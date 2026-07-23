defmodule EzagentPluginGithub.GitHubWebhookVerifier do
  @moduledoc """
  Verifies inbound GitHub webhook deliveries.

  GitHub signs each delivery with an HMAC-SHA256 of the **raw request body** keyed
  by the App's webhook secret, sent in the `X-Hub-Signature-256` header as
  `sha256=<lowercase-hex-digest>`.

  > The HMAC MUST be computed over the exact raw bytes GitHub sent. If a body
  > parser (`Plug.Parsers`) has already consumed and re-encoded the body, the
  > digest will not match. Callers must capture the raw body BEFORE any parser
  > runs (see `EzagentPluginGithub.GitHubWebhookPlug`).

  Comparison is constant-time (`Plug.Crypto.secure_compare/2`) to avoid leaking
  the expected signature through timing.
  """

  @doc """
  Verifies `signature_header` against the HMAC-SHA256 of `raw_body` under `secret`.

  Returns `:ok` on a match, `{:error, :missing_signature}` when the header is
  absent, or `{:error, :invalid_signature}` when it does not match.

  ## Examples

      iex> secret = "s3cr3t"
      iex> body = ~s({"zen":"Keep it logically awesome."})
      iex> sig = "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower)
      iex> EzagentPluginGithub.GitHubWebhookVerifier.verify(body, sig, secret)
      :ok
  """
  @spec verify(binary(), String.t() | nil, binary()) ::
          :ok | {:error, :missing_signature | :invalid_signature}
  def verify(_raw_body, nil, _secret), do: {:error, :missing_signature}

  def verify(raw_body, signature_header, secret)
      when is_binary(raw_body) and is_binary(signature_header) and is_binary(secret) do
    expected =
      "sha256=" <> (:crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower))

    if Plug.Crypto.secure_compare(expected, signature_header) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end
end
