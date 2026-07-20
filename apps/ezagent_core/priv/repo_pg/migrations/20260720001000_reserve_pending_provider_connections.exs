defmodule EzagentCore.Repo.Migrations.ReservePendingProviderConnections do
  use Ecto.Migration

  def up do
    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_callback_prepare_check
      )
    )

    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_callback_result_check
      )
    )

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_callback_prepare_check,
        check: """
        operation_class <> 'store'
        OR status <> 'prepared'
        OR (expected_credential_version IS NOT NULL AND
            ((prior_credential_ref IS NULL AND prior_credential_version IS NULL) OR
             (prior_credential_ref IS NOT NULL AND prior_credential_version IS NOT NULL)))
        """
      )
    )

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_callback_result_check,
        check: """
        operation_class <> 'store'
        OR status NOT IN ('backend_committed','cleanup_pending')
        OR (handoff_ref IS NOT NULL AND result_ref IS NOT NULL AND
            expected_credential_version IS NOT NULL AND
            result_credential_version IS NOT NULL AND
            ((prior_credential_ref IS NULL AND prior_credential_version IS NULL) OR
             (prior_credential_ref IS NOT NULL AND prior_credential_version IS NOT NULL)))
        """
      )
    )

    drop(constraint(:provider_connections, :provider_connections_status_check))
    drop(constraint(:provider_connections, :provider_connections_backend_binding_check))

    drop(index(:provider_connections, [], name: :provider_connections_active_binding_index))

    alter table(:provider_connections) do
      modify(:external_account_id, :text, null: true)
      modify(:execution_identity, :text, null: true)
      modify(:authorization_backend_ref, :text, null: true)
      modify(:credential_backend_ref, :text, null: true)
      add(:requested_execution_identity_class, :text)
    end

    execute("""
    UPDATE provider_connections
       SET requested_execution_identity_class = execution_identity
    """)

    execute("""
    UPDATE provider_connections
       SET external_account_id = NULL,
           display_login = NULL,
           execution_identity = NULL,
           authorization_backend_ref = NULL,
           credential_backend_ref = NULL,
           backend_pair_id = NULL,
           authorization_backend_id = NULL,
           credential_backend_id = NULL,
           permission_digest = NULL,
           expires_at = NULL
     WHERE status = 'pending_authorization'
    """)

    alter table(:provider_authorization_attempts) do
      modify(:backend_pair_id, :text, null: true)
      modify(:authorization_ref, :text, null: true)
      modify(:bound_subject_digest, :text, null: true)
      modify(:state_digest, :text, null: true)
      modify(:expires_at, :utc_datetime_usec, null: true)
      add(:purpose, :text)
      add(:reservation_digest, :text)
      add(:requested_permission_digest, :text)
      add(:requested_execution_identity_class, :text)
      add(:redirect_uri_id, :text)
      add(:callback_artifact_digest, :text)
    end

    drop(
      constraint(
        :provider_authorization_attempts,
        :provider_authorization_attempts_status_check
      )
    )

    execute("""
    UPDATE provider_authorization_attempts AS attempt
       SET purpose = CASE
             WHEN attempt.status IN ('pending','consuming')
              AND connection.status = 'pending_authorization'
               THEN 'initial_bind'
             ELSE 'legacy'
           END
      FROM provider_connections AS connection
     WHERE connection.connection_id = attempt.connection_id
    """)

    execute("""
    UPDATE provider_authorization_attempts AS attempt
       SET reservation_digest = attempt.state_digest,
           requested_permission_digest = backend.requested_permissions_digest,
           requested_execution_identity_class = backend.execution_identity,
           redirect_uri_id = backend.redirect_uri_id,
           callback_artifact_digest = attempt.bound_subject_digest
      FROM provider_authorization_backend_records AS backend
     WHERE attempt.purpose = 'initial_bind'
       AND backend.authorization_ref = attempt.authorization_ref
    """)

    execute("""
    UPDATE provider_authorization_attempts
       SET status = 'cancelled',
           claim_token = NULL,
           claim_until = NULL
     WHERE purpose = 'legacy'
       AND status IN ('pending','consuming')
    """)

    execute("""
    ALTER TABLE provider_authorization_attempts
      ALTER COLUMN purpose SET NOT NULL
    """)

    create(
      constraint(:provider_connections, :provider_connections_status_check,
        check:
          "status IN ('pending_authorization','active','refresh_required','refreshing','degraded','expired','revoking','revoked','disconnecting','disconnected','failed')"
      )
    )

    create(
      constraint(:provider_connections, :provider_connections_pending_identity_check,
        check: """
        (status = 'pending_authorization' AND
          requested_execution_identity_class IS NOT NULL AND
          external_account_id IS NULL AND display_login IS NULL AND
          execution_identity IS NULL AND authorization_backend_ref IS NULL AND
          credential_backend_ref IS NULL AND permission_digest IS NULL AND
          expires_at IS NULL AND backend_pair_id IS NULL AND
          authorization_backend_id IS NULL AND credential_backend_id IS NULL)
        OR status <> 'pending_authorization'
        """
      )
    )

    create(
      constraint(:provider_connections, :provider_connections_failed_identity_check,
        check: """
        status <> 'failed'
        OR (last_error_code = 'account_conflict' AND
            external_account_id IS NULL AND display_login IS NULL AND
            execution_identity IS NULL AND authorization_backend_ref IS NULL AND
            credential_backend_ref IS NULL AND permission_digest IS NULL AND
            expires_at IS NULL AND backend_pair_id IS NULL AND
            authorization_backend_id IS NULL AND credential_backend_id IS NULL)
        """
      )
    )

    create(
      constraint(:provider_connections, :provider_connections_bound_identity_check,
        check: """
        status IN ('pending_authorization','failed')
        OR (external_account_id IS NOT NULL AND execution_identity IS NOT NULL AND
            authorization_backend_ref IS NOT NULL AND credential_backend_ref IS NOT NULL)
        """
      )
    )

    create(
      constraint(:provider_connections, :provider_connections_backend_binding_check,
        check:
          "(backend_pair_id IS NULL AND authorization_backend_id IS NULL AND credential_backend_id IS NULL) OR (backend_pair_id IS NOT NULL AND authorization_backend_id IS NOT NULL AND credential_backend_id IS NOT NULL)"
      )
    )

    create(
      unique_index(
        :provider_connections,
        [
          :workspace_uri,
          :owner_uri,
          :provider_id,
          :governed_host,
          :external_account_id,
          :execution_identity
        ],
        where:
          "external_account_id IS NOT NULL AND status NOT IN ('revoked','disconnected','failed')",
        name: :provider_connections_active_binding_index
      )
    )

    create(
      constraint(
        :provider_authorization_attempts,
        :provider_authorization_attempts_status_check,
        check: "status IN ('beginning','pending','consuming','consumed','cancelled','expired')"
      )
    )

    drop(
      constraint(
        :provider_connection_events,
        :provider_connection_events_transition_from_check
      )
    )

    drop(
      constraint(
        :provider_connection_events,
        :provider_connection_events_transition_to_check
      )
    )

    create(
      constraint(
        :provider_connection_events,
        :provider_connection_events_transition_from_check,
        check:
          "transition_from IS NULL OR transition_from IN ('pending_authorization','active','refresh_required','refreshing','degraded','expired','revoking','revoked','disconnecting','disconnected','failed')"
      )
    )

    create(
      constraint(
        :provider_connection_events,
        :provider_connection_events_transition_to_check,
        check:
          "transition_to IS NULL OR transition_to IN ('pending_authorization','active','refresh_required','refreshing','degraded','expired','revoking','revoked','disconnecting','disconnected','failed')"
      )
    )

    create(
      constraint(
        :provider_authorization_attempts,
        :provider_authorization_attempts_purpose_check,
        check: "purpose IN ('legacy','initial_bind','reauthorize')"
      )
    )

    create(
      constraint(
        :provider_authorization_attempts,
        :provider_authorization_attempts_reservation_check,
        check: """
        purpose = 'legacy'
        OR (reservation_digest IS NOT NULL AND requested_permission_digest IS NOT NULL AND
            requested_execution_identity_class IS NOT NULL AND redirect_uri_id IS NOT NULL AND
            callback_artifact_digest IS NOT NULL)
        """
      )
    )

    create(
      constraint(
        :provider_authorization_attempts,
        :provider_authorization_attempts_lifecycle_check,
        check: """
        (purpose = 'legacy' AND status IN ('consumed','cancelled','expired'))
        OR (purpose IN ('initial_bind','reauthorize') AND
            (status NOT IN ('pending','consuming') OR
             (backend_pair_id IS NOT NULL AND authorization_ref IS NOT NULL AND
              bound_subject_digest IS NOT NULL AND state_digest IS NOT NULL AND
              expires_at IS NOT NULL)))
        """
      )
    )

    drop(
      index(:provider_authorization_attempts, [],
        name: :provider_authorization_attempts_authorization_ref_index
      )
    )

    drop(
      index(:provider_authorization_attempts, [],
        name: :provider_authorization_attempts_backend_state_index
      )
    )

    create(
      unique_index(:provider_authorization_attempts, [:authorization_ref],
        where: "authorization_ref IS NOT NULL",
        name: :provider_authorization_attempts_authorization_ref_index
      )
    )

    create(
      unique_index(:provider_authorization_attempts, [:backend_pair_id, :state_digest],
        where: "backend_pair_id IS NOT NULL AND state_digest IS NOT NULL",
        name: :provider_authorization_attempts_backend_state_index
      )
    )

    create(
      unique_index(:provider_authorization_attempts, [:connection_id],
        where:
          "purpose IN ('initial_bind','reauthorize') AND status IN ('beginning','pending','consuming')",
        name: :provider_authorization_attempts_one_open_index
      )
    )
  end

  def down do
    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_callback_prepare_check
      )
    )

    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_callback_result_check
      )
    )

    drop(
      constraint(
        :provider_connection_events,
        :provider_connection_events_transition_from_check
      )
    )

    drop(
      constraint(
        :provider_connection_events,
        :provider_connection_events_transition_to_check
      )
    )

    create(
      constraint(
        :provider_connection_events,
        :provider_connection_events_transition_from_check,
        check:
          "transition_from IS NULL OR transition_from IN ('pending_authorization','active','refresh_required','refreshing','degraded','expired','revoking','revoked','disconnecting','disconnected')"
      )
    )

    create(
      constraint(
        :provider_connection_events,
        :provider_connection_events_transition_to_check,
        check:
          "transition_to IS NULL OR transition_to IN ('pending_authorization','active','refresh_required','refreshing','degraded','expired','revoking','revoked','disconnecting','disconnected')"
      )
    )

    drop(
      index(:provider_authorization_attempts, [],
        name: :provider_authorization_attempts_one_open_index
      )
    )

    drop(
      index(:provider_authorization_attempts, [],
        name: :provider_authorization_attempts_authorization_ref_index
      )
    )

    drop(
      index(:provider_authorization_attempts, [],
        name: :provider_authorization_attempts_backend_state_index
      )
    )

    drop(index(:provider_connections, [], name: :provider_connections_active_binding_index))

    drop(
      constraint(
        :provider_authorization_attempts,
        :provider_authorization_attempts_lifecycle_check
      )
    )

    drop(
      constraint(
        :provider_authorization_attempts,
        :provider_authorization_attempts_reservation_check
      )
    )

    drop(
      constraint(
        :provider_authorization_attempts,
        :provider_authorization_attempts_purpose_check
      )
    )

    drop(
      constraint(
        :provider_authorization_attempts,
        :provider_authorization_attempts_status_check
      )
    )

    drop(constraint(:provider_connections, :provider_connections_bound_identity_check))
    drop(constraint(:provider_connections, :provider_connections_failed_identity_check))
    drop(constraint(:provider_connections, :provider_connections_pending_identity_check))
    drop(constraint(:provider_connections, :provider_connections_status_check))
    drop(constraint(:provider_connections, :provider_connections_backend_binding_check))

    alter table(:provider_authorization_attempts) do
      modify(:backend_pair_id, :text, null: false)
      modify(:authorization_ref, :text, null: false)
      modify(:bound_subject_digest, :text, null: false)
      modify(:state_digest, :text, null: false)
      modify(:expires_at, :utc_datetime_usec, null: false)
      remove(:callback_artifact_digest)
      remove(:redirect_uri_id)
      remove(:requested_execution_identity_class)
      remove(:requested_permission_digest)
      remove(:reservation_digest)
      remove(:purpose)
    end

    alter table(:provider_connections) do
      modify(:external_account_id, :text, null: false)
      modify(:execution_identity, :text, null: false)
      modify(:authorization_backend_ref, :text, null: false)
      modify(:credential_backend_ref, :text, null: false)
      remove(:requested_execution_identity_class)
    end

    create(
      constraint(:provider_connections, :provider_connections_status_check,
        check:
          "status IN ('pending_authorization','active','refresh_required','refreshing','degraded','expired','revoking','revoked','disconnecting','disconnected')"
      )
    )

    create(
      constraint(
        :provider_authorization_attempts,
        :provider_authorization_attempts_status_check,
        check: "status IN ('pending','consuming','consumed','cancelled','expired')"
      )
    )

    create(
      constraint(:provider_connections, :provider_connections_backend_binding_check,
        check:
          "(backend_pair_id IS NULL AND authorization_backend_id IS NULL AND credential_backend_id IS NULL) OR (backend_pair_id IS NOT NULL AND authorization_backend_id IS NOT NULL AND credential_backend_id IS NOT NULL)"
      )
    )

    create(
      unique_index(
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
    )

    create(
      unique_index(:provider_authorization_attempts, [:authorization_ref],
        name: :provider_authorization_attempts_authorization_ref_index
      )
    )

    create(
      unique_index(:provider_authorization_attempts, [:backend_pair_id, :state_digest],
        name: :provider_authorization_attempts_backend_state_index
      )
    )

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_callback_prepare_check,
        check:
          "operation_class <> 'store' OR status <> 'prepared' OR (expected_credential_version IS NOT NULL AND prior_credential_ref IS NOT NULL AND prior_credential_version IS NOT NULL)"
      )
    )

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_callback_result_check,
        check: """
        operation_class <> 'store'
        OR status NOT IN ('backend_committed','cleanup_pending')
        OR (handoff_ref IS NOT NULL AND result_ref IS NOT NULL AND
            expected_credential_version IS NOT NULL AND
            result_credential_version IS NOT NULL AND
            prior_credential_ref IS NOT NULL AND prior_credential_version IS NOT NULL)
        """
      )
    )
  end
end
