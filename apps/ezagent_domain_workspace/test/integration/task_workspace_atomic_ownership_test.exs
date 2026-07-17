defmodule Ezagent.Workspace.TaskWorkspace.AtomicOwnershipTest do
  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.Kind.Template.PreStart, as: CorePreStart
  alias Ezagent.Workspace.TaskWorkspace.{AgentStart, Paths, Provision, Reconciler, Store}
  alias EzagentCore.Repo

  setup do
    :ok = CorePreStart.replace_for_test(Ezagent.Workspace.TaskWorkspace.PreStart)
    owner = self()

    Application.put_env(:ezagent_domain_workspace, :sidecar_gate_test_owner, owner)
    Application.put_env(:ezagent_domain_workspace, :provisioner_test_owner, owner)

    Application.put_env(
      :ezagent_domain_workspace,
      :task_workspace_git_runner,
      EzagentDomainWorkspace.TestSupport.FakeTaskWorkspaceGitRunner
    )

    Application.put_env(
      :ezagent_domain_workspace,
      :task_workspace_retirement,
      EzagentDomainWorkspace.TestSupport.FakeTaskWorkspaceRetirement
    )

    Application.put_env(:ezagent_domain_workspace, :provisioner_test_verify_absent_result, :ok)

    flavor = "atomic-#{System.unique_integer([:positive])}"

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: EzagentDomainWorkspace.TestSupport.TaskWorkspaceTemplateClass
      })

    on_exit(fn ->
      CorePreStart.replace_for_test(nil)
      Ezagent.Agent.TestTemplateSpawn.clear()

      for key <- [
            :sidecar_gate_test_owner,
            :provisioner_test_owner,
            :task_workspace_git_runner,
            :task_workspace_retirement,
            :provisioner_test_verify_absent_result
          ],
          do: Application.delete_env(:ezagent_domain_workspace, key)
    end)

    %{flavor: flavor}
  end

  test "1 receipt commits inside real Kind.spawn before child init returns and caller dies", %{
    flavor: flavor
  } do
    row = ready_row("winner-before-return")
    agent = uri(row.agent_uri)
    Ezagent.Agent.TestLaunchPostCommitPublisher.inject(agent, :barrier_after_commit, self())
    on_exit(fn -> Ezagent.Agent.TestLaunchPostCommitPublisher.clear(agent) end)

    caller = start_caller(row, flavor)
    assert_receive {:launch_receipt_committed, facts, init_pid}
    assert facts.attempt_id == Store.get(row.id).creation_attempt_id
    Process.exit(caller, :kill)
    send(init_pid, :release_after_commit)
    recover_owned(Store.get(row.id))
  end

  test "2 real instantiate return before TemplateSpawn completion survives caller crash", %{
    flavor: flavor
  } do
    row = ready_row("return-before-completion")
    Ezagent.Agent.TestTemplateSpawn.inject(:barrier_before_complete, self())
    caller = start_caller(row, flavor)

    assert_receive {:template_spawn_before_complete, _completion, {:ok, %{fresh?: true}},
                    hook_pid}

    Process.exit(caller, :kill)
    refute Process.alive?(caller)
    refute Process.alive?(hook_pid)
    recover_owned(Store.get(row.id))
  end

  test "3 real adopted same-lineage path has no losing receipt and recovery only cleans Git", %{
    flavor: flavor
  } do
    row = ready_row("adopted")
    agent = uri(row.agent_uri)
    root = uri(row.provenance_root_uri)
    assert {:ok, _} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent})
    :ok = Ezagent.AgentLineage.record(agent, root)
    :ok = Ezagent.WorkspaceRegistry.bind(agent, workspace())

    assert {:error, :sidecar_start_not_fresh} = start(row, flavor)
    assert {:error, :creation_attempt_not_found} = receipt(row)
    pending = force_pending(Store.get(row.id), :adopted_caller_crash)
    recover_unowned(pending)
  end

  test "4 concurrent production starts yield one SQL receipt and loser owns nothing", %{
    flavor: flavor
  } do
    first = ready_row("race-a", agent_uri: "entity://atomic-team/agent/raced")
    second = ready_row("race-b", agent_uri: first.agent_uri)
    tasks = Enum.map([first, second], &Task.async(fn -> start(&1, flavor) end))
    Enum.each(tasks, &Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), &1.pid))
    results = Enum.map(tasks, &Task.await(&1, 5_000))
    assert Enum.count(results, &match?({:ok, %{fresh?: true}}, &1)) == 1

    assert Repo.aggregate(
             from(e in Ezagent.Agent.CreationInventoryEntry,
               where: e.agent_uri == ^first.agent_uri
             ),
             :count
           ) == 1

    loser =
      Enum.find([first, second], fn row -> match?({:error, _}, receipt(Store.get(row.id))) end)

    recover_unowned(force_pending(Store.get(loser.id), :losing_attempt))
  end

  test "5 exact-write failures through real Agent init leak no actor or facts", %{flavor: flavor} do
    for failed <- [:inventory, :lineage] do
      row = ready_row("write-#{failed}")
      attempt = row.creation_attempt_id
      Ezagent.Agent.TestLaunchPersistence.inject(attempt, {:fail, failed}, self())
      on_exit(fn -> Ezagent.Agent.TestLaunchPersistence.clear(attempt) end)
      assert {:error, _} = start(row, flavor)
      assert_receive {:persistence_failed, ^attempt, ^failed}
      assert :error = Ezagent.KindRegistry.lookup(uri(row.agent_uri))
      assert {:error, :creation_attempt_not_found} = receipt(row)
      recover_unowned(Store.get(row.id))
    end
  end

  test "6 postcommit cache failure is recovered from SQL receipt after cache reset", %{
    flavor: flavor
  } do
    row = ready_row("cache-rehydrate")
    agent = uri(row.agent_uri)
    Ezagent.Agent.TestTemplateSpawn.inject(:barrier_before_complete, self())
    Ezagent.Agent.TestLaunchPostCommitPublisher.inject(agent, :raise_lineage_cache, self())
    on_exit(fn -> Ezagent.Agent.TestLaunchPostCommitPublisher.clear(agent) end)
    caller = start_caller(row, flavor)
    assert_receive {:lineage_cache_failed, ^agent}
    assert_receive {:template_spawn_before_complete, _, {:ok, %{fresh?: true}}, _}
    Process.exit(caller, :kill)
    :ets.delete(Ezagent.AgentLineage.table(), URI.to_string(agent))
    :ets.delete(Ezagent.WorkspaceRegistry.table(), URI.to_string(agent))
    assert :error = Ezagent.AgentLineage.lookup(agent)
    :ok = Ezagent.AgentLineage.rehydrate()
    assert {:ok, _} = Ezagent.AgentLineage.lookup(agent)
    recover_owned(Store.get(row.id))
  end

  test "7 real TemplateSpawn sidecar failure after receipt recovers exact retirement", %{
    flavor: flavor
  } do
    row = ready_row("sidecar-failure")
    Ezagent.Agent.TestTemplateSpawn.inject(:barrier_before_complete, self())
    caller = start_caller(row, flavor)
    assert_receive {:template_spawn_before_complete, _, {:ok, %{fresh?: true}}, _}
    Process.exit(caller, :kill)
    recover_owned(Store.get(row.id))
  end

  test "8 durable SQL receipt survives cache-process state recycling", %{flavor: flavor} do
    row = ready_row("restart")
    Ezagent.Agent.TestTemplateSpawn.inject(:barrier_before_complete, self())
    caller = start_caller(row, flavor)
    assert_receive {:template_spawn_before_complete, _, {:ok, %{fresh?: true}}, _}
    Process.exit(caller, :kill)
    :ets.delete(Ezagent.AgentLineage.table(), row.agent_uri)
    :ets.delete(Ezagent.WorkspaceRegistry.table(), row.agent_uri)
    :ok = Ezagent.AgentLineage.rehydrate()
    assert {:ok, _} = receipt(Repo.get!(Provision, row.id))
    recover_owned(Repo.get!(Provision, row.id))
  end

  test "9 coordinator replay is exact and reconciler blocks durable coordinate conflict", %{
    flavor: flavor
  } do
    row = ready_row("replay")
    assert {:ok, %{fresh?: true}} = start(row, flavor)
    exact = Store.get(row.id)
    assert {:ok, _} = receipt(exact)
    assert {:ok, _} = receipt(exact)
    conflict = Repo.get!(Provision, row.id)

    Repo.update_all(from(p in Provision, where: p.id == ^row.id),
      set: [provenance_root_uri: "entity://atomic-team/user/conflict", status: :cleanup_pending]
    )

    assert %{failed: 1} = Reconciler.recover_once(limit: 1)
    blocked = Store.get(conflict.id)
    assert blocked.blocker_code == "creation_receipt_conflict"
    refute_receive {:retire_agent, _, _}
  end

  test "10 expired production starting without receipt cleans Git and never retires" do
    row = ready_row("expired", lease_seconds: 1) |> claim_only()
    recover_unowned(row, DateTime.add(row.start_lease_until, 1, :second))
  end

  defp start_caller(row, flavor) do
    parent = self()
    spawn(fn -> send(parent, {:start_result, self(), start(row, flavor)}) end)
  end

  defp start(row, flavor) do
    AgentStart.start(
      %{flavor: flavor, agent_uri: row.agent_uri, project_cwd: row.worktree_path},
      uri(row.agent_uri),
      uri(row.provenance_root_uri),
      workspace(),
      identity(row)
    )
  end

  defp recover_owned(row) do
    now = DateTime.add(row.start_lease_until || DateTime.utc_now(), 1, :second)
    assert %{cleaned: 1, failed: 0} = Reconciler.recover_once(limit: 1, now: now)
    assert_receive {:retire_agent, agent_uri, attempt_id}
    assert agent_uri == row.agent_uri
    assert attempt_id == row.creation_attempt_id
    assert_receive {:retirement_facts, facts}
    assert facts.attempt_id == row.creation_attempt_id
    assert facts.agent_uri == uri(row.agent_uri)
    assert facts.root_uri == uri(row.provenance_root_uri)
    assert facts.workspace_uri == uri(row.workspace_uri)
  end

  defp recover_unowned(row, now \\ DateTime.add(DateTime.utc_now(), 120, :second)) do
    assert %{cleaned: 1, failed: 0} = Reconciler.recover_once(limit: 1, now: now)
    refute_receive {:retire_agent, _, _}
    assert_receive {:git_verify_absent, %{worktree_path: path}}
    assert path == row.worktree_path
  end

  defp force_pending(%Provision{status: :ready} = row, reason) do
    {:ok, claimed} = Store.claim_start(row.id, row.start_token)
    {:ok, pending} = Store.fail_start(claimed.id, claimed.start_claim_token, reason)
    pending
  end

  defp force_pending(%Provision{status: :started} = row, _reason) do
    Repo.update_all(from(p in Provision, where: p.id == ^row.id), set: [status: :cleanup_pending])
    Store.get(row.id)
  end

  defp force_pending(%Provision{} = row, _reason), do: row

  defp claim_only(row),
    do: Store.claim_start(row.id, row.start_token, lease_seconds: 1) |> elem(1)

  defp receipt(row),
    do:
      Ezagent.Agent.CreationInventory.exact(
        row.creation_attempt_id,
        uri(row.agent_uri),
        uri(row.provenance_root_uri),
        uri(row.workspace_uri)
      )

  defp identity(row),
    do: %{
      provision_id: row.provision_id,
      task_access_uri: uri(row.task_access_uri),
      task_uri: uri(row.task_uri),
      generation: row.generation
    }

  defp uri(value), do: Ezagent.URI.new!(value)
  defp workspace, do: Ezagent.URI.workspace("atomic-team")

  defp ready_row(suffix, opts \\ []) do
    attrs = path_attrs(suffix)
    {:ok, planned} = Store.create_planned(Map.put(attrs, :visibility, :public))
    {:ok, claim} = Store.claim_provision(planned.id)

    {:ok, paths} =
      Paths.derive(
        Map.update!(attrs, :workspace_uri, &uri/1)
        |> Map.update!(:task_uri, &uri/1)
        |> Map.update!(:task_access_uri, &uri/1)
        |> Map.update!(:repository_uri, &uri/1)
      )

    {:ok, ready} =
      Store.mark_ready(planned.id, claim.claim_token, %{
        expected_version: claim.state_version,
        cache_identity: paths.cache_identity,
        worktree_identity: paths.worktree_identity,
        worktree_path: paths.worktree_path,
        resolved_base_commit: String.duplicate("a", 40),
        local_branch_ref: Ezagent.Workspace.TaskWorkspace.GitRunner.local_branch_ref(claim),
        remote_url: "https://example.test/repo.git"
      })

    agent = Keyword.get(opts, :agent_uri, "entity://atomic-team/agent/#{suffix}")

    {:ok, bound} =
      Store.bind_start_intent(ready.provision_id, %{
        agent_uri: agent,
        provenance_root_uri: "entity://atomic-team/user/owner",
        workspace_uri: ready.workspace_uri,
        task_access_uri: ready.task_access_uri,
        task_uri: ready.task_uri,
        generation: ready.generation
      })

    if Keyword.has_key?(opts, :lease_seconds), do: bound, else: bound
  end

  defp path_attrs(suffix),
    do: %{
      provision_id: "atomic-#{suffix}-#{System.unique_integer([:positive])}",
      workspace_uri: URI.to_string(workspace()),
      task_uri: URI.to_string(Ezagent.URI.resource("atomic-team", "kanban-task", suffix)),
      generation: 1,
      task_access_uri:
        URI.to_string(Ezagent.URI.resource("atomic-team", "git-task-access", suffix)),
      repository_uri:
        URI.to_string(Ezagent.URI.resource("atomic-team", "git-repository", suffix)),
      checkout_fingerprint: "fingerprint-#{suffix}",
      base_ref: "main",
      allowed_head_ref: "task/#{suffix}"
    }
end
