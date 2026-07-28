defmodule Ezagent.Identity.ProvisioningReceipt do
  @moduledoc """
  #189 PR-1 — the authenticated provisioning RECEIPT (addendum §2/§3).

  "Genuine create" of an identity-caps store row is proven by an
  authenticated receipt, not by marker absence (absence only proves "this
  spawn won the race", not "authorized to create identity"). A receipt is
  minted in-VM by the provisioning operation and HMAC-signed with the
  node-local provisioning secret (`:ezagent_domain_identity,
  :provisioning_receipt_secret`), so an external caller cannot forge one.

  The receipt binds:

    * `subject_uri` — the entity URI being (re-)provisioned;
    * `actor_uri` — the authenticated operator/principal performing the op;
    * `transition` — `:provision` (genuine create) or `:reprovision` (the
      only way out of `revoked_unprovisioned` / `tombstoned`);
    * `issued_at` + `nonce` — uniqueness / audit.

  PR-1 is additive: `Ezagent.EntityCaps.Store.provision/3` and
  `reprovision/3` require a valid receipt, but no runtime path calls them
  yet (the atomic cutover wires the genuine-provision seam).
  """

  @enforce_keys [:subject_uri, :actor_uri, :transition, :issued_at, :nonce, :signature]
  defstruct [:subject_uri, :actor_uri, :transition, :issued_at, :nonce, :signature]

  @type t :: %__MODULE__{
          subject_uri: String.t(),
          actor_uri: String.t(),
          transition: :provision | :reprovision,
          issued_at: DateTime.t(),
          nonce: String.t(),
          signature: binary()
        }

  @transitions [:provision, :reprovision]

  @doc """
  Mint a signed receipt for `subject_uri` by `actor_uri` performing
  `transition` (`:provision` | `:reprovision`).
  """
  @spec issue(URI.t() | String.t(), URI.t() | String.t(), :provision | :reprovision, keyword()) ::
          t()
  def issue(subject_uri, actor_uri, transition, opts \\ [])
      when transition in @transitions do
    receipt = %__MODULE__{
      subject_uri: uri_key(subject_uri),
      actor_uri: uri_key(actor_uri),
      transition: transition,
      issued_at: Keyword.get(opts, :issued_at, DateTime.utc_now() |> DateTime.truncate(:microsecond)),
      nonce: Keyword.get(opts, :nonce, generate_nonce()),
      signature: nil
    }

    %{receipt | signature: sign(receipt)}
  end

  @doc "Whether the receipt carries a valid signature (HMAC, constant-time)."
  @spec verify(t()) :: boolean()
  def verify(%__MODULE__{signature: signature} = receipt) when is_binary(signature) do
    :crypto.hash_equals(signature, sign(receipt))
  end

  def verify(_receipt), do: false

  @doc """
  Whether the receipt is valid FOR `uri` undergoing `transition`: signature
  verifies, subject matches, and the transition matches.
  """
  @spec valid_for?(t(), URI.t() | String.t(), :provision | :reprovision) :: boolean()
  def valid_for?(%__MODULE__{} = receipt, uri, transition) when transition in @transitions do
    receipt.transition == transition and
      receipt.subject_uri == uri_key(uri) and
      verify(receipt)
  end

  def valid_for?(_receipt, _uri, _transition), do: false

  @doc "Serialize for the `identity_caps.provisioning_receipt` text column."
  @spec to_json(t()) :: binary()
  def to_json(%__MODULE__{} = receipt) do
    Jason.encode!(%{
      "subject_uri" => receipt.subject_uri,
      "actor_uri" => receipt.actor_uri,
      "transition" => Atom.to_string(receipt.transition),
      "issued_at" => DateTime.to_iso8601(receipt.issued_at),
      "nonce" => receipt.nonce,
      "signature" => Base.url_encode64(receipt.signature, padding: false)
    })
  end

  @doc "Inverse of `to_json/1`; `{:error, :invalid_receipt}` on any malformed input."
  @spec from_json(binary() | nil) :: {:ok, t()} | {:error, :invalid_receipt}
  def from_json(nil), do: {:error, :invalid_receipt}

  def from_json(json) when is_binary(json) do
    with {:ok, decoded} when is_map(decoded) <- Jason.decode(json),
         {:ok, transition} <- transition_from(decoded["transition"]),
         {:ok, issued_at, _} <- DateTime.from_iso8601(decoded["issued_at"] || ""),
         {:ok, signature} <- decode_signature(decoded["signature"]),
         true <- is_binary(decoded["subject_uri"]) and is_binary(decoded["actor_uri"]) and
           is_binary(decoded["nonce"]) do
      {:ok,
       %__MODULE__{
         subject_uri: decoded["subject_uri"],
         actor_uri: decoded["actor_uri"],
         transition: transition,
         issued_at: issued_at,
         nonce: decoded["nonce"],
         signature: signature
       }}
    else
      _ -> {:error, :invalid_receipt}
    end
  end

  def from_json(_other), do: {:error, :invalid_receipt}

  defp transition_from("provision"), do: {:ok, :provision}
  defp transition_from("reprovision"), do: {:ok, :reprovision}
  defp transition_from(_other), do: :error

  defp decode_signature(signature) when is_binary(signature) do
    case Base.url_decode64(signature, padding: false) do
      {:ok, raw} -> {:ok, raw}
      :error -> :error
    end
  end

  defp decode_signature(_other), do: :error

  # The signed payload is the canonical pipe-joined binding tuple; URIs and
  # ISO timestamps cannot contain "|" so the encoding is unambiguous.
  defp sign(%__MODULE__{} = receipt) do
    payload =
      [
        receipt.subject_uri,
        receipt.actor_uri,
        Atom.to_string(receipt.transition),
        DateTime.to_iso8601(receipt.issued_at),
        receipt.nonce
      ]
      |> Enum.join("|")

    :crypto.mac(:hmac, :sha256, secret(), payload)
  end

  defp secret do
    Application.get_env(:ezagent_domain_identity, :provisioning_receipt_secret) ||
      raise """
      missing :ezagent_domain_identity, :provisioning_receipt_secret config —
      set EZAGENT_PROVISIONING_RECEIPT_SECRET (see config/config.exs)
      """
  end

  defp generate_nonce, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp uri_key(%URI{} = uri), do: uri |> Ezagent.URI.instance() |> URI.to_string()

  defp uri_key(uri) when is_binary(uri),
    do: uri |> Ezagent.URI.new!() |> Ezagent.URI.instance() |> URI.to_string()
end
