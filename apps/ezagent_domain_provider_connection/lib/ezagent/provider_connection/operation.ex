defmodule Ezagent.ProviderConnection.Operation do
  @moduledoc "Durable idempotency and recovery operation."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "provider_connection_operations" do
    field(:workspace_uri, :string)
    field(:connection_id, Ecto.UUID)
    field(:backend_pair_id, :string)
    field(:operation_class, :string)
    field(:correlation_id, :string)
    field(:bound_input_digest, :string)
    field(:expected_connection_version, :integer)
    field(:expected_credential_version, :integer)
    field(:result_ref, :string)
    field(:status, :string)
    field(:lease_token, :string)
    field(:lease_until, :utc_datetime_usec)
    field(:safe_error_code, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @trusted_required ~w(workspace_uri connection_id backend_pair_id operation_class correlation_id bound_input_digest)a
  @trusted @trusted_required ++ [:safe_error_code]
  def create_changeset(attrs),
    do:
      %__MODULE__{}
      |> cast(attrs, [:status])
      |> change(Map.take(attrs, @trusted))
      |> validate_required(@trusted_required ++ [:status])
      |> unique_constraint(:correlation_id, name: :provider_connection_operations_command_index)
      |> check_constraint(:operation_class,
        name: :provider_connection_operations_operation_class_check
      )
      |> check_constraint(:status, name: :provider_connection_operations_status_check)
      |> check_constraint(:safe_error_code,
        name: :provider_connection_operations_safe_error_code_check
      )
end
