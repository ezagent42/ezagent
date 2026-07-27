defmodule Ezagent.Workspace.TaskWorkspace.ChangeCollectorTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.DomainGit.RepositoryRef
  alias Ezagent.DomainGit.WorkspaceChangePort.Request
  alias Ezagent.DomainGit.WorkspaceProvisionPort.Request, as: ProvisionRequest
  alias Ezagent.Entity.GitTaskAccess
  alias Ezagent.Workspace.TaskWorkspace.{ChangeCollector, Provisioner}
  alias EzagentDomainWorkspace.TestSupport.FakeTaskWorkspaceGitRunner

  setup do
    previous_home = System.get_env("EZAGENT_HOME")

    root =
      Path.join(System.tmp_dir!(), "change-collector-#{System.unique_integer([:positive])}")

    System.put_env("EZAGENT_HOME", root)

    Application.put_env(
      :ezagent_domain_workspace,
      :task_workspace_git_runner,
      Ezagent.Workspace.TaskWorkspace.GitRunner
    )

    on_exit(fn ->
      if is_nil(previous_home),
        do: System.delete_env("EZAGENT_HOME"),
        else: System.put_env("EZAGENT_HOME", previous_home)

      Application.delete_env(:ezagent_domain_workspace, :task_workspace_git_runner)
      Application.delete_env(:ezagent_domain_workspace, :task_workspace_remote_builder)
      Application.delete_env(:ezagent_domain_workspace, :provisioner_test_collect_status_result)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  describe "collect/1 happy path" do
    test "collects a single new UTF-8 file as one upsert", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      File.write!(Path.join(worktree_path, "notes.md"), "hello from the task\n")

      assert {:ok, [change]} = ChangeCollector.collect(change_request)
      assert change.path == "notes.md"
      assert change.operation == :upsert
      assert change.content == "hello from the task\n"
    end

    test "collects a modified tracked file as an upsert", %{root: root} do
      %{worktree_path: worktree_path, change_request: change_request} = ready_fixture!(root)

      File.write!(Path.join(worktree_path, "README.md"), "modified by the task\n")

      assert {:ok, [change]} = ChangeCollector.collect(change_request)
      assert change.path == "README.md"
      assert change.content == "modified by the task\n"
    end

    test "rejects an empty diff", %{root: root} do
      %{change_request: change_request} = ready_fixture!(root)

      assert {:error, :no_changes_collected} = ChangeCollector.collect(change_request)
    end

    test "rejects when no ready provision matches provision_id", %{root: root} do
      %{change_request: change_request} = ready_fixture!(root)

      unready = %{
        change_request
        | provision_id: "never-provisioned-#{System.unique_integer([:positive])}"
      }

      assert {:error, :workspace_not_ready} = ChangeCollector.collect(unready)
    end

    test "rejects when generation does not match the provisioned identity", %{root: root} do
      %{change_request: change_request} = ready_fixture!(root)

      mismatched = %{change_request | generation: change_request.generation + 1}

      assert {:error, :workspace_identity_mismatch} = ChangeCollector.collect(mismatched)
    end

    test "rejects a malformed argument closed to the port contract" do
      assert {:error, :invalid_change_request} = ChangeCollector.collect(:not_a_request)
    end
  end

  defp ready_fixture!(root, suffix \\ "one") do
    origin = local_origin!(root)
    workspace = "change-collector-#{suffix}-#{System.unique_integer([:positive])}"
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
        visibility: :public
      })

    {:ok, policy} =
      GitTaskAccess.new(%{
        id: "task-access-#{suffix}-#{System.unique_integer([:positive])}",
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
    provision_id = "provision-#{suffix}-#{System.unique_integer([:positive])}"

    {:ok, provision_request} =
      ProvisionRequest.new_authorized(
        %{
          task_access_uri: task_access_uri,
          task_uri: task_uri,
          generation: 1,
          operation: :prepare,
          provision_id: provision_id
        },
        policy
      )

    Application.put_env(:ezagent_domain_workspace, :task_workspace_remote_builder, fn _, _ ->
      %{remote_url: origin, allow_local_fixture: true}
    end)

    assert {:ok, %{status: :ready, cwd: worktree_path}} = Provisioner.prepare(provision_request)

    {:ok, change_request} =
      Request.new(%{
        task_access_uri: task_access_uri,
        task_uri: task_uri,
        generation: 1,
        provision_id: provision_id
      })

    %{
      worktree_path: worktree_path,
      change_request: change_request,
      task_access_uri: task_access_uri,
      task_uri: task_uri
    }
  end

  defp local_origin!(root) do
    origin = Path.join(root, "origin-#{System.unique_integer([:positive])}.git")
    source = Path.join(root, "source-#{System.unique_integer([:positive])}")
    File.mkdir_p!(source)

    git!(root, ["init", "--bare", origin])
    git!(source, ["init", "-b", "main"])
    File.write!(Path.join(source, "README.md"), "fixture\n")
    git!(source, ["add", "README.md"])

    git!(source, [
      "-c",
      "user.name=Fixture",
      "-c",
      "user.email=fixture@example.test",
      "commit",
      "-m",
      "fixture"
    ])

    git!(source, ["remote", "add", "origin", origin])
    git!(source, ["push", "origin", "main"])
    git!(root, ["--git-dir", origin, "symbolic-ref", "HEAD", "refs/heads/main"])
    origin
  end

  defp git!(cd, args) do
    {output, 0} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    output
  end
end
