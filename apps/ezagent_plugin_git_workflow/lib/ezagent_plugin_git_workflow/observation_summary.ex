defmodule EzagentPluginGitWorkflow.ObservationSummary do
  @moduledoc """
  Bounded, order-independent summaries of ONE observation tick's checks and
  reviews (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §5.3 durable facts, §6.3 observation).

  ## The rule this module exists for

  §6.3 closes with:

  > 空 checks 或空 reviews 是有效事实，不得伪造成通过或批准。

  An empty checks list is a FACT: the provider answered, and it reported
  nothing. It is not `"0 failed"`, not `"passing"`, not `"all green"` — each of
  which is arithmetically defensible and reads as success, which is exactly the
  failure mode. The empty answers here are:

      summarize_checks([])  == "no checks reported"
      summarize_reviews([]) == "no reviews reported"

  Sentences, not tallies. An operator reading either one cannot extract a
  verdict from it, because there is no verdict in it.

  A summary is written ONLY when the provider answered. A tick whose
  `list_checks` call failed writes no facts at all and leaves the previous
  snapshot untouched (`EzagentPluginGitWorkflow.Observation` routes that through
  `Blocker`), so `"no checks reported"` never has to also carry the meaning "we
  could not ask" — it always means "we asked, and the answer was nothing".

  ## Buckets, not entries

  A summary aggregates by the closed vocabularies the domain values already
  declare — `Ezagent.DomainGit.Check`'s `status`/`conclusion` and
  `Ezagent.DomainGit.Review`'s `state`:

      summarize_checks(cs)  == "3 checks: completed:failed=1 completed:succeeded=2"
      summarize_reviews(rs) == "2 reviews: approved=1 changes_requested=1"

  Only non-zero buckets appear. `"1 failed"` and `"0 failed"` therefore never
  collapse to the same string: the second one has no `completed:failed` bucket
  at all.

  ## What is deliberately NOT in a summary

  No check name, no check URL, no review author label, no external id, no
  timestamp. Two independent reasons, and either alone would be sufficient:
  §3.2's leak list names them, and every one of them is caller-shaped free text,
  so including it would make the column unbounded. The bucket functions
  destructure ONLY `status`/`conclusion`/`state` out of their structs — a field
  this module never binds is a field it cannot leak.

  Nor is the raw list serialized into the column as JSON. §5.3 forbids an
  unbounded blob; a JSON list wearing a string's clothes is that blob.

  ## Ordering and boundedness

  Buckets are emitted in sorted label order, so shuffling the input produces a
  byte-identical summary. `list_checks` guarantees no ordering, and an
  order-dependent summary would rewrite the column on every tick for no reason
  — noise an operator would have to learn to ignore, in the one place they look
  to find out whether anything changed.

  Sorting is used rather than a hand-written vocabulary order for a second
  reason: a restated vocabulary drifts from the domain type's own, and the copy
  that drifts is the one that silently DROPS a bucket it does not recognise.
  Sorting cannot drop anything.

  `max_bytes/0` is the cap. It is derived, not guessed: `Check` declares three
  statuses and eight conclusions, so at most ten distinct check buckets exist,
  whose labels total 164 bytes; with the `=`, the separators and the `"N
  checks: "` prefix that is 192 bytes plus 11 count digits. 512 therefore holds
  for any check list whose length has up to 29 decimal digits — every list the
  VM can hold. Reviews declare four states and are far smaller.
  """

  alias Ezagent.DomainGit.Check
  alias Ezagent.DomainGit.Review

  @no_checks "no checks reported"
  @no_reviews "no reviews reported"
  @max_bytes 512

  @doc """
  The wording for "the provider answered, and reported no checks".

  Exposed as a function so a caller (P4e's acceptance run) asserts against the
  same value this module writes rather than a re-typed copy of it.
  """
  @spec no_checks_reported() :: String.t()
  def no_checks_reported, do: @no_checks

  @doc "The wording for \"the provider answered, and reported no reviews\"."
  @spec no_reviews_reported() :: String.t()
  def no_reviews_reported, do: @no_reviews

  @doc """
  The byte cap every summary this module produces stays under — see the
  moduledoc for the arithmetic that makes it a proof rather than a hope.
  """
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Summarizes one tick's checks.

  An EMPTY list is `no_checks_reported/0` — a statement of fact that cannot be
  read as success (§6.3). Every non-empty list is a total plus its non-zero
  status/conclusion buckets, in sorted label order.
  """
  @spec summarize_checks([Check.t()]) :: String.t()
  def summarize_checks([]), do: @no_checks

  def summarize_checks(checks) when is_list(checks),
    do: render(length(checks), "checks", Enum.frequencies_by(checks, &check_label/1))

  @doc """
  Summarizes one tick's reviews.

  An EMPTY list is `no_reviews_reported/0`. It is never "not blocked" and never
  anything that reads as approval — nobody approved anything, and that is what
  the row says.

  The counts are of review EVENTS exactly as the provider returned them, NOT of
  distinct reviewers: `Review` carries an optional `submitted_at`, so "the
  latest review per author" is not always derivable, and computing it from list
  position would make the summary order-dependent — the one property the
  moduledoc rules out.
  """
  @spec summarize_reviews([Review.t()]) :: String.t()
  def summarize_reviews([]), do: @no_reviews

  def summarize_reviews(reviews) when is_list(reviews),
    do: render(length(reviews), "reviews", Enum.frequencies_by(reviews, &review_label/1))

  # `Enum.sort/1` on `{label, count}` orders by label, and labels are unique
  # map keys, so the order is total and independent of the input's order.
  defp render(total, noun, counts) do
    buckets =
      counts
      |> Enum.sort()
      |> Enum.map_join(" ", fn {label, count} -> "#{label}=#{count}" end)

    "#{total} #{noun}: #{buckets}"
  end

  # A conclusion only exists once a check has completed (`Check` enforces
  # that), so the two-level label is the honest one: `completed:failed` says
  # both that the check finished AND how, while a bare `failed` would look like
  # a peer of `queued`.
  defp check_label(%Check{status: :completed, conclusion: conclusion}),
    do: "completed:" <> Atom.to_string(conclusion)

  defp check_label(%Check{status: status}), do: Atom.to_string(status)

  defp review_label(%Review{state: state}), do: Atom.to_string(state)
end
