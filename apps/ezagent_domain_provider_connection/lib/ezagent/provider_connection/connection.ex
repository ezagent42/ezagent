defmodule Ezagent.ProviderConnection.Connection do
  @moduledoc "Durable provider connection identity."
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:connection_id, Ecto.UUID, autogenerate: false}
  schema "provider_connections" do
    field(:workspace_uri, :string)
    field(:owner_uri, :string)
    field(:provider_id, :string)
    field(:governed_host, :string)
    field(:external_account_id, :string)
    field(:display_login, :string)
    field(:execution_identity, :string)
    field(:acquisition_method, :string)
    field(:authorization_backend_ref, :string)
    field(:credential_backend_ref, :string)
    field(:authorization_version, :integer, default: 0)
    field(:credential_version, :integer, default: 0)
    field(:connection_version, :integer, default: 0)
    field(:status, :string)
    field(:permission_digest, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:last_error_code, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @trusted ~w(connection_id workspace_uri owner_uri authorization_backend_ref credential_backend_ref)a
  @user ~w(provider_id governed_host external_account_id display_login execution_identity acquisition_method status permission_digest expires_at last_error_code)a
  def create_changeset(attrs) do
    trusted = Map.take(attrs, @trusted)

    %__MODULE__{}
    |> cast(attrs, @user)
    |> change(trusted)
    |> validate_required(
      @trusted ++
        ~w(provider_id governed_host external_account_id execution_identity acquisition_method status)a
    )
    |> unique_constraint(:connection_id, name: :provider_connections_pkey)
    |> unique_constraint(:external_account_id, name: :provider_connections_active_binding_index)
    |> check_constraint(:status, name: :provider_connections_status_check)
    |> check_constraint(:last_error_code, name: :provider_connections_last_error_code_check)
  end
end
