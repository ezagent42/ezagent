defmodule EzagentPluginGitWorkflow.ObservationSummaryTest do
  @moduledoc """
  Design §6.3's closing line — "空 checks 或空 reviews 是有效事实，不得伪造成
  通过或批准" — is the reason this module exists, so the two tests named for it
  assert against the ACTUAL string rather than a shape.

  Everything else here defends a property the tick depends on: a summary that
  churned with input order would rewrite the column every tick, and a summary
  that grew with input size would be the unbounded blob §5.3 forbids.
  """

  use ExUnit.Case, async: true

  alias Ezagent.DomainGit.Check
  alias Ezagent.DomainGit.Review
  alias EzagentPluginGitWorkflow.ObservationSummary

  @moduletag :observation

  # Every spelling an operator (or a downstream tool) could read as "this is
  # fine". A summary of NOTHING must contain none of them — including the bare
  # "0", which is the digit "0 failed" and "0 problems" are built out of.
  @reads_as_success ~w(pass passing passed success succeeded ok okay green
                       clean approve approved 0)

  defp check(opts) do
    %Check{
      external_id: Keyword.get(opts, :external_id, "chk-1"),
      name: Keyword.get(opts, :name, "build"),
      status: Keyword.fetch!(opts, :status),
      conclusion: Keyword.get(opts, :conclusion),
      url: Keyword.get(opts, :url)
    }
  end

  defp completed(conclusion), do: check(status: :completed, conclusion: conclusion)

  defp review(state, opts \\ []) do
    %Review{
      external_id: Keyword.get(opts, :external_id, "rev-1"),
      author_label: Keyword.get(opts, :author_label, "Reviewer"),
      state: state,
      submitted_at: Keyword.get(opts, :submitted_at)
    }
  end

  # ---------------------------------------------------------------------------
  # §6.3 — an empty list is a fact, never a verdict
  # ---------------------------------------------------------------------------

  describe "an empty checks list is a fact, not a pass" do
    test "the summary is the exact sentence, and P4e can ask for it by name" do
      assert ObservationSummary.summarize_checks([]) == "no checks reported"
      assert ObservationSummary.summarize_checks([]) == ObservationSummary.no_checks_reported()
    end

    test "no substring of it reads as success" do
      summary = ObservationSummary.summarize_checks([])
      downcased = String.downcase(summary)

      for word <- @reads_as_success do
        refute String.contains?(downcased, word),
               "the empty-checks summary #{inspect(summary)} contains #{inspect(word)}, " <>
                 "which reads as a verdict — §6.3 forbids faking an empty answer into one"
      end
    end

    test "it is NOT the zero case of the counted form" do
      # "0 checks: " would be arithmetically true and would read as "nothing
      # failed". The empty answer must be a different sentence, not that one.
      refute ObservationSummary.summarize_checks([]) =~ "checks:"
    end
  end

  describe "an empty reviews list is a fact, not an approval" do
    test "the summary is the exact sentence, and P4e can ask for it by name" do
      assert ObservationSummary.summarize_reviews([]) == "no reviews reported"
      assert ObservationSummary.summarize_reviews([]) == ObservationSummary.no_reviews_reported()
    end

    test "no substring of it reads as approval or as success" do
      summary = ObservationSummary.summarize_reviews([])
      downcased = String.downcase(summary)

      for word <- @reads_as_success ++ ~w(not blocked unblocked) do
        refute String.contains?(downcased, word),
               "the empty-reviews summary #{inspect(summary)} contains #{inspect(word)}"
      end
    end

    test "it is NOT the zero case of the counted form" do
      refute ObservationSummary.summarize_reviews([]) =~ "reviews:"
    end
  end

  # ---------------------------------------------------------------------------
  # Distinct outcomes must produce distinct summaries
  # ---------------------------------------------------------------------------

  describe "distinguishability" do
    test "all-succeeded, mixed, all-failed, still-running and empty are five strings" do
      summaries = [
        empty: ObservationSummary.summarize_checks([]),
        all_succeeded:
          ObservationSummary.summarize_checks([completed(:succeeded), completed(:succeeded)]),
        mixed: ObservationSummary.summarize_checks([completed(:succeeded), completed(:failed)]),
        all_failed: ObservationSummary.summarize_checks([completed(:failed), completed(:failed)]),
        running:
          ObservationSummary.summarize_checks([
            check(status: :in_progress),
            check(status: :queued)
          ])
      ]

      values = Keyword.values(summaries)
      assert length(Enum.uniq(values)) == 5, "collapsed: #{inspect(summaries)}"
    end

    test "one failure among successes is visible, and zero failures does not print as a failure count" do
      mixed = ObservationSummary.summarize_checks([completed(:succeeded), completed(:failed)])
      clean = ObservationSummary.summarize_checks([completed(:succeeded), completed(:succeeded)])

      assert mixed =~ "completed:failed=1"
      refute clean =~ "completed:failed"
    end

    test "every review state produces its own bucket" do
      for state <- [:approved, :changes_requested, :commented, :dismissed] do
        assert ObservationSummary.summarize_reviews([review(state)]) ==
                 "1 reviews: #{state}=1"
      end
    end

    test "an approval among change requests does not read as approved overall" do
      summary =
        ObservationSummary.summarize_reviews([
          review(:approved, external_id: "a"),
          review(:changes_requested, external_id: "b")
        ])

      assert summary == "2 reviews: approved=1 changes_requested=1"
    end
  end

  # ---------------------------------------------------------------------------
  # Order independence
  # ---------------------------------------------------------------------------

  describe "order independence" do
    test "shuffling the same check set produces a byte-identical summary" do
      checks = [
        completed(:succeeded),
        completed(:failed),
        check(status: :in_progress),
        completed(:skipped),
        check(status: :queued),
        completed(:succeeded)
      ]

      expected = ObservationSummary.summarize_checks(checks)

      for _ <- 1..25 do
        assert ObservationSummary.summarize_checks(Enum.shuffle(checks)) == expected
      end
    end

    test "shuffling the same review set produces a byte-identical summary" do
      reviews = [
        review(:approved, external_id: "a"),
        review(:commented, external_id: "b"),
        review(:changes_requested, external_id: "c"),
        review(:approved, external_id: "d")
      ]

      expected = ObservationSummary.summarize_reviews(reviews)

      for _ <- 1..25 do
        assert ObservationSummary.summarize_reviews(Enum.shuffle(reviews)) == expected
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Boundedness (§5.3 — no unbounded value in a fact column)
  # ---------------------------------------------------------------------------

  describe "boundedness" do
    test "200 checks stay under the stated cap" do
      conclusions =
        ~w(succeeded failed cancelled skipped neutral timed_out action_required other)a

      checks =
        Enum.map(1..200, fn i ->
          completed(Enum.at(conclusions, rem(i, length(conclusions))))
        end)

      summary = ObservationSummary.summarize_checks(checks)

      assert byte_size(summary) <= ObservationSummary.max_bytes()
      # And it did not grow per entry: 200 entries, at most 8 buckets.
      assert byte_size(summary) < 200
    end

    test "every bucket populated at once still fits, for checks and for reviews" do
      conclusions =
        ~w(succeeded failed cancelled skipped neutral timed_out action_required other)a

      checks =
        Enum.map(conclusions, &completed/1) ++
          [check(status: :queued), check(status: :in_progress)]

      # Repeat the whole vocabulary enough times that every count is 5 digits.
      many = List.duplicate(checks, 10_000) |> List.flatten()

      assert byte_size(ObservationSummary.summarize_checks(many)) <=
               ObservationSummary.max_bytes()

      reviews =
        [:approved, :changes_requested, :commented, :dismissed]
        |> Enum.map(&review/1)
        |> List.duplicate(10_000)
        |> List.flatten()

      assert byte_size(ObservationSummary.summarize_reviews(reviews)) <=
               ObservationSummary.max_bytes()
    end
  end

  # ---------------------------------------------------------------------------
  # §3.2 leak list
  # ---------------------------------------------------------------------------

  describe "nothing caller-shaped reaches the summary" do
    test "check names and URLs do not appear" do
      checks = [
        check(
          status: :completed,
          conclusion: :failed,
          name: "SECRET-CHECK-NAME",
          url: URI.parse("https://ci.example.test/SECRET-URL"),
          external_id: "SECRET-EXTERNAL-ID"
        )
      ]

      summary = ObservationSummary.summarize_checks(checks)

      for leak <- ~w(SECRET-CHECK-NAME SECRET-URL SECRET-EXTERNAL-ID ci.example.test https) do
        refute String.contains?(summary, leak), "#{leak} reached #{inspect(summary)}"
      end
    end

    test "review author labels and ids do not appear" do
      reviews = [
        review(:approved, author_label: "SECRET-AUTHOR", external_id: "SECRET-REVIEW-ID")
      ]

      summary = ObservationSummary.summarize_reviews(reviews)

      refute String.contains?(summary, "SECRET-AUTHOR")
      refute String.contains?(summary, "SECRET-REVIEW-ID")
    end
  end
end
