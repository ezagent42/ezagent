defmodule EzagentDomainInstanceMessage.Integration.PublisherSessionTest do
  @moduledoc """
  Integration test for the Session Kind as a `Ezagent.ActionSet.Publisher`
  implementer — drives the production path:

      Kind.spawn(Session) → post_init/2 subscribes to SliceChange topic →
      chat.send / chat.join mutates :chat slice → Runtime emits SliceChange →
      Server forwards via handle_info → SessionImpl.handle_kind_message →
      ring + fanout to live subscribers.

  Plus the `subscribe_from / snapshot / history` dispatch round-trips
  go through the standard `Invocation.dispatch/1` path (Session module
  functions are thin wrappers per `apps/ezagent_domain_session/lib/ezagent/entity/session.ex`
  PR-EM-0 amendment).

  ## Why these tests live here (not in external_mirror)

  external_mirror has zero deps on chat (intentional — see SPEC §9
  PR-EM-0 dep declaration). Live-Session dispatch tests need
  Session, Chat Behavior, WorkspaceRegistry, MessageStore — all in
  chat — so they live alongside the chat integration suite.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.{Session, User}
  alias Ezagent.{Invocation, KindRegistry}
  alias Ezagent.Publisher.Event

  setup do
    # PR-N1's SliceChange hook is OFF by default — enable for this
    # suite so :chat slice changes propagate to the Publisher.
    original = Application.get_env(:ezagent_core, :slice_change_hook)
    Application.put_env(:ezagent_core, :slice_change_hook, true)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:ezagent_core, :slice_change_hook)
      else
        Application.put_env(:ezagent_core, :slice_change_hook, original)
      end
    end)

    :ok
  end

  defp spawn_session do
    session_uri =
      Ezagent.URI.new!(
        "session://system/default/publisher-test-#{System.unique_integer([:positive])}"
      )

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Ezagent.Entity.Session.behaviors(),
        # P5-A: `:snapshot`/`:history` are now MEMBERSHIP-gated (cap-exempt +
        # a live `ChatMembership` owner/member check), so the `admin_ctx`
        # reader must be the session OWNER to pass authz. (`:subscribe_from`
        # is still cap-gated, so admin's bootstrap caps cover it regardless.)
        owner_uri: User.admin_uri()
      })

    :ok =
      Ezagent.WorkspaceRegistry.bind(
        session_uri,
        Ezagent.Capability.workspace_of(session_uri)
      )

    :ok =
      Ezagent.ActionSet.Session.MemberCap.grant_owner_at_creation(
        session_uri,
        User.admin_uri()
      )

    on_exit(fn ->
      case KindRegistry.lookup(session_uri) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid)

        :error ->
          :ok
      end
    end)

    session_uri
  end

  # Mutate the :chat slice via `chat.join` — the simplest slice-
  # mutating path on Session (writes `members` + `monitors`). `chat.send`
  # is read-only on the slice (writes to MessageStore via Repo), so
  # it does NOT trigger a SliceChange event — using it here would be
  # a no-op for our Publisher hook.
  defp spawn_member_user do
    member_uri =
      Ezagent.URI.new!(
        "entity://system/user/pub-test-member-#{System.unique_integer([:positive])}"
      )

    {:ok, pid} =
      Ezagent.Kind.spawn(User, %{uri: member_uri, initial_caps: MapSet.new()})

    on_exit(fn ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(
          EzagentDomainIdentity.Application.UserSupervisor,
          pid
        )
      end
    end)

    member_uri
  end

  defp mutate_chat_slice(session_uri) do
    # Each call adds a NEW unique member → slice ALWAYS differs from
    # prior → SliceChange fires every time.
    member_uri = spawn_member_user()
    target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")
    admin = User.admin_uri()
    cap = Ezagent.Test.CapHelper.signed_action_cap!(target, admin)

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{member: member_uri},
      ctx: %{
        caller: admin,
        authenticated_principal: admin,
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  # Codex round-1 CRITICAL fix (2026-05-25) — Session.subscribe_from/3
  # etc. now RAISE; production callers must use the 4-ary form with
  # an explicit ctx. Tests supply admin caps explicitly.
  defp admin_ctx(session_uri) do
    subscribe_cap =
      Ezagent.Test.CapHelper.signed_fixture_cap!(
        session_uri,
        :session,
        Ezagent.ActionSet.Publisher.SessionImpl,
        :subscribe_from,
        User.admin_uri()
      )

    %{
      caller: User.admin_uri(),
      authenticated_principal: User.admin_uri(),
      caps: MapSet.new([subscribe_cap])
    }
  end

  describe "Session.subscribe_from/4 with :latest (production path)" do
    test "subscriber receives the NEXT mutation's event (no backlog)" do
      session_uri = spawn_session()

      # Owner-cap convergence is the first durable membership event.
      wait_until_cursor(session_uri, 1)

      assert {:ok, baseline} =
               Session.subscribe_from(session_uri, self(), :latest, admin_ctx(session_uri))

      # Mutate (chat.join adds a new member to the :chat slice).
      assert {:ok, %{status: :granted}} = mutate_chat_slice(session_uri)

      # Receive the publisher event.
      assert_receive {:publisher_event, %Event{cursor: cursor, slice_key: :session}}, 500
      assert cursor == baseline + 1
    end
  end

  describe "Session.subscribe_from/4 with :earliest" do
    test "subscriber receives entire retained history in order" do
      session_uri = spawn_session()
      wait_until_cursor(session_uri, 1)

      # Pre-populate with 3 mutations.
      Enum.each(1..3, fn _ -> {:ok, _} = mutate_chat_slice(session_uri) end)

      # Wait for all 3 SliceChange events to have been processed by
      # the Server's handle_info → SessionImpl.handle_kind_message
      # (eventually consistent — give it a beat).
      wait_until_cursor(session_uri, 4)
      wait_until_cursor_stable(session_uri)

      replay_cursor = publisher_slice(session_uri).cursor

      # Now subscribe :earliest from a fresh listener pid.
      parent = self()

      pid =
        spawn(fn ->
          msgs = collect_events(replay_cursor, [])
          send(parent, {:replayed, msgs})
        end)

      assert {:ok, ^replay_cursor} =
               Session.subscribe_from(session_uri, pid, :earliest, admin_ctx(session_uri))

      assert_receive {:replayed, events}, 500
      assert Enum.map(events, & &1.cursor) == Enum.to_list(1..replay_cursor)
    end
  end

  describe "Session.history/4 dispatch round-trip" do
    test "returns the (from, to] window from the live ring" do
      session_uri = spawn_session()
      wait_until_cursor(session_uri, 1)

      Enum.each(1..5, fn _ -> {:ok, _} = mutate_chat_slice(session_uri) end)
      wait_until_cursor(session_uri, 6)

      assert {:ok, events} = Session.history(session_uri, 1, 3, admin_ctx(session_uri))
      assert Enum.map(events, & &1.cursor) == [2, 3]
    end
  end

  describe "Session.snapshot/2 dispatch round-trip" do
    test "returns current cursor + the latest payload as state" do
      session_uri = spawn_session()
      wait_until_cursor(session_uri, 1)

      {:ok, _} = mutate_chat_slice(session_uri)
      wait_until_cursor(session_uri, 2)

      assert {:ok, %{cursor: cursor, state: state}} =
               Session.snapshot(session_uri, admin_ctx(session_uri))

      # `state` is the most recent event's payload — under the PR-EM-0
      # shape, that's a map with `:new_slice`. Just assert the shape;
      # exact content is the Chat Behavior's concern.
      assert cursor >= 2
      assert is_map(state)
      assert Map.has_key?(state, :new_slice)
    end
  end

  describe "no-ambient-caps invariant (codex round-1 CRITICAL fix)" do
    test "Session.subscribe_from/3 raises — forces caller to supply ctx" do
      assert_raise ArgumentError, ~r/requires an explicit caller ctx/, fn ->
        Session.subscribe_from(
          Ezagent.URI.new!("session://team-alpha/default/x"),
          self(),
          :latest
        )
      end
    end

    test "Session.snapshot/1 raises — forces caller to supply ctx" do
      assert_raise ArgumentError, ~r/requires an explicit caller ctx/, fn ->
        Session.snapshot(Ezagent.URI.new!("session://team-alpha/default/x"))
      end
    end

    test "Session.history/3 raises — forces caller to supply ctx" do
      assert_raise ArgumentError, ~r/requires an explicit caller ctx/, fn ->
        Session.history(Ezagent.URI.new!("session://team-alpha/default/x"), 0, :latest)
      end
    end

    test "a caller with empty caps cannot subscribe (step 5.5 denies)" do
      session_uri = spawn_session()
      wait_until_cursor(session_uri, 1)

      empty_ctx = %{
        caller:
          Ezagent.URI.new!(
            "entity://team-alpha/user/no-caps-#{System.unique_integer([:positive])}"
          ),
        caps: MapSet.new()
      }

      empty_ctx = Map.put(empty_ctx, :authenticated_principal, empty_ctx.caller)

      assert {:error, :missing_cap} =
               Session.subscribe_from(session_uri, self(), :latest, empty_ctx)
    end
  end

  describe "durability invariant (codex round-1 HIGH fix)" do
    test "publisher cursor + ring survive a Session restart" do
      session_uri = spawn_session()

      # Emit 3 events.
      Enum.each(1..3, fn _ -> {:ok, _} = mutate_chat_slice(session_uri) end)
      wait_until_cursor(session_uri, 4)
      wait_until_cursor_stable(session_uri)

      pre_restart = publisher_slice(session_uri)
      expected_cursor = pre_restart.cursor
      expected_ring_cursors = Enum.map(pre_restart.ring, & &1.cursor)

      assert expected_cursor >= 4
      assert length(pre_restart.ring) == expected_cursor

      # Restart the Session Kind.
      {:ok, pid_before} = Ezagent.KindRegistry.lookup(session_uri)

      :ok =
        DynamicSupervisor.terminate_child(
          EzagentDomainInstanceMessage.SessionSupervisor,
          pid_before
        )

      # Wait for it to be gone.
      Enum.reduce_while(1..50, nil, fn _, _ ->
        case Ezagent.KindRegistry.lookup(session_uri) do
          :error ->
            {:halt, :ok}

          _ ->
            Process.sleep(20)
            {:cont, nil}
        end
      end)

      # Respawn — snapshot restore should bring back cursor + ring.
      {:ok, _new_pid} =
        Ezagent.Kind.spawn(Session, %{
          uri: session_uri,
          behaviors: Ezagent.Entity.Session.behaviors()
        })

      :ok =
        Ezagent.WorkspaceRegistry.bind(session_uri, Ezagent.Capability.workspace_of(session_uri))

      post_restart = publisher_slice(session_uri)

      assert post_restart.cursor == expected_cursor,
             "Expected cursor=#{expected_cursor} to survive restart; got #{post_restart.cursor}. " <>
               "If this fails, Kind.Server's handle_info path is NOT persisting " <>
               "SessionImpl's :slice_changed mutations — codex round-1 HIGH fix " <>
               "regressed."

      # Ring contents survive, including the born-owner membership event.
      assert Enum.map(post_restart.ring, & &1.cursor) == expected_ring_cursors
    end
  end

  # ---- helpers ----------------------------------------------------------

  # Lifecycle migration (SPEC 2026-05-29): the `:publisher` slice is now a
  # two-container `%{state:, transients:}` map (`ring`/`cursor`/`retention`
  # under `.state`; `subscribers`/`monitors` under `.transients`). This
  # raw `:sys.get_state` helper sees the full split — flatten the two
  # containers back into one map so the existing `%{cursor:}` /
  # `%{subscribers:}` assertions keep reading the right values.
  defp publisher_slice(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    state = :sys.get_state(pid)

    case Map.get(state.state, :publisher, %{}) do
      %{state: persistent, transients: transients} -> Map.merge(persistent, transients)
      flat -> flat
    end
  end

  defp wait_until_cursor(session_uri, target, attempts \\ 50)

  defp wait_until_cursor(_session_uri, _target, 0),
    do: flunk("publisher cursor never reached target")

  defp wait_until_cursor(session_uri, target, attempts) when attempts > 0 do
    case publisher_slice(session_uri) do
      %{cursor: c} when c >= target ->
        :ok

      _ ->
        Process.sleep(20)
        wait_until_cursor(session_uri, target, attempts - 1)
    end
  end

  defp wait_until_cursor_stable(session_uri, attempts \\ 50, stable_reads \\ 3)

  defp wait_until_cursor_stable(_session_uri, 0, _stable_reads),
    do: flunk("publisher cursor did not stabilize")

  defp wait_until_cursor_stable(session_uri, attempts, stable_reads) do
    cursor = publisher_slice(session_uri).cursor

    if cursor_stable_for?(session_uri, cursor, stable_reads) do
      :ok
    else
      wait_until_cursor_stable(session_uri, attempts - 1, stable_reads)
    end
  end

  defp cursor_stable_for?(_session_uri, _cursor, 0), do: true

  defp cursor_stable_for?(session_uri, cursor, reads_left) do
    Process.sleep(20)

    publisher_slice(session_uri).cursor == cursor and
      cursor_stable_for?(session_uri, cursor, reads_left - 1)
  end

  defp collect_events(0, acc), do: Enum.reverse(acc)

  defp collect_events(n, acc) when n > 0 do
    receive do
      {:publisher_event, %Event{} = ev} -> collect_events(n - 1, [ev | acc])
    after
      500 -> Enum.reverse(acc)
    end
  end
end
