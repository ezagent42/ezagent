defmodule Ezagent.ProviderConnection.Connection do
  @moduledoc "Durable provider connection identity."
  @derive {Inspect,
           only: [
             :connection_id,
             :workspace_uri,
             :owner_uri,
             :provider_id,
             :governed_host,
             :external_account_id,
             :display_login,
             :execution_identity,
             :acquisition_method,
             :connection_version,
             :status,
             :permission_digest,
             :expires_at,
             :last_error_code
           ]}
  use Ecto.Schema
  import Ecto.Changeset

  alias Ezagent.ProviderConnection.Types

  @closed_statuses Enum.map(Types.statuses(), &Atom.to_string/1)
  @closed_errors Enum.map(Types.errors(), &Atom.to_string/1)
  @closed_token ~r/\A[a-z0-9](?:[a-z0-9_-]*[a-z0-9])?\z/
  @primary_key {:connection_id, Ecto.UUID, autogenerate: false}
  schema "provider_connections" do
    field(:workspace_uri, :string)
    field(:owner_uri, :string)
    field(:provider_id, :string)
    field(:governed_host, :string)
    field(:external_account_id, :string)
    field(:display_login, :string)
    field(:execution_identity, :string)
    field(:requested_execution_identity_class, :string)
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

  @trusted_required ~w(connection_id workspace_uri owner_uri)a
  @trusted @trusted_required ++
             ~w(authorization_backend_ref credential_backend_ref backend_pair_id authorization_backend_id credential_backend_id)a
  @user ~w(provider_id governed_host external_account_id display_login execution_identity requested_execution_identity_class acquisition_method status permission_digest expires_at last_error_code)a
  @bound_required ~w(external_account_id execution_identity authorization_backend_ref credential_backend_ref)a
  @immutable ~w(workspace_uri owner_uri provider_id governed_host external_account_id execution_identity acquisition_method)a
  @bind_immutable ~w(workspace_uri owner_uri provider_id governed_host acquisition_method)a
  @active_pointer_fields ~w(external_account_id display_login execution_identity authorization_backend_ref credential_backend_ref backend_pair_id authorization_backend_id credential_backend_id permission_digest expires_at)a
  @transition_trusted ~w(authorization_backend_ref credential_backend_ref authorization_version credential_version connection_version refresh_lease_token refresh_lease_until refresh_lease_version)a
  @doc "Builds a new durable provider connection while separating trusted ownership fields."
  def create_changeset(attrs) do
    trusted = Map.take(attrs, @trusted)

    %__MODULE__{}
    |> cast(attrs, @user)
    |> change(trusted)
    |> validate_required(
      @trusted_required ++ ~w(provider_id governed_host acquisition_method status)a
    )
    |> validate_pending_or_bound()
    |> validate_canonical_scope()
    |> validate_governed_host()
    |> validate_closed_inputs()
    |> unique_constraint(:connection_id, name: :provider_connections_pkey)
    |> unique_constraint(:external_account_id, name: :provider_connections_active_binding_index)
    |> check_constraint(:status, name: :provider_connections_status_check)
    |> check_constraint(:last_error_code, name: :provider_connections_last_error_code_check)
    |> check_constraint(:backend_pair_id, name: :provider_connections_backend_binding_check)
    |> check_constraint(:status, name: :provider_connections_pending_identity_check)
    |> check_constraint(:status, name: :provider_connections_failed_identity_check)
    |> check_constraint(:status, name: :provider_connections_bound_identity_check)
  end

  @doc "Binds immutable provider identity exactly once on a pending connection."
  def bind_changeset(%__MODULE__{status: "pending_authorization"} = connection, attrs) do
    connection
    |> cast(attrs, [
      :external_account_id,
      :display_login,
      :execution_identity,
      :status,
      :permission_digest,
      :expires_at,
      :last_error_code
    ])
    |> change(
      Map.take(attrs, [
        :authorization_backend_ref,
        :credential_backend_ref,
        :backend_pair_id,
        :authorization_backend_id,
        :credential_backend_id,
        :authorization_version,
        :credential_version,
        :connection_version
      ])
    )
    |> reject_attrs(attrs, @bind_immutable)
    |> validate_bind_result()
    |> validate_failed_without_active_pointers()
    |> validate_inclusion(:status, ["active", "failed"])
    |> validate_closed_inputs()
    |> check_constraint(:status, name: :provider_connections_status_check)
    |> check_constraint(:status, name: :provider_connections_failed_identity_check)
    |> check_constraint(:status, name: :provider_connections_bound_identity_check)
    |> check_constraint(:backend_pair_id, name: :provider_connections_backend_binding_check)
  end

  def bind_changeset(%__MODULE__{} = connection, _attrs),
    do: add_error(change(connection), :status, "is not pending authorization")

  @doc "Applies a lifecycle transition without permitting bound identity drift."
  def transition_changeset(%__MODULE__{} = connection, attrs) do
    connection
    |> cast(attrs, [
      :display_login,
      :status,
      :permission_digest,
      :expires_at,
      :last_error_code
    ])
    |> change(Map.take(attrs, @transition_trusted))
    |> reject_attrs(attrs, @immutable)
    |> validate_closed_inputs()
    |> check_constraint(:status, name: :provider_connections_status_check)
    |> check_constraint(:last_error_code, name: :provider_connections_last_error_code_check)
    |> check_constraint(:status, name: :provider_connections_bound_identity_check)
    |> check_constraint(:refresh_lease_token,
      name: :provider_connections_refresh_lease_pair_check
    )
  end

  defp validate_pending_or_bound(changeset) do
    case get_field(changeset, :status) do
      "pending_authorization" ->
        validate_required(changeset, [:requested_execution_identity_class])

      "failed" ->
        changeset

      _bound ->
        validate_required(changeset, @bound_required)
    end
  end

  defp validate_bind_result(changeset) do
    case get_field(changeset, :status) do
      "active" -> validate_required(changeset, @bound_required ++ [:status])
      "failed" -> validate_required(changeset, [:status, :last_error_code])
      _other -> validate_required(changeset, [:status])
    end
  end

  defp validate_failed_without_active_pointers(changeset) do
    if get_field(changeset, :status) == "failed" do
      active_pointer? =
        Enum.any?(@active_pointer_fields, &(not is_nil(get_field(changeset, &1))))

      if active_pointer? or get_field(changeset, :last_error_code) != "account_conflict",
        do: add_error(changeset, :status, "must be a closed account conflict"),
        else: changeset
    else
      changeset
    end
  end

  defp validate_canonical_scope(changeset) do
    changeset
    |> validate_canonical_uri(:workspace_uri, "workspace")
    |> validate_canonical_uri(:owner_uri, "entity")
    |> validate_owner_workspace()
  end

  defp validate_canonical_uri(changeset, field, expected_scheme) do
    validate_change(changeset, field, fn ^field, value ->
      with true <- is_binary(value),
           {:ok, uri} <- Ezagent.URI.parse(value),
           true <- uri.scheme == expected_scheme,
           true <- URI.to_string(uri) == value do
        []
      else
        _ -> [{field, "must be a canonical #{expected_scheme} URI"}]
      end
    end)
  end

  defp validate_owner_workspace(changeset) do
    owner = get_field(changeset, :owner_uri)
    workspace = get_field(changeset, :workspace_uri)

    with true <- is_binary(owner) and is_binary(workspace),
         {:ok, owner_uri} <- Ezagent.URI.parse(owner),
         {:ok, "user"} <- Ezagent.URI.type(owner_uri),
         %URI{} = owner_workspace <- Ezagent.Capability.workspace_of(owner_uri),
         true <- URI.to_string(owner_workspace) == workspace do
      changeset
    else
      _ -> add_error(changeset, :owner_uri, "must belong to workspace_uri")
    end
  end

  defp validate_governed_host(changeset) do
    validate_change(changeset, :governed_host, fn :governed_host, host ->
      labels = if is_binary(host), do: String.split(host, "."), else: []

      valid? =
        labels != [] and String.length(host) <= 253 and
          Enum.all?(labels, fn label ->
            String.length(label) in 1..63 and
              Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, label)
          end)

      if valid?, do: [], else: [governed_host: "must be a normalized host"]
    end)
  end

  defp validate_closed_inputs(changeset) do
    changeset
    |> validate_inclusion(:status, @closed_statuses)
    |> validate_inclusion(:last_error_code, @closed_errors)
    |> validate_format(:provider_id, @closed_token)
    |> validate_format(:acquisition_method, @closed_token)
    |> validate_format(:requested_execution_identity_class, @closed_token)
    |> validate_format(:execution_identity, @closed_token)
    |> validate_change(:external_account_id, fn :external_account_id, value ->
      if is_binary(value) and value != "" and value == String.trim(value),
        do: [],
        else: [external_account_id: "must be a canonical non-empty identifier"]
    end)
  end

  defp reject_attrs(changeset, attrs, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      if Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field)),
        do: add_error(acc, field, "is immutable"),
        else: acc
    end)
  end
end
