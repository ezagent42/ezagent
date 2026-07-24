defmodule EzagentPluginGitWorkflow.SchemaTest do
  use EzagentPluginGitWorkflow.ConnCase, async: false

  alias EzagentCore.Repo
  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :schema

  describe "TaskBinding struct" do
    test "validates required fields, ignoring timestamps" do
      attrs = %{
        id: "bnd_test1",
        generation: 1,
        workspace_uri: URI.parse("workspace://test-ws"),
        task_receiver_uri: URI.parse("resource://test-ws/kanban-task/task1"),
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

      assert {:ok, %TaskBinding{}} = TaskBinding.new(attrs)
    end

    test "rejects credential/token/secret fields" do
      attrs = %{
        id: "bnd_secret",
        generation: 1,
        workspace_uri: URI.parse("workspace://test-ws"),
        task_receiver_uri: URI.parse("resource://test-ws/kanban-task/task1"),
        credential_owner_uri: URI.parse("entity://test-ws/user/admin"),
        repository_uri: URI.parse("resource://test-ws/git-repository/my-repo"),
        provider_adapter: "github",
        provider_host: "github.com",
        external_id: "owner/repo",
        owner_path: "owner",
        base_ref: "main",
        visibility: :public,
        allowed_head_namespace: "feature/",
        enabled: true,
        token: "should-not-be-here",
        installation_id: 123
      }

      assert {:error, _reason} = TaskBinding.new(attrs)
    end

    test "rejects arbitrary non-governed fields" do
      attrs = %{
        id: "bnd_extra",
        generation: 1,
        workspace_uri: URI.parse("workspace://test-ws"),
        task_receiver_uri: URI.parse("resource://test-ws/kanban-task/task1"),
        credential_owner_uri: URI.parse("entity://test-ws/user/admin"),
        repository_uri: URI.parse("resource://test-ws/git-repository/my-repo"),
        provider_adapter: "github",
        provider_host: "github.com",
        external_id: "owner/repo",
        owner_path: "owner",
        base_ref: "main",
        visibility: :public,
        allowed_head_namespace: "feature/",
        enabled: true,
        extra_arbitrary: "not-allowed"
      }

      assert {:error, _reason} = TaskBinding.new(attrs)
    end

    test "rejects invalid visibility values" do
      attrs = %{
        id: "bnd_vis",
        generation: 1,
        workspace_uri: URI.parse("workspace://test-ws"),
        task_receiver_uri: URI.parse("resource://test-ws/kanban-task/task1"),
        credential_owner_uri: URI.parse("entity://test-ws/user/admin"),
        repository_uri: URI.parse("resource://test-ws/git-repository/my-repo"),
        provider_adapter: "github",
        provider_host: "github.com",
        external_id: "owner/repo",
        owner_path: "owner",
        base_ref: "main",
        visibility: :internal,
        allowed_head_namespace: "feature/",
        enabled: true
      }

      assert {:error, _reason} = TaskBinding.new(attrs)
    end

    test "rejects empty id" do
      attrs = %{
        id: "",
        generation: 1,
        workspace_uri: URI.parse("workspace://test-ws"),
        task_receiver_uri: URI.parse("resource://test-ws/kanban-task/task1"),
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

      assert {:error, _reason} = TaskBinding.new(attrs)
    end
  end

  describe "WorkflowRun struct" do
    test "validates required fields" do
      attrs = %{
        id: "run_test1",
        binding_id: "bnd_test1",
        binding_generation: 1,
        external_task_id: "task-ext-1",
        authenticated_principal_uri: URI.parse("entity://test-ws/agent/worker1"),
        status: "accepted",
        state_version: 1,
        input_digest: "sha256:abc123",
        source_task_uri: URI.parse("resource://test-ws/kanban-task/task1"),
        source_revision: "abc123",
        requested_head_ref: "feature/test",
        last_error_code: nil
      }

      assert {:ok, %WorkflowRun{}} = WorkflowRun.new(attrs)
    end

    test "rejects secret/provider-private fields" do
      attrs = %{
        id: "run_secret",
        binding_id: "bnd_test1",
        binding_generation: 1,
        external_task_id: "task-ext-2",
        authenticated_principal_uri: URI.parse("entity://test-ws/agent/worker1"),
        status: "accepted",
        state_version: 1,
        input_digest: "sha256:abc123",
        source_task_uri: URI.parse("resource://test-ws/kanban-task/task1"),
        source_revision: "abc123",
        requested_head_ref: "feature/test",
        last_error_code: nil,
        provider_response: %{pr_url: "https://..."}
      }

      assert {:error, _reason} = WorkflowRun.new(attrs)
    end

    test "rejects lifecycle-result fields" do
      attrs = %{
        id: "run_lifecycle",
        binding_id: "bnd_test1",
        binding_generation: 1,
        external_task_id: "task-ext-3",
        authenticated_principal_uri: URI.parse("entity://test-ws/agent/worker1"),
        status: "accepted",
        state_version: 1,
        input_digest: "sha256:abc123",
        source_task_uri: URI.parse("resource://test-ws/kanban-task/task1"),
        source_revision: "abc123",
        requested_head_ref: "feature/test",
        last_error_code: nil,
        worker_pid: "pid-123",
        workspace_cwd: "/tmp/ws"
      }

      assert {:error, _reason} = WorkflowRun.new(attrs)
    end

    test "rejects status not accepted" do
      attrs = %{
        id: "run_bad_status",
        binding_id: "bnd_test1",
        binding_generation: 1,
        external_task_id: "task-ext-4",
        authenticated_principal_uri: URI.parse("entity://test-ws/agent/worker1"),
        status: "completed",
        state_version: 1,
        input_digest: "sha256:abc123",
        source_task_uri: URI.parse("resource://test-ws/kanban-task/task1"),
        source_revision: "abc123",
        requested_head_ref: "feature/test",
        last_error_code: nil
      }

      assert {:error, _reason} = WorkflowRun.new(attrs)
    end
  end

  describe "schema field audit" do
    test "TaskBinding has no secret value fields in its struct definition" do
      fields = TaskBinding.__struct__() |> Map.keys()
      # credential_owner_uri is an approved URI-pointer field, not a credential value.
      forbidden = ~w(token secret password oauth installation_id private_key)a

      for field <- fields do
        field_str = Atom.to_string(field)
        refute Enum.any?(forbidden, &String.contains?(field_str, Atom.to_string(&1))),
               "field #{field} looks like a secret-value field"
      end
    end

    test "WorkflowRun has no secret/provider-private fields in its struct definition" do
      fields = WorkflowRun.__struct__() |> Map.keys()
      # credential_owner_uri is in the binding (not run); exclude it here.
      forbidden = ~w(token secret password provider_response raw_ worker_pid workspace_cwd)a

      for field <- fields do
        field_str = Atom.to_string(field)
        refute Enum.any?(forbidden, &String.contains?(field_str, Atom.to_string(&1))),
               "field #{field} looks like a secret/provider-private value field"
      end
    end
  end
end
