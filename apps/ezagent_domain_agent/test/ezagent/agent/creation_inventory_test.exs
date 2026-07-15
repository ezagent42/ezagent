defmodule Ezagent.Agent.CreationInventoryTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.CreationInventory

  test "records creation facts idempotently and rejects a different target" do
    suffix = System.unique_integer([:positive])
    agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/inventory-#{suffix}")
    other_uri = Ezagent.URI.new!("entity://team-alpha/agent/other-#{suffix}")
    root_uri = Ezagent.URI.new!("entity://team-alpha/user/owner-#{suffix}")
    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
    attempt_id = CreationInventory.attempt_id(agent_uri)

    assert :ok = CreationInventory.record(attempt_id, agent_uri, root_uri, workspace_uri)
    assert :ok = CreationInventory.record(attempt_id, agent_uri, root_uri, workspace_uri)
    assert CreationInventory.member?(attempt_id, agent_uri, root_uri, workspace_uri)
    refute CreationInventory.member?(attempt_id, other_uri, root_uri, workspace_uri)
  end
end
