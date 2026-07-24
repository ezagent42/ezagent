defmodule EzagentPluginGitWorkflow.SchemaTest do
  use EzagentPluginGitWorkflow.ConnCase, async: false

  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :schema

  @valid_binding_attrs %{
    id: "bnd_test1",
    generation: 1,
    workspace_uri: Ezagent.URI.workspace("test-ws"),
    task_receiver_uri: Ezagent.URI.resource("test-ws", "kanban-task", "task1"),
    credential_owner_uri: Ezagent.URI.entity("test-ws", "user", "admin"),
    repository_uri: Ezagent.URI.resource("test-ws", "git-repository", "my-repo"),
    provider_adapter: :github_test_adapter,
    provider_host: "github.com",
    external_id: "owner/repo",
    owner_path: "owner",
    base_ref: "main",
    visibility: :public,
    allowed_head_namespace: "feature/",
    enabled: true
  }

  describe "TaskBinding" do
    test "validates with correct fields" do
      assert {:ok, %TaskBinding{}} = TaskBinding.new(@valid_binding_attrs)
    end

    test "rejects unknown fields (no secret/credential/token)" do
      bad = Map.put(@valid_binding_attrs, :token, "secret-value")
      assert {:error, {:unknown_fields, [:token]}} = TaskBinding.new(bad)
    end

    test "rejects extra fields like installation_id" do
      bad = Map.put(@valid_binding_attrs, :installation_id, 123)
      assert {:error, _} = TaskBinding.new(bad)
    end

    test "rejects invalid visibility" do
      bad = %{@valid_binding_attrs | visibility: :internal}
      assert {:error, {:invalid_field, :visibility}} = TaskBinding.new(bad)
    end

    test "rejects empty id" do
      bad = %{@valid_binding_attrs | id: ""}
      assert {:error, {:invalid_field, :id}} = TaskBinding.new(bad)
    end

    test "validates RepositoryRef through canonical RepositoryRef.new/1" do
      # base_ref with "refs/" prefix is invalid per RepositoryRef.valid_ref?/1
      bad = %{@valid_binding_attrs | base_ref: "refs/heads/main"}
      assert {:error, {:invalid_repository_ref, _}} = TaskBinding.new(bad)
    end
  end

  describe "WorkflowRun" do
    test "has server-owned fields (id, status, state_version, input_digest)" do
      attrs = %{
        id: "run_srv",
        binding_id: "bnd1",
        binding_generation: 1,
        external_task_id: "ext1",
        status: "accepted",
        state_version: 1,
        input_digest: "sha256:abcdef",
        source_task_uri: URI.parse("resource://ws/kanban-task/t1"),
        source_revision: "abc",
        requested_head_ref: "feature/x",
        last_error_code: nil
      }

      assert {:ok, %WorkflowRun{}} = WorkflowRun.new(attrs)
    end

    test "rejects status other than accepted" do
      attrs = %{
        id: "run_bad",
        binding_id: "bnd1",
        binding_generation: 1,
        external_task_id: "ext1",
        status: "completed",
        state_version: 1,
        input_digest: "sha256:abc",
        source_task_uri: URI.parse("resource://ws/kanban-task/t1"),
        source_revision: nil,
        requested_head_ref: nil,
        last_error_code: nil
      }

      assert {:error, {:invalid_field, :status}} = WorkflowRun.new(attrs)
    end

    test "generates deterministic id from unique key" do
      id1 = WorkflowRun.generate_id("bnd1", 1, "task1")
      id2 = WorkflowRun.generate_id("bnd1", 1, "task1")
      id3 = WorkflowRun.generate_id("bnd1", 1, "task2")

      assert is_binary(id1)
      assert id1 == id2
      assert id1 != id3
      assert String.starts_with?(id1, "run_")
    end

    test "computes digest from intent fields" do
      fields = %{
        binding_id: "bnd1",
        binding_generation: 1,
        external_task_id: "ext1",
        source_task_uri: URI.parse("resource://ws/kanban-task/t1"),
        source_revision: "abc",
        requested_head_ref: "feature/x"
      }

      d1 = WorkflowRun.compute_digest(fields)
      d2 = WorkflowRun.compute_digest(fields)
      d3 = WorkflowRun.compute_digest(Map.put(fields, :source_revision, "xyz"))

      assert is_binary(d1)
      assert String.starts_with?(d1, "sha256:")
      assert d1 == d2
      assert d1 != d3
    end
  end

  describe "schema no-secret audit" do
    test "TaskBinding struct has no secret-value fields" do
      binding_path = Path.join(__DIR__, "../../lib/ezagent_plugin_git_workflow/task_binding.ex") |> Path.expand()
      content = File.read!(binding_path)

      refute content =~ ~r/field\s+:token\b/
      refute content =~ ~r/field\s+: installation_id\b/
    end

    test "WorkflowRun has no authenticated_principal or credential field definitions" do
      run_path = Path.join(__DIR__, "../../lib/ezagent_plugin_git_workflow/workflow_run.ex") |> Path.expand()
      content = File.read!(run_path)

      refute content =~ ~r/\s:authenticated_principal\b/
      refute content =~ ~r/\s:token\b/
      refute content =~ ~r/\s:credential\b/
      refute content =~ ~r/\s:secret\b/
    end
  end
end
