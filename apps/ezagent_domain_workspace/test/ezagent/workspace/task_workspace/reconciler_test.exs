defmodule Ezagent.Workspace.TaskWorkspace.ReconcilerTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace.TaskWorkspace.{Paths, Provision, Reconciler, Store}
  alias EzagentCore.Repo

  setup do
    Application.put_env(:ezagent_domain_workspace, :provisioner_test_owner, self())

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
    Application.delete_env(:ezagent_domain_workspace, :provisioner_test_verify_result)

    on_exit(fn ->
      for key <- [
            :provisioner_test_owner,
            :task_workspace_git_runner,
            :task_workspace_retirement,
            :task_workspace_retirement_result,
            :task_workspace_retirement_hook,
            :provisioner_test_verify_absent_result,
            :provisioner_test_remove_result,
            :provisioner_test_verify_result
          ],
          do: Application.delete_env(:ezagent_domain_workspace, key)
    end)

    :ok
  end

  test "never-started cleanup removes only the canonical durable path" do
    ready = ready_row()

    assert {:ok, %Provision{status: :cleaned}} = Reconciler.cleanup(ready.id, :task_cancelled)
    assert_receive {:git_verify_absent, %{worktree_path: path}}
    assert path == ready.worktree_path
    refute_receive {:retire_agent, _, _}
  end

  test "terminal cleanup retry is idempotent and performs no second effect" do
    ready = ready_row()
    assert {:ok, cleaned} = Reconciler.cleanup(ready.id, :task_cancelled)
    assert_receive {:git_verify_absent, _}

    assert {:ok, same} = Reconciler.cleanup(ready.id, :task_cancelled)
    assert same.id == cleaned.id
    assert same.cleaned_at == cleaned.cleaned_at
    refute_receive {:git_verify_absent, _}
  end

  test "transient ready verification failure is non-destructive" do
    ready = ready_row()

    Application.put_env(
      :ezagent_domain_workspace,
      :provisioner_test_verify_result,
      {:error, :git_command_timeout}
    )

    assert %{attempted: 1, cleaned: 0, failed: 1} = Reconciler.recover_once(limit: 1)
    assert Repo.get!(Provision, ready.id).status == :ready
    refute_receive {:git_remove, _}
    refute_receive {:git_verify_absent, _}
  end

  test "ambiguous start transfers retirement evidence before Git cleanup" do
    ready = ready_row()
    {:ok, _claimed} = Store.claim_start(ready.id, ready.start_token)

    assert {:ok, %Provision{status: :cleaned}} = Reconciler.cleanup(ready.id, :task_cancelled)
    assert_receive {:retire_agent, "entity://reconciler-team/agent/worker", nil}
    assert_receive {:git_verify_absent, _}
  end

  test "canonical identity mismatch fails closed without any external effect" do
    ready = ready_row()

    ready
    |> Provision.transition_changeset(%{worktree_path: ready.worktree_path <> "-rogue"})
    |> Repo.update!()

    assert {:error, :workspace_path_mismatch} = Reconciler.cleanup(ready.id, :task_cancelled)
    refute_receive {:retire_agent, _, _}
    refute_receive {:git_remove, _}
    refute_receive {:git_verify_absent, _}
  end

  test "a cleanup lease takeover after retirement fences the Git effect" do
    ready = ready_row()
    {:ok, _claimed} = Store.claim_start(ready.id, ready.start_token)

    Application.put_env(:ezagent_domain_workspace, :task_workspace_retirement_hook, fn ->
      current = Repo.get!(Provision, ready.id)

      {:ok, _replacement} =
        Store.claim_cleanup(current.id, now: DateTime.add(current.lease_until, 1, :second))

      :ok
    end)

    assert {:error, :cleanup_lease_lost} = Reconciler.cleanup(ready.id, :task_cancelled)
    assert_receive {:retire_agent, _, _}
    refute_receive {:git_remove, _}
    refute_receive {:git_verify_absent, _}
  end

  test "bounded boot recovery ignores planned rows and continues after a row failure" do
    Application.put_env(
      :ezagent_domain_workspace,
      :provisioner_test_verify_result,
      {:error, :worktree_verification_failed}
    )

    _planned = planned_row("planned")
    bad = ready_row("bad")

    bad
    |> Provision.transition_changeset(%{worktree_path: bad.worktree_path <> "-rogue"})
    |> Repo.update!()

    good = ready_row("good")

    assert %{attempted: 2, cleaned: 1, failed: 1} = Reconciler.recover_once(limit: 2)
    assert Repo.get!(Provision, good.id).status == :cleaned
    assert Repo.get!(Provision, bad.id).status == :ready
  end

  test "cleanup lane is not starved by older valid ready rows" do
    for suffix <- ~w(valid-a valid-b valid-c), do: ready_row(suffix)
    pending = planned_row("pending")
    {:ok, :never_started, _pending} = Store.request_cleanup(pending.id, :task_cancelled)

    assert %{attempted: 2, cleaned: 1} = Reconciler.recover_once(limit: 2)
    assert Repo.get!(Provision, pending.id).status == :cleaned
  end

  defp ready_row(suffix \\ "one") do
    row = planned_row(suffix)
    {:ok, claim} = Store.claim_provision(row.id)
    {:ok, paths} = Paths.derive(path_attrs(suffix))

    {:ok, ready} =
      Store.mark_ready(row.id, claim.claim_token, %{
        expected_version: claim.state_version,
        cache_identity: paths.cache_identity,
        worktree_identity: paths.worktree_identity,
        worktree_path: paths.worktree_path,
        resolved_base_commit: String.duplicate("a", 40),
        local_branch_ref: "refs/heads/ezagent/task/reconciler/g1"
      })

    {:ok, ready} =
      Store.bind_start_intent(ready.provision_id, %{
        agent_uri: "entity://reconciler-team/agent/worker",
        provenance_root_uri: "entity://reconciler-team/user/owner",
        workspace_uri: ready.workspace_uri,
        task_access_uri: ready.task_access_uri,
        task_uri: ready.task_uri,
        generation: ready.generation
      })

    ready
  end

  defp planned_row(suffix) do
    attrs = path_attrs(suffix)

    stored =
      attrs
      |> Map.update!(:workspace_uri, &URI.to_string/1)
      |> Map.update!(:task_uri, &URI.to_string/1)
      |> Map.update!(:task_access_uri, &URI.to_string/1)
      |> Map.update!(:repository_uri, &URI.to_string/1)
      |> Map.put(:visibility, :public)

    {:ok, row} = Store.create_planned(stored)
    row
  end

  defp path_attrs(suffix) do
    %{
      provision_id: "reconcile-#{suffix}",
      workspace_uri: Ezagent.URI.workspace("reconciler-team"),
      task_uri: Ezagent.URI.resource("reconciler-team", "kanban-task", "task-#{suffix}"),
      generation: 1,
      task_access_uri:
        Ezagent.URI.resource("reconciler-team", "git-task-access", "access-#{suffix}"),
      repository_uri:
        Ezagent.URI.resource("reconciler-team", "git-repository", "repository-#{suffix}"),
      checkout_fingerprint: "fingerprint-#{suffix}",
      base_ref: "main",
      allowed_head_ref: "task/#{suffix}"
    }
  end
end
