defmodule Ezagent.Agent.CreationInventoryTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.CreationInventory
  alias EzagentCore.Repo

  test "records creation facts idempotently and rejects a different target" do
    suffix = System.unique_integer([:positive])
    agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/inventory-#{suffix}")
    other_uri = Ezagent.URI.new!("entity://team-alpha/agent/other-#{suffix}")
    root_uri = Ezagent.URI.new!("entity://team-alpha/user/owner-#{suffix}")
    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
    attempt_id = CreationInventory.new_attempt_id()

    assert :ok = CreationInventory.record(attempt_id, agent_uri, root_uri, workspace_uri)
    assert :ok = CreationInventory.record(attempt_id, agent_uri, root_uri, workspace_uri)
    :ok = Ezagent.AgentLineage.record(agent_uri, root_uri)
    assert CreationInventory.member?(attempt_id, agent_uri, root_uri, workspace_uri)
    refute CreationInventory.member?(attempt_id, other_uri, root_uri, workspace_uri)
    assert {:ok, ^attempt_id} = CreationInventory.find_attempt(agent_uri, workspace_uri)

    assert agent_uri in Ezagent.Provenance.DerivationEdges.descendants(root_uri)

    different_root = Ezagent.URI.new!("entity://team-alpha/user/different-#{suffix}")

    assert {:error, :creation_fact_conflict} =
             CreationInventory.record(attempt_id, agent_uri, different_root, workspace_uri)
  end

  test "exact writes distinguish insert, replay, coordinate conflict, and absence" do
    suffix = System.unique_integer([:positive])
    agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/exact-inventory-#{suffix}")
    root_uri = Ezagent.URI.new!("entity://team-alpha/user/exact-owner-#{suffix}")
    other_root = Ezagent.URI.new!("entity://team-alpha/user/exact-other-#{suffix}")
    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
    other_workspace = Ezagent.URI.new!("workspace://team-beta")
    attempt_id = CreationInventory.new_attempt_id()

    assert {:error, :creation_attempt_not_found} =
             CreationInventory.exact(attempt_id, agent_uri, root_uri, workspace_uri)

    assert {:ok, :inserted} =
             CreationInventory.record_exact(Repo, attempt_id, agent_uri, root_uri, workspace_uri)

    assert {:ok, entry} = CreationInventory.exact(attempt_id, agent_uri, root_uri, workspace_uri)
    assert entry.creation_attempt_id == attempt_id
    assert entry.agent_uri == URI.to_string(agent_uri)
    assert entry.provenance_root_uri == URI.to_string(root_uri)
    assert entry.workspace_uri == URI.to_string(workspace_uri)

    assert {:ok, :exists} =
             CreationInventory.record_exact(Repo, attempt_id, agent_uri, root_uri, workspace_uri)

    assert {:error, :creation_fact_conflict} =
             CreationInventory.record_exact(
               Repo,
               attempt_id,
               agent_uri,
               other_root,
               workspace_uri
             )

    assert {:error, :creation_fact_conflict} =
             CreationInventory.record_exact(
               Repo,
               attempt_id,
               agent_uri,
               root_uri,
               other_workspace
             )

    assert {:error, :creation_fact_conflict} =
             CreationInventory.exact(attempt_id, agent_uri, other_root, workspace_uri)
  end

  test "inventory and lineage exact writes roll back together without publishing cache" do
    suffix = System.unique_integer([:positive])
    agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/rollback-inventory-#{suffix}")
    root_uri = Ezagent.URI.new!("entity://team-alpha/user/rollback-owner-#{suffix}")
    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
    attempt_id = CreationInventory.new_attempt_id()

    assert {:error, :forced} =
             Repo.transaction(fn ->
               assert {:ok, :inserted} =
                        CreationInventory.record_exact(
                          Repo,
                          attempt_id,
                          agent_uri,
                          root_uri,
                          workspace_uri
                        )

               assert {:ok, :inserted} =
                        Ezagent.AgentLineage.record_exact(Repo, agent_uri, root_uri)

               assert :error = Ezagent.AgentLineage.lookup(agent_uri)
               Repo.rollback(:forced)
             end)

    assert {:error, :creation_attempt_not_found} =
             CreationInventory.exact(attempt_id, agent_uri, root_uri, workspace_uri)

    assert :error = Ezagent.AgentLineage.lookup(agent_uri)
    assert nil == Repo.get(Ezagent.AgentLineage, URI.to_string(agent_uri))
  end
end
