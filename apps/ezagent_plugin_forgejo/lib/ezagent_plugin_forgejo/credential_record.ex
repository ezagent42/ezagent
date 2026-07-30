defmodule EzagentPluginForgejo.CredentialRecord do
  @moduledoc """
  Durable, sealed custody for one Forgejo OAuth credential.

  Sealed by `Ezagent.ProviderConnection.SealedEnvelope` — the same keyed,
  rotatable envelope the provider-connection domain uses for its own
  authorization records, rather than a third private AES implementation. The
  `credential_ref` is bound into the AAD, so a ciphertext cannot be moved to
  another row.

  ## Why durable at all

  This replaced an ETS table owned by one Agent. That table dies with its owner,
  so one crash wiped every user's credential on the node — including the refresh
  token, which made recovery a browser re-authorization per user per instance
  rather than a renewal. `provider_connections` meanwhile kept pointing at the
  vanished rows, so connections looked active and failed on lease.
  """

  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  alias Ezagent.ProviderConnection.SealedEnvelope
  alias EzagentCore.Repo

  @purpose :provider_credential

  @primary_key false
  schema "forgejo_credentials" do
    field(:credential_ref, :string, primary_key: true)
    field(:workspace_uri, :string)
    field(:credential_version, :integer)
    field(:key_id, :string)
    field(:key_fingerprint, :binary)
    field(:nonce, :binary)
    field(:ciphertext, :binary)

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Seals and stores a credential, returning the ref the domain will carry."
  @spec insert(String.t(), String.t()) ::
          {:ok, %{credential_ref: String.t(), credential_version: pos_integer()}}
          | {:error, atom()}
  def insert(workspace_uri, credential)
      when is_binary(workspace_uri) and is_binary(credential) do
    ref = "forgejo-credential-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    with {:ok, snapshot} <- SealedEnvelope.snapshot() do
      %{
        key_id: key_id,
        key_fingerprint: fingerprint,
        nonce: nonce,
        ciphertext: ciphertext
      } = SealedEnvelope.seal(snapshot, :active, @purpose, credential, aad(ref))

      now = DateTime.utc_now()

      Repo.insert!(%__MODULE__{
        credential_ref: ref,
        workspace_uri: workspace_uri,
        credential_version: 1,
        key_id: key_id,
        key_fingerprint: fingerprint,
        nonce: nonce,
        ciphertext: ciphertext,
        inserted_at: now,
        updated_at: now
      })

      {:ok, %{credential_ref: ref, credential_version: 1}}
    end
  end

  @doc """
  Opens the stored credential, scoped to the workspace that owns it.

  `workspace_uri` is REQUIRED and participates in the lookup. The table is
  registered as per-tenant, and that registration's contract is "a cross-tenant
  read is a miss rather than a leak" — a `workspace_uri` column no query
  consults would not deliver it. A ref belonging to another tenant reads as
  `:credential_conflict`, indistinguishable from an absent one.
  """
  @spec fetch_credential(String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def fetch_credential(workspace_uri, credential_ref)
      when is_binary(workspace_uri) and is_binary(credential_ref) do
    with {:ok, snapshot} <- SealedEnvelope.snapshot(),
         %__MODULE__{} = row <- scoped_row(workspace_uri, credential_ref) do
      SealedEnvelope.open(snapshot, @purpose, envelope_of(row), aad(credential_ref))
    else
      nil -> {:error, :credential_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the stored version, for the domain's expected-version checks.

  Deliberately NOT workspace-scoped: the domain calls `status/1` and
  `begin_refresh_exchange/1` with commands that carry no `workspace_uri`
  (`termination.ex:138`, `refresh.ex:449`), so there is no tenant to compare
  against. This returns an integer, never credential material, so an unscoped
  read discloses only whether a ref exists and at what version. The paths that
  DO return material (`fetch_credential/2`) and that mutate it (`replace/4`)
  are scoped.
  """
  @spec version(String.t()) :: {:ok, pos_integer()} | {:error, :credential_conflict}
  def version(credential_ref) when is_binary(credential_ref) do
    case Repo.get(__MODULE__, credential_ref) do
      %__MODULE__{credential_version: version} -> {:ok, version}
      nil -> {:error, :credential_conflict}
    end
  end

  @doc """
  Returns the workspace a credential belongs to.

  Used by the refresh path to capture the tenant at `begin_refresh_exchange/1`,
  because the domain's follow-up `replace/1` carries no `workspace_uri` and the
  rotation must land on the same tenant's row.
  """
  @spec workspace_of(String.t()) :: {:ok, String.t()} | {:error, :credential_conflict}
  def workspace_of(credential_ref) when is_binary(credential_ref) do
    case Repo.get(__MODULE__, credential_ref) do
      %__MODULE__{workspace_uri: workspace_uri} -> {:ok, workspace_uri}
      nil -> {:error, :credential_conflict}
    end
  end

  defp scoped_row(workspace_uri, credential_ref),
    do: Repo.get_by(__MODULE__, credential_ref: credential_ref, workspace_uri: workspace_uri)

  @doc """
  Re-seals a credential under a version CAS.

  The update is guarded by `credential_version` in the WHERE clause, so two
  concurrent replacements cannot both win: the loser sees zero rows updated and
  gets `:stale_version` rather than silently overwriting.
  """
  @spec replace(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, %{credential_ref: String.t(), credential_version: pos_integer()}}
          | {:error, atom()}
  def replace(workspace_uri, credential_ref, credential, expected_version)
      when is_binary(workspace_uri) and is_binary(credential_ref) and is_binary(credential) and
             is_integer(expected_version) do
    with {:ok, snapshot} <- SealedEnvelope.snapshot() do
      %{
        key_id: key_id,
        key_fingerprint: fingerprint,
        nonce: nonce,
        ciphertext: ciphertext
      } = SealedEnvelope.seal(snapshot, :active, @purpose, credential, aad(credential_ref))

      next = expected_version + 1

      {count, _returned} =
        Repo.update_all(
          # Keyword-syntax `where` on purpose: an `r in __MODULE__` binding would
          # make `r.credential_ref` a non-assertive access, which
          # `PluginWorkspaceLocalityContractTest` enumerates. Same CAS semantics —
          # both columns are still in the WHERE clause.
          from(__MODULE__,
            where: [
              credential_ref: ^credential_ref,
              workspace_uri: ^workspace_uri,
              credential_version: ^expected_version
            ]
          ),
          set: [
            credential_version: next,
            key_id: key_id,
            key_fingerprint: fingerprint,
            nonce: nonce,
            ciphertext: ciphertext,
            updated_at: DateTime.utc_now()
          ]
        )

      case count do
        1 -> {:ok, %{credential_ref: credential_ref, credential_version: next}}
        0 -> miss_reason(workspace_uri, credential_ref)
      end
    end
  end

  @doc "Removes a credential. Deleting an absent one is already the desired state."
  @spec delete(String.t()) :: :ok
  def delete(credential_ref) when is_binary(credential_ref) do
    Repo.delete_all(from(__MODULE__, where: [credential_ref: ^credential_ref]))
    :ok
  end

  # Zero rows updated means the ref is gone, belongs to another tenant, or the
  # version moved. The domain treats stale-version differently from absent, so
  # they must not collapse — but a cross-tenant ref must read as absent, which
  # is why this re-reads through the SCOPED lookup rather than by ref alone.
  defp miss_reason(workspace_uri, credential_ref) do
    case scoped_row(workspace_uri, credential_ref) do
      %__MODULE__{} -> {:error, :stale_version}
      nil -> {:error, :credential_conflict}
    end
  end

  defp envelope_of(%__MODULE__{
         key_id: key_id,
         key_fingerprint: fingerprint,
         nonce: nonce,
         ciphertext: ciphertext
       }),
       do: %{
         key_id: key_id,
         key_fingerprint: fingerprint,
         nonce: nonce,
         ciphertext: ciphertext
       }

  # The ref is bound into the additional data, so a ciphertext copied to another
  # row will not open.
  defp aad(credential_ref), do: %{credential_ref: credential_ref}
end
