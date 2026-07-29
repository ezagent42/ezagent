defmodule EzagentPluginForgejo.ForgejoCredentialBackend do
  @moduledoc """
  `Ezagent.ProviderConnection.CredentialBackend` implementation for Forgejo PATs.

  Credentials live in a named ETS table, encrypted at rest with AES-256-GCM
  under a key from `:ezagent_plugin_forgejo, :token_encryption_key`. The table
  is owned by this module's supervised process.

  ## Why there is no refresh exchange

  A Forgejo personal access token does not refresh — there is no refresh-token
  flow to drive, so `begin_refresh_exchange/1` and `consume_refresh_exchange/1`
  answer `{:error, :backend_unavailable}`. That is the honest answer, not a
  gap: pretending to succeed would let a caller believe a rotation happened.

  ## Security posture (design §4.2)

  This backend preserves "the credential never leaves the plugin": the
  plaintext PAT exists only between `lease_for_operation/1` and the HTTP call
  in `EzagentPluginForgejo.ForgejoClient`. What it CANNOT preserve is GitHub's
  "least privilege + short lived" — a Forgejo PAT is account-scoped and
  long-lived, with no per-operation minting to sit behind. See design §4 for
  what that costs and §4.3 for the isolation unit that compensates.

  The AES-GCM helpers are private here rather than a public sibling module
  (as `EzagentPluginGithub.GitHubTokenStore` is): they are an implementation
  detail of storage, covered through this module's round-trip and
  no-plaintext-at-rest tests. If a third provider plugin needs the same
  primitives, promoting them to shared domain code beats a third copy.
  """

  @behaviour Ezagent.ProviderConnection.CredentialBackend

  @table_name :forgejo_credential_tokens
  @key_size 32
  @nonce_size 12
  @tag_size 16

  # Only usable within a single VM session. Real deployments MUST configure a
  # stable key, or every restart orphans every stored credential.
  @fallback_key :crypto.strong_rand_bytes(@key_size)

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  @doc "Starts the credential backend process, which owns the ETS table."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    Agent.start_link(
      fn ->
        :ets.new(@table_name, [:set, :public, :named_table, read_concurrency: true])
        :ok
      end,
      name: name
    )
  end

  # ── Callbacks ──────────────────────────────────────────────────────────

  @impl true
  def store(%{credential_material: {:write_only_handoff, token}}) do
    ref = "forgejo-credential-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

    :ets.insert(@table_name, {ref, {encrypt(token), 1}})
    {:ok, %{credential_ref: ref, credential_version: 1}}
  end

  @impl true
  def replace(%{
        credential_ref: ref,
        expected_credential_version: expected_version,
        credential_material: {:write_only_handoff, new_token}
      }) do
    case :ets.lookup(@table_name, ref) do
      [{^ref, {_encrypted, version}}] when is_integer(version) and version == expected_version ->
        new_version = version + 1
        :ets.insert(@table_name, {ref, {encrypt(new_token), new_version}})
        {:ok, %{credential_ref: ref, credential_version: new_version}}

      [{^ref, {_encrypted, _version}}] ->
        {:error, :stale_version}

      [] ->
        {:error, :credential_conflict}
    end
  end

  @impl true
  def status(%{credential_ref: ref}) do
    case :ets.lookup(@table_name, ref) do
      [{^ref, {_encrypted, version}}] ->
        {:ok, %{credential_ref: ref, credential_version: version}}

      [] ->
        {:error, :credential_conflict}
    end
  end

  @impl true
  def lease_for_operation(%{credential_ref: ref}) do
    case :ets.lookup(@table_name, ref) do
      [{^ref, {sealed, _version}}] ->
        case decrypt(sealed) do
          {:ok, token} -> {:ok, %{credential: token, credential_ref: ref, expires_at: nil}}
          {:error, reason} -> {:error, reason}
        end

      [] ->
        {:error, :credential_conflict}
    end
  end

  @impl true
  def consume_lease(_command), do: :ok

  @impl true
  def begin_refresh_exchange(_command), do: {:error, :backend_unavailable}

  @impl true
  def consume_refresh_exchange(_command), do: {:error, :backend_unavailable}

  # Deleting an absent key is already a no-op in ETS, so an exact retry of the
  # same `idempotency_key` applies the same single logical effect.
  @impl true
  def revoke(%{credential_ref: ref}) do
    :ets.delete(@table_name, ref)
    :ok
  end

  # ── Encryption at rest ─────────────────────────────────────────────────

  defp encrypt(plaintext) do
    key = encryption_key()
    nonce = :crypto.strong_rand_bytes(@nonce_size)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, "", true)

    {nonce, ciphertext <> tag}
  end

  defp decrypt({nonce, ciphertext_with_tag}) do
    ciphertext_size = byte_size(ciphertext_with_tag) - @tag_size

    <<ciphertext::binary-size(ciphertext_size), tag::binary-size(@tag_size)>> =
      ciphertext_with_tag

    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           encryption_key(),
           nonce,
           ciphertext,
           "",
           tag,
           false
         ) do
      plaintext when is_binary(plaintext) -> {:ok, plaintext}
      _ -> {:error, :authentication_failed}
    end
  end

  defp encryption_key do
    case Application.get_env(:ezagent_plugin_forgejo, :token_encryption_key) do
      nil ->
        @fallback_key

      {:system, var} ->
        var |> System.get_env() |> decode_key()

      value when is_binary(value) ->
        decode_key(value)
    end
  end

  defp decode_key(nil), do: @fallback_key

  defp decode_key(value) do
    case Base.decode64(value) do
      {:ok, key} when byte_size(key) == @key_size ->
        key

      _ ->
        raise "Invalid :ezagent_plugin_forgejo token_encryption_key: expected a base64-encoded 32-byte key"
    end
  end
end
