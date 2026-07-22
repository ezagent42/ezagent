defmodule EzagentDomainInstanceMessage.PresenceFanoutTest do
  @moduledoc """
  Tests for `EzagentDomainInstanceMessage.PresenceFanout` — Decision Log #93
  consumer that bridges `Ezagent.Presence` diffs into per-session
  `:events` topics.

  These tests broadcast the membership-change events directly (rather
  than going through `Ezagent.ActionSet.Session.invoke(:join)` end-to-end)
  to keep the test fast + isolated. The chat-behavior integration is
  exercised via existing chat tests.
  """

  # DataCase (not bare ExUnit.Case) — the "bootstrap rebuild" test calls
  # Ezagent.Users.create/3 + EzagentDomainInstanceMessage.SessionCreator.create_session/3, which hit
  # the Repo from the test process and from spawned Kinds. Without a sandbox
  # checkout in shared mode those raise DBConnection.OwnershipError. DataCase
  # also brings the P6 owner-exit Kind drain.
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.ActionSet.Session.Membership
  alias Ezagent.Presence
  alias EzagentDomainInstanceMessage.PresenceFanout

  # Canonical (`authority: nil`) construction — PresenceFanout rebroadcasts
  # `:member_presence` with the canonical member_uri (`Ezagent.URI.new!`
  # derived from the Presence topic), so a test pinning `^member_uri` must
  # hold the canonical struct. `URI.parse/1` yields the non-canonical
  # `authority`-bearing shape and the assert_receive pin would never match.
  defp unique_session_uri(suffix),
    do:
      Ezagent.URI.new!(
        "session://team-alpha/default/presence_fanout_#{suffix}_#{System.unique_integer([:positive])}"
      )

  defp unique_user_uri(suffix),
    do:
      Ezagent.URI.new!(
        "entity://team-alpha/user/presence_fanout_#{suffix}_#{System.unique_integer([:positive])}"
      )

  defp broadcast_change(session_uri, event) do
    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      "esr:session_membership:changes",
      {:session_membership_change, session_uri, event}
    )
  end

  defp wait_for(fun, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    if do_wait(fun, deadline) do
      :ok
    else
      flunk("wait_for timed out")
    end
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(10)
        do_wait(fun, deadline)
    end
  end

  describe "membership-change index maintenance" do
    test ":member_joined adds (user → session) to the index" do
      session_uri = unique_session_uri("join_idx")
      member_uri = unique_user_uri("join_idx")

      broadcast_change(session_uri, {:member_joined, member_uri})
      wait_for(fn -> Map.has_key?(PresenceFanout.__index__(), member_uri) end)

      idx = PresenceFanout.__index__()
      assert MapSet.member?(idx[member_uri], session_uri)
    end

    test ":member_left removes (user → session) from the index" do
      session_uri = unique_session_uri("leave_idx")
      member_uri = unique_user_uri("leave_idx")

      broadcast_change(session_uri, {:member_joined, member_uri})
      wait_for(fn -> Map.has_key?(PresenceFanout.__index__(), member_uri) end)

      broadcast_change(session_uri, {:member_left, member_uri})
      wait_for(fn -> not Map.has_key?(PresenceFanout.__index__(), member_uri) end)

      refute Map.has_key?(PresenceFanout.__index__(), member_uri)
    end

    test "member in MULTIPLE sessions stays indexed until LAST session leaves" do
      session_a = unique_session_uri("multi_a")
      session_b = unique_session_uri("multi_b")
      member_uri = unique_user_uri("multi_member")

      broadcast_change(session_a, {:member_joined, member_uri})
      broadcast_change(session_b, {:member_joined, member_uri})

      wait_for(fn ->
        sessions = Map.get(PresenceFanout.__index__(), member_uri, MapSet.new())
        MapSet.size(sessions) == 2
      end)

      # Leave session_a — should still be indexed under session_b
      broadcast_change(session_a, {:member_left, member_uri})

      wait_for(fn ->
        sessions = Map.get(PresenceFanout.__index__(), member_uri, MapSet.new())
        MapSet.size(sessions) == 1
      end)

      assert MapSet.equal?(
               Map.get(PresenceFanout.__index__(), member_uri),
               MapSet.new([session_b])
             )

      # Leave session_b — now drop from index
      broadcast_change(session_b, {:member_left, member_uri})

      wait_for(fn -> not Map.has_key?(PresenceFanout.__index__(), member_uri) end)
    end

    test ":member_offline does NOT change the index (membership stays)" do
      session_uri = unique_session_uri("offline_idx")
      member_uri = unique_user_uri("offline_idx")

      broadcast_change(session_uri, {:member_joined, member_uri})
      wait_for(fn -> Map.has_key?(PresenceFanout.__index__(), member_uri) end)

      broadcast_change(session_uri, {:member_offline, member_uri, DateTime.utc_now()})

      # Give the GenServer a tick to process the offline event
      Process.sleep(50)

      # Index unchanged — member is still in session_uri
      assert MapSet.member?(
               Map.get(PresenceFanout.__index__(), member_uri, MapSet.new()),
               session_uri
             )
    end
  end

  describe "bootstrap rebuild (PR-5)" do
    test "fanout restart picks up existing session members from KindRegistry" do
      # Setup: create a session via the canonical facade so it's real,
      # join an extra member, then RESTART the fanout and assert the
      # index gets re-populated from the live Session's :chat slice.
      member_uri =
        Ezagent.URI.new!(
          "entity://system/user/bootstrap_test_#{System.unique_integer([:positive])}"
        )

      # Spawn the member user Kind
      {:ok, _} = Ezagent.Users.create(URI.to_string(member_uri), nil, [])
      {:ok, _pid} = Ezagent.SpawnRegistry.spawn(member_uri)

      # Create a session + join member
      admin_uri = Ezagent.Entity.User.admin_uri()
      {:ok, _} = Ezagent.SpawnRegistry.spawn(admin_uri)

      short = "bootstrap_test_#{System.unique_integer([:positive])}"

      {:ok, session_uri, _meta} =
        EzagentDomainInstanceMessage.SessionCreator.create_session(short, admin_uri,
          template_name: "default"
        )

      # chat.join member
      join_target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")
      :ok = Membership.provision_invited_join_authority(session_uri, member_uri, admin_uri)

      assert {:ok, %{status: :granted, member: ^member_uri}} =
               Ezagent.Invocation.dispatch(%Ezagent.Invocation{
                 origin: :trusted_internal,
                 target: join_target,
                 mode: :call,
                 args: %{member: member_uri},
                 ctx: %{
                   caller: member_uri,
                   authenticated_principal: member_uri,
                   caps: Ezagent.Identity.list_caps_for(member_uri),
                   reply: :inline
                 }
               })

      # Wait for the :session_membership_change → fanout to settle
      wait_for(fn -> Map.has_key?(PresenceFanout.__index__(), member_uri) end)

      # Sanity: index has the member
      assert Map.has_key?(PresenceFanout.__index__(), member_uri)

      # Stop the fanout — supervisor will restart it
      pid_before = Process.whereis(PresenceFanout)
      ref = Process.monitor(pid_before)
      Process.exit(pid_before, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid_before, _}, 1_000

      # Wait for supervisor restart
      wait_for(fn ->
        pid = Process.whereis(PresenceFanout)
        is_pid(pid) and pid != pid_before
      end)

      # The new fanout's bootstrap_rebuild should have re-indexed
      # the EXISTING session→member mapping from the live KindRegistry.
      wait_for(fn -> Map.has_key?(PresenceFanout.__index__(), member_uri) end, 2_000)

      assert MapSet.member?(
               Map.get(PresenceFanout.__index__(), member_uri, MapSet.new()),
               session_uri
             )
    end
  end

  describe "presence-diff → session :events fan-out" do
    test "transport joining fans :member_presence online?: true to session topic" do
      session_uri = unique_session_uri("fanout_on")
      member_uri = unique_user_uri("fanout_on")

      # Subscribe to the session's events topic FIRST — assertion target
      Phoenix.PubSub.subscribe(
        EzagentCore.PubSub,
        SessionBehavior.session_events_topic(session_uri)
      )

      # Register interest
      broadcast_change(session_uri, {:member_joined, member_uri})
      wait_for(fn -> Map.has_key?(PresenceFanout.__index__(), member_uri) end)

      # Drain the :member_joined event the fanout's broadcast_change/2
      # caller sent on session topic too — we want a clean inbox before
      # the presence step.
      flush_member_events()

      # Track presence in a separate process — keep it alive so the entry
      # stays during assertion.
      tracker =
        spawn(fn ->
          {:ok, _} = Presence.track(member_uri, "tab1", %{transport: :liveview})

          receive do
            :exit -> :ok
          end
        end)

      assert_receive {:member_presence, ^session_uri, ^member_uri, %{online?: true}}, 2_000

      send(tracker, :exit)
    end

    test "last transport leaving fans :member_presence online?: false" do
      session_uri = unique_session_uri("fanout_off")
      member_uri = unique_user_uri("fanout_off")

      Phoenix.PubSub.subscribe(
        EzagentCore.PubSub,
        SessionBehavior.session_events_topic(session_uri)
      )

      broadcast_change(session_uri, {:member_joined, member_uri})
      wait_for(fn -> Map.has_key?(PresenceFanout.__index__(), member_uri) end)

      flush_member_events()

      tracker =
        spawn(fn ->
          {:ok, _} = Presence.track(member_uri, "tab_off", %{transport: :liveview})

          receive do
            :exit -> :ok
          end
        end)

      assert_receive {:member_presence, ^session_uri, ^member_uri, %{online?: true}}, 2_000

      send(tracker, :exit)
      assert_receive {:member_presence, ^session_uri, ^member_uri, %{online?: false}}, 2_000
    end
  end

  defp flush_member_events do
    receive do
      {:member_joined, _} -> flush_member_events()
      {:member_left, _} -> flush_member_events()
      {:member_offline, _, _} -> flush_member_events()
    after
      0 -> :ok
    end
  end
end
