defmodule EzagentCore.Repo.Migrations.CloseProviderResultOwnershipStages do
  use Ecto.Migration

  def up do
    alter table(:provider_connection_operations) do
      add(:expected_authorization_ref, :text)
      add(:expected_authorization_version, :bigint)
    end

    # Classify before writing anything. In particular, a completed callback result is
    # provenance, not proof of its own provenance: it must either bind to its exact
    # attempt or be a genuinely legacy post-CAS row still reflected by the connection.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
          FROM provider_connection_operations operation
         WHERE operation.operation_class IN ('store','replace','refresh')
           AND ((operation.result_ref IS NULL) <> (operation.result_credential_version IS NULL))
      ) THEN
        RAISE EXCEPTION 'partial credential ownership tuple'
          USING ERRCODE = 'check_violation';
      END IF;

      IF EXISTS (
        SELECT 1
          FROM provider_connection_operations operation
         WHERE operation.operation_class IN ('store','replace','refresh')
           AND operation.status = 'fenced'
           AND (
             operation.provider_result_ref IS NULL AND operation.handoff_ref IS NULL
             AND operation.result_permission_digest IS NULL
             AND operation.result_expires_at IS NULL
             AND operation.result_external_account_id IS NULL
             AND operation.result_display_login IS NULL
             AND operation.result_execution_identity IS NULL
             AND operation.result_authorization_ref IS NULL
             AND operation.result_authorization_version IS NULL
             AND operation.result_ref IS NULL
             AND operation.result_credential_version IS NULL
           ) IS NOT TRUE
      ) THEN
        RAISE EXCEPTION 'fenced operation carries external ownership'
          USING ERRCODE = 'check_violation';
      END IF;

      IF EXISTS (
        SELECT 1
          FROM provider_connection_operations operation
          JOIN provider_connections connection
            ON connection.connection_id = operation.connection_id
           AND connection.workspace_uri = operation.workspace_uri
         WHERE operation.operation_class IN ('store','replace')
           AND operation.status <> 'fenced'
           AND (
             (operation.status = 'prepared'
              AND operation.provider_result_ref IS NULL AND operation.handoff_ref IS NULL
              AND operation.result_permission_digest IS NULL
              AND operation.result_expires_at IS NULL
              AND operation.result_external_account_id IS NULL
              AND operation.result_display_login IS NULL
              AND operation.result_execution_identity IS NULL
              AND operation.result_authorization_ref IS NULL
              AND operation.result_authorization_version IS NULL
              AND operation.result_ref IS NULL
              AND operation.result_credential_version IS NULL)
             OR
             (operation.provider_result_ref IS NOT NULL AND operation.handoff_ref IS NOT NULL
              AND operation.result_external_account_id IS NOT NULL
              AND operation.result_display_login IS NOT NULL
              AND operation.result_execution_identity IS NOT NULL
              AND operation.result_authorization_ref IS NOT NULL
              AND operation.result_authorization_version > 0
              AND (
                operation.result_permission_digest IS NOT NULL
                OR (
                  operation.attempt_ref IS NULL
                  AND operation.status IN ('connection_committed','finalized')
                  AND connection.status = 'active'
                  AND connection.connection_version = operation.expected_connection_version + 1
                  AND connection.authorization_backend_ref = operation.result_authorization_ref
                  AND connection.authorization_version = operation.result_authorization_version
                  AND connection.permission_digest IS NOT NULL
                )
              )
              AND (
                (operation.status = 'prepared'
                 AND operation.result_ref IS NULL
                 AND operation.result_credential_version IS NULL)
                OR
                (operation.status IN ('backend_committed','connection_committed','finalized','cleanup_pending')
                 AND operation.result_ref IS NOT NULL
                 AND operation.result_credential_version IS NOT NULL)
              ))
           ) IS NOT TRUE
      ) THEN
        RAISE EXCEPTION 'partial callback provider ownership tuple'
          USING ERRCODE = 'check_violation';
      END IF;

      IF EXISTS (
        SELECT 1
          FROM provider_connection_operations operation
          JOIN provider_connections connection
            ON connection.connection_id = operation.connection_id
           AND connection.workspace_uri = operation.workspace_uri
         WHERE operation.operation_class = 'refresh'
           AND operation.status <> 'fenced'
           AND (
             (operation.status = 'prepared'
              AND operation.provider_result_ref IS NULL AND operation.handoff_ref IS NULL
              AND operation.result_permission_digest IS NULL
              AND operation.result_expires_at IS NULL
              AND operation.result_external_account_id IS NULL
              AND operation.result_display_login IS NULL
              AND operation.result_execution_identity IS NULL
              AND operation.result_authorization_ref IS NULL
              AND operation.result_authorization_version IS NULL
              AND operation.result_ref IS NULL
              AND operation.result_credential_version IS NULL)
             OR
             (operation.provider_result_ref IS NOT NULL AND operation.handoff_ref IS NOT NULL
              AND operation.result_external_account_id IS NULL
              AND operation.result_display_login IS NULL
              AND operation.result_execution_identity IS NULL
              AND operation.result_authorization_ref IS NULL
              AND operation.result_authorization_version IS NULL
              AND (
                operation.result_permission_digest IS NOT NULL
                OR (
                  operation.status IN ('connection_committed','finalized')
                  AND connection.status = 'active'
                  AND connection.connection_version = operation.expected_connection_version + 2
                  AND connection.permission_digest IS NOT NULL
                )
              )
              AND (
                (operation.status = 'prepared'
                 AND operation.result_ref IS NULL
                 AND operation.result_credential_version IS NULL)
                OR
                (operation.status IN ('backend_committed','connection_committed','finalized','cleanup_pending')
                 AND operation.result_ref IS NOT NULL
                 AND operation.result_credential_version IS NOT NULL)
              ))
           ) IS NOT TRUE
      ) THEN
        RAISE EXCEPTION 'partial refresh provider ownership tuple'
          USING ERRCODE = 'check_violation';
      END IF;

      IF EXISTS (
        SELECT 1
          FROM provider_connection_operations operation
          JOIN provider_connections connection
            ON connection.connection_id = operation.connection_id
           AND connection.workspace_uri = operation.workspace_uri
         WHERE operation.operation_class IN ('store','replace')
           AND (
             (operation.attempt_ref IS NOT NULL AND EXISTS (
               SELECT 1
                 FROM provider_authorization_attempts attempt
                WHERE attempt.attempt_ref = operation.attempt_ref
                  AND (operation.result_authorization_ref IS NULL
                       OR attempt.authorization_ref = operation.result_authorization_ref)
                  AND attempt.connection_id = operation.connection_id
                  AND attempt.workspace_uri = operation.workspace_uri
                  AND attempt.backend_pair_id = operation.backend_pair_id
                  AND attempt.connection_version = operation.expected_connection_version
                  AND (
                    (connection.connection_version = operation.expected_connection_version
                     AND connection.authorization_version >= 0)
                    OR
                    (connection.connection_version IN (
                       operation.expected_connection_version + 1,
                       operation.expected_connection_version + 2
                     )
                     AND (
                       (connection.authorization_version >= 0
                        AND (connection.authorization_backend_ref IS NULL
                             OR connection.authorization_backend_ref = attempt.authorization_ref))
                       OR
                       (connection.authorization_version >= 0
                        AND operation.operation_class = 'replace'
                        AND attempt.purpose = 'reauthorize'
                        AND operation.status IN ('fenced','cleanup_pending')
                        AND connection.status IN (
                          'expired','revoking','revoked','disconnecting','disconnected'
                        ))
                       OR
                       (operation.provider_result_ref IS NOT NULL
                        AND connection.authorization_backend_ref = operation.result_authorization_ref
                        AND connection.authorization_version = operation.result_authorization_version)
                     ))
                  )
             ))
             OR
             (operation.attempt_ref IS NULL
              AND operation.provider_result_ref IS NOT NULL
              AND operation.status IN ('connection_committed','finalized')
              AND connection.status = 'active'
              AND connection.connection_version = operation.expected_connection_version + 1
              AND connection.authorization_backend_ref = operation.result_authorization_ref
              AND connection.authorization_version = operation.result_authorization_version)
           ) IS NOT TRUE
      ) THEN
        RAISE EXCEPTION 'ambiguous operation authorization reservation'
          USING ERRCODE = 'check_violation';
      END IF;

      IF EXISTS (
        SELECT 1
          FROM provider_connection_operations operation
          JOIN provider_connections connection
            ON connection.connection_id = operation.connection_id
           AND connection.workspace_uri = operation.workspace_uri
         WHERE operation.operation_class = 'refresh'
           AND NOT (
             connection.authorization_backend_ref IS NOT NULL
             AND connection.authorization_version IS NOT NULL
             AND (
               (operation.status IN ('prepared','backend_committed','cleanup_pending')
                AND connection.status = 'refreshing'
                AND connection.connection_version IN (
                  operation.expected_connection_version,
                  operation.expected_connection_version + 1
                ))
               OR
               (operation.status IN ('connection_committed','finalized')
                AND connection.status = 'active'
                AND connection.connection_version = operation.expected_connection_version + 2)
               OR
               (operation.status = 'fenced'
                AND connection.connection_version IN (
                  operation.expected_connection_version,
                  operation.expected_connection_version + 1,
                  operation.expected_connection_version + 2
                ))
             )
           )
      ) THEN
        RAISE EXCEPTION 'ambiguous operation authorization reservation'
          USING ERRCODE = 'check_violation';
      END IF;
    END;
    $$
    """)

    execute("""
    UPDATE provider_connection_operations AS operation
       SET expected_authorization_ref = CASE
             WHEN operation.operation_class IN ('store','replace')
                  AND operation.attempt_ref IS NOT NULL
             THEN (
               SELECT attempt.authorization_ref
                 FROM provider_authorization_attempts attempt
                WHERE attempt.attempt_ref = operation.attempt_ref
             )
             WHEN operation.operation_class IN ('store','replace')
             THEN operation.result_authorization_ref
             ELSE connection.authorization_backend_ref
           END,
           expected_authorization_version = CASE
             WHEN operation.operation_class IN ('store','replace')
                  AND connection.connection_version = operation.expected_connection_version + 1
                  AND operation.provider_result_ref IS NOT NULL
                  AND connection.authorization_backend_ref = operation.result_authorization_ref
                  AND connection.authorization_version = operation.result_authorization_version
             THEN connection.authorization_version - 1
             ELSE connection.authorization_version
           END,
           result_permission_digest = CASE
             WHEN operation.provider_result_ref IS NOT NULL
                  AND operation.result_permission_digest IS NULL
             THEN connection.permission_digest
             ELSE operation.result_permission_digest
           END
      FROM provider_connections AS connection
     WHERE connection.connection_id = operation.connection_id
       AND connection.workspace_uri = operation.workspace_uri
       AND operation.operation_class IN ('store','replace','refresh')
    """)

    execute("""
    DO $$
    DECLARE
      conflicting RECORD;
    BEGIN
      SELECT id, correlation_id
        INTO conflicting
        FROM provider_connection_operations
       WHERE NOT (#{ownership_stage_check()})
       LIMIT 1;

      IF FOUND THEN
        RAISE EXCEPTION 'ownership-stage backfill conflict for operation % correlation %',
          conflicting.id, conflicting.correlation_id
          USING ERRCODE = 'check_violation';
      END IF;
    END;
    $$
    """)

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_expected_authorization_check,
        check: """
        operation_class NOT IN ('store','replace','refresh')
        OR (expected_authorization_ref IS NOT NULL
            AND expected_authorization_version IS NOT NULL
            AND expected_authorization_version >= 0)
        """
      )
    )

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_ownership_stage_check,
        check: ownership_stage_check()
      )
    )

    execute("""
    CREATE FUNCTION provider_connection_operations_enforce_ownership_immutability()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF TG_OP = 'UPDATE'
         AND (OLD.expected_authorization_ref IS DISTINCT FROM NEW.expected_authorization_ref
              OR OLD.expected_authorization_version IS DISTINCT FROM NEW.expected_authorization_version
              OR (OLD.provider_result_ref IS NOT NULL AND (
                OLD.provider_result_ref IS DISTINCT FROM NEW.provider_result_ref
                OR OLD.handoff_ref IS DISTINCT FROM NEW.handoff_ref
                OR OLD.result_permission_digest IS DISTINCT FROM NEW.result_permission_digest
                OR OLD.result_expires_at IS DISTINCT FROM NEW.result_expires_at
                OR OLD.result_external_account_id IS DISTINCT FROM NEW.result_external_account_id
                OR OLD.result_display_login IS DISTINCT FROM NEW.result_display_login
                OR OLD.result_execution_identity IS DISTINCT FROM NEW.result_execution_identity
                OR OLD.result_authorization_ref IS DISTINCT FROM NEW.result_authorization_ref
                OR OLD.result_authorization_version IS DISTINCT FROM NEW.result_authorization_version
              ))
              OR (OLD.result_ref IS NOT NULL AND (
                OLD.result_ref IS DISTINCT FROM NEW.result_ref
                OR OLD.result_credential_version IS DISTINCT FROM NEW.result_credential_version
              )))
      THEN
        RAISE EXCEPTION 'provider operation ownership coordinates are immutable'
          USING ERRCODE = 'check_violation',
                CONSTRAINT = 'provider_connection_operations_ownership_immutability_check';
      END IF;

      IF NEW.operation_class IN ('store','replace')
         AND (TG_OP = 'INSERT'
              OR OLD.expected_authorization_ref IS DISTINCT FROM NEW.expected_authorization_ref
              OR OLD.expected_authorization_version IS DISTINCT FROM NEW.expected_authorization_version
              OR OLD.attempt_ref IS DISTINCT FROM NEW.attempt_ref
              OR OLD.connection_id IS DISTINCT FROM NEW.connection_id
              OR OLD.workspace_uri IS DISTINCT FROM NEW.workspace_uri
              OR OLD.backend_pair_id IS DISTINCT FROM NEW.backend_pair_id
              OR OLD.expected_connection_version IS DISTINCT FROM NEW.expected_connection_version)
         AND NOT EXISTS (
           SELECT 1
             FROM provider_authorization_attempts attempt
             JOIN provider_connections connection
               ON connection.connection_id = attempt.connection_id
              AND connection.workspace_uri = attempt.workspace_uri
            WHERE attempt.attempt_ref = NEW.attempt_ref
              AND attempt.authorization_ref = NEW.expected_authorization_ref
              AND attempt.connection_id = NEW.connection_id
              AND attempt.workspace_uri = NEW.workspace_uri
              AND attempt.backend_pair_id = NEW.backend_pair_id
              AND attempt.connection_version = NEW.expected_connection_version
              AND (
                 (connection.connection_version IN (
                   NEW.expected_connection_version,
                   NEW.expected_connection_version + 1,
                   NEW.expected_connection_version + 2
                 )
                 AND connection.authorization_version = NEW.expected_authorization_version
                )
                OR
                (connection.connection_version = NEW.expected_connection_version + 1
                 AND NEW.provider_result_ref IS NOT NULL
                 AND connection.authorization_backend_ref = NEW.result_authorization_ref
                 AND connection.authorization_version = NEW.result_authorization_version
                 AND NEW.result_authorization_ref = NEW.expected_authorization_ref
                 AND NEW.result_authorization_version = NEW.expected_authorization_version + 1)
              )
         )
      THEN
        RAISE EXCEPTION 'provider operation expected authorization mismatch'
          USING ERRCODE = 'check_violation',
                CONSTRAINT = 'provider_connection_operations_expected_authorization_binding_check';
      END IF;

      IF NEW.operation_class = 'refresh'
         AND (TG_OP = 'INSERT'
              OR OLD.expected_authorization_ref IS DISTINCT FROM NEW.expected_authorization_ref
              OR OLD.expected_authorization_version IS DISTINCT FROM NEW.expected_authorization_version
              OR OLD.connection_id IS DISTINCT FROM NEW.connection_id
              OR OLD.workspace_uri IS DISTINCT FROM NEW.workspace_uri
              OR OLD.backend_pair_id IS DISTINCT FROM NEW.backend_pair_id
              OR OLD.expected_connection_version IS DISTINCT FROM NEW.expected_connection_version)
         AND NOT EXISTS (
           SELECT 1
             FROM provider_connections connection
            WHERE connection.connection_id = NEW.connection_id
              AND connection.workspace_uri = NEW.workspace_uri
              AND connection.backend_pair_id = NEW.backend_pair_id
              AND connection.authorization_backend_ref = NEW.expected_authorization_ref
              AND connection.authorization_version = NEW.expected_authorization_version
              AND connection.connection_version IN (
                NEW.expected_connection_version,
                NEW.expected_connection_version + 1,
                NEW.expected_connection_version + 2
              )
         )
      THEN
        RAISE EXCEPTION 'provider refresh expected authorization mismatch'
          USING ERRCODE = 'check_violation',
                CONSTRAINT = 'provider_connection_operations_expected_authorization_binding_check';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER provider_connection_operations_ownership_immutability_trigger
    BEFORE INSERT OR UPDATE OF expected_authorization_ref, expected_authorization_version,
      provider_result_ref, handoff_ref, result_permission_digest,
      result_expires_at, result_external_account_id, result_display_login,
      result_execution_identity, result_authorization_ref, result_authorization_version,
      result_ref, result_credential_version, attempt_ref, connection_id, workspace_uri,
      backend_pair_id, expected_connection_version
    ON provider_connection_operations
    FOR EACH ROW
    EXECUTE FUNCTION provider_connection_operations_enforce_ownership_immutability()
    """)
  end

  def down do
    execute(
      "DROP TRIGGER provider_connection_operations_ownership_immutability_trigger ON provider_connection_operations"
    )

    execute("DROP FUNCTION provider_connection_operations_enforce_ownership_immutability()")

    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_ownership_stage_check
      )
    )

    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_expected_authorization_check
      )
    )

    alter table(:provider_connection_operations) do
      remove(:expected_authorization_version)
      remove(:expected_authorization_ref)
    end
  end

  defp ownership_stage_check do
    """
    operation_class NOT IN ('store','replace','refresh')
    OR status NOT IN ('prepared','backend_committed','connection_committed','finalized','fenced','cleanup_pending')
    OR (
      (status IN ('prepared','fenced') AND (
        (provider_result_ref IS NULL AND handoff_ref IS NULL
         AND result_permission_digest IS NULL AND result_expires_at IS NULL
         AND result_external_account_id IS NULL AND result_display_login IS NULL
         AND result_execution_identity IS NULL AND result_authorization_ref IS NULL
         AND result_authorization_version IS NULL AND result_ref IS NULL
         AND result_credential_version IS NULL)
        OR
        (status = 'prepared'
         AND result_ref IS NULL AND result_credential_version IS NULL
         AND provider_result_ref IS NOT NULL AND handoff_ref IS NOT NULL
         AND result_permission_digest IS NOT NULL
         AND (
           (operation_class IN ('store','replace')
            AND result_external_account_id IS NOT NULL AND result_display_login IS NOT NULL
            AND result_execution_identity IS NOT NULL
            AND result_authorization_ref = expected_authorization_ref
            AND result_authorization_version = expected_authorization_version + 1)
           OR
           (operation_class = 'refresh'
            AND result_external_account_id IS NULL AND result_display_login IS NULL
            AND result_execution_identity IS NULL AND result_authorization_ref IS NULL
            AND result_authorization_version IS NULL)
         ))
      ))
      OR
      (status IN ('backend_committed','connection_committed','finalized','cleanup_pending')
       AND provider_result_ref IS NOT NULL AND handoff_ref IS NOT NULL
       AND result_permission_digest IS NOT NULL AND result_ref IS NOT NULL
       AND result_credential_version IS NOT NULL
       AND (
         (operation_class IN ('store','replace')
          AND result_external_account_id IS NOT NULL AND result_display_login IS NOT NULL
          AND result_execution_identity IS NOT NULL
          AND result_authorization_ref = expected_authorization_ref
          AND result_authorization_version = expected_authorization_version + 1)
         OR
         (operation_class = 'refresh'
          AND result_external_account_id IS NULL AND result_display_login IS NULL
          AND result_execution_identity IS NULL AND result_authorization_ref IS NULL
          AND result_authorization_version IS NULL)
       ))
    )
    """
  end
end
