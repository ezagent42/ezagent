defmodule EzagentPluginGitWorkflow.PlanERestartReconciliationTest do
  @moduledoc """
  Slice P4e — design §6.2's crash windows as RECOVERY paths, not error paths.

  Each window is entered by making the world stop at exactly that point, and
  each is then resumed from the DURABLE state alone: `StageRunner.advance/1`
  and `Observation.tick/2` take a run id and read everything else out of
  Postgres, so "restart" and "first run" are the same code path. One test
  runs the resume in a genuinely fresh process, so the claim is literal
  rather than argued.

  | §6.2 window | covered by |
  |---|---|
  | commit created, head not advanced | "…the ref is still sitting at base…" here |
  | head advanced, PR not created | "…the head ref is already advanced…" here |
  | PR created, fact not persisted | `plan_e_fault_injection_test.exs` fault 3 |
  | facts persisted, state CAS not done | "…the facts are written and the CAS never ran…" here |
  | observation answered, snapshot not persisted | `plan_e_fault_injection_test.exs` fault 4 |
  """

  use EzagentPluginGitWorkflow.PlanEE2ECase

  alias EzagentPluginGitWorkflow.ExecutionSeam.CapBacked
  alias EzagentPluginGitWorkflow.ExecutionSeamTestDelegate
  alias EzagentPluginGitWorkflow.Observation
  alias EzagentPluginGitWorkflow.StageRunner
  alias EzagentPluginGitWorkflow.StubGitProvider
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :plan_e_e2e

  defp commit_posts(provider) do
    provider
    |> StubGitProvider.log()
    |> Enum.filter(&(&1.method == "POST" and String.ends_with?(&1.path, "/git/commits")))
  end

  # ---------------------------------------------------------------------------
  # The ordering that closes P3's provenance gap
  # ---------------------------------------------------------------------------

  describe "the ref's identity is durable before the provider is touched" do
    test "deterministic_head_ref is in the facts row even when the FIRST request fails", %{
      run: run,
      binding: binding,
      provider: provider,
      policy: policy
    } do
      :ok = to_changes_ready!(run.id, binding)

      # The very first request of the change-request callback. Failing it
      # means the provider learned nothing at all — so anything in the facts
      # row afterwards was written BEFORE any provider call.
      :ok =
        StubGitProvider.fail_next(provider,
          method: "GET",
          suffix: "/installation",
          status: 503
        )

      assert {:retry, %{code: :provider_unavailable}} = StageRunner.advance(run.id)

      assert StubGitProvider.count(provider, "POST", "/git/refs") == 0
      assert {:ok, facts} = Store.read_facts(run.id)
      assert facts.deterministic_head_ref == policy.allowed_head_ref
    end
  end

  # ---------------------------------------------------------------------------
  # Window 1 — the commit exists, the ref is still at base
  # ---------------------------------------------------------------------------

  describe "§6.2 window 1 — commit created, head ref never advanced" do
    test "the resume reproduces the SAME commit and completes, rather than conflicting", %{
      run: run,
      binding: binding,
      provider: provider,
      policy: policy,
      origin: origin
    } do
      :ok = to_changes_ready!(run.id, binding)

      :ok =
        StubGitProvider.fail_next(provider,
          method: "PATCH",
          suffix: policy.allowed_head_ref,
          status: 503
        )

      assert {:retry, %{code: :provider_unavailable, stage: :create_change_request}} =
               StageRunner.advance(run.id)

      # This is P3's KNOWN LIMITATION window: the ref exists and still points
      # at base, with a commit built but unreferenced.
      %{refs: refs, commits: commits} = StubGitProvider.state(provider)
      assert refs[policy.allowed_head_ref] == origin.head_sha
      assert map_size(commits) == 2

      # The resume COMPLETES. `:head_ref_conflict` here would mean a run could
      # never recover from its own interrupted attempt.
      assert %WorkflowRun{status: "pr_open"} = advance!(run.id)

      # ONE effective commit across both attempts. The commit POST was issued
      # twice — the adapter cannot look a commit up by content — and both
      # bodies are byte-identical, INCLUDING the author/committer date, which
      # is what makes GitHub's content addressing hand back the same sha
      # instead of orphaning the first attempt's commit (§6.1, 2026-07-27).
      assert [first_post, second_post] = commit_posts(provider)
      assert first_post.body == second_post.body

      %{refs: after_refs, commits: after_commits, pulls: pulls} = StubGitProvider.state(provider)
      assert map_size(after_commits) == 2
      assert length(pulls) == 1

      {:ok, facts} = Store.read_facts(run.id)
      assert after_refs[policy.allowed_head_ref] == facts.head_sha
      assert facts.head_sha != origin.head_sha
    end

    test "a ref planted at base by someone else is resumed onto — the gap P4c did NOT close", %{
      run: run,
      binding: binding,
      provider: provider,
      policy: policy,
      origin: origin
    } do
      # CHARACTERIZATION, not an endorsement. `github_adapter.ex`'s KNOWN
      # LIMITATION names the workflow's durable facts as the identity that
      # would close this, and P4c writes `deterministic_head_ref` before the
      # first mutation so a resumed run HAS that fact. But nothing reads it:
      # grep for `deterministic_head_ref` outside `store.ex`/`workflow_facts.ex`
      # and the only hit is the write in `stage_runner.ex`. The fact is written
      # unconditionally, so it says "this ref NAME is mine", never "I created
      # that ref" — a foreign ref sitting at base is therefore still
      # indistinguishable from this run's own interrupted attempt.
      #
      # This test exists so the gap is visible and so closing it announces
      # itself here rather than silently.
      :ok = to_changes_ready!(run.id, binding)

      # A ref at base has no commit of its own to plant, which is precisely
      # why the adapter has nothing to check.
      :ok = StubGitProvider.set_ref(provider, policy.allowed_head_ref, origin.head_sha)

      assert %WorkflowRun{status: "pr_open"} = advance!(run.id)
      assert StubGitProvider.count(provider, "POST", "/git/refs") == 0
    end
  end

  # ---------------------------------------------------------------------------
  # Window 2 — the ref is advanced, the PR was never created
  # ---------------------------------------------------------------------------

  describe "§6.2 window 2 — head advanced, PR never created" do
    test "the resume creates exactly one PR and re-creates no git data", %{
      run: run,
      binding: binding,
      provider: provider,
      policy: policy
    } do
      :ok = to_changes_ready!(run.id, binding)

      :ok =
        StubGitProvider.fail_next(provider, method: "POST", suffix: "/pulls", status: 503)

      assert {:retry, %{code: :provider_unavailable}} = StageRunner.advance(run.id)

      %{refs: refs, pulls: pulls} = StubGitProvider.state(provider)
      assert refs[policy.allowed_head_ref] != nil
      assert pulls == []

      :ok = StubGitProvider.reset_log(provider)
      assert %WorkflowRun{status: "pr_open"} = advance!(run.id)

      # Nothing in the git-data chain was re-created on the way back.
      assert StubGitProvider.count(provider, "POST", "/git/refs") == 0
      assert StubGitProvider.count(provider, "POST", "/git/commits") == 0
      assert Enum.count(StubGitProvider.log(provider), &(&1.method == "PATCH")) == 0
      assert StubGitProvider.count(provider, "POST", "/pulls") == 1

      assert length(StubGitProvider.state(provider).pulls) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Window 4 — the facts are written, the state CAS never ran
  # ---------------------------------------------------------------------------

  describe "§6.2 window 4 — facts persisted, state CAS never ran" do
    test "the resume mutates nothing and lands on the same facts", %{
      run: run,
      binding: binding,
      provider: provider
    } do
      :ok = to_changes_ready!(run.id, binding)
      assert %WorkflowRun{status: "pr_open"} = advance!(run.id)
      {:ok, before_resume} = Store.read_facts(run.id)

      # Exactly what a crash between `persist_change_request/2` and
      # `Store.transition/4` leaves: the facts are there, the status is not.
      :ok = rewind!(run.id, "changes_ready")
      :ok = StubGitProvider.reset_log(provider)

      assert %WorkflowRun{status: "pr_open"} = advance!(run.id)

      assert StubGitProvider.mutating(provider) == []
      assert StubGitProvider.count(provider, "POST", "/pulls") == 0
      assert length(StubGitProvider.state(provider).pulls) == 1

      {:ok, after_resume} = Store.read_facts(run.id)
      assert after_resume.change_request_id == before_resume.change_request_id
      assert after_resume.head_sha == before_resume.head_sha
      assert after_resume.deterministic_head_ref == before_resume.deterministic_head_ref
    end
  end

  # ---------------------------------------------------------------------------
  # Convergence — an interrupted run and an uninterrupted one agree
  # ---------------------------------------------------------------------------

  describe "an interrupted run converges on the same terminal facts" do
    test "resumed from Postgres in a FRESH process, with nothing carried over", %{
      run: run,
      binding: binding,
      provider: provider,
      policy: policy
    } do
      :ok = to_changes_ready!(run.id, binding)

      # Interrupt in the middle of the git-data chain.
      :ok =
        StubGitProvider.fail_next(provider,
          method: "PATCH",
          suffix: policy.allowed_head_ref,
          status: 503
        )

      assert {:retry, _} = StageRunner.advance(run.id)

      # A different process, holding no state from the one that failed. The
      # seam backend is process-local by design, so installing it here is part
      # of what a fresh process does, not a shortcut around one.
      task =
        Task.async(fn ->
          :ok = ExecutionSeamTestDelegate.put_backend(CapBacked)
          StageRunner.advance(run.id)
        end)

      assert {:ok, %WorkflowRun{status: "pr_open"}} = Task.await(task, 30_000)
      assert {:ok, _} = Observation.tick(run.id)

      {:ok, interrupted} = Store.read_facts(run.id)

      # Now the same run again, start to finish, with nothing interrupted.
      :ok = rewind!(run.id, "accepted")
      :ok = to_changes_ready!(run.id, binding)
      assert %WorkflowRun{status: "pr_open"} = advance!(run.id)
      assert {:ok, _} = Observation.tick(run.id)

      {:ok, uninterrupted} = Store.read_facts(run.id)

      for field <- [
            :workspace_provision_id,
            :deterministic_head_ref,
            :change_digest,
            :expected_base_sha,
            :head_sha,
            :change_request_id,
            :change_request_url,
            :change_request_state,
            :change_request_head_ref,
            :change_request_base_ref,
            :checks_summary,
            :reviews_summary
          ] do
        assert Map.fetch!(interrupted, field) == Map.fetch!(uninterrupted, field),
               "#{field} diverged between the interrupted and uninterrupted executions"
      end

      # And the provider still holds one of everything.
      %{refs: refs, commits: commits, pulls: pulls} = StubGitProvider.state(provider)
      assert Map.keys(refs) |> Enum.sort() == Enum.sort(["main", policy.allowed_head_ref])
      assert map_size(commits) == 2
      assert length(pulls) == 1
    end
  end
end
