defmodule EzagentPluginGithub.Config do
  @moduledoc """
  Runtime configuration for the `:ezagent_plugin_github` OTP application.

  The plugin authenticates to GitHub as a **GitHub App** (app_id 4361756), which
  uses three distinct credential surfaces:

    * `app_id` + `private_key` (PEM) — sign the App JWT that authenticates AS THE
      APP and mints installation access tokens for repo operations.
    * `client_id` + `client_secret` — the App's user-to-server OAuth credentials,
      used only to identify WHO the connecting user is (not for repo access).
    * `webhook_secret` — HMAC key for verifying inbound webhook deliveries.

  Non-secret identifiers (`app_id`, `client_id`) are configured directly. Secrets
  (`client_secret`, `private_key`, `webhook_secret`) are supplied via
  `{:system, "ENV_VAR"}` and must never be hardcoded in source.

  Supports two lookup modes:
    * `{:system, "ENV_VAR"}` — read the value from the named environment variable
    * direct binary — return the value as-is

  Raises a human-readable `RuntimeError` when a required key is missing or the
  environment variable is unset, so boot-time misconfiguration is caught eagerly
  rather than silently producing `nil`.
  """

  @doc """
  Returns the GitHub App's numeric application ID (used as the JWT `iss` claim).
  """
  @spec app_id :: String.t()
  def app_id, do: fetch_env!(:app_id)

  @doc """
  Returns the GitHub App's OAuth client ID (user-to-server identity flow).
  """
  @spec client_id :: String.t()
  def client_id, do: fetch_env!(:client_id)

  @doc """
  Returns the GitHub App's OAuth client secret (user-to-server identity flow).
  """
  @spec client_secret :: String.t()
  def client_secret, do: fetch_env!(:client_secret)

  @doc """
  Returns the GitHub App's private key, decoded from PEM into an Erlang
  `:public_key` private-key record ready for RS256 signing.

  Fails loud (raises `RuntimeError`) when the key is missing OR when the
  configured value is not a decodable PEM private key — never falls back to a
  placeholder, which would produce JWTs GitHub rejects and a silently-dead App.

  The PEM string itself is treated as a write-only secret: it is decoded here and
  never returned or logged in cleartext.
  """
  @spec private_key :: tuple()
  def private_key do
    pem = fetch_env!(:private_key)

    case :public_key.pem_decode(pem) do
      [entry | _rest] ->
        try do
          :public_key.pem_entry_decode(entry)
        rescue
          _error ->
            raise "Invalid GITHUB_APP_PRIVATE_KEY: PEM entry could not be decoded as a private key"
        end

      [] ->
        raise "Invalid GITHUB_APP_PRIVATE_KEY: expected a PEM-encoded private key"
    end
  end

  @doc """
  Returns the GitHub App webhook secret used to verify `X-Hub-Signature-256`.
  """
  @spec webhook_secret :: String.t()
  def webhook_secret, do: fetch_env!(:webhook_secret)

  @doc """
  Returns the OAuth redirect URI for the GitHub App user-to-server callback.
  Reads from Application env with a development-friendly default.
  """
  @spec redirect_uri :: String.t()
  def redirect_uri,
    do:
      Application.get_env(
        :ezagent_plugin_github,
        :redirect_uri,
        "https://ezagent.example/github/callback"
      )

  @doc """
  Returns the token encryption key for AES-256-GCM credential storage.

  Must be 32 bytes decoded from a base64-encoded string in config or env var
  `GITHUB_TOKEN_ENCRYPTION_KEY`. Returns `nil` when not configured — the caller
  should fall back to a module-load-time random key for development.
  """
  @spec token_encryption_key :: String.t() | nil
  def token_encryption_key do
    case Application.get_env(:ezagent_plugin_github, :token_encryption_key) do
      {:system, env_var} ->
        System.get_env(env_var)

      value when is_binary(value) ->
        value

      nil ->
        nil
    end
  end

  defp fetch_env!(key) do
    case Application.get_env(:ezagent_plugin_github, key) do
      {:system, env_var} ->
        System.get_env(env_var) || raise "Missing env var: #{env_var}"

      value when is_binary(value) ->
        value

      nil ->
        raise "Missing config: :ezagent_plugin_github, #{key}"
    end
  end
end
