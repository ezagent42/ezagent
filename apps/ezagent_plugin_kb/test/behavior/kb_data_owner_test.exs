defmodule Ezagent.ActionSet.KbDataOwnerTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, CapabilityRegistry}
  alias Ezagent.ActionSet.Kb

  test "delegates concrete KB ownership to the canonical ApiKeys resolver" do
    suffix = System.unique_integer([:positive])
    kb = Ezagent.URI.new!("entity://acme/agent/kb-#{suffix}")
    owner = Ezagent.URI.new!("entity://acme/user/owner-#{suffix}")

    :ok = Ezagent.AgentLineage.record(kb, owner)

    assert CapabilityRegistry.data_owner_of(Kb, kb) == owner
  end

  test "allows a non-admin owner to authorize a concrete KB query cap" do
    suffix = System.unique_integer([:positive])
    kb = Ezagent.URI.new!("entity://acme/agent/kb-authorize-#{suffix}")
    owner = Ezagent.URI.new!("entity://acme/user/owner-#{suffix}")
    workspace = Ezagent.URI.new!("workspace://acme")

    :ok = Ezagent.AgentLineage.record(kb, owner)

    cap = Capability.cap(:agent, Kb, :query, kb, workspace)

    assert :ok = CapabilityRegistry.authorize_grant(MapSet.new(), cap, %{caller: owner})
  end
end
