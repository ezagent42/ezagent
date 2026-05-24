defmodule EzagentDomainChat.Integration.PublisherSessionTest do
  @moduledoc """
  Integration test for the Session Kind as a `Ezagent.Behavior.Publisher`
  implementer — drives the production path:

      Kind.spawn(Session) → post_init/2 subscribes to SliceChange topic →
      chat.send / chat.join mutates :chat slice → Runtime emits SliceChange →
      Server forwards via handle_info → SessionImpl.handle_kind_message →
      ring + fanout to live subscribers.

  Plus the `subscribe_from / snapshot / history` dispatch round-trips
  go through the standard `Invocation.dispatch/1` path (Session module
  functions are thin wrappers per `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex`
  PR-EM-0 amendment).

  ## Why these tests live here (not in external_mirror)

  external_mirror has zero deps on chat (intentional — see SPEC §9
  PR-EM-0 dep declaration). Live-Session dispatch tests need
  Session, Chat Behavior, WorkspaceRegistry, MessageStore — all in
  chat — so they live alongside the chat integration suite.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.{Session, User}
  alias Ezagent.{Invocation, KindRegistry, Message}
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
      URI.parse("session://default/default/publisher-test-#{System.unique_integer([:positive])}")

    {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: session_uri})

    :ok =
      Ezagent.WorkspaceRegistry.bind(
        session_uri,
        Ezagent.Capability.workspace_of(session_uri)
      )

    on_exit(fn ->
      case KindRegistry.lookup(session_uri) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(EzagentDomainChat.SessionSupervisor, pid)

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
      URI.parse("entity://user/default/pub-test-member-#{System.unique_integer([:positive])}")

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

    Invocation.dispatch(%Invocation{
      target: URI.new!("#{URI.to_string(session_uri)}?action=chat.join"),
      mode: :call,
      args: %{member: member_uri},
      ctx: %{
        caller: User.admin_uri(),
        caps: User.admin_caps(),
        reply: {:caller_inbox, self()}
      }
    })
  end

  describe "Session.subscribe_from/3 with :latest (production path)" do
    test "subscriber receives the NEXT mutation's event (no backlog)" do
      session_uri = spawn_session()

      # Subscribe BEFORE mutating; cursor=0 at this point.
      assert {:ok, 0} = Session.subscribe_from(session_uri, self(), :latest)

      # Mutate (chat.join adds a new member to the :chat slice).
      assert {:ok, %{members: _}} = mutate_chat_slice(session_uri)

      # Receive the publisher event.
      assert_receive {:publisher_event, %Event{cursor: 1, slice_key: :chat}}, 500
    end
  end

  describe "Session.subscribe_from/3 with :earliest" do
    test "subscriber receives entire retained history in order" do
      session_uri = spawn_session()

      # Pre-populate with 3 mutations.
      Enum.each(1..3, fn _ -> {:ok, _} = mutate_chat_slice(session_uri) end)

      # Wait for all 3 SliceChange events to have been processed by
      # the Server's handle_info → SessionImpl.handle_kind_message
      # (eventually consistent — give it a beat).
      wait_until_cursor(session_uri, 3)

      # Now subscribe :earliest from a fresh listener pid.
      parent = self()

      pid =
        spawn(fn ->
          msgs = collect_events(3, [])
          send(parent, {:replayed, msgs})
        end)

      assert {:ok, 3} = Session.subscribe_from(session_uri, pid, :earliest)

      assert_receive {:replayed, events}, 500
      assert Enum.map(events, & &1.cursor) == [1, 2, 3]
    end
  end

  describe "Session.history/3 dispatch round-trip" do
    test "returns the (from, to] window from the live ring" do
      session_uri = spawn_session()

      Enum.each(1..5, fn _ -> {:ok, _} = mutate_chat_slice(session_uri) end)
      wait_until_cursor(session_uri, 5)

      assert {:ok, events} = Session.history(session_uri, 1, 3)
      assert Enum.map(events, & &1.cursor) == [2, 3]
    end
  end

  describe "Session.snapshot/1 dispatch round-trip" do
    test "returns current cursor + the latest payload as state" do
      session_uri = spawn_session()

      {:ok, _} = mutate_chat_slice(session_uri)
      wait_until_cursor(session_uri, 1)

      assert {:ok, %{cursor: 1, state: state}} = Session.snapshot(session_uri)
      # `state` is the most recent event's payload — under the PR-EM-0
      # shape, that's a map with `:new_slice`. Just assert the shape;
      # exact content is the Chat Behavior's concern.
      assert is_map(state)
      assert Map.has_key?(state, :new_slice)
    end
  end

  # ---- helpers ----------------------------------------------------------

  defp publisher_slice(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    state = :sys.get_state(pid)
    Map.get(state.state, :publisher, %{})
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

  defp collect_events(0, acc), do: Enum.reverse(acc)

  defp collect_events(n, acc) when n > 0 do
    receive do
      {:publisher_event, %Event{} = ev} -> collect_events(n - 1, [ev | acc])
    after
      500 -> Enum.reverse(acc)
    end
  end
end
