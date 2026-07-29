defmodule EzagentPluginForgejo.Sealed do
  @moduledoc """
  AES-256-GCM sealing for this plugin's two at-rest secrets.

  Both the connected user's OAuth tokens
  (`EzagentPluginForgejo.ForgejoCredentialBackend`) and a tenant's OAuth
  application client secret (`EzagentPluginForgejo.OAuthApp`) are sealed here,
  under `:ezagent_plugin_forgejo, :token_encryption_key`.

  This started life as private functions inside the credential backend, with a
  note that a second copy should be promoted rather than duplicated. The second
  caller arrived with slice F0, so it was promoted.

  The key is read per call rather than captured at start-up, so rotating the
  configured key takes effect without a restart. A key that fails to decode
  raises: booting with a silently-wrong key would orphan every stored secret
  with no signal.
  """

  @key_size 32
  @nonce_size 12
  @tag_size 16

  # Only usable within a single VM session. Real deployments MUST configure a
  # stable key, or every restart orphans every stored secret.
  @fallback_key :crypto.strong_rand_bytes(@key_size)

  @type sealed :: {nonce :: binary(), ciphertext_with_tag :: binary()}

  @doc "Seals plaintext, returning the nonce and ciphertext-with-tag to store."
  @spec seal(binary()) :: sealed()
  def seal(plaintext) when is_binary(plaintext) do
    nonce = :crypto.strong_rand_bytes(@nonce_size)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key(), nonce, plaintext, "", true)

    {nonce, ciphertext <> tag}
  end

  @doc """
  Opens a sealed value.

  Returns `{:error, :authentication_failed}` when the GCM tag does not verify —
  a wrong key or a tampered row — rather than returning garbage plaintext.
  """
  @spec open(sealed()) :: {:ok, binary()} | {:error, :authentication_failed}
  def open({nonce, ciphertext_with_tag})
      when is_binary(nonce) and byte_size(ciphertext_with_tag) >= @tag_size do
    ciphertext_size = byte_size(ciphertext_with_tag) - @tag_size

    <<ciphertext::binary-size(ciphertext_size), tag::binary-size(@tag_size)>> =
      ciphertext_with_tag

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key(), nonce, ciphertext, "", tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      _failed -> {:error, :authentication_failed}
    end
  end

  def open(_sealed), do: {:error, :authentication_failed}

  defp key do
    case Application.get_env(:ezagent_plugin_forgejo, :token_encryption_key) do
      nil ->
        @fallback_key

      # A configured `{:system, VAR}` whose VAR is unset is a misconfiguration,
      # not a licence to invent a key: falling back would encrypt real
      # credentials under a compile-time value that changes on the next build,
      # silently orphaning every stored secret. Only an ABSENT config key
      # (dev/test) gets the fallback.
      {:system, var} ->
        case System.get_env(var) do
          nil ->
            raise "#{var} is not set. :ezagent_plugin_forgejo is configured to read its " <>
                    "token encryption key from that variable; refusing to fall back to an " <>
                    "ephemeral key that would orphan every stored credential on restart."

          value ->
            decode_key(value)
        end

      value when is_binary(value) ->
        decode_key(value)
    end
  end

  defp decode_key(value) do
    case Base.decode64(value) do
      {:ok, key} when byte_size(key) == @key_size ->
        key

      _invalid ->
        raise "Invalid :ezagent_plugin_forgejo token_encryption_key: " <>
                "expected a base64-encoded #{@key_size}-byte key"
    end
  end
end
