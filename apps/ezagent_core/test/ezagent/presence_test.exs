defmodule Ezagent.PresenceTest do
  @moduledoc """
  Unit tests for `Ezagent.Presence`. Covers:

  - `track + list + present?` round-trips (auto-untrack on process exit)
  - Multiple transport_ids on the same URI
  - `track/4` with explicit pid arg
  - `subscribe/1` event delivery (tuple shape, NOT %Phoenix.Socket.Broadcast)
  - Event-shape normalization (`%{transport_id => [meta]}`, NOT
    `%{transport_id => %{metas: [meta]}}` — codex rev-2 round-2 HIGH-2
    regression test)

  `async: false` because the Tracker is a global singleton; tests use
  unique URIs per case so they don't collide.
  """

  use ExUnit.Case, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.Presence

  defp unique_user_uri(suffix) do
    URI.parse(
      "entity://team-alpha/user/presence_test_#{suffix}_#{System.unique_integer([:positive])}"
    )
  end

  defp wait_for(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for(fun, deadline)
  end

  defp do_wait_for(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("wait_for timed out")
      else
        Process.sleep(10)
        do_wait_for(fun, deadline)
      end
    end
  end

  describe "track + list + present?" do
    test "single-transport round-trip" do
      uri = unique_user_uri("rt")
      {:ok, _ref} = Presence.track(uri, "liveview:tab1", %{transport: :liveview})

      assert Presence.present?(uri) == true
      assert %{"liveview:tab1" => [meta]} = Presence.list(uri)
      assert meta.transport == :liveview
    end

    test "multiple transport_ids on same URI" do
      uri = unique_user_uri("multi")
      {:ok, _} = Presence.track(uri, "liveview:tab1", %{transport: :liveview})
      {:ok, _} = Presence.track(uri, "feishu:chat1", %{transport: :feishu})

      list = Presence.list(uri)
      assert Map.has_key?(list, "liveview:tab1")
      assert Map.has_key?(list, "feishu:chat1")
    end

    test "untrack removes the entry" do
      uri = unique_user_uri("untrack")
      {:ok, _} = Presence.track(uri, "x", %{transport: :liveview})
      assert Presence.present?(uri)

      :ok = Presence.untrack(uri, "x")
      assert Presence.present?(uri) == false
    end

    test "calling-process exit removes the entry (auto-cleanup)" do
      uri = unique_user_uri("autocleanup")
      parent = self()

      pid =
        spawn(fn ->
          {:ok, _} = Presence.track(uri, "child", %{transport: :liveview})
          send(parent, :tracked)
          # Wait until parent signals to exit
          receive do
            :exit -> :ok
          end
        end)

      assert_receive :tracked, 1_000
      assert Presence.present?(uri)

      send(pid, :exit)
      # Wait for Phoenix.Presence DOWN to propagate
      wait_for(fn -> not Presence.present?(uri) end, 2_000)
      assert Presence.present?(uri) == false
    end

    test "track/4 with explicit pid arg uses that pid's lifetime" do
      uri = unique_user_uri("explicit_pid")
      parent = self()

      pid =
        spawn(fn ->
          receive do
            :exit -> :ok
          end

          send(parent, :exited)
        end)

      # Track on behalf of pid (not self())
      {:ok, _} = Presence.track(pid, uri, "x", %{transport: :liveview})
      assert Presence.present?(uri)

      send(pid, :exit)
      assert_receive :exited, 1_000
      wait_for(fn -> not Presence.present?(uri) end, 2_000)
      assert Presence.present?(uri) == false
    end
  end

  describe "subscribe/1 — event delivery" do
    test "subscriber receives tuple-shape :joins diff" do
      uri = unique_user_uri("sub_join")
      :ok = Presence.subscribe(uri)

      spawn(fn ->
        {:ok, _} = Presence.track(uri, "j1", %{transport: :liveview})
        # Keep alive so the entry stays until assert finishes
        Process.sleep(500)
      end)

      assert_receive {:ezagent_presence_diff, _topic,
                      %{joins: joins, leaves: leaves, current: current}},
                     2_000

      # CODEX HIGH-2 REGRESSION: shape MUST be %{tid => [meta]}, NOT
      # %{tid => %{metas: [meta]}}.
      assert %{"j1" => [meta]} = joins
      assert meta.transport == :liveview
      assert leaves == %{}
      # current includes the just-joined entry
      assert %{"j1" => [_]} = current
    end

    test "subscriber receives tuple-shape :leaves diff on process exit" do
      uri = unique_user_uri("sub_leave")
      :ok = Presence.subscribe(uri)

      tracker =
        spawn(fn ->
          {:ok, _} = Presence.track(uri, "L1", %{transport: :liveview})

          receive do
            :exit -> :ok
          end
        end)

      # Wait for the join
      assert_receive {:ezagent_presence_diff, _topic, %{joins: %{"L1" => _}}}, 2_000

      send(tracker, :exit)
      assert_receive {:ezagent_presence_diff, _topic, %{leaves: %{"L1" => _}}}, 2_000
    end
  end

  describe "subscribe/1 — argument validation" do
    test "worker principals share Agent presence semantics" do
      assert :ok = Presence.subscribe(Ezagent.URI.worker("team-alpha", "worker-presence"))
    end

    test "non-User/Agent scheme raises ArgumentError" do
      assert_raise ArgumentError, ~r/unsupported URI/, fn ->
        Presence.subscribe(Ezagent.URI.new!("session://system/default/main"))
      end
    end
  end

  describe "topic/1" do
    test "wraps URI in esr:presence:" do
      uri = Ezagent.URI.new!("entity://team-alpha/user/topic_test")
      assert Presence.topic(uri) == "esr:presence:entity://team-alpha/user/topic_test"
    end

    test "accepts string URI too" do
      assert Presence.topic("entity://team-alpha/user/abc") ==
               "esr:presence:entity://team-alpha/user/abc"
    end
  end
end
