defmodule Ezagent.Agent.RetirementTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{AgentLineage, Invocation}
  alias Ezagent.Agent.RetirementObligations
  alias Ezagent.Domain.Agent

  setup do
    suffix = System.unique_integer([:positive])
    workspace_uri = Ezagent.URI.new!("workspace://team-alpha")
    owner_uri = Ezagent.URI.new!("entity://team-alpha/user/owner-#{suffix}")
    agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/worker-#{suffix}")
    creation_attempt_id = Ezagent.Agent.CreationInventory.new_attempt_id()

    :ok =
      Ezagent.Agent.CreationInventory.record(
        creation_attempt_id,
        agent_uri,
        owner_uri,
        workspace_uri
      )

    ctx = %{
      caller: owner_uri,
      caps: MapSet.new(),
      workspace_uri: workspace_uri,
      provenance_root: owner_uri,
      creation_attempt_id: creation_attempt_id,
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
             Agent.retire_spawned(agent_uri, %{ctx | creation_attempt_id: "unknown-attempt"})
  end

  test "rejects a target outside the claimed lineage", %{agent_uri: agent_uri, ctx: ctx} do
    other_owner = Ezagent.URI.new!("entity://team-alpha/user/other-owner")
    :ok = Ezagent.AgentLineage.record(agent_uri, ctx.provenance_root)

    assert {:error, %{termination: :not_destroyed, reason: :provenance_mismatch}} =
             Agent.retire_spawned(agent_uri, %{ctx | provenance_root: other_owner})
  end

  test "rejects a target whose current direct parent differs from creation inventory", %{
    agent_uri: agent_uri,
    owner_uri: owner_uri,
    ctx: ctx
  } do
    intermediary_uri = Ezagent.URI.new!("entity://team-alpha/agent/intermediary")
    :ok = Ezagent.AgentLineage.record(agent_uri, intermediary_uri)
    :ok = Ezagent.AgentLineage.record(intermediary_uri, owner_uri)

    assert Ezagent.AgentLineage.spawned_in_lineage?(agent_uri, owner_uri)

    assert {:error, %{termination: :not_destroyed, reason: :creation_attempt_mismatch}} =
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

  test "a completed creation attempt is idempotent", %{
    agent_uri: agent_uri,
    owner_uri: owner_uri,
    ctx: ctx
  } do
    :ok = AgentLineage.record(agent_uri, owner_uri)
    authorized_ctx = %{ctx | caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])}

    assert {:ok, %{termination: :destroyed, cleanup: :complete}} =
             Agent.retire_spawned(agent_uri, authorized_ctx)

    assert {:ok, %{termination: :destroyed, cleanup: :complete, idempotent: true}} =
             Agent.retire_spawned(agent_uri, authorized_ctx)
  end

  test "persists a recoverable obligation before terminating when cleanup fails", %{
    agent_uri: agent_uri,
    owner_uri: owner_uri,
    ctx: ctx
  } do
    config_dir = "/tmp/retirement-cleanup-failure-#{System.unique_integer([:positive])}"
    {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri})
    :ok = Ezagent.WorkspaceRegistry.bind(agent_uri, ctx.workspace_uri)
    :ok = AgentLineage.record(agent_uri, owner_uri)

    assert {:ok, _} =
             Invocation.dispatch(%Invocation{
               target: Ezagent.URI.with_action(agent_uri, :sandbox, :update_config),
               mode: :call,
               args: %{config_dir_path: config_dir, template_class: __MODULE__.RaisingCleanup},
               ctx: %{
                 caller: owner_uri,
                 caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
                 reply: {:caller_inbox, self()}
               }
             })

    authorized_ctx = %{ctx | caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])}

    assert {:partial,
            %{
              termination: :destroyed,
              cleanup: :pending,
              obligation_id: obligation_id,
              failures: [_]
            }} = Agent.retire_spawned(agent_uri, authorized_ctx)

    obligation = RetirementObligations.get!(obligation_id)
    assert obligation.status == :pending
    assert obligation.agent_uri == URI.to_string(agent_uri)
    assert obligation.pending_steps["sandbox_cleanup"]["config_dir_path"] == config_dir
  end

  defmodule RaisingCleanup do
    def destroy_config_dir(%URI{}, _config_dir) do
      raise RuntimeError, "simulated retirement cleanup failure"
    end
  end
end
