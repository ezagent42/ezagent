defmodule EzagentPluginGitWorkflow.ObservationDispatchTest do
  @moduledoc """
  The Slice P4d tick driven through the REAL seam — `ExecutionSeam.CapBacked`
  → `Ezagent.Invocation.dispatch/1` → the task-access Kind → the Git
  task-access action set → the adapter probe.

  `observation_test.exs` scripts the seam, which is what makes its ordering,
  absence and fresh-sha claims expressible; the cost is that it proves nothing
  about the arg SHAPES. This file is the other half. Every arg key set here is
  checked against the action set's `@allowed_keys`, `commit_sha` and
  `change_request_id` are rebuilt through their domain value types, each of the
  three actions must be in the policy's `allowed_actions`, and every call
  carries a real signed capability. A tick that assembled the right values under
  the wrong keys — or asked for an action the policy does not grant — passes the
  scripted suite and fails here.
  """

  use EzagentPluginGitWorkflow.GitDispatchCase

  alias EzagentPluginGitWorkflow.AcceptIntent
  alias EzagentPluginGitWorkflow.ExecutionSeam.CapBacked
  alias EzagentPluginGitWorkflow.ExecutionSeamTestDelegate
  alias EzagentPluginGitWorkflow.GitAdapterProbe
  alias EzagentPluginGitWorkflow.Observation
  alias EzagentPluginGitWorkflow.PolicyDerivation
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.WorkflowFacts
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :observation

  @change_request_id "cr-p4d-dispatch"
  # Deliberately NOT `GitAdapterProbe.head_sha/0`: the row starts out naming a
  # commit the PR has moved off, so a tick reading the row instead of the fresh
  # read would ask about the wrong one.
  @stale_head_sha String.duplicate("f", 40)

  setup %{binding: binding, run: fixture_run} do
    :ok = ExecutionSeamTestDelegate.put_backend(CapBacked)
    on_exit(fn -> ExecutionSeamTestDelegate.clear_backend() end)

    {:ok, _} = Store.register_binding(binding)

    {:ok, intent} =
      AcceptIntent.new(%{
        binding_id: binding.id,
        binding_generation: binding.generation,
        external_task_id: fixture_run.external_task_id,
        source_task_uri: fixture_run.source_task_uri,
        source_revision: nil,
        requested_head_ref: nil
      })

    {:ok, accepted} = Store.accept(intent)
    {:ok, policy} = PolicyDerivation.derive(accepted, binding)

    {:ok, facts} =
      WorkflowFacts.new(%{
        id: "fact_" <> accepted.id,
        run_id: accepted.id,
        workspace_uri: accepted.workspace_uri,
        head_sha: @stale_head_sha,
        change_request_id: @change_request_id,
        change_request_state: "open",
        change_request_head_ref: policy.allowed_head_ref,
        change_request_base_ref: "main"
      })

    {:ok, _} = Store.upsert_facts(facts)
    Repo.query!("UPDATE git_workflow_runs SET status = 'pr_open' WHERE id = $1", [accepted.id])
    {:ok, run} = Store.read_run(accepted.id)

    %{run: run, policy: policy}
  end

  defp adapter_calls(acc \\ []) do
    receive do
      {:git_p4b_adapter_call, action, _context} -> adapter_calls([action | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "pr_open → observations_current through real dispatch" do
    test "the tick advances and reaches exactly the three read actions", %{run: run} do
      assert {:ok, %WorkflowRun{status: "observations_current"}} = Observation.tick(run.id)

      assert adapter_calls() == [:read_change_request, :list_checks, :list_reviews]
    end

    test "the persisted snapshot is the provider's answer, refreshed off the stale row", %{
      run: run
    } do
      assert {:ok, _} = Observation.tick(run.id)
      {:ok, facts} = Store.read_facts(run.id)

      # The fresh read moved the head off the value the row started with.
      assert facts.head_sha == GitAdapterProbe.head_sha()
      refute facts.head_sha == @stale_head_sha

      assert facts.checks_summary == "1 checks: completed:succeeded=1"
      assert facts.reviews_summary == "1 reviews: approved=1"
      assert facts.checks_revision == 1
      assert facts.reviews_revision == 1
      assert %DateTime{} = facts.checks_observed_at
      assert facts.change_request_id == @change_request_id
    end

    test "nothing the probe reports that must not persist reaches a workflow column", %{run: run} do
      assert {:ok, _} = Observation.tick(run.id)

      for table <- ~w(git_workflow_facts git_workflow_runs) do
        %{rows: rows} = Repo.query!("SELECT * FROM #{table}")

        # `P4b Reviewer` is the probe's `author_label`; the check's `name` is
        # `p4b/<sha>`. Neither belongs in a durable summary column (§3.2).
        refute Enum.any?(List.flatten(rows), fn value ->
                 is_binary(value) and String.contains?(value, "P4b Reviewer")
               end)
      end

      {:ok, facts} = Store.read_facts(run.id)
      refute facts.checks_summary =~ "p4b/"
    end
  end

  describe "repeat ticks create no mutation" do
    test "three ticks reach only the three reads — never create_change_request", %{run: run} do
      for _ <- 1..3 do
        assert {:ok, %WorkflowRun{status: "observations_current"}} = Observation.tick(run.id)
      end

      assert adapter_calls() ==
               List.flatten(
                 List.duplicate([:read_change_request, :list_checks, :list_reviews], 3)
               )

      refute_receive {:git_p4b_adapter_call, :create_change_request, _context}
      refute_receive {:git_p4b_adapter_call, :resolve_repository, _context}
    end

    test "the revision counts the ticks and the row stays a single row", %{run: run} do
      for _ <- 1..3, do: assert({:ok, _} = Observation.tick(run.id))

      {:ok, facts} = Store.read_facts(run.id)
      assert facts.checks_revision == 3
      assert facts.reviews_revision == 3

      %{rows: [[count]]} =
        Repo.query!("SELECT COUNT(*) FROM git_workflow_facts WHERE run_id = $1", [run.id])

      assert count == 1
    end
  end

  describe "the deadline never reaches the adapter" do
    test "an expired deadline blocks without a single dispatch", %{run: run} do
      past = DateTime.add(DateTime.utc_now(), -1, :second)

      assert {:blocked, %{code: :observation_incomplete}} =
               Observation.tick(run.id, deadline: past)

      refute_receive {:git_p4b_adapter_call, _action, _context}

      assert {:ok, %WorkflowRun{status: "blocked", last_error_code: "observation_incomplete"}} =
               Store.read_run(run.id)
    end
  end
end
