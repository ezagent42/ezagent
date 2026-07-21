defmodule EzagentPluginGithub.GitHubOAuth do
  @moduledoc """
  GitHub OAuth URL construction and token exchange.

  Provides two public functions:
  - `authorize_url/2` — builds the GitHub OAuth authorization URL
  - `exchange_code/3` — exchanges an authorization code for an access token

  The token exchange uses `Req` directly (not `GitHubClient`) because the
  GitHub OAuth token endpoint expects a form-encoded body (`form:` option)
  and an `Accept: application/json` header, which differs from the GitHub
  REST API conventions used by `GitHubClient`.
  """

  @authorize_url "https://github.com/login/oauth/authorize"
  @token_url "https://github.com/login/oauth/access_token"

  @doc """
  Constructs the GitHub OAuth authorization URL.

  Returns a full URL pointing to `https://github.com/login/oauth/authorize`
  with `client_id`, `redirect_uri`, `state`, and `scope=repo` query parameters.

  ## Examples

      GitHubOAuth.authorize_url("https://example.com/callback", "state-abc")
      # => "https://github.com/login/oauth/authorize?client_id=...&redirect_uri=...&state=...&scope=repo"
  """
  @spec authorize_url(redirect_uri :: String.t(), state :: String.t()) :: String.t()
  def authorize_url(redirect_uri, state) do
    query =
      URI.encode_query(%{
        client_id: EzagentPluginGithub.Config.oauth_client_id(),
        redirect_uri: redirect_uri,
        state: state,
        scope: "repo"
      })

    "#{@authorize_url}?#{query}"
  end

  @doc """
  Exchanges an authorization code for an access token.

  POSTs to the GitHub OAuth token endpoint (`https://github.com/login/oauth/access_token`)
  with form-encoded `client_id`, `client_secret`, `code`, and `redirect_uri`.

  Accepts an optional keyword list of `Req` options (e.g. `plug: {Req.Test, name}`
  for test stubbing) as the third argument.

  ## Examples

      GitHubOAuth.exchange_code("abc123", "https://example.com/callback")
      # => {:ok, %{access_token: "gho_xxx"}}

      GitHubOAuth.exchange_code("abc123", "https://example.com/callback",
        plug: {Req.Test, :my_stub}
      )
  """
  @spec exchange_code(code :: String.t(), redirect_uri :: String.t(), opts :: Keyword.t()) ::
          {:ok, %{access_token: String.t()}} | {:error, atom()}
  def exchange_code(code, redirect_uri, opts \\ []) do
    body = %{
      client_id: EzagentPluginGithub.Config.oauth_client_id(),
      client_secret: EzagentPluginGithub.Config.oauth_client_secret(),
      code: code,
      redirect_uri: redirect_uri
    }

    base_opts = [
      form: body,
      headers: [
        {"accept", "application/json"},
        {"user-agent", "ezagent-github-plugin"}
      ]
    ]

    case Req.post(@token_url, Keyword.merge(base_opts, opts)) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} ->
        {:ok, %{access_token: token}}

      {:ok, %{status: status}} when status in 400..499 ->
        {:error, :provider_denied}

      {:ok, %{status: status}} when status >= 500 ->
        {:error, :backend_unavailable}

      {:error, _} ->
        {:error, :backend_unavailable}
    end
  end
end
