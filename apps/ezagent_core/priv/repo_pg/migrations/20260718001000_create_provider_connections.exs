defmodule EzagentCore.Repo.Migrations.CreateProviderConnections do
  use Ecto.Migration

  def up do
    create table(:provider_connections, primary_key: false) do
      add :connection_id, :uuid, primary_key: true
      add :workspace_uri, :text, null: false
      add :owner_uri, :text, null: false
      add :provider_id, :text, null: false
      add :governed_host, :text, null: false
      add :external_account_id, :text, null: false
      add :display_login, :text
      add :execution_identity, :text, null: false
      add :acquisition_method, :text, null: false
      add :authorization_backend_ref, :text, null: false
      add :credential_backend_ref, :text, null: false
      add :authorization_version, :bigint, null: false, default: 0
      add :credential_version, :bigint, null: false, default: 0
      add :connection_version, :bigint, null: false, default: 0
      add :status, :text, null: false
      add :permission_digest, :text
      add :expires_at, :utc_datetime_usec
      add :last_error_code, :text
      timestamps(type: :utc_datetime_usec)
    end

    create index(:provider_connections, [:workspace_uri])

    create unique_index(
             :provider_connections,
             [
               :workspace_uri,
               :owner_uri,
               :provider_id,
               :governed_host,
               :external_account_id,
               :execution_identity
             ],
             where: "status NOT IN ('revoked','disconnected')",
             name: :provider_connections_active_binding_index
           )

    create constraint(:provider_connections, :provider_connections_status_check,
             check:
               "status IN ('pending_authorization','active','refresh_required','refreshing','degraded','expired','revoking','revoked','disconnecting','disconnected')"
           )

    create constraint(:provider_connections, :provider_connections_last_error_code_check,
             check:
               "last_error_code IS NULL OR last_error_code IN ('invalid_subject','invalid_method','invalid_host','state_mismatch','pkce_mismatch','callback_expired','callback_replayed','callback_in_progress','correlation_conflict','account_conflict','stale_version','reauthentication_failed','backend_unavailable','credential_conflict','credential_revocation_failed','refresh_lease_lost','provider_denied','provider_protocol_failed','cleanup_pending','connection_terminal')"
           )

    create table(:provider_authorization_attempts, primary_key: false) do
      add :attempt_ref, :uuid, primary_key: true
      add :workspace_uri, :text, null: false
      add :backend_pair_id, :text, null: false
      add :authorization_ref, :text, null: false
      add :connection_id, :uuid, null: false
      add :connection_version, :bigint, null: false, default: 0
      add :bound_subject_digest, :text, null: false
      add :state_digest, :text, null: false
      add :pkce_digest, :text
      add :correlation_id, :text, null: false
      add :attempt_version, :bigint, null: false, default: 0
      add :status, :text, null: false
      add :callback_artifact, :map
      add :claim_token, :text
      add :claim_until, :utc_datetime_usec
      add :consumed_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:provider_authorization_attempts, [:workspace_uri])
    create unique_index(:provider_authorization_attempts, [:authorization_ref])

    create unique_index(:provider_authorization_attempts, [:backend_pair_id, :state_digest],
             name: :provider_authorization_attempts_backend_state_index
           )

    create constraint(
             :provider_authorization_attempts,
             :provider_authorization_attempts_status_check,
             check: "status IN ('pending','consuming','consumed','cancelled','expired')"
           )

    create table(:provider_connection_operations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_uri, :text, null: false
      add :connection_id, :uuid, null: false
      add :backend_pair_id, :text, null: false
      add :operation_class, :text, null: false
      add :correlation_id, :text, null: false
      add :bound_input_digest, :text, null: false
      add :expected_connection_version, :bigint
      add :expected_credential_version, :bigint
      add :result_ref, :text
      add :status, :text, null: false
      add :lease_token, :text
      add :lease_until, :utc_datetime_usec
      add :safe_error_code, :text
      timestamps(type: :utc_datetime_usec)
    end

    create index(:provider_connection_operations, [:workspace_uri])

    create unique_index(
             :provider_connection_operations,
             [:backend_pair_id, :operation_class, :correlation_id],
             name: :provider_connection_operations_command_index
           )

    create constraint(
             :provider_connection_operations,
             :provider_connection_operations_operation_class_check,
             check: "operation_class IN ('store','replace','refresh','revoke','disconnect')"
           )

    create constraint(
             :provider_connection_operations,
             :provider_connection_operations_status_check,
             check:
               "status IN ('prepared','backend_committed','connection_committed','finalized','fenced','cleanup_pending')"
           )

    create constraint(
             :provider_connection_operations,
             :provider_connection_operations_safe_error_code_check,
             check:
               "safe_error_code IS NULL OR safe_error_code IN ('invalid_subject','invalid_method','invalid_host','state_mismatch','pkce_mismatch','callback_expired','callback_replayed','callback_in_progress','correlation_conflict','account_conflict','stale_version','reauthentication_failed','backend_unavailable','credential_conflict','credential_revocation_failed','refresh_lease_lost','provider_denied','provider_protocol_failed','cleanup_pending','connection_terminal')"
           )

    create table(:provider_connection_events, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_uri, :text, null: false
      add :connection_id, :uuid, null: false
      add :actor_role, :text
      add :transition_from, :text
      add :transition_to, :text
      add :connection_version, :bigint
      add :correlation_id, :text
      add :result_class, :text
      add :provider_request_id, :text
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:provider_connection_events, [:workspace_uri])

    create constraint(
             :provider_connection_events,
             :provider_connection_events_transition_from_check,
             check:
               "transition_from IS NULL OR transition_from IN ('pending_authorization','active','refresh_required','refreshing','degraded','expired','revoking','revoked','disconnecting','disconnected')"
           )

    create constraint(
             :provider_connection_events,
             :provider_connection_events_transition_to_check,
             check:
               "transition_to IS NULL OR transition_to IN ('pending_authorization','active','refresh_required','refreshing','degraded','expired','revoking','revoked','disconnecting','disconnected')"
           )

    create table(:provider_authorization_backend_records, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_uri, :text, null: false
      add :backend_pair_id, :text, null: false
      add :authorization_ref, :text, null: false
      add :key_id, :text, null: false
      add :key_fingerprint, :binary, null: false
      add :nonce, :binary
      add :ciphertext, :binary
      add :bound_input_digest, :text, null: false
      add :begin_correlation_id, :text, null: false
      add :owner_uri, :text, null: false
      add :connection_id, :text, null: false
      add :connection_version, :bigint, null: false
      add :provider_id, :text, null: false
      add :governed_host, :text, null: false
      add :acquisition_method, :text, null: false
      add :requested_permissions_digest, :text, null: false
      add :redirect_uri_id, :text, null: false
      add :handoff_ciphertext, :binary
      add :handoff_ref, :text
      add :consume_correlation_id, :text
      add :consume_input_digest, :text
      add :callback_key_id, :text
      add :callback_key_fingerprint, :binary
      add :callback_nonce, :binary
      add :callback_ciphertext, :binary
      add :lifecycle_status, :text, null: false
      add :shredded_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:provider_authorization_backend_records, [:workspace_uri])

    create unique_index(:provider_authorization_backend_records, [:authorization_ref],
             name: :provider_authorization_backend_records_authorization_ref_index
           )

    create constraint(
             :provider_authorization_backend_records,
             :provider_authorization_backend_records_lifecycle_status_check,
             check: "lifecycle_status IN ('pending','consumed','cancelled','expired')"
           )

    create table(:provider_authorization_commands, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_uri, :text, null: false
      add :backend_pair_id, :text, null: false
      add :operation_class, :text, null: false
      add :correlation_id, :text, null: false
      add :bound_input_digest, :text, null: false
      add :authorization_ref, :text
      add :status, :text, null: false
      add :safe_result, :map
      add :safe_error_code, :text
      timestamps(type: :utc_datetime_usec)
    end

    create index(:provider_authorization_commands, [:workspace_uri])

    create unique_index(
             :provider_authorization_commands,
             [:backend_pair_id, :operation_class, :correlation_id],
             name: :provider_authorization_commands_command_index
           )

    create constraint(
             :provider_authorization_commands,
             :provider_authorization_commands_operation_class_check,
             check: "operation_class IN ('begin','consume','reauthenticate','cancel')"
           )

    create constraint(
             :provider_authorization_commands,
             :provider_authorization_commands_status_check,
             check: "status IN ('prepared','committed','terminal_failed')"
           )
  end

  def down do
    drop_if_exists table(:provider_authorization_commands)
    drop table(:provider_authorization_backend_records)
    drop table(:provider_connection_events)
    drop table(:provider_connection_operations)
    drop table(:provider_authorization_attempts)
    drop table(:provider_connections)
  end
end
