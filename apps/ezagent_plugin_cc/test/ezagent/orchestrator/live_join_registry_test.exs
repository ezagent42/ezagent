defmodule Ezagent.Orchestrator.LiveJoinRegistryTest do
  @moduledoc """
  Unit tests for `Ezagent.Orchestrator.LiveJoinRegistry` (the durable
  live-bridge-joined? state) AND the readiness-gate poll that reads it.

  ## Why this exists

  The orchestrator startup gate USED to rely on a FIRE-ONCE PubSub
  broadcast (`{:orchestrator_ready, uri}` from `McpChannel.join/3`). The
  creating process missed the broadcast whenever its `receive` was not
  yet parked at the instant the live bridge joined — so the gate timed
  out and KILLED a working orchestrator, rolling back the create with
  EMPTY members. The fix records the join as DURABLE STATE and POLLS it,
  so a join that already happened is still observed. These tests pin both
  halves: the registry mark/joined?/clear contract, and the gate poll
  resolving `:ready` on a mark within the window + fail-loud when never
  marked.
  """

  use ExUnit.Case, async: false

  alias Ezagent.Orchestrator.LiveJoinRegistry

  setup do
    :ok = LiveJoinRegistry.init()
    uri = Ezagent.URI.new!("entity://default/agent/cc_orchestrator-test#{System.unique_integer([:positive])}")
    on_exit(fn -> LiveJoinRegistry.clear(uri) end)
    {:ok, uri: uri}
  end

  describe "mark_joined/1 + joined?/1 + clear/1" do
    test "an un-marked orchestrator is not joined", %{uri: uri} do
      refute LiveJoinRegistry.joined?(uri)
    end

    test "mark_joined makes joined? true", %{uri: uri} do
      assert :ok = LiveJoinRegistry.mark_joined(uri)
      assert LiveJoinRegistry.joined?(uri)
    end

    test "clear removes the live-join row", %{uri: uri} do
      :ok = LiveJoinRegistry.mark_joined(uri)
      assert LiveJoinRegistry.joined?(uri)

      assert :ok = LiveJoinRegistry.clear(uri)
      refute LiveJoinRegistry.joined?(uri)
    end

    test "mark_joined is idempotent", %{uri: uri} do
      :ok = LiveJoinRegistry.mark_joined(uri)
      :ok = LiveJoinRegistry.mark_joined(uri)
      assert LiveJoinRegistry.joined?(uri)
    end

    test "clear of an absent row is a no-op", %{uri: uri} do
      assert :ok = LiveJoinRegistry.clear(uri)
      refute LiveJoinRegistry.joined?(uri)
    end

    test "marks are per-URI — one orchestrator's join does not satisfy another", %{uri: uri} do
      other = Ezagent.URI.new!("entity://default/agent/cc_orchestrator-other")
      on_exit(fn -> LiveJoinRegistry.clear(other) end)

      :ok = LiveJoinRegistry.mark_joined(uri)
      assert LiveJoinRegistry.joined?(uri)
      refute LiveJoinRegistry.joined?(other)
    end
  end

  describe "readiness gate poll (Session.__await_orchestrator_ready_for_test__/3)" do
    test "returns :ready when LiveJoinRegistry is marked within the window (live join from another process)",
         %{uri: uri} do
      ok = {:ok, uri, :created}

      # Simulate the live bridge join from ANOTHER process AFTER the gate
      # has started polling — the exact race the fire-once broadcast lost.
      spawn(fn ->
        Process.sleep(150)
        LiveJoinRegistry.mark_joined(uri)
      end)

      assert ^ok =
               Ezagent.Entity.Session.__await_orchestrator_ready_for_test__(ok, uri, 5_000)

      assert LiveJoinRegistry.joined?(uri)
    end

    test "returns :ready immediately when the join already happened before the gate parked",
         %{uri: uri} do
      ok = {:ok, uri, :created}
      # Join completed BEFORE the gate runs — the lost-broadcast scenario.
      :ok = LiveJoinRegistry.mark_joined(uri)

      assert ^ok =
               Ezagent.Entity.Session.__await_orchestrator_ready_for_test__(ok, uri, 5_000)
    end

    test "fail-loud {:error, {:orchestrator_not_ready_within, _}} when never marked", %{uri: uri} do
      ok = {:ok, uri, :created}
      refute LiveJoinRegistry.joined?(uri)

      assert {:error, {:orchestrator_not_ready_within, ms}} =
               Ezagent.Entity.Session.__await_orchestrator_ready_for_test__(ok, uri, 200)

      assert is_integer(ms)
    end
  end
end
