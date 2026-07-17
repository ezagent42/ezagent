defmodule Ezagent.Workspace.TaskWorkspace.AtomicOwnershipTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.CreationInventory
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

    on_exit(fn ->
      for key <- [
            :provisioner_test_owner,
            :task_workspace_git_runner,
            :task_workspace_retirement,
            :provisioner_test_verify_absent_result
          ],
          do: Application.delete_env(:ezagent_domain_workspace, key)
    end)

    :ok
  end

  test "1 winner commit before init return crash is owned by exact durable facts" do
    starting = starting_row("winner-before-return")
    barrier = barrier(:winner_committed_before_init_return)
    record_receipt(starting)
    assert_receive {:winner_committed_before_init_return, ^barrier}
    release(barrier)
    assert_owned(starting)
  end

  test "2 instantiate return before completion crash remains receipt-owned" do
    starting = starting_row("return-before-completion")
    barrier = barrier(:instantiate_returned)
    record_receipt(starting)
    assert_receive {:instantiate_returned, ^barrier}
    release(barrier)
    assert_owned(starting)
  end

  test "3 adopted same-lineage Agent has no losing-attempt receipt" do
    starting = starting_row("adopted")
    assert {:unowned, :creation_receipt_absent} = Store.classify_creation_receipt(starting)
  end

  test "4 concurrent attempts expose exactly one winning receipt" do
    winner = starting_row("concurrent-winner")
    loser = starting_row("concurrent-loser", agent_uri: winner.agent_uri)
    barrier = barrier(:spawn_winner_selected)
    record_receipt(winner)
    assert_receive {:spawn_winner_selected, ^barrier}
    release(barrier)
    assert_owned(winner)
    assert {:unowned, :creation_receipt_absent} = Store.classify_creation_receipt(loser)
  end

  test "5 each ownership transaction write failure leaves no receipt" do
    for failed_write <- [:inventory, :lineage] do
      starting = starting_row("transaction-#{failed_write}")

      assert {:error, ^failed_write} =
               Repo.transaction(fn ->
                 if failed_write == :inventory do
                   Repo.rollback(:inventory)
                 else
                   record_receipt(starting)
                   Repo.rollback(:lineage)
                 end
               end)

      assert {:unowned, :creation_receipt_absent} = Store.classify_creation_receipt(starting)
    end
  end

  test "6 cache publication failure rehydrates from the durable receipt" do
    starting = starting_row("cache-rehydrate")
    record_receipt(starting)
    assert :error = Ezagent.WorkspaceRegistry.lookup(Ezagent.URI.new!(starting.agent_uri))
    assert_owned(starting)
  end

  test "7 sidecar failure after receipt remains sanctioned ownership" do
    starting = starting_row("sidecar-after-receipt")
    record_receipt(starting)

    assert {:ok, _pending} =
             Store.fail_start(starting.id, starting.start_claim_token, :sidecar_failed)

    assert_owned(Store.get(starting.id))
  end

  test "8 Repo and BEAM-state restart reads ownership from SQL" do
    starting = starting_row("repo-beam-restart")
    record_receipt(starting)
    barrier = barrier(:beam_state_discarded)
    assert_receive {:beam_state_discarded, ^barrier}
    release(barrier)
    assert_owned(Repo.get!(Provision, starting.id))
  end

  test "9 exact replay is owned while a coordinate conflict fails closed" do
    starting = starting_row("replay-conflict")
    record_receipt(starting)
    record_receipt(starting)
    assert_owned(starting)

    conflict = %{starting | provenance_root_uri: "entity://atomic-team/user/conflict"}
    assert {:error, :creation_receipt_conflict} = Store.classify_creation_receipt(conflict)
  end

  test "10 expired starting row without receipt cleans Git and never retires" do
    starting = starting_row("expired-no-receipt", lease_seconds: 1)
    now = DateTime.add(starting.start_lease_until, 1, :second)

    assert %{attempted: 1, cleaned: 1, failed: 0} =
             Reconciler.recover_once(limit: 1, now: now)

    refute_receive {:retire_agent, _, _}
    assert_receive {:git_verify_absent, %{worktree_path: path}}
    assert path == starting.worktree_path
  end

  defp barrier(message) do
    parent = self()

    spawn(fn ->
      send(parent, {message, self()})

      receive do
        :release -> :ok
      end
    end)
  end

  defp release(pid), do: send(pid, :release)

  defp assert_owned(row) do
    assert {:owned, facts} = Store.classify_creation_receipt(row)
    assert facts.attempt_id == row.creation_attempt_id
    assert facts.agent_uri == Ezagent.URI.new!(row.agent_uri)
    assert facts.root_uri == Ezagent.URI.new!(row.provenance_root_uri)
    assert facts.workspace_uri == Ezagent.URI.new!(row.workspace_uri)
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

  defp starting_row(suffix, opts \\ []) do
    attrs = path_attrs(suffix)

    {:ok, planned} =
      attrs
      |> Map.update!(:workspace_uri, &URI.to_string/1)
      |> Map.update!(:task_uri, &URI.to_string/1)
      |> Map.update!(:task_access_uri, &URI.to_string/1)
      |> Map.update!(:repository_uri, &URI.to_string/1)
      |> Map.put(:visibility, :public)
      |> Store.create_planned()

    {:ok, claim} = Store.claim_provision(planned.id)
    {:ok, paths} = Paths.derive(attrs)

    {:ok, ready} =
      Store.mark_ready(planned.id, claim.claim_token, %{
        expected_version: claim.state_version,
        cache_identity: paths.cache_identity,
        worktree_identity: paths.worktree_identity,
        worktree_path: paths.worktree_path,
        resolved_base_commit: String.duplicate("a", 40),
        local_branch_ref: Ezagent.Workspace.TaskWorkspace.GitRunner.local_branch_ref(claim)
      })

    agent_uri = Keyword.get(opts, :agent_uri, "entity://atomic-team/agent/worker-#{suffix}")

    {:ok, ready} =
      Store.bind_start_intent(ready.provision_id, %{
        agent_uri: agent_uri,
        provenance_root_uri: "entity://atomic-team/user/owner",
        workspace_uri: ready.workspace_uri,
        task_access_uri: ready.task_access_uri,
        task_uri: ready.task_uri,
        generation: ready.generation
      })

    Store.claim_start(ready.id, ready.start_token,
      lease_seconds: Keyword.get(opts, :lease_seconds, 60)
    )
    |> elem(1)
  end

  defp path_attrs(suffix) do
    %{
      provision_id: "atomic-#{suffix}",
      workspace_uri: Ezagent.URI.workspace("atomic-team"),
      task_uri: Ezagent.URI.resource("atomic-team", "kanban-task", "task-#{suffix}"),
      generation: 1,
      task_access_uri: Ezagent.URI.resource("atomic-team", "git-task-access", "access-#{suffix}"),
      repository_uri: Ezagent.URI.resource("atomic-team", "git-repository", "repo-#{suffix}"),
      checkout_fingerprint: "fingerprint-#{suffix}",
      base_ref: "main",
      allowed_head_ref: "task/#{suffix}"
    }
  end
end
