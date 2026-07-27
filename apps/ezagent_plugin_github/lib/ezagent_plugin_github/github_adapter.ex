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
  # already exists, this V1 either reuses it (parent matches the verified
  # base) or fails closed (:head_ref_conflict) -- it never moves it. There is
  # no PATCH/force-push path anywhere in this module.

  defp reconcile_head_ref(repo, file_changes, create_req, base_sha, token) do
    head_ref_path = "/repos/#{repo.external_id}/git/ref/heads/#{create_req.head_ref}"

    case GitHubClient.get(head_ref_path, token, request_opts()) do
      {:ok, head_ref_data} ->
        verify_existing_head(repo, head_ref_data, base_sha, token)

      {:error, :repository_not_found} ->
        create_head_commit(repo, file_changes, create_req, base_sha, token)

      {:error, reason} ->
        {:error, map_git_data_error(reason)}
    end
  end

  # Existing ref found -- verify it descends directly from expected_base_sha
  # before reusing it. This checks the commit's sole parent only (not its
  # tree): the caller-supplied file_changes for a given deterministic
  # head_ref are assumed content-stable across retries (the workflow layer
  # enforces this via its own input-digest check, design §5.1) -- this
  # adapter has no run/generation identity to independently re-derive that
  # guarantee, so parent-matches-base is the strongest check it can perform
  # without recomputing (and thereby re-uploading) blob/tree content on every
  # retry.
  defp verify_existing_head(repo, %{"object" => %{"sha" => head_sha}}, base_sha, token)
       when is_binary(head_sha) do
    commit_path = "/repos/#{repo.external_id}/git/commits/#{head_sha}"

    case GitHubClient.get(commit_path, token, request_opts()) do
      {:ok, %{"parents" => [%{"sha" => ^base_sha}]}} -> {:ok, head_sha}
      {:ok, _mismatched_or_unexpected_shape} -> {:error, :head_ref_conflict}
      {:error, reason} -> {:error, map_git_data_error(reason)}
    end
  end

  defp verify_existing_head(_repo, _head_ref_data, _base_sha, _token),
    do: {:error, :head_ref_conflict}

  defp create_head_commit(_repo, [], _create_req, _base_sha, _token),
    do: {:error, :invalid_file_change}

  defp create_head_commit(repo, file_changes, create_req, base_sha, token) do
    with {:ok, base_tree_sha} <- fetch_base_tree_sha(repo, base_sha, token),
         {:ok, blob_shas} <- create_blobs(repo, file_changes, token),
         {:ok, tree_sha} <- create_tree(repo, file_changes, blob_shas, base_tree_sha, token),
         {:ok, commit_sha} <- create_commit(repo, tree_sha, create_req, token),
         :ok <- create_head_ref(repo, commit_sha, create_req.head_ref, token) do
      {:ok, commit_sha}
    else
      {:error, reason} -> {:error, map_git_data_error(reason)}
    end
  end

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

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_commit(repo, tree_sha, create_req, token) do
    path = "/repos/#{repo.external_id}/git/commits"

    body = %{
      message: create_req.title,
      tree: tree_sha,
      parents: [create_req.expected_base_sha.value]
    }

    case GitHubClient.post(path, token, body, request_opts()) do
      {:ok, %{"sha" => sha}} ->
        {:ok, sha}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Creates the deterministic ref for the FIRST time -- POST (not PATCH):
  # `reconcile_head_ref/5` only reaches this function when the ref is
  # confirmed absent. An already-present ref is either reused as-is
  # (`verify_existing_head/4`) or rejected as `:head_ref_conflict` -- there is
  # no third path that mutates an existing ref.
  defp create_head_ref(repo, commit_sha, head_ref, token) do
    path = "/repos/#{repo.external_id}/git/refs"
    body = %{ref: "refs/heads/#{head_ref}", sha: commit_sha}

    case GitHubClient.post(path, token, body, request_opts()) do
      {:ok, _data} -> :ok
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
  defp map_read_error(other), do: other

  defp map_write_error(:provider_denied), do: :repository_write_denied
  defp map_write_error(other), do: other

  defp map_checks_error(:provider_denied), do: :checks_unavailable
  defp map_checks_error(other), do: other

  defp map_git_data_error(:provider_denied), do: :repository_write_denied
  defp map_git_data_error(:change_request_conflict), do: :change_request_conflict
  defp map_git_data_error(other), do: other
end
