defmodule EzagentCore.Repo.Migrations.HardenProviderTask8Fences do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE provider_connections ADD COLUMN IF NOT EXISTS refresh_lease_token text"

    execute "ALTER TABLE provider_connections ADD COLUMN IF NOT EXISTS refresh_lease_until timestamp(6)"

    execute "ALTER TABLE provider_connections ADD COLUMN IF NOT EXISTS refresh_lease_version bigint NOT NULL DEFAULT 0"

    execute "ALTER TABLE provider_connections ADD COLUMN IF NOT EXISTS backend_pair_id text"

    execute "ALTER TABLE provider_connections ADD COLUMN IF NOT EXISTS authorization_backend_id text"

    execute "ALTER TABLE provider_connections ADD COLUMN IF NOT EXISTS credential_backend_id text"
    execute "ALTER TABLE provider_connection_operations ADD COLUMN IF NOT EXISTS attempt_ref uuid"

    execute "ALTER TABLE provider_connection_operations ADD COLUMN IF NOT EXISTS result_credential_version bigint"

    execute "ALTER TABLE provider_connection_operations ADD COLUMN IF NOT EXISTS prior_credential_ref text"

    execute "ALTER TABLE provider_connection_operations ADD COLUMN IF NOT EXISTS prior_credential_version bigint"

    execute "ALTER TABLE provider_connection_operations ADD COLUMN IF NOT EXISTS result_permission_digest text"

    execute "ALTER TABLE provider_connection_operations ADD COLUMN IF NOT EXISTS result_expires_at timestamp(6)"

    execute "CREATE INDEX IF NOT EXISTS provider_connection_operations_attempt_ref_index ON provider_connection_operations (attempt_ref)"

    create constraint(:provider_connections, :provider_connections_refresh_lease_pair_check,
             check:
               "(refresh_lease_token IS NULL AND refresh_lease_until IS NULL) OR (refresh_lease_token IS NOT NULL AND refresh_lease_until IS NOT NULL)"
           )

    create constraint(:provider_connections, :provider_connections_backend_binding_check,
             check:
               "(backend_pair_id IS NULL AND authorization_backend_id IS NULL AND credential_backend_id IS NULL) OR (backend_pair_id IS NOT NULL AND authorization_backend_id IS NOT NULL AND credential_backend_id IS NOT NULL)"
           )

    create constraint(
             :provider_connection_operations,
             :provider_connection_operations_callback_prepare_check,
             check:
               "operation_class <> 'store' OR status <> 'prepared' OR (expected_credential_version IS NOT NULL AND prior_credential_ref IS NOT NULL AND prior_credential_version IS NOT NULL)"
           )

    execute "ALTER TABLE provider_connection_operations DROP CONSTRAINT provider_connection_operations_callback_result_check"

    execute """
    ALTER TABLE provider_connection_operations
    ADD CONSTRAINT provider_connection_operations_callback_result_check
    CHECK (
      operation_class <> 'store'
      OR status NOT IN ('backend_committed','cleanup_pending')
      OR (
        handoff_ref IS NOT NULL
        AND result_ref IS NOT NULL
        AND expected_credential_version IS NOT NULL
        AND result_credential_version IS NOT NULL
        AND prior_credential_ref IS NOT NULL
        AND prior_credential_version IS NOT NULL
      )
    )
    """

    execute "ALTER TABLE provider_authorization_backend_records DROP CONSTRAINT provider_authorization_backend_records_lifecycle_status_check"

    execute """
    ALTER TABLE provider_authorization_backend_records
    ADD CONSTRAINT provider_authorization_backend_records_lifecycle_status_check
    CHECK (lifecycle_status IN ('pending','consumed','cancelled','expired','handoff_finalization_pending','shredded'))
    """
  end

  def down do
    drop constraint(
           :provider_connection_operations,
           :provider_connection_operations_callback_prepare_check
         )

    execute "ALTER TABLE provider_connection_operations DROP CONSTRAINT provider_connection_operations_callback_result_check"

    execute """
    ALTER TABLE provider_connection_operations
    ADD CONSTRAINT provider_connection_operations_callback_result_check
    CHECK (
      operation_class <> 'store'
      OR status NOT IN ('backend_committed','cleanup_pending')
      OR (
        handoff_ref IS NOT NULL
        AND result_ref IS NOT NULL
        AND expected_credential_version IS NOT NULL
      )
    )
    """

    execute "ALTER TABLE provider_authorization_backend_records DROP CONSTRAINT provider_authorization_backend_records_lifecycle_status_check"

    execute "UPDATE provider_authorization_backend_records SET lifecycle_status = 'consumed' WHERE lifecycle_status IN ('handoff_finalization_pending','shredded')"

    execute """
    ALTER TABLE provider_authorization_backend_records
    ADD CONSTRAINT provider_authorization_backend_records_lifecycle_status_check
    CHECK (lifecycle_status IN ('pending','consumed','cancelled','expired'))
    """

    drop constraint(:provider_connections, :provider_connections_refresh_lease_pair_check)
    drop constraint(:provider_connections, :provider_connections_backend_binding_check)
    execute "DROP INDEX IF EXISTS provider_connection_operations_attempt_ref_index"

    alter table(:provider_connection_operations) do
      remove :result_expires_at
      remove :result_permission_digest
      remove :prior_credential_version
      remove :prior_credential_ref
      remove :result_credential_version
      remove :attempt_ref
    end

    alter table(:provider_connections) do
      remove :credential_backend_id
      remove :authorization_backend_id
      remove :backend_pair_id
      remove :refresh_lease_version
      remove :refresh_lease_until
      remove :refresh_lease_token
    end
  end
end
