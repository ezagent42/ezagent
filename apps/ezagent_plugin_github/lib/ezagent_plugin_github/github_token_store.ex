defmodule EzagentPluginGithub.GitHubTokenStore do
  @moduledoc """
  AES-256-GCM encrypted token persistence for GitHub credentials.

  Provides `encrypt/2` and `decrypt/2` using Erlang's `:crypto.crypto_one_time_aead`
  with AES-256-GCM. Each encryption uses a fresh 12-byte random nonce. The tag
  is appended to the ciphertext for storage and split off before decryption.
  """

  @key_size 32
  @nonce_size 12
  @tag_size 16

  @doc """
  Encrypts `plaintext` using `key` (must be 32 bytes for AES-256).

  Returns `{nonce, ciphertext_with_tag}` where `nonce` is the 12-byte random
  nonce and `ciphertext_with_tag` is the ciphertext (same length as plaintext)
  concatenated with the 16-byte GCM authentication tag.
  """
  @spec encrypt(binary(), binary()) :: {binary(), binary()}
  def encrypt(plaintext, key) when is_binary(plaintext) and byte_size(key) == @key_size do
    nonce = :crypto.strong_rand_bytes(@nonce_size)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, "", true)

    {nonce, ciphertext <> tag}
  end

  @doc """
  Decrypts `{nonce, ciphertext_with_tag}` using `key` (must be 32 bytes).

  Splits the last 16 bytes off `ciphertext_with_tag` as the GCM authentication
  tag and verifies it during decryption.

  Returns `{:ok, plaintext}` on success, `{:error, :authentication_failed}` if
  the tag does not match (wrong key or tampered ciphertext).
  """
  @spec decrypt({binary(), binary()}, binary()) ::
          {:ok, binary()} | {:error, :authentication_failed}
  def decrypt({nonce, ciphertext_with_tag}, key) when byte_size(key) == @key_size do
    ciphertext_size = byte_size(ciphertext_with_tag) - @tag_size

    <<ciphertext::binary-size(ciphertext_size), tag::binary-size(@tag_size)>> =
      ciphertext_with_tag

    case :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, ciphertext, "", tag, false) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      {:error, :bad_tag} -> {:error, :authentication_failed}
      :error -> {:error, :authentication_failed}
    end
  end
end
