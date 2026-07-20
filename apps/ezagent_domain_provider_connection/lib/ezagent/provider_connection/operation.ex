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
      |> foreign_key_constraint(:connection_id,
        name: :provider_connection_operations_connection_workspace_fkey
      )

  @doc false
  def backend_commit_changeset(%__MODULE__{status: "prepared"} = operation, attrs) do
    credential_result_changeset(operation, "backend_committed", attrs)
  end

  @doc false
  def cleanup_pending_changeset(%__MODULE__{status: "prepared"} = operation, attrs) do
    credential_result_changeset(operation, "cleanup_pending", attrs)
  end

  defp credential_result_changeset(operation, status, attrs) do
    operation
    |> change(
      Map.take(attrs, [
        :result_ref,
        :result_external_account_id,
        :result_display_login,
        :result_execution_identity,
        :result_authorization_ref,
        :result_authorization_version,
        :provider_result_ref,
        :safe_error_code,
        :result_credential_version,
        :result_permission_digest,
        :result_expires_at,
        :provider_cleanup_status,
        :credential_cleanup_status
      ])
    )
    |> change(status: status)
    |> validate_required([
      :handoff_ref,
      :result_ref,
      :result_credential_version,
      :prior_credential_ref,
      :prior_credential_version
    ])
    |> check_constraint(:status, name: :provider_connection_operations_status_check)
    |> check_constraint(:result_ref,
      name: :provider_connection_operations_callback_result_check
    )
    |> check_constraint(:status,
      name: :provider_connection_operations_normalized_callback_result_check
    )
    |> check_constraint(:provider_cleanup_status,
      name: :provider_connection_operations_provider_cleanup_result_check
    )
    |> check_constraint(:credential_cleanup_status,
      name: :provider_connection_operations_credential_cleanup_result_check
    )
    |> check_constraint(:status,
      name: :provider_connection_operations_durable_ownership_check
    )
  end
end
