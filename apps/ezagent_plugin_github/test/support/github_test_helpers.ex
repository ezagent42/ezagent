defmodule EzagentPluginGithub.TestHelpers do
  @moduledoc """
  Test helpers for the GitHub plugin — shared fixtures and config setup.

  Provides `backend_pair/0`, `driver_declaration/0`, and `oauth_config/0` for
  use by driver, adapter, and credential backend tests.
  """

  @doc """
  Returns a `BackendPair` struct declaring the `pair-github-v1` pair that
  links the `local-authorization-v1` authorization backend with the
  `github-credential-v1` credential backend.
  """
  def backend_pair do
    Ezagent.ProviderConnection.BackendPair.new!(%{
      pair_id: "pair-github-v1",
      authorization_backend: %{id: "local-authorization-v1", fingerprint: "local-v1"},
      credential_backend: %{id: "github-credential-v1", fingerprint: "github-cred-v1"}
    })
  end

  @doc """
  Returns a `Driver` struct declaring the `github` / `oauth_user` driver that
  maps to `EzagentPluginGithub.GitHubDriver` and the `pair-github-v1` backend
  pair.
  """
  def driver_declaration do
    Ezagent.ProviderConnection.Driver.new!(%{
      provider_id: "github",
      acquisition_method: "oauth_user",
      provider_fingerprint: "github-driver-v1",
      implementation: EzagentPluginGithub.GitHubDriver,
      backend_pair_ids: ["pair-github-v1"],
      metadata: %{
        authorization_redirect_schema: %{
          type: :map,
          fields: %{
            "authorization_uri" => %{type: :string},
            "state" => %{type: :string},
            "pkce_digest" => %{type: :string}
          }
        },
        provider_metadata_schema: %{type: :map, fields: %{}}
      }
    })
  end

  @doc """
  Sets test OAuth client id and secret in application config.
  """
  def oauth_config do
    Application.put_env(:ezagent_plugin_github, :oauth_client_id, "test-client-id")
    Application.put_env(:ezagent_plugin_github, :oauth_client_secret, "test-secret")
  end
end
