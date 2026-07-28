defmodule EzagentPluginGitWorkflow.ObservationTest do
  @moduledoc """
  The Slice P4d observation tick against a SCRIPTED seam.

  The two claims this file exists for are both ones a happy-path assertion
  cannot make:

    * **the fresh head sha** — the stub answers `read_change_request` with a
      head sha that DIFFERS from the persisted one, so a tick that reused the
      stored value is caught by what `list_checks` received, not by the final
      row (which would look correct either way);
    * **the absence of mutation** — `refute_receive` over consecutive ticks is
      the only way to say "and nothing else was invoked".

  `observation_dispatch_test.exs` covers the same tick through the REAL seam,
  where the arg key sets and the policy gates are enforced for real.
  """

  use EzagentPluginGitWorkflow.ConnCase, async: false

  alias Ezagent.DomainGit.ChangeRequest
  alias Ezagent.DomainGit.Check
  alias Ezagent.DomainGit.CommitSha
  alias Ezagent.DomainGit.Review
  alias EzagentPluginGitWorkflow.AcceptIntent
  alias EzagentPluginGitWorkflow.ExecutionSeamTestDelegate
  alias EzagentPluginGitWorkflow.GitTaskAccessFixture
  alias EzagentPluginGitWorkflow.Observation
  alias EzagentPluginGitWorkflow.ObservationSummary
  alias EzagentPluginGitWorkflow.PolicyDerivation
  alias EzagentPluginGitWorkflow.ScriptedExecutionSeam
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.WorkflowFacts
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :observation

  @change_request_id "cr-p4d-1"
  # What P4c left in the facts row.
  @stored_head_sha String.duplicate("c", 40)
  # What THIS tick's `read_change_request` answers with — a push moved the head
  # since the row was written.
  @fresh_head_sha String.duplicate("e", 40)

  setup do
    binding = GitTaskAccessFixture.binding()
    {:ok, _} = Store.register_binding(binding)

    attrs = GitTaskAccessFixture.run_attrs()

    {:ok, intent} =
      AcceptIntent.new(%{
        binding_id: binding.id,
        binding_generation: binding.generation,
        external_task_id: attrs.external_task_id,
        source_task_uri: attrs.source_task_uri,
        source_revision: nil,
        requested_head_ref: nil
      })

    {:ok, accepted} = Store.accept(intent)
    {:ok, policy} = PolicyDerivation.derive(accepted, binding)

    # Land the run exactly where P4c leaves it: `pr_open`, with the facts row
    # P4c wrote. Driving the three P4c stages here would test P4c, not this.
    run = seed_pr_open!(accepted, policy)

    on_exit(fn -> ExecutionSeamTestDelegate.clear_backend() end)

    %{binding: binding, run: run, policy: policy}
  end

  # ---------------------------------------------------------------------------
  # Fixtures
  # ---------------------------------------------------------------------------

  defp seed_pr_open!(run, policy) do
    {:ok, facts} =
      WorkflowFacts.new(%{
        id: "fact_" <> run.id,
        run_id: run.id,
        workspace_uri: run.workspace_uri,
        workspace_provision_id: "prov-p4d",
        deterministic_head_ref: policy.allowed_head_ref,
        change_digest: "sha256:" <> String.duplicate("a", 64),
        expected_base_sha: String.duplicate("b", 40),
        head_sha: @stored_head_sha,
        change_request_id: @change_request_id,
        change_request_url: "https://git.example.test/p4d/pull/1",
        change_request_state: "open",
        change_request_head_ref: policy.allowed_head_ref,
        change_request_base_ref: "main"
      })

    {:ok, _} = Store.upsert_facts(facts)

    Repo.query!("UPDATE git_workflow_runs SET status = 'pr_open' WHERE id = $1", [run.id])
    {:ok, at_pr_open} = Store.read_run(run.id)
    at_pr_open
  end

  defp change_request(opts) do
    %ChangeRequest{
      external_id: Keyword.get(opts, :external_id, @change_request_id),
      url: URI.parse(Keyword.get(opts, :url, "https://git.example.test/p4d/pull/1")),
      head_ref: Keyword.get(opts, :head_ref, "task/p4b/whatever"),
      head_sha: Keyword.get(opts, :head_sha, @fresh_head_sha),
      base_ref: Keyword.get(opts, :base_ref, "main"),
      state: Keyword.get(opts, :state, :open)
    }
  end

  defp completed(conclusion, id) do
    %Check{
      external_id: id,
      name: "build",
      status: :completed,
      conclusion: conclusion,
      url: nil
    }
  end

  defp review(state, id) do
    %Review{external_id: id, author_label: "Reviewer", state: state, submitted_at: nil}
  end

  defp script(opts) do
    %{
      read_change_request:
        Keyword.get(opts, :read_change_request, {:ok, change_request(opts)}),
      list_checks: Keyword.get(opts, :list_checks, {:ok, [completed(:succeeded, "chk-1")]}),
      list_reviews: Keyword.get(opts, :list_reviews, {:ok, [review(:approved, "rev-1")]})
    }
  end

  defp install(opts \\ []), do: :ok = ScriptedExecutionSeam.install(script(opts))

  defp facts!(run_id) do
    {:ok, facts} = Store.read_facts(run_id)
    facts
  end

  # Drains and returns every seam invocation reported so far, in order.
  defp invoked_actions(acc \\ []) do
    receive do
      {:seam_invoke, action, _args} -> invoked_actions([action | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ---------------------------------------------------------------------------
  # §6.3 step 2 — THE fresh head sha
  # ---------------------------------------------------------------------------

  describe "list_checks uses THIS tick's head sha" do
    test "the sha sent is the fresh read's, not the one persisted in facts", %{run: run} do
      # The row says one thing, the provider says another. A tick that read the
      # row would be indistinguishable from a correct one by its final state.
      assert facts!(run.id).head_sha == @stored_head_sha

      install()

      assert {:ok, %WorkflowRun{status: "observations_current"}} = Observation.tick(run.id)

      assert_receive {:seam_invoke, :list_checks, %{commit_sha: %CommitSha{value: sent}}}
      assert sent == @fresh_head_sha
      refute sent == @stored_head_sha
    end

    test "and the SAME fresh sha is what the row ends up holding", %{run: run} do
      install()
      assert {:ok, _} = Observation.tick(run.id)

      # One snapshot: the checks were observed for exactly the commit the row
      # now names as the head.
      assert facts!(run.id).head_sha == @fresh_head_sha
    end

    test "a head sha the domain type rejects blocks before list_checks is reached", %{run: run} do
      install(head_sha: "not-a-sha")

      assert {:blocked, %{code: :internal_error, stage: :observation}} = Observation.tick(run.id)

      assert_receive {:seam_invoke, :read_change_request, _args}
      refute_receive {:seam_invoke, :list_checks, _args}
    end
  end

  # ---------------------------------------------------------------------------
  # §6.3 — the three actions, in order, and NOTHING else
  # ---------------------------------------------------------------------------

  describe "the action vocabulary of a tick" do
    test "one tick invokes exactly read_change_request, list_checks, list_reviews", %{run: run} do
      install()
      assert {:ok, _} = Observation.tick(run.id)

      assert invoked_actions() == [:read_change_request, :list_checks, :list_reviews]
    end

    test "three consecutive ticks invoke those three and NOTHING else", %{run: run} do
      install()

      for _ <- 1..3 do
        assert {:ok, %WorkflowRun{status: "observations_current"}} = Observation.tick(run.id)
      end

      assert invoked_actions() ==
               List.duplicate([:read_change_request, :list_checks, :list_reviews], 3)
               |> List.flatten()

      # And said the same thing a second way, so a future change that renamed
      # the reporting shape cannot quietly disarm the claim above.
      refute_receive {:seam_invoke, :create_change_request, _args}
      refute_receive {:seam_invoke, :provision_workspace, _args}
      refute_receive {:seam_invoke, :collect_workspace_changes, _args}
      refute_receive {:seam_invoke, :cleanup_workspace, _args}
      refute_receive {:seam_invoke, :resolve_repository, _args}
    end

    test "each action carries exactly the key set the action set allows", %{
      run: run,
      policy: policy
    } do
      install()
      assert {:ok, _} = Observation.tick(run.id)

      assert_receive {:seam_invoke, :read_change_request, read_args}
      assert read_args |> Map.keys() |> Enum.sort() == [:change_request_id, :repository]
      assert read_args.change_request_id.external_id == @change_request_id
      assert read_args.repository == policy.repository

      assert_receive {:seam_invoke, :list_checks, checks_args}
      assert checks_args |> Map.keys() |> Enum.sort() == [:commit_sha, :repository]

      assert_receive {:seam_invoke, :list_reviews, reviews_args}
      assert reviews_args |> Map.keys() |> Enum.sort() == [:change_request_id, :repository]
      assert reviews_args.change_request_id == read_args.change_request_id
    end
  end

  # ---------------------------------------------------------------------------
  # §6.3 — the empty answers are facts
  # ---------------------------------------------------------------------------

  describe "empty checks and empty reviews are valid observations" do
    test "an empty checks list persists the non-success sentence and still advances", %{run: run} do
      install(list_checks: {:ok, []})

      assert {:ok, %WorkflowRun{status: "observations_current"}} = Observation.tick(run.id)

      facts = facts!(run.id)
      assert facts.checks_summary == "no checks reported"
      assert facts.checks_summary == ObservationSummary.no_checks_reported()
      assert facts.checks_revision == 1
      assert %DateTime{} = facts.checks_observed_at
    end

    test "an empty reviews list is not an approval and still advances", %{run: run} do
      install(list_reviews: {:ok, []})

      assert {:ok, %WorkflowRun{status: "observations_current"}} = Observation.tick(run.id)

      facts = facts!(run.id)
      assert facts.reviews_summary == "no reviews reported"
      assert facts.reviews_summary == ObservationSummary.no_reviews_reported()
      assert facts.reviews_revision == 1
    end

    test "both empty is a successful tick, not a blocker", %{run: run} do
      install(list_checks: {:ok, []}, list_reviews: {:ok, []})

      assert {:ok, %WorkflowRun{status: "observations_current"}} = Observation.tick(run.id)
      assert {:ok, %WorkflowRun{last_error_code: nil}} = Store.read_run(run.id)
    end
  end

  # ---------------------------------------------------------------------------
  # §5.3 / §6.2's last crash window — one tick, one write
  # ---------------------------------------------------------------------------

  describe "one tick's facts are written together" do
    test "a tick whose list_reviews fails writes NO checks facts at all", %{run: run} do
      install(list_reviews: {:error, :provider_unavailable})

      assert {:retry, %{code: :provider_unavailable, retryable: true}} = Observation.tick(run.id)

      # The checks were already fetched. If they had been written on their own,
      # the row would carry tick N's checks with no reviews beside them.
      facts = facts!(run.id)
      assert facts.checks_summary == nil
      assert facts.checks_revision == nil
      assert facts.checks_observed_at == nil
      assert facts.reviews_summary == nil
      # And the head sha the fresh read reported did not land either.
      assert facts.head_sha == @stored_head_sha
    end

    test "a crash between the two provider reads leaves the row byte-identical", %{run: run} do
      before = facts!(run.id)

      install(list_reviews: fn _args -> raise "provider call exploded mid-flight" end)

      assert_raise RuntimeError, "provider call exploded mid-flight", fn ->
        Observation.tick(run.id)
      end

      assert facts!(run.id) == before
      assert {:ok, %WorkflowRun{status: "pr_open"}} = Store.read_run(run.id)
    end

    test "both observed_at columns hold the same instant — they date the tick", %{run: run} do
      install()
      assert {:ok, _} = Observation.tick(run.id)

      facts = facts!(run.id)
      assert facts.checks_observed_at == facts.reviews_observed_at
    end

    test "all six observation columns move on the same tick", %{run: run} do
      install()
      assert {:ok, _} = Observation.tick(run.id)

      facts = facts!(run.id)

      for field <- ~w(checks_summary checks_revision checks_observed_at
                      reviews_summary reviews_revision reviews_observed_at)a do
        refute is_nil(Map.fetch!(facts, field)), "#{field} was left behind"
      end
    end
  end

  # ---------------------------------------------------------------------------
  # The revision rule
  # ---------------------------------------------------------------------------

  describe "revision bumps on every tick that observed" do
    test "nil → 1 → 2 → 3, and an IDENTICAL answer still bumps", %{run: run} do
      assert facts!(run.id).checks_revision == nil

      install()

      for expected <- 1..3 do
        assert {:ok, _} = Observation.tick(run.id)
        facts = facts!(run.id)

        assert facts.checks_revision == expected
        assert facts.reviews_revision == expected
      end

      # The summaries never changed — the revision is a count of OBSERVATIONS,
      # not of distinct snapshots. That is what tells an operator the provider
      # was re-queried rather than the write skipped.
      facts = facts!(run.id)
      assert facts.checks_summary == "1 checks: completed:succeeded=1"
      assert facts.reviews_summary == "1 reviews: approved=1"
    end

    test "observed_at advances alongside the revision", %{run: run} do
      install()
      assert {:ok, _} = Observation.tick(run.id)
      first = facts!(run.id)

      Process.sleep(5)
      assert {:ok, _} = Observation.tick(run.id)
      second = facts!(run.id)

      assert DateTime.after?(second.checks_observed_at, first.checks_observed_at)
      assert second.checks_revision == first.checks_revision + 1
    end

    test "a FAILED tick bumps nothing — the pair always describes a real answer", %{run: run} do
      install()
      assert {:ok, _} = Observation.tick(run.id)
      after_success = facts!(run.id)

      :ok = ScriptedExecutionSeam.rescript(script(list_checks: {:error, :provider_rate_limited}))
      assert {:retry, %{code: :provider_rate_limited}} = Observation.tick(run.id)

      after_failure = facts!(run.id)
      assert after_failure.checks_revision == after_success.checks_revision
      assert after_failure.checks_observed_at == after_success.checks_observed_at
      assert after_failure.reviews_revision == after_success.reviews_revision
    end

    test "a changed answer is visible in the summary, not only in the revision", %{run: run} do
      install()
      assert {:ok, _} = Observation.tick(run.id)
      assert facts!(run.id).checks_summary == "1 checks: completed:succeeded=1"

      :ok =
        ScriptedExecutionSeam.rescript(
          script(list_checks: {:ok, [completed(:succeeded, "chk-1"), completed(:failed, "chk-2")]})
        )

      assert {:ok, _} = Observation.tick(run.id)

      facts = facts!(run.id)
      assert facts.checks_summary == "2 checks: completed:failed=1 completed:succeeded=1"
      assert facts.checks_revision == 2
    end
  end

  # ---------------------------------------------------------------------------
  # The change request the tick asked about
  # ---------------------------------------------------------------------------

  describe "the fresh read refreshes the mutable change-request facts" do
    test "state, url, head_ref and base_ref all come from this tick's read", %{run: run} do
      install(
        state: :merged,
        url: "https://git.example.test/p4d/pull/1#merged",
        head_ref: "task/p4b/moved",
        base_ref: "release"
      )

      assert {:ok, _} = Observation.tick(run.id)

      facts = facts!(run.id)
      assert facts.change_request_state == "merged"
      assert facts.change_request_url == "https://git.example.test/p4d/pull/1#merged"
      assert facts.change_request_head_ref == "task/p4b/moved"
      assert facts.change_request_base_ref == "release"
    end

    test "change_request_id is identity and the tick never rewrites it", %{run: run} do
      install()
      assert {:ok, _} = Observation.tick(run.id)
      assert facts!(run.id).change_request_id == @change_request_id
    end

    test "an answer about a DIFFERENT change request is a conflict, not a snapshot", %{run: run} do
      before = facts!(run.id)
      install(external_id: "cr-somebody-elses")

      assert {:blocked, %{code: :change_request_conflict, retryable: false}} =
               Observation.tick(run.id)

      # Nothing about the other PR reached this run's row, and no checks were
      # even asked for.
      refute_receive {:seam_invoke, :list_checks, _args}
      assert facts!(run.id) == before
      assert {:ok, %WorkflowRun{status: "blocked"}} = Store.read_run(run.id)
    end
  end

  # ---------------------------------------------------------------------------
  # State machine (§5.4)
  # ---------------------------------------------------------------------------

  describe "legal edges" do
    test "pr_open → observations_current, then the self-loop keeps working", %{run: run} do
      install()

      assert {:ok, %WorkflowRun{status: "observations_current", state_version: v1}} =
               Observation.tick(run.id)

      assert {:ok, %WorkflowRun{status: "observations_current", state_version: v2}} =
               Observation.tick(run.id)

      assert v2 == v1 + 1
    end

    test "a run in any other state owes no tick and reaches no provider", %{run: run} do
      install()

      for status <- ~w(accepted authorized workspace_ready changes_ready blocked failed cancelled) do
        Repo.query!("UPDATE git_workflow_runs SET status = $1 WHERE id = $2", [status, run.id])

        assert {:error, {:unexpected_status, ^status}} = Observation.tick(run.id)
        refute_receive {:seam_invoke, _action, _args}
      end
    end

    test "an unknown run id is not_found" do
      assert {:error, :not_found} = Observation.tick("run_nope")
    end
  end

  # ---------------------------------------------------------------------------
  # Task 3 — the deadline belongs to the caller (§7.2)
  # ---------------------------------------------------------------------------

  describe "deadline" do
    test "a deadline already past blocks with observation_incomplete and asks NOTHING", %{
      run: run
    } do
      install()
      past = DateTime.add(DateTime.utc_now(), -60, :second)

      assert {:blocked, %{code: :observation_incomplete, stage: :observation}} =
               Observation.tick(run.id, deadline: past)

      # THE point: a deadline checked after the round trip has already paid the
      # cost it existed to avoid.
      refute_receive {:seam_invoke, _action, _args}

      assert {:ok, %WorkflowRun{status: "blocked", last_error_code: "observation_incomplete"}} =
               Store.read_run(run.id)
    end

    test "a deadline in the future is not in the way", %{run: run} do
      install()
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      assert {:ok, %WorkflowRun{status: "observations_current"}} =
               Observation.tick(run.id, deadline: future)

      assert_receive {:seam_invoke, :read_change_request, _args}
    end

    test "no deadline means empty checks never block — waiting is the caller's job", %{run: run} do
      install(list_checks: {:ok, []}, list_reviews: {:ok, []})

      for _ <- 1..3 do
        assert {:ok, %WorkflowRun{status: "observations_current"}} = Observation.tick(run.id)
      end

      assert {:ok, %WorkflowRun{last_error_code: nil}} = Store.read_run(run.id)
      assert facts!(run.id).checks_revision == 3
    end

    test "an expired deadline blocks even from observations_current", %{run: run} do
      install()
      assert {:ok, %WorkflowRun{status: "observations_current"}} = Observation.tick(run.id)

      past = DateTime.add(DateTime.utc_now(), -1, :second)
      assert {:blocked, %{code: :observation_incomplete}} = Observation.tick(run.id, deadline: past)

      assert {:ok, %WorkflowRun{status: "blocked"}} = Store.read_run(run.id)
    end

    test "the module never sleeps or retries — two calls, two round trips", %{run: run} do
      install(list_checks: {:error, :provider_unavailable})

      assert {:retry, %{attempt: 0}} = Observation.tick(run.id)
      assert {:retry, %{attempt: 7}} = Observation.tick(run.id, attempt: 7)

      assert invoked_actions() == [
               :read_change_request,
               :list_checks,
               :read_change_request,
               :list_checks
             ]
    end
  end

  # ---------------------------------------------------------------------------
  # Failure classification and leak-free presentation (§7.1, §7.2)
  # ---------------------------------------------------------------------------

  describe "failures" do
    test "a retryable provider failure leaves the status and version ALONE", %{run: run} do
      install(list_checks: {:error, :provider_unavailable})

      assert {:retry, %{code: :provider_unavailable, retryable: true}} = Observation.tick(run.id)

      assert {:ok,
              %WorkflowRun{
                status: "pr_open",
                state_version: version,
                last_error_code: "provider_unavailable"
              }} = Store.read_run(run.id)

      assert version == run.state_version
    end

    test "checks_unavailable is retryable, not a reason to fake a summary", %{run: run} do
      install(list_checks: {:error, :checks_unavailable})

      assert {:retry, %{code: :checks_unavailable, retryable: true}} = Observation.tick(run.id)
      assert facts!(run.id).checks_summary == nil
    end

    test "a terminal denial CASes to blocked and persists the code", %{run: run} do
      install(read_change_request: {:error, :not_authorized})

      assert {:blocked, %{code: :not_authorized, retryable: false}} = Observation.tick(run.id)

      assert {:ok, %WorkflowRun{status: "blocked", last_error_code: "not_authorized"}} =
               Store.read_run(run.id)
    end

    test "a provider term carrying a secret leaks into neither the return nor any row", %{run: run} do
      install(
        list_reviews:
          {:error, %{status: 403, body: "Bearer ghp_TOTALLY_SECRET", path: "/etc/shadow"}}
      )

      assert {:blocked, presentation} = Observation.tick(run.id)

      assert presentation == %{
               code: :internal_error,
               stage: :observation,
               retryable: false,
               attempt: 0,
               metadata: %{}
             }

      for table <- ~w(git_workflow_facts git_workflow_runs) do
        %{rows: rows} = Repo.query!("SELECT * FROM #{table}")

        refute Enum.any?(List.flatten(rows), fn value ->
                 is_binary(value) and
                   (String.contains?(value, "ghp_") or String.contains?(value, "/etc/shadow"))
               end)
      end
    end

    test "a review author label never reaches a persisted column", %{run: run} do
      install(
        list_reviews:
          {:ok,
           [
             %Review{
               external_id: "rev-leak",
               author_label: "SECRET-REVIEWER-NAME",
               state: :approved,
               submitted_at: nil
             }
           ]}
      )

      assert {:ok, _} = Observation.tick(run.id)

      %{rows: [row]} =
        Repo.query!("SELECT * FROM git_workflow_facts WHERE run_id = $1", [run.id])

      refute Enum.any?(row, fn value ->
               is_binary(value) and String.contains?(value, "SECRET-REVIEWER-NAME")
             end)
    end

    test "a list carrying something other than the domain value is refused", %{run: run} do
      install(list_checks: {:ok, [%{status: :completed, conclusion: :succeeded}]})

      assert {:blocked, %{code: :internal_error}} = Observation.tick(run.id)
      assert facts!(run.id).checks_summary == nil
    end

    test "a facts row with no change_request_id is a defect, not a provider outcome", %{run: run} do
      Repo.query!("UPDATE git_workflow_facts SET change_request_id = NULL WHERE run_id = $1", [
        run.id
      ])

      install()

      assert {:blocked, %{code: :internal_error, stage: :observation}} = Observation.tick(run.id)
      refute_receive {:seam_invoke, _action, _args}
    end
  end
end
