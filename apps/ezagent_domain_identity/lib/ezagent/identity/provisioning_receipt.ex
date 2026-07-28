defmodule Ezagent.Identity.ProvisioningReceipt do
  @moduledoc """
  #189 PR-1 — the authenticated provisioning RECEIPT (addendum §2/§3),
  hardened per codex review F3.

  "Genuine create" of an identity-caps store row is proven by an
  authenticated receipt, not by marker absence (absence only proves "this
  spawn won the race", not "authorized to create identity"). A receipt is
  minted in-VM by the provisioning operation and HMAC-signed with the
  provisioning secret (see `secret!/0` resolution below), so an external
  caller cannot forge one.

  The receipt binds — and the signature covers ALL of:

    * `subject_uri` — the entity URI being (re-)provisioned;
    * `actor_uri` — the operator performing the op (the store verifies the
      caller-supplied authenticated actor matches AND is an authorized
      admin via `Ezagent.Identity.AdminAuthority.admin?/1`);
    * `transition` — `:provision` (genuine create) or `:reprovision` (the
      only way out of `revoked_unprovisioned` / `tombstoned`);
    * `caps_digest` — SHA-256 of the canonical encoding of the EXACT cap
      set being activated, so one receipt cannot provision arbitrary caps
      supplied separately;
    * `issued_at` + `nonce` — freshness (TTL, default 5 minutes) and
      SINGLE-USE (the nonce is consumed durably in
      `provisioning_receipt_nonces` inside the provisioning transaction —
      a replay is rejected).

  ## Secret resolution (codex F4 — lazy, never boot-mandatory)

  The HMAC secret is resolved at RECEIPT USE time (issue/verify), not at
  boot: `config :ezagent_domain_identity, :provisioning_receipt_secret`,
  then the `EZAGENT_PROVISIONING_RECEIPT_SECRET` env var. Missing/weak
  (`< 32` bytes) secrets raise ONLY when a receipt is actually minted or
  verified — PR-1 has no production provisioning path, so PR-1 introduces
  NO new required boot variable.
  """

  alias EzagentCore.Repo

  @enforce_keys [
    :subject_uri,
    :actor_uri,
    :transition,
    :caps_digest,
    :issued_at,
    :nonce,
    :signature
  ]
  defstruct [:subject_uri, :actor_uri, :transition, :caps_digest, :issued_at, :nonce, :signature]

  @type t :: %__MODULE__{
          subject_uri: String.t(),
          actor_uri: String.t(),
          transition: :provision | :reprovision,
          caps_digest: binary(),
          issued_at: DateTime.t(),
          nonce: String.t(),
          signature: binary()
        }

  @transitions [:provision, :reprovision]

  @default_ttl_ms 300_000
  # Small negative tolerance for clock skew between issuer and verifier.
  @clock_skew_ms 5_000

  @doc """
  Mint a signed receipt for `subject_uri` by `actor_uri` performing
  `transition` (`:provision` | `:reprovision`) on EXACTLY the cap set
  `caps` (digest-bound — provisioning any other set with this receipt
  fails verification).
  """
  @spec issue(
          URI.t() | String.t(),
          URI.t() | String.t(),
          :provision | :reprovision,
          [Ezagent.Capability.t()] | MapSet.t(Ezagent.Capability.t()),
          keyword()
        ) :: t()
  def issue(subject_uri, actor_uri, transition, caps, opts \\ [])
      when transition in @transitions and (is_list(caps) or is_struct(caps, MapSet)) do
    receipt = %__MODULE__{
      subject_uri: uri_string(subject_uri),
      actor_uri: uri_string(actor_uri),
      transition: transition,
      caps_digest: caps_digest(caps),
      issued_at:
        Keyword.get(opts, :issued_at, DateTime.utc_now() |> DateTime.truncate(:microsecond)),
      nonce: Keyword.get(opts, :nonce, generate_nonce()),
      signature: nil
    }

    %{receipt | signature: sign(receipt)}
  end

  @doc """
  SHA-256 of the canonical cap-set encoding (sorted `Capability.to_map/1`
  JSON) — the digest bound into every receipt.
  """
  @spec caps_digest([Ezagent.Capability.t()] | MapSet.t(Ezagent.Capability.t())) :: binary()
  def caps_digest(caps) when is_list(caps) or is_struct(caps, MapSet) do
    canonical =
      caps
      |> Enum.map(&Ezagent.Capability.to_map/1)
      |> Enum.sort()
      |> Jason.encode!()

    :crypto.hash(:sha256, canonical)
  end

  @doc "Whether the receipt carries a valid signature (HMAC, constant-time)."
  @spec verify(t()) :: boolean()
  def verify(%__MODULE__{signature: signature} = receipt) when is_binary(signature) do
    :crypto.hash_equals(signature, sign(receipt))
  end

  def verify(_receipt), do: false

  @doc """
  Whether the receipt is fresh: `issued_at` lies within the TTL
  (`:provisioning_receipt_ttl_ms`, default #{@default_ttl_ms}ms; small
  negative tolerance for clock skew).
  """
  @spec fresh?(t()) :: boolean()
  def fresh?(%__MODULE__{issued_at: issued_at}) do
    age_ms = DateTime.diff(DateTime.utc_now(), issued_at, :millisecond)
    age_ms >= -@clock_skew_ms and age_ms <= ttl_ms()
  end

  @doc """
  Whether the receipt is valid FOR `uri` undergoing `transition` activating
  EXACTLY `caps`: signature verifies, subject + transition + cap-set digest
  match, and the receipt is fresh. (Single-use consumption happens
  separately, inside the provisioning transaction — see `consume/1`.)
  """
  @spec valid_for?(
          t(),
          URI.t() | String.t(),
          :provision | :reprovision,
          [Ezagent.Capability.t()] | MapSet.t(Ezagent.Capability.t())
        ) :: boolean()
  def valid_for?(%__MODULE__{} = receipt, uri, transition, caps)
      when transition in @transitions do
    receipt.transition == transition and
      receipt.subject_uri == uri_string(uri) and
      fresh?(receipt) and
      :crypto.hash_equals(receipt.caps_digest, caps_digest(caps)) and
      verify(receipt)
  end

  def valid_for?(_receipt, _uri, _transition, _caps), do: false

  @doc """
  Consume the receipt's nonce (SINGLE-USE), durably, in the caller's
  transaction: the first consumer wins; a replay returns
  `{:error, :receipt_already_used}`. The insert is atomic
  (`ON CONFLICT DO NOTHING` on the nonce PK), so concurrent replays cannot
  both pass.
  """
  @spec consume(t()) :: :ok | {:error, :receipt_already_used}
  def consume(%__MODULE__{nonce: nonce}) do
    consumed_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.insert_all(
           "provisioning_receipt_nonces",
           [%{nonce: nonce, consumed_at: consumed_at}],
           on_conflict: :nothing,
           conflict_target: :nonce
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :receipt_already_used}
    end
  end

  @doc "Serialize for the `identity_caps.provisioning_receipt` text column."
  @spec to_json(t()) :: binary()
  def to_json(%__MODULE__{} = receipt) do
    Jason.encode!(%{
      "subject_uri" => receipt.subject_uri,
      "actor_uri" => receipt.actor_uri,
      "transition" => Atom.to_string(receipt.transition),
      "caps_digest" => Base.url_encode64(receipt.caps_digest, padding: false),
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
         {:ok, caps_digest} <- decode_b64(decoded["caps_digest"]),
         {:ok, signature} <- decode_b64(decoded["signature"]),
         true <-
           is_binary(decoded["subject_uri"]) and is_binary(decoded["actor_uri"]) and
             is_binary(decoded["nonce"]) do
      {:ok,
       %__MODULE__{
         subject_uri: decoded["subject_uri"],
         actor_uri: decoded["actor_uri"],
         transition: transition,
         caps_digest: caps_digest,
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

  defp decode_b64(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, raw} -> {:ok, raw}
      :error -> :error
    end
  end

  defp decode_b64(_other), do: :error

  # The signed payload is the canonical pipe-joined binding tuple; URIs,
  # ISO timestamps, and url-safe base64 cannot contain "|" so the encoding
  # is unambiguous.
  defp sign(%__MODULE__{} = receipt) do
    payload =
      [
        receipt.subject_uri,
        receipt.actor_uri,
        Atom.to_string(receipt.transition),
        Base.url_encode64(receipt.caps_digest, padding: false),
        DateTime.to_iso8601(receipt.issued_at),
        receipt.nonce
      ]
      |> Enum.join("|")

    :crypto.mac(:hmac, :sha256, secret!(), payload)
  end

  # F3(d)/F4: resolved LAZILY at receipt use (never a boot-mandatory var);
  # blank/short secrets are rejected — `""` is truthy, so check explicitly.
  defp secret! do
    candidate =
      Application.get_env(:ezagent_domain_identity, :provisioning_receipt_secret) ||
        System.get_env("EZAGENT_PROVISIONING_RECEIPT_SECRET")

    if is_binary(candidate) and byte_size(candidate) >= 32 do
      candidate
    else
      raise """
      provisioning receipt secret missing or weak (need >= 32 bytes) —
      set EZAGENT_PROVISIONING_RECEIPT_SECRET or
      config :ezagent_domain_identity, :provisioning_receipt_secret
      """
    end
  end

  defp ttl_ms,
    do:
      Application.get_env(:ezagent_domain_identity, :provisioning_receipt_ttl_ms, @default_ttl_ms)

  defp generate_nonce, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

  defp uri_string(%URI{} = uri), do: uri |> Ezagent.URI.instance() |> URI.to_string()

  defp uri_string(uri) when is_binary(uri),
    do: uri |> Ezagent.URI.new!() |> Ezagent.URI.instance() |> URI.to_string()
end
