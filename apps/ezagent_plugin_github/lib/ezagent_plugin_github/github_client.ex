defmodule EzagentPluginGithub.GitHubClient do
  @moduledoc """
  Thin Req wrapper for the GitHub REST API.

  Every call automatically injects:
    * `Authorization: Bearer <token>`
    * `Accept: application/vnd.github+json`
    * `User-Agent: ezagent-github-plugin`

  ## Returns

    Success (HTTP 2xx) → `{:ok, decoded_body}` where `decoded_body` is the
    JSON-decoded response body (a map for single-resource endpoints, a list
    for collection/search endpoints such as the PR search)
    Error (HTTP 4xx/5xx) → `{:error, reason_atom}` where `reason_atom` is one of:

      | Status            | Atom                       |
      |-------------------|----------------------------|
      | 401               | `:authentication_rejected`|
      | 403 (rate limit)  | `:provider_rate_limited`  |
      | 403 (other)       | `:provider_denied`        |
      | 404               | `:repository_not_found`   |
      | 422               | `:unprocessable_entity`   |
      | 429               | `:provider_rate_limited`  |
      | other             | `:provider_unavailable`   |

    A 403 is classified as a rate limit when the response carries
    `x-ratelimit-remaining: 0` (primary limit exhausted) or a `retry-after`
    header (secondary/abuse-detection limit) — otherwise it is a plain
    permission denial. Only those two header values are ever inspected; the
    full header list and the response body are never retained.

    `:unprocessable_entity` is a deliberately neutral 422 marker — this
    client has no idea whether a caller's 422 means "ref already exists"
    (a benign race) or a genuine Git-data validation failure or PR conflict.
    Each call site in the adapter classifies it using its own operation
    semantics; this client never guesses.
  """

  @base_url "https://api.github.com"

  @doc """
  Issues a GET request against the GitHub REST API.

  ## Examples

      GitHubClient.get("/user", "ghp_test_token")
      # => {:ok, %{"login" => "octocat", ...}}

      GitHubClient.get("/repos/owner/missing", "token")
      # => {:error, :repository_not_found}
  """
  @spec get(path :: String.t(), token :: String.t(), opts :: Keyword.t()) ::
          {:ok, map() | list()} | {:error, atom()}
  def get(path, token, opts \\ []) when is_binary(path) and is_binary(token) do
    base_opts = [
      headers: [
        {"authorization", "Bearer #{token}"},
        {"accept", "application/vnd.github+json"},
        {"user-agent", "ezagent-github-plugin"}
      ]
    ]

    (@base_url <> path)
    |> Req.get(Keyword.merge(base_opts, opts))
    |> handle_response()
  end

  @doc """
  Issues a POST request against the GitHub REST API with a JSON body.

  ## Examples

      GitHubClient.post("/repos/owner/repo/issues", "ghp_token", %{title: "Bug"})
      # => {:ok, %{"id" => 42, "number" => 1, ...}}
  """
  @spec post(path :: String.t(), token :: String.t(), body :: map(), opts :: Keyword.t()) ::
          {:ok, map()} | {:error, atom()}
  def post(path, token, body, opts \\ [])
      when is_binary(path) and is_binary(token) and is_map(body) do
    base_opts = [
      json: body,
      headers: [
        {"authorization", "Bearer #{token}"},
        {"accept", "application/vnd.github+json"},
        {"user-agent", "ezagent-github-plugin"}
      ]
    ]

    (@base_url <> path)
    |> Req.post(Keyword.merge(base_opts, opts))
    |> handle_response()
  end

  @doc """
  Issues a PATCH request against the GitHub REST API with a JSON body.

  ## Examples

      GitHubClient.patch("/repos/owner/repo/git/refs/heads/feature", "ghp_token", %{sha: "abc123"})
      # => {:ok, %{"ref" => "refs/heads/feature", ...}}
  """
  @spec patch(path :: String.t(), token :: String.t(), body :: map(), opts :: Keyword.t()) ::
          {:ok, map()} | {:error, atom()}
  def patch(path, token, body, opts \\ [])
      when is_binary(path) and is_binary(token) and is_map(body) do
    base_opts = [
      json: body,
      headers: [
        {"authorization", "Bearer #{token}"},
        {"accept", "application/vnd.github+json"},
        {"user-agent", "ezagent-github-plugin"}
      ]
    ]

    (@base_url <> path)
    |> Req.patch(Keyword.merge(base_opts, opts))
    |> handle_response()
  end

  # ── error mapping ────────────────────────────────────────────────────

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_response({:ok, %{status: 401}}), do: {:error, :authentication_rejected}
  defp handle_response({:ok, %{status: 404}}), do: {:error, :repository_not_found}
  defp handle_response({:ok, %{status: 403} = resp}), do: classify_403(resp)
  defp handle_response({:ok, %{status: 422}}), do: {:error, :unprocessable_entity}
  defp handle_response({:ok, %{status: 429}}), do: {:error, :provider_rate_limited}
  defp handle_response({:ok, _}), do: {:error, :provider_unavailable}
  defp handle_response({:error, _}), do: {:error, :provider_unavailable}

  # GitHub returns 403 (or 429) for BOTH a plain permission denial and a
  # rate limit; the two safe headers below are how it distinguishes them.
  # Primary limit exhaustion carries `x-ratelimit-remaining: 0`; a
  # secondary/abuse-detection limit carries `retry-after`. Neither the full
  # header list nor the response body is ever retained past this check.
  defp classify_403(resp) do
    if primary_limit_exhausted?(resp) or secondary_limit_signaled?(resp) do
      {:error, :provider_rate_limited}
    else
      {:error, :provider_denied}
    end
  end

  defp primary_limit_exhausted?(resp),
    do: Req.Response.get_header(resp, "x-ratelimit-remaining") == ["0"]

  defp secondary_limit_signaled?(resp),
    do: Req.Response.get_header(resp, "retry-after") != []
end
