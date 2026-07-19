defmodule Ezagent.ProviderConnection.ProviderAuthorizationCommand do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "provider_authorization_commands" do
    field(:workspace_uri, :string)
    field(:backend_pair_id, :string)
    field(:operation_class, :string)
    field(:correlation_id, :string)
    field(:bound_input_digest, :string)
    field(:authorization_ref, :string)
    field(:status, :string)
    field(:safe_result, :map)
    field(:safe_error_code, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(id workspace_uri backend_pair_id operation_class correlation_id bound_input_digest status)a
  @trusted @required ++ [:authorization_ref, :safe_result, :safe_error_code]

  @doc false
  def create_changeset(attrs) do
    %__MODULE__{}
    |> change(Map.take(attrs, @trusted))
    |> validate_required(@required)
    |> unique_constraint(:correlation_id, name: :provider_authorization_commands_command_index)
    |> check_constraint(:operation_class,
      name: :provider_authorization_commands_operation_class_check
    )
    |> check_constraint(:status, name: :provider_authorization_commands_status_check)
  end
end
