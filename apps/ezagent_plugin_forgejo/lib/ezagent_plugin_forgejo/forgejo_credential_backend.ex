defmodule EzagentPluginForgejo.ForgejoCredentialBackend do
  @moduledoc """
  `Ezagent.ProviderConnection.CredentialBackend` implementation for Forgejo PATs.

  Credentials live in a named ETS table, encrypted at rest with AES-256-GCM
  under a key from `:ezagent_plugin_forgejo, :token_encryption_key`. The table
  is owned by this module's supervised process.

  ## Refresh exchange is stubbed, pending slice F0

  `begin_refresh_exchange/1` and `consume_refresh_exchange/1` currently answer
  `{:error, :backend_unavailable}`. **That is a stub with a scheduled owner,
  not a statement about Forgejo.**

  A personal access token genuinely has nothing to refresh. But V1 authenticates
  with OAuth2, not a PAT (design §4.1, decided 2026-07-29), and Forgejo's OAuth2
  *does* issue refresh tokens — measured: `expires_in: 3600`, and
  `grant_type=refresh_token` returns a new access token **and a new refresh
  token** (rotation). So both callbacks become real in F0, and the stored
  credential gains a rotating refresh token beside the access token.

  Until then these answer unavailable rather than pretending to succeed: a
  caller that believed a rotation happened would keep using a token that
  expires in an hour.

  ## Security posture (design §4.2)

  This backend preserves "the credential never leaves the plugin": the
  plaintext token exists only between `lease_for_operation/1` and the HTTP call
  in `EzagentPluginForgejo.ForgejoClient`.

  With OAuth2 the credential is also genuinely **short-lived** (1h + rotation),
  which is parity with a GitHub installation token. What is still not available
  is GitHub's **per-repository** scoping: Forgejo's scope grammar is
  `<read|write>:<category>` with no repository selector. Note that last point is
  a structural inference from the grammar, **not** something measured — see
  design §4.1.1 for what would settle it.

  Sealing lives in `EzagentPluginForgejo.Sealed`. It began as private
  functions here, with a note that a second caller should trigger promotion
  rather than a copy; `EzagentPluginForgejo.OAuthApp` became that caller in
  slice F0, so it was promoted. This module's round-trip and
  no-plaintext-at-rest tests still cover the path.
  """

  @behaviour Ezagent.ProviderConnection.CredentialBackend

  alias EzagentPluginForgejo.Sealed

  @table_name :forgejo_credential_tokens

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

    :ets.insert(@table_name, {ref, {Sealed.seal(token), 1}})
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
        :ets.insert(@table_name, {ref, {Sealed.seal(new_token), new_version}})
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
        case Sealed.open(sealed) do
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
end
