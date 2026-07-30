defmodule EzagentPluginForgejo.ForgejoDriver do
  @moduledoc """
  `Ezagent.ProviderConnection.Driver` for Forgejo's OAuth2 authorization-code flow.

  One declaration — `{"forgejo", "oauth_user"}` — serves every Forgejo instance.
  The per-instance difference is carried by the connection's `governed_host`,
  which the domain passes in both the driver context and the private frame, and
  which selects the tenant's registered OAuth application
  (`EzagentPluginForgejo.OAuthApp`). Nothing about a specific instance is
  compiled in.

  ## Where the credential comes from

  `consume_callback/1` exchanges the authorization code for an access token
  **and a refresh token**, then calls `GET /user` to learn which account
  authorized. Both tokens plus the absolute expiry travel to the credential
  backend as one JSON-encoded handoff: Forgejo rotates refresh tokens, so a
  credential that stored only the access token could never be refreshed — it
  would simply stop working an hour later.

  ## Renewal

  A Forgejo access token expires in an hour and IS the repository credential,
  so renewal is load-bearing — unlike GitHub, where a fresh installation token
  is minted per operation and the stored user-to-server token is identity-only
  (which is why that plugin's refresh path is a no-op without consequence).

  `refresh/1` and `reconcile_refresh/1` delegate to the domain's exchange
  facade, which owns the scope authority and routes the provider closure
  through the credential backend. `renew/2` is the Forgejo-specific half and
  is public for exactly that reason: it is the part worth testing on its own,
  given the current refresh token and nothing else.

  Forgejo **rotates** refresh tokens, so a renewal returns a new pair and the
  previous refresh token stops working; `renew/2` therefore hands back both
  tokens as the replacement credential, never just the access token.
  """

  @behaviour Ezagent.ProviderConnection.Driver

  alias Ezagent.ProviderConnection.CredentialBackend.RefreshUse
  alias Ezagent.ProviderConnection.CredentialRefreshExchange
  alias EzagentPluginForgejo.{ForgejoClient, ForgejoOAuth, Instance, OAuthApp}

  @impl true
  def begin_authorization(%{exchange: exchange} = context) when is_function(exchange, 1) do
    exchange.(fn %{state: state, pkce_verifier: verifier} = frame ->
      with {:ok, app} <- tenant_app(context, frame),
           {:ok, url} <- ForgejoOAuth.authorize_url(app, state, verifier) do
        {:ok,
         %{
           redirect: %{
             "authorization_uri" => url,
             "state" => state,
             "pkce_digest" => pkce_digest(verifier)
           }
         }}
      else
        {:error, _reason} -> {:error, :provider_protocol_failed}
      end
    end)
  end

  def begin_authorization(_context), do: {:error, :provider_protocol_failed}

  @impl true
  def consume_callback(%{exchange: exchange} = context) when is_function(exchange, 1) do
    corr_id = Map.get(context, :correlation_id, "unknown")

    exchange.(fn %{pkce_verifier: verifier} = frame ->
      with {:ok, app} <- tenant_app(context, frame),
           {:ok, code} <- authorization_code(frame),
           {:ok, %{access_token: access} = tokens} <-
             ForgejoOAuth.exchange_code(app, code, verifier, req_opts()),
           {:ok, account} <- connected_account(app, access) do
        {:ok, consume_result(context, corr_id, tokens, account)}
      else
        {:error, _reason} -> {:error, :provider_protocol_failed}
      end
    end)
  end

  def consume_callback(_context), do: {:error, :provider_protocol_failed}

  # An authorization code is single-use. If the first attempt's response was
  # lost, the code may already have been consumed and cannot be replayed into
  # the same credential -- and this driver holds no provider-side handle to
  # look the outcome up by. Reporting `:not_completed` lets the domain restart
  # authorization, which is correct; inventing a result would not be.
  @impl true
  def reconcile_callback(%{exchange: exchange}) when is_function(exchange, 1),
    do: exchange.(fn _frame -> {:ok, :not_completed} end)

  def reconcile_callback(_context), do: {:ok, :not_completed}

  @impl true
  def refresh(%{refresh_use: %RefreshUse{} = use} = context) do
    CredentialRefreshExchange.consume_refresh_exchange(%{
      refresh_use: use,
      provider_exchange: &renew(context, &1)
    })
  end

  def refresh(_context), do: {:error, :provider_protocol_failed}

  # A renewal that lost its response left no provider-side handle to look the
  # outcome up by, and the refresh token may already have been rotated away by
  # the attempt that was lost. Reporting `:not_completed` lets the domain
  # decide (retry the refresh, or fall back to re-authorization) instead of
  # this driver guessing which token is now live.
  @impl true
  def reconcile_refresh(%{refresh_use: %RefreshUse{} = use}) do
    CredentialRefreshExchange.consume_refresh_exchange(%{
      refresh_use: use,
      provider_exchange: fn _frame -> {:ok, :not_completed} end
    })
  end

  def reconcile_refresh(_context), do: {:error, :provider_protocol_failed}

  @doc """
  Renews a connection's credential against the tenant's Forgejo instance.

  This is the provider half of `refresh/1`: the domain's exchange facade calls
  it with the current refresh token, sourced from the credential backend. It is
  public because it is the Forgejo-specific logic — `refresh/1` around it is
  delegation the domain already tests.

  Returns the five-key shape the domain seals, carrying **both** rotated tokens:
  Forgejo invalidates the previous refresh token on use, so a replacement that
  held only the access token could never be renewed again.
  """
  @spec renew(map(), map()) :: {:ok, map()} | {:error, atom()}
  def renew(context, %{current_credential: refresh_token}) when is_binary(refresh_token) do
    with {:ok, app} <- tenant_app(context, %{}),
         {:ok, %{expires_at: expires_at} = tokens} <-
           ForgejoOAuth.refresh(app, refresh_token, req_opts()) do
      {:ok,
       %{
         provider_result_ref: "forgejo-refresh-#{Map.get(context, :correlation_id, "unknown")}",
         replacement_credential: {:write_only_handoff, encode_credential(tokens)},
         granted_permissions_digest: permissions_digest(),
         expires_at: expires_at,
         provider_metadata: %{}
       }}
    else
      {:error, _reason} -> {:error, :provider_protocol_failed}
    end
  end

  def renew(_context, _frame), do: {:error, :provider_protocol_failed}

  @impl true
  def discard_callback_result(_context), do: :ok

  @impl true
  def discard_refresh_result(_context), do: :ok

  # Forgejo exposes no token-revocation endpoint (checked against the target
  # instance's swagger) -- a user revokes an application from their own account
  # settings. Nothing is called remotely; this reports that the local side is
  # done so the domain can reach a terminal state.
  @impl true
  def revoke(_context), do: {:ok, %{revoked: true}}

  # ── internals ────────────────────────────────────────────────────────

  # `governed_host` arrives on both the context (driver identity) and the
  # private frame; `workspace_uri` only on the context. Preferring the frame's
  # host keeps the lookup keyed to the same value the domain sealed into the
  # exchange, and falls back to the context when a frame omits it.
  defp tenant_app(context, frame) do
    workspace_uri = Map.get(context, :workspace_uri)
    host = Map.get(frame, :governed_host) || Map.get(context, :governed_host)

    if is_binary(workspace_uri) and is_binary(host) do
      OAuthApp.fetch(workspace_uri, host)
    else
      {:error, :oauth_app_not_registered}
    end
  end

  defp authorization_code(%{callback_envelope: envelope}) when is_map(envelope) do
    case envelope[:code] || envelope["code"] do
      code when is_binary(code) and code != "" -> {:ok, code}
      _missing -> {:error, :provider_protocol_failed}
    end
  end

  defp authorization_code(_frame), do: {:error, :provider_protocol_failed}

  # A token that cannot name its own account is unusable here even though the
  # exchange succeeded: storing it would leave a connection that looks bound
  # and fails on first real use.
  defp connected_account(%{host: host}, access_token) do
    with {:ok, base} <- Instance.api_base(host),
         {:ok, %{"id" => id, "login" => login}} <-
           ForgejoClient.get(base, "/user", access_token, req_opts()) do
      {:ok, %{external_account_id: to_string(id), display_login: login}}
    else
      _error -> {:error, :provider_protocol_failed}
    end
  end

  defp consume_result(context, corr_id, %{expires_at: expires_at} = tokens, account) do
    %{external_account_id: external_account_id, display_login: display_login} = account

    %{
      provider_result_ref: "forgejo-result-#{corr_id}",
      external_account_id: external_account_id,
      display_login: display_login,
      execution_identity: %{kind: :connected_user, external_account_id: external_account_id},
      authorization_ref: Map.get(context, :authorization_ref),
      authorization_version: (Map.get(context, :expected_authorization_version, 0) || 0) + 1,
      credential_material: {:write_only_handoff, encode_credential(tokens)},
      granted_permissions_digest: permissions_digest(),
      expires_at: expires_at,
      provider_metadata: %{}
    }
  end

  # Both tokens plus the expiry are one credential: Forgejo rotates refresh
  # tokens, so they are only useful together. JSON keeps the handoff a plain
  # binary, which is what the backend seals.
  defp encode_credential(%{
         access_token: access_token,
         refresh_token: refresh_token,
         expires_at: expires_at
       }) do
    Jason.encode!(%{
      "access_token" => access_token,
      "refresh_token" => refresh_token,
      "expires_at" => expires_at && DateTime.to_iso8601(expires_at)
    })
  end

  # The token response does not echo what was actually granted (measured), so
  # this records what was REQUESTED. It is a digest of intent, not of a
  # provider confirmation -- a scope that was silently withheld surfaces later
  # as a named scope error on the failing call.
  defp permissions_digest, do: "requested:" <> Enum.join(ForgejoOAuth.scopes(), ",")

  defp pkce_digest(verifier),
    do: :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)

  defp req_opts, do: Application.get_env(:ezagent_plugin_forgejo, :adapter_req_opts, [])
end
