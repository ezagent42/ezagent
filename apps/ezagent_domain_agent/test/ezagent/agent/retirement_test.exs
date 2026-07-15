defmodule Ezagent.Agent.RetirementTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Domain.Agent

  setup do
    suffix = System.unique_integer([:positive])
    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
    owner_uri = Ezagent.URI.new!("entity://team-alpha/user/owner-#{suffix}")
    agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/worker-#{suffix}")

    ctx = %{
      caller: owner_uri,
      caps: MapSet.new(),
      workspace_uri: workspace_uri,
      provenance_root: owner_uri,
      creation_attempt_id: "attempt-#{suffix}",
      created_agent_uris: [agent_uri],
      reason: :rollback
    }

    %{agent_uri: agent_uri, owner_uri: owner_uri, workspace_uri: workspace_uri, ctx: ctx}
  end

  test "rejects a non-Agent target", %{ctx: ctx} do
    session_uri = Ezagent.URI.new!("session://team-alpha/default/not-an-agent")

    assert {:error, %{termination: :not_destroyed, reason: :invalid_agent_target}} =
             Agent.retire_spawned(session_uri, ctx)
  end

  test "rejects a workspace mismatch", %{agent_uri: agent_uri, ctx: ctx} do
    wrong_workspace = Ezagent.URI.new!("workspace://other")

    assert {:error, %{termination: :not_destroyed, reason: :workspace_mismatch}} =
             Agent.retire_spawned(agent_uri, %{ctx | workspace_uri: wrong_workspace})
  end

  test "rejects a target outside the creation attempt inventory", %{
    agent_uri: agent_uri,
    owner_uri: owner_uri,
    ctx: ctx
  } do
    :ok = Ezagent.AgentLineage.record(agent_uri, owner_uri)

    assert {:error, %{termination: :not_destroyed, reason: :creation_attempt_mismatch}} =
             Agent.retire_spawned(agent_uri, %{ctx | created_agent_uris: []})
  end

  test "rejects a target outside the claimed lineage", %{agent_uri: agent_uri, ctx: ctx} do
    other_owner = Ezagent.URI.new!("entity://team-alpha/user/other-owner")
    :ok = Ezagent.AgentLineage.record(agent_uri, other_owner)

    assert {:error, %{termination: :not_destroyed, reason: :provenance_mismatch}} =
             Agent.retire_spawned(agent_uri, ctx)
  end

  test "lineage alone does not authorize retirement", %{
    agent_uri: agent_uri,
    owner_uri: owner_uri,
    ctx: ctx
  } do
    :ok = Ezagent.AgentLineage.record(agent_uri, owner_uri)
    {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri})

    assert {:error, %{termination: :not_destroyed, reason: :unauthorized}} =
             Agent.retire_spawned(agent_uri, ctx)

    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(agent_uri)
  end
end
