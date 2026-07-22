defmodule EzagentPluginGithub.GitHubAdapter do
  @moduledoc """
  Maps Git domain operations to the GitHub REST API (v3).

  Each callback accepts `Ezagent.DomainGit` value types, calls the GitHub REST
  API via `GitHubClient`, and maps provider responses back to Domain Git structs.

  Repository operations authenticate with a GitHub App **installation access
  token** resolved per-repo via `EzagentPluginGithub.GitHubInstallation` — not
  with the connecting user's token. The user token establishes identity at
  connection time; the installation token grants the App's permissions on the
  target repository. Every callback resolves the installation token first and
  fails closed (mapping to a stable read/write error) if it cannot be obtained.
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
    with {:ok, token} <- installation_token(repo),
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
    case installation_token(repo) do
      {:ok, token} ->
        base_ref_path = "/repos/#{repo.external_id}/git/ref/heads/#{repo.base_ref}"

        case GitHubClient.get(base_ref_path, token, request_opts()) do
          {:ok, ref_data} ->
            case verify_base_sha(ref_data, create_req.expected_base_sha) do
              :ok ->
                if file_changes == [] do
                  create_pr(repo, create_req, token)
                else
                  create_change_request_with_files(
                    repo,
                    file_changes,
                    create_req,
                    ref_data,
                    token
                  )
                end

              {:error, _reason} = error ->
                error
            end

          {:error, :repository_not_found} ->
            {:error, :base_ref_not_found}

          {:error, reason} ->
            {:error, map_read_error(reason)}
        end

      {:error, reason} ->
        {:error, map_read_error(reason)}
    end
  end

  # ── Git data operations ──────────────────────────────────────────────

  defp verify_base_sha(%{"object" => %{"sha" => sha}}, %CommitSha{value: expected}) do
    if sha == expected, do: :ok, else: {:error, :base_sha_mismatch}
  end

  defp verify_base_sha(_ref_data, _expected_sha), do: {:error, :base_sha_mismatch}

  defp create_change_request_with_files(repo, file_changes, create_req, ref_data, token) do
    base_tree_sha = ref_data["object"]["sha"]

    with {:ok, blob_shas} <- create_blobs(repo, file_changes, token),
         {:ok, tree_sha} <- create_tree(repo, file_changes, blob_shas, base_tree_sha, token),
         {:ok, commit_sha} <- create_commit(repo, tree_sha, create_req, token),
         :ok <- update_head_ref(repo, commit_sha, create_req.head_ref, token) do
      create_pr(repo, create_req, token)
    else
      {:error, reason} -> {:error, map_git_data_error(reason)}
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

  defp update_head_ref(repo, commit_sha, head_ref, token) do
    path = "/repos/#{repo.external_id}/git/refs/heads/#{head_ref}"

    case GitHubClient.patch(path, token, %{sha: commit_sha, force: false}, request_opts()) do
      {:ok, _data} ->
        :ok

      {:error, reason} ->
        {:error, reason}
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
    with {:ok, token} <- installation_token(repo),
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
    with {:ok, token} <- installation_token(repo),
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
    case installation_token(repo) do
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

  defp map_uri(url) when is_binary(url), do: URI.parse(url)

  defp map_datetime(nil), do: nil

  defp map_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      {:error, _reason} -> nil
    end
  end

  # ── Token resolution ───────────────────────────────────────────────────

  # Resolves the GitHub App installation access token for the repo's account.
  # Returns `{:ok, token}` or a `GitHubClient` error atom (mapped by the caller
  # to a stable read/write error). The token is never logged.
  defp installation_token(%RepositoryRef{external_id: external_id}) do
    GitHubInstallation.token_for_repo(external_id)
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
