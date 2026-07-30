defmodule Ezagent.ProviderConnection.SealedEnvelope do
  @moduledoc """
  The single at-rest sealing implementation for this domain and its provider
  plugins: AES-256-GCM under a keyed, rotatable envelope.

      %{key_id: String.t(), key_fingerprint: binary(), nonce: binary(), ciphertext: binary()}

  Extracted verbatim from private functions that existed in TWO full parallel
  copies inside `LocalAuthorizationBackend` (`exchange.ex` and
  `reconciliation.ex` each carried snapshot loading, fingerprinting, seal and
  unseal). The algorithm is unchanged — rows sealed before the extraction must
  still open, which `sealed_envelope_test.exs` proves with a golden vector built
  from `:crypto` directly rather than by round-tripping this module against
  itself.

  ## Rotation is real

  A snapshot carries EVERY configured key plus which one is active. New rows
  seal under `:active`; existing rows open under the `key_id` they recorded. So
  rotation is "add a key, make it active" and old ciphertext keeps opening — it
  does not orphan anything.

  ## `purpose` is what keeps uses apart

  `purpose` and a record-specific `aad` are bound into the GCM additional data.
  A ciphertext sealed for one purpose cannot be opened as another, and cannot be
  moved between records. Purposes are not registered anywhere: they are atoms
  chosen by the caller. Existing ones are `:authorization_attempt`,
  `:authorization_callback` and `:credential_handoff`.

  **This module does not police which purposes a caller may open.** The recovery
  path in `reconciliation.ex` deliberately restricts itself to the two
  authorization purposes; that restriction is a property of that path, so it
  stays at that call site rather than being centralised here where it would
  either leak to callers that must not have it or be silently dropped.

  ## The keyring name is historical

  Keys come from `Application.get_env(:ezagent_domain_provider_connection,
  AuthorizationKeyRing)` and are cross-checked against
  `AuthorizationKeyRing.validated_fingerprint/0`. That name predates this module
  serving anything other than authorization records; it is shared, and it is not
  renamed here because the env var (`EZAGENT_PROVIDER_AUTH_ACTIVE_KEY_ID`) is
  deployment-visible and renaming it buys no behaviour.
  """

  alias Ezagent.ProviderConnection.AuthorizationKeyRing
  alias Ezagent.ProviderConnection.LocalAuthorizationBackend.Support

  @tag_bytes 16
  @nonce_bytes 12
  @key_bytes 32
  @key_id_pattern ~r/\A[a-zA-Z0-9._-]{1,64}\z/

  @fixture_enabled Application.compile_env(
                     :ezagent_domain_provider_connection,
                     :authorization_key_ring_fixture_enabled,
                     false
                   )

  @type snapshot :: %{active_key_id: String.t(), keys: %{String.t() => binary()}}
  @type envelope :: %{
          key_id: String.t(),
          key_fingerprint: binary(),
          nonce: binary(),
          ciphertext: binary()
        }

  @doc """
  Loads and validates the key snapshot.

  Fails closed as `:authorization_backend_unavailable` on any malformed
  configuration, and only succeeds after the computed fingerprint matches the
  singleton's validated one — so a process reading a config that drifted from
  what the keyring validated at boot cannot seal or open anything.
  """
  @spec snapshot() :: {:ok, snapshot()} | {:error, :authorization_backend_unavailable}
  def snapshot do
    with {:ok, state} <- parse_config(),
         {:ok, validated} <- AuthorizationKeyRing.validated_fingerprint(),
         true <- fingerprint(state) == validated do
      {:ok, state}
    else
      _error -> {:error, :authorization_backend_unavailable}
    end
  end

  @doc "Seals a term under the active key, or under an explicitly named key."
  @spec seal(snapshot(), :active | String.t(), atom(), term(), term()) :: envelope()
  def seal(%{active_key_id: active} = snapshot, :active, purpose, value, aad),
    do: seal(snapshot, active, purpose, value, aad)

  def seal(%{keys: keys}, key_id, purpose, value, aad) when is_binary(key_id) do
    key = Map.fetch!(keys, key_id)
    nonce = :crypto.strong_rand_bytes(@nonce_bytes)
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

  @doc """
  Re-seals under the key an existing row already used.

  Used when a record must keep its key across an update instead of migrating to
  whatever is active now. Refuses if the row's recorded fingerprint does not
  match the key that id resolves to — that mismatch means the configuration
  changed under a live row, and sealing anyway would produce a row nothing can
  open.
  """
  @spec seal_with_record_key(
          snapshot(),
          %{key_id: String.t(), key_fingerprint: binary()},
          atom(),
          term(),
          term()
        ) :: {:ok, envelope()} | {:error, :authentication_failed}
  def seal_with_record_key(
        %{keys: keys} = snapshot,
        %{key_id: key_id, key_fingerprint: fingerprint},
        purpose,
        value,
        aad
      ) do
    with {:ok, key} <- Map.fetch(keys, key_id),
         true <- Support.sha256(key) == fingerprint do
      {:ok, seal(snapshot, key_id, purpose, value, aad)}
    else
      _error -> {:error, :authentication_failed}
    end
  end

  def seal_with_record_key(_snapshot, _row, _purpose, _value, _aad),
    do: {:error, :authentication_failed}

  @doc """
  Opens an envelope, requiring the recorded fingerprint AND the GCM tag to verify.

  Every failure — unknown key id, fingerprint mismatch, wrong purpose, wrong
  aad, tampered ciphertext, malformed shape — is the same
  `:authentication_failed`. Callers must not be able to tell which, and this
  never raises: a malformed row is a closed error, not a crash in whatever
  process happened to read it.
  """
  @spec open(snapshot(), atom(), term(), term()) ::
          {:ok, term()} | {:error, :authentication_failed}
  def open(
        %{keys: keys},
        purpose,
        %{key_id: key_id, key_fingerprint: fingerprint, nonce: nonce, ciphertext: blob},
        aad
      )
      when is_binary(key_id) and is_binary(fingerprint) and is_binary(nonce) and
             byte_size(nonce) == @nonce_bytes and is_binary(blob) and
             byte_size(blob) >= @tag_bytes do
    with {:ok, key} <- Map.fetch(keys, key_id),
         true <- Support.sha256(key) == fingerprint do
      <<tag::binary-size(@tag_bytes), ciphertext::binary>> = blob

      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             Support.encode_aad(purpose, aad),
             tag,
             false
           ) do
        :error -> {:error, :authentication_failed}
        plaintext -> {:ok, :erlang.binary_to_term(plaintext, [:safe])}
      end
    else
      _error -> {:error, :authentication_failed}
    end
  rescue
    _error -> {:error, :authentication_failed}
  end

  def open(_snapshot, _purpose, _envelope, _aad), do: {:error, :authentication_failed}

  # ── config ───────────────────────────────────────────────────────────

  defp parse_config do
    config = Application.get_env(:ezagent_domain_provider_connection, AuthorizationKeyRing, [])

    with {:ok, pairs} <- key_pairs(Keyword.get(config, :source), config),
         {:ok, keys} <- validate_keys(pairs),
         active when is_binary(active) <- Keyword.get(config, :active_key_id),
         true <- Regex.match?(@key_id_pattern, active),
         true <- Map.has_key?(keys, active) do
      {:ok, %{active_key_id: active, keys: keys}}
    else
      _error -> {:error, :authorization_backend_unavailable}
    end
  end

  if @fixture_enabled do
    defp key_pairs(:explicit_test, config) do
      case Keyword.get(config, :keys) do
        keys when is_map(keys) -> {:ok, Map.to_list(keys)}
        _other -> {:error, :invalid}
      end
    end
  end

  defp key_pairs(:runtime_env, config) do
    with json when is_binary(json) <- Keyword.get(config, :keys_json),
         {:ok, %Jason.OrderedObject{values: pairs}} <-
           Jason.decode(json, objects: :ordered_objects) do
      Enum.reduce_while(pairs, {:ok, []}, fn {id, encoded}, {:ok, acc} ->
        case is_binary(encoded) && Base.decode64(encoded) do
          {:ok, key} -> {:cont, {:ok, [{id, key} | acc]}}
          _other -> {:halt, {:error, :invalid}}
        end
      end)
    else
      _error -> {:error, :invalid}
    end
  end

  defp key_pairs(_source, _config), do: {:error, :invalid}

  defp validate_keys(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {id, key}, {:ok, acc} ->
      if is_binary(id) and Regex.match?(@key_id_pattern, id) and is_binary(key) and
           byte_size(key) == @key_bytes and not Map.has_key?(acc, id) do
        {:cont, {:ok, Map.put(acc, id, key)}}
      else
        {:halt, {:error, :invalid}}
      end
    end)
  end

  defp fingerprint(%{active_key_id: active, keys: keys}) do
    key_digests = Map.new(keys, fn {id, key} -> {id, Support.sha256(key)} end)
    Support.sha256(:erlang.term_to_binary({active, key_digests}, [:deterministic]))
  end
end
