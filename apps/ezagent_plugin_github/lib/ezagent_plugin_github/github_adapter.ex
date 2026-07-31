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
      2026-07-27 and corrected 2026-07-27 P3-fix3): `create_commit/4` passes
      explicit `author`/`committer` objects whose `date` is
      `create_req.commit_date` — a required, provider-neutral field with no
      default, populated by the caller (the workflow, Slice P4) from
      `git_workflow_runs.inserted_at`, the real moment the run was durably
      accepted — instead of left for GitHub to fill in with wall-clock "now".
      Blob and tree creation are already content-addressed and idempotent;
      without an explicit date, the commit was the one object in the chain
      that was NOT, so a retry landing while the deterministic ref still
      pointed at base rebuilt a commit with a fresh timestamp — and
      therefore a fresh sha — leaving the previous attempt's commit as an
      orphan. With a run-stable date, `tree + parents + message + author +
      committer` are all fixed, so the commit sha is a pure function of
      content and a retry reproduces the SAME sha. This adapter never
      derives or reads a clock for the date itself —
      `CreateChangeRequest.new/1` fails closed with
      `{:error, {:invalid_field, :commit_date}}` if the caller omits it or
      supplies a non-`DateTime`, which is strictly better than silently
      substituting a fabricated one (an earlier same-day draft hashed
      `ctx.idempotency_key` into a synthetic date instead, which was
      run-stable but frequently future-dated). The timestamp on the Git
      object is consequently not "when the work happened" — that is
      recorded in the workflow's typed facts (design §5.3's `observed_at`
      columns) — it exists solely to make the sha reproducible.
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
    RepositoryRef,
    Review
  }

  alias EzagentPluginGithub.{GitHubClient, GitHubInstallation}

  @github_host "github.com"

  # Synthetic, fixed commit identity (design §6.1 step 5 amendment): the
  # commit author/committer must be explicit so the sha is a pure function
  # of content (see `create_commit/4` below, which reads `date` from
  # `create_req.commit_date` rather than deriving one). The name/email do
  # not need to look like a real person or match any particular GitHub
  # identity -- only to never vary -- so they are fixed constants rather
  # than sourced from config or the installation. `.example` matches this
  # plugin's existing placeholder-domain convention (see
  # `Config.redirect_uri/0`).
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
        _ctx,
        %RepositoryRef{} = repo,
        file_changes,
        %CreateChangeRequest{} = create_req
      ) do
    case installation_token(repo, :change_request_write) do
      {:ok, token} ->
        with {:ok, base_sha} <- verify_base_ref(repo, create_req, token),
             {:ok, _head_sha} <-
               reconcile_head_ref(repo, file_changes, create_req, base_sha, token) do
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

  defp reconcile_head_ref(repo, file_changes, create_req, base_sha, token) do
    path = head_ref_path(repo, create_req.head_ref)

    case GitHubClient.get(path, token, request_opts()) do
      {:error, :repository_not_found} ->
        create_head_commit(repo, file_changes, create_req, base_sha, token)

      other ->
        handle_head_lookup(other, repo, file_changes, create_req, base_sha, token)
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
         repo,
         file_changes,
         create_req,
         base_sha,
         token
       )
       when sha == base_sha do
    resume_head_commit(repo, file_changes, create_req, base_sha, token)
  end

  defp handle_head_lookup(
         {:ok, head_ref_data},
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
         _repo,
         _file_changes,
         _create_req,
         _base_sha,
         _token
       ) do
    {:error, map_git_data_error(reason)}
  end

  defp create_head_commit(_repo, [], _create_req, _base_sha, _token),
    do: {:error, :invalid_file_change}

  defp create_head_commit(repo, file_changes, create_req, base_sha, token) do
    case create_ref(repo, base_sha, create_req.head_ref, token) do
      :ok ->
        resume_head_commit(repo, file_changes, create_req, base_sha, token)

      {:error, :unprocessable_entity} ->
        # A 422 creating a ref this call just confirmed absent could be a
        # legitimate race with a concurrent creator (design §6.2) -- re-read
        # and reconcile through the normal safe-reuse path instead of
        # failing outright. `handle_head_lookup/6` disambiguates the two
        # outcomes: the ref now being found (the race) vs. the re-read still
        # coming back not-found (a genuine ref-validation failure, mapped to
        # `:invalid_ref` rather than looping back into create_head_commit).
        head_ref_path(repo, create_req.head_ref)
        |> GitHubClient.get(token, request_opts())
        |> handle_head_lookup(repo, file_changes, create_req, base_sha, token)

      {:error, reason} ->
        {:error, map_git_data_error(reason)}
    end
  end

  defp resume_head_commit(_repo, [], _create_req, _base_sha, _token),
    do: {:error, :invalid_file_change}

  defp resume_head_commit(repo, file_changes, create_req, base_sha, token) do
    with {:ok, base_tree_sha} <- fetch_base_tree_sha(repo, base_sha, token),
         {:ok, blob_shas} <- create_blobs(repo, file_changes, token),
         {:ok, tree_sha} <- create_tree(repo, file_changes, blob_shas, base_tree_sha, token),
         {:ok, commit_sha} <- create_commit(repo, tree_sha, create_req, token),
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
  # 2026-07-27, date source corrected 2026-07-27 P3-fix3) so GitHub never
  # fills in the omitted date with wall-clock "now". Without this,
  # `tree`/`parents`/`message` alone would still be identical across a
  # retry, but the persisted commit would carry whatever time the retry
  # happened to run at -- a different sha every time, and an orphan left
  # behind whenever the deterministic ref was still sitting at base (design
  # §6.2's first crash window). `date` is `create_req.commit_date` --
  # required on `CreateChangeRequest`, populated by the caller (the
  # workflow, Slice P4) from `git_workflow_runs.inserted_at` -- this adapter
  # never derives or reads a clock for it.
  defp create_commit(repo, tree_sha, create_req, token) do
    path = "/repos/#{repo.external_id}/git/commits"

    author = %{
      name: @commit_author_name,
      email: @commit_author_email,
      date: DateTime.to_iso8601(create_req.commit_date)
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

  # Creates the deterministic ref for the FIRST time, pointing at the
  # VERIFIED BASE commit -- not a head commit, which does not exist yet.
  # This establishes the durable remote mutation identity (design §6.1 step
  # 4) BEFORE any blob/tree/commit work, so a crash anywhere after this
  # point (§6.2's "commit created, head update before" window) leaves a ref
  # the retry can find and continue from, instead of silently repeating the
  # whole Git-data POST chain. POST (not PATCH): `create_head_commit/5` only
  # reaches this function when `reconcile_head_ref/5` has confirmed the ref
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
         {:ok, body} <-
           GitHubClient.get(
             "/repos/#{repo.external_id}/commits/#{sha.value}/check-runs",
             token,
             request_opts()
           ) do
      build_checks(body)
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
            collect(reviews, &build_review/1)

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

  # `private` is required to be a boolean rather than read for truthiness.
  #
  # `RepositoryRef.visibility` is not a label — `TaskWorkspace.Provisioner`
  # refuses a checkout on `:private` and permits one on `:public`. A body that
  # omits the field used to answer `:public`, which hands a private repository
  # the permission its owner never gave. "The provider did not tell us" is not
  # "the provider said public".
  #
  # `full_name` and `default_branch` are likewise required from the RESPONSE
  # rather than defaulted back to the caller's own request: falling back means
  # the adapter reports the value it was asked about as though the provider had
  # confirmed it, which is the whole failure mode this module was fixed for.
  defp build_repository_ref(%RepositoryRef{} = input, data) do
    # The caller-derived and constant fields are bound once, ahead of the
    # branch: `plugin_workspace_locality_contract_test` reads a workspace-bound
    # runtime access from inside a plugin branch as an owner-bypass site, and
    # hoisting keeps that gate meaningful rather than widening it.
    identity = %{
      repository_uri: input.repository_uri,
      provider_adapter: :github,
      provider_host: @github_host
    }

    case repository_facts(data) do
      {:ok, facts} ->
        facts
        |> Map.merge(identity)
        |> RepositoryRef.new()
        |> case do
          {:ok, repository} -> {:ok, repository}
          {:error, _validation_error} -> {:error, :provider_unavailable}
        end

      :error ->
        {:error, :provider_unavailable}
    end
  end

  # Response-shape validation is a separate function from struct assembly so the
  # guards live away from the clause that reads the caller's own
  # `repository_uri` — `plugin_workspace_locality_contract_test` reads a guarded
  # plugin clause touching workspace-bound runtime as an owner-bypass site, and
  # the split keeps that gate meaningful instead of widening it.
  defp repository_facts(%{
         "full_name" => full_name,
         "default_branch" => default_branch,
         "private" => private
       })
       when is_binary(full_name) and is_binary(default_branch) and is_boolean(private) do
    case String.split(full_name, "/") do
      [owner | _rest] when owner != "" ->
        {:ok,
         %{
           external_id: full_name,
           owner_path: owner,
           base_ref: default_branch,
           visibility: if(private, do: :private, else: :public)
         }}

      _ ->
        :error
    end
  end

  defp repository_facts(_data), do: :error

  # The required shape is matched in the head rather than dug out with Access:
  # an absent `head`/`base` is a body this code does not parse, and reading it as
  # a change request with nil refs would report a shape failure as a fact.
  defp build_change_request(
         %{"head" => %{"ref" => head_ref, "sha" => head_sha}, "base" => %{"ref" => base_ref}} =
           data
       ) do
    with {:ok, state} <- map_pr_state(data["state"], data["merged"]),
         {:ok, url} <- map_uri(data["html_url"]),
         {:ok, change_request} <-
           ChangeRequest.new(%{
             external_id: to_string(data["number"]),
             url: url,
             head_ref: head_ref,
             head_sha: head_sha,
             base_ref: base_ref,
             state: state
           }) do
      {:ok, change_request}
    else
      # `ChangeRequest.new/1` answers with a `ValidationError`, which is NOT a
      # member of the frozen `DomainGit.Error` union the callback is typed
      # against. Everything unparsable leaves as the one error atom.
      _ -> {:error, :provider_unavailable}
    end
  end

  defp build_change_request(_data), do: {:error, :provider_unavailable}

  defp build_checks(%{"check_runs" => check_runs}) when is_list(check_runs),
    do: collect(check_runs, &build_check/1)

  # An absent or non-list `check_runs` is refused rather than read as `{:ok, []}`
  # — a caller reads an empty list as "nothing failed", so answering it for a
  # body we did not understand is the same fail-open in a different costume.
  defp build_checks(_body), do: {:error, :provider_unavailable}

  # `is_map` is a guard, not decoration: `Access` on a scalar RAISES, and a raise
  # escapes the callback without either `{:ok, _}` or `{:error, Error.t()}` —
  # the closed result the adapter contract is typed against.
  defp build_check(run) when is_map(run) do
    with {:ok, status} <- map_check_status(run["status"]),
         {:ok, conclusion} <- map_check_conclusion(run["conclusion"]),
         {:ok, url} <- map_uri(run["details_url"]),
         {:ok, check} <-
           Check.new(%{
             external_id: to_string(run["id"]),
             name: run["name"],
             status: status,
             conclusion: conclusion,
             url: url
           }) do
      {:ok, check}
    else
      _ -> {:error, :provider_unavailable}
    end
  end

  defp build_check(_run), do: {:error, :provider_unavailable}

  # FILTERING and LOSING are different, and collapsing them is a fail-open.
  #
  # A `PENDING` entry is a draft its author never submitted — GitHub omits
  # `submitted_at` for exactly that reason — so dropping it is the contract. A
  # SUBMITTED review this code cannot parse is something else: dropping it
  # silently means an `APPROVED` that normalizes survives while a
  # `CHANGES_REQUESTED` whose shape drifted disappears, and the caller records
  # `approved=1` with a human's explicit objection erased from the facts.
  defp build_review(%{"state" => raw} = data) when is_binary(raw) do
    case String.upcase(raw) do
      "PENDING" -> :filtered
      state -> build_submitted_review(state, data)
    end
  end

  defp build_review(_data), do: {:error, :provider_unavailable}

  # `user` is destructured in the head for the same reason `build_check/1` guards
  # on `is_map`: `data["user"]["login"]` RAISES when `user` is a scalar, and a
  # raise leaves the callback's closed result contract entirely. A `nil` user
  # (GitHub's shape for a deleted account) needs no special case — it fails the
  # match here and leaves as the typed error.
  defp build_submitted_review(state, %{"user" => %{"login" => login}} = data) do
    with {:ok, mapped} <- map_review_state(state),
         {:ok, submitted_at} <- map_datetime(data["submitted_at"]),
         {:ok, review} <-
           Review.new(%{
             external_id: to_string(data["id"]),
             author_label: login,
             state: mapped,
             submitted_at: submitted_at
           }) do
      {:ok, review}
    else
      _ -> {:error, :provider_unavailable}
    end
  end

  defp build_submitted_review(_state, _data), do: {:error, :provider_unavailable}

  # One unparsable entry fails the WHOLE read. A partial list is indistinguishable
  # from the complete facts at the call site, and the entry most likely to be
  # dropped is precisely the one whose shape drifted — never the boring one.
  defp collect(entries, build) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case build.(entry) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :filtered -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── Value mappers ───────────────────────────────────────────────────────
  #
  # Every mapper answers `{:ok, value}` or `:error`, and `:error` fails the read.
  # A mapper degrades onto a specific value ONLY where the domain type declares a
  # member meaning "a value we have no mapping for" — `Check.conclusion` has
  # `:other`; `Check.status`, `Review.state` and `ChangeRequest.state` have
  # nothing of the kind, so for those any answer would be an invention.

  # `merged` is only load-bearing on a CLOSED pull request, and there it is the
  # whole answer: a merged pull request still reports state "closed", so reading
  # `state` alone records every merge as a plain close. An absent or non-boolean
  # `merged` on a closed pull request means we cannot tell those two apart, and
  # `ChangeRequest.state` has no member for "we could not tell" — so it fails.
  #
  # An OPEN pull request deliberately ignores the field. It is definitionally
  # not merged, and `reconcile_pull_request/3` builds from the pull-request LIST
  # endpoint (pinned to `state: "open"`), whose entries do not carry `merged` at
  # all — requiring it there would fail a read that is perfectly well understood.
  defp map_pr_state("open", _merged), do: {:ok, :open}
  defp map_pr_state("closed", true), do: {:ok, :merged}
  defp map_pr_state("closed", false), do: {:ok, :closed}
  defp map_pr_state(_state, _merged), do: :error

  # GitHub documents six statuses. `waiting` (deployment protection rule),
  # `requested` (not yet queued) and `pending` (concurrency group) all mean "has
  # not started", which `Check.status` spells `:queued` — that is a mapping, not
  # a guess, and GitHub reports `conclusion: null` for all three, matching what
  # `Check.new/1` requires of a non-terminal status.
  defp map_check_status("queued"), do: {:ok, :queued}
  defp map_check_status("waiting"), do: {:ok, :queued}
  defp map_check_status("requested"), do: {:ok, :queued}
  defp map_check_status("pending"), do: {:ok, :queued}
  defp map_check_status("in_progress"), do: {:ok, :in_progress}
  defp map_check_status("completed"), do: {:ok, :completed}
  defp map_check_status(_unknown), do: :error

  defp map_check_conclusion(nil), do: {:ok, nil}
  defp map_check_conclusion("success"), do: {:ok, :succeeded}
  defp map_check_conclusion("failure"), do: {:ok, :failed}
  defp map_check_conclusion("neutral"), do: {:ok, :neutral}
  defp map_check_conclusion("cancelled"), do: {:ok, :cancelled}
  defp map_check_conclusion("skipped"), do: {:ok, :skipped}
  defp map_check_conclusion("timed_out"), do: {:ok, :timed_out}
  defp map_check_conclusion("action_required"), do: {:ok, :action_required}

  # An unrecognized conclusion STRING degrades onto `:other` — honest reporting.
  # A non-string is a shape failure: "we cannot find the conclusion" is not "a
  # conclusion we have no mapping for".
  defp map_check_conclusion(unknown) when is_binary(unknown), do: {:ok, :other}
  defp map_check_conclusion(_malformed), do: :error

  defp map_review_state("APPROVED"), do: {:ok, :approved}
  defp map_review_state("CHANGES_REQUESTED"), do: {:ok, :changes_requested}
  defp map_review_state("COMMENTED"), do: {:ok, :commented}
  defp map_review_state("DISMISSED"), do: {:ok, :dismissed}
  defp map_review_state(_unknown), do: :error

  defp map_uri(nil), do: {:ok, nil}

  # uri-canonical-allow: external GitHub API URL (not an Ezagent-scheme URI)
  defp map_uri(url) when is_binary(url), do: {:ok, URI.parse(url)}
  defp map_uri(_malformed), do: :error

  # An ABSENT timestamp is legitimate — the only reviews without one are the
  # drafts already filtered above. A PRESENT one that will not parse is a shape
  # failure, and nilling it would report a submitted review as never submitted.
  defp map_datetime(nil), do: {:ok, nil}

  defp map_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _reason} -> :error
    end
  end

  defp map_datetime(_malformed), do: :error

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
