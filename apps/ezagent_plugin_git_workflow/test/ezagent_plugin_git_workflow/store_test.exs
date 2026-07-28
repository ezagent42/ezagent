defmodule EzagentPluginGitWorkflow.StoreTest do
  use EzagentPluginGitWorkflow.ConnCase, async: false

  alias Ezagent.DomainGit.CommitSha
  alias Ezagent.DomainGit.CreateChangeRequest
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

    test "upsert_facts/1 never returns an id that was not persisted" do
      # Two concurrent-shaped callers upsert the SAME run_id with DIFFERENT
      # `id` values. The SQL update clause deliberately excludes `id`, so
      # the row keeps its ORIGINAL id on conflict — the second caller's
      # returned struct must reflect that persisted id, not its own input.
      {:ok, first} =
        WorkflowFacts.new(%{
          id: "wf_conflict_first",
          run_id: "run_conflict_1",
          workspace_uri: Ezagent.URI.workspace("test-ws")
        })

      assert {:ok, %WorkflowFacts{id: "wf_conflict_first"}} = Store.upsert_facts(first)

      {:ok, second} =
        WorkflowFacts.new(%{
          id: "wf_conflict_second",
          run_id: "run_conflict_1",
          workspace_uri: Ezagent.URI.workspace("test-ws"),
          head_sha: "second-sha"
        })

      assert {:ok, %WorkflowFacts{id: "wf_conflict_first", head_sha: "second-sha"}} =
               Store.upsert_facts(second)

      assert {:ok, %WorkflowFacts{id: "wf_conflict_first"}} = Store.read_facts("run_conflict_1")
    end
  end

  # Design §6.1 requires the commit date stamped on the provider-side Git
  # commit to be `git_workflow_runs.inserted_at`, read by the workflow from
  # its OWN run row and handed to `CreateChangeRequest`. That constructor
  # requires a `%DateTime{}` and rejects a `%NaiveDateTime{}`, so a store that
  # hands back the naive value breaks the mandated path outright — this is not
  # a representation preference.
  #
  # The columns are `timestamp without time zone` by design (Ecto's
  # `timestamps(type: :utc_datetime_usec)` stores UTC there); what was missing
  # is that raw `Repo.query!/2` bypasses Ecto's load casting, which is what
  # would otherwise return a `DateTime`. The fix is load-side only, in all
  # THREE row mappers — a mapper left unconverted is the same trap for
  # whichever slice reads it next.
  describe "timestamp round-trip (design §6.1)" do
    test "a run read back carries a UTC DateTime that CreateChangeRequest accepts" do
      {:ok, accepted} = Store.accept(build_intent(%{external_task_id: "task-ts-run"}))
      {:ok, run} = Store.read_run(accepted.id)

      assert %DateTime{time_zone: "Etc/UTC"} = run.inserted_at
      assert %DateTime{time_zone: "Etc/UTC"} = run.updated_at

      assert {:ok, %CreateChangeRequest{commit_date: commit_date}} =
               CreateChangeRequest.new(%{
                 title: "P4c",
                 body: "",
                 head_ref: "feature/run-ts",
                 expected_base_sha: %CommitSha{value: String.duplicate("a", 40)},
                 commit_date: run.inserted_at
               })

      assert commit_date == run.inserted_at
    end

    test "the transition CAS path returns the same UTC DateTime" do
      {:ok, accepted} = Store.accept(build_intent(%{external_task_id: "task-ts-cas"}))

      assert {:ok, transitioned} =
               Store.transition(accepted.id, accepted.state_version, "accepted", "authorized")

      assert %DateTime{time_zone: "Etc/UTC"} = transitioned.inserted_at
      assert %DateTime{time_zone: "Etc/UTC"} = transitioned.updated_at
    end

    test "facts read back carry UTC DateTimes, bookkeeping and fact columns alike" do
      established = establish_facts!("run_ts_facts")

      assert %DateTime{time_zone: "Etc/UTC"} = established.inserted_at
      assert %DateTime{time_zone: "Etc/UTC"} = established.updated_at

      observed_at = ~U[2026-07-28 09:30:00.000000Z]

      assert {:ok, updated} =
               Store.update_facts("run_ts_facts", %{checks_observed_at: observed_at})

      assert updated.checks_observed_at == observed_at
      assert %DateTime{time_zone: "Etc/UTC"} = updated.checks_observed_at

      assert {:ok, reread} = Store.read_facts("run_ts_facts")
      assert reread.checks_observed_at == observed_at
      assert %DateTime{time_zone: "Etc/UTC"} = reread.inserted_at
    end

    test "a binding read back carries UTC DateTimes" do
      insert_binding!(%{id: "bnd_ts"})

      assert {:ok, binding} = Store.read_binding("bnd_ts")
      assert %DateTime{time_zone: "Etc/UTC"} = binding.inserted_at
      assert %DateTime{time_zone: "Etc/UTC"} = binding.updated_at

      assert {:ok, disabled} = Store.disable_binding("bnd_ts")
      assert %DateTime{time_zone: "Etc/UTC"} = disabled.inserted_at
      assert %DateTime{time_zone: "Etc/UTC"} = disabled.updated_at
    end
  end

  defp establish_facts!(run_id, attrs \\ %{}) do
    {:ok, facts} =
      %{
        id: "wf_#{run_id}",
        run_id: run_id,
        workspace_uri: Ezagent.URI.workspace("test-ws")
      }
      |> Map.merge(attrs)
      |> WorkflowFacts.new()

    {:ok, established} = Store.upsert_facts(facts)
    established
  end

  # P4a reported the naive/aware mismatch here as a pre-existing defect and
  # normalized around it with an `as_naive/1` helper, because P4a had no
  # consumer that broke. P4c is that consumer (design §6.1), so the store now
  # converts on read and these assertions compare `%DateTime{}` values
  # DIRECTLY — a regression to `NaiveDateTime` fails them instead of being
  # normalized away.
  describe "update_facts/2" do
    # THE reason this function exists (plan gap ③, design §5.3). `upsert_facts/1`
    # is a full-row replace: its ON CONFLICT sets EVERY column to EXCLUDED, so a
    # later stage passing only its own fact nulls out every earlier stage's.
    # Doing that to `deterministic_head_ref` is what would break the GitHub
    # adapter's KNOWN LIMITATION fix — it could no longer prove a ref sitting at
    # base is its own retry rather than a foreign branch.
    test "a later stage's write does not erase an earlier stage's facts" do
      establish_facts!("run_incr_1", %{workspace_provision_id: "prov-1"})

      assert {:ok, %WorkflowFacts{}} =
               Store.update_facts("run_incr_1", %{deterministic_head_ref: "task/run-incr-1"})

      assert {:ok,
              %WorkflowFacts{
                workspace_provision_id: "prov-1",
                deterministic_head_ref: "task/run-incr-1"
              }} = Store.read_facts("run_incr_1")

      # A third write must preserve BOTH of the first two, not just the latest.
      assert {:ok, %WorkflowFacts{}} =
               Store.update_facts("run_incr_1", %{
                 expected_base_sha: "a" <> String.duplicate("0", 39)
               })

      assert {:ok,
              %WorkflowFacts{
                workspace_provision_id: "prov-1",
                deterministic_head_ref: "task/run-incr-1",
                expected_base_sha: "a" <> _
              }} = Store.read_facts("run_incr_1")
    end

    test "returns the row as persisted, built from RETURNING *" do
      establish_facts!("run_incr_2")

      assert {:ok, %WorkflowFacts{id: "wf_run_incr_2", run_id: "run_incr_2", head_sha: "abc"}} =
               Store.update_facts("run_incr_2", %{head_sha: "abc"})
    end

    # Identity guard: a fact write must never move a row's identity, and the
    # generated SQL must never be able to carry a caller-chosen column name.
    for column <- [:id, :run_id, :workspace_uri, :inserted_at, :updated_at] do
      test "rejects #{inspect(column)} — identity/bookkeeping columns are not facts" do
        established = establish_facts!("run_reject_#{unquote(column)}")

        assert {:error, :unknown_fields} =
                 Store.update_facts(established.run_id, %{unquote(column) => "hijacked"})

        assert {:ok, ^established} = Store.read_facts(established.run_id)
      end
    end

    test "rejects an unknown column" do
      established = establish_facts!("run_incr_unknown")

      assert {:error, :unknown_fields} =
               Store.update_facts("run_incr_unknown", %{drop_table: "x"})

      assert {:ok, ^established} = Store.read_facts("run_incr_unknown")
    end

    test "rejects an empty map rather than emitting an empty SET clause" do
      establish_facts!("run_incr_empty")

      assert {:error, :empty_update} = Store.update_facts("run_incr_empty", %{})
    end

    test "an unknown run_id is not_found, and inserts nothing" do
      assert {:error, :not_found} =
               Store.update_facts("run_never_established", %{head_sha: "abc"})

      assert {:error, :not_found} = Store.read_facts("run_never_established")

      [[count]] =
        Repo.query!("SELECT COUNT(*) FROM git_workflow_facts WHERE run_id = $1", [
          "run_never_established"
        ]).rows

      assert count == 0
    end

    test "advances updated_at while leaving id and inserted_at alone" do
      established = establish_facts!("run_incr_ts")
      # The store stamps inserted_at/updated_at from DateTime.utc_now/0, so a
      # same-microsecond second write would make the comparison vacuous.
      Process.sleep(5)

      assert {:ok, updated} = Store.update_facts("run_incr_ts", %{head_sha: "abc"})

      assert updated.id == established.id
      assert updated.inserted_at == established.inserted_at

      assert DateTime.compare(updated.updated_at, established.updated_at) == :gt
    end

    test "round-trips datetime and integer columns, not only strings" do
      establish_facts!("run_incr_types")
      observed_at = ~U[2026-07-28 09:30:00.000000Z]

      assert {:ok, _} =
               Store.update_facts("run_incr_types", %{
                 checks_revision: 7,
                 checks_observed_at: observed_at
               })

      assert {:ok, %WorkflowFacts{checks_revision: 7} = facts} =
               Store.read_facts("run_incr_types")

      assert facts.checks_observed_at == observed_at
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
