defmodule EzagentPluginGitWorkflow.PlanEFaultInjectionTest do
  @moduledoc """
  Slice P4e — design §8's eight fault injections, against the same real
  pipeline `plan_e_local_e2e_test.exs` runs (see
  `EzagentPluginGitWorkflow.PlanEE2ECase`).

  Cases 3 and 4 are why this slice exists. Both are "the world ended between
  an effect and its record", the class §6.2 is written for, and neither is
  reachable from a happy path. Both are also easy to write so they pass
  WITHOUT exercising the window — so each asserts what happened on the
  RETRY, not merely that no exception escaped:

    * case 3 makes the provider really create the PR and then lose the
      answer (`mode: :after`), and asserts the retry issued no second
      `POST /pulls`;
    * case 4 lets the observation reads really complete, kills the tick with
      the answers in hand, and asserts the row is byte-identical afterwards
      and then wholly the NEW tick — never a mixture.
  """

  use EzagentPluginGitWorkflow.PlanEE2ECase

  alias EzagentPluginGitWorkflow.AcceptIntent
  alias EzagentPluginGitWorkflow.Authorization
  alias EzagentPluginGitWorkflow.CrashingSeam
  alias EzagentPluginGitWorkflow.ExecutionSeam.CapBacked
  alias EzagentPluginGitWorkflow.ExecutionSeamTestDelegate
  alias EzagentPluginGitWorkflow.Observation
  alias EzagentPluginGitWorkflow.StageRunner
  alias EzagentPluginGitWorkflow.StubGitProvider
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :plan_e_e2e

  # A value that must never reach a persisted column or a log line. It rides
  # in the provider's error BODY, which is exactly where a raw-response leak
  # would pick it up.
  @provider_secret "PROVIDER-BODY-SECRET-ghp_should_never_be_persisted"

  defp provision_count do
    %{rows: [[count]]} = Repo.query!("SELECT COUNT(*) FROM git_task_workspace_provisions")
    count
  end

  defp pr_count(provider), do: length(StubGitProvider.state(provider).pulls)

  # ---------------------------------------------------------------------------
  # 1 — authorization unavailable, before ANY side effect
  # ---------------------------------------------------------------------------

  describe "fault 1 — authorization unavailable" do
    test "denies the accepted→authorized step with zero workspace, filesystem or provider effect",
         %{run: run, binding: binding, provider: provider, root: root} do
      # `Unavailable` is what a build with no backend answers with — the §3.1
      # fallback, installed here by simply not installing anything.
      :ok = ExecutionSeamTestDelegate.clear_backend()

      assert {:error, :authorization_unavailable} = Authorization.authorize_run(run, binding)

      assert {:ok, %WorkflowRun{status: "accepted", last_error_code: nil}} = Store.read_run(run.id)
      assert StubGitProvider.log(provider) == []
      assert provision_count() == 0
      assert {:error, :not_found} = Store.read_facts(run.id)

      # Nothing was checked out either: the only directories under the
      # test's `EZAGENT_HOME` are the fixture repository's own.
      assert root |> File.ls!() |> Enum.all?(&(&1 =~ ~r/^(origin|source)-/))
    end

    test "an already-authorized run whose backend has gone away performs no stage effect", %{
      run: run,
      binding: binding,
      provider: provider
    } do
      authorize!(run.id, binding)
      :ok = ExecutionSeamTestDelegate.clear_backend()

      assert {:retry, %{code: :authorization_unavailable, stage: :provision_workspace}} =
               StageRunner.advance(run.id)

      assert StubGitProvider.log(provider) == []
      assert provision_count() == 0
      assert {:error, :not_found} = Store.read_facts(run.id)

      assert {:ok, %WorkflowRun{status: "authorized", last_error_code: "authorization_unavailable"}} =
               Store.read_run(run.id)
    end
  end

  # ---------------------------------------------------------------------------
  # 2 — no provider call is possible below workspace_ready
  # ---------------------------------------------------------------------------

  describe "fault 2 — provider calls below workspace_ready" do
    test "the provider receives nothing until the change-request stage", %{
      run: run,
      binding: binding,
      provider: provider
    } do
      authorize!(run.id, binding)
      assert StubGitProvider.log(provider) == []

      assert %WorkflowRun{status: "workspace_ready"} = advance!(run.id)
      assert StubGitProvider.log(provider) == []

      write_worker_file!(run.id, worker_content())
      assert %WorkflowRun{status: "changes_ready"} = advance!(run.id)
      assert StubGitProvider.log(provider) == []

      assert %WorkflowRun{status: "pr_open"} = advance!(run.id)
      assert StubGitProvider.log(provider) != []
    end
  end

  # ---------------------------------------------------------------------------
  # 3 — the PR POST succeeded and the receipt was lost
  # ---------------------------------------------------------------------------

  describe "fault 3 — PR created, receipt lost" do
    test "the retry reconciles onto the SAME pull request and issues no second POST /pulls", %{
      run: run,
      binding: binding,
      provider: provider
    } do
      :ok = to_changes_ready!(run.id, binding)

      # `:after` — the PR really is created, then the answer is lost. A
      # `:before` failure would test the ordinary error path instead, and the
      # window would go unexercised.
      :ok =
        StubGitProvider.fail_next(provider,
          method: "POST",
          suffix: "/pulls",
          status: 502,
          mode: :after,
          body: %{"message" => @provider_secret}
        )

      assert {:retry, %{code: :provider_unavailable, stage: :create_change_request}} =
               StageRunner.advance(run.id)

      # The effect DID land — this is the window, not a plain failure.
      assert pr_count(provider) == 1
      assert {:ok, %WorkflowRun{status: "changes_ready"}} = Store.read_run(run.id)
      assert {:ok, %{change_request_id: nil}} = Store.read_facts(run.id)

      :ok = StubGitProvider.reset_log(provider)

      assert %WorkflowRun{status: "pr_open"} = advance!(run.id)

      assert StubGitProvider.count(provider, "POST", "/pulls") == 0
      assert pr_count(provider) == 1

      {:ok, facts} = Store.read_facts(run.id)
      [%{"number" => number}] = StubGitProvider.state(provider).pulls
      assert facts.change_request_id == to_string(number)
    end
  end

  # ---------------------------------------------------------------------------
  # 4 — the observation answers arrived and the DB write never happened
  # ---------------------------------------------------------------------------

  describe "fault 4 — observation answered, snapshot never persisted" do
    test "the crashed tick writes nothing, and the retry writes ONE whole tick", %{
      run: run,
      binding: binding,
      provider: provider
    } do
      :ok = to_changes_ready!(run.id, binding)
      assert %WorkflowRun{status: "pr_open"} = advance!(run.id)
      assert {:ok, _} = Observation.tick(run.id)

      {:ok, before_crash} = Store.read_facts(run.id)
      assert before_crash.checks_summary == "1 checks: completed:succeeded=1"
      assert before_crash.checks_revision == 1

      # Change the answer so the two ticks are DISTINGUISHABLE in the row. Two
      # identical ticks could not show which one a column came from, which is
      # the whole question here.
      :ok =
        StubGitProvider.set_observations(provider,
          checks: [
            %{"id" => 9002, "name" => "ci/build", "status" => "queued", "conclusion" => nil}
          ],
          reviews: []
        )

      :ok = ExecutionSeamTestDelegate.put_backend(CrashingSeam)
      :ok = CrashingSeam.crash_after(:list_reviews)
      :ok = StubGitProvider.reset_log(provider)

      assert_raise CrashingSeam.Crash, fn -> Observation.tick(run.id) end

      # The three reads really completed and the reviews answer was in hand —
      # the window is "after the response", not "instead of" it.
      assert StubGitProvider.count(provider, "GET", "/check-runs") == 1
      assert StubGitProvider.count(provider, "GET", "/reviews") == 1
      assert CrashingSeam.armed_result() == {:ok, []}

      # FULLY the old tick: not one column moved.
      {:ok, after_crash} = Store.read_facts(run.id)
      assert after_crash == before_crash

      :ok = ExecutionSeamTestDelegate.put_backend(CapBacked)
      assert {:ok, %WorkflowRun{status: "observations_current"}} = Observation.tick(run.id)

      # FULLY the new tick: both halves are the new answer, both revisions
      # advanced together, and both timestamps date the same tick.
      {:ok, after_retry} = Store.read_facts(run.id)
      assert after_retry.checks_summary == "1 checks: queued=1"
      assert after_retry.reviews_summary == "no reviews reported"
      assert after_retry.checks_revision == 2
      assert after_retry.reviews_revision == 2
      assert after_retry.checks_observed_at == after_retry.reviews_observed_at
    end
  end

  # ---------------------------------------------------------------------------
  # 5 — branch collision
  # ---------------------------------------------------------------------------

  describe "fault 5 — branch collision" do
    test "a foreign commit on the deterministic ref is :head_ref_conflict, never a force push", %{
      run: run,
      binding: binding,
      provider: provider,
      policy: policy,
      origin: origin
    } do
      :ok = to_changes_ready!(run.id, binding)

      # A ref of this exact name carrying a commit this run did not build.
      # Its parent IS the verified base, so parent equality alone would let
      # it through — the adapter's tree check is what refuses it.
      {:ok, foreign_sha} =
        StubGitProvider.plant_ref(provider, policy.allowed_head_ref,
          parent: origin.head_sha,
          marker: "some other branch"
        )

      :ok = StubGitProvider.reset_log(provider)

      assert {:blocked, %{code: :head_ref_conflict, stage: :create_change_request}} =
               StageRunner.advance(run.id)

      assert {:ok, %WorkflowRun{status: "blocked", last_error_code: "head_ref_conflict"}} =
               Store.read_run(run.id)

      log = StubGitProvider.log(provider)

      # No force push — and not merely "no force push that succeeded": no
      # ref update of any kind was attempted.
      assert Enum.count(log, &(&1.method == "PATCH")) == 0
      refute Enum.any?(log, &(&1.body["force"] == true))

      # And no PR and no commit came out of the collision.
      assert StubGitProvider.count(provider, "POST", "/pulls") == 0
      assert StubGitProvider.count(provider, "POST", "/git/commits") == 0
      assert StubGitProvider.count(provider, "POST", "/git/refs") == 0
      assert pr_count(provider) == 0
      assert StubGitProvider.state(provider).refs[policy.allowed_head_ref] == foreign_sha
    end
  end

  # ---------------------------------------------------------------------------
  # 6 — digest conflict
  # ---------------------------------------------------------------------------

  describe "fault 6 — digest conflict" do
    test "a second accept for the same run key with different inputs loses, and mutates nothing",
         %{run: run, intent: intent, provider: provider} do
      %AcceptIntent{} = intent
      conflicting = %{intent | source_revision: "a-different-revision"}

      assert {:error, :digest_conflict} = Store.accept(conflicting)

      %{rows: [[count]]} = Repo.query!("SELECT COUNT(*) FROM git_workflow_runs")
      assert count == 1

      {:ok, unchanged} = Store.read_run(run.id)
      assert unchanged.input_digest == run.input_digest
      assert unchanged.source_revision == nil
      assert StubGitProvider.log(provider) == []
      assert provision_count() == 0
    end

    test "a worktree that moved between collection and creation blocks before any mutation", %{
      run: run,
      binding: binding,
      provider: provider
    } do
      :ok = to_changes_ready!(run.id, binding)

      # The recorded `change_digest` no longer describes the worktree. §6.2's
      # idempotency rests on the commit being a pure function of the tree, so
      # committing THIS tree under THAT digest is the silent corruption the
      # check exists to stop.
      write_worker_file!(run.id, "the worker wrote something else\n")

      assert {:blocked, %{code: :change_digest_mismatch, stage: :create_change_request}} =
               StageRunner.advance(run.id)

      assert StubGitProvider.log(provider) == []
      assert pr_count(provider) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # 7 — unsupported workspace change
  # ---------------------------------------------------------------------------

  describe "fault 7 — unsupported workspace change" do
    test "a binary file blocks at collection with no commit and no PR", %{
      run: run,
      binding: binding,
      provider: provider
    } do
      authorize!(run.id, binding)
      assert %WorkflowRun{status: "workspace_ready"} = advance!(run.id)

      write_worker_file!(run.id, <<0, 1, 2, 3, 0xFF>>, "payload.bin")

      assert {:blocked, %{code: :unsupported_workspace_change, stage: :collect_workspace_changes}} =
               StageRunner.advance(run.id)

      assert {:ok,
              %WorkflowRun{status: "blocked", last_error_code: "unsupported_workspace_change"}} =
               Store.read_run(run.id)

      assert StubGitProvider.log(provider) == []
      assert pr_count(provider) == 0
      assert StubGitProvider.state(provider).commits |> map_size() == 1
    end
  end

  # ---------------------------------------------------------------------------
  # 8 — GitHub 401 / 403 / 422 / 429 / 5xx
  # ---------------------------------------------------------------------------

  describe "fault 8 — provider status mapping and leak-freedom" do
    # The fault is armed on the FIRST request of the change-request callback
    # (the installation lookup), so all five statuses are compared at one call
    # site rather than each at whichever site happened to be convenient.
    for {status, code, outcome} <- [
          {401, :provider_permission_denied, :blocked},
          {403, :provider_permission_denied, :blocked},
          {422, :provider_unavailable, :retry},
          {429, :provider_rate_limited, :retry},
          {503, :provider_unavailable, :retry}
        ] do
      test "HTTP #{status} maps to #{code} and leaks no response body", %{
        run: run,
        binding: binding,
        provider: provider
      } do
        :ok = to_changes_ready!(run.id, binding)

        :ok =
          StubGitProvider.fail_next(provider,
            method: "GET",
            suffix: "/installation",
            status: unquote(status),
            body: %{"message" => @provider_secret, "documentation_url" => @provider_secret}
          )

        {result, log_output} =
          ExUnit.CaptureLog.with_log(fn -> StageRunner.advance(run.id) end)

        assert {unquote(outcome), presentation} = result
        assert presentation.code == unquote(code)
        assert presentation.stage == :create_change_request
        assert presentation.retryable == (unquote(outcome) == :retry)

        # §7.1: presentation carries five fields and nothing else.
        assert Map.keys(presentation) |> Enum.sort() ==
                 [:attempt, :code, :metadata, :retryable, :stage]

        {:ok, after_fault} = Store.read_run(run.id)
        assert after_fault.last_error_code == Atom.to_string(unquote(code))

        # The leak half — for THIS status, not only for one of the five.
        # The positive control keeps the sweep from being vacuous: it really
        # is reading rows, and it really would see the secret if one were
        # there.
        persisted = all_persisted_strings()
        assert run.id in persisted

        for value <- persisted do
          refute String.contains?(value, @provider_secret)
        end

        refute String.contains?(log_output, @provider_secret)
        refute presentation |> inspect() |> String.contains?(@provider_secret)

        # Nothing was created on the way to the failure either.
        assert pr_count(provider) == 0
        assert StubGitProvider.state(provider).refs |> Map.keys() == ["main"]
      end
    end
  end
end
