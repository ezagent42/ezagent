defmodule EzagentPluginGithub.TestHelpers do
  @moduledoc """
  Test helpers for the GitHub plugin — shared fixtures and config setup.

  Provides `backend_pair/0`, `driver_declaration/0`, `github_config/0`, and a
  generated test RSA key (`test_private_key_pem/0`) for driver, adapter,
  credential-backend, JWT, and installation tests. No real GitHub App secrets are
  needed — everything here is synthetic.
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
  Sets synthetic GitHub App config (app_id, user-to-server client_id/secret, a
  generated private key PEM, and a webhook secret) in application env.
  """
  def github_config do
    Application.put_env(:ezagent_plugin_github, :app_id, "4361756")
    Application.put_env(:ezagent_plugin_github, :client_id, "test-client-id")
    Application.put_env(:ezagent_plugin_github, :client_secret, "test-secret")
    Application.put_env(:ezagent_plugin_github, :private_key, test_private_key_pem())
    Application.put_env(:ezagent_plugin_github, :webhook_secret, "test-webhook-secret")
  end

  @doc """
  Generates a fresh 2048-bit RSA private key and encodes it as a PKCS#1 PEM
  string (the `BEGIN RSA PRIVATE KEY` form GitHub Apps issue).
  """
  def test_private_key_pem do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    entry = :public_key.pem_entry_encode(:RSAPrivateKey, key)
    :public_key.pem_encode([entry])
  end
end
