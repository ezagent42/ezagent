defmodule EzagentPluginGitWorkflow.StoreTest do
  use EzagentPluginGitWorkflow.ConnCase, async: false

  alias EzagentCore.Repo
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :store

  @valid_binding_attrs %{
    id: "bnd_store_test",
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

  defp insert_binding!(attrs \\ %{}) do
    merged = Map.merge(@valid_binding_attrs, attrs)
    {:ok, binding} = TaskBinding.new(merged)
    now = DateTime.utc_now()

    Repo.insert_all(
      "git_workflow_bindings",
      [
        %{
          id: binding.id,
          generation: binding.generation,
          workspace_uri: URI.to_string(binding.workspace_uri),
          task_receiver_uri: URI.to_string(binding.task_receiver_uri),
          credential_owner_uri: URI.to_string(binding.credential_owner_uri),
          repository_uri: URI.to_string(binding.repository_uri),
          provider_adapter: binding.provider_adapter,
          provider_host: binding.provider_host,
          external_id: binding.external_id,
          owner_path: binding.owner_path,
          base_ref: binding.base_ref,
          visibility: Atom.to_string(binding.visibility),
          allowed_head_namespace: binding.allowed_head_namespace,
          enabled: binding.enabled,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:id]
    )

    binding
  end

  @valid_run_attrs %{
    id: "run_store_1",
    binding_id: "bnd_store_test",
    binding_generation: 1,
    external_task_id: "task-ext-store-1",
    authenticated_principal_uri: URI.parse("entity://test-ws/agent/worker1"),
    status: "accepted",
    state_version: 1,
    input_digest: "sha256:abc123",
    source_task_uri: URI.parse("resource://test-ws/kanban-task/task-src"),
    source_revision: "abc123",
    requested_head_ref: "feature/test",
    last_error_code: nil
  }

  setup do
    insert_binding!()
    :ok
  end

  describe "claim/2" do
    test "inserts a new accepted run when no conflict exists" do
      insert_binding!(%{id: "bnd_claim_new", generation: 2})

      {:ok, run} = WorkflowRun.new(%{@valid_run_attrs | id: "run_claim_new", binding_id: "bnd_claim_new",
                     binding_generation: 2, external_task_id: "task-new-1"})

      assert {:ok, %WorkflowRun{status: "accepted", state_version: 1}} =
               Store.claim(run)
    end

    test "returns existing run for identical claim (idempotent)" do
      {:ok, run} = WorkflowRun.new(@valid_run_attrs)

      {:ok, inserted} = Store.claim(run)
      {:ok, reloaded} = Store.claim(run)

      assert inserted.id == reloaded.id
      assert inserted.status == reloaded.status
      assert inserted.state_version == reloaded.state_version
    end

    test "returns error on different digest for same unique key" do
      {:ok, run1} = WorkflowRun.new(@valid_run_attrs)

      run2_attrs = %{@valid_run_attrs | input_digest: "sha256:different",
                      source_revision: "xyz789"}
      {:ok, run2} = WorkflowRun.new(run2_attrs)

      {:ok, _inserted} = Store.claim(run1)
      assert {:error, :digest_conflict} = Store.claim(run2)
    end

    test "nil authenticated_principal returns error" do
      # Bypass struct validation to test the Store-level guard
      run = struct!(WorkflowRun, %{
        id: "run_no_principal",
        binding_id: "bnd_store_test",
        binding_generation: 1,
        external_task_id: "task-no-principal",
        authenticated_principal_uri: nil,
        status: "accepted",
        state_version: 1,
        input_digest: "sha256:abc",
        source_task_uri: URI.parse("resource://test-ws/kanban-task/task-src"),
        source_revision: nil,
        requested_head_ref: nil,
        last_error_code: nil
      })

      assert {:error, :authenticated_principal_required} = Store.claim(run)
    end

    test "disabled binding returns error" do
      insert_binding!(%{id: "bnd_disabled", enabled: false})
      {:ok, run} = WorkflowRun.new(%{@valid_run_attrs | id: "run_disabled_binding",
                binding_id: "bnd_disabled", external_task_id: "task-disabled"})

      assert {:error, :binding_disabled} = Store.claim(run)
    end
  end

  describe "transition/4 CAS" do
    setup do
      {:ok, run} = WorkflowRun.new(@valid_run_attrs)
      {:ok, inserted} = Store.claim(run)
      {:ok, run: inserted}
    end

    test "transitions from accepted to next status", %{run: run} do
      assert {:ok, %WorkflowRun{status: "workspace_ready", state_version: 2}} =
               Store.transition(run.id, 1, "accepted", "workspace_ready")
    end

    test "exact retry is idempotent", %{run: run} do
      {:ok, r1} = Store.transition(run.id, 1, "accepted", "workspace_ready")
      {:ok, r2} = Store.transition(run.id, 1, "accepted", "workspace_ready")

      assert r1.id == r2.id
      assert r1.state_version == r2.state_version
    end

    test "stale state_version returns error", %{run: run} do
      {:ok, _r1} = Store.transition(run.id, 1, "accepted", "workspace_ready")

      assert {:error, :stale_state_version} =
               Store.transition(run.id, 1, "accepted", "worker_ready")
    end

    test "wrong expected_status returns status conflict", %{run: run} do
      assert {:error, :workflow_state_conflict} =
               Store.transition(run.id, 1, "workspace_ready", "worker_ready")
    end

    test "non-existent run_id returns error" do
      assert {:error, :not_found} =
               Store.transition("nonexistent", 1, "accepted", "workspace_ready")
    end
  end

  describe "read_run/1" do
    setup do
      {:ok, run} = WorkflowRun.new(@valid_run_attrs)
      {:ok, inserted} = Store.claim(run)
      {:ok, run: inserted}
    end

    test "reads an existing run by id", %{run: run} do
      assert {:ok, %WorkflowRun{id: id}} = Store.read_run(run.id)
      assert id == run.id
    end

    test "returns error for unknown id" do
      assert {:error, :not_found} = Store.read_run("nonexistent")
    end
  end

  describe "register_binding/1" do
    test "inserts a valid binding" do
      {:ok, binding} = TaskBinding.new(%{@valid_binding_attrs | id: "bnd_register_test"})
      assert {:ok, %TaskBinding{id: "bnd_register_test"}} = Store.register_binding(binding)
    end

    test "rejects duplicate binding id" do
      {:ok, binding} = TaskBinding.new(%{@valid_binding_attrs | id: "bnd_dup"})
      {:ok, _} = Store.register_binding(binding)
      assert {:error, {:binding_exists, "bnd_dup"}} = Store.register_binding(binding)
    end
  end

  describe "disable_binding/1" do
    test "disables an existing enabled binding" do
      {:ok, binding} = TaskBinding.new(%{@valid_binding_attrs | id: "bnd_to_disable"})
      {:ok, _} = Store.register_binding(binding)
      assert {:ok, %TaskBinding{enabled: false}} = Store.disable_binding("bnd_to_disable")
    end

    test "returns error for unknown binding id" do
      assert {:error, :not_found} = Store.disable_binding("nonexistent")
    end
  end

  describe "read_binding/1" do
    test "reads an existing binding by id" do
      {:ok, binding} = TaskBinding.new(%{@valid_binding_attrs | id: "bnd_read"})
      {:ok, _} = Store.register_binding(binding)
      assert {:ok, %TaskBinding{id: "bnd_read"}} = Store.read_binding("bnd_read")
    end

    test "returns error for unknown id" do
      assert {:error, :not_found} = Store.read_binding("nonexistent")
    end
  end
end
