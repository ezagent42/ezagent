defmodule Ezagent.ProviderConnection.Operation do
  @moduledoc "Durable idempotency and recovery operation."
  @derive {Inspect,
           only: [
             :id,
             :workspace_uri,
             :connection_id,
             :attempt_ref,
             :operation_class,
             :correlation_id,
             :expected_connection_version,
             :expected_authorization_version,
             :expected_credential_version,
             :result_external_account_id,
             :result_display_login,
             :result_execution_identity,
             :result_permission_digest,
             :result_expires_at,
             :result_authorization_version,
             :result_credential_version,
             :status,
             :safe_error_code,
             :recovery_attempts,
             :next_recovery_at,
             :last_recovery_error_code,
             :provider_cleanup_status,
             :credential_cleanup_status
           ]}
  use Ecto.Schema
  import Ecto.Changeset

  alias Ezagent.ProviderConnection.{AuthorizationAttempt, AuthorizationBackendRecord, Connection}
  @primary_key {:id, Ecto.UUID, autogenerate: true}
  schema "provider_connection_operations" do
    field(:workspace_uri, :string)
    field(:connection_id, Ecto.UUID)
    field(:attempt_ref, Ecto.UUID)
    field(:backend_pair_id, :string)
    field(:operation_class, :string)
    field(:correlation_id, :string)
    field(:bound_input_digest, :string)
    field(:expected_connection_version, :integer)
    field(:expected_authorization_ref, :string)
    field(:expected_authorization_version, :integer)
    field(:attempt_version, :integer)
    field(:attempt_claim_token, :string)
    field(:handoff_ref, :string)
    field(:expected_credential_version, :integer)
    field(:result_credential_version, :integer)
    field(:result_ref, :string)
    field(:result_external_account_id, :string)
    field(:result_display_login, :string)
    field(:result_execution_identity, :string)
    field(:result_authorization_ref, :string)
    field(:result_authorization_version, :integer)
    field(:provider_result_ref, :string)
    field(:prior_credential_ref, :string)
    field(:prior_credential_version, :integer)
    field(:result_permission_digest, :string)
    field(:result_expires_at, :utc_datetime_usec)
    field(:status, :string)
    field(:lease_token, :string)
    field(:lease_until, :utc_datetime_usec)
    field(:safe_error_code, :string)
    field(:recovery_attempts, :integer, default: 0)
    field(:next_recovery_at, :utc_datetime_usec)
    field(:last_recovery_error_code, :string)
    field(:provider_cleanup_status, :string, default: "not_required")
    field(:credential_cleanup_status, :string, default: "not_required")
    field(:provider_cleanup_error_code, :string)
    field(:credential_cleanup_error_code, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  @spec callback_digest(AuthorizationBackendRecord.t(), AuthorizationAttempt.t(), Connection.t()) ::
          String.t()
  def callback_digest(
        %AuthorizationBackendRecord{} = backend_record,
        %AuthorizationAttempt{} = attempt,
        %Connection{} = connection
      ) do
    {
      :provider_callback_store_v1,
      {
        backend_record.authorization_ref,
        backend_record.backend_pair_id,
        backend_record.bound_input_digest,
        backend_record.begin_correlation_id,
        backend_record.owner_uri,
        backend_record.workspace_uri,
        backend_record.connection_id,
        backend_record.connection_version,
        backend_record.provider_id,
        backend_record.governed_host,
        backend_record.acquisition_method,
        backend_record.requested_permissions_digest,
        backend_record.redirect_uri_id
      },
      {
        attempt.attempt_ref,
        attempt.authorization_ref,
        attempt.backend_pair_id,
        attempt.bound_subject_digest,
        attempt.workspace_uri,
        attempt.connection_id,
        attempt.connection_version,
        attempt.correlation_id
      },
      {
        connection.owner_uri,
        connection.workspace_uri,
        connection.connection_id,
        connection.connection_version,
        connection.provider_id,
        connection.governed_host,
        connection.acquisition_method,
        backend_record.execution_identity,
        connection.execution_identity
      }
    }
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @trusted_required ~w(workspace_uri connection_id backend_pair_id operation_class correlation_id bound_input_digest expected_connection_version)a
  @trusted @trusted_required ++
             [
               :attempt_ref,
               :attempt_version,
               :attempt_claim_token,
               :expected_authorization_ref,
               :expected_authorization_version,
               :expected_credential_version,
               :prior_credential_ref,
               :prior_credential_version,
               :safe_error_code,
               :recovery_attempts,
               :next_recovery_at,
               :last_recovery_error_code,
               :provider_cleanup_status,
               :credential_cleanup_status,
               :provider_cleanup_error_code,
               :credential_cleanup_error_code
             ]
  @doc "Builds the initial idempotent operation changeset from trusted command coordinates."
  def create_changeset(attrs) when is_map(attrs) do
    attrs
    |> base_create_changeset()
    |> reject_unscoped_effect_operation()
  end

  defp base_create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:status])
    |> change(Map.take(attrs, @trusted))
    |> reject_invocation_private_terms(attrs)
    |> validate_required(@trusted_required ++ [:status])
    |> validate_prior_credential_pair()
    |> validate_expected_authorization_coordinates()
    |> unique_constraint(:correlation_id, name: :provider_connection_operations_command_index)
    |> check_constraint(:operation_class,
      name: :provider_connection_operations_operation_class_check
    )
    |> check_constraint(:status, name: :provider_connection_operations_status_check)
    |> check_constraint(:status,
      name: :provider_connection_operations_callback_prepare_check
    )
    |> check_constraint(:safe_error_code,
      name: :provider_connection_operations_safe_error_code_check
    )
    |> check_constraint(:recovery_attempts,
      name: :provider_connection_operations_recovery_attempts_check
    )
    |> check_constraint(:last_recovery_error_code,
      name: :provider_connection_operations_last_recovery_error_code_check
    )
    |> check_constraint(:provider_cleanup_status,
      name: :provider_connection_operations_provider_cleanup_status_check
    )
    |> check_constraint(:credential_cleanup_status,
      name: :provider_connection_operations_credential_cleanup_status_check
    )
    |> check_constraint(:provider_cleanup_error_code,
      name: :provider_connection_operations_provider_cleanup_error_check
    )
    |> check_constraint(:credential_cleanup_error_code,
      name: :provider_connection_operations_credential_cleanup_error_check
    )
    |> check_constraint(:status,
      name: :provider_connection_operations_durable_ownership_check
    )
    |> check_constraint(:expected_authorization_ref,
      name: :provider_connection_operations_expected_authorization_check
    )
    |> check_constraint(:status,
      name: :provider_connection_operations_ownership_stage_check
    )
    |> check_constraint(:attempt_ref,
      name: :provider_connection_operations_attempt_purpose_check
    )
    |> foreign_key_constraint(:connection_id,
      name: :provider_connection_operations_connection_workspace_fkey
    )
  end

  defp reject_invocation_private_terms(changeset, attrs) do
    if invocation_private_term?(Map.take(attrs, @trusted)),
      do: add_error(changeset, :base, "contains invocation-private refresh authority"),
      else: changeset
  end

  defp invocation_private_term?(%Ezagent.ProviderConnection.CredentialBackend.RefreshUse{}),
    do: true

  defp invocation_private_term?(value)
       when is_pid(value) or is_reference(value) or is_function(value) or is_port(value),
       do: true

  defp invocation_private_term?(%_struct{} = value),
    do: value |> Map.from_struct() |> invocation_private_term?()

  defp invocation_private_term?(value) when is_map(value),
    do:
      Enum.any?(value, fn {key, item} ->
        invocation_private_term?(key) or invocation_private_term?(item)
      end)

  defp invocation_private_term?(value) when is_list(value),
    do: Enum.any?(value, &invocation_private_term?/1)

  defp invocation_private_term?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&invocation_private_term?/1)

  defp invocation_private_term?(_value), do: false

  @doc "Builds a callback-store operation from a locked attempt and connection."
  @spec store_create_changeset(AuthorizationAttempt.t(), Connection.t(), map()) ::
          Ecto.Changeset.t()
  def store_create_changeset(
        %AuthorizationAttempt{} = attempt,
        %Connection{} = connection,
        attrs
      )
      when is_map(attrs) do
    trusted_scope = %{
      workspace_uri: connection.workspace_uri,
      connection_id: connection.connection_id,
      attempt_ref: attempt.attempt_ref,
      backend_pair_id: attempt.backend_pair_id,
      expected_connection_version: connection.connection_version,
      expected_authorization_ref: attempt.authorization_ref,
      expected_authorization_version: connection.authorization_version,
      expected_credential_version: connection.credential_version,
      attempt_version: attempt.attempt_version,
      attempt_claim_token: attempt.claim_token
    }

    attrs
    |> Map.merge(trusted_scope)
    |> Map.put(:operation_class, callback_operation_class(attempt.purpose))
    |> put_prior_credential(attempt, connection)
    |> base_create_changeset()
    |> validate_store_scope(attempt, connection)
  end

  @doc "Builds a refresh operation from the locked connection generation."
  @spec refresh_create_changeset(Connection.t(), map()) :: Ecto.Changeset.t()
  def refresh_create_changeset(%Connection{} = connection, attrs) when is_map(attrs) do
    trusted_scope = %{
      workspace_uri: connection.workspace_uri,
      connection_id: connection.connection_id,
      backend_pair_id: connection.backend_pair_id,
      operation_class: "refresh",
      expected_connection_version: connection.connection_version,
      expected_authorization_ref: connection.authorization_backend_ref,
      expected_authorization_version: connection.authorization_version,
      expected_credential_version: connection.credential_version,
      prior_credential_ref: connection.credential_backend_ref,
      prior_credential_version: connection.credential_version
    }

    attrs
    |> Map.merge(trusted_scope)
    |> base_create_changeset()
  end

  @doc false
  def provider_ownership_changeset(%__MODULE__{status: "prepared"} = operation, attrs)
      when is_map(attrs) do
    allowed = provider_ownership_fields(operation.operation_class)

    operation
    |> change(Map.take(attrs, allowed))
    |> validate_effect_ownership_class()
    |> validate_exact_keys(attrs, allowed -- [:result_expires_at], [:result_expires_at])
    |> validate_unowned_provider_stage()
    |> validate_provider_ownership()
    |> check_constraint(:status,
      name: :provider_connection_operations_ownership_stage_check
    )
  end

  def provider_ownership_changeset(%__MODULE__{} = operation, attrs) when is_map(attrs) do
    operation
    |> change()
    |> add_error(:status, "must be unowned prepared before provider ownership")
  end

  @doc false
  def credential_ownership_changeset(
        %__MODULE__{status: "prepared"} = operation,
        status,
        attrs
      )
      when status in ["backend_committed", "cleanup_pending"] and is_map(attrs) do
    operation
    |> change(Map.take(attrs, [:result_ref, :result_credential_version]))
    |> validate_effect_ownership_class()
    |> validate_exact_keys(attrs, [:result_ref, :result_credential_version])
    |> validate_provider_ownership()
    |> validate_unowned_credential_stage()
    |> change(status: status)
    |> validate_required([:result_ref, :result_credential_version])
    |> check_constraint(:status, name: :provider_connection_operations_status_check)
    |> check_constraint(:status,
      name: :provider_connection_operations_ownership_stage_check
    )
  end

  def credential_ownership_changeset(%__MODULE__{} = operation, _status, attrs)
      when is_map(attrs) do
    operation
    |> change()
    |> add_error(:status, "must be provider-owned prepared before credential ownership")
  end

  defp validate_expected_authorization_coordinates(changeset) do
    if get_field(changeset, :operation_class) in ["store", "replace", "refresh"] do
      validate_required(changeset, [
        :expected_authorization_ref,
        :expected_authorization_version
      ])
    else
      changeset
    end
  end

  defp reject_unscoped_effect_operation(changeset) do
    if get_field(changeset, :operation_class) in ["store", "replace", "refresh"] do
      add_error(
        changeset,
        :operation_class,
        "must be built by its locked scoped constructor"
      )
    else
      changeset
    end
  end

  defp provider_ownership_fields(operation_class) when operation_class in ["store", "replace"] do
    [
      :handoff_ref,
      :provider_result_ref,
      :result_external_account_id,
      :result_display_login,
      :result_execution_identity,
      :result_authorization_ref,
      :result_authorization_version,
      :result_permission_digest,
      :result_expires_at
    ]
  end

  defp provider_ownership_fields("refresh") do
    [
      :handoff_ref,
      :provider_result_ref,
      :result_permission_digest,
      :result_expires_at
    ]
  end

  defp provider_ownership_fields(_operation_class), do: []

  defp validate_provider_ownership(changeset) do
    required =
      case get_field(changeset, :operation_class) do
        operation_class when operation_class in ["store", "replace"] ->
          [
            :handoff_ref,
            :provider_result_ref,
            :result_external_account_id,
            :result_display_login,
            :result_execution_identity,
            :result_authorization_ref,
            :result_authorization_version,
            :result_permission_digest
          ]

        "refresh" ->
          [:handoff_ref, :provider_result_ref, :result_permission_digest]

        _other ->
          []
      end

    changeset
    |> validate_required(required)
    |> validate_refresh_callback_fields_absent()
    |> validate_callback_authorization_result()
  end

  defp validate_effect_ownership_class(changeset) do
    if get_field(changeset, :operation_class) in ["store", "replace", "refresh"] do
      changeset
    else
      add_error(changeset, :operation_class, "does not own provider or credential results")
    end
  end

  defp validate_refresh_callback_fields_absent(changeset) do
    if get_field(changeset, :operation_class) == "refresh" do
      Enum.reduce(callback_only_result_fields(), changeset, fn field, acc ->
        if is_nil(get_field(acc, field)),
          do: acc,
          else: add_error(acc, field, "must be absent for refresh")
      end)
    else
      changeset
    end
  end

  defp validate_callback_authorization_result(changeset) do
    case {
      get_field(changeset, :operation_class),
      get_field(changeset, :expected_authorization_ref),
      get_field(changeset, :expected_authorization_version),
      get_field(changeset, :result_authorization_ref),
      get_field(changeset, :result_authorization_version)
    } do
      {operation_class, expected_ref, expected_version, expected_ref, result_version}
      when operation_class in ["store", "replace"] and is_integer(expected_version) and
             result_version == expected_version + 1 ->
        changeset

      {operation_class, _expected_ref, _expected_version, _result_ref, _result_version}
      when operation_class in ["store", "replace"] ->
        add_error(changeset, :result_authorization_ref, "does not match reserved authorization")

      _other ->
        changeset
    end
  end

  defp provider_ownership_state_fields do
    [
      :handoff_ref,
      :provider_result_ref,
      :result_external_account_id,
      :result_display_login,
      :result_execution_identity,
      :result_authorization_ref,
      :result_authorization_version,
      :result_permission_digest,
      :result_expires_at,
      :result_ref,
      :result_credential_version
    ]
  end

  defp callback_only_result_fields do
    [
      :result_external_account_id,
      :result_display_login,
      :result_execution_identity,
      :result_authorization_ref,
      :result_authorization_version
    ]
  end

  defp validate_exact_keys(changeset, attrs, required_keys, optional_keys \\ []) do
    supplied = attrs |> Map.keys() |> MapSet.new()
    required = MapSet.new(required_keys)
    allowed = MapSet.union(required, MapSet.new(optional_keys))

    changeset =
      supplied
      |> MapSet.difference(allowed)
      |> Enum.reduce(changeset, fn key, acc ->
        add_error(acc, :base, "contains unsupported ownership field #{inspect(key)}")
      end)

    required
    |> MapSet.difference(supplied)
    |> Enum.reduce(changeset, fn key, acc ->
      add_error(acc, key, "is required")
    end)
  end

  defp validate_unowned_provider_stage(changeset) do
    Enum.reduce(provider_ownership_state_fields(), changeset, fn field, acc ->
      if is_nil(Map.get(acc.data, field)),
        do: acc,
        else: add_error(acc, field, "provider ownership is already or partially recorded")
    end)
  end

  defp validate_unowned_credential_stage(changeset) do
    case {Map.get(changeset.data, :result_ref),
          Map.get(changeset.data, :result_credential_version)} do
      {nil, nil} ->
        changeset

      _owned_or_partial ->
        add_error(changeset, :result_ref, "credential ownership is already or partially recorded")
    end
  end

  defp validate_prior_credential_pair(changeset) do
    case {
      get_field(changeset, :prior_credential_ref),
      get_field(changeset, :prior_credential_version)
    } do
      {nil, nil} ->
        changeset

      {prior_ref, prior_version} when is_binary(prior_ref) and is_integer(prior_version) ->
        changeset

      _half_pair ->
        add_error(
          changeset,
          :prior_credential_ref,
          "must be present with prior credential version"
        )
    end
  end

  defp put_prior_credential(attrs, %AuthorizationAttempt{purpose: "initial_bind"}, _connection) do
    Map.merge(attrs, %{prior_credential_ref: nil, prior_credential_version: nil})
  end

  defp put_prior_credential(attrs, %AuthorizationAttempt{purpose: "reauthorize"}, connection) do
    Map.merge(attrs, %{
      prior_credential_ref: connection.credential_backend_ref,
      prior_credential_version: connection.credential_version
    })
  end

  defp put_prior_credential(attrs, _attempt, _connection), do: attrs

  defp validate_store_scope(changeset, attempt, connection) do
    consistent? =
      get_field(changeset, :operation_class) == callback_operation_class(attempt.purpose) and
        attempt.purpose in ["initial_bind", "reauthorize"] and
        attempt.connection_id == connection.connection_id and
        attempt.workspace_uri == connection.workspace_uri and
        attempt.connection_version == connection.connection_version and
        connection.backend_pair_id in [nil, attempt.backend_pair_id] and
        attempt.backend_pair_id == get_field(changeset, :backend_pair_id) and
        get_field(changeset, :expected_connection_version) == attempt.connection_version and
        get_field(changeset, :expected_authorization_ref) == attempt.authorization_ref and
        get_field(changeset, :expected_authorization_version) == connection.authorization_version and
        get_field(changeset, :expected_credential_version) == connection.credential_version and
        valid_prior_coordinates?(changeset, attempt, connection)

    if consistent?,
      do: changeset,
      else:
        add_error(changeset, :attempt_ref, "does not match locked attempt purpose and connection")
  end

  defp valid_prior_coordinates?(
         changeset,
         %AuthorizationAttempt{purpose: "initial_bind"},
         _connection
       ) do
    is_nil(get_field(changeset, :prior_credential_ref)) and
      is_nil(get_field(changeset, :prior_credential_version))
  end

  defp valid_prior_coordinates?(
         changeset,
         %AuthorizationAttempt{purpose: "reauthorize"},
         connection
       ) do
    is_binary(connection.credential_backend_ref) and
      is_integer(connection.credential_version) and
      get_field(changeset, :prior_credential_ref) == connection.credential_backend_ref and
      get_field(changeset, :prior_credential_version) == connection.credential_version
  end

  defp valid_prior_coordinates?(_changeset, _attempt, _connection), do: false

  defp callback_operation_class("initial_bind"), do: "store"
  defp callback_operation_class("reauthorize"), do: "replace"
  defp callback_operation_class(_purpose), do: nil
end
