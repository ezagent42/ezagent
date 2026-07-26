defmodule EzagentPluginGitWorkflow.StoreTest do
  use EzagentPluginGitWorkflow.ConnCase, async: false

  alias EzagentCore.Repo
  alias EzagentPluginGitWorkflow.AcceptIntent
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.TaskBinding
  alias EzagentPluginGitWorkflow.WorkflowFacts
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
      requested_head_ref: nil
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

    test "requested_head_ref inside namespace but not the deterministic value returns error" do
      # Regression for the pre-P1 gap: the old check only verified
      # String.starts_with?/2 against the namespace, so any suffix under
      # "feature/" was accepted. It must now match derive/2 exactly.
      intent =
        build_intent(%{
          external_task_id: "task-non-deterministic-head",
          requested_head_ref: "feature/whatever-i-want"
        })

      assert {:error, :head_ref_not_allowed} = Store.accept(intent)
    end

    test "requested_head_ref matching the deterministic value is accepted" do
      external_task_id = "task-deterministic-head"

      run_id =
        EzagentPluginGitWorkflow.WorkflowRun.generate_id("bnd_store_test", 1, external_task_id)

      expected_ref = EzagentPluginGitWorkflow.DeterministicRef.derive("feature/", run_id)

      intent =
        build_intent(%{
          external_task_id: external_task_id,
          requested_head_ref: expected_ref
        })

      assert {:ok, %WorkflowRun{requested_head_ref: ^expected_ref}} = Store.accept(intent)
    end

    test "run.workspace_uri equals binding.workspace_uri" do
      intent = build_intent(%{external_task_id: "task-ws-proof"})
      {:ok, run} = Store.accept(intent)
      {:ok, binding} = Store.read_binding("bnd_store_test")

      assert run.workspace_uri == binding.workspace_uri
      assert Ezagent.URI.canonical?(run.workspace_uri)
    end

    test "persisted workspace_uri matches binding workspace" do
      intent = build_intent(%{external_task_id: "task-ws-db"})
      {:ok, run} = Store.accept(intent)

      [[db_ws]] =
        Repo.query!(
          "SELECT workspace_uri FROM git_workflow_runs WHERE id = $1",
          [run.id]
        ).rows

      {:ok, binding} = Store.read_binding("bnd_store_test")
      assert db_ws == URI.to_string(binding.workspace_uri)
    end

    test "exact retry returns same canonical workspace_uri" do
      intent = build_intent(%{external_task_id: "task-ws-retry"})
      {:ok, r1} = Store.accept(intent)
      {:ok, r2} = Store.accept(intent)

      assert r1.workspace_uri == r2.workspace_uri
      assert Ezagent.URI.canonical?(r1.workspace_uri)
    end
  end

  describe "transition/4 CAS" do
    setup do
      intent = build_intent()
      {:ok, run} = Store.accept(intent)
      {:ok, run: run}
    end

    test "transitions from accepted to authorized", %{run: run} do
      assert {:ok, %WorkflowRun{status: "authorized", state_version: 2}} =
               Store.transition(run.id, 1, "accepted", "authorized")
    end

    test "exact retry is idempotent", %{run: run} do
      {:ok, r1} = Store.transition(run.id, 1, "accepted", "authorized")
      {:ok, r2} = Store.transition(run.id, 1, "accepted", "authorized")
      assert r1.state_version == r2.state_version
    end

    test "stale state_version returns error", %{run: run} do
      {:ok, _} = Store.transition(run.id, 1, "accepted", "authorized")

      # Second call's target must itself be a legal edge from the claimed
      # expected_status ("accepted") so it clears check_legal_edge and
      # reaches the DB CAS, where it is then classified as stale against
      # the run's actual (now "authorized") state. "blocked" is legal from
      # every non-terminal state, so it always reaches that classification
      # regardless of which state the run actually raced ahead to.
      assert {:error, :stale_state_version} =
               Store.transition(run.id, 1, "accepted", "blocked")
    end

    test "wrong expected_status returns conflict", %{run: run} do
      assert {:error, :workflow_state_conflict} =
               Store.transition(run.id, 1, "workspace_ready", "changes_ready")
    end

    test "non-existent run returns not_found" do
      assert {:error, :not_found} =
               Store.transition("nonexistent", 1, "accepted", "authorized")
    end

    test "rejects unknown status at gate" do
      intent = build_intent()
      {:ok, run} = Store.accept(intent)

      assert {:error, {:invalid_status, "invalid_status"}} =
               Store.transition(run.id, 1, "accepted", "invalid_status")
    end

    test "rejects a known status that is not a legal edge from the current one", %{run: run} do
      assert {:error, {:illegal_transition, "accepted", "pr_open"}} =
               Store.transition(run.id, 1, "accepted", "pr_open")
    end

    test "terminal runs: exact retry returns same run, different transition rejected", %{
      run: run
    } do
      {:ok, r1} = Store.transition(run.id, 1, "accepted", "blocked")
      assert r1.status == "blocked"
      assert r1.state_version == 2

      # Exact retry with same params: returns same run (idempotent).
      {:ok, r2} = Store.transition(run.id, 1, "accepted", "blocked")
      assert r2.id == r1.id
      assert r2.status == "blocked"
      assert r2.state_version == 2

      {:ok, r3} = Store.transition(run.id, 2, "blocked", "failed")
      assert r3.status == "failed"
      assert r3.state_version == 3

      # Different transition attempt on terminal run: rejected. Terminal
      # states have no outgoing @legal_edges entry at all, so a caller
      # that (correctly) names "failed" as expected_status would be
      # rejected at the check_legal_edge gate with {:illegal_transition,
      # "failed", _} before ever reaching the DB — never exercising the
      # :workflow_terminal classification this test targets. Using
      # "blocked" here models a caller with a stale-but-plausible view
      # (legal edge, reaches the DB) who discovers upon CAS-miss
      # classification that the run has since become terminal — which is
      # exactly the case :workflow_terminal exists to report.
      assert {:error, :workflow_terminal} =
               Store.transition(run.id, 3, "blocked", "cancelled")

      {:ok, final} = Store.read_run(run.id)
      assert final.state_version == 3
      assert final.status == "failed"
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

  describe "facts" do
    test "upsert_facts/1 then read_facts/1 round-trips" do
      {:ok, facts} =
        WorkflowFacts.new(%{
          id: "wf_rt_1",
          run_id: "run_rt_1",
          workspace_uri: Ezagent.URI.workspace("test-ws")
        })

      assert {:ok, %WorkflowFacts{id: "wf_rt_1"}} = Store.upsert_facts(facts)

      assert {:ok, %WorkflowFacts{id: "wf_rt_1", run_id: "run_rt_1"}} =
               Store.read_facts("run_rt_1")
    end

    test "upsert_facts/1 updates in place on repeated calls for the same run_id" do
      {:ok, facts} =
        WorkflowFacts.new(%{
          id: "wf_rt_2",
          run_id: "run_rt_2",
          workspace_uri: Ezagent.URI.workspace("test-ws")
        })

      {:ok, _} = Store.upsert_facts(facts)

      {:ok, updated} =
        WorkflowFacts.new(%{
          id: "wf_rt_2",
          run_id: "run_rt_2",
          workspace_uri: Ezagent.URI.workspace("test-ws"),
          head_sha: "abc123"
        })

      {:ok, _} = Store.upsert_facts(updated)

      assert {:ok, %WorkflowFacts{head_sha: "abc123"}} = Store.read_facts("run_rt_2")
      # still exactly one row for this run_id
      [[count]] =
        Repo.query!("SELECT COUNT(*) FROM git_workflow_facts WHERE run_id = $1", ["run_rt_2"]).rows

      assert count == 1
    end

    test "read_facts/1 returns not_found for an unknown run_id" do
      assert {:error, :not_found} = Store.read_facts("nonexistent")
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

    test "persisted binding URIs use canonical stable_key format" do
      {:ok, binding} = TaskBinding.new(%{@valid_binding_attrs | id: "bnd_stable"})
      {:ok, _} = Store.register_binding(binding)

      [[ws, task, cred, repo]] =
        Repo.query!(
          "SELECT workspace_uri, task_receiver_uri, credential_owner_uri, repository_uri
           FROM git_workflow_bindings WHERE id = $1",
          ["bnd_stable"]
        ).rows

      assert ws == Ezagent.URI.stable_key(binding.workspace_uri)
      assert task == Ezagent.URI.stable_key(binding.task_receiver_uri)
      assert cred == Ezagent.URI.stable_key(binding.credential_owner_uri)
      assert repo == Ezagent.URI.stable_key(binding.repository_uri)
    end
  end
end
