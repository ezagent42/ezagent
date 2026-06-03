defmodule Ezagent.AgentLineageTest do
  @moduledoc """
  Remediation C-B (#114) — `Ezagent.AgentLineage` durable backing.

  These tests pin the write-through + boot-rehydrate contract: the ETS
  cache is fast but volatile; the `agent_lineage` SQLite table is the
  source of truth, so a simulated restart (clear ETS → `rehydrate/0`)
  must restore every recorded lineage entry. This test FAILS exactly
  when the durable backing regresses — i.e. when `record/2` stops
  write-through or `rehydrate/0` stops re-populating from the table.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.AgentLineage

  defp agent_uri(name),
    do: URI.parse("entity://agent/team-alpha/#{name}-#{System.unique_integer([:positive])}")

  defp principal_uri(name),
    do: URI.parse("entity://user/team-alpha/#{name}-#{System.unique_integer([:positive])}")

  describe "record/2 + lookup/1 (fast ETS read path)" do
    test "record then lookup round-trips" do
      agent = agent_uri("a")
      parent = principal_uri("p")

      :ok = AgentLineage.record(agent, parent)
      assert {:ok, looked_up} = AgentLineage.lookup(agent)
      assert URI.to_string(looked_up) == URI.to_string(parent)
    end

    test "lookup of an unrecorded agent returns :error" do
      assert :error = AgentLineage.lookup(agent_uri("missing"))
    end
  end

  describe "durable backing — survives a simulated restart" do
    test "record write-through + rehydrate restores lineage after ETS is cleared" do
      agent = agent_uri("durable")
      parent = principal_uri("owner")

      :ok = AgentLineage.record(agent, parent)
      assert {:ok, _} = AgentLineage.lookup(agent)

      # Simulate a cold restart: the ETS cache is recreated EMPTY by
      # EzagentCore.EtsOwner on every boot. Clear it to model that.
      :ets.delete_all_objects(AgentLineage.table())
      assert :error = AgentLineage.lookup(agent),
             "precondition: clearing ETS must lose the cache entry"

      # Boot-time loader re-populates ETS from the durable table.
      :ok = AgentLineage.rehydrate()

      assert {:ok, restored} = AgentLineage.lookup(agent)
      assert URI.to_string(restored) == URI.to_string(parent)
    end

    test "spawned_in_lineage? still walks the chain after rehydrate" do
      root = principal_uri("root")
      mid = agent_uri("mid")
      leaf = agent_uri("leaf")

      :ok = AgentLineage.record(mid, root)
      :ok = AgentLineage.record(leaf, mid)

      :ets.delete_all_objects(AgentLineage.table())
      :ok = AgentLineage.rehydrate()

      assert AgentLineage.spawned_in_lineage?(leaf, root)
      refute AgentLineage.spawned_in_lineage?(leaf, principal_uri("stranger"))
    end
  end

  describe "forget/1" do
    test "removes the row so a rehydrate does not bring it back" do
      agent = agent_uri("forgotten")
      parent = principal_uri("p")

      :ok = AgentLineage.record(agent, parent)
      :ok = AgentLineage.forget(agent)
      assert :error = AgentLineage.lookup(agent)

      # The durable row is gone too — a rehydrate must not resurrect it.
      :ets.delete_all_objects(AgentLineage.table())
      :ok = AgentLineage.rehydrate()
      assert :error = AgentLineage.lookup(agent)
    end
  end
end
