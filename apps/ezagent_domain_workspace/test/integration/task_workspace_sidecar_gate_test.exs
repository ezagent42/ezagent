defmodule Ezagent.Workspace.TaskWorkspace.SidecarGateTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Kind.Template.PreStart, as: CorePreStart
  alias Ezagent.Workspace.TaskWorkspace.AgentStart.Ref
  alias Ezagent.Workspace.TaskWorkspace.{AgentStart, Paths, PreStart, Reconciler, Store}
  alias EzagentCore.Repo

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
      Application.delete_env(:ezagent_domain_workspace, :sidecar_gate_fresh?)
      Application.delete_env(:ezagent_domain_workspace, :sidecar_gate_proof_row_id)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_owner)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_verify_result)
      Application.delete_env(:ezagent_domain_workspace, :task_workspace_retirement)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_verify_absent_result)
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
    assert is_binary(ready.creation_attempt_id)
    assert {:ok, %{claim: _claim}} = CorePreStart.prepare(ref)

    abandoned = Store.get(ready.id)
    assert abandoned.start_token_consumed_at
    assert abandoned.agent_uri == URI.to_string(agent_uri)
    assert abandoned.provenance_root_uri == "entity://sidecar-gate/user/owner"
    assert abandoned.creation_attempt_id == ready.creation_attempt_id
  end

  test "caller death after real prepare leaves starting for fenced recovery" do
    ready = recovery_ready_row(Ezagent.URI.agent("sidecar-gate", "dead-caller"))
    ref = start_ref(ready.provision_id, ready.generation)
    parent = self()

    Application.put_env(
      :ezagent_domain_workspace,
      :task_workspace_git_runner,
      EzagentDomainWorkspace.TestSupport.FakeTaskWorkspaceGitRunner
    )

    Application.put_env(:ezagent_domain_workspace, :provisioner_test_owner, self())

    caller =
      spawn(fn ->
        send(parent, {:caller_ready, self()})

        receive do
          :prepare -> :ok
        end

        result = CorePreStart.prepare(ref)
        send(parent, {:prepared_before_death, self(), result})
        Process.sleep(:infinity)
      end)

    assert_receive {:caller_ready, ^caller}
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), caller)
    send(caller, :prepare)
    assert_receive {:prepared_before_death, ^caller, {:ok, %{claim: _claim}}}
    Process.exit(caller, :kill)
    refute Process.alive?(caller)

    starting = Store.get(ready.id)
    assert starting.status == :starting

    Application.put_env(
      :ezagent_domain_workspace,
      :task_workspace_retirement,
      EzagentDomainWorkspace.TestSupport.FakeTaskWorkspaceRetirement
    )

    Application.put_env(:ezagent_domain_workspace, :provisioner_test_verify_absent_result, :ok)
    now = DateTime.add(starting.start_lease_until, 1, :second)

    assert %{cleaned: 1, failed: 0} = Reconciler.recover_once(limit: 1, now: now)
    refute_receive {:retire_agent, _, _}
    assert Store.get(ready.id).status == :cleaned
    refute_receive {:instantiate_called, _}
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
        local_branch_ref: Ezagent.Workspace.TaskWorkspace.GitRunner.local_branch_ref(claimed)
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

    assert {:ok, %{fresh?: true}} =
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
    assert_receive {:launch_context_received, launch_context}
    assert is_reference(launch_context)
    assert data["cwd"] == canonical_cwd()
    refute Map.has_key?(data, "pre_start_ref")
    started = Store.get(ready.id)
    assert started.status == :sidecar_started
    assert started.agent_uri == "entity://sidecar-gate/agent/worker-#{unique}"
    assert is_binary(started.creation_attempt_id)

    assert {:ok, started.creation_attempt_id} ==
             Ezagent.Agent.CreationInventory.find_attempt(agent_uri, workspace_uri())

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

  test "checkout availability failure releases the start claim for a safe retry" do
    ready = ready_row()

    Application.put_env(
      :ezagent_domain_workspace,
      :task_workspace_git_runner,
      EzagentDomainWorkspace.TestSupport.FakeTaskWorkspaceGitRunner
    )

    Application.put_env(:ezagent_domain_workspace, :provisioner_test_owner, self())

    Application.put_env(
      :ezagent_domain_workspace,
      :provisioner_test_verify_result,
      {:error, :checkout_unavailable}
    )

    assert {:error, :checkout_unavailable} =
             CorePreStart.prepare(start_ref(ready.provision_id, ready.generation))

    retryable = Store.get(ready.id)
    assert retryable.status == :ready
    assert retryable.start_token_consumed_at == nil
    refute_receive {:instantiate_called, _}
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

    assert :ok =
             CorePreStart.complete(claim, {:ok, %{workers: [unknown_agent], fresh?: true}})

    assert Store.get(ready.id).status == :cleanup_pending
  end

  test "completion uses the prebound attempt even when a later inventory fact exists" do
    agent_uri = Ezagent.URI.agent("sidecar-gate", "exact-attempt")
    ready = ready_row(agent_uri)
    ref = start_ref(ready.provision_id, ready.generation)
    assert {:ok, %{claim: claim}} = CorePreStart.prepare(ref)
    :ok = Ezagent.AgentLineage.record(agent_uri, Ezagent.URI.user("sidecar-gate", "owner"))

    later = Ezagent.Agent.CreationInventory.new_attempt_id()

    :ok =
      Ezagent.Agent.CreationInventory.record(
        later,
        agent_uri,
        Ezagent.URI.user("sidecar-gate", "owner"),
        workspace_uri()
      )

    assert :ok = CorePreStart.complete(claim, {:ok, %{workers: [agent_uri], fresh?: true}})
    assert Store.get(ready.id).creation_attempt_id == ready.creation_attempt_id
    refute Store.get(ready.id).creation_attempt_id == later
  end

  test "adopted worker is rejected without transferring retirement ownership" do
    ready = ready_row()
    ref = start_ref(ready.provision_id, ready.generation)
    assert {:ok, %{claim: claim}} = CorePreStart.prepare(ref)
    agent_uri = Ezagent.URI.new!(ready.agent_uri)

    assert {:error, :sidecar_start_not_fresh} =
             CorePreStart.complete(claim, {:ok, %{workers: [agent_uri], fresh?: false}})

    current = Store.get(ready.id)
    assert current.status == :ready
    assert current.start_token_consumed_at == nil
    refute_receive {:retire_agent, _, _}
  end

  test "AgentStart rejects an adopted TemplateSpawn worker and cleanup never retires it", %{
    flavor: flavor
  } do
    agent_uri = Ezagent.URI.agent("sidecar-gate", "adopted-through-template")
    ready = ready_row(agent_uri)
    original_root = Ezagent.URI.user("sidecar-gate", "original-owner")
    original_workspace = workspace_uri()
    assert {:ok, _pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri})
    :ok = Ezagent.AgentLineage.record(agent_uri, original_root)
    :ok = Ezagent.WorkspaceRegistry.bind(agent_uri, original_workspace)
    :ok = Ezagent.AgentFlavorAttributes.put(agent_uri, "original-flavor")
    assert {:ok, original_sandbox} = Ezagent.Kind.get_slice(agent_uri, :sandbox)

    assert {:error, :sidecar_start_not_fresh} =
             AgentStart.start(
               %{flavor: flavor, project_cwd: "/untrusted"},
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

    assert Store.get(ready.id).status == :ready
    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(agent_uri)
    assert {:ok, ^original_root} = Ezagent.AgentLineage.lookup(agent_uri)
    assert {:ok, ^original_workspace} = Ezagent.WorkspaceRegistry.lookup(agent_uri)
    assert {:ok, "original-flavor"} = Ezagent.AgentFlavorAttributes.get(agent_uri)
    assert {:ok, ^original_sandbox} = Ezagent.Kind.get_slice(agent_uri, :sandbox)

    assert {:error, :creation_attempt_not_found} =
             Ezagent.Agent.CreationInventory.find_attempt(agent_uri, workspace_uri())

    refute_receive {:retire_agent, _, _}
  end

  test "late claimant completion cannot mutate a takeover claim" do
    agent_uri =
      Ezagent.URI.agent("sidecar-gate", "takeover-#{System.unique_integer([:positive])}")

    ready = ready_row(agent_uri)

    assert {:ok, first} =
             Store.claim_start(ready.id, ready.start_token,
               now: at(0),
               lease_seconds: 30
             )

    assert {:ok, second} =
             Store.claim_start(ready.id, ready.start_token,
               now: at(30),
               lease_seconds: 60
             )

    outcomes = [
      {:error, :instantiate_failed},
      {:ok,
       %{
         workers: [Ezagent.URI.agent("sidecar-gate", "wrong-worker")],
         fresh?: true
       }}
    ]

    for outcome <- outcomes do
      before = Store.get(ready.id)

      assert {:error, :sidecar_start_claim_lost} =
               PreStart.complete({first.id, first.start_claim_token}, outcome)

      after_completion = Store.get(ready.id)
      assert after_completion.status == before.status
      assert after_completion.start_claim_token == second.start_claim_token
      assert after_completion.start_claim_token == before.start_claim_token
      assert after_completion.start_lease_until == before.start_lease_until
      assert after_completion.state_version == before.state_version
      refute_receive {:retire_agent, _, _}
      refute_receive {:git_remove, _, _}
      refute_receive {:git_verify_absent, _, _}
    end
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
        local_branch_ref: Ezagent.Workspace.TaskWorkspace.GitRunner.local_branch_ref(claimed),
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

  defp recovery_ready_row(agent_uri) do
    stored = attrs()
    {:ok, planned} = Store.create_planned(stored)
    {:ok, claimed} = Store.claim_provision(planned.id, lease_seconds: 135)

    {:ok, paths} =
      Paths.derive(%{
        provision_id: planned.provision_id,
        workspace_uri: Ezagent.URI.new!(planned.workspace_uri),
        task_uri: Ezagent.URI.new!(planned.task_uri),
        generation: planned.generation,
        task_access_uri: Ezagent.URI.new!(planned.task_access_uri),
        repository_uri: Ezagent.URI.new!(planned.repository_uri),
        checkout_fingerprint: planned.checkout_fingerprint,
        base_ref: planned.base_ref,
        allowed_head_ref: planned.allowed_head_ref
      })

    {:ok, ready} =
      Store.mark_ready(planned.id, claimed.claim_token, %{
        expected_version: claimed.state_version,
        cache_identity: paths.cache_identity,
        worktree_identity: paths.worktree_identity,
        worktree_path: paths.worktree_path,
        resolved_base_commit: String.duplicate("a", 40),
        local_branch_ref: Ezagent.Workspace.TaskWorkspace.GitRunner.local_branch_ref(claimed),
        remote_url: "https://git.example.test/acme/widgets.git"
      })

    {:ok, bound} =
      Store.bind_start_intent(ready.provision_id, %{
        agent_uri: URI.to_string(agent_uri),
        provenance_root_uri: URI.to_string(Ezagent.URI.user("sidecar-gate", "owner")),
        workspace_uri: ready.workspace_uri,
        task_access_uri: ready.task_access_uri,
        task_uri: ready.task_uri,
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
  defp at(seconds), do: DateTime.add(~U[2026-07-17 00:00:00.000000Z], seconds, :second)

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
