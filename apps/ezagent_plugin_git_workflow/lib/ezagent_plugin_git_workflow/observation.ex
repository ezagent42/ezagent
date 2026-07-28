defmodule EzagentPluginGitWorkflow.Observation do
  @moduledoc """
  ONE observation tick — the repeatable step that carries a run from `pr_open`
  to `observations_current` and keeps it there (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §6.3 observation, §5.3 durable facts, §5.4 state machine, §7.2 retry policy).

  Like `EzagentPluginGitWorkflow.StageRunner`, this is a plain module: `tick/2`
  performs EXACTLY ONE observation and returns. Not a GenServer, not a
  supervision child, not a polling loop. Whoever drives the ticks owns the
  cadence.

  ## The five steps, and the only three actions

  | step | action | args |
  |---|---|---|
  | 1 | `:read_change_request` | `change_request_id`, `repository` |
  | 2 | `:list_checks` | `commit_sha`, `repository` |
  | 3 | `:list_reviews` | `change_request_id`, `repository` |
  | 4 | persist this tick's facts — ONE `Store.update_facts/2` | — |
  | 5 | CAS to `observations_current` | — |

  All three go through `EzagentPluginGitWorkflow.ExecutionSeam`, never a port or
  an adapter directly. All three are pure READS, which is what makes a repeat
  tick safe: §6.3's "重复 tick 只更新 snapshot revision/observed_at，不创建
  mutation". This module invokes nothing else — there is no call site here for
  `:create_change_request`, `:provision_workspace`, `:collect_workspace_changes`
  or `:cleanup_workspace`, and `observation_test.exs` asserts that ABSENCE
  across consecutive ticks rather than only asserting what did happen.

  ## Step 2 asks about THIS tick's head sha, never the stored one

  §6.3 step 2 says it outright: `list_checks` uses the `head_sha` from step 1's
  fresh read. The stored `head_sha` fact is what the PR's head was when it was
  created (or when the last tick ran) — a new push moves it, and checks for the
  old commit are a perfectly well-formed answer to the wrong question. The
  resulting row would pair a current PR state with stale checks and look
  entirely fine, which is why the value is threaded from the fresh read into
  `list_checks` and the SAME fresh value is written back to `head_sha`. One
  snapshot, one commit.

  The fresh read is additionally pinned to the change request the tick asked
  about: an answer whose `external_id` is not the one in the facts row is
  `:change_request_conflict`, not a snapshot to store. Writing another PR's
  state and checks under this run's `change_request_id` is the same class of
  internally-consistent-looking lie as the stale sha.

  ## One tick's facts are written TOGETHER

  `checks_summary`, `checks_revision`, `checks_observed_at`, `reviews_summary`,
  `reviews_revision`, `reviews_observed_at`, plus the `change_request_*` and
  `head_sha` the fresh read refreshed, all go in a SINGLE
  `Store.update_facts/2`. Two calls would let a crash in between leave checks
  from tick N beside reviews from tick N+1 — a snapshot that never existed at
  any moment, and one nothing downstream could detect.

  Both `observed_at` columns get the SAME value for the same reason: they date
  the TICK, not the individual HTTP round trips. Two timestamps microseconds
  apart would invite an operator to read a causal ordering into scheduling
  noise. They stay separate columns because §5.3 lists them separately and a
  later slice may observe one without the other.

  ## The revision rule: every tick that observed bumps it

  `checks_revision` and `reviews_revision` are incremented on EVERY tick that
  got an answer, whether or not the answer is byte-identical to the last one
  (`nil` → 1 → 2 → …). The alternative — bump only when the summary changed —
  is defensible, and is rejected here for two reasons:

    * §6.3 says a repeat tick "只更新 snapshot revision/observed_at". A repeat
      tick is precisely the one whose answer may be unchanged, so that sentence
      is about this case;
    * it makes the revision mean "how many times this run's checks were
      observed" — a fact the row can otherwise not express at all. Under a
      conditional bump, an unchanged row cannot distinguish "we re-queried and
      nothing moved" from "nobody ticked", which is the question an operator
      staring at a stalled PR actually has.

  A tick that FAILED (the provider was unavailable, the deadline was spent)
  writes nothing and bumps nothing, so the pair
  `(revision, observed_at)` always describes a real provider answer.

  Both counters therefore advance in lockstep in V1. They are separate columns
  anyway, per §5.3.

  ## Empty is a fact

  Empty checks and empty reviews are normal, successful observations. §7.2:
  "checks/reviews 尚未出现:observation 可重试,不算 provider failure". So an
  empty list does NOT block, does not retry, and does not fail — it is
  summarized by `EzagentPluginGitWorkflow.ObservationSummary` into a sentence
  that cannot be read as a pass or an approval, persisted, and the run advances
  to `observations_current`. Ticking again later is how the caller waits.

  ## Deadlines belong to the caller

  This module owns no clock beyond `DateTime.utc_now/0` for the snapshot
  timestamp: it never sleeps, never retries internally, never starts a timer.
  §7.2's "达到 deadline:明确 `blocked: observation_incomplete`" is served by
  `tick/2`'s `:deadline` option, and it is checked BEFORE anything is asked of
  the provider — a deadline enforced after the round trip has already paid the
  cost it existed to avoid.

  Passing no deadline means "observe once and tell me what is there", which
  never blocks on incompleteness. Passing an expired one means "my budget is
  spent", which always does.
  """

  alias Ezagent.DomainGit.ChangeRequest
  alias Ezagent.DomainGit.ChangeRequestId
  alias Ezagent.DomainGit.Check
  alias Ezagent.DomainGit.CommitSha
  alias Ezagent.DomainGit.Review
  alias Ezagent.Entity.GitTaskAccess
  alias EzagentPluginGitWorkflow.Authorization
  alias EzagentPluginGitWorkflow.AuthorizedTask
  alias EzagentPluginGitWorkflow.ExecutionSeam
  alias EzagentPluginGitWorkflow.ObservationSummary
  alias EzagentPluginGitWorkflow.RunFailure
  alias EzagentPluginGitWorkflow.Store
  alias EzagentPluginGitWorkflow.WorkflowFacts
  alias EzagentPluginGitWorkflow.WorkflowRun

  # `pr_open → observations_current` and `observations_current →
  # observations_current` are both legal edges in `WorkflowRun.@legal_edges`;
  # the self-loop is what makes repeat ticks work. Every other status owes no
  # tick — including `blocked`, so a blocked run is never re-observed into
  # looking healthy.
  @observable ["pr_open", "observations_current"]

  @stage :observation

  @type result ::
          {:ok, WorkflowRun.t()}
          | {:blocked, RunFailure.presentation()}
          | {:retry, RunFailure.presentation()}
          | {:error, term()}

  @doc """
  Performs ONE observation tick against the run's live change request.

  Options:

    * `:deadline` — a `DateTime`. When it is already past, the run CASes to
      `blocked` carrying `observation_incomplete` and NO provider call is made
      (§7.2). Absent (the default), incompleteness never blocks.
    * `:attempt` — labels the presentation only. This module neither counts
      attempts nor bounds them.

  Returns:

    * `{:ok, run}` — the snapshot is persisted and the run is at
      `observations_current`;
    * `{:blocked, presentation}` — a terminal blocker, or the deadline; the run
      is at `blocked` and the code is persisted;
    * `{:retry, presentation}` — a retryable failure; the status is unchanged
      and the code is persisted. Nothing was written to the facts row;
    * `{:error, {:unexpected_status, status}}` — the run owes no tick;
    * `{:error, reason}` — the run does not exist, or the CAS lost a race.
  """
  @spec tick(String.t(), keyword()) :: result()
  def tick(run_id, opts \\ []) when is_binary(run_id) and is_list(opts) do
    attempt = Keyword.get(opts, :attempt, 0)
    deadline = Keyword.get(opts, :deadline)

    case Store.read_run(run_id) do
      {:ok, run} -> tick_run(run, attempt, deadline)
      {:error, reason} -> {:error, reason}
    end
  end

  # The status gate runs FIRST: a run that owes no tick must be reported as
  # such, not re-blocked because a caller happened to pass a stale deadline.
  defp tick_run(%WorkflowRun{status: status} = run, attempt, deadline)
       when status in @observable do
    if spent?(deadline),
      do: RunFailure.block(run, @stage, attempt, :observation_incomplete),
      else: observe(run, attempt)
  end

  defp tick_run(%WorkflowRun{status: status}, _attempt, _deadline),
    do: {:error, {:unexpected_status, status}}

  defp spent?(nil), do: false
  defp spent?(%DateTime{} = deadline), do: DateTime.after?(DateTime.utc_now(), deadline)

  # ---------------------------------------------------------------------------
  # The tick
  # ---------------------------------------------------------------------------

  # `Authorization.authorized_task/1` re-asks the seam on every tick rather than
  # caching — see its own doc. The binding it also returns is not needed here:
  # everything this tick sends is either the policy's own copy or a fact from
  # the run's row.
  defp observe(%WorkflowRun{id: run_id} = run, attempt) do
    with {:ok, _binding, task} <- Authorization.authorized_task(run),
         {:ok, facts} <- read_facts(run_id),
         {:ok, change_request_id} <- change_request_id(facts),
         {:ok, fresh} <- read_change_request(task, change_request_id),
         {:ok, commit_sha} <- head_commit_sha(fresh),
         {:ok, checks} <- list_checks(task, commit_sha),
         {:ok, reviews} <- list_reviews(task, change_request_id),
         {:ok, _persisted} <- persist(run_id, facts, fresh, checks, reviews) do
      transition(run, "observations_current")
    else
      {:error, reason} -> RunFailure.fail(run, @stage, attempt, reason)
    end
  end

  # ---------------------------------------------------------------------------
  # Seam calls — the three, and nothing else
  # ---------------------------------------------------------------------------

  # `repository` is the policy's own copy rather than a caller-supplied one:
  # the action set compares the incoming repository against the policy and
  # refuses a mismatch, so passing anything else could only ever be a denial.
  defp invoke(%AuthorizedTask{policy: %GitTaskAccess{repository: repository}} = task, action, args),
    do: ExecutionSeam.invoke(task, action, Map.put(args, :repository, repository))

  # The `^asked` pin is the identity guard: a change request that is not the one
  # this run owns must not have its state and checks written under this run's
  # `change_request_id`.
  defp read_change_request(task, %ChangeRequestId{external_id: asked} = change_request_id) do
    case invoke(task, :read_change_request, %{change_request_id: change_request_id}) do
      {:ok, %ChangeRequest{external_id: ^asked} = fresh} -> {:ok, fresh}
      {:ok, %ChangeRequest{}} -> {:error, :change_request_conflict}
      {:ok, _other} -> {:error, :internal_error}
      {:error, reason} -> {:error, reason}
    end
  end

  # §6.3 step 2 — the sha comes out of the FRESH read, never out of the facts
  # row. See the moduledoc.
  defp head_commit_sha(%ChangeRequest{head_sha: head_sha}), do: CommitSha.new(%{value: head_sha})

  # NO `{:ok, []}` special case, deliberately: an empty list is a valid fact
  # (§6.3), and turning it into an error here is precisely the misreading
  # `ObservationSummary` exists to prevent — at the opposite extreme.
  defp list_checks(task, commit_sha) do
    case invoke(task, :list_checks, %{commit_sha: commit_sha}) do
      {:ok, checks} when is_list(checks) -> all_structs(checks, Check)
      {:ok, _other} -> {:error, :internal_error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_reviews(task, change_request_id) do
    case invoke(task, :list_reviews, %{change_request_id: change_request_id}) do
      {:ok, reviews} when is_list(reviews) -> all_structs(reviews, Review)
      {:ok, _other} -> {:error, :internal_error}
      {:error, reason} -> {:error, reason}
    end
  end

  # A list carrying anything but the normalized domain value is a port-contract
  # violation. It is refused here rather than at `ObservationSummary`, whose
  # clause heads would otherwise raise several frames deep inside a tick.
  defp all_structs(list, module) do
    if Enum.all?(list, &is_struct(&1, module)),
      do: {:ok, list},
      else: {:error, :internal_error}
  end

  # ---------------------------------------------------------------------------
  # Durable rows
  # ---------------------------------------------------------------------------

  defp read_facts(run_id) do
    case Store.read_facts(run_id) do
      {:ok, facts} -> {:ok, facts}
      {:error, _reason} -> {:error, :internal_error}
    end
  end

  # A run at `pr_open` whose facts row carries no `change_request_id` is a
  # runner defect, not a provider outcome: P4c writes that fact before it CASes
  # to `pr_open`, so its absence means the two disagree.
  defp change_request_id(%WorkflowFacts{change_request_id: external_id})
       when is_binary(external_id),
       do: ChangeRequestId.new(%{external_id: external_id})

  defp change_request_id(%WorkflowFacts{}), do: {:error, :internal_error}

  # THE single write (see the moduledoc). Eleven columns, one statement: the six
  # observation facts this tick produced plus the five the fresh read refreshed.
  #
  # `change_request_id` is deliberately NOT among them. It is identity, it was
  # established by the stage that created the request, and the tick asks BY it —
  # a row whose identity column could be rewritten from a response is a row that
  # can silently start describing a different pull request.
  defp persist(
         run_id,
         %WorkflowFacts{checks_revision: checks_revision, reviews_revision: reviews_revision},
         %ChangeRequest{
           url: url,
           state: state,
           head_ref: head_ref,
           head_sha: head_sha,
           base_ref: base_ref
         },
         checks,
         reviews
       ) do
    observed_at = DateTime.utc_now()

    result =
      Store.update_facts(run_id, %{
        change_request_url: URI.to_string(url),
        change_request_state: Atom.to_string(state),
        change_request_head_ref: head_ref,
        change_request_base_ref: base_ref,
        head_sha: head_sha,
        checks_summary: ObservationSummary.summarize_checks(checks),
        checks_revision: next_revision(checks_revision),
        checks_observed_at: observed_at,
        reviews_summary: ObservationSummary.summarize_reviews(reviews),
        reviews_revision: next_revision(reviews_revision),
        reviews_observed_at: observed_at
      })

    case result do
      {:ok, facts} -> {:ok, facts}
      # `:not_found` / `:unknown_fields` / `{:invalid_field, _}` are all defects
      # in this module, not provider outcomes, and `:internal_error` is terminal
      # — which is where a defect belongs.
      {:error, _reason} -> {:error, :internal_error}
    end
  end

  defp next_revision(nil), do: 1
  defp next_revision(revision) when is_integer(revision) and revision >= 0, do: revision + 1

  defp transition(%WorkflowRun{id: id, state_version: version, status: status}, next_status),
    do: Store.transition(id, version, status, next_status)
end
