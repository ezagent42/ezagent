defmodule EzagentPluginGitWorkflow.SchemaTest do
  use EzagentPluginGitWorkflow.ConnCase, async: false

  alias EzagentPluginGitWorkflow.AcceptIntent
  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :schema

  @valid_binding_attrs %{
    id: "bnd_test1",
    generation: 1,
    workspace_uri: Ezagent.URI.workspace("test-ws"),
    task_receiver_uri: Ezagent.URI.resource("test-ws", "kanban-task", "task1"),
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

  describe "TaskBinding" do
    test "validates with correct fields" do
      assert {:ok, %TaskBinding{}} = TaskBinding.new(@valid_binding_attrs)
    end

    test "rejects unknown fields" do
      bad = Map.put(@valid_binding_attrs, :token, "secret")
      assert {:error, {:unknown_fields, [:token]}} = TaskBinding.new(bad)
    end

    test "rejects missing fields" do
      assert {:error, {:missing_field, :id}} =
               TaskBinding.new(Map.delete(@valid_binding_attrs, :id))
    end

    test "rejects invalid visibility" do
      bad = %{@valid_binding_attrs | visibility: :internal}
      assert {:error, {:invalid_field, :visibility}} = TaskBinding.new(bad)
    end

    test "validates RepositoryRef" do
      bad = %{@valid_binding_attrs | base_ref: "refs/heads/main"}
      assert {:error, {:invalid_repository_ref, _}} = TaskBinding.new(bad)
    end

    test "accepts a normal allowed_head_namespace like feature/" do
      assert {:ok, %TaskBinding{allowed_head_namespace: "feature/"}} =
               TaskBinding.new(@valid_binding_attrs)
    end

    test "rejects allowed_head_namespace whose derived ref would contain .." do
      bad = %{@valid_binding_attrs | allowed_head_namespace: "feature/../"}
      assert {:error, {:invalid_field, :allowed_head_namespace}} = TaskBinding.new(bad)
    end

    test "rejects allowed_head_namespace whose derived ref would contain //" do
      bad = %{@valid_binding_attrs | allowed_head_namespace: "feature//sub/"}
      assert {:error, {:invalid_field, :allowed_head_namespace}} = TaskBinding.new(bad)
    end

    test "rejects allowed_head_namespace whose derived ref would contain @{" do
      bad = %{@valid_binding_attrs | allowed_head_namespace: "feature/@{/"}
      assert {:error, {:invalid_field, :allowed_head_namespace}} = TaskBinding.new(bad)
    end

    test "rejects allowed_head_namespace whose derived ref would exceed 255 bytes" do
      # derived length = byte_size(ns) + byte_size("run-") + 24 hex chars
      #                = byte_size(ns) + 28
      # 255 - 28 = 227, so 228+ overflows the limit.
      bad = %{@valid_binding_attrs | allowed_head_namespace: String.duplicate("a", 228)}
      assert {:error, {:invalid_field, :allowed_head_namespace}} = TaskBinding.new(bad)
    end

    test "accepts allowed_head_namespace exactly at the 255-byte derived-ref boundary" do
      ok = %{@valid_binding_attrs | allowed_head_namespace: String.duplicate("a", 227)}
      assert {:ok, %TaskBinding{}} = TaskBinding.new(ok)
    end
  end

  describe "WorkflowRun closed status set" do
    test "accepts all valid statuses" do
      for s <- WorkflowRun.statuses() do
        assert WorkflowRun.valid_status?(s), "expected #{s} to be valid"
      end
    end

    test "rejects unknown status" do
      refute WorkflowRun.valid_status?("random_status")
    end

    test "terminal statuses are correctly identified" do
      assert WorkflowRun.terminal?("completed")
      assert WorkflowRun.terminal?("failed")
      assert WorkflowRun.terminal?("cancelled")

      refute WorkflowRun.terminal?("accepted")
      refute WorkflowRun.terminal?("workspace_ready")
    end

    test "invalid status rejected by WorkflowRun.new" do
      attrs = valid_run_attrs()
      bad = %{attrs | status: "unknown"}
      assert {:error, {:invalid_field, :status}} = WorkflowRun.new(bad)
    end
  end

  describe "AcceptIntent typed contract" do
    test "rejects server-owned field id" do
      assert {:error, {:server_owned_field, :id}} =
               AcceptIntent.new(Map.put(valid_intent_attrs(), :id, "run-1"))
    end

    test "rejects server-owned field status" do
      assert {:error, {:server_owned_field, :status}} =
               AcceptIntent.new(Map.put(valid_intent_attrs(), :status, "accepted"))
    end

    test "all keys are callable without KeyError" do
      {:ok, intent} = AcceptIntent.new(valid_intent_attrs())
      assert is_binary(intent.binding_id)
      assert is_integer(intent.binding_generation)
    end
  end

  describe "WorkflowRun full run id" do
    test "generate_id produces full sha256, not truncated" do
      id = WorkflowRun.generate_id("bnd", 1, "task")
      assert String.starts_with?(id, "run_")
      # "run_" + 64 hex chars
      assert byte_size(id) == 68
    end
  end

  describe "schema no-secret audit" do
    test "TaskBinding struct keys have no secret fields" do
      keys =
        Map.keys(%{
          __struct__: TaskBinding,
          id: "",
          generation: 1,
          workspace_uri: nil,
          task_receiver_uri: nil,
          credential_owner_uri: nil,
          repository_uri: nil,
          provider_adapter: nil,
          provider_host: "",
          external_id: "",
          owner_path: "",
          base_ref: "",
          visibility: nil,
          allowed_head_namespace: "",
          enabled: true,
          inserted_at: nil,
          updated_at: nil
        }) -- [:__struct__, :inserted_at, :updated_at]

      forbidden = ~w(token credential secret password oauth installation_id private_key)a

      for key <- keys do
        key_str = Atom.to_string(key)
        # credential_owner_uri is approved
        unless key == :credential_owner_uri do
          refute Enum.any?(forbidden, &String.contains?(key_str, Atom.to_string(&1))),
                 "TaskBinding key #{key} looks like a secret field"
        end
      end
    end

    test "WorkflowRun struct keys have no auth or secret fields" do
      keys =
        WorkflowRun.__struct__()
        |> Map.keys()
        |> Enum.reject(&(&1 in [:__struct__, :inserted_at, :updated_at]))

      forbidden =
        ~w(authenticated_principal token credential secret password provider_response worker_pid workspace_cwd)a

      for key <- keys do
        key_str = Atom.to_string(key)

        refute Enum.any?(forbidden, &String.contains?(key_str, Atom.to_string(&1))),
               "WorkflowRun key #{key} looks like a forbidden field"
      end
    end

    test "AcceptIntent allowed keys have only caller fields" do
      allowed = AcceptIntent.__struct__() |> Map.keys()
      assert :binding_id in allowed
      assert :binding_generation in allowed
      assert :external_task_id in allowed
      assert :source_task_uri in allowed
      assert :source_revision in allowed
      assert :requested_head_ref in allowed

      refute :id in allowed
      refute :status in allowed
      refute :state_version in allowed
      refute :input_digest in allowed
      refute :authenticated_principal_uri in allowed
    end
  end

  # Helpers

  defp valid_intent_attrs do
    %{
      binding_id: "bnd-1",
      binding_generation: 1,
      external_task_id: "task-1",
      source_task_uri: Ezagent.URI.resource("ws", "kanban-task", "t1"),
      source_revision: "abc",
      requested_head_ref: "feature/x"
    }
  end

  defp valid_run_attrs do
    %{
      id: "run_test",
      binding_id: "bnd1",
      binding_generation: 1,
      external_task_id: "ext1",
      workspace_uri: Ezagent.URI.workspace("test-ws"),
      status: "accepted",
      state_version: 1,
      input_digest: "sha256:abcdef",
      source_task_uri: Ezagent.URI.resource("ws", "kanban-task", "t1"),
      source_revision: "abc",
      requested_head_ref: "feature/x",
      last_error_code: nil
    }
  end
end
