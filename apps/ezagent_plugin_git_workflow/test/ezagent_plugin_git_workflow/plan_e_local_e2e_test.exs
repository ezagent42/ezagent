defmodule EzagentPluginGitWorkflow.PlanELocalE2ETest do
  @moduledoc """
  Slice P4e — design §8's local end-to-end acceptance run.

  The whole provider-owned loop, twice:

      accept task → authorize → prepare isolated workspace
      → test worker writes one bounded UTF-8 file → collect FileChange
      → mint scoped installation token → create/reconcile commit + branch + PR
      → read PR/checks/reviews → persist normalized facts

  See `EzagentPluginGitWorkflow.PlanEE2ECase` for what is real (everything
  but GitHub) and why §8's "显式 test-authorized execution backend" line is
  superseded by §3.4.

  ## Assertions are made against what the provider RECEIVED

  §8's "一个 deterministic ref / 一个 effective remote commit / 一个 PR /
  第二次没有重复 mutation" is checked by counting requests, not by reading
  the end state. The end state cannot distinguish "created once" from
  "created twice, the second was a no-op" — and those differ exactly where
  §6.2's crash windows live.
  """

  use EzagentPluginGitWorkflow.PlanEE2ECase

  alias EzagentPluginGitWorkflow.Authorization, as: Authz
  alias EzagentPluginGitWorkflow.Observation
  alias EzagentPluginGitWorkflow.StageRunner
  alias EzagentPluginGitWorkflow.StubGitProvider
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.WorkflowFacts
  alias EzagentPluginGitWorkflow.WorkflowRun

  @moduletag :plan_e_e2e

  @worker_file "notes.md"
  @worker_content "written by the task worker\n"

  # ---------------------------------------------------------------------------
  # The scenario, as one reusable pass
  # ---------------------------------------------------------------------------

  defp advance!(run_id) do
    assert {:ok, run} = StageRunner.advance(run_id)
    run
  end

  # `accepted → authorized` is `Authorization.authorize_run/2` — the same
  # production entry point §8's "authorize test task" names, and the one
  # design §3.1 requires to have zero side effects when it denies.
  defp authorize!(run_id, binding) do
    {:ok, run} = Store.read_run(run_id)

    assert {:ok, %WorkflowRun{status: "authorized"} = authorized} =
             Authz.authorize_run(run, binding)

    authorized
  end

  # §8's main scenario. `write_file` is what makes step 4 real: the collected
  # change comes from a file a worker actually wrote into the provisioned
  # worktree, never from a hand-built `%FileChange{}`.
  defp run_pass!(run_id, binding, opts \\ []) do
    authorize!(run_id, binding)
    assert %WorkflowRun{status: "workspace_ready"} = advance!(run_id)

    if Keyword.get(opts, :write_file, true) do
      write_worker_file!(run_id, Keyword.get(opts, :content, @worker_content))
    end

    assert %WorkflowRun{status: "changes_ready"} = advance!(run_id)
    assert %WorkflowRun{status: "pr_open"} = advance!(run_id)
    assert {:ok, %WorkflowRun{status: "observations_current"}} = Observation.tick(run_id)

    {:ok, facts} = Store.read_facts(run_id)
    facts
  end

  defp write_worker_file!(run_id, content, name \\ @worker_file) do
    {:ok, %WorkflowFacts{workspace_provision_id: provision_id}} = Store.read_facts(run_id)
    path = Path.join(worktree_path!(provision_id), name)
    File.write!(path, content)
    path
  end

  defp mutating_kinds(provider) do
    provider |> StubGitProvider.mutating() |> Enum.map(& &1.created)
  end

  # ---------------------------------------------------------------------------
  # §8 main scenario, executed twice
  # ---------------------------------------------------------------------------

  describe "§8 main scenario, run twice against the same run identity" do
    setup %{run: run, provider: provider, intent: intent, binding: binding} do
      first = run_pass!(run.id, binding)
      first_log = StubGitProvider.log(provider)
      :ok = StubGitProvider.reset_log(provider)

      # Re-accepting the SAME intent is idempotent: same run, no second row.
      assert {:ok, %WorkflowRun{id: reaccepted_id}} = Store.accept(intent)
      assert reaccepted_id == run.id

      # A crash between the facts write and the state CAS leaves exactly this
      # durable shape (§6.2's fourth window); it is also the only way to
      # replay a completed sequence, since §5.4 has no edge back.
      :ok = rewind!(run.id, "accepted")

      second = run_pass!(run.id, binding)

      %{first: first, first_log: first_log, second: second}
    end

    test "1 — exactly one run row", %{run: run} do
      %{rows: [[count]]} =
        Repo.query!("SELECT COUNT(*) FROM git_workflow_runs WHERE id = $1", [run.id])

      assert count == 1

      %{rows: [[total]]} = Repo.query!("SELECT COUNT(*) FROM git_workflow_runs")
      assert total == 1
    end

    test "2 — exactly one workspace provision, and the second pass reused it", %{
      first: first,
      second: second
    } do
      assert second.workspace_provision_id == first.workspace_provision_id

      %{rows: [[count]]} =
        Repo.query!(
          "SELECT COUNT(*) FROM git_task_workspace_provisions WHERE provision_id = $1",
          [
            first.workspace_provision_id
          ]
        )

      assert count == 1
    end

    test "3 — exactly one deterministic ref, and the second pass created none", %{
      provider: provider,
      first: first,
      policy: policy
    } do
      %{refs: refs} = StubGitProvider.state(provider)

      assert Map.keys(refs) |> Enum.sort() == Enum.sort(["main", policy.allowed_head_ref])
      assert first.deterministic_head_ref == policy.allowed_head_ref

      assert StubGitProvider.count(provider, "POST", "/git/refs") == 0
    end

    test "4 — exactly one effective remote commit, and the second pass created none", %{
      provider: provider,
      origin: origin,
      first: first
    } do
      %{commits: commits, refs: refs} = StubGitProvider.state(provider)

      # The seeded base plus exactly one commit this run produced.
      assert map_size(commits) == 2
      assert Map.has_key?(commits, origin.head_sha)
      assert refs[first.deterministic_head_ref] == first.head_sha
      assert commits[first.head_sha]["parents"] == [%{"sha" => origin.head_sha}]

      assert StubGitProvider.count(provider, "POST", "/git/commits") == 0
    end

    test "5 — exactly one PR, and the second pass issued no second POST /pulls", %{
      provider: provider,
      first: first
    } do
      %{pulls: pulls} = StubGitProvider.state(provider)

      assert [%{"number" => number}] = pulls
      assert first.change_request_id == to_string(number)

      assert StubGitProvider.count(provider, "POST", "/pulls") == 0
    end

    test "6 — the second pass fresh-reads but performs NO duplicate mutation", %{
      provider: provider
    } do
      log = StubGitProvider.log(provider)

      assert Enum.count(log, &(&1.method == "GET")) > 0

      # Every mutating verb §8 names, counted for the second pass alone.
      assert StubGitProvider.count(provider, "POST", "/git/refs") == 0
      assert StubGitProvider.count(provider, "POST", "/git/commits") == 0
      assert StubGitProvider.count(provider, "POST", "/pulls") == 0
      assert Enum.count(log, &(&1.method == "PATCH")) == 0

      # Blob/tree POSTs DO happen on the second pass — the adapter recomputes
      # this call's tree to prove the existing head is its own. They are
      # content-addressed no-ops, which is a claim about what they CREATED,
      # not about whether they were sent.
      assert StubGitProvider.count(provider, "POST", "/git/blobs") > 0
      assert mutating_kinds(provider) == []
    end

    test "7 — one token mint per adapter callback, and the mints are what carried it", %{
      provider: provider,
      first_log: first_log
    } do
      # Four adapter callbacks reach the provider in one pass: one
      # `create_change_request` plus the observation tick's three reads.
      # `provision_workspace` and `collect_workspace_changes` are workspace
      # actions and must mint nothing.
      assert Enum.count(first_log, &String.ends_with?(&1.path, "/access_tokens")) == 4
      assert Enum.count(first_log, &String.ends_with?(&1.path, "/installation")) == 4

      assert Enum.count(
               StubGitProvider.log(provider),
               &String.ends_with?(&1.path, "/access_tokens")
             ) ==
               4

      # The mint pair authenticates with the App JWT; every repository call
      # carries the minted installation token. A repository call that reached
      # the provider with no token would mean the mint was decorative.
      for entry <- first_log do
        expected =
          if String.ends_with?(entry.path, "/access_tokens") or
               String.ends_with?(entry.path, "/installation"),
             do: :app_jwt,
             else: :installation_token

        assert entry.authorization == expected, "#{entry.method} #{entry.path}"
      end
    end

    test "8 — the persisted facts agree with the provider's own responses", %{
      provider: provider,
      second: second,
      origin: origin,
      policy: policy
    } do
      %{pulls: [pull], refs: refs} = StubGitProvider.state(provider)

      assert second.change_request_id == to_string(pull["number"])
      assert second.change_request_url == pull["html_url"]
      assert second.change_request_state == "open"
      assert second.change_request_head_ref == policy.allowed_head_ref
      assert second.change_request_base_ref == "main"
      assert second.head_sha == refs[policy.allowed_head_ref]
      assert second.expected_base_sha == origin.head_sha

      # The observation snapshot is the provider's answer, normalized.
      assert second.checks_summary == "1 checks: completed:succeeded=1"
      assert second.reviews_summary == "1 reviews: approved=1"
      assert %DateTime{} = second.checks_observed_at

      # ONE, not two, and that is correct: replaying from `accepted` re-runs
      # the provision stage, whose `Store.upsert_facts/1` is a full-row
      # replace (the only stage for which that is safe — there is no earlier
      # stage's fact to erase). The revision counts observations of the CURRENT
      # facts row generation, and the second pass started a new one.
      assert second.checks_revision == 1
      assert second.reviews_revision == 1
    end

    test "commit_date is run.inserted_at and does not move between passes", %{
      first_log: first_log,
      run: run
    } do
      commit_post =
        Enum.find(
          first_log,
          &(&1.method == "POST" and String.ends_with?(&1.path, "/git/commits"))
        )

      # `Store.accept/1` returns the struct it inserted, which carries no
      # timestamps; the runner reads `inserted_at` off the ROW, so the row is
      # what this compares against.
      {:ok, %{inserted_at: %DateTime{} = accepted_at}} = Store.read_run(run.id)

      assert commit_post.body["author"] == commit_post.body["committer"]
      assert commit_post.body["author"]["date"] == DateTime.to_iso8601(accepted_at)

      # Not wall-clock "now" wearing a disguise: the accept happened before
      # every provider call in this test, so the two are ordered, and a
      # regression to reading the clock at commit-creation time would land
      # after them.
      assert DateTime.compare(accepted_at, DateTime.utc_now()) == :lt

      # `upsert_facts`' ON CONFLICT clause excludes `inserted_at` and the
      # rewind touches only `status`, so the second pass stamps the SAME date
      # — which is why the commit sha reproduces instead of orphaning.
      {:ok, after_second_pass} = Store.read_run(run.id)
      assert after_second_pass.inserted_at == accepted_at
    end
  end

  # ---------------------------------------------------------------------------
  # §8 assertion 7's negative half
  # ---------------------------------------------------------------------------

  describe "no token leaves the plugin" do
    test "the minted token appears in no persisted row, no telemetry event and no log line", %{
      run: run,
      token: token,
      binding: binding,
      provider: provider
    } do
      {telemetry, log_output} =
        ExUnit.CaptureLog.with_log(fn ->
          {_facts, events} = capture_telemetry(fn -> run_pass!(run.id, binding) end)
          events
        end)

      # This whole test is vacuous unless the token was really on the wire.
      # `:installation_token` is recorded only when the request's
      # `Authorization` header was byte-equal to `Bearer <token>`.
      assert provider
             |> StubGitProvider.log()
             |> Enum.count(&(&1.authorization == :installation_token)) > 0

      for value <- all_persisted_strings() do
        refute String.contains?(value, token), "token reached a persisted column"
        refute String.contains?(value, "ghs-"), "a GitHub token shape reached a persisted column"
      end

      refute String.contains?(log_output, token)
      refute String.contains?(log_output, "ghs-")

      # The repo query event carries the SQL and every bound parameter, so a
      # token that reached any column would appear here even if the write
      # were later rolled back.
      assert Enum.any?(telemetry, fn {event, _m, _md} ->
               event == [:ezagent_core, :repo, :query]
             end),
             "the repo telemetry event never fired — the leak sweep would be vacuous"

      refute telemetry
             |> inspect(limit: :infinity, printable_limit: :infinity)
             |> String.contains?(token)
    end

    test "the workspace start_token is not persisted into a workflow column either", %{
      run: run,
      binding: binding
    } do
      run_pass!(run.id, binding)

      %{rows: [[start_token]]} =
        Repo.query!("SELECT start_token FROM git_task_workspace_provisions LIMIT 1")

      assert is_binary(start_token) and start_token != ""

      for table <- ~w(git_workflow_facts git_workflow_runs git_workflow_bindings) do
        %{rows: rows} = Repo.query!("SELECT * FROM #{table}")

        refute rows
               |> List.flatten()
               |> Enum.any?(&(is_binary(&1) and String.contains?(&1, start_token))),
               "#{table} carries the workspace start token"
      end
    end
  end
end
