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

    Application.put_env(
      :ezagent_domain_workspace,
      :provisioner_test_prepare_result,
      prepared_result()
    )

    Application.delete_env(:ezagent_domain_workspace, :provisioner_test_verify_result)
    Application.delete_env(:ezagent_domain_workspace, :provisioner_test_delay)
    Application.delete_env(:ezagent_domain_workspace, :provisioner_test_verify_hook)
    Application.delete_env(:ezagent_domain_workspace, :provisioner_test_remove_clears)
    Application.delete_env(:ezagent_domain_workspace, :provisioner_test_verify_absent_result)

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_workspace, :task_workspace_git_runner)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_owner)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_prepare_result)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_verify_result)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_delay)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_verify_hook)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_remove_clears)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_verify_absent_result)
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

    assert %Provision{
             resolved_base_commit: resolved_base_commit,
             local_branch_ref: "refs/heads/ezagent/task/0123456789abcdef01234567/g1"
           } = Repo.get_by!(Provision, provision_id: fixture.request.provision_id)

    assert resolved_base_commit == String.duplicate("a", 40)
  end

  test "private policy fails before row, path, or Git process" do
    fixture = start_policy(:private)

    assert {:error, :private_checkout_not_supported} = Provisioner.prepare(fixture.request)
    assert Repo.aggregate(Provision, :count) == 0
    refute_receive {:git_prepare, _}
  end

  test "missing or forged authorized policy fails closed before effects" do
    fixture = start_policy(:public)

    assert {:error, :task_policy_mismatch} =
             Provisioner.prepare(%{fixture.request | task_policy: nil})

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

    assert %Provision{status: :cleaned, cleanup_reason: "checkout_unavailable"} =
             only_row()

    second = start_policy(:public, "second")

    Application.put_env(
      :ezagent_domain_workspace,
      :provisioner_test_prepare_result,
      prepared_result()
    )

    Application.put_env(
      :ezagent_domain_workspace,
      :provisioner_test_verify_result,
      {:error, :raw_path_detail}
    )

    assert {:error, :workspace_not_ready} = Provisioner.prepare(second.request)

    assert Repo.get_by!(Provision, provision_id: second.request.provision_id).status ==
             :cleaned
  end

  test "indeterminate worktree add persists effect proof and cleanup converges before retry" do
    fixture = start_policy(:public)
    {:ok, paths} = Ezagent.Workspace.TaskWorkspace.Paths.derive(git_attrs(fixture))
    prepared = Map.merge(paths, prepared_proof())

    Application.put_env(
      :ezagent_domain_workspace,
      :provisioner_test_prepare_result,
      {:error, {:worktree_add_failed, :git_command_timeout}, prepared}
    )

    Application.put_env(
      :ezagent_domain_workspace,
      :provisioner_test_verify_absent_result,
      {:error, :worktree_still_present}
    )

    Application.put_env(:ezagent_domain_workspace, :provisioner_test_remove_clears, true)

    assert {:error, :checkout_unavailable} = Provisioner.prepare(fixture.request)
    assert_receive {:git_prepare, _}
    assert_receive {:git_remove, %{worktree_path: worktree_path}}
    assert worktree_path == paths.worktree_path

    assert %Provision{
             status: :cleaned,
             worktree_path: ^worktree_path,
             resolved_base_commit: resolved_base_commit
           } = Repo.get_by!(Provision, provision_id: fixture.request.provision_id)

    assert resolved_base_commit == prepared.resolved_base_commit
    assert {:error, :provision_cancelled} = Provisioner.prepare(fixture.request)
    refute_receive {:git_prepare, _}
  end

  test "cancelled generation and an active path owner never run a second effect" do
    cancelled = start_policy(:public)
    assert {:ok, row} = Store.create_planned(planned_attrs(cancelled))
    assert {:ok, :never_started, _pending} = Store.request_cleanup(row.id, :task_cancelled)

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
               worktree_path: conflict_paths.worktree_path,
               resolved_base_commit: String.duplicate("b", 40),
               local_branch_ref: "refs/heads/ezagent/task/fedcba9876543210fedcba98/g1"
             })

    assert {:error, :worktree_conflict} = Provisioner.prepare(conflict.request)
    refute_receive {:git_prepare, _}
  end

  test "cancellation after Git success fences ready and leaves cleanup to its owner" do
    fixture = start_policy(:public)

    Application.put_env(:ezagent_domain_workspace, :provisioner_test_verify_hook, fn ->
      row = Repo.get_by!(Provision, provision_id: fixture.request.provision_id)
      {:ok, :never_started, _pending} = Store.request_cleanup(row.id, :task_cancelled)
      :ok
    end)

    assert {:error, :provision_lease_lost} = Provisioner.prepare(fixture.request)
    assert_receive {:git_prepare, _}
    refute_receive {:git_remove, _}

    assert Repo.get_by!(Provision, provision_id: fixture.request.provision_id).status ==
             :cleanup_pending
  end

  test "lease takeover fences stale failure without deleting the replacement artifact" do
    fixture = start_policy(:public)

    Application.put_env(:ezagent_domain_workspace, :provisioner_test_verify_hook, fn ->
      row = Repo.get_by!(Provision, provision_id: fixture.request.provision_id)
      {:ok, _replacement} = Store.claim_provision(row.id, now: DateTime.add(row.lease_until, 1))
      :ok
    end)

    assert {:error, :provision_lease_lost} = Provisioner.prepare(fixture.request)
    refute_receive {:git_remove, _}

    current = Repo.get_by!(Provision, provision_id: fixture.request.provision_id)
    assert current.status == :provisioning
    refute is_nil(current.claim_token)
  end

  test "authorized policy envelope remains authoritative during preparation" do
    fixture = start_policy(:public)
    _paths = configure_canonical_prepare(fixture)

    Application.put_env(
      :ezagent_domain_workspace,
      :provisioner_test_verify_absent_result,
      {:error, :worktree_still_present}
    )

    Application.put_env(:ezagent_domain_workspace, :provisioner_test_remove_clears, true)

    Application.put_env(:ezagent_domain_workspace, :provisioner_test_verify_hook, fn ->
      :ok = Ezagent.DomainGit.TaskAccessSupervisor.teardown(fixture.request.task_access_uri)
      private_repository = %{fixture.policy.repository | visibility: :private}
      private_policy = %{fixture.policy | repository: private_repository}
      {:ok, _pid} = Ezagent.DomainGit.TaskAccessSupervisor.ensure_started(private_policy)
      :ok
    end)

    assert {:ok, %{status: :ready}} = Provisioner.prepare(fixture.request)
    assert_receive {:git_prepare, _}
    refute_receive {:git_remove, _}

    assert %Provision{status: :ready} =
             Repo.get_by!(Provision, provision_id: fixture.request.provision_id)
  end

  test "provision lease exceeds bounded lock wait plus the Git command budget" do
    assert Provisioner.provision_lease_seconds() * 1_000 >
             5_000 + Ezagent.Workspace.TaskWorkspace.GitRunner.maximum_provision_duration_ms()
  end

  test "provision failures do not call Git removal outside the reconciler" do
    source =
      File.read!(
        Path.expand("../../../../lib/ezagent/workspace/task_workspace/provisioner.ex", __DIR__)
      )

    refute source =~ "runner().remove"
    refute source =~ "serialized_remove"
  end

  test "cleanup revalidates policy coordinates and completes the durable row" do
    fixture = start_policy(:public)

    {:ok, paths} =
      Ezagent.Workspace.TaskWorkspace.Paths.derive(%{
        workspace_uri: fixture.policy.workspace_uri,
        repository_uri: fixture.policy.repository.repository_uri,
        provision_id: fixture.request.provision_id,
        generation: fixture.request.generation,
        base_ref: fixture.policy.repository.base_ref,
        allowed_head_ref: fixture.policy.allowed_head_ref
      })

    Application.put_env(
      :ezagent_domain_workspace,
      :provisioner_test_prepare_result,
      {:ok, Map.merge(paths, prepared_proof())}
    )

    assert {:ok, %{status: :ready}} = Provisioner.prepare(fixture.request)

    cleanup_request = %{fixture.request | operation: :cleanup}

    assert {:ok, %{status: :cleaned, provision_id: provision_id}} =
             Provisioner.cleanup(cleanup_request)

    assert provision_id == fixture.request.provision_id
    assert_receive {:git_verify_absent, _}

    assert {:ok, %{status: :cleaned, provision_id: ^provision_id}} =
             Provisioner.cleanup(cleanup_request)
  end

  test "failed prepared worktree waits for the same cache lock before removal" do
    fixture = start_policy(:public)
    paths = configure_canonical_prepare(fixture)
    owner = self()

    Application.put_env(:ezagent_domain_workspace, :provisioner_test_verify_hook, fn ->
      send(owner, {:verify_paused, self()})
      receive do: (:continue_verify -> :ok)
    end)

    Application.put_env(
      :ezagent_domain_workspace,
      :provisioner_test_verify_result,
      {:error, :worktree_verification_failed}
    )

    Application.put_env(
      :ezagent_domain_workspace,
      :provisioner_test_verify_absent_result,
      {:error, :worktree_still_present}
    )

    Application.put_env(:ezagent_domain_workspace, :provisioner_test_remove_clears, true)

    provision = Task.async(fn -> Provisioner.prepare(fixture.request) end)
    assert_receive {:verify_paused, worker}

    holder =
      Task.async(fn ->
        Ezagent.Workspace.TaskWorkspace.CacheLock.with_lock(paths.cache_identity, 1_000, fn ->
          send(owner, {:remove_lock_held, self()})
          receive do: (:release_remove_lock -> :ok)
        end)
      end)

    assert_receive {:remove_lock_held, holder_pid}
    send(worker, :continue_verify)
    refute_receive {:git_remove, _}, 50
    send(holder_pid, :release_remove_lock)
    assert_receive {:git_remove, _}
    assert {:error, :workspace_not_ready} = Task.await(provision)
    assert :ok = Task.await(holder)
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

    {:ok, request} =
      Request.new_authorized(
        %{
          task_access_uri: task_access_uri,
          task_uri: task_uri,
          generation: 1,
          operation: :prepare,
          provision_id: "provision-#{suffix}-#{System.unique_integer([:positive])}"
        },
        policy
      )

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
      checkout_fingerprint: Provisioner.checkout_fingerprint(policy),
      base_ref: policy.repository.base_ref,
      allowed_head_ref: policy.allowed_head_ref,
      visibility: policy.repository.visibility
    }
  end

  defp configure_canonical_prepare(fixture) do
    {:ok, paths} =
      Ezagent.Workspace.TaskWorkspace.Paths.derive(%{
        workspace_uri: fixture.policy.workspace_uri,
        repository_uri: fixture.policy.repository.repository_uri,
        provision_id: fixture.request.provision_id,
        generation: fixture.request.generation,
        base_ref: fixture.policy.repository.base_ref,
        allowed_head_ref: fixture.policy.allowed_head_ref
      })

    Application.put_env(
      :ezagent_domain_workspace,
      :provisioner_test_prepare_result,
      {:ok, Map.merge(paths, prepared_proof())}
    )

    paths
  end

  defp git_attrs(fixture) do
    %{
      workspace_uri: fixture.policy.workspace_uri,
      repository_uri: fixture.policy.repository.repository_uri,
      provision_id: fixture.request.provision_id,
      generation: fixture.request.generation,
      base_ref: fixture.policy.repository.base_ref,
      allowed_head_ref: fixture.policy.allowed_head_ref
    }
  end

  defp prepared_result do
    {:ok,
     Map.merge(
       %{
         cache_identity: "cache-fixture",
         worktree_identity: "worktree-fixture",
         worktree_path: "/tmp/ezagent-task-worktree-fixture"
       },
       prepared_proof()
     )}
  end

  defp prepared_proof do
    %{
      resolved_base_commit: String.duplicate("a", 40),
      local_branch_ref: "refs/heads/ezagent/task/0123456789abcdef01234567/g1"
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
