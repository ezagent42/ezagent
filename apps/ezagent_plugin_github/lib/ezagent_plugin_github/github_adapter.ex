defmodule EzagentPluginGithub.GitHubAdapter do
  @moduledoc """
  Maps Git domain operations to the GitHub REST API (v3).

  Each callback accepts `Ezagent.DomainGit` value types, calls the GitHub REST
  API via `GitHubClient`, and maps provider responses back to Domain Git structs.

  Repository operations authenticate with a GitHub App **operation-scoped
  installation access token** — minted fresh per callback via
  `EzagentPluginGithub.GitHubInstallation` for exactly that callback's closed
  permission profile (statically selected here, never from `ctx`, action args,
  prompt, or card) and discarded when the callback returns; there is no shared
  cache. Every callback fails closed if the token cannot be minted or scoped.

  ## Reconciliation

  `create_change_request/4` is create-or-reconcile, not create-only (design
  docs/superpowers/specs/2026-07-25-git-provider-v1-plan-e-provider-owned-loop-design.md
  §6.1-§6.2): re-invoking it with the same repo/head_ref/expected_base_sha
  after any crash never duplicates a remote mutation.

    * The deterministic head ref is the mutation identity, and it is
      created BEFORE any blob/tree/commit work — pointing at the verified
      base commit, not a head commit that does not exist yet. That
      establishes the durable remote mutation identity first, so a crash
      anywhere after ref creation (§6.2's "commit created, head update
      before" window) leaves a marker the retry can find, instead of
      silently repeating the whole Git-data POST chain. Once blob/tree/
      commit are built, the ref is ADVANCED onto the new commit with a
      non-force update (`PATCH git/refs/heads/...`, `force: false`); a
      rejected non-fast-forward advance is `:head_ref_conflict`, never a
      force-push.
    * If the ref already exists past base, it is reused only when its sole
      parent is exactly the verified base sha AND its tree matches the tree
      this call's own (idempotent, content-addressed) blob/tree creation
      produces for the same `file_changes` — parent equality alone does not
      prove this run produced that commit, since any unrelated commit built
      on the same base would also match. Any mismatch fails closed with
      `:head_ref_conflict`.
    * The PR's head+base pair (never its title or body) is the reconciliation
      identity: an exact, open, head+base search runs before any PR is
      created. Zero matches creates one; exactly one match is normalized and
      returned; more than one match fails closed with
      `:change_request_conflict`.
    * The commit itself is made deterministic (design §6.1 step 5, amended
      2026-07-27): `create_commit/5` passes explicit `author`/`committer`
      objects whose `date` is derived from `ctx.idempotency_key` instead of
      left for GitHub to fill in with wall-clock "now". Blob and tree
      creation are already content-addressed and idempotent; without this,
      the commit was the one object in the chain that was NOT, so a retry
      landing while the deterministic ref still pointed at base rebuilt a
      commit with a fresh timestamp — and therefore a fresh sha — leaving
      the previous attempt's commit as an orphan. With a run-stable date,
      `tree + parents + message + author + committer` are all fixed, so the
      commit sha is a pure function of content and a retry reproduces the
      SAME sha. The timestamp on the Git object is consequently not "when
      the work happened" — that is recorded in the workflow's typed facts
      (design §5.3's `observed_at` columns) — it exists solely to make the
      sha reproducible.
    * A 422 from ref *creation* is disambiguated, not assumed benign (design
      §6.2): the re-read it triggers either finds the ref (a genuine
      concurrent-creation race — reconcile normally) or still finds nothing
      (a real ref-validation failure, surfaced as `:invalid_ref` rather than
      the confusingly-reused `:repository_not_found`).
    * `resolve_repository/2`, `read_change_request/3`, `list_checks/3`, and
      `list_reviews/3` are pure reads and need no reconciliation logic — a
      repeated read cannot duplicate a mutation.
  """
  @behaviour Ezagent.DomainGit.Adapter

  alias Ezagent.DomainGit.{
    ChangeRequest,
    ChangeRequestId,
    Check,
    CommitSha,
    CreateChangeRequest,
    FileChange,
    OperationContext,
    RepositoryRef,
    Review
  }

  alias EzagentPluginGithub.{GitHubClient, GitHubInstallation}

  @github_host "github.com"

  # Synthetic, fixed commit identity (design §6.1 step 5 amendment): the
  # commit author/committer must be explicit so the sha is a pure function
  # of content (see `create_commit/5` / `deterministic_commit_date/1`
  # below). The name/email do not need to look like a real person or match
  # any particular GitHub identity -- only to never vary -- so they are
  # fixed constants rather than sourced from config or the installation.
  # `.example` matches this plugin's existing placeholder-domain convention
  # (see `Config.redirect_uri/0`).
  @commit_author_name "Ezagent Git Provider"
  @commit_author_email "git-provider@ezagent.example"

  @impl true
  def resolve_repository(_ctx, %RepositoryRef{} = repo) do
    with {:ok, token} <- installation_token(repo, :metadata_read),
         {:ok, data} <- GitHubClient.get("/repos/#{repo.external_id}", token, request_opts()) do
      build_repository_ref(repo, data)
    else
      {:error, reason} -> {:error, map_read_error(reason)}
    end
  end

  @impl true
  def create_change_request(
        ctx,
        %RepositoryRef{} = repo,
        file_changes,
        %CreateChangeRequest{} = create_req
      ) do
    case installation_token(repo, :change_request_write) do
      {:ok, token} ->
        with {:ok, base_sha} <- verify_base_ref(repo, create_req, token),
             {:ok, _head_sha} <-
               reconcile_head_ref(ctx, repo, file_changes, create_req, base_sha, token) do
          reconcile_pull_request(repo, create_req, token)
        end

      {:error, reason} ->
        {:error, map_read_error(reason)}
    end
  end

  # ── Step 1: base ref verification ───────────────────────────────────────

  defp verify_base_ref(repo, create_req, token) do
    base_ref_path = "/repos/#{repo.external_id}/git/ref/heads/#{repo.base_ref}"

    case GitHubClient.get(base_ref_path, token, request_opts()) do
      {:ok, ref_data} -> verify_base_sha(ref_data, create_req.expected_base_sha)
      {:error, :repository_not_found} -> {:error, :base_ref_not_found}
      {:error, reason} -> {:error, map_read_error(reason)}
    end
  end

  defp verify_base_sha(%{"object" => %{"sha" => sha}}, %CommitSha{value: expected}) do
    if sha == expected, do: {:ok, expected}, else: {:error, :base_sha_mismatch}
  end

  defp verify_base_sha(_ref_data, _expected_sha), do: {:error, :base_sha_mismatch}

  # ── Step 2: deterministic head ref create-or-reconcile (design §6.1 steps 3-6) ──
  #
  # The deterministic ref is the remote mutation identity (design §6.2): if it
  # is absent, it is created FIRST -- pointing at the verified base commit --
  # before any blob/tree/commit work, then advanced onto the new commit with
  # a non-force update once that commit exists. If it already exists past
  # base, this V1 either reuses it (parent AND tree match the verified base /
  # this call's own recomputed tree) or fails closed (:head_ref_conflict).
  # There is no force-push path anywhere in this module.

  defp reconcile_head_ref(ctx, repo, file_changes, create_req, base_sha, token) do
    path = head_ref_path(repo, create_req.head_ref)

    case GitHubClient.get(path, token, request_opts()) do
      {:error, :repository_not_found} ->
        create_head_commit(ctx, repo, file_changes, create_req, base_sha, token)

      other ->
        handle_head_lookup(other, ctx, repo, file_changes, create_req, base_sha, token)
    end
  end

  # The ref exists and still points at exactly the verified base sha -- this
  # is the durable marker `create_ref/4` planted (design §6.1 step 4), not an
  # existing head commit to verify against. Resume the chain rather than
  # treating it as "an existing head" (there is nothing to compare a tree
  # against yet).
  #
  # KNOWN LIMITATION (out of scope for this slice, tracked for P4): this
  # clause performs no provenance check. Any pre-existing ref of this exact
  # name that happens to sit at base -- planted by a wholly unrelated branch,
  # not this operation's own retry -- is indistinguishable from this
  # operation's own marker and is treated as safe to resume onto. Unlike the
  # "ref exists past base" path below (`reconcile_existing_head/5`, which
  # verifies parent AND tree), there is no commit here yet to check
  # provenance against -- the ref points directly at base_sha, so there is
  # nothing to compare. Closing this gap needs an identity the adapter does
  # not have: the workflow's own durable facts (design §5.3) recording which
  # ref belongs to which run. That is Slice P4's concern, not this adapter's.
  defp handle_head_lookup(
         {:ok, %{"object" => %{"sha" => sha}}},
         ctx,
         repo,
         file_changes,
         create_req,
         base_sha,
         token
       )
       when sha == base_sha do
    resume_head_commit(ctx, repo, file_changes, create_req, base_sha, token)
  end

  defp handle_head_lookup(
         {:ok, head_ref_data},
         _ctx,
         repo,
         file_changes,
         _create_req,
         base_sha,
         token
       ) do
    reconcile_existing_head(repo, head_ref_data, file_changes, base_sha, token)
  end

  # A 422 on ref *creation* followed by a re-read that STILL finds nothing
  # (design §6.2) is not the benign concurrent-creation race the clauses
  # above already resolve by finding the ref -- it means GitHub rejected the
  # ref creation for a real reason and it was genuinely never persisted.
  # `:repository_not_found` would be the wrong code to surface here even
  # though it is what the failed GET maps to: the repository was already
  # proven to exist by the base-ref read earlier in this same callback, and
  # reusing that atom would collide with its OTHER meaning in this very
  # module -- on `reconcile_head_ref`'s first read (above), the identical
  # atom is not an error at all, it is the normal "absent, go create it"
  # signal. `:invalid_ref` (an existing closed-set `Ezagent.DomainGit.Error`
  # value, unused elsewhere in this adapter) names the actual failure
  # without overloading either of `:repository_not_found`'s other meanings.
  # This clause only ever matches re-reads reached via `create_head_commit`'s
  # 422 branch below: `reconcile_head_ref` intercepts a first-read
  # `:repository_not_found` directly, so that value can never reach here as
  # part of the plain "other" branch.
  defp handle_head_lookup(
         {:error, :repository_not_found},
         _ctx,
         _repo,
         _file_changes,
         _create_req,
         _base_sha,
         _token
       ) do
    {:error, :invalid_ref}
  end

  defp handle_head_lookup(
         {:error, reason},
         _ctx,
         _repo,
         _file_changes,
         _create_req,
         _base_sha,
         _token
       ) do
    {:error, map_git_data_error(reason)}
  end

  defp create_head_commit(_ctx, _repo, [], _create_req, _base_sha, _token),
    do: {:error, :invalid_file_change}

  defp create_head_commit(ctx, repo, file_changes, create_req, base_sha, token) do
    case create_ref(repo, base_sha, create_req.head_ref, token) do
      :ok ->
        resume_head_commit(ctx, repo, file_changes, create_req, base_sha, token)

      {:error, :unprocessable_entity} ->
        # A 422 creating a ref this call just confirmed absent could be a
        # legitimate race with a concurrent creator (design §6.2) -- re-read
        # and reconcile through the normal safe-reuse path instead of
        # failing outright. `handle_head_lookup/7` disambiguates the two
        # outcomes: the ref now being found (the race) vs. the re-read still
        # coming back not-found (a genuine ref-validation failure, mapped to
        # `:invalid_ref` rather than looping back into create_head_commit).
        head_ref_path(repo, create_req.head_ref)
        |> GitHubClient.get(token, request_opts())
        |> handle_head_lookup(ctx, repo, file_changes, create_req, base_sha, token)

      {:error, reason} ->
        {:error, map_git_data_error(reason)}
    end
  end

  defp resume_head_commit(_ctx, _repo, [], _create_req, _base_sha, _token),
    do: {:error, :invalid_file_change}

  defp resume_head_commit(ctx, repo, file_changes, create_req, base_sha, token) do
    with {:ok, base_tree_sha} <- fetch_base_tree_sha(repo, base_sha, token),
         {:ok, blob_shas} <- create_blobs(repo, file_changes, token),
         {:ok, tree_sha} <- create_tree(repo, file_changes, blob_shas, base_tree_sha, token),
         {:ok, commit_sha} <- create_commit(ctx, repo, tree_sha, create_req, token),
         :ok <- advance_ref(repo, commit_sha, create_req.head_ref, token) do
      {:ok, commit_sha}
    else
      {:error, reason} -> {:error, map_git_data_error(reason)}
    end
  end

  # Existing ref found past base -- verify it descends directly from
  # expected_base_sha AND that its tree matches. Parent equality alone does
  # not distinguish this run's commit from any other commit that happens to
  # share the same base (design §6.1 step 4's "verify safe reuse"); the tree
  # check closes that gap.
  defp reconcile_existing_head(
         repo,
         %{"object" => %{"sha" => head_sha}},
         file_changes,
         base_sha,
         token
       )
       when is_binary(head_sha) do
    commit_path = "/repos/#{repo.external_id}/git/commits/#{head_sha}"

    case GitHubClient.get(commit_path, token, request_opts()) do
      {:ok, %{"tree" => %{"sha" => existing_tree_sha}, "parents" => [%{"sha" => ^base_sha}]}} ->
        verify_tree_reuse(repo, file_changes, base_sha, existing_tree_sha, head_sha, token)

      {:ok, _mismatched_or_unexpected_shape} ->
        {:error, :head_ref_conflict}

      {:error, reason} ->
        {:error, map_git_data_error(reason)}
    end
  end

  defp reconcile_existing_head(_repo, _head_ref_data, _file_changes, _base_sha, _token),
    do: {:error, :head_ref_conflict}

  # Blob/tree creation is content-addressed and idempotent (design §6.1 step
  # 5 note): recomputing this call's tree from `file_changes` and comparing
  # shas is a cheap, exact provenance check, rather than trusting the
  # caller's input digest -- which only guarantees stability across THIS
  # run's own retries (design §5.1), not that the existing commit came from
  # this run at all.
  defp verify_tree_reuse(repo, file_changes, base_sha, existing_tree_sha, head_sha, token) do
    with {:ok, base_tree_sha} <- fetch_base_tree_sha(repo, base_sha, token),
         {:ok, blob_shas} <- create_blobs(repo, file_changes, token),
         {:ok, tree_sha} <- create_tree(repo, file_changes, blob_shas, base_tree_sha, token) do
      if tree_sha == existing_tree_sha do
        {:ok, head_sha}
      else
        {:error, :head_ref_conflict}
      end
    else
      {:error, reason} -> {:error, map_git_data_error(reason)}
    end
  end

  defp head_ref_path(repo, head_ref), do: "/repos/#{repo.external_id}/git/ref/heads/#{head_ref}"

  # Fetches the TREE sha for the verified base commit -- NOT the ref's commit
  # sha itself, which `POST git/trees`'s `base_tree` parameter documents as
  # requiring a tree object's sha, not a commit object's sha.
  defp fetch_base_tree_sha(repo, base_sha, token) do
    commit_path = "/repos/#{repo.external_id}/git/commits/#{base_sha}"

    case GitHubClient.get(commit_path, token, request_opts()) do
      {:ok, %{"tree" => %{"sha" => tree_sha}}} -> {:ok, tree_sha}
      {:ok, _unexpected_shape} -> {:error, :provider_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_blobs(repo, file_changes, token) do
    Enum.reduce_while(file_changes, {:ok, []}, fn %FileChange{content: content}, {:ok, acc} ->
      path = "/repos/#{repo.external_id}/git/blobs"

      case GitHubClient.post(
             path,
             token,
             %{content: content, encoding: "utf-8"},
             request_opts()
           ) do
        {:ok, %{"sha" => sha}} ->
          {:cont, {:ok, acc ++ [sha]}}

        {:ok, _unexpected} ->
          {:halt, {:error, :provider_unavailable}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp create_tree(repo, file_changes, blob_shas, base_tree_sha, token) do
    tree_entries =
      Enum.zip(file_changes, blob_shas)
      |> Enum.map(fn {%FileChange{path: path}, sha} ->
        %{path: path, mode: "100644", type: "blob", sha: sha}
      end)

    path = "/repos/#{repo.external_id}/git/trees"

    case GitHubClient.post(
           path,
           token,
           %{base_tree: base_tree_sha, tree: tree_entries},
           request_opts()
         ) do
      {:ok, %{"sha" => sha}} ->
        {:ok, sha}

      {:ok, _unexpected} ->
        {:error, :provider_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Passes EXPLICIT `author`/`committer` (design §6.1 step 5 amendment,
  # 2026-07-27) so GitHub never fills in the omitted date with wall-clock
  # "now". Without this, `tree`/`parents`/`message` alone would still be
  # identical across a retry, but the persisted commit would carry whatever
  # time the retry happened to run at -- a different sha every time, and an
  # orphan left behind whenever the deterministic ref was still sitting at
  # base (design §6.2's first crash window). See `deterministic_commit_date/1`
  # for where `date` comes from.
  defp create_commit(ctx, repo, tree_sha, create_req, token) do
    path = "/repos/#{repo.external_id}/git/commits"

    author = %{
      name: @commit_author_name,
      email: @commit_author_email,
      date: deterministic_commit_date(ctx)
    }

    body = %{
      message: create_req.title,
      tree: tree_sha,
      parents: [create_req.expected_base_sha.value],
      author: author,
      committer: author
    }

    case GitHubClient.post(path, token, body, request_opts()) do
      {:ok, %{"sha" => sha}} ->
        {:ok, sha}

      {:ok, _unexpected} ->
        {:error, :provider_unavailable}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Derives a commit `date` that is stable across retries of the SAME run
  # without reading the wall clock (design §6.1 step 5 amendment). Built
  # from `ctx.idempotency_key` ("task_id:generation:action", assembled in
  # `Ezagent.ActionSet.GitTaskAccess.operation_context/3`) rather than a new
  # field on any DomainGit value: that key is already this exact callback's
  # stable-by-construction identity for the run -- unchanged across retries,
  # since neither task id, generation, nor the literal `:create_change_request`
  # action vary between them -- and it is the same primitive this codebase's
  # other idempotency machinery keys on, so reusing it here does not invent
  # a second identity concept. The resulting date does not need to look
  # "real" (design §6.1: real timing lives in the workflow's typed facts,
  # not on the Git object) -- only to never change for the same
  # (task, generation, action) triple, which a deterministic hash guarantees.
  defp deterministic_commit_date(%OperationContext{idempotency_key: key}) do
    <<seed::unsigned-32, _rest::binary>> = :crypto.hash(:sha256, key)
    seed |> DateTime.from_unix!() |> DateTime.to_iso8601()
  end

  # Creates the deterministic ref for the FIRST time, pointing at the
  # VERIFIED BASE commit -- not a head commit, which does not exist yet.
  # This establishes the durable remote mutation identity (design §6.1 step
  # 4) BEFORE any blob/tree/commit work, so a crash anywhere after this
  # point (§6.2's "commit created, head update before" window) leaves a ref
  # the retry can find and continue from, instead of silently repeating the
  # whole Git-data POST chain. POST (not PATCH): `create_head_commit/6` only
  # reaches this function when `reconcile_head_ref/6` has confirmed the ref
  # absent.
  defp create_ref(repo, sha, head_ref, token) do
    path = "/repos/#{repo.external_id}/git/refs"
    body = %{ref: "refs/heads/#{head_ref}", sha: sha}

    case GitHubClient.post(path, token, body, request_opts()) do
      {:ok, _data} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Advances the marker ref from base onto the newly-created commit with a
  # NON-FORCE update (design §6.1 step 6): this is the only place the ref's
  # target ever moves, and it only succeeds as a fast-forward from exactly
  # the sha `create_ref/4` set. GitHub answers a rejected non-fast-forward
  # update with 422 -- a real conflict (someone else advanced the ref), not
  # a retryable transport error -- so it maps directly to
  # `:head_ref_conflict` rather than through the generic Git-data mapper.
  defp advance_ref(repo, commit_sha, head_ref, token) do
    path = "/repos/#{repo.external_id}/git/refs/heads/#{head_ref}"
    body = %{sha: commit_sha, force: false}

    case GitHubClient.patch(path, token, body, request_opts()) do
      {:ok, _data} -> :ok
      {:error, :unprocessable_entity} -> {:error, :head_ref_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Step 3: PR exact find-or-create (design §6.1 steps 7-8, §6.2) ───────
  #
  # Exact head+base is the PR reconciliation identity -- title/body are never
  # used to find a match. `state: "open"` matches design §6.1 step 7's "查询
  # exact head+base 的 open PR" literally: a closed/merged PR with the same
  # head+base does not block creating a new one.

  defp reconcile_pull_request(repo, create_req, token) do
    path = "/repos/#{repo.external_id}/pulls"

    query = [
      head: "#{repo.owner_path}:#{create_req.head_ref}",
      base: repo.base_ref,
      state: "open"
    ]

    case GitHubClient.get(path, token, Keyword.merge(request_opts(), params: query)) do
      {:ok, []} -> create_pr(repo, create_req, token)
      {:ok, [single]} when is_map(single) -> build_change_request(single)
      {:ok, [_, _ | _]} -> {:error, :change_request_conflict}
      {:ok, _unexpected} -> {:error, :provider_unavailable}
      {:error, reason} -> {:error, map_read_error(reason)}
    end
  end

  defp create_pr(repo, create_req, token) do
    path = "/repos/#{repo.external_id}/pulls"

    body = %{
      title: create_req.title,
      head: create_req.head_ref,
      base: repo.base_ref,
      body: create_req.body
    }

    case GitHubClient.post(path, token, body, request_opts()) do
      {:ok, data} ->
        build_change_request(data)

      {:error, :unprocessable_entity} ->
        {:error, :change_request_conflict}

      {:error, reason} ->
        {:error, map_write_error(reason)}
    end
  end

  @impl true
  def read_change_request(_ctx, %RepositoryRef{} = repo, %ChangeRequestId{} = cr_id) do
    with {:ok, token} <- installation_token(repo, :change_request_read),
         {:ok, data} <-
           GitHubClient.get(
             "/repos/#{repo.external_id}/pulls/#{cr_id.external_id}",
             token,
             request_opts()
           ) do
      build_change_request(data)
    else
      {:error, reason} -> {:error, map_read_error(reason)}
    end
  end

  @impl true
  def list_checks(_ctx, %RepositoryRef{} = repo, %CommitSha{} = sha) do
    with {:ok, token} <- installation_token(repo, :checks_read),
         {:ok, %{"check_runs" => check_runs}} <-
           GitHubClient.get(
             "/repos/#{repo.external_id}/commits/#{sha.value}/check-runs",
             token,
             request_opts()
           ) do
      checks = check_runs |> Enum.map(&build_check/1) |> Enum.reject(&is_nil/1)
      {:ok, checks}
    else
      {:error, reason} -> {:error, map_checks_error(reason)}
    end
  end

  @impl true
  def list_reviews(_ctx, %RepositoryRef{} = repo, %ChangeRequestId{} = cr_id) do
    case installation_token(repo, :change_request_read) do
      {:ok, token} ->
        path = "/repos/#{repo.external_id}/pulls/#{cr_id.external_id}/reviews"

        case GitHubClient.get(path, token, request_opts()) do
          {:ok, reviews} when is_list(reviews) ->
            result = reviews |> Enum.map(&build_review/1) |> Enum.reject(&is_nil/1)
            {:ok, result}

          {:ok, _unexpected} ->
            {:error, :provider_unavailable}

          {:error, reason} ->
            {:error, map_read_error(reason)}
        end

      {:error, reason} ->
        {:error, map_read_error(reason)}
    end
  end

  # ── Build helpers ───────────────────────────────────────────────────────

  defp build_repository_ref(%RepositoryRef{} = input, data) do
    full_name = data["full_name"] || input.external_id
    [owner | _rest] = String.split(full_name, "/")

    RepositoryRef.new(%{
      repository_uri: input.repository_uri,
      provider_adapter: :github,
      provider_host: @github_host,
      external_id: full_name,
      owner_path: owner,
      base_ref: data["default_branch"] || input.base_ref,
      visibility: if(data["private"], do: :private, else: :public)
    })
  end

  defp build_change_request(data) do
    head = data["head"]
    base = data["base"]
    state = map_pr_state(data["state"], data["merged"])

    ChangeRequest.new(%{
      external_id: to_string(data["number"]),
      # uri-canonical-allow: external GitHub API URL (not an Ezagent-scheme URI)
      url: URI.parse(data["html_url"]),
      head_ref: head["ref"],
      head_sha: head["sha"],
      base_ref: base["ref"],
      state: state
    })
  end

  defp build_check(run) do
    case Check.new(%{
           external_id: to_string(run["id"]),
           name: run["name"],
           status: map_check_status(run["status"]),
           conclusion: map_check_conclusion(run["conclusion"]),
           url: map_uri(run["details_url"])
         }) do
      {:ok, check} ->
        check

      {:error, _validation_error} ->
        nil
    end
  end

  defp build_review(review_data) do
    case Review.new(%{
           external_id: to_string(review_data["id"]),
           author_label: review_data["user"]["login"],
           state: map_review_state(review_data["state"]),
           submitted_at: map_datetime(review_data["submitted_at"])
         }) do
      {:ok, review} ->
        review

      {:error, _validation_error} ->
        nil
    end
  end

  # ── Value mappers ───────────────────────────────────────────────────────

  defp map_pr_state("open", _merged), do: :open
  defp map_pr_state("closed", true), do: :merged
  defp map_pr_state("closed", _merged), do: :closed
  defp map_pr_state(_, _), do: :closed

  defp map_check_status("queued"), do: :queued
  defp map_check_status("in_progress"), do: :in_progress
  defp map_check_status("completed"), do: :completed
  defp map_check_status(_), do: :completed

  defp map_check_conclusion("success"), do: :succeeded
  defp map_check_conclusion("failure"), do: :failed
  defp map_check_conclusion("neutral"), do: :neutral
  defp map_check_conclusion("cancelled"), do: :cancelled
  defp map_check_conclusion("skipped"), do: :skipped
  defp map_check_conclusion("timed_out"), do: :timed_out
  defp map_check_conclusion("action_required"), do: :action_required
  defp map_check_conclusion(nil), do: nil
  defp map_check_conclusion(_), do: :other

  defp map_review_state(state) when is_binary(state) do
    case String.upcase(state) do
      "APPROVED" -> :approved
      "CHANGES_REQUESTED" -> :changes_requested
      "COMMENTED" -> :commented
      "DISMISSED" -> :dismissed
      _ -> :commented
    end
  end

  defp map_review_state(_), do: :commented

  defp map_uri(nil), do: nil

  # uri-canonical-allow: external GitHub API URL (not an Ezagent-scheme URI)
  defp map_uri(url) when is_binary(url), do: URI.parse(url)

  defp map_datetime(nil), do: nil

  defp map_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      {:error, _reason} -> nil
    end
  end

  # ── Token resolution ───────────────────────────────────────────────────

  # Mints an operation-scoped GitHub App installation access token for `repo`
  # and the caller's closed `profile`, statically selected by this module (never
  # from ctx/action args/prompt/card — see moduledoc). Returns `{:ok, token}` or
  # a `GitHubClient`/`:installation_scope_mismatch` error atom (mapped by the
  # caller to a stable read/write error). The token is minted fresh for this
  # call — never cached — and is never logged.
  defp installation_token(%RepositoryRef{} = repo, profile) do
    GitHubInstallation.token_for_operation(repo, profile, request_opts())
  end

  # ── Request opts (test injection point) ─────────────────────────────────

  defp request_opts do
    Application.get_env(:ezagent_plugin_github, :adapter_req_opts, [])
  end

  # ── Error mappers ───────────────────────────────────────────────────────

  defp map_read_error(:provider_denied), do: :repository_read_denied
  defp map_read_error(:unprocessable_entity), do: :provider_unavailable
  defp map_read_error(other), do: other

  defp map_write_error(:provider_denied), do: :repository_write_denied
  defp map_write_error(other), do: other

  defp map_checks_error(:provider_denied), do: :checks_unavailable
  defp map_checks_error(:unprocessable_entity), do: :provider_unavailable
  defp map_checks_error(other), do: other

  defp map_git_data_error(:provider_denied), do: :repository_write_denied
  defp map_git_data_error(:unprocessable_entity), do: :provider_unavailable
  defp map_git_data_error(other), do: other
end
