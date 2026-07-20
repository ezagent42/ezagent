defmodule EzagentCore.Repo.Migrations.CloseProviderBindingCas do
  use Ecto.Migration

  def up do
    alter table(:provider_connection_operations) do
      add(:result_external_account_id, :text)
      add(:result_display_login, :text)
      add(:result_execution_identity, :text)
      add(:result_authorization_ref, :text)
      add(:result_authorization_version, :bigint)
      add(:provider_result_ref, :text)
    end

    execute("""
    UPDATE provider_connection_operations AS operation
       SET result_external_account_id = connection.external_account_id,
           result_display_login = connection.display_login,
           result_execution_identity = connection.execution_identity,
           result_authorization_ref = connection.authorization_backend_ref,
           result_authorization_version = connection.authorization_version,
           provider_result_ref = COALESCE(operation.handoff_ref, operation.result_ref)
      FROM provider_connections AS connection
     WHERE connection.connection_id = operation.connection_id
       AND operation.operation_class IN ('store','replace')
       AND operation.status IN ('backend_committed','connection_committed','finalized','cleanup_pending')
    """)

    create(
      unique_index(:provider_connections, [:connection_id, :workspace_uri],
        name: :provider_connections_id_workspace_index
      )
    )

    execute("""
    ALTER TABLE provider_authorization_attempts
      ADD CONSTRAINT provider_authorization_attempts_connection_workspace_fkey
      FOREIGN KEY (connection_id, workspace_uri)
      REFERENCES provider_connections(connection_id, workspace_uri)
      NOT VALID
    """)

    execute("""
    ALTER TABLE provider_connection_operations
      ADD CONSTRAINT provider_connection_operations_connection_workspace_fkey
      FOREIGN KEY (connection_id, workspace_uri)
      REFERENCES provider_connections(connection_id, workspace_uri)
      NOT VALID
    """)

    execute("""
    ALTER TABLE provider_connection_events
      ADD CONSTRAINT provider_connection_events_connection_workspace_fkey
      FOREIGN KEY (connection_id, workspace_uri)
      REFERENCES provider_connections(connection_id, workspace_uri)
      NOT VALID
    """)

    execute("""
    ALTER TABLE provider_authorization_attempts
      VALIDATE CONSTRAINT provider_authorization_attempts_connection_workspace_fkey
    """)

    execute("""
    ALTER TABLE provider_connection_operations
      VALIDATE CONSTRAINT provider_connection_operations_connection_workspace_fkey
    """)

    execute("""
    ALTER TABLE provider_connection_events
      VALIDATE CONSTRAINT provider_connection_events_connection_workspace_fkey
    """)

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_normalized_callback_result_check,
        check: """
        operation_class NOT IN ('store','replace')
        OR status NOT IN ('backend_committed','connection_committed','finalized','cleanup_pending')
        OR (result_external_account_id IS NOT NULL AND
            result_execution_identity IS NOT NULL AND
            result_authorization_ref IS NOT NULL AND
            result_authorization_version IS NOT NULL AND
            result_ref IS NOT NULL AND result_credential_version IS NOT NULL AND
            provider_result_ref IS NOT NULL)
        """
      )
    )

    execute("""
    CREATE FUNCTION provider_connections_enforce_immutable_binding()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF OLD.workspace_uri IS DISTINCT FROM NEW.workspace_uri
         OR OLD.owner_uri IS DISTINCT FROM NEW.owner_uri
         OR OLD.provider_id IS DISTINCT FROM NEW.provider_id
         OR OLD.governed_host IS DISTINCT FROM NEW.governed_host
         OR OLD.acquisition_method IS DISTINCT FROM NEW.acquisition_method
         OR (OLD.external_account_id IS NOT NULL
             AND OLD.external_account_id IS DISTINCT FROM NEW.external_account_id)
         OR (OLD.execution_identity IS NOT NULL
             AND OLD.execution_identity IS DISTINCT FROM NEW.execution_identity)
         OR ((OLD.external_account_id IS NULL OR OLD.execution_identity IS NULL)
             AND NOT (
               OLD.status = 'pending_authorization'
               AND NEW.status IN ('active','failed')
             )
             AND (OLD.external_account_id IS DISTINCT FROM NEW.external_account_id
                  OR OLD.execution_identity IS DISTINCT FROM NEW.execution_identity))
      THEN
        RAISE EXCEPTION 'provider connection immutable identity drift'
          USING ERRCODE = 'check_violation',
                CONSTRAINT = 'provider_connections_immutable_binding_check';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER provider_connections_immutable_binding_trigger
    BEFORE UPDATE ON provider_connections
    FOR EACH ROW
    EXECUTE FUNCTION provider_connections_enforce_immutable_binding()
    """)

    execute("""
    CREATE FUNCTION provider_authorization_attempts_enforce_immutable_coordinates()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF OLD.attempt_ref IS DISTINCT FROM NEW.attempt_ref
         OR OLD.connection_id IS DISTINCT FROM NEW.connection_id
         OR OLD.workspace_uri IS DISTINCT FROM NEW.workspace_uri
         OR OLD.connection_version IS DISTINCT FROM NEW.connection_version
         OR OLD.purpose IS DISTINCT FROM NEW.purpose
      THEN
        RAISE EXCEPTION 'provider authorization attempt immutable coordinate drift'
          USING ERRCODE = 'check_violation',
                CONSTRAINT = 'provider_authorization_attempts_immutable_coordinates_check';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER provider_authorization_attempts_immutable_coordinates_trigger
    BEFORE UPDATE OF attempt_ref, connection_id, workspace_uri, connection_version, purpose
    ON provider_authorization_attempts
    FOR EACH ROW
    EXECUTE FUNCTION provider_authorization_attempts_enforce_immutable_coordinates()
    """)

    execute("""
    CREATE FUNCTION provider_connection_operations_enforce_attempt_purpose()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      attempt provider_authorization_attempts%ROWTYPE;
    BEGIN
      IF NEW.operation_class <> 'store' THEN
        RETURN NEW;
      END IF;

      SELECT *
        INTO attempt
        FROM provider_authorization_attempts
       WHERE attempt_ref = NEW.attempt_ref;

      IF NOT FOUND
         OR attempt.connection_id IS DISTINCT FROM NEW.connection_id
         OR attempt.workspace_uri IS DISTINCT FROM NEW.workspace_uri
         OR (attempt.purpose = 'initial_bind'
             AND NEW.prior_credential_ref IS NOT NULL
             AND NEW.prior_credential_version IS NOT NULL)
         OR (attempt.purpose = 'reauthorize'
             AND NEW.prior_credential_ref IS NULL
             AND NEW.prior_credential_version IS NULL)
         OR attempt.purpose NOT IN ('initial_bind', 'reauthorize')
      THEN
        RAISE EXCEPTION 'provider operation attempt purpose mismatch'
          USING ERRCODE = 'check_violation',
                CONSTRAINT = 'provider_connection_operations_attempt_purpose_check';
      END IF;

      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER provider_connection_operations_attempt_purpose_trigger
    BEFORE INSERT OR UPDATE OF attempt_ref, prior_credential_ref,
      prior_credential_version, connection_id, workspace_uri, operation_class
    ON provider_connection_operations
    FOR EACH ROW
    EXECUTE FUNCTION provider_connection_operations_enforce_attempt_purpose()
    """)
  end

  def down do
    execute("""
    DROP TRIGGER provider_connection_operations_attempt_purpose_trigger
    ON provider_connection_operations
    """)

    execute("DROP FUNCTION provider_connection_operations_enforce_attempt_purpose()")

    execute("""
    DROP TRIGGER provider_authorization_attempts_immutable_coordinates_trigger
    ON provider_authorization_attempts
    """)

    execute("DROP FUNCTION provider_authorization_attempts_enforce_immutable_coordinates()")

    execute("""
    DROP TRIGGER provider_connections_immutable_binding_trigger
    ON provider_connections
    """)

    execute("DROP FUNCTION provider_connections_enforce_immutable_binding()")

    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_normalized_callback_result_check
      )
    )

    execute("""
    ALTER TABLE provider_connection_events
      DROP CONSTRAINT provider_connection_events_connection_workspace_fkey
    """)

    execute("""
    ALTER TABLE provider_connection_operations
      DROP CONSTRAINT provider_connection_operations_connection_workspace_fkey
    """)

    execute("""
    ALTER TABLE provider_authorization_attempts
      DROP CONSTRAINT provider_authorization_attempts_connection_workspace_fkey
    """)

    drop(index(:provider_connections, [], name: :provider_connections_id_workspace_index))

    alter table(:provider_connection_operations) do
      remove(:provider_result_ref)
      remove(:result_authorization_version)
      remove(:result_authorization_ref)
      remove(:result_execution_identity)
      remove(:result_display_login)
      remove(:result_external_account_id)
    end
  end
end
