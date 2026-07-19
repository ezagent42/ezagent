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
    field(:backend_pair_id, :string)
    field(:authorization_backend_id, :string)
    field(:credential_backend_id, :string)
    field(:authorization_version, :integer, default: 0)
    field(:credential_version, :integer, default: 0)
    field(:connection_version, :integer, default: 0)
    field(:status, :string)
    field(:permission_digest, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:last_error_code, :string)
    field(:refresh_lease_token, :string)
    field(:refresh_lease_until, :utc_datetime_usec)
    field(:refresh_lease_version, :integer, default: 0)
    timestamps(type: :utc_datetime_usec)
  end

  @trusted_required ~w(connection_id workspace_uri owner_uri authorization_backend_ref credential_backend_ref)a
  @trusted @trusted_required ++
             ~w(backend_pair_id authorization_backend_id credential_backend_id)a
  @user ~w(provider_id governed_host external_account_id display_login execution_identity acquisition_method status permission_digest expires_at last_error_code)a
  @doc "Builds a new durable provider connection while separating trusted ownership fields."
  def create_changeset(attrs) do
    trusted = Map.take(attrs, @trusted)

    %__MODULE__{}
    |> cast(attrs, @user)
    |> change(trusted)
    |> validate_required(
      @trusted_required ++
        ~w(provider_id governed_host external_account_id execution_identity acquisition_method status)a
    )
    |> unique_constraint(:connection_id, name: :provider_connections_pkey)
    |> unique_constraint(:external_account_id, name: :provider_connections_active_binding_index)
    |> check_constraint(:status, name: :provider_connections_status_check)
    |> check_constraint(:last_error_code, name: :provider_connections_last_error_code_check)
    |> check_constraint(:backend_pair_id, name: :provider_connections_backend_binding_check)
  end
end
