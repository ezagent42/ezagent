defmodule Ezagent.Workspace.TaskWorkspace.ReconcilerTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace.TaskWorkspace.{Paths, Provision, Reconciler, Store}
  alias Ezagent.Agent.CreationInventory
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
            :provisioner_test_remove_clears,
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
    assert_receive {:git_verify, proof}
    assert proof.remote_url == ready.remote_url
    assert proof.resolved_base_commit == ready.resolved_base_commit
    assert proof.local_branch_ref == ready.local_branch_ref
    refute_receive {:git_remove, _}
    refute_receive {:git_verify_absent, _}
  end

  test "ambiguous start transfers retirement evidence before Git cleanup" do
    ready = ready_row()
    {:ok, claimed} = Store.claim_start(ready.id, ready.start_token)
    record_receipt(claimed)

    assert {:ok, %Provision{status: :cleaned}} = Reconciler.cleanup(ready.id, :task_cancelled)
    assert_receive {:retire_agent, "entity://reconciler-team/agent/worker", attempt_id}
    assert attempt_id == Store.get(ready.id).creation_attempt_id
    assert_receive {:retirement_facts, facts}
    assert facts.attempt_id == claimed.creation_attempt_id
    assert facts.agent_uri == Ezagent.URI.new!(claimed.agent_uri)
    assert facts.root_uri == Ezagent.URI.new!(claimed.provenance_root_uri)
    assert facts.workspace_uri == Ezagent.URI.new!(claimed.workspace_uri)
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
    {:ok, claimed} = Store.claim_start(ready.id, ready.start_token)
    record_receipt(claimed)

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

  test "expired starting is retired and cleaned without another instantiate" do
    ready = ready_row("expired-start")
    {:ok, starting} = Store.claim_start(ready.id, ready.start_token, lease_seconds: 1)
    record_receipt(starting)
    now = DateTime.add(starting.start_lease_until, 1, :second)
    agent_uri = starting.agent_uri

    Application.put_env(
      :ezagent_domain_workspace,
      :provisioner_test_verify_absent_result,
      {:error, :worktree_still_present}
    )

    Application.put_env(:ezagent_domain_workspace, :provisioner_test_remove_clears, true)

    assert %{attempted: 1, cleaned: 1, failed: 0} =
             Reconciler.recover_once(limit: 10, now: now)

    assert_receive {:retire_agent, ^agent_uri, attempt_id}
    assert attempt_id == starting.creation_attempt_id
    assert_receive {:git_remove, %{worktree_path: path}}
    assert path == starting.worktree_path
    assert Repo.get!(Provision, starting.id).status == :cleaned
    refute_receive {:instantiate_called, _}
  end

  test "expired starting without an exact receipt cleans Git without fake retirement" do
    ready = ready_row("expired-no-receipt")
    {:ok, starting} = Store.claim_start(ready.id, ready.start_token, lease_seconds: 1)
    now = DateTime.add(starting.start_lease_until, 1, :second)

    assert %{attempted: 1, cleaned: 1, failed: 0} =
             Reconciler.recover_once(limit: 1, now: now)

    refute_receive {:retire_agent, _, _}
    assert_receive {:git_verify_absent, %{worktree_path: path}}
    assert path == starting.worktree_path
    assert Repo.get!(Provision, starting.id).status == :cleaned
  end

  test "exact receipt conflict remains cleanup-pending with a fixed auditable blocker" do
    ready = ready_row("receipt-conflict")
    {:ok, starting} = Store.claim_start(ready.id, ready.start_token, lease_seconds: 1)
    now = DateTime.add(starting.start_lease_until, 1, :second)

    agent = Ezagent.URI.new!(starting.agent_uri)
    workspace = Ezagent.URI.new!(starting.workspace_uri)
    conflicting_root = Ezagent.URI.user("reconciler-team", "other-owner")

    assert {:ok, :inserted} =
             CreationInventory.record_exact(
               Repo,
               starting.creation_attempt_id,
               agent,
               conflicting_root,
               workspace
             )

    assert %{attempted: 1, cleaned: 0, failed: 1} =
             Reconciler.recover_once(limit: 1, now: now)

    blocked = Repo.get!(Provision, starting.id)
    assert blocked.status == :cleanup_pending
    assert blocked.blocker_code == "creation_receipt_conflict"
    refute_receive {:retire_agent, _, _}
    refute_receive {:git_verify_absent, _}
  end

  test "expired start recovery fences the stale original claimant" do
    ready = ready_row("stale-start")
    {:ok, starting} = Store.claim_start(ready.id, ready.start_token, lease_seconds: 1)
    now = DateTime.add(starting.start_lease_until, 1, :second)

    assert %{cleaned: 1, failed: 0} = Reconciler.recover_once(limit: 10, now: now)

    assert {:error, :invalid_start_transition} =
             Store.mark_started(starting.id, starting.start_claim_token, %{
               agent_uri: starting.agent_uri,
               creation_attempt_id: "stale-attempt",
               provenance_root_uri: starting.provenance_root_uri
             })

    assert {:error, :invalid_start_transition} =
             Store.fail_start(starting.id, starting.start_claim_token, :stale_worker)
  end

  test "nil start lease is conservatively recovered" do
    ready = ready_row("nil-start-lease")
    {:ok, starting} = Store.claim_start(ready.id, ready.start_token)
    record_receipt(starting)

    starting
    |> Provision.transition_changeset(%{start_lease_until: nil})
    |> Repo.update!()

    assert %{attempted: 1, cleaned: 1, failed: 0} = Reconciler.recover_once(limit: 1)
    assert_receive {:retire_agent, _, attempt_id}
    assert attempt_id == Store.get(starting.id).creation_attempt_id
    assert Repo.get!(Provision, starting.id).status == :cleaned
  end

  test "a competing start reclaim makes a stale recovery snapshot a benign skip" do
    ready = ready_row("reclaim-race")
    {:ok, stale} = Store.claim_start(ready.id, ready.start_token, lease_seconds: 1)
    recovery_now = DateTime.add(stale.start_lease_until, 1, :second)

    result =
      Reconciler.recover_once(
        limit: 1,
        now: recovery_now,
        after_candidate_list: fn [candidate] ->
          assert candidate.state_version == stale.state_version

          {:ok, reclaimed} =
            Store.claim_start(stale.id, stale.start_token,
              now: recovery_now,
              lease_seconds: 60
            )

          send(self(), {:reclaimed, reclaimed})
        end
      )

    assert %{attempted: 1, cleaned: 0, failed: 0} = result
    assert_receive {:reclaimed, reclaimed}
    current = Repo.get!(Provision, stale.id)
    assert current.status == :starting
    assert current.start_claim_token == reclaimed.start_claim_token
    refute_receive {:retire_agent, _, _}
    refute_receive {:git_remove, _}
  end

  test "old start claimant cannot complete or fail after cleanup ownership is acquired" do
    ready = ready_row("cleanup-owned")
    {:ok, starting} = Store.claim_start(ready.id, ready.start_token, lease_seconds: 1)
    record_receipt(starting)
    now = DateTime.add(starting.start_lease_until, 1, :second)
    parent = self()

    Application.put_env(:ezagent_domain_workspace, :task_workspace_retirement_hook, fn ->
      send(parent, {:cleanup_owned, self()})

      receive do
        :continue_cleanup -> :ok
      end
    end)

    recovery = Task.async(fn -> Reconciler.recover_once(limit: 1, now: now) end)
    assert_receive {:cleanup_owned, recovery_pid}

    owned = Repo.get!(Provision, starting.id)
    assert owned.status == :cleanup_pending
    assert is_binary(owned.claim_token)

    assert {:error, :invalid_start_transition} =
             Store.mark_started(starting.id, starting.start_claim_token, %{
               agent_uri: starting.agent_uri,
               creation_attempt_id: "stale-attempt",
               provenance_root_uri: starting.provenance_root_uri
             })

    assert {:error, :invalid_start_transition} =
             Store.fail_start(starting.id, starting.start_claim_token, :stale_worker)

    refute_receive {:git_remove, _}
    send(recovery_pid, :continue_cleanup)
    assert %{cleaned: 1, failed: 0} = Task.await(recovery)
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
        local_branch_ref: Ezagent.Workspace.TaskWorkspace.GitRunner.local_branch_ref(claim),
        remote_url: "https://git.example.test/acme/widgets.git"
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

  defp record_receipt(row) do
    assert {:ok, _} =
             CreationInventory.record_exact(
               Repo,
               row.creation_attempt_id,
               Ezagent.URI.new!(row.agent_uri),
               Ezagent.URI.new!(row.provenance_root_uri),
               Ezagent.URI.new!(row.workspace_uri)
             )
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
