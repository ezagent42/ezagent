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
    workspace_uri: Ezagent.URI.workspace("test-ws"),
    task_receiver_uri: Ezagent.URI.resource("test-ws", "kanban-task", "task-recv"),
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

  defp insert_binding!(attrs \\ %{}) do
    merged = Map.merge(@valid_binding_attrs, attrs)
    {:ok, binding} = TaskBinding.new(merged)
    {:ok, _} = Store.register_binding(binding)
    binding
  end

  @accept_attrs %{
    binding_id: "bnd_store_test",
    binding_generation: 1,
    external_task_id: "task-accept-1",
    source_task_uri: URI.parse("resource://test-ws/kanban-task/task-src"),
    source_revision: "abc123",
    requested_head_ref: "feature/test"
  }

  setup do
    insert_binding!()
    :ok
  end

  describe "accept/1" do
    test "creates an accepted run with server-generated fields" do
      assert {:ok, %WorkflowRun{status: "accepted", state_version: 1}} =
               Store.accept(@accept_attrs)

      # Verify the run id is deterministic
      expected_id = WorkflowRun.generate_id("bnd_store_test", 1, "task-accept-1")

      {:ok, run} = Store.accept(@accept_attrs)
      assert run.id == expected_id
    end

    test "idempotent: same accept returns the same run" do
      {:ok, r1} = Store.accept(@accept_attrs)
      {:ok, r2} = Store.accept(@accept_attrs)

      assert r1.id == r2.id
      assert r1.status == r2.status
      assert r1.state_version == r2.state_version
      assert r1.input_digest == r2.input_digest
    end

    test "different source revision on same unique key returns digest_conflict" do
      {:ok, _r1} = Store.accept(@accept_attrs)

      diff = %{@accept_attrs | source_revision: "xyz-different"}

      assert {:error, :digest_conflict} = Store.accept(diff)
    end

    test "unknown binding returns binding_not_found" do
      attrs = %{@accept_attrs | binding_id: "nonexistent"}
      assert {:error, :binding_not_found} = Store.accept(attrs)
    end

    test "disabled binding returns binding_disabled" do
      insert_binding!(%{id: "bnd_disabled", enabled: false})

      attrs = %{@accept_attrs | binding_id: "bnd_disabled",
                external_task_id: "task-disabled"}

      assert {:error, :binding_disabled} = Store.accept(attrs)
    end

    test "server-generates id deterministically from unique key" do
      {:ok, run} = Store.accept(@accept_attrs)

      expected_id = WorkflowRun.generate_id("bnd_store_test", 1, "task-accept-1")
      assert run.id == expected_id
    end

    test "server-generates digest from intent fields" do
      {:ok, run} = Store.accept(@accept_attrs)

      expected_digest = WorkflowRun.compute_digest(@accept_attrs)
      assert run.input_digest == expected_digest
      assert String.starts_with?(run.input_digest, "sha256:")
    end

    test "only one row in DB after accept" do
      {:ok, _} = Store.accept(@accept_attrs)

      [[count]] =
        Repo.query!(
          "SELECT COUNT(*) FROM git_workflow_runs WHERE binding_id = $1 AND external_task_id = $2",
          ["bnd_store_test", "task-accept-1"]
        ).rows

      assert count == 1
    end
  end

  describe "transition/4 CAS" do
    setup do
      {:ok, run} = Store.accept(@accept_attrs)
      {:ok, run: run}
    end

    test "transitions from accepted to next status", %{run: run} do
      assert {:ok, %WorkflowRun{status: "workspace_ready", state_version: 2}} =
               Store.transition(run.id, 1, "accepted", "workspace_ready")
    end

    test "exact retry is idempotent", %{run: run} do
      {:ok, r1} = Store.transition(run.id, 1, "accepted", "workspace_ready")
      {:ok, r2} = Store.transition(run.id, 1, "accepted", "workspace_ready")

      assert r1.state_version == r2.state_version
      assert r1.status == r2.status
    end

    test "stale state_version returns error", %{run: run} do
      {:ok, _} = Store.transition(run.id, 1, "accepted", "workspace_ready")

      assert {:error, :stale_state_version} =
               Store.transition(run.id, 1, "accepted", "worker_ready")
    end

    test "wrong expected_status returns conflict", %{run: run} do
      assert {:error, :workflow_state_conflict} =
               Store.transition(run.id, 1, "workspace_ready", "worker_ready")
    end

    test "non-existent run_id returns not_found" do
      assert {:error, :not_found} =
               Store.transition("nonexistent", 1, "accepted", "workspace_ready")
    end
  end

  describe "read_run/1" do
    setup do
      {:ok, run} = Store.accept(@accept_attrs)
      {:ok, run: run}
    end

    test "reads by id", %{run: run} do
      assert {:ok, %WorkflowRun{id: id}} = Store.read_run(run.id)
      assert id == run.id
    end

    test "returns error for unknown id" do
      assert {:error, :not_found} = Store.read_run("nonexistent")
    end
  end

  describe "register_binding/1" do
    test "inserts a valid binding" do
      {:ok, binding} = TaskBinding.new(%{@valid_binding_attrs | id: "bnd_register"})
      assert {:ok, %TaskBinding{id: "bnd_register"}} = Store.register_binding(binding)
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
    test "reads an existing binding" do
      {:ok, binding} = TaskBinding.new(%{@valid_binding_attrs | id: "bnd_read"})
      {:ok, _} = Store.register_binding(binding)
      assert {:ok, %TaskBinding{id: "bnd_read"}} = Store.read_binding("bnd_read")
    end

    test "returns error for unknown id" do
      assert {:error, :not_found} = Store.read_binding("nonexistent")
    end
  end
end
