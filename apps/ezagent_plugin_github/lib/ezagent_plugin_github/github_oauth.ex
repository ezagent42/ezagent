defmodule EzagentPluginGithub.GitHubOAuth do
  @moduledoc """
  GitHub App **user-to-server** OAuth — URL construction and token exchange.

  This is the IDENTITY flow: it establishes WHO the connecting user is. A GitHub
  App reuses the same OAuth endpoints as a classic OAuth App
  (`login/oauth/authorize` / `login/oauth/access_token`) with the App's
  `client_id`/`client_secret`, and returns a user-to-server token (`ghu_…`)
  scoped to the App's installations.

  Repository access does NOT come from this token — it comes from the App's
  installation access token (`EzagentPluginGithub.GitHubInstallation`). A GitHub
  App's user-to-server OAuth therefore takes NO `scope` parameter; requesting
  `scope=repo` (the classic OAuth-App model) is meaningless here and is omitted.

  Provides two public functions:
  - `authorize_url/2` — builds the GitHub user-to-server authorization URL
  - `exchange_code/3` — exchanges an authorization code for a user-to-server token

  The token exchange uses `Req` directly (not `GitHubClient`) because the GitHub
  OAuth token endpoint expects a form-encoded body (`form:` option) and an
  `Accept: application/json` header, which differs from the GitHub REST API
  conventions used by `GitHubClient`.
  """

  @authorize_url "https://github.com/login/oauth/authorize"
  @token_url "https://github.com/login/oauth/access_token"

  @doc """
  Constructs the GitHub App user-to-server authorization URL.

  Returns a full URL pointing to `https://github.com/login/oauth/authorize` with
  `client_id`, `redirect_uri`, and `state` query parameters. No `scope` is sent —
  a GitHub App's repo access is governed by its installation, not the user token.

  ## Examples

      GitHubOAuth.authorize_url("https://example.com/callback", "state-abc")
      # => "https://github.com/login/oauth/authorize?client_id=...&redirect_uri=...&state=..."
  """
  @spec authorize_url(redirect_uri :: String.t(), state :: String.t()) :: String.t()
  def authorize_url(redirect_uri, state) do
    query =
      URI.encode_query(%{
        client_id: EzagentPluginGithub.Config.client_id(),
        redirect_uri: redirect_uri,
        state: state
      })

    "#{@authorize_url}?#{query}"
  end

  @doc """
  Exchanges an authorization code for a user-to-server access token.

  POSTs to the GitHub OAuth token endpoint (`https://github.com/login/oauth/access_token`)
  with form-encoded `client_id`, `client_secret`, `code`, and `redirect_uri`.

  Accepts an optional keyword list of `Req` options (e.g. `plug: {Req.Test, name}`
  for test stubbing) as the third argument.

  ## Examples

      GitHubOAuth.exchange_code("abc123", "https://example.com/callback")
      # => {:ok, %{access_token: "ghu_xxx"}}

      GitHubOAuth.exchange_code("abc123", "https://example.com/callback",
        plug: {Req.Test, :my_stub}
      )
  """
  @spec exchange_code(code :: String.t(), redirect_uri :: String.t(), opts :: Keyword.t()) ::
          {:ok, %{access_token: String.t()}} | {:error, atom()}
  def exchange_code(code, redirect_uri, opts \\ []) do
    body = %{
      client_id: EzagentPluginGithub.Config.client_id(),
      client_secret: EzagentPluginGithub.Config.client_secret(),
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
