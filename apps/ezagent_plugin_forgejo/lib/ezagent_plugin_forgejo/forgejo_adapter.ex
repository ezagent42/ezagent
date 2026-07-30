defmodule EzagentPluginForgejo.ForgejoAdapter do
  @moduledoc """
  `Ezagent.DomainGit.Adapter` for Forgejo (and Gitea — same API base).

  All five callbacks. `create_change_request/4` is create-or-reconcile, not
  create-only: design §7.1's sequence, whose recovery rules exist because
  `POST /contents` is measurably NOT idempotent — identical content still
  produces a new commit and advances the branch (findings §3.3). Every retry
  therefore reads before it writes, and a branch already carrying this run's
  commit is recognised rather than written to twice.

  ## Every callback leases the credential again

  Design §4.2. Nothing is cached across callbacks: a credential revoked between
  two operations must stop working at the second one, and a cache would keep it
  alive. The plaintext token exists only between
  `EzagentPluginForgejo.CredentialSource.access_token/3` and the HTTP call.

  Unlike the GitHub adapter there is nothing to mint — the credential was
  issued once at authorization time — so each callback resolves the stored
  connection for `ctx.credential_owner_uri` on this repository's instance.

  ## Error mapping is per call site

  `EzagentPluginForgejo.ForgejoClient` returns protocol-level markers and
  refuses to guess what a 404 or 403 means; the same status means different
  things depending on the operation. A 5xx keeps its status through
  `{:provider_request_failed, op, status}`, and a transport failure reports
  status `0` — an explicit "no HTTP response arrived", which matters because
  the remote state is then unknown (design §8.3).
  """

  @behaviour Ezagent.DomainGit.Adapter

  alias Ezagent.DomainGit.{
    ChangeRequestId,
    CommitSha,
    CreateChangeRequest,
    FileChange,
    OperationContext,
    RepositoryRef
  }

  alias EzagentPluginForgejo.{CredentialSource, ForgejoClient, Instance, Normalize}

  @impl true
  def resolve_repository(%OperationContext{} = ctx, %RepositoryRef{external_id: id} = repo) do
    with {:ok, base, token} <- session(ctx, repo),
         {:ok, %{"full_name" => _full_name}} <-
           ForgejoClient.get(base, "/repos/#{id}", token, req_opts()) do
      {:ok, repo}
    else
      {:ok, _unexpected} -> {:error, :provider_unavailable}
      {:error, marker} -> {:error, map_error(marker, :resolve_repository, :read)}
    end
  end

  @impl true
  def read_change_request(
        %OperationContext{} = ctx,
        %RepositoryRef{external_id: id} = repo,
        %ChangeRequestId{external_id: external_id}
      ) do
    with {:ok, base, token} <- session(ctx, repo),
         {:ok, body} <-
           ForgejoClient.get(
             base,
             "/repos/#{id}/pulls/#{external_id}",
             token,
             req_opts()
           ) do
      Normalize.change_request(body)
    else
      {:error, marker} -> {:error, map_error(marker, :read_change_request, :read)}
    end
  end

  @impl true
  def list_checks(
        %OperationContext{} = ctx,
        %RepositoryRef{external_id: id} = repo,
        %CommitSha{value: sha}
      ) do
    # The COMBINED endpoint (`/status`), never `/statuses`. Measured: the
    # latter returns the full re-run history — 56 entries across 17 contexts on
    # a single head, one context repeated 7 times — which would become several
    # `Check` records sharing a name and contradicting each other.
    #
    # NOT paginated here, unlike `list_reviews/3` and the PR list. This endpoint
    # takes `page`/`limit` (target-instance swagger) but returns a single
    # CombinedStatus OBJECT with the statuses nested inside, so what paging does
    # to that object — slice the array and repeat the rollup, or something else
    # — is unmeasured. The probe repository has no CI, so it could not be
    # settled. Reading page 1 only is therefore a KNOWN residual limit: a head
    # with more distinct contexts than the instance default page size would
    # report a partial check list.
    #
    # To settle it: point a repo with >30 distinct status contexts at one head
    # and compare `?page=1&limit=1` with the unpaginated response. If the
    # statuses array slices, switch to the same all-pages read and merge on
    # `context`, keeping the LAST entry per context.
    with {:ok, base, token} <- session(ctx, repo),
         {:ok, body} <-
           ForgejoClient.get(
             base,
             "/repos/#{id}/commits/#{sha}/status",
             token,
             req_opts()
           ) do
      Normalize.checks(body)
    else
      {:error, marker} -> {:error, map_error(marker, :list_checks, :checks)}
    end
  end

  @impl true
  def list_reviews(
        %OperationContext{} = ctx,
        %RepositoryRef{external_id: id} = repo,
        %ChangeRequestId{external_id: external_id}
      ) do
    # Paginated: `ListPullReviews` takes `page`/`limit` (target-instance
    # swagger). A single GET returns only the first page, and the reviews it
    # drops are the OLDEST -- which is exactly where an earlier blocking
    # `REQUEST_CHANGES` sits, so truncation reads as "approved".
    with {:ok, base, token} <- session(ctx, repo),
         {:ok, body} <-
           all_pages(base, token, "/repos/#{id}/pulls/#{external_id}/reviews") do
      Normalize.reviews(body)
    else
      {:error, marker} -> {:error, map_error(marker, :list_reviews, :read)}
    end
  end

  @impl true
  def create_change_request(
        %OperationContext{} = ctx,
        %RepositoryRef{external_id: id, base_ref: base_ref} = repo,
        file_changes,
        %CreateChangeRequest{head_ref: head_ref} = request
      )
      when is_list(file_changes) do
    with :ok <- ensure_changes(file_changes),
         {:ok, base, token} <- session(ctx, repo),
         env <- %{base: base, token: token, id: id, base_ref: base_ref, head_ref: head_ref},
         :ok <- verify_base(env, request),
         {:ok, head} <- ensure_head(env, file_changes, request),
         :ok <- ensure_commit(env, head, file_changes, request) do
      find_or_create_pull(env, request)
    end
  end

  # ── §7.1 step 2: verify the base ─────────────────────────────────────

  defp verify_base(%{base_ref: base_ref} = env, %CreateChangeRequest{
         expected_base_sha: %CommitSha{value: expected}
       }) do
    case branch(env, base_ref) do
      {:ok, ^expected} -> :ok
      {:ok, _other} -> {:error, :base_sha_mismatch}
      {:error, :not_found} -> {:error, :base_ref_not_found}
      {:error, marker} -> {:error, map_error(marker, :create_change_request, :read)}
    end
  end

  # ── §7.1 steps 3-5: the deterministic head ref ───────────────────────
  #
  # `:already_written` short-circuits the write: the branch is already carrying
  # THIS run's commit, and `POST /contents` is not idempotent (findings §3.3),
  # so re-sending it would stack a second, content-identical commit.

  # Returns the state so `ensure_commit/4` does not have to re-derive it. The
  # provenance check costs one read PER CHANGED FILE, and `ChangeLimits` allows
  # 100 files, so re-running it here meant up to 200 serial reads on a resume
  # instead of 100 — and every extra read is another chance for the transient
  # failure that used to wedge the run.
  defp ensure_head(env, file_changes, request) do
    case head_state(env, file_changes, request) do
      # `create_branch/3` returns the state it ESTABLISHED, which is not always
      # `:at_base`: its 409 path reconciles and may find the branch already
      # carrying this run's commit. Hardcoding `:at_base` here discarded that and
      # wrote a second, content-identical commit — `POST /contents` is not
      # idempotent, so that is a real duplicate.
      {:ok, :absent} ->
        create_branch(env, file_changes, request)

      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp head_state(
         %{head_ref: head_ref} = env,
         file_changes,
         %CreateChangeRequest{
           expected_base_sha: %CommitSha{value: base_sha}
         } = req
       ) do
    case branch_commit(env, head_ref) do
      {:error, :not_found} ->
        {:ok, :absent}

      {:error, marker} ->
        {:error, map_error(marker, :create_change_request, :read)}

      {:ok, %{"id" => ^base_sha}} ->
        {:ok, :at_base}

      {:ok, commit} ->
        # Advanced past base. The only safe reading is "this run already wrote
        # it" -- and that is decided by comparing what a re-run WOULD produce,
        # never by assuming. Anything else is someone else's branch and must
        # not be resumed onto or force-moved.
        case ours?(env, file_changes, commit, req) do
          {:ok, true} -> {:ok, :already_written}
          {:ok, false} -> {:error, :head_ref_conflict}
          {:error, marker} -> {:error, map_error(marker, :create_change_request, :read)}
        end
    end
  end

  # The commit sha is a pure function of (parent, tree, message, author,
  # committer, dates) -- measured, findings §3.2. The adapter cannot compute it
  # locally without implementing Git object hashing, so it compares every input
  # it pinned when writing: `write_contents/3` sets `message`, `author`,
  # `committer` and both `dates` from the request.
  #
  # The message ALONE is not a provenance criterion -- a change-request title is
  # public, so anyone can author a commit carrying it. Matching on it alone was
  # fail-open: a branch advanced by someone else whose message happened to equal
  # our title read as `:already_written`, skipping the write and opening a PR
  # that points at THEIR content. Every pinned field must match.
  #
  # `parents` is not available here: the branch endpoint's commit object carries
  # {id, message, timestamp, author, committer, url, verification} and no parent
  # list (measured on the target instance). The date is what carries the weight
  # -- it is second-precision and taken from the caller's `commit_date`, so a
  # foreign commit must coincide on title, both identities AND that exact
  # timestamp to be misread.
  # Three-valued on purpose: `{:ok, true|false}` when the answer is known, and
  # `{:error, marker}` when it could not be determined. Collapsing the third
  # case into `false` reported "someone else's branch" for what was actually a
  # failed read — and `:head_ref_conflict` is a TERMINAL blocker for the
  # workflow, so one transient 5xx during a resume permanently wedged a run
  # whose write had in fact landed. Design §8.3: a transport failure means the
  # remote state is UNKNOWN, and unknown must not be answered as known.
  defp ours?(env, file_changes, commit, %CreateChangeRequest{
         title: title,
         commit_date: commit_date
       })
       when is_map(commit) do
    metadata? =
      String.trim(to_string(commit["message"] || "")) == String.trim(title) and
        same_identity?(commit["author"]) and same_identity?(commit["committer"]) and
        same_instant?(commit["timestamp"], commit_date)

    # Metadata first: it costs nothing. Only a metadata match is worth N reads.
    if metadata?, do: same_content?(env, file_changes, commit["id"]), else: {:ok, false}
  end

  defp ours?(_env, _file_changes, _commit, _request), do: {:ok, false}

  # Metadata alone is NOT provenance. message, identity and date are all derived
  # from the RUN, so a second attempt carrying different `file_changes` shares
  # every one of them -- and skipping the write there would open a change request
  # pointing at the first attempt's content.
  #
  # GitHub's adapter closes this by recomputing the tree sha, which its
  # content-addressed, idempotent blob/tree writes make free
  # (`github_adapter.ex:298`). Forgejo has no Git Data write chain (findings §1),
  # so the tree sha cannot be obtained that way. What IS available: `/contents`
  # returns the standard git blob sha (measured -- `sha1("blob <len>\0" <> body)`),
  # so every changed file's expected sha is computable LOCALLY, and the read it
  # is compared against is one `file_operations/2` performs anyway on the write
  # path.
  #
  # Residual, deliberately not closed: this proves every file this call WOULD
  # write already carries exactly that content. It does not prove nothing ELSE
  # was changed in the same commit -- that needs the full tree, i.e. a recursive
  # tree read plus a local reimplementation of git tree hashing (mode bits,
  # entry ordering, submodules). Reaching it requires every metadata field to
  # coincide first. Recorded in design §12.4.
  # Reads are pinned to `commit_id`, NOT to the branch name. The metadata came
  # from one specific commit; a branch can advance between that read and each
  # content read, and then every file can match individually while no single
  # commit carries the whole expected set. Measured: `/contents` accepts a commit
  # sha as `ref`.
  #
  # Stops at the first mismatch, so a foreign branch costs one read, not N.
  defp same_content?(env, file_changes, commit_id) when is_binary(commit_id) do
    Enum.reduce_while(file_changes, {:ok, true}, fn %FileChange{path: path, content: content},
                                                    acc ->
      case blob_sha(env, path, commit_id) do
        {:ok, sha} when is_binary(sha) ->
          if sha == git_blob_sha(content), do: {:cont, acc}, else: {:halt, {:ok, false}}

        # Absent is a definite answer: a file this call would write is not there,
        # so the commit is not this call's.
        {:ok, nil} ->
          {:halt, {:ok, false}}

        {:error, marker} ->
          {:halt, {:error, marker}}
      end
    end)
  end

  defp same_content?(_env, _file_changes, _absent_commit_id), do: {:ok, false}

  # `sha1("blob <byte_size>\0" <> content)` — the git object id of a blob. Pure,
  # local, no request.
  defp git_blob_sha(content) do
    :crypto.hash(:sha, "blob #{byte_size(content)}\0" <> content)
    |> Base.encode16(case: :lower)
  end

  defp same_identity?(%{"name" => name, "email" => email}) do
    %{name: expected_name, email: expected_email} = commit_identity()
    name == expected_name and email == expected_email
  end

  defp same_identity?(_absent), do: false

  # Compared as instants, not strings: Forgejo echoes the timestamp in the
  # instance's own offset (`+08:00` observed), so a byte comparison against the
  # UTC value the adapter sent would never match a commit it really wrote.
  defp same_instant?(timestamp, %DateTime{} = commit_date) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, at, _offset} -> DateTime.compare(at, git_instant(commit_date)) == :eq
      _unparsable -> false
    end
  end

  defp same_instant?(_timestamp, _commit_date), do: false

  # Git stores commit times as epoch SECONDS. `commit_date` is
  # `git_workflow_runs.inserted_at`, whose column is `:utc_datetime_usec`, so it
  # arrives with microseconds — which Git and Forgejo both drop.
  #
  # Truncating here is what makes the round trip closed: the same value is sent
  # as `dates` and compared against what comes back, so a commit this adapter
  # wrote is recognised. Comparing the untruncated value never matched, which
  # made every lost-response resume report `:head_ref_conflict` against its own
  # work. Truncation does not weaken the check — the discarded precision was
  # never transmitted in the first place.
  defp git_instant(%DateTime{} = at), do: DateTime.truncate(at, :second)

  defp create_branch(
         %{base: base, token: token, id: id, head_ref: head_ref} = env,
         file_changes,
         %CreateChangeRequest{
           expected_base_sha: %CommitSha{value: base_sha}
         } = request
       ) do
    body = %{new_branch_name: head_ref, old_ref_name: base_sha}

    case ForgejoClient.post(base, "/repos/#{id}/branches", token, body, req_opts()) do
      # Freshly created at the verified base: writable, nothing on it yet.
      {:ok, _created} ->
        {:ok, :at_base}

      # 409 from THIS endpoint means the branch appeared between the read and
      # the create -- a concurrent-creation race, benign. (`POST /contents`
      # reports the same situation as 422 -- two endpoints, two codes, measured.)
      #
      # Re-read through the FULL reconciliation, not just "is it still at base?".
      # The racing writer is usually the same logical run executing twice, so the
      # commit now on the branch is the one this call would have produced;
      # answering `:head_ref_conflict` on sight would make two identical runs
      # fail to converge. `head_state/2` still refuses anything that is not ours.
      {:error, :conflict} ->
        reconcile_head(env, file_changes, request, [:at_base, :already_written])

      {:error, marker} ->
        {:error, map_error(marker, :create_change_request, :write)}
    end
  end

  # ── §7.1 step 6: the commit ──────────────────────────────────────────

  # Takes the state `ensure_head/3` already established. It used to call
  # `head_state/3` a second time, which on a resume repeated the whole
  # per-file provenance read.
  defp ensure_commit(_env, :already_written, _file_changes, _request), do: :ok

  defp ensure_commit(env, _writable, file_changes, request),
    do: write_contents(env, file_changes, request)

  defp write_contents(
         %{base: base, token: token, id: id, head_ref: head_ref} = env,
         file_changes,
         %CreateChangeRequest{title: title, commit_date: commit_date} = request
       ) do
    with {:ok, files} <- file_operations(env, file_changes) do
      # Same truncation as `git_instant/1` in `ours?/2`: what is written and
      # what is compared must be the same value, or a resume cannot recognise
      # its own commit.
      stamp = commit_date |> git_instant() |> DateTime.to_iso8601()

      body = %{
        branch: head_ref,
        message: title,
        files: files,
        author: commit_identity(),
        committer: commit_identity(),
        dates: %{author: stamp, committer: stamp}
      }

      case ForgejoClient.post(base, "/repos/#{id}/contents", token, body, req_opts()) do
        {:ok, _written} ->
          :ok

        # The state read a moment ago is stale: someone wrote between the read
        # and this call. Re-read once through the full reconciliation -- for two
        # identical runs the writer was the other run, and its commit is the one
        # this call would have produced, so the correct answer is to converge on
        # it rather than to report a conflict. `head_state/2` still refuses a
        # commit that is not ours, so this cannot resume onto a foreign branch.
        #
        # Re-read ONCE. `POST /contents` is not idempotent (findings §3.3), so
        # retrying the write here would stack a second commit; and looping would
        # spin against a branch someone else is actively moving.
        {:error, marker} when marker in [:file_exists, :branch_exists] ->
          with {:ok, _state} <-
                 reconcile_head(env, file_changes, request, [:already_written]),
               do: :ok

        # `sha_required` is NOT a concurrency signal: it means this adapter built
        # an `update` operation without the blob sha, which is an internal
        # construction error. Design §8 gives it its own stable code so a caller
        # does not retry a request that cannot succeed no matter how the remote
        # state moves.
        {:error, :sha_required} ->
          {:error, :invalid_file_change}

        {:error, marker} ->
          {:error, map_error(marker, :create_change_request, :write)}
      end
    end
  end

  # The single re-read both benign races converge through. `accept` differs by
  # call site because the same state means different things:
  #
  #   * after a 409 from `POST /branches`, `:at_base` is the ordinary outcome --
  #     the concurrent creator made the branch but has not written yet, so this
  #     call proceeds and `ensure_commit/3` writes onto it;
  #   * after a file-exists 422 from `POST /contents`, `:at_base` is
  #     contradictory (a file cannot exist on a branch still at base) and
  #     accepting it would report success for a write that never landed.
  #
  # `head_state/2` refuses a commit that is not ours in both cases, so neither
  # site can resume onto a foreign branch.
  defp reconcile_head(env, file_changes, request, accept) do
    case head_state(env, file_changes, request) do
      {:ok, state} -> if state in accept, do: {:ok, state}, else: {:error, :head_ref_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  # `FileChange.valid_path?/1` admits `#`, `?` and `%`. Interpolated raw, they
  # are parsed as fragment/query and the GET reads a DIFFERENT resource — which
  # 404s, so the adapter plans a `create`, Forgejo answers file-exists 422
  # against the real path in the JSON body, and an encoding bug surfaces as a
  # concurrency conflict. Segments are encoded individually so `/` keeps its
  # meaning as the path separator.
  defp encode_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &URI.encode(&1, fn c -> URI.char_unreserved?(c) end))
  end

  # Forgejo has no upsert: `create` and `update` are exclusive and `update` must
  # carry the file's current blob sha (findings §3.4). So each path is read
  # first. The read-to-write window is covered by the 422 handling above.
  defp file_operations(env, file_changes) do
    Enum.reduce_while(file_changes, {:ok, []}, fn %FileChange{path: path} = change, {:ok, acc} ->
      case blob_sha(env, path) do
        {:ok, nil} ->
          {:cont, {:ok, [create_op(change) | acc]}}

        {:ok, sha} ->
          {:cont,
           {:ok, [Map.put(create_op(change), :sha, sha) |> Map.put(:operation, "update") | acc]}}

        {:error, marker} ->
          {:halt, {:error, map_error(marker, :create_change_request, :read)}}
      end
    end)
    |> case do
      {:ok, ops} -> {:ok, Enum.reverse(ops)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_op(%FileChange{path: path, content: content}),
    do: %{operation: "create", path: path, content: Base.encode64(content)}

  defp blob_sha(%{head_ref: head_ref} = env, path), do: blob_sha(env, path, head_ref)

  defp blob_sha(%{base: base, token: token, id: id}, path, ref) do
    case ForgejoClient.get(
           base,
           "/repos/#{id}/contents/#{encode_path(path)}?ref=#{URI.encode_www_form(ref)}",
           token,
           req_opts()
         ) do
      # `sha` does NOT mean the same thing for every `type` (measured on the
      # target instance, swagger `ContentsResponse`):
      #
      #   file      -> blob sha of the content
      #   symlink   -> blob sha of the TARGET PATH string -- still a blob sha, so
      #                it compares correctly and simply will not equal a plain
      #                file's content, which is the right answer
      #   submodule -> the pointed-at COMMIT sha, not a blob sha at all
      #   dir       -> a tree sha
      #
      # Returning a submodule's or a directory's sha as if it were a blob sha
      # makes every comparison false, so a path occupied by one of them would
      # report `:head_ref_conflict` forever -- a fail-closed wedge wearing a
      # concurrency conflict's name. They get their own marker instead.
      #
      # An ABSENT `type` is treated as a file: older instances (and any shape
      # this probe did not see) omit it, and absence is not evidence of a
      # non-file.
      {:ok, %{"type" => type, "sha" => _sha}} when type in ["submodule", "dir"] ->
        {:error, :unwritable_path_kind}

      {:ok, %{"sha" => sha}} when is_binary(sha) ->
        {:ok, sha}

      {:ok, _other} ->
        {:ok, nil}

      {:error, :not_found} ->
        {:ok, nil}

      {:error, marker} ->
        {:error, marker}
    end
  end

  # ── §7.1 steps 7-8: PR find-or-create ────────────────────────────────

  defp find_or_create_pull(env, request) do
    case open_pulls(env) do
      {:ok, pulls} ->
        # `GET /pulls` has NO head/base filter (measured, findings §2.1), so
        # the exact match is made here. `/pulls/{base}/{head}` exists but
        # returns the OLDEST match regardless of state -- a trap, not a
        # shortcut (findings §2.2).
        case Enum.filter(pulls, &exact_match?(&1, env)) do
          [] -> create_pull(env, request)
          [single] -> Normalize.change_request(single)
          [_ | _] -> {:error, :change_request_conflict}
        end

      {:error, marker} ->
        {:error, map_error(marker, :create_change_request, :read)}
    end
  end

  defp exact_match?(pull, %{head_ref: head_ref, base_ref: base_ref}) when is_map(pull) do
    get_in(pull, ["head", "ref"]) == head_ref and get_in(pull, ["base", "ref"]) == base_ref
  end

  defp exact_match?(_pull, _env), do: false

  # `GET /pulls` has no head/base filter (findings §2.1), so the match is made
  # client-side over the whole open list -- which means the whole list has to be
  # read. Stopping at the first page turned "the PR is on page 2" into "there is
  # no PR" and opened a SECOND one, defeating the find-or-create this path
  # exists for. It also downgraded a two-match ambiguity to a silent reuse when
  # the matches straddled a page boundary.
  @page_size 50
  # The bound is in ITEMS, not pages, because the page length is the instance's
  # choice: `max_response_items` can be lower than `@page_size`, and a
  # page-counted cap then silently shrinks with it (20 pages x a 20-item cap =
  # 380 reachable PRs, not the 1000 a page count suggests).
  #
  # Past the bound the read is REFUSED rather than truncated -- a truncated list
  # is indistinguishable from "no match" and would create a duplicate PR.
  @max_items 2_000

  defp open_pulls(%{base: base, token: token, id: id}),
    do: all_pages(base, token, "/repos/#{id}/pulls?state=open")

  # Reads a paginated list endpoint to exhaustion. Every list endpoint this
  # adapter touches takes `page`/`limit` (target-instance swagger), and for all
  # of them a truncated read is indistinguishable from a short one -- which is
  # why the cap REFUSES rather than returning what it has.
  defp all_pages(base, token, path), do: all_pages(base, token, path, 1, [])

  defp all_pages(_base, _token, _path, _page, acc) when length(acc) >= @max_items,
    do: {:error, :provider_unavailable}

  defp all_pages(base, token, path, page, acc) do
    joiner = if String.contains?(path, "?"), do: "&", else: "?"
    url = "#{path}#{joiner}limit=#{@page_size}&page=#{page}"

    case ForgejoClient.get(base, url, token, req_opts()) do
      # ONLY an empty page ends the read. `limit` is a request, not a promise:
      # `max_response_items` is an instance setting (50 on the probe instance,
      # configurable lower), so a FULL page can come back shorter than asked
      # for. Inferring "last page" from a short page stops mid-list on any
      # instance capped below @page_size — and a truncated list is
      # indistinguishable from no-match, which creates a duplicate PR.
      #
      # The cost is one extra request per read. That is the correct trade
      # against silently missing a page.
      {:ok, []} ->
        {:ok, acc}

      {:ok, items} when is_list(items) ->
        all_pages(base, token, path, page + 1, acc ++ items)

      {:ok, _other} ->
        {:error, :provider_unavailable}

      {:error, marker} ->
        {:error, marker}
    end
  end

  defp create_pull(
         %{base: base, token: token, id: id, head_ref: head_ref, base_ref: base_ref},
         %CreateChangeRequest{title: title, body: body}
       ) do
    payload = %{title: title, body: body, head: head_ref, base: base_ref}

    case ForgejoClient.post(base, "/repos/#{id}/pulls", token, payload, req_opts()) do
      {:ok, created} -> Normalize.change_request(created)
      {:error, :conflict} -> {:error, :change_request_conflict}
      {:error, marker} -> {:error, map_error(marker, :create_change_request, :write)}
    end
  end

  # ── shared reads ─────────────────────────────────────────────────────

  defp branch(env, ref) do
    case branch_commit(env, ref) do
      {:ok, %{"id" => sha}} when is_binary(sha) -> {:ok, sha}
      {:ok, _other} -> {:error, :provider_unavailable}
      {:error, marker} -> {:error, marker}
    end
  end

  defp branch_commit(%{base: base, token: token, id: id}, ref) do
    case ForgejoClient.get(
           base,
           "/repos/#{id}/branches/#{ref}",
           token,
           req_opts()
         ) do
      {:ok, %{"commit" => commit}} when is_map(commit) -> {:ok, commit}
      {:ok, _other} -> {:error, :provider_unavailable}
      {:error, marker} -> {:error, marker}
    end
  end

  # Empty change sets never reach the provider: design §2.2 has no meaning for
  # a commit with nothing in it, and the workflow reports its own
  # `no_changes_collected` blocker before this point.
  defp ensure_changes([]), do: {:error, :invalid_file_change}
  defp ensure_changes(_changes), do: :ok

  # The Git identity on the commit. Not the connected user: the credential owner
  # authorized the operation but did not author the text, and the timestamp is
  # already the run's (design §6.1) rather than a wall clock.
  defp commit_identity, do: %{name: "Ezagent", email: "ezagent@invalid"}

  # ── internals ────────────────────────────────────────────────────────

  # One lease per callback, and the base URL derived from THIS repository's
  # instance — two bindings in one VM routinely point at different servers.
  defp session(%OperationContext{credential_owner_uri: owner_uri}, %RepositoryRef{
         provider_host: host
       }) do
    with {:ok, base} <- Instance.api_base(host),
         {:ok, workspace} <- workspace_of(owner_uri),
         {:ok, token} <- CredentialSource.access_token(workspace, URI.to_string(owner_uri), host) do
      {:ok, base, token}
    end
  end

  # `Ezagent.URI.workspace_of/1` already derives the tenant URI from an entity
  # URI. Rebuilding it as `"workspace://" <> name` duplicated that derivation in
  # a plugin AND hand-assembled an Ezagent-scheme URI — which
  # `mix ezagent.uri_query.scan` flags as
  # `raw_cross_cutting_uri_construction`, because a hand-built URI skips the
  # canonicalisation every reader assumes.
  #
  # `:any` means the owner is cross-workspace (`system://` or an unknown
  # scheme). A credential lookup needs ONE concrete tenant, so that is refused
  # rather than resolved against an arbitrary workspace.
  defp workspace_of(owner_uri) do
    case Ezagent.URI.workspace_of(owner_uri) do
      %URI{} = workspace -> {:ok, URI.to_string(workspace)}
      :any -> {:error, :provider_account_not_connected}
    end
  end

  # `ForgejoClient`'s markers are protocol-level on purpose. The same status
  # means different things per operation, so each call site supplies the
  # reading: a 403 on a repository read is a read denial, the same 403 on the
  # checks endpoint means checks are unavailable.
  # A path occupied by a submodule or a directory where this run wants a plain
  # file is a malformed request, not a provider fault and not a race: no retry
  # and no remote change makes it succeed. Same stable code as the other
  # file-operation construction errors (design §8).
  defp map_error(:unwritable_path_kind, _operation, _kind), do: :invalid_file_change

  defp map_error({:provider_status, status}, operation, _kind),
    do: {:provider_request_failed, operation, status}

  # Status 0 is the explicit "no HTTP response arrived" marker. It is NOT a
  # refusal: the request may or may not have reached the instance, so a caller
  # must re-read before deciding anything (design §8.3).
  defp map_error(:provider_unreachable, operation, _kind),
    do: {:provider_request_failed, operation, 0}

  defp map_error(:authentication_rejected, _operation, _kind), do: :authentication_rejected
  defp map_error(:provider_rate_limited, _operation, _kind), do: :provider_rate_limited
  defp map_error(:not_found, _operation, _kind), do: :repository_not_found
  defp map_error(:provider_denied, _operation, :checks), do: :checks_unavailable
  defp map_error(:provider_denied, _operation, :write), do: :repository_write_denied
  defp map_error(:repository_archived, _operation, _kind), do: :repository_write_denied

  defp map_error(:quota_exceeded, operation, _kind),
    do: {:provider_request_failed, operation, 413}

  defp map_error(:provider_denied, _operation, _kind), do: :repository_read_denied

  # Already a closed `DomainGit.Error` — `CredentialSource` returns those
  # directly, so they pass through rather than being re-mapped.
  defp map_error(marker, _operation, _kind)
       when marker in [:provider_account_not_connected, :credential_backend_unavailable],
       do: marker

  defp map_error(_marker, _operation, _kind), do: :provider_unavailable

  defp req_opts, do: Application.get_env(:ezagent_plugin_forgejo, :adapter_req_opts, [])
end
