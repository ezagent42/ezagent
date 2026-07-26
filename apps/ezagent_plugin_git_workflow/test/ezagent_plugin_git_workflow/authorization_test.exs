defmodule EzagentPluginGitWorkflow.AuthorizationTest do
  use EzagentPluginGitWorkflow.ConnCase, async: false

  alias EzagentPluginGitWorkflow.AcceptIntent
  alias EzagentPluginGitWorkflow.Authorization
  alias EzagentPluginGitWorkflow.ExecutionSeam
  alias EzagentPluginGitWorkflow.ExecutionSeam.Unavailable
  alias EzagentPluginGitWorkflow.FakeExecutionSeam
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :authorization

  @valid_binding_attrs %{
    id: "bnd_auth_test",
    generation: 1,
    workspace_uri: Ezagent.URI.workspace("test-ws"),
    task_receiver_uri: Ezagent.URI.resource("test-ws", "kanban-task", "task-recv"),
    credential_owner_uri: Ezagent.URI.entity("test-ws", "user", "credential-owner"),
    repository_uri: Ezagent.URI.resource("test-ws", "git-repository", "my-repo"),
    provider_adapter: :github,
    provider_host: "github.com",
    external_id: "owner/repo",
    owner_path: "owner",
    base_ref: "main",
    visibility: :public,
    allowed_head_namespace: "feature/",
    enabled: true
  }

  setup do
    {:ok, binding} = TaskBinding.new(@valid_binding_attrs)
    {:ok, _} = Store.register_binding(binding)

    {:ok, intent} =
      AcceptIntent.new(%{
        binding_id: "bnd_auth_test",
        binding_generation: 1,
        external_task_id: "task-auth-1",
        source_task_uri: Ezagent.URI.resource("test-ws", "kanban-task", "task-src"),
        source_revision: "abc123",
        requested_head_ref: nil
      })

    {:ok, run} = Store.accept(intent)

    on_exit(fn -> Application.delete_env(:ezagent_plugin_git_workflow, :execution_seam) end)

    {:ok, binding: binding, run: run}
  end

  test "production default: seam unavailable leaves the run at accepted", %{
    run: run,
    binding: binding
  } do
    assert ExecutionSeam.implementation() == Unavailable

    assert {:error, :authorization_unavailable} = Authorization.authorize_run(run, binding)

    {:ok, unchanged} = Store.read_run(run.id)
    assert unchanged.status == "accepted"
    assert unchanged.state_version == 1
  end

  test "injected fake seam: authorize success transitions accepted -> authorized", %{
    run: run,
    binding: binding
  } do
    Application.put_env(:ezagent_plugin_git_workflow, :execution_seam, FakeExecutionSeam)

    assert {:ok, %WorkflowRun{status: "authorized", state_version: 2}} =
             Authorization.authorize_run(run, binding)
  end

  test "injected fake seam: not_authorized leaves the run at accepted", %{binding: binding} do
    Application.put_env(:ezagent_plugin_git_workflow, :execution_seam, FakeExecutionSeam)

    # FakeExecutionSeam denies on binding_id "bnd_denied" — build that run
    # struct directly (mirrors Store's own struct!(WorkflowRun, %{...})
    # idiom); Authorization.authorize_run/2 never reads the DB for `run`
    # itself, so no matching binding row needs to exist for this case.
    denied_run =
      struct!(WorkflowRun, %{
        id: "run_denied",
        binding_id: "bnd_denied",
        binding_generation: 1,
        external_task_id: "task-denied-1",
        workspace_uri: binding.workspace_uri,
        status: "accepted",
        state_version: 1,
        input_digest: "sha256:test",
        source_task_uri: Ezagent.URI.resource("test-ws", "kanban-task", "task-src"),
        source_revision: "abc123",
        requested_head_ref: nil,
        last_error_code: nil
      })

    assert {:error, :not_authorized} = Authorization.authorize_run(denied_run, binding)
  end

  test "refuses to authorize a run that is not accepted", %{run: run, binding: binding} do
    {:ok, authorized} = Store.transition(run.id, 1, "accepted", "authorized")

    assert {:error, {:invalid_run_status, "authorized"}} =
             Authorization.authorize_run(authorized, binding)
  end
end
