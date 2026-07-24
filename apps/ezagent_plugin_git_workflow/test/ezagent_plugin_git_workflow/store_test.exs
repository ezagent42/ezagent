defmodule EzagentPluginGitWorkflow.StoreTest do
  use EzagentPluginGitWorkflow.ConnCase, async: false

  alias EzagentCore.Repo
  alias EzagentPluginGitWorkflow.AcceptIntent
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :store

  @valid_binding_attrs %{
    id: "bnd_store_test",
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

  defp insert_binding!(attrs \\ %{}) do
    merged = Map.merge(@valid_binding_attrs, attrs)
    {:ok, binding} = TaskBinding.new(merged)
    {:ok, _} = Store.register_binding(binding)
    binding
  end

  defp build_intent(attrs \\ %{}) do
    defaults = %{
      binding_id: "bnd_store_test",
      binding_generation: 1,
      external_task_id: "task-accept-1",
      source_task_uri: Ezagent.URI.resource("test-ws", "kanban-task", "task-src"),
      source_revision: "abc123",
      requested_head_ref: "feature/test"
    }

    {:ok, intent} = Map.merge(defaults, attrs) |> AcceptIntent.new()
    intent
  end

  setup do
    insert_binding!()
    :ok
  end

  describe "accept/1" do
    test "accepts typed AcceptIntent, returns run with server-generated fields" do
      intent = build_intent()

      assert {:ok, %WorkflowRun{status: "accepted", state_version: 1}} =
               Store.accept(intent)
    end

    test "run id is full sha256 (no truncation)" do
      intent = build_intent()
      {:ok, run} = Store.accept(intent)

      expected_prefix = "run_"
      assert String.starts_with?(run.id, expected_prefix)
      # Full sha256 hex = 64 chars + "run_" prefix = 68 chars
      assert byte_size(run.id) == 4 + 64
    end

    test "idempotent: same intent returns same run" do
      intent = build_intent()
      {:ok, r1} = Store.accept(intent)
      {:ok, r2} = Store.accept(intent)

      assert r1.id == r2.id
      assert r1.input_digest == r2.input_digest
      assert r1.state_version == r2.state_version
    end

    test "different digest on same unique key returns digest_conflict" do
      i1 = build_intent(%{external_task_id: "task-digest-conflict"})
      i2 = build_intent(%{external_task_id: "task-digest-conflict", source_revision: "xyz"})

      {:ok, _} = Store.accept(i1)
      assert {:error, :digest_conflict} = Store.accept(i2)
    end

    test "unknown binding returns binding_not_found" do
      intent = build_intent(%{binding_id: "nonexistent"})
      assert {:error, :binding_not_found} = Store.accept(intent)
    end

    test "disabled binding returns binding_disabled" do
      insert_binding!(%{id: "bnd_disabled", enabled: false})
      intent = build_intent(%{binding_id: "bnd_disabled", external_task_id: "task-dis"})
      assert {:error, :binding_disabled} = Store.accept(intent)
    end

    test "binding_generation_mismatch returns error, zero DB effect" do
      intent = build_intent(%{binding_generation: 99, external_task_id: "task-gen-mismatch"})
      assert {:error, :binding_generation_mismatch} = Store.accept(intent)

      [[count]] =
        Repo.query!(
          "SELECT COUNT(*) FROM git_workflow_runs WHERE binding_id=$1",
          ["bnd_store_test"]
        ).rows

      assert count == 0
    end

    test "source workspace mismatch returns error" do
      intent =
        build_intent(%{
          external_task_id: "task-ws-mismatch",
          source_task_uri: Ezagent.URI.resource("other-ws", "kanban-task", "task-src")
        })

      assert {:error, :source_workspace_mismatch} = Store.accept(intent)
    end

    test "requested_head_ref outside allowed namespace returns error" do
      intent =
        build_intent(%{
          external_task_id: "task-bad-head",
          requested_head_ref: "hotfix/critical"
        })

      assert {:error, :head_ref_not_allowed} = Store.accept(intent)
    end
  end

  describe "transition/4 CAS" do
    setup do
      intent = build_intent()
      {:ok, run} = Store.accept(intent)
      {:ok, run: run}
    end

    test "transitions from accepted to workspace_ready", %{run: run} do
      assert {:ok, %WorkflowRun{status: "workspace_ready", state_version: 2}} =
               Store.transition(run.id, 1, "accepted", "workspace_ready")
    end

    test "exact retry is idempotent", %{run: run} do
      {:ok, r1} = Store.transition(run.id, 1, "accepted", "workspace_ready")
      {:ok, r2} = Store.transition(run.id, 1, "accepted", "workspace_ready")
      assert r1.state_version == r2.state_version
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

    test "non-existent run returns not_found" do
      assert {:error, :not_found} =
               Store.transition("nonexistent", 1, "accepted", "workspace_ready")
    end

    test "rejects unknown status at gate" do
      intent = build_intent()
      {:ok, run} = Store.accept(intent)

      assert {:error, {:invalid_status, "invalid_status"}} =
               Store.transition(run.id, 1, "accepted", "invalid_status")
    end

    test "terminal runs: exact retry returns same run, different transition rejected" do
      intent = build_intent()
      {:ok, run} = Store.accept(intent)

      # First: accepted → completed (terminal). CAS succeeds.
      {:ok, r1} = Store.transition(run.id, 1, "accepted", "completed")
      assert r1.status == "completed"
      assert r1.state_version == 2

      # Exact retry with same params: returns same completed run (idempotent).
      {:ok, r2} = Store.transition(run.id, 1, "accepted", "completed")
      assert r2.id == r1.id
      assert r2.status == "completed"
      assert r2.state_version == 2

      # Different transition attempt on terminal run: rejected.
      assert {:error, :workflow_terminal} =
               Store.transition(run.id, 2, "completed", "projected")

      # State didn't change.
      {:ok, final} = Store.read_run(run.id)
      assert final.state_version == 2
      assert final.status == "completed"
    end
  end

  describe "read_run/1" do
    setup do
      intent = build_intent()
      {:ok, run} = Store.accept(intent)
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
      {:ok, binding} = TaskBinding.new(%{@valid_binding_attrs | id: "bnd_reg"})
      assert {:ok, %TaskBinding{id: "bnd_reg"}} = Store.register_binding(binding)
    end

    test "rejects duplicate binding id" do
      {:ok, binding} = TaskBinding.new(%{@valid_binding_attrs | id: "bnd_dup2"})
      {:ok, _} = Store.register_binding(binding)
      assert {:error, {:binding_exists, "bnd_dup2"}} = Store.register_binding(binding)
    end
  end
end
