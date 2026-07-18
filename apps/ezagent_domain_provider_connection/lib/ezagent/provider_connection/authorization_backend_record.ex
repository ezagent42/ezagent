defmodule Ezagent.ProviderConnection.AuthorizationBackendRecord do
  @moduledoc false
  @derive {Inspect,
           only: [
             :id,
             :workspace_uri,
             :backend_pair_id,
             :authorization_ref,
             :consume_status,
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
    field(:key_id, :string)
    field(:nonce, :binary)
    field(:ciphertext, :binary)
    field(:bound_input_digest, :string)
    field(:handoff_ciphertext, :binary)
    field(:handoff_ref, :string)
    field(:consume_correlation_id, :string)
    field(:consume_status, :string)
    field(:shredded_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @trusted ~w(id workspace_uri backend_pair_id authorization_ref key_id nonce ciphertext bound_input_digest expires_at)a
  def create_changeset(attrs),
    do:
      %__MODULE__{}
      |> cast(attrs, [:consume_status])
      |> change(Map.take(attrs, @trusted))
      |> validate_required(@trusted ++ [:consume_status])
      |> unique_constraint(:authorization_ref,
        name: :provider_authorization_backend_records_committed_consume_index
      )
      |> check_constraint(:consume_status,
        name: :provider_authorization_backend_records_consume_status_check
      )
end
