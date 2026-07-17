defmodule Ezagent.Workspace.TaskWorkspace.ProvisionerTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.DomainGit.RepositoryRef
  alias Ezagent.DomainGit.WorkspaceProvisionPort.Request
  alias Ezagent.Entity.GitTaskAccess
  alias Ezagent.Workspace.TaskWorkspace.{Provision, Provisioner, Store}
  alias EzagentCore.Repo
  alias EzagentDomainWorkspace.TestSupport.FakeTaskWorkspaceGitRunner

  setup do
    Application.put_env(
      :ezagent_domain_workspace,
      :task_workspace_git_runner,
      FakeTaskWorkspaceGitRunner
    )

    Application.put_env(:ezagent_domain_workspace, :provisioner_test_owner, self())
    Application.delete_env(:ezagent_domain_workspace, :provisioner_test_prepare_result)
    Application.delete_env(:ezagent_domain_workspace, :provisioner_test_verify_result)
    Application.delete_env(:ezagent_domain_workspace, :provisioner_test_delay)
    Application.delete_env(:ezagent_domain_workspace, :provisioner_test_verify_hook)

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_workspace, :task_workspace_git_runner)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_owner)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_prepare_result)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_verify_result)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_delay)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_verify_hook)
    end)

    :ok
  end

  test "duplicate prepare converges on one row and one Git effect" do
    fixture = start_policy(:public)
    Application.put_env(:ezagent_domain_workspace, :provisioner_test_delay, 100)

    results =
      1..8
      |> Task.async_stream(fn _ -> Provisioner.prepare(fixture.request) end,
        max_concurrency: 8,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %{status: :ready}}, &1))

    assert results |> Enum.map(fn {:ok, ready} -> ready.provision_id end) |> Enum.uniq() ==
             [fixture.request.provision_id]

    assert_receive {:git_prepare, %{remote_url: "https://git.example.test/acme/widgets.git"}}
    refute_receive {:git_prepare, _}
    assert Repo.aggregate(Provision, :count) == 1
  end

  test "private policy fails before row, path, or Git process" do
    fixture = start_policy(:private)

    assert {:error, :private_checkout_not_supported} = Provisioner.prepare(fixture.request)
    assert Repo.aggregate(Provision, :count) == 0
    refute_receive {:git_prepare, _}
  end

  test "stored fingerprint drift blocks before Git effect" do
    fixture = start_policy(:public)

    attrs = planned_attrs(fixture)

    assert {:ok, _row} =
             Store.create_planned(%{attrs | repository_uri: other_repository_uri(fixture)})

    assert {:error, :task_policy_mismatch} = Provisioner.prepare(fixture.request)
    refute_receive {:git_prepare, _}
  end

  test "Git and verification failures become safe cleanup-pending blockers" do
    fixture = start_policy(:public)

    Application.put_env(
      :ezagent_domain_workspace,
      :provisioner_test_prepare_result,
      {:error, {:git_exit, 32768}}
    )

    assert {:error, :checkout_unavailable} = Provisioner.prepare(fixture.request)

    assert %Provision{status: :cleanup_pending, cleanup_reason: "checkout_unavailable"} =
             only_row()

    second = start_policy(:public, "second")
    Application.delete_env(:ezagent_domain_workspace, :provisioner_test_prepare_result)

    Application.put_env(
      :ezagent_domain_workspace,
      :provisioner_test_verify_result,
      {:error, :raw_path_detail}
    )

    assert {:error, :workspace_not_ready} = Provisioner.prepare(second.request)

    assert Repo.get_by!(Provision, provision_id: second.request.provision_id).status ==
             :cleanup_pending
  end

  test "cancelled generation and an active path owner never run a second effect" do
    cancelled = start_policy(:public)
    assert {:ok, row} = Store.create_planned(planned_attrs(cancelled))
    assert {:ok, _pending} = Store.request_cleanup(row.id, :task_cancelled)

    assert {:error, :provision_cancelled} = Provisioner.prepare(cancelled.request)
    refute_receive {:git_prepare, _}

    conflict = start_policy(:public, "conflict")
    owner = start_policy(:public, "owner")

    conflict_git_attrs = %{
      workspace_uri: conflict.policy.workspace_uri,
      repository_uri: conflict.policy.repository.repository_uri,
      base_ref: conflict.policy.repository.base_ref,
      provision_id: conflict.request.provision_id,
      generation: conflict.request.generation,
      allowed_head_ref: conflict.policy.allowed_head_ref
    }

    assert {:ok, conflict_paths} =
             Ezagent.Workspace.TaskWorkspace.Paths.derive(conflict_git_attrs)

    assert {:ok, owner_row} = Store.create_planned(planned_attrs(owner))
    assert {:ok, owner_claim} = Store.claim_provision(owner_row.id)

    assert {:ok, _ready_owner} =
             Store.mark_ready(owner_row.id, owner_claim.claim_token, %{
               expected_version: owner_claim.state_version,
               cache_identity: "cache-owner",
               worktree_identity: "worktree-owner",
               worktree_path: conflict_paths.worktree_path
             })

    assert {:error, :worktree_conflict} = Provisioner.prepare(conflict.request)
    refute_receive {:git_prepare, _}
  end

  test "lease loss after Git success cannot publish ready and removes the prepared worktree" do
    fixture = start_policy(:public)

    Application.put_env(:ezagent_domain_workspace, :provisioner_test_verify_hook, fn ->
      row = Repo.get_by!(Provision, provision_id: fixture.request.provision_id)
      {:ok, _pending} = Store.request_cleanup(row.id, :task_cancelled)
      :ok
    end)

    assert {:error, :provision_lease_lost} = Provisioner.prepare(fixture.request)
    assert_receive {:git_prepare, _}
    assert_receive {:git_remove, _}

    assert Repo.get_by!(Provision, provision_id: fixture.request.provision_id).status ==
             :cleanup_pending
  end

  defp start_policy(visibility, suffix \\ "one") do
    id = "task-access-#{suffix}-#{System.unique_integer([:positive])}"
    workspace = "provisioner-#{suffix}-#{System.unique_integer([:positive])}"
    workspace_uri = Ezagent.URI.workspace(workspace)
    task_id = "task-#{suffix}"

    {:ok, repository} =
      RepositoryRef.new(%{
        repository_uri: Ezagent.URI.resource(workspace, "git-repository", "widgets"),
        provider_adapter: :fixture,
        provider_host: "git.example.test",
        external_id: "repo-1",
        owner_path: "acme/widgets",
        base_ref: "main",
        visibility: visibility
      })

    {:ok, policy} =
      GitTaskAccess.new(%{
        id: id,
        task_id: task_id,
        generation: 1,
        workspace_uri: workspace_uri,
        credential_owner_uri: Ezagent.URI.user(workspace, "owner"),
        grantee_uri: Ezagent.URI.agent(workspace, "worker"),
        repository: repository,
        provider_adapter: :fixture,
        allowed_head_ref: "task/#{task_id}",
        allowed_actions: [:provision_workspace, :cleanup_workspace],
        idempotency_inputs: %{task_id: task_id, generation: 1}
      })

    task_access_uri = GitTaskAccess.uri_from_args(policy)
    assert {:ok, _pid} = Ezagent.DomainGit.TaskAccessSupervisor.ensure_started(policy)
    on_exit(fn -> Ezagent.DomainGit.TaskAccessSupervisor.teardown(task_access_uri) end)

    task_uri = Ezagent.URI.resource(workspace, "kanban-task", task_id)

    request = %Request{
      task_access_uri: task_access_uri,
      task_uri: task_uri,
      generation: 1,
      operation: :prepare,
      provision_id: "provision-#{suffix}-#{System.unique_integer([:positive])}"
    }

    %{policy: policy, request: request}
  end

  defp planned_attrs(fixture) do
    policy = fixture.policy

    %{
      provision_id: fixture.request.provision_id,
      workspace_uri: URI.to_string(policy.workspace_uri),
      task_uri: URI.to_string(fixture.request.task_uri),
      generation: fixture.request.generation,
      task_access_uri: URI.to_string(fixture.request.task_access_uri),
      repository_uri: URI.to_string(policy.repository.repository_uri),
      base_ref: policy.repository.base_ref,
      allowed_head_ref: policy.allowed_head_ref,
      visibility: policy.repository.visibility
    }
  end

  defp other_repository_uri(fixture) do
    workspace = Ezagent.URI.workspace_name!(fixture.policy.workspace_uri)
    URI.to_string(Ezagent.URI.resource(workspace, "git-repository", "other"))
  end

  defp only_row do
    [row] = Repo.all(Provision)
    row
  end
end
