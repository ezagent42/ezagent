defmodule EzagentPluginGitWorkflow.AuthorityTest do
  use EzagentPluginGitWorkflow.ConnCase, async: false

  alias EzagentCore.Repo
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :authority

  @binding_attrs %{
    id: "bnd_auth_test",
    generation: 1,
    workspace_uri: URI.parse("workspace://test-ws"),
    task_receiver_uri: URI.parse("resource://test-ws/kanban-task/task-recv"),
    credential_owner_uri: URI.parse("entity://test-ws/user/admin"),
    repository_uri: URI.parse("resource://test-ws/git-repository/my-repo"),
    provider_adapter: "github",
    provider_host: "github.com",
    external_id: "owner/repo",
    owner_path: "owner",
    base_ref: "main",
    visibility: :public,
    allowed_head_namespace: "feature/",
    enabled: true
  }

  setup do
    {:ok, binding} = TaskBinding.new(@binding_attrs)
    {:ok, _} = Store.register_binding(binding)
    :ok
  end

  describe "authenticated_principal enforcement" do
    test "missing authenticated_principal returns error with zero run side effect" do
      run = struct!(WorkflowRun, %{
        id: "run-no-principal",
        binding_id: "bnd_auth_test",
        binding_generation: 1,
        external_task_id: "task-no-principal",
        authenticated_principal_uri: nil,
        status: "accepted",
        state_version: 1,
        input_digest: "sha256:abc",
        source_task_uri: URI.parse("resource://test-ws/kanban-task/task-src"),
        source_revision: "abc",
        requested_head_ref: "feature/x",
        last_error_code: nil
      })

      assert {:error, :authenticated_principal_required} = Store.claim(run)

      # Zero runs created
      [[count]] =
        Repo.query!(
          "SELECT COUNT(*) FROM git_workflow_runs WHERE external_task_id = $1",
          ["task-no-principal"]
        ).rows

      assert count == 0
    end

    test "valid authenticated_principal creates run" do
      {:ok, run} = WorkflowRun.new(%{
        id: "run-with-principal",
        binding_id: "bnd_auth_test",
        binding_generation: 1,
        external_task_id: "task-with-principal",
        authenticated_principal_uri: URI.parse("entity://test-ws/agent/worker1"),
        status: "accepted",
        state_version: 1,
        input_digest: "sha256:abc",
        source_task_uri: URI.parse("resource://test-ws/kanban-task/task-src"),
        source_revision: "abc",
        requested_head_ref: "feature/x",
        last_error_code: nil
      })

      assert {:ok, _run} = Store.claim(run)
    end
  end

  describe "binding governance" do
    test "claim with unknown binding returns error" do
      {:ok, run} = WorkflowRun.new(%{
        id: "run-unknown-binding",
        binding_id: "nonexistent-binding",
        binding_generation: 1,
        external_task_id: "task-unknown",
        authenticated_principal_uri: URI.parse("entity://test-ws/agent/worker1"),
        status: "accepted",
        state_version: 1,
        input_digest: "sha256:abc",
        source_task_uri: URI.parse("resource://test-ws/kanban-task/task-src"),
        source_revision: "abc",
        requested_head_ref: "feature/x",
        last_error_code: nil
      })

      assert {:error, :binding_not_found} = Store.claim(run)
    end

    test "claim with disabled binding returns error" do
      {:ok, disabled} = TaskBinding.new(%{@binding_attrs | id: "bnd_disabled_auth",
        enabled: false})
      {:ok, _} = Store.register_binding(disabled)

      {:ok, run} = WorkflowRun.new(%{
        id: "run-disabled-binding",
        binding_id: "bnd_disabled_auth",
        binding_generation: 1,
        external_task_id: "task-disabled-auth",
        authenticated_principal_uri: URI.parse("entity://test-ws/agent/worker1"),
        status: "accepted",
        state_version: 1,
        input_digest: "sha256:abc",
        source_task_uri: URI.parse("resource://test-ws/kanban-task/task-src"),
        source_revision: "abc",
        requested_head_ref: "feature/x",
        last_error_code: nil
      })

      assert {:error, :binding_disabled} = Store.claim(run)
    end
  end

  describe "claim side-effect audit" do
    test "authorized claim produces only an accepted run, zero other effects" do
      {:ok, run} = WorkflowRun.new(%{
        id: "run-audit",
        binding_id: "bnd_auth_test",
        binding_generation: 1,
        external_task_id: "task-audit",
        authenticated_principal_uri: URI.parse("entity://test-ws/agent/worker1"),
        status: "accepted",
        state_version: 1,
        input_digest: "sha256:abc",
        source_task_uri: URI.parse("resource://test-ws/kanban-task/task-src"),
        source_revision: "abc",
        requested_head_ref: "feature/x",
        last_error_code: nil
      })

      assert {:ok, %WorkflowRun{status: "accepted", state_version: 1}} =
               Store.claim(run)

      # Single row created
      [[count]] =
        Repo.query!(
          "SELECT COUNT(*) FROM git_workflow_runs WHERE external_task_id = $1",
          ["task-audit"]
        ).rows

      assert count == 1

      # Status is exactly "accepted" — no workspace/worker/authority provisioning
      [[status]] =
        Repo.query!(
          "SELECT status FROM git_workflow_runs WHERE external_task_id = $1",
          ["task-audit"]
        ).rows

      assert status == "accepted"
    end
  end
end
