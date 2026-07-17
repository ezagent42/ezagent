defmodule Ezagent.Workspace.TaskWorkspace.SidecarGateTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Kind.Template.PreStart, as: CorePreStart
  alias Ezagent.Workspace.TaskWorkspace.AgentStart.Ref
  alias Ezagent.Workspace.TaskWorkspace.{AgentStart, PreStart, Store}

  setup do
    :ok = CorePreStart.replace_for_test(PreStart)

    Application.put_env(
      :ezagent_domain_workspace,
      :task_workspace_git_runner,
      EzagentDomainWorkspace.TestSupport.TaskWorkspaceProofRunner
    )

    Application.put_env(:ezagent_domain_workspace, :sidecar_gate_test_owner, self())

    Application.put_env(
      :ezagent_domain_workspace,
      :sidecar_gate_test_provenance,
      Ezagent.URI.user("sidecar-gate", "owner")
    )

    flavor = "task-workspace-#{System.unique_integer([:positive])}"

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: EzagentDomainWorkspace.TestSupport.TaskWorkspaceTemplateClass
      })

    on_exit(fn ->
      CorePreStart.replace_for_test(nil)
      Application.delete_env(:ezagent_domain_workspace, :task_workspace_git_runner)
      Application.delete_env(:ezagent_domain_workspace, :sidecar_gate_test_owner)
      Application.delete_env(:ezagent_domain_workspace, :sidecar_gate_test_provenance)
      Application.delete_env(:ezagent_domain_workspace, :sidecar_gate_proof_row_id)
    end)

    %{flavor: flavor}
  end

  test "opaque start reference has only the governed identity fields" do
    ref = start_ref("provision-1", 3)

    assert Map.from_struct(ref) == %{
             provision_id: "provision-1",
             task_access_uri: task_access_uri(),
             task_uri: task_uri(),
             generation: 3
           }
  end

  test "ready generation injects its recorded canonical cwd" do
    ready = ready_row()

    ref = start_ref(ready.provision_id, ready.generation)

    assert {:ok, %{cwd: cwd, claim: claim}} = CorePreStart.prepare(ref)
    assert cwd == ready.worktree_path
    assert is_reference(claim)
  end

  test "retirement intent is durable before prepare and survives an abandoned completion" do
    agent_uri = Ezagent.URI.agent("sidecar-gate", "crash-window")
    ready = ready_row(agent_uri)
    ref = start_ref(ready.provision_id, ready.generation)

    assert ready.agent_uri == URI.to_string(agent_uri)
    assert ready.provenance_root_uri == "entity://sidecar-gate/user/owner"
    assert {:ok, %{claim: _claim}} = CorePreStart.prepare(ref)

    abandoned = Store.get(ready.id)
    assert abandoned.start_token_consumed_at
    assert abandoned.agent_uri == URI.to_string(agent_uri)
    assert abandoned.provenance_root_uri == "entity://sidecar-gate/user/owner"
  end

  test "mismatched start coordinates cannot poison a ready row" do
    {:ok, planned} = Store.create_planned(attrs())
    {:ok, claimed} = Store.claim_provision(planned.id, lease_seconds: 135)

    {:ok, ready} =
      Store.mark_ready(planned.id, claimed.claim_token, %{
        expected_version: claimed.state_version,
        cache_identity: "cache-proof",
        worktree_identity: "worktree-proof",
        worktree_path: canonical_cwd(),
        resolved_base_commit: String.duplicate("a", 40),
        local_branch_ref: "refs/heads/ezagent/task/proof/g3"
      })

    valid = %{
      agent_uri: "entity://sidecar-gate/agent/worker",
      provenance_root_uri: "entity://sidecar-gate/user/owner",
      workspace_uri: URI.to_string(workspace_uri()),
      task_access_uri: URI.to_string(task_access_uri()),
      task_uri: URI.to_string(task_uri()),
      generation: ready.generation
    }

    mismatches = [
      %{
        valid
        | task_uri: URI.to_string(Ezagent.URI.resource("sidecar-gate", "kanban-task", "wrong"))
      },
      %{valid | generation: ready.generation + 1},
      %{valid | workspace_uri: URI.to_string(Ezagent.URI.workspace("other"))},
      %{valid | agent_uri: "entity://other/agent/worker"}
    ]

    for mismatch <- mismatches do
      assert {:error, _reason} = Store.bind_start_intent(ready.provision_id, mismatch)
      unchanged = Store.get(ready.id)
      assert unchanged.agent_uri == nil
      assert unchanged.provenance_root_uri == nil
      assert unchanged.state_version == ready.state_version
    end
  end

  test "twenty concurrent starts consume one ready generation" do
    ready = ready_row()

    ref = start_ref(ready.provision_id, ready.generation)

    results =
      1..20
      |> Task.async_stream(fn _ -> CorePreStart.prepare(ref) end,
        max_concurrency: 20,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(results, &match?({:error, :sidecar_start_already_consumed}, &1)) ==
             19
  end

  test "AgentStart threads only the trusted ref and instantiates with authoritative cwd", %{
    flavor: flavor
  } do
    unique = System.unique_integer([:positive])
    agent_uri = Ezagent.URI.agent("sidecar-gate", "worker-#{unique}")
    ready = ready_row(agent_uri)

    assert {:ok, %{fresh?: false}} =
             AgentStart.start(
               %{flavor: flavor, project_cwd: "/untrusted/authored"},
               agent_uri,
               Ezagent.URI.user("sidecar-gate", "owner"),
               workspace_uri(),
               %{
                 provision_id: ready.provision_id,
                 task_access_uri: task_access_uri(),
                 task_uri: task_uri(),
                 generation: ready.generation
               }
             )

    assert_receive {:instantiate_called, data}
    assert data["cwd"] == canonical_cwd()
    refute Map.has_key?(data, "pre_start_ref")
    started = Store.get(ready.id)
    assert started.status == :sidecar_started
    assert started.agent_uri == "entity://sidecar-gate/agent/worker-#{unique}"
    assert is_binary(started.creation_attempt_id)
    assert started.provenance_root_uri == "entity://sidecar-gate/user/owner"
  end

  test "failed filesystem proof requests cleanup before instantiate" do
    ready = ready_row()

    Application.put_env(
      :ezagent_domain_workspace,
      :task_workspace_git_runner,
      EzagentDomainWorkspace.TestSupport.FailingTaskWorkspaceProofRunner
    )

    ref = start_ref(ready.provision_id, ready.generation)

    assert {:error, :workspace_checkout_mismatch} = CorePreStart.prepare(ref)
    assert Store.get(ready.id).status == :cleanup_pending
  end

  test "the start claim is durable and its persisted proof is complete before verification" do
    ready = ready_row()
    ref = start_ref(ready.provision_id, ready.generation)
    Application.put_env(:ezagent_domain_workspace, :sidecar_gate_proof_row_id, ready.id)

    assert {:ok, %{claim: {id, token}}} = PreStart.prepare(ref)
    assert_receive {:proof_called, proof, :starting, ^token}
    assert id == ready.id

    assert proof == %{
             cache_path: Path.join(Path.dirname(ready.worktree_path), ready.cache_identity),
             worktree_path: ready.worktree_path,
             remote_url: ready.remote_url,
             resolved_base_commit: ready.resolved_base_commit,
             local_branch_ref: ready.local_branch_ref
           }
  end

  test "instantiate error requests cleanup and consumed token cannot retry" do
    ready = ready_row()

    ref = start_ref(ready.provision_id, ready.generation)

    assert {:ok, %{claim: claim}} = CorePreStart.prepare(ref)

    assert :ok = CorePreStart.complete(claim, {:error, :instantiate_failed})
    assert Store.get(ready.id).status == :cleanup_pending
    assert {:error, :sidecar_start_already_consumed} = CorePreStart.prepare(ref)
  end

  test "successful-looking instantiate without durable provenance requests cleanup" do
    ready = ready_row()

    ref = start_ref(ready.provision_id, ready.generation)

    assert {:ok, %{claim: claim}} = CorePreStart.prepare(ref)
    unknown_agent = Ezagent.URI.agent("sidecar-gate", "unknown")

    assert :ok = CorePreStart.complete(claim, {:ok, %{workers: [unknown_agent]}})
    assert Store.get(ready.id).status == :cleanup_pending
  end

  defp ready_row(agent_uri \\ Ezagent.URI.agent("sidecar-gate", "reserved-worker")) do
    {:ok, planned} = Store.create_planned(attrs())
    {:ok, claimed} = Store.claim_provision(planned.id, lease_seconds: 135)

    {:ok, ready} =
      Store.mark_ready(planned.id, claimed.claim_token, %{
        expected_version: claimed.state_version,
        cache_identity: "cache-proof",
        worktree_identity: "worktree-proof",
        worktree_path: canonical_cwd(),
        resolved_base_commit: String.duplicate("a", 40),
        local_branch_ref: "refs/heads/ezagent/task/proof/g3",
        remote_url: "https://git.example.test/acme/widgets.git"
      })

    {:ok, bound} =
      Store.bind_start_intent(ready.provision_id, %{
        agent_uri: URI.to_string(agent_uri),
        provenance_root_uri: URI.to_string(Ezagent.URI.user("sidecar-gate", "owner")),
        workspace_uri: URI.to_string(workspace_uri()),
        task_access_uri: URI.to_string(task_access_uri()),
        task_uri: URI.to_string(task_uri()),
        generation: ready.generation
      })

    bound
  end

  defp attrs do
    %{
      provision_id: "provision-#{System.unique_integer([:positive])}",
      workspace_uri: URI.to_string(workspace_uri()),
      task_uri: URI.to_string(task_uri()),
      generation: 3,
      task_access_uri: URI.to_string(task_access_uri()),
      repository_uri:
        URI.to_string(Ezagent.URI.resource("sidecar-gate", "git-repository", "repo")),
      checkout_fingerprint: "checkout-proof",
      base_ref: "main",
      allowed_head_ref: "task/head",
      visibility: :public
    }
  end

  defp canonical_cwd, do: "/tmp/task-workspace-proof"

  defp start_ref(provision_id, generation) do
    %Ref{
      provision_id: provision_id,
      task_access_uri: task_access_uri(),
      task_uri: task_uri(),
      generation: generation
    }
  end

  defp workspace_uri, do: Ezagent.URI.workspace("sidecar-gate")
  defp task_uri, do: Ezagent.URI.resource("sidecar-gate", "kanban-task", "task-1")

  defp task_access_uri,
    do: Ezagent.URI.resource("sidecar-gate", "git-task-access", "task-1")
end
