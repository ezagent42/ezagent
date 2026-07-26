defmodule EzagentPluginGitWorkflow.AuthorizationTest do
  use EzagentPluginGitWorkflow.ConnCase, async: false

  alias EzagentPluginGitWorkflow.AcceptIntent
  alias EzagentPluginGitWorkflow.Authorization
  alias EzagentPluginGitWorkflow.ExecutionSeamTestDelegate
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

    on_exit(fn -> ExecutionSeamTestDelegate.clear_backend() end)

    {:ok, binding: binding, run: run}
  end

  test "production default: seam unavailable leaves the run at accepted", %{
    run: run,
    binding: binding
  } do
    # No backend installed for this process — ExecutionSeam.implementation/0
    # resolves to the test delegate (compile-time fixed), which itself falls
    # back to Unavailable when nothing was injected. The assertion below is
    # therefore a behavioral proof of the fail-closed default, not a check
    # on which module identity implementation/0 happens to return.
    assert {:error, :authorization_unavailable} = Authorization.authorize_run(run, binding)

    {:ok, unchanged} = Store.read_run(run.id)
    assert unchanged.status == "accepted"
    assert unchanged.state_version == 1
  end

  test "injected fake seam: authorize success transitions accepted -> authorized", %{
    run: run,
    binding: binding
  } do
    ExecutionSeamTestDelegate.put_backend(FakeExecutionSeam)

    assert {:ok, %WorkflowRun{status: "authorized", state_version: 2}} =
             Authorization.authorize_run(run, binding)
  end

  test "injected fake seam: not_authorized leaves a REAL persisted run at accepted" do
    ExecutionSeamTestDelegate.put_backend(FakeExecutionSeam)

    # FakeExecutionSeam denies on binding_id "bnd_denied" — register a real
    # binding under that id and accept a real intent against it through the
    # same Store path every other run in this file goes through, so the run
    # being denied here is an actual persisted row (mirrors the unavailable
    # -path test above), not a struct that was never written to the database.
    {:ok, denied_binding} = TaskBinding.new(%{@valid_binding_attrs | id: "bnd_denied"})
    {:ok, _} = Store.register_binding(denied_binding)

    {:ok, intent} =
      AcceptIntent.new(%{
        binding_id: "bnd_denied",
        binding_generation: 1,
        external_task_id: "task-denied-1",
        source_task_uri: Ezagent.URI.resource("test-ws", "kanban-task", "task-src"),
        source_revision: "abc123",
        requested_head_ref: nil
      })

    {:ok, denied_run} = Store.accept(intent)

    assert {:error, :not_authorized} = Authorization.authorize_run(denied_run, denied_binding)

    {:ok, unchanged} = Store.read_run(denied_run.id)
    assert unchanged.status == "accepted"
    assert unchanged.state_version == 1
  end

  test "refuses to authorize a run that is not accepted", %{run: run, binding: binding} do
    {:ok, authorized} = Store.transition(run.id, 1, "accepted", "authorized")

    assert {:error, {:invalid_run_status, "authorized"}} =
             Authorization.authorize_run(authorized, binding)
  end
end
