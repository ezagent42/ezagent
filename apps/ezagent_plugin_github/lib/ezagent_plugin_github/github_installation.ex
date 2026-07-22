defmodule EzagentPluginGithub.GitHubInstallation do
  @moduledoc """
  Resolves and caches GitHub App **installation access tokens** — the credential
  used for repository operations (contents, PRs, checks).

  In the GitHub App model, repo access does NOT come from the connecting user's
  token; it comes from the App's installation on the repo's account. To act on a
  repository this module:

    1. Signs an App JWT (`EzagentPluginGithub.GitHubAppJwt`).
    2. `GET /repos/{owner}/{repo}/installation` (JWT auth) to resolve the
       installation `id` for that repo — deterministic: a repo belongs to exactly
       one installation.
    3. `POST /app/installations/{id}/access_tokens` (JWT auth) to mint a token,
       which GitHub returns with an ISO-8601 `expires_at` (~1 hour).

  Tokens are cached per account (owner) in an ETS table and reused across that
  account's repos until they approach expiry (60-second margin), then re-minted.
  The cache holds short-lived tokens in memory only (never persisted across
  boots), mirroring the in-memory lease posture of the credential backend.

  The owning process (an `Agent`) is started in the plugin supervision tree and
  keeps the ETS table alive for the application's lifetime.
  """

  alias EzagentPluginGithub.{GitHubAppJwt, GitHubClient}

  @table_name :github_installation_tokens
  # Re-mint when fewer than this many seconds remain, so a cached token never
  # expires mid-operation.
  @refresh_margin_seconds 60

  @doc """
  Returns a child specification so the module can own its ETS cache table in the
  application's supervision tree.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc """
  Starts the cache-owning process and creates the ETS table.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    Agent.start_link(
      fn ->
        ensure_table!()
        :ok
      end,
      name: name
    )
  end

  @doc """
  Returns a valid installation access token for `repo_full_name` (`"owner/repo"`).

  Returns a cached token when one exists for the repo's account and is not near
  expiry; otherwise mints a fresh one via the App JWT and caches it.

  `opts` are passed through to the underlying `GitHubClient` HTTP calls (e.g.
  `plug: {Req.Test, name}` for stubbing); they default to the
  `:installation_req_opts` application env.

  Returns `{:ok, token}` or `{:error, reason}` where `reason` is a stable
  `GitHubClient` error atom (`:authentication_rejected`, `:repository_not_found`,
  `:provider_denied`, `:provider_unavailable`, …). Raises (fail-loud) only if the
  App private key is missing/malformed — an operations misconfiguration.
  """
  @spec token_for_repo(String.t(), Keyword.t()) :: {:ok, String.t()} | {:error, atom()}
  def token_for_repo(repo_full_name, opts \\ []) when is_binary(repo_full_name) do
    ensure_table!()
    account = account_of(repo_full_name)
    now = System.system_time(:second)

    case cached_token(account, now) do
      {:ok, token} -> {:ok, token}
      :miss -> mint(account, repo_full_name, merged_opts(opts))
    end
  end

  @doc """
  Seeds the cache with a token for `account`, valid until `expires_at_unix`
  (Unix seconds). Test/support seam so callers can exercise the cache-hit path
  without hitting the GitHub API.
  """
  @spec put_cached_token(String.t(), String.t(), integer()) :: :ok
  def put_cached_token(account, token, expires_at_unix)
      when is_binary(account) and is_binary(token) and is_integer(expires_at_unix) do
    ensure_table!()
    :ets.insert(@table_name, {account, {token, expires_at_unix}})
    :ok
  end

  # ── Minting ────────────────────────────────────────────────────────────

  defp mint(account, repo_full_name, opts) do
    # Fail-loud on a missing/malformed key happens inside generate/0.
    jwt = GitHubAppJwt.generate()

    with {:ok, %{"id" => installation_id}} <-
           GitHubClient.get("/repos/#{repo_full_name}/installation", jwt, opts),
         {:ok, %{"token" => token} = body} <-
           GitHubClient.post(
             "/app/installations/#{installation_id}/access_tokens",
             jwt,
             %{},
             opts
           ) do
      maybe_cache(account, token, body["expires_at"])
      {:ok, token}
    else
      {:error, reason} -> {:error, reason}
      {:ok, _unexpected_shape} -> {:error, :provider_unavailable}
    end
  end

  # ── Cache ──────────────────────────────────────────────────────────────

  defp cached_token(account, now) do
    case :ets.lookup(@table_name, account) do
      [{^account, {token, expires_at_unix}}]
      when expires_at_unix - now > @refresh_margin_seconds ->
        {:ok, token}

      _stale_or_absent ->
        :miss
    end
  end

  defp maybe_cache(account, token, expires_at) when is_binary(expires_at) do
    case DateTime.from_iso8601(expires_at) do
      {:ok, dt, _offset} ->
        :ets.insert(@table_name, {account, {token, DateTime.to_unix(dt)}})

      {:error, _reason} ->
        # Unparseable expiry — use the token for this operation but don't cache a
        # token we cannot age out safely.
        :ok
    end
  end

  defp maybe_cache(_account, _token, _expires_at), do: :ok

  defp account_of(repo_full_name) do
    repo_full_name |> String.split("/") |> List.first()
  end

  defp merged_opts(opts) do
    Application.get_env(:ezagent_plugin_github, :installation_req_opts, [])
    |> Keyword.merge(opts)
  end

  defp ensure_table! do
    case :ets.whereis(@table_name) do
      :undefined ->
        :ets.new(@table_name, [:set, :public, :named_table])

      _tid ->
        :ok
    end
  end
end
