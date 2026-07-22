defmodule Ezagent.DomainGit.D0BackendReuseGate.RemoteSeal do
  @moduledoc false

  @seal_key :crypto.hash(:sha256, "ezagent-d0-remote-shaped-fake")

  def seal(value) when is_binary(value) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, @seal_key, iv, value, <<>>, true)

    Base.url_encode64(iv <> tag <> ciphertext, padding: false)
  end

  def unseal(sealed) do
    with {:ok, raw} <- Base.url_decode64(sealed, padding: false),
         <<iv::binary-size(12), tag::binary-size(16), ciphertext::binary>> <- raw,
         value when is_binary(value) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             @seal_key,
             iv,
             ciphertext,
             <<>>,
             tag,
             false
           ) do
      {:ok, value}
    else
      _ -> {:error, :provider_response_invalid}
    end
  end
end
