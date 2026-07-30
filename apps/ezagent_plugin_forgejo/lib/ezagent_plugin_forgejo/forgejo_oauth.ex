defmodule EzagentPluginForgejo.ForgejoOAuth do
  @moduledoc """
  Forgejo OAuth2 authorization-code flow: URL construction, code exchange, refresh.

  Every function takes the tenant's registered OAuth application

      %{host: String.t(), client_id: String.t(), client_secret: String.t(),
        redirect_uri: String.t()}

  because Forgejo is self-hosted: the endpoints live on the tenant's own
  instance, and one Ezagent node routinely serves several. A module-level
  endpoint constant — which is correct for GitHub — would send every tenant's
  users to whichever instance was compiled in.

  ## Measured behaviour this module is built on

  Verified 2026-07-29 against `code.hyprial.com` (`15.0.5+gitea-1.22.0`),
  recorded in `docs/superpowers/specs/2026-07-29-forgejo-api-probe-findings.md`
  §7:

    * PKCE `S256` is supported;
    * `expires_in` is `3600`;
    * a refresh returns a new access token **and a new refresh token** —
      Forgejo rotates, so the old refresh token must be replaced, not kept;
    * the token response does **not** echo the granted scopes, so what was
      actually granted can only be inferred later from a scope-specific
      failure.

  ## Why the token endpoint does not go through `ForgejoClient`

  `ForgejoClient` speaks the REST API: `/api/v1` base, `Authorization: token`.
  The OAuth token endpoint is neither — it lives outside `/api/v1`, takes a
  form-encoded body, and authenticates with client credentials in that body.
  """

  alias EzagentPluginForgejo.Instance

  # Scopes are a design decision, not a per-call parameter: `write:repository`
  # for the PR loop's reads and writes, `read:user` to identify the connecting
  # account (`GET /user`, which `write:repository` alone cannot reach —
  # measured). Forgejo's grammar is `<read|write>:<category>` with no
  # repository selector, so this cannot be narrowed to one repo (design
  # §4.1.1).
  @scopes ["write:repository", "read:user"]

  @type app :: %{
          required(:host) => String.t(),
          required(:client_id) => String.t(),
          required(:client_secret) => String.t(),
          required(:redirect_uri) => String.t()
        }
  @type tokens :: %{
          access_token: String.t(),
          refresh_token: String.t() | nil,
          expires_at: DateTime.t() | nil
        }
  @type error :: :invalid_provider_host | :provider_protocol_failed | :provider_unreachable

  @doc """
  Builds the browser-bound authorization URL for a tenant's instance.

  Takes the PKCE *verifier* and derives the S256 challenge here, so the
  verifier itself never reaches the browser's URL bar or the instance's access
  logs. The caller keeps the verifier to present at `exchange_code/4`.
  """
  @spec authorize_url(app(), String.t(), String.t()) :: {:ok, String.t()} | {:error, error()}
  def authorize_url(
        %{client_id: client_id, redirect_uri: redirect_uri} = app,
        state,
        code_verifier
      )
      when is_binary(state) and is_binary(code_verifier) do
    with {:ok, base} <- web_base(app) do
      query =
        URI.encode_query(%{
          "response_type" => "code",
          "client_id" => client_id,
          "redirect_uri" => redirect_uri,
          "state" => state,
          "code_challenge" => s256_challenge(code_verifier),
          "code_challenge_method" => "S256",
          "scope" => Enum.join(@scopes, " ")
        })

      {:ok, base <> "/login/oauth/authorize?" <> query}
    end
  end

  @doc "Exchanges an authorization code for tokens, proving possession of the PKCE verifier."
  @spec exchange_code(app(), String.t(), String.t(), keyword()) ::
          {:ok, tokens()} | {:error, error()}
  def exchange_code(%{redirect_uri: redirect_uri} = app, code, code_verifier, opts \\ [])
      when is_binary(code) and is_binary(code_verifier) do
    post_token(
      app,
      %{
        "grant_type" => "authorization_code",
        "code" => code,
        "code_verifier" => code_verifier,
        "redirect_uri" => redirect_uri
      },
      opts
    )
  end

  @doc """
  Exchanges a refresh token for a fresh pair.

  Forgejo **rotates**: the returned `refresh_token` differs from the one sent,
  and the old one stops working. Callers must persist the returned pair rather
  than keeping the refresh token they had.
  """
  @spec refresh(app(), String.t(), keyword()) :: {:ok, tokens()} | {:error, error()}
  def refresh(app, refresh_token, opts \\ []) when is_binary(refresh_token) do
    post_token(app, %{"grant_type" => "refresh_token", "refresh_token" => refresh_token}, opts)
  end

  @doc "Returns the OAuth scopes this plugin requests."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  # ── internals ────────────────────────────────────────────────────────

  defp post_token(%{client_id: client_id, client_secret: client_secret} = app, params, opts) do
    with {:ok, base} <- web_base(app) do
      form = Map.merge(params, %{"client_id" => client_id, "client_secret" => client_secret})

      (base <> "/login/oauth/access_token")
      |> Req.post(
        Keyword.merge(
          [
            form: form,
            retry: false,
            headers: [
              {"accept", "application/json"},
              {"user-agent", "ezagent-forgejo-plugin"}
            ]
          ],
          opts
        )
      )
      |> handle_token_response()
    end
  end

  defp handle_token_response({:ok, %{status: status, body: body}})
       when status in 200..299 and is_map(body) do
    # All three fields are required, not best-effort. A credential without a
    # refresh token cannot be renewed and dies silently after an hour; one
    # without a positive `expires_in` gets recorded as non-expiring despite the
    # measured 1h lifetime, so nothing ever tries to renew it. Both produce a
    # connection that LOOKS active and fails later, which is worse than
    # refusing the exchange now.
    case body do
      %{"access_token" => access, "refresh_token" => refresh, "expires_in" => seconds}
      when is_binary(access) and access != "" and is_binary(refresh) and refresh != "" and
             is_integer(seconds) and seconds > 0 ->
        {:ok,
         %{
           access_token: access,
           refresh_token: refresh,
           expires_at: DateTime.add(DateTime.utc_now(), seconds, :second)
         }}

      _incomplete ->
        # A 2xx carrying `{"error": ...}` instead of a token is still a failed
        # exchange; treating it as success would store an empty credential.
        {:error, :provider_protocol_failed}
    end
  end

  defp handle_token_response({:ok, _response}), do: {:error, :provider_protocol_failed}

  # Same split as `ForgejoClient` (design §8.3): a lost response means the
  # remote state is unknown — the code may already have been consumed — while
  # a refusal means it definitively was not accepted.
  defp handle_token_response({:error, _exception}), do: {:error, :provider_unreachable}

  defp s256_challenge(verifier),
    do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

  # Reuses the host validation that guards the REST base (an allowlist, not a
  # blocklist) so a malformed host cannot redirect a user — or a client
  # secret — to another server. The web endpoints sit at the instance root,
  # not under `/api/v1`, so the `/api/v1` suffix is trimmed back off rather
  # than duplicating the regex.
  defp web_base(%{host: host}) do
    case Instance.api_base(host) do
      {:ok, api_base} -> {:ok, String.replace_suffix(api_base, "/api/v1", "")}
      {:error, reason} -> {:error, reason}
    end
  end
end
