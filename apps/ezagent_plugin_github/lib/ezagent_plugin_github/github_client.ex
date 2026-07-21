defmodule EzagentPluginGithub.GitHubClient do
  @moduledoc """
  Thin Req wrapper for the GitHub REST API.

  Every call automatically injects:
    * `Authorization: Bearer <token>`
    * `Accept: application/vnd.github+json`
    * `User-Agent: ezagent-github-plugin`

  ## Returns

    Success (HTTP 2xx) → `{:ok, decoded_body}` where `decoded_body` is a map
    Error (HTTP 4xx/5xx) → `{:error, reason_atom}` where `reason_atom` is one of:

      | Status | Atom                          |
      |--------|-------------------------------|
      | 401    | `:authentication_rejected`    |
      | 403    | `:provider_denied`            |
      | 404    | `:repository_not_found`       |
      | 422    | `:change_request_conflict`    |
      | other  | `:provider_unavailable`       |
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
          {:ok, map()} | {:error, atom()}
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

  # ── error mapping ────────────────────────────────────────────────────

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299,
    do: {:ok, body}

  defp handle_response({:ok, %{status: 401}}), do: {:error, :authentication_rejected}
  defp handle_response({:ok, %{status: 404}}), do: {:error, :repository_not_found}
  defp handle_response({:ok, %{status: 403}}), do: {:error, :provider_denied}
  defp handle_response({:ok, %{status: 422}}), do: {:error, :change_request_conflict}
  defp handle_response({:ok, _}), do: {:error, :provider_unavailable}
  defp handle_response({:error, _}), do: {:error, :provider_unavailable}
end
