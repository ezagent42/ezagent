defmodule Ezagent.Agent.CreationInventoryTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.CreationInventory

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

    different_root = Ezagent.URI.new!("entity://team-alpha/user/different-#{suffix}")

    assert {:error, :creation_fact_conflict} =
             CreationInventory.record(attempt_id, agent_uri, different_root, workspace_uri)
  end
end
