defmodule EzagentPluginGithub.Config do
  @moduledoc """
  Runtime configuration for the `:ezagent_plugin_github` OTP application.

  Supports two lookup modes:
    * `{:system, "ENV_VAR"}` — read the value from the named environment variable
    * direct binary — return the value as-is

  Raises a human-readable `RuntimeError` when the key is missing or the
  environment variable is unset, so boot-time misconfiguration is caught
  eagerly rather than silently producing `nil`.
  """

  @doc """
  Returns the GitHub OAuth App client ID.
  """
  @spec oauth_client_id :: String.t()
  def oauth_client_id, do: fetch_env!(:oauth_client_id)

  @doc """
  Returns the GitHub OAuth App client secret.
  """
  @spec oauth_client_secret :: String.t()
  def oauth_client_secret, do: fetch_env!(:oauth_client_secret)

  @doc """
  Returns the OAuth redirect URI for the GitHub OAuth App callback.
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
