defmodule EzagentPluginGitWorkflow.ConcurrencyTest do
  use EzagentPluginGitWorkflow.ConnCase, async: false

  alias EzagentCore.Repo
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :concurrency

  @binding_attrs %{
    id: "bnd_conc",
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

  describe "unique constraint enforcement" do
    test "duplicate (binding_id, generation, external_task_id) rejects second insert" do
      attrs = %{
        id: "run-uc-1",
        binding_id: "bnd_conc",
        binding_generation: 1,
        external_task_id: "task-uc",
        authenticated_principal_uri: URI.parse("entity://test-ws/agent/worker1"),
        status: "accepted",
        state_version: 1,
        input_digest: "sha256:abc",
        source_task_uri: URI.parse("resource://test-ws/kanban-task/task-src"),
        source_revision: "abc",
        requested_head_ref: "feature/x",
        last_error_code: nil
      }

      {:ok, run} = WorkflowRun.new(attrs)

      # First insert succeeds
      {:ok, inserted} = Store.claim(run)
      assert inserted.status == "accepted"

      # Second claim with same unique key + same digest is idempotent
      {:ok, reloaded} = Store.claim(run)
      assert reloaded.id == inserted.id
      assert reloaded.input_digest == inserted.input_digest

      # Only one row in DB
      [[count]] =
        Repo.query!(
          "SELECT COUNT(*) FROM git_workflow_runs WHERE binding_id = $1 AND binding_generation = $2 AND external_task_id = $3",
          ["bnd_conc", 1, "task-uc"]
        ).rows

      assert count == 1
    end

    test "same unique key + different digest returns digest_conflict" do
      attrs_a = %{
        id: "run-digest-a",
        binding_id: "bnd_conc",
        binding_generation: 1,
        external_task_id: "task-digest-conflict",
        authenticated_principal_uri: URI.parse("entity://test-ws/agent/worker1"),
        status: "accepted",
        state_version: 1,
        input_digest: "sha256:digest-A",
        source_task_uri: URI.parse("resource://test-ws/kanban-task/task-src"),
        source_revision: "rev-A",
        requested_head_ref: "feature/a",
        last_error_code: nil
      }

      attrs_b = %{attrs_a | id: "run-digest-b", input_digest: "sha256:digest-B",
                    source_revision: "rev-B"}

      {:ok, run_a} = WorkflowRun.new(attrs_a)
      {:ok, run_b} = WorkflowRun.new(attrs_b)

      # First claim with digest A succeeds
      assert {:ok, _} = Store.claim(run_a)

      # Second claim with same unique key but digest B returns conflict
      assert {:error, :digest_conflict} = Store.claim(run_b)

      # Still only one row
      [[count]] =
        Repo.query!(
          "SELECT COUNT(*) FROM git_workflow_runs WHERE binding_id = $1 AND binding_generation = $2 AND external_task_id = $3",
          ["bnd_conc", 1, "task-digest-conflict"]
        ).rows

      assert count == 1
    end
  end

  describe "CAS atomicity" do
    setup do
      {:ok, run} =
        struct!(WorkflowRun, %{
          id: "run-cas",
          binding_id: "bnd_conc",
          binding_generation: 1,
          external_task_id: "task-cas",
          authenticated_principal_uri: URI.parse("entity://test-ws/agent/worker1"),
          status: "accepted",
          state_version: 1,
          input_digest: "sha256:cas",
          source_task_uri: URI.parse("resource://test-ws/kanban-task/task-src"),
          source_revision: "abc",
          requested_head_ref: "feature/cas",
          last_error_code: nil
        })
        |> Store.claim()

      {:ok, run: run}
    end

    test "CAS succeeds with correct expected_version and expected_status" do
      assert {:ok, %WorkflowRun{status: "workspace_ready", state_version: 2}} =
               Store.transition("run-cas", 1, "accepted", "workspace_ready")
    end

    test "CAS exact retry is idempotent" do
      {:ok, r1} = Store.transition("run-cas", 1, "accepted", "workspace_ready")
      {:ok, r2} = Store.transition("run-cas", 1, "accepted", "workspace_ready")

      assert r1.id == r2.id
      assert r1.state_version == r2.state_version
      assert r1.status == "workspace_ready"
    end

    test "CAS rejects stale state_version" do
      {:ok, _} = Store.transition("run-cas", 1, "accepted", "workspace_ready")

      # Now state_version is 2, retry with version 1 → stale
      assert {:error, :stale_state_version} =
               Store.transition("run-cas", 1, "accepted", "worker_ready")
    end

    test "CAS rejects wrong expected_status" do
      assert {:error, :workflow_state_conflict} =
               Store.transition("run-cas", 1, "completed", "blocked")
    end
  end
end
