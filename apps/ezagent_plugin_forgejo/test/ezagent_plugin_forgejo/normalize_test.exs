defmodule EzagentPluginForgejo.NormalizeTest do
  @moduledoc """
  Forgejo response bodies → `Ezagent.DomainGit` values.

  The shapes here are taken from live responses recorded in
  `docs/superpowers/specs/2026-07-29-forgejo-api-probe-findings.md` §6, not
  invented: Forgejo's checks model is the older commit-status API, and its
  review list mixes review *requests* in with submitted reviews.
  """
  use ExUnit.Case, async: true

  alias Ezagent.DomainGit.{Check, ChangeRequest, Review}
  alias EzagentPluginForgejo.Normalize

  @pull %{
    "number" => 42,
    "html_url" => "https://code.hyprial.test/o/r/pulls/42",
    "state" => "open",
    "merged" => false,
    "head" => %{"ref" => "task/p4e/run-abc", "sha" => "A" |> String.duplicate(40)},
    "base" => %{"ref" => "main"}
  }

  describe "change_request/1" do
    test "normalizes an open pull request" do
      assert {:ok, %ChangeRequest{} = cr} = Normalize.change_request(@pull)

      assert cr.external_id == "42"
      assert cr.head_ref == "task/p4e/run-abc"
      assert cr.base_ref == "main"
      assert cr.state == :open
      assert URI.to_string(cr.url) == "https://code.hyprial.test/o/r/pulls/42"
    end

    test "lowercases the head sha" do
      assert {:ok, cr} = Normalize.change_request(@pull)
      assert cr.head_sha == String.duplicate("a", 40)
    end

    # `merged` is a separate boolean from `state`; a merged PR reports
    # state "closed". Reading only `state` would record every merged change
    # request as merely closed, which is a different fact.
    test "a merged pull request is :merged, not :closed" do
      merged = %{@pull | "state" => "closed", "merged" => true}
      assert {:ok, %ChangeRequest{state: :merged}} = Normalize.change_request(merged)
    end

    test "a closed-unmerged pull request is :closed" do
      closed = %{@pull | "state" => "closed", "merged" => false}
      assert {:ok, %ChangeRequest{state: :closed}} = Normalize.change_request(closed)
    end

    test "a response missing required fields is refused" do
      assert {:error, :provider_unavailable} = Normalize.change_request(%{"number" => 42})
    end

    test "a non-map response is refused" do
      assert {:error, :provider_unavailable} = Normalize.change_request("nope")
    end
  end

  describe "checks/1" do
    # Measured: `/statuses` returns the full re-run history (56 entries across
    # 17 contexts on one head); `/status` returns one per context. The adapter
    # reads the combined endpoint, so this takes its `statuses` array.
    test "normalizes one check per commit status" do
      combined = %{
        "state" => "failure",
        "total_count" => 2,
        "statuses" => [
          %{
            "id" => 1,
            "context" => "testing / test-pgsql",
            "status" => "failure",
            "target_url" => "https://code.hyprial.test/runs/1"
          },
          %{"id" => 2, "context" => "testing / lint", "status" => "success", "target_url" => ""}
        ]
      }

      assert {:ok, [first, second]} = Normalize.checks(combined)

      assert %Check{external_id: "1", name: "testing / test-pgsql"} = first
      assert first.status == :completed
      assert first.conclusion == :failed
      assert URI.to_string(first.url) == "https://code.hyprial.test/runs/1"

      assert %Check{name: "testing / lint", conclusion: :succeeded} = second
      assert second.url == nil
    end

    for {forgejo, status, conclusion} <- [
          {"pending", :in_progress, nil},
          {"success", :completed, :succeeded},
          {"failure", :completed, :failed},
          {"skipped", :completed, :skipped},
          {"error", :completed, :failed},
          {"warning", :completed, :neutral}
        ] do
      test "maps commit status #{forgejo}" do
        combined = %{"statuses" => [%{"id" => 9, "context" => "c", "status" => unquote(forgejo)}]}

        assert {:ok, [check]} = Normalize.checks(combined)
        assert check.status == unquote(status)
        assert check.conclusion == unquote(conclusion)
      end
    end

    # `error` and `warning` were NOT observed in sampling (findings §6.2), and
    # a future Forgejo may add more. An unknown value must degrade, never crash
    # and never be silently read as success.
    test "an unrecognised status degrades to :other rather than crashing" do
      combined = %{"statuses" => [%{"id" => 9, "context" => "c", "status" => "teleported"}]}

      assert {:ok, [check]} = Normalize.checks(combined)
      assert check.status == :completed
      assert check.conclusion == :other
    end

    # Plan E §6.3: empty checks is a valid fact and must not be faked into a pass.
    test "no statuses is an empty list, not a failure" do
      assert {:ok, []} = Normalize.checks(%{"state" => "pending", "statuses" => []})
    end

    # The live instance returns `"statuses": null` — not `[]` — for a commit no
    # CI has touched (verified against code.hyprial.com). Reading null as "a
    # shape I do not understand" turned "no checks yet" into a provider fault,
    # which only the live E2E could surface: the stub produced `[]`.
    test "a null statuses list is no checks, not a provider fault" do
      assert {:ok, []} =
               Normalize.checks(%{
                 "state" => "",
                 "sha" => "",
                 "total_count" => 0,
                 "statuses" => nil
               })
    end

    test "a malformed combined response is refused" do
      assert {:error, :provider_unavailable} = Normalize.checks(%{"statuses" => "not-a-list"})
    end
  end

  describe "reviews/1" do
    # Measured on live PRs: the list includes `REQUEST_REVIEW` entries, which
    # mean "a review was REQUESTED from someone" -- not a submitted review.
    # `DomainGit.Review.state` has no such member, and counting one as a review
    # would invent an event that never happened.
    test "drops review requests, keeping only submitted reviews" do
      body = [
        %{
          "id" => 1,
          "state" => "APPROVED",
          "dismissed" => false,
          "user" => %{"login" => "alice"},
          "submitted_at" => "2026-07-29T10:00:00Z"
        },
        %{
          "id" => 2,
          "state" => "REQUEST_REVIEW",
          "dismissed" => false,
          "user" => %{"login" => "bob"}
        }
      ]

      assert {:ok, [only]} = Normalize.reviews(body)
      assert %Review{external_id: "1", author_label: "alice", state: :approved} = only
    end

    test "drops pending drafts" do
      body = [
        %{"id" => 3, "state" => "PENDING", "dismissed" => false, "user" => %{"login" => "a"}}
      ]

      assert {:ok, []} = Normalize.reviews(body)
    end

    # `dismissed` is a boolean sitting BESIDE `state`, not a state value. Read
    # the state first and a dismissed approval still counts as an approval.
    test "a dismissed approval is :dismissed, not :approved" do
      body = [
        %{
          "id" => 4,
          "state" => "APPROVED",
          "dismissed" => true,
          "user" => %{"login" => "alice"},
          "submitted_at" => "2026-07-29T10:00:00Z"
        }
      ]

      assert {:ok, [%Review{state: :dismissed}]} = Normalize.reviews(body)
    end

    for {forgejo, state} <- [
          {"APPROVED", :approved},
          {"REQUEST_CHANGES", :changes_requested},
          {"COMMENT", :commented}
        ] do
      test "maps review state #{forgejo}" do
        body = [
          %{
            "id" => 5,
            "state" => unquote(forgejo),
            "dismissed" => false,
            "user" => %{"login" => "a"}
          }
        ]

        assert {:ok, [review]} = Normalize.reviews(body)
        assert review.state == unquote(state)
      end
    end

    # Corrected 2026-07-30: this used to assert `{:ok, []}`, i.e. it PINNED the
    # fail-open. "Dropped rather than guessed" conflated two different things —
    # not guessing a neighbouring state is right, but silently discarding a
    # submitted review the code cannot read is a loss, and the caller cannot
    # tell the difference between "no such review" and "we lost one".
    test "an unrecognised review state is refused rather than guessed or dropped" do
      body = [
        %{"id" => 6, "state" => "TELEPORTED", "dismissed" => false, "user" => %{"login" => "a"}}
      ]

      assert {:error, :provider_unavailable} = Normalize.reviews(body)
    end

    test "parses submitted_at when present" do
      body = [
        %{
          "id" => 7,
          "state" => "APPROVED",
          "dismissed" => false,
          "user" => %{"login" => "a"},
          "submitted_at" => "2026-07-29T10:00:00Z"
        }
      ]

      assert {:ok, [%Review{submitted_at: %DateTime{}}]} = Normalize.reviews(body)
    end

    test "a missing or unparseable submitted_at is nil, not a crash" do
      body = [
        %{"id" => 8, "state" => "APPROVED", "dismissed" => false, "user" => %{"login" => "a"}},
        %{
          "id" => 9,
          "state" => "APPROVED",
          "dismissed" => false,
          "user" => %{"login" => "b"},
          "submitted_at" => "not-a-date"
        }
      ]

      assert {:ok, [one, two]} = Normalize.reviews(body)
      assert one.submitted_at == nil
      assert two.submitted_at == nil
    end

    # Same correction. The dangerous shape is the MIXED list: an APPROVED that
    # parses beside a REQUEST_CHANGES that does not. Dropping produced
    # "approved=1" with the objection erased.
    test "a review without an identifiable author is refused, not dropped" do
      body = [%{"id" => 10, "state" => "APPROVED", "dismissed" => false, "user" => %{}}]
      assert {:error, :provider_unavailable} = Normalize.reviews(body)
    end

    test "empty reviews is an empty list, not a failure" do
      assert {:ok, []} = Normalize.reviews([])
    end

    test "a non-list response is refused" do
      assert {:error, :provider_unavailable} = Normalize.reviews(%{"unexpected" => true})
    end
  end

  describe "read-path fail-open boundaries" do
    # The dangerous asymmetry: an APPROVED that normalizes survives while a
    # REQUEST_CHANGES that does not is silently dropped. The caller then records
    # "1 review: approved=1" and a human's explicit objection has vanished from
    # the facts a gate runs on.
    #
    # Dropping a REQUEST_REVIEW is a deliberate FILTER — it is not a submitted
    # review. Dropping a submitted review this code cannot parse is a LOSS, and
    # the two must not share a code path.
    test "an unparseable submitted review is refused, not dropped" do
      body = [
        %{
          "id" => 1,
          "state" => "APPROVED",
          "dismissed" => false,
          "user" => %{"login" => "alice"},
          "submitted_at" => "2026-07-29T10:00:00Z"
        },
        # A submitted REQUEST_CHANGES whose author is unusable.
        %{"id" => 2, "state" => "REQUEST_CHANGES", "dismissed" => false, "user" => nil}
      ]

      assert {:error, :provider_unavailable} = Normalize.reviews(body)
    end

    test "an unknown submitted state is refused, not dropped" do
      body = [%{"id" => 3, "state" => "SOMETHING_NEW", "user" => %{"login" => "bob"}}]

      assert {:error, :provider_unavailable} = Normalize.reviews(body)
    end

    # Still a filter, not a loss: these are not submitted reviews.
    test "review requests and pending drafts are still filtered silently" do
      body = [
        %{"id" => 4, "state" => "REQUEST_REVIEW", "user" => %{"login" => "carol"}},
        %{"id" => 5, "state" => "PENDING", "user" => %{"login" => "dave"}}
      ]

      assert {:ok, []} = Normalize.reviews(body)
    end

    # `"statuses": nil` is MEASURED — a commit no CI has touched. An ABSENT key
    # is not: it has never been observed, and the adjacent clause already
    # refuses a non-list. Reporting "no checks" for an unmeasured shape is the
    # same fail-open in a different costume: the caller reads it as "nothing
    # failed".
    test "a combined status missing the statuses key is refused" do
      assert {:error, :provider_unavailable} =
               Normalize.checks(%{"state" => "failure", "total_count" => 1})
    end

    test "the measured empty shape is still an empty list, not a failure" do
      assert {:ok, []} = Normalize.checks(%{"statuses" => nil})
    end
  end
end
