defmodule Ezagent.ActionSet.CcHeadlessAgentDataOwnerTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.CcHeadlessAgent
  alias Ezagent.CapabilityRegistry

  test "delegates concrete agent ownership to the canonical ApiKeys resolver" do
    suffix = System.unique_integer([:positive])
    agent = Ezagent.URI.new!("entity://acme/agent/cc-owner-test-#{suffix}")
    owner = Ezagent.URI.new!("entity://acme/user/owner-#{suffix}")

    :ok = Ezagent.AgentLineage.record(agent, owner)

    assert CapabilityRegistry.data_owner_of(CcHeadlessAgent, agent) == owner
  end
end
