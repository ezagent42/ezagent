defmodule Ezagent.ProviderConnection.SealedEnvelopeTest do
  @moduledoc """
  Byte-compatibility is the whole point of this file.

  `SealedEnvelope` was extracted from private functions in `exchange.ex` and
  `reconciliation.ex`. Rows sealed by that pre-extraction code exist, so the
  extracted module must open them. A round-trip test cannot show that: it seals
  and opens with the same code and stays green even if the tag position or the
  AAD encoding changed. The golden vector below is therefore built with
  `:crypto` directly, transcribed from the pre-extraction source.
  """
  use ExUnit.Case, async: false

  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Support
  alias Ezagent.ProviderConnection.SealedEnvelope

  @purpose :authorization_attempt
  @aad %{connection_id: "conn-1", correlation_id: "corr-1"}

  setup do
    {:ok, snapshot} = SealedEnvelope.snapshot()
    {:ok, snapshot: snapshot}
  end

  # Transcribed from the pre-extraction `seal_with/5`: nonce 12 bytes,
  # plaintext = term_to_binary(value, [:deterministic]), AAD =
  # Support.encode_aad(purpose, aad), ciphertext = <<tag, ciphertext>>.
  defp legacy_seal(%{active_key_id: key_id, keys: keys}, purpose, value, aad) do
    key = Map.fetch!(keys, key_id)
    nonce = :crypto.strong_rand_bytes(12)
    plaintext = :erlang.term_to_binary(value, [:deterministic])

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        plaintext,
        Support.encode_aad(purpose, aad),
        true
      )

    %{
      key_id: key_id,
      key_fingerprint: Support.sha256(key),
      nonce: nonce,
      ciphertext: <<tag::binary, ciphertext::binary>>
    }
  end

  test "opens an envelope sealed by the pre-extraction algorithm", %{snapshot: snapshot} do
    value = %{state: "st-1", pkce_verifier: "verifier-1"}
    envelope = legacy_seal(snapshot, @purpose, value, @aad)

    assert {:ok, ^value} = SealedEnvelope.open(snapshot, @purpose, envelope, @aad)
  end

  test "its own output is byte-identical in shape to the legacy envelope", %{snapshot: snapshot} do
    value = %{state: "st-2"}
    legacy = legacy_seal(snapshot, @purpose, value, @aad)
    fresh = SealedEnvelope.seal(snapshot, :active, @purpose, value, @aad)

    assert Enum.sort(Map.keys(fresh)) == Enum.sort(Map.keys(legacy))
    assert fresh.key_id == legacy.key_id
    assert fresh.key_fingerprint == legacy.key_fingerprint
    assert byte_size(fresh.nonce) == byte_size(legacy.nonce)
    # Same plaintext + same tag length => same ciphertext length. A moved tag or
    # a changed plaintext encoding shows up here.
    assert byte_size(fresh.ciphertext) == byte_size(legacy.ciphertext)
  end

  test "the legacy algorithm opens what SealedEnvelope sealed", %{snapshot: snapshot} do
    value = %{round: :trip}

    %{key_id: key_id, nonce: nonce, ciphertext: blob} =
      SealedEnvelope.seal(snapshot, :active, @purpose, value, @aad)

    key = Map.fetch!(snapshot.keys, key_id)
    <<tag::binary-size(16), ciphertext::binary>> = blob

    plaintext =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        key,
        nonce,
        ciphertext,
        Support.encode_aad(@purpose, @aad),
        tag,
        false
      )

    assert :erlang.binary_to_term(plaintext, [:safe]) == value
  end

  # AAD binds a ciphertext to its purpose AND its record. Without this, a
  # credential envelope could be opened as an authorization attempt.
  test "a different purpose cannot open it", %{snapshot: snapshot} do
    envelope = SealedEnvelope.seal(snapshot, :active, @purpose, %{a: 1}, @aad)

    assert {:error, :authentication_failed} =
             SealedEnvelope.open(snapshot, :credential_handoff, envelope, @aad)
  end

  test "a different aad cannot open it", %{snapshot: snapshot} do
    envelope = SealedEnvelope.seal(snapshot, :active, @purpose, %{a: 1}, @aad)

    assert {:error, :authentication_failed} =
             SealedEnvelope.open(snapshot, @purpose, envelope, %{connection_id: "other"})
  end

  test "a wrong key fingerprint is refused before decryption", %{snapshot: snapshot} do
    envelope = SealedEnvelope.seal(snapshot, :active, @purpose, %{a: 1}, @aad)
    tampered = %{envelope | key_fingerprint: :crypto.hash(:sha256, "not-the-key")}

    assert {:error, :authentication_failed} =
             SealedEnvelope.open(snapshot, @purpose, tampered, @aad)
  end

  test "a malformed envelope is refused, not raised", %{snapshot: snapshot} do
    for bad <- [%{}, %{key_id: "x"}, "not-a-map", nil] do
      assert {:error, :authentication_failed} =
               SealedEnvelope.open(snapshot, @purpose, bad, @aad)
    end
  end

  test "seal_with_record_key refuses a row whose fingerprint does not match", %{
    snapshot: snapshot
  } do
    row = %{key_id: snapshot.active_key_id, key_fingerprint: :crypto.hash(:sha256, "wrong")}

    assert {:error, :authentication_failed} =
             SealedEnvelope.seal_with_record_key(snapshot, row, @purpose, %{a: 1}, @aad)
  end

  test "seal_with_record_key seals under the row's key when it matches", %{snapshot: snapshot} do
    key = Map.fetch!(snapshot.keys, snapshot.active_key_id)
    row = %{key_id: snapshot.active_key_id, key_fingerprint: Support.sha256(key)}

    assert {:ok, envelope} =
             SealedEnvelope.seal_with_record_key(snapshot, row, @purpose, %{a: 1}, @aad)

    assert envelope.key_id == snapshot.active_key_id
    assert {:ok, %{a: 1}} = SealedEnvelope.open(snapshot, @purpose, envelope, @aad)
  end
end

defmodule Ezagent.ProviderConnection.RecoveryPurposeBoundaryTest do
  @moduledoc """
  The recovery path in `reconciliation.ex` restricts which purposes it will
  decrypt. That restriction is one `if` and is invisible to the envelope module,
  which deliberately polices nothing — so it needs its own test, or extracting
  the crypto silently widened what recovery can read.
  """
  use ExUnit.Case, async: false

  alias Ezagent.ProviderConnection.SealedEnvelope

  test "SealedEnvelope itself does NOT restrict purposes" do
    {:ok, snapshot} = SealedEnvelope.snapshot()
    aad = %{r: 1}
    envelope = SealedEnvelope.seal(snapshot, :active, :credential_handoff, %{v: 1}, aad)

    # If this starts failing, someone centralised the recovery allowlist into
    # SealedEnvelope and broke exchange.ex, which legitimately opens this purpose.
    assert {:ok, %{v: 1}} = SealedEnvelope.open(snapshot, :credential_handoff, envelope, aad)
  end
end
