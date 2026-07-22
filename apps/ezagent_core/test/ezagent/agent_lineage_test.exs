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
  alias EzagentCore.Repo

  defp agent_uri(name),
    do:
      Ezagent.URI.new!("entity://team-alpha/agent/#{name}-#{System.unique_integer([:positive])}")

  defp principal_uri(name),
    do: Ezagent.URI.new!("entity://team-alpha/user/#{name}-#{System.unique_integer([:positive])}")

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

  describe "record_exact/3" do
    test "inserts and replays exact lineage without publishing the cache" do
      agent = agent_uri("exact")
      parent = principal_uri("owner")

      assert {:ok, :inserted} = AgentLineage.record_exact(Repo, agent, parent)
      assert :error = AgentLineage.lookup(agent)
      assert {:ok, :exists} = AgentLineage.record_exact(Repo, agent, parent)

      assert :ok = AgentLineage.publish_cache(agent, parent)
      assert {:ok, ^parent} = AgentLineage.lookup(agent)
    end

    test "rejects a conflicting parent and never reparents the Agent" do
      agent = agent_uri("conflict")
      original_parent = principal_uri("original")
      conflicting_parent = principal_uri("conflicting")

      assert {:ok, :inserted} = AgentLineage.record_exact(Repo, agent, original_parent)

      assert {:error, :lineage_conflict} =
               AgentLineage.record_exact(Repo, agent, conflicting_parent)

      assert %AgentLineage{spawned_by: stored_parent} =
               Repo.get(AgentLineage, URI.to_string(agent))

      assert stored_parent == URI.to_string(original_parent)
      assert :ok = AgentLineage.publish_cache(agent, original_parent)
      assert {:ok, ^original_parent} = AgentLineage.lookup(agent)
    end
  end
end
