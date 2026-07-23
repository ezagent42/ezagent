defmodule EzagentCore.Repo.Migrations.CloseProviderBindingCasReplace do
  use Ecto.Migration

  # Final-review Minor: 20260720002000's attempt-purpose trigger returned
  # early for every non-'store' class, so reauthorization callback
  # operations (class 'replace') received no DB-level attempt-purpose or
  # prior-credential binding validation and the trigger's 'reauthorize'
  # branch was dead code for exactly the class it was written for. The
  # application changeset and the 05000 expected-authorization trigger hold
  # the invariant in the meantime; this restores the intended DB
  # defense-in-depth for BOTH callback classes. The original migration is
  # byte-immutable; this forward replacement swaps the early-return guard
  # ('store' -> 'store','replace') and scopes the connection-generation
  # clause by class: 'store' keeps the original exact-generation binding,
  # while 'replace' (reauthorization) may bind a current-or-past
  # generation — the terminal-callback-proof path legitimately settles a
  # reauthorization operation one generation behind a
  # revoking/disconnecting connection (the terminal-insert race proof in
  # CallbackRecoveryTest). Every other validation rule is untouched.

  def up do
    execute("""
    CREATE OR REPLACE FUNCTION provider_connection_operations_enforce_attempt_purpose()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      attempt provider_authorization_attempts%ROWTYPE;
      connection provider_connections%ROWTYPE;
    BEGIN
      IF TG_OP = 'UPDATE'
         AND (OLD.attempt_ref IS DISTINCT FROM NEW.attempt_ref
              OR OLD.connection_id IS DISTINCT FROM NEW.connection_id
              OR OLD.workspace_uri IS DISTINCT FROM NEW.workspace_uri
              OR OLD.expected_connection_version IS DISTINCT FROM NEW.expected_connection_version
              OR OLD.expected_credential_version IS DISTINCT FROM NEW.expected_credential_version
              OR OLD.backend_pair_id IS DISTINCT FROM NEW.backend_pair_id
              OR OLD.prior_credential_ref IS DISTINCT FROM NEW.prior_credential_ref
              OR OLD.prior_credential_version IS DISTINCT FROM NEW.prior_credential_version
              OR OLD.operation_class IS DISTINCT FROM NEW.operation_class)
      THEN
        RAISE EXCEPTION 'provider operation attempt coordinates are immutable'
          USING ERRCODE = 'check_violation',
                CONSTRAINT = 'provider_connection_operations_attempt_purpose_check';
      END IF;

      IF NEW.operation_class NOT IN ('store', 'replace') THEN
        RETURN NEW;
      END IF;

      SELECT *
        INTO attempt
        FROM provider_authorization_attempts
       WHERE attempt_ref = NEW.attempt_ref;

      SELECT *
        INTO connection
        FROM provider_connections
       WHERE connection_id = NEW.connection_id
         AND workspace_uri = NEW.workspace_uri;

      IF NOT FOUND
         OR attempt.connection_id IS DISTINCT FROM NEW.connection_id
         OR attempt.workspace_uri IS DISTINCT FROM NEW.workspace_uri
         OR attempt.connection_version IS DISTINCT FROM NEW.expected_connection_version
         OR attempt.backend_pair_id IS DISTINCT FROM NEW.backend_pair_id
         OR (NEW.operation_class = 'store'
             AND connection.connection_version IS DISTINCT FROM NEW.expected_connection_version)
         OR (NEW.operation_class = 'replace'
             AND connection.connection_version < NEW.expected_connection_version)
         OR (NEW.expected_credential_version IS NOT NULL
             AND connection.credential_version IS DISTINCT FROM NEW.expected_credential_version)
         OR (NEW.expected_credential_version IS NULL
             AND NEW.status NOT IN ('prepared', 'backend_committed', 'cleanup_pending'))
         OR (connection.backend_pair_id IS NOT NULL
             AND connection.backend_pair_id IS DISTINCT FROM NEW.backend_pair_id)
         OR (attempt.purpose = 'initial_bind'
             AND NEW.prior_credential_ref IS NOT NULL
             AND NEW.prior_credential_version IS NOT NULL)
         OR (attempt.purpose = 'reauthorize'
             AND (
               (NEW.prior_credential_ref IS NULL
                AND NEW.prior_credential_version IS NULL)
               OR
               (NEW.prior_credential_ref IS NOT NULL
                AND NEW.prior_credential_version IS NOT NULL
                AND (NEW.prior_credential_ref IS DISTINCT FROM connection.credential_backend_ref
                     OR NEW.prior_credential_version IS DISTINCT FROM connection.credential_version))
             ))
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
  end

  def down do
    execute("""
    CREATE OR REPLACE FUNCTION provider_connection_operations_enforce_attempt_purpose()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      attempt provider_authorization_attempts%ROWTYPE;
      connection provider_connections%ROWTYPE;
    BEGIN
      IF TG_OP = 'UPDATE'
         AND (OLD.attempt_ref IS DISTINCT FROM NEW.attempt_ref
              OR OLD.connection_id IS DISTINCT FROM NEW.connection_id
              OR OLD.workspace_uri IS DISTINCT FROM NEW.workspace_uri
              OR OLD.expected_connection_version IS DISTINCT FROM NEW.expected_connection_version
              OR OLD.expected_credential_version IS DISTINCT FROM NEW.expected_credential_version
              OR OLD.backend_pair_id IS DISTINCT FROM NEW.backend_pair_id
              OR OLD.prior_credential_ref IS DISTINCT FROM NEW.prior_credential_ref
              OR OLD.prior_credential_version IS DISTINCT FROM NEW.prior_credential_version
              OR OLD.operation_class IS DISTINCT FROM NEW.operation_class)
      THEN
        RAISE EXCEPTION 'provider operation attempt coordinates are immutable'
          USING ERRCODE = 'check_violation',
                CONSTRAINT = 'provider_connection_operations_attempt_purpose_check';
      END IF;

      IF NEW.operation_class <> 'store' THEN
        RETURN NEW;
      END IF;

      SELECT *
        INTO attempt
        FROM provider_authorization_attempts
       WHERE attempt_ref = NEW.attempt_ref;

      SELECT *
        INTO connection
        FROM provider_connections
       WHERE connection_id = NEW.connection_id
         AND workspace_uri = NEW.workspace_uri;

      IF NOT FOUND
         OR attempt.connection_id IS DISTINCT FROM NEW.connection_id
         OR attempt.workspace_uri IS DISTINCT FROM NEW.workspace_uri
         OR attempt.connection_version IS DISTINCT FROM NEW.expected_connection_version
         OR attempt.backend_pair_id IS DISTINCT FROM NEW.backend_pair_id
         OR connection.connection_version IS DISTINCT FROM NEW.expected_connection_version
         OR (NEW.expected_credential_version IS NOT NULL
             AND connection.credential_version IS DISTINCT FROM NEW.expected_credential_version)
         OR (NEW.expected_credential_version IS NULL
             AND NEW.status NOT IN ('prepared', 'backend_committed', 'cleanup_pending'))
         OR (connection.backend_pair_id IS NOT NULL
             AND connection.backend_pair_id IS DISTINCT FROM NEW.backend_pair_id)
         OR (attempt.purpose = 'initial_bind'
             AND NEW.prior_credential_ref IS NOT NULL
             AND NEW.prior_credential_version IS NOT NULL)
         OR (attempt.purpose = 'reauthorize'
             AND (
               (NEW.prior_credential_ref IS NULL
                AND NEW.prior_credential_version IS NULL)
               OR
               (NEW.prior_credential_ref IS NOT NULL
                AND NEW.prior_credential_version IS NOT NULL
                AND (NEW.prior_credential_ref IS DISTINCT FROM connection.credential_backend_ref
                     OR NEW.prior_credential_version IS DISTINCT FROM connection.credential_version))
             ))
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
  end
end
