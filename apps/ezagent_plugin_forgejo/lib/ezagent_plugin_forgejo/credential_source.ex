defmodule EzagentPluginForgejo.CredentialSource do
  @moduledoc """
  Resolves a stored connection into the access token an adapter call needs.

  This step has no GitHub counterpart: a GitHub App mints a credential per
  operation and never looks one up. A Forgejo credential was issued once, at
  authorization time, so the adapter must first find the right connection —
  keyed by `{workspace, credential owner, provider, instance host}` — and then
  lease its credential.

  `credential_owner_uri` reaches this module through
  `Ezagent.DomainGit.OperationContext`; the other three come from the
  `Ezagent.DomainGit.RepositoryRef` and the driver's fixed provider id.

  ## Why `execution_identity` is a constant here

  `Ezagent.ProviderConnection.Selector.select/1` requires it as one of five
  exact axes. It is not a provider account identifier (that is
  `external_account_id`) but an identity *class*, and
  `EzagentPluginForgejo.ForgejoDriver.consume_callback/1` only ever emits
  `:connected_user`. Supplying it here keeps a provider-side concept out of the
  provider-neutral `OperationContext`.

  ## Access token only

  The stored credential is a JSON bundle holding both tokens. Only the access
  token leaves this module. The refresh token exists so renewal can happen;
  handing it to an HTTP call would hand out a long-lived capability where a
  short-lived one was asked for.
  """

  alias Ezagent.ProviderConnection.Selector
  alias EzagentPluginForgejo.ForgejoCredentialBackend

  @execution_identity "connected_user"
  @provider_id "forgejo"

  @doc """
  Returns the access token for the credential-owner's connection to one instance.

  Errors are `Ezagent.DomainGit.Error` members so adapter call sites can return
  them unchanged:

    * `:provider_account_not_connected` — no selectable connection for that
      exact scope. Also what a revoked or disconnected connection produces:
      `Selector` excludes terminal states, and serving a withdrawn
      authorization's credential would keep it working.
    * `:credential_backend_unavailable` — the connection points at a
      credential that cannot be leased or is not this plugin's bundle.
  """
  @spec access_token(String.t(), String.t(), String.t()) ::
          {:ok, String.t()}
          | {:error, :provider_account_not_connected | :credential_backend_unavailable}
  def access_token(workspace_uri, credential_owner_uri, governed_host)
      when is_binary(workspace_uri) and is_binary(credential_owner_uri) and
             is_binary(governed_host) do
    scope = %{
      owner_uri: credential_owner_uri,
      workspace_uri: workspace_uri,
      provider_id: @provider_id,
      governed_host: governed_host,
      execution_identity: @execution_identity
    }

    case Selector.select(scope) do
      {:ok, %{credential_backend_ref: ref}} when is_binary(ref) -> lease(workspace_uri, ref)
      {:ok, _no_credential_pointer} -> {:error, :provider_account_not_connected}
      {:error, _reason} -> {:error, :provider_account_not_connected}
    end
  end

  # The workspace travels with the ref. `Selector.select/1` already chose the
  # connection by tenant, so passing it on means a mis-bound or stale pointer to
  # ANOTHER tenant's credential reads as a miss instead of leasing their token.
  defp lease(workspace_uri, ref) do
    with {:ok, %{credential: credential}} <-
           ForgejoCredentialBackend.lease_for_operation(%{
             workspace_uri: workspace_uri,
             credential_ref: ref
           }),
         {:ok, %{"access_token" => access}} when is_binary(access) and access != "" <-
           Jason.decode(credential) do
      {:ok, access}
    else
      # A credential that is not this plugin's bundle means something else
      # wrote that row. Sending an unknown blob to the instance as a bearer
      # token would be worse than refusing.
      _unusable -> {:error, :credential_backend_unavailable}
    end
  end
end
