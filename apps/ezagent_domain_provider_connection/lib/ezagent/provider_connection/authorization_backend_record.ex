defmodule Ezagent.ProviderConnection.AuthorizationBackendRecord do
  @moduledoc false
  @derive {Inspect,
           only: [
             :id,
             :workspace_uri,
             :execution_identity,
             :lifecycle_status,
             :shredded_at,
             :expires_at
           ]}
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "provider_authorization_backend_records" do
    field(:workspace_uri, :string)
    field(:backend_pair_id, :string)
    field(:authorization_ref, :string)
    field(:execution_identity, :string)
    field(:key_id, :string)
    field(:key_fingerprint, :binary)
    field(:nonce, :binary)
    field(:ciphertext, :binary)
    field(:bound_input_digest, :string)
    field(:begin_correlation_id, :string)
    field(:owner_uri, :string)
    field(:connection_id, :string)
    field(:connection_version, :integer)
    field(:provider_id, :string)
    field(:governed_host, :string)
    field(:acquisition_method, :string)
    field(:requested_permissions_digest, :string)
    field(:redirect_uri_id, :string)
    field(:handoff_ciphertext, :binary)
    field(:handoff_ref, :string)
    field(:consume_correlation_id, :string)
    field(:consume_input_digest, :string)
    field(:callback_key_id, :string)
    field(:callback_key_fingerprint, :binary)
    field(:callback_nonce, :binary)
    field(:callback_ciphertext, :binary)
    field(:lifecycle_status, :string)
    field(:shredded_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @trusted ~w(id workspace_uri backend_pair_id authorization_ref execution_identity key_id key_fingerprint nonce ciphertext bound_input_digest begin_correlation_id owner_uri connection_id connection_version provider_id governed_host acquisition_method requested_permissions_digest redirect_uri_id expires_at)a
  @doc false
  def create_changeset(attrs),
    do:
      %__MODULE__{}
      |> cast(attrs, [:lifecycle_status])
      |> change(Map.take(attrs, @trusted))
      |> validate_required(@trusted ++ [:lifecycle_status])
      |> unique_constraint(:authorization_ref,
        name: :provider_authorization_backend_records_authorization_ref_index
      )
      |> check_constraint(:lifecycle_status,
        name: :provider_authorization_backend_records_lifecycle_status_check
      )
      |> check_constraint(:lifecycle_status,
        name: :provider_authorization_backend_records_handoff_coherence_check
      )

  @doc false
  def prepare_handoff_finalization_changeset(
        %__MODULE__{
          lifecycle_status: "consumed",
          handoff_ref: handoff_ref,
          handoff_ciphertext: handoff_ciphertext,
          shredded_at: nil
        } = record
      )
      when is_binary(handoff_ref) and byte_size(handoff_ref) > 0 and
             is_binary(handoff_ciphertext) and byte_size(handoff_ciphertext) > 0 do
    change(record, lifecycle_status: "handoff_finalization_pending")
  end

  def prepare_handoff_finalization_changeset(%__MODULE__{} = record) do
    record
    |> change()
    |> add_error(:lifecycle_status, "is not a coherent consumed handoff")
  end

  @doc false
  def finalize_handoff_changeset(
        %__MODULE__{
          lifecycle_status: "handoff_finalization_pending",
          handoff_ref: handoff_ref,
          handoff_ciphertext: handoff_ciphertext,
          shredded_at: nil
        } = record,
        %DateTime{} = now
      )
      when is_binary(handoff_ref) and byte_size(handoff_ref) > 0 and
             is_binary(handoff_ciphertext) and byte_size(handoff_ciphertext) > 0 do
    change(record,
      handoff_ciphertext: nil,
      shredded_at: now,
      lifecycle_status: "shredded"
    )
  end

  def finalize_handoff_changeset(%__MODULE__{} = record, %DateTime{}) do
    record
    |> change()
    |> add_error(:lifecycle_status, "is not a coherent pending handoff")
  end
end
