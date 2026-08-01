defmodule EzagentPluginForgejo.Normalize do
  @moduledoc """
  Forgejo response bodies → `Ezagent.DomainGit` values.

  Kept separate from the adapter because it is pure: no credential, no HTTP, no
  instance. Every mapping below is anchored to a live response recorded in
  `docs/superpowers/specs/2026-07-29-forgejo-api-probe-findings.md` §6.

  ## Two places Forgejo differs from GitHub in a way that bites

  **Checks are the older commit-status model.** There is no Checks API. The
  adapter reads `GET /commits/{ref}/status` (combined, one entry per context)
  rather than `/statuses` (the full re-run history — measured at 56 entries
  across 17 contexts for a single head, with one context repeated 7 times).
  Normalizing the history would produce several `Check` records sharing a name
  and contradicting each other.

  **The review list contains review REQUESTS.** A `REQUEST_REVIEW` entry means
  "a review was requested from someone", not a submitted review, and
  `DomainGit.Review.state` has no member for it. Those entries are dropped;
  counting one would invent an event that never happened. `dismissed` is a
  boolean beside `state`, not a state value — read in the wrong order, a
  withdrawn approval still reads as an approval.

  ## Unknown values degrade only where the domain has somewhere honest to land

  `error` / `warning` commit statuses and the `REQUEST_CHANGES` / `COMMENT`
  review states were not observed during sampling, and a later Forgejo may add
  more.

  An unrecognized check conclusion becomes `:other`, because `Check.conclusion`
  declares that member and it means exactly "a value we have no mapping for".
  An unrecognized review state has no such member on `Review.state`, so it
  REFUSES the whole read as `:provider_response_unrecognized` — it is not
  dropped, which an earlier revision of this doc claimed and which would let a
  `REQUEST_CHANGES` disappear while the approvals beside it survived.

  Nothing here is read as success, and nothing raises.
  """

  alias Ezagent.DomainGit.{Check, ChangeRequest, Review}

  @doc "Normalizes a pull-request body into provider-neutral change-request facts."
  @spec change_request(term()) ::
          {:ok, ChangeRequest.t()} | {:error, :provider_response_unrecognized}
  def change_request(
        %{
          "number" => number,
          "html_url" => url,
          "state" => state,
          "head" => %{"ref" => head_ref, "sha" => head_sha},
          "base" => %{"ref" => base_ref}
        } = body
      )
      when is_binary(url) do
    attrs = %{
      external_id: to_string(number),
      # uri-canonical-allow: html_url is the provider's own web link to the pull request — an external http(s) URL, not an Ezagent-scheme URI.
      url: URI.parse(url),
      head_ref: head_ref,
      head_sha: head_sha,
      base_ref: base_ref,
      state: change_request_state(state, body["merged"])
    }

    case ChangeRequest.new(attrs) do
      {:ok, change_request} -> {:ok, change_request}
      {:error, _reason} -> {:error, :provider_response_unrecognized}
    end
  end

  def change_request(_body), do: {:error, :provider_response_unrecognized}

  @doc """
  Normalizes a `CombinedStatus` body into provider-neutral check facts.

  Takes the combined endpoint's `statuses` array, which Forgejo has already
  reduced to the latest entry per context.
  """
  @spec checks(term()) :: {:ok, [Check.t()]} | {:error, :provider_response_unrecognized}
  def checks(%{"statuses" => statuses}) when is_list(statuses) do
    statuses
    |> Enum.reduce_while({:ok, []}, fn status, {:ok, acc} ->
      case check(status) do
        {:ok, check} -> {:cont, {:ok, [check | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, checks} -> {:ok, Enum.reverse(checks)}
      {:error, reason} -> {:error, reason}
    end
  end

  # A commit no CI has touched comes back as `"statuses": null`, NOT `[]` --
  # measured against the live instance, and the one shape the stub never
  # produced. That is genuinely "no checks reported", so reporting a provider
  # fault for it would turn every fresh pull request into a failure.
  def checks(%{"statuses" => nil}), do: {:ok, []}

  # Any OTHER non-list `statuses` is a shape this code does not understand --
  # refuse rather than report "no checks", which a caller reads as "nothing
  # failed".
  def checks(%{"statuses" => _malformed}), do: {:error, :provider_response_unrecognized}

  # An ABSENT `statuses` key is refused, not read as "no checks".
  #
  # `"statuses": nil` is measured — it is what a commit no CI has touched
  # returns, key present. An absent key has never been observed, and the clause
  # directly above already refuses a non-list. Answering `{:ok, []}` for an
  # unmeasured shape is the same fail-open in a different costume: the caller
  # reads it as "nothing failed" and a real failing check disappears on a
  # response the code did not understand.
  def checks(_body), do: {:error, :provider_response_unrecognized}

  @doc """
  Normalizes a review list, keeping only genuinely submitted reviews.

  Review requests and unsubmitted drafts are dropped rather than mapped onto a
  state they do not mean.
  """
  @spec reviews(term()) :: {:ok, [Review.t()]} | {:error, :provider_response_unrecognized}
  def reviews(body) when is_list(body) do
    Enum.reduce_while(body, {:ok, []}, fn entry, {:ok, acc} ->
      case review(entry) do
        {:ok, [review]} -> {:cont, {:ok, [review | acc]}}
        {:ok, []} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reviews} -> {:ok, Enum.reverse(reviews)}
      {:error, reason} -> {:error, reason}
    end
  end

  def reviews(_body), do: {:error, :provider_response_unrecognized}

  # ── internals ────────────────────────────────────────────────────────

  # The status field is `status` on a nested CommitStatus but `state` on the
  # CombinedStatus wrapper — the SAME Go type (`CommitStatusState`) under two
  # JSON names, an upstream naming inconsistency rather than a semantic
  # distinction. Which makes it precisely the field a version bump might rename.
  #
  # So it is required to be a binary. An absent or non-string field is a shape
  # this code does not parse, and folding that into `:other` would silently
  # downgrade EVERY check on a schema change — `:other` means "a state we have
  # no mapping for", not "we could not find the state".
  defp check(%{"id" => id, "context" => context, "status" => raw} = status)
       when is_binary(raw) do
    {check_status, conclusion} = check_state(raw)

    attrs = %{
      external_id: to_string(id),
      name: context,
      status: check_status,
      conclusion: conclusion,
      url: web_uri(status["target_url"])
    }

    case Check.new(attrs) do
      {:ok, check} -> {:ok, check}
      {:error, _reason} -> {:error, :provider_response_unrecognized}
    end
  end

  defp check(_status), do: {:error, :provider_response_unrecognized}

  # `merged` is a boolean beside `state`; a merged pull request still reports
  # state "closed". Reading only `state` would record every merge as a plain
  # close, losing the one fact a reviewer cares about most.
  #
  # On a CLOSED pull request that boolean is the WHOLE answer, so an absent or
  # non-boolean one means we cannot tell a merge from a plain close — and
  # `:closed` is not a safe guess, it erases the merge. An OPEN pull request is
  # definitionally not merged and never consults it, which is also why the
  # pull-request LIST endpoint (no `merged` field) still normalizes.
  defp change_request_state("closed", true), do: :merged
  defp change_request_state("closed", false), do: :closed
  defp change_request_state("closed", _unreadable), do: nil
  defp change_request_state("open", _merged), do: :open
  defp change_request_state(_state, _merged), do: nil

  defp check_state("pending"), do: {:in_progress, nil}
  defp check_state("success"), do: {:completed, :succeeded}
  defp check_state("failure"), do: {:completed, :failed}
  defp check_state("error"), do: {:completed, :failed}
  defp check_state("warning"), do: {:completed, :neutral}
  defp check_state("skipped"), do: {:completed, :skipped}
  defp check_state(_unknown), do: {:completed, :other}

  # FILTERING and LOSING are different, and collapsing them was a fail-open.
  #
  # A `REQUEST_REVIEW` / `PENDING` entry is not a submitted review, so dropping
  # it is the contract. A SUBMITTED review this code cannot parse is something
  # else entirely: dropping it silently means an `APPROVED` that normalizes
  # survives while a `REQUEST_CHANGES` that does not simply disappears, and the
  # caller records "approved=1" with a human's explicit objection erased from
  # the facts a gate runs on.
  #
  # So: `{:ok, [review]}` kept, `{:ok, []}` deliberately filtered,
  # `{:error, _}` refused — the whole read fails rather than returning a
  # partial answer that reads as "nothing is blocking".
  defp review(%{"state" => state}) when state in ["REQUEST_REVIEW", "PENDING"], do: {:ok, []}

  defp review(%{"id" => id, "user" => %{"login" => login}} = entry)
       when is_binary(login) and login != "" do
    case review_state(entry) do
      nil ->
        {:error, :provider_response_unrecognized}

      state ->
        attrs = %{
          external_id: to_string(id),
          author_label: login,
          state: state,
          submitted_at: timestamp(entry["submitted_at"])
        }

        case Review.new(attrs) do
          {:ok, review} -> {:ok, [review]}
          {:error, _reason} -> {:error, :provider_response_unrecognized}
        end
    end
  end

  defp review(_entry), do: {:error, :provider_response_unrecognized}

  # Dismissal is checked BEFORE the state string: a dismissed approval is a
  # withdrawn approval, and reading `state` first would keep counting it.
  defp review_state(%{"dismissed" => true}), do: :dismissed
  defp review_state(%{"state" => "APPROVED"}), do: :approved
  defp review_state(%{"state" => "REQUEST_CHANGES"}), do: :changes_requested
  defp review_state(%{"state" => "COMMENT"}), do: :commented
  defp review_state(_entry), do: nil

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp timestamp(_value), do: nil

  # `target_url` is routinely an empty string rather than absent. `Check.url`
  # accepts nil, so an empty or malformed value becomes nil rather than
  # failing the whole normalization over a cosmetic link.
  defp web_uri(value) when is_binary(value) and value != "" do
    # uri-canonical-allow: target_url is a CI provider's external result link — an http(s) URL, not an Ezagent-scheme URI.
    uri = URI.parse(value)
    if ChangeRequest.web_uri?(uri), do: uri, else: nil
  end

  defp web_uri(_value), do: nil
end
