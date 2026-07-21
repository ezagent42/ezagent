defmodule EzagentPluginGithub.GitHubAdapter do
  @moduledoc """
  Maps Git domain operations to the GitHub REST API (v3).

  Each callback accepts `Ezagent.DomainGit` value types, calls the GitHub REST
  API via `GitHubClient`, and maps provider responses back to Domain Git structs.
  """
  @behaviour Ezagent.DomainGit.Adapter

  alias Ezagent.DomainGit.{
    ChangeRequest,
    ChangeRequestId,
    Check,
    CommitSha,
    CreateChangeRequest,
    RepositoryRef,
    Review
  }

  alias EzagentPluginGithub.GitHubClient

  @github_host "github.com"

  # Token resolution is handled by the caller (integration layer). For now the
  # adapter uses a placeholder that will be replaced once credential wiring lands.
  @placeholder_token ""

  @impl true
  def resolve_repository(_ctx, %RepositoryRef{} = repo) do
    path = "/repos/#{repo.external_id}"

    case GitHubClient.get(path, @placeholder_token, request_opts()) do
      {:ok, data} ->
        build_repository_ref(repo, data)

      {:error, reason} ->
        {:error, map_read_error(reason)}
    end
  end

  @impl true
  def create_change_request(
        _ctx,
        %RepositoryRef{} = repo,
        _file_changes,
        %CreateChangeRequest{} = create_req
      ) do
    path = "/repos/#{repo.external_id}/pulls"

    body = %{
      title: create_req.title,
      head: create_req.head_ref,
      base: repo.base_ref,
      body: create_req.body
    }

    case GitHubClient.post(path, @placeholder_token, body, request_opts()) do
      {:ok, data} ->
        build_change_request(data)

      {:error, reason} ->
        {:error, map_write_error(reason)}
    end
  end

  @impl true
  def read_change_request(_ctx, %RepositoryRef{} = repo, %ChangeRequestId{} = cr_id) do
    path = "/repos/#{repo.external_id}/pulls/#{cr_id.external_id}"

    case GitHubClient.get(path, @placeholder_token, request_opts()) do
      {:ok, data} ->
        build_change_request(data)

      {:error, reason} ->
        {:error, map_read_error(reason)}
    end
  end

  @impl true
  def list_checks(_ctx, %RepositoryRef{} = repo, %CommitSha{} = sha) do
    path = "/repos/#{repo.external_id}/commits/#{sha.value}/check-runs"

    case GitHubClient.get(path, @placeholder_token, request_opts()) do
      {:ok, %{"check_runs" => check_runs}} ->
        checks = Enum.map(check_runs, &build_check/1)
        {:ok, checks}

      {:error, reason} ->
        {:error, map_checks_error(reason)}
    end
  end

  @impl true
  def list_reviews(_ctx, %RepositoryRef{} = repo, %ChangeRequestId{} = cr_id) do
    path = "/repos/#{repo.external_id}/pulls/#{cr_id.external_id}/reviews"

    case GitHubClient.get(path, @placeholder_token, request_opts()) do
      {:ok, reviews} when is_list(reviews) ->
        result = Enum.map(reviews, &build_review/1)
        {:ok, result}

      {:ok, _unexpected} ->
        {:error, :provider_unavailable}

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
      provider_adapter: __MODULE__,
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
    {:ok, check} =
      Check.new(%{
        external_id: to_string(run["id"]),
        name: run["name"],
        status: map_check_status(run["status"]),
        conclusion: map_check_conclusion(run["conclusion"]),
        url: map_uri(run["details_url"])
      })

    check
  end

  defp build_review(review_data) do
    {:ok, review} =
      Review.new(%{
        external_id: to_string(review_data["id"]),
        author_label: review_data["user"]["login"],
        state: map_review_state(review_data["state"]),
        submitted_at: map_datetime(review_data["submitted_at"])
      })

    review
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

  defp map_review_state("approved"), do: :approved
  defp map_review_state("changes_requested"), do: :changes_requested
  defp map_review_state("comment"), do: :commented
  defp map_review_state("dismissed"), do: :dismissed
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
end
