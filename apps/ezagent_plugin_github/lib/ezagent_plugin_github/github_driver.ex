defmodule EzagentPluginGithub.GitHubDriver do
  @moduledoc """
  Driver behaviour implementation for the GitHub OAuth App provider.

  Implements all 8 `Ezagent.ProviderConnection.Driver` callbacks to support
  the GitHub OAuth App authorization lifecycle — begin, consume, refresh,
  revoke, and discard operations.

  ## Callback summary

    * `begin_authorization/1` — constructs a GitHub OAuth authorization URL
      via the exchange function. The redirect contains `authorization_uri`,
      `state`, and `pkce_digest` (URL-safe base64 SHA256 of the verifier).

    * `consume_callback/1` — exchanges the authorization code for an access
      token via `GitHubOAuth.exchange_code/2`.

    * `refresh/1` — no-op (OAuth App tokens never expire). Calls
      `CredentialRefreshExchange.consume_refresh_exchange/1`.

    * `reconcile_callback/1`, `reconcile_refresh/1` — return
      `{:ok, :not_completed}`.

    * `discard_callback_result/1`, `discard_refresh_result/1` — return `:ok`.

    * `revoke/1` — returns `{:ok, %{revoked: true}}`.
  """

  @behaviour Ezagent.ProviderConnection.Driver

  alias EzagentPluginGithub.{Config, GitHubClient, GitHubOAuth}

  @impl true
  def begin_authorization(%{exchange: exchange} = _context) when is_function(exchange, 1) do
    exchange.(fn private_frame ->
      url = GitHubOAuth.authorize_url(Config.redirect_uri(), private_frame.state)

      pkce_digest =
        :crypto.hash(:sha256, private_frame.pkce_verifier) |> Base.url_encode64(padding: false)

      {:ok,
       %{
         redirect: %{
           "authorization_uri" => url,
           "state" => private_frame.state,
           "pkce_digest" => pkce_digest
         }
       }}
    end)
  end

  def begin_authorization(_context), do: {:error, :provider_protocol_failed}

  @impl true
  def consume_callback(%{exchange: exchange} = context) when is_function(exchange, 1) do
    corr_id = Map.get(context, :correlation_id, "unknown")

    exchange.(fn private_frame ->
      code = private_frame.callback_envelope[:code] || private_frame.callback_envelope["code"]

      case GitHubOAuth.exchange_code(code, Config.redirect_uri()) do
        {:ok, %{access_token: token}} ->
          case GitHubClient.get("/user", token) do
            {:ok, user} ->
              external_account_id = Integer.to_string(user["id"])
              display_login = user["login"]

              {:ok,
               %{
                 provider_result_ref: "gh-result-#{corr_id}",
                 external_account_id: external_account_id,
                 display_login: display_login,
                 execution_identity: %{
                   kind: :connected_user,
                   external_account_id: external_account_id
                 },
                 authorization_ref: context.authorization_ref,
                 authorization_version:
                   (Map.get(context, :expected_authorization_version, 0) || 0) + 1,
                 credential_material: {:write_only_handoff, token},
                 granted_permissions_digest: "repo",
                 expires_at: nil,
                 provider_metadata: %{}
               }}

            {:error, _reason} ->
              {:error, :provider_protocol_failed}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  def consume_callback(_context), do: {:error, :provider_protocol_failed}

  @impl true
  def reconcile_callback(%{exchange: exchange, correlation_id: _corr_id}) do
    exchange.(fn _private_frame ->
      {:ok, :not_completed}
    end)
  end

  def reconcile_callback(_context), do: {:ok, :not_completed}

  @impl true
  def refresh(%{refresh_use: refresh_use}) do
    Ezagent.ProviderConnection.CredentialRefreshExchange.consume_refresh_exchange(%{
      refresh_use: refresh_use,
      provider_exchange: fn _private_frame ->
        {:ok,
         %{
           provider_result_ref: "gh-refresh-noop",
           replacement_credential: {:write_only_handoff, "github-noop-refresh"},
           granted_permissions_digest: "repo",
           expires_at: nil,
           provider_metadata: %{}
         }}
      end
    })
  end

  def refresh(_context), do: {:error, :provider_protocol_failed}

  @impl true
  def reconcile_refresh(%{refresh_use: refresh_use}) do
    Ezagent.ProviderConnection.CredentialRefreshExchange.consume_refresh_exchange(%{
      refresh_use: refresh_use,
      provider_exchange: fn _private_frame ->
        {:ok, :not_completed}
      end
    })
  end

  def reconcile_refresh(_context), do: {:error, :provider_protocol_failed}

  @impl true
  def discard_callback_result(_context), do: :ok

  @impl true
  def discard_refresh_result(_context), do: :ok

  @impl true
  def revoke(_context), do: {:ok, %{revoked: true}}
end
