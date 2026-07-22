defmodule EzagentCore.Repo.Migrations.CloseProviderHandoffCleanupCoherence do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
          FROM provider_authorization_backend_records
         WHERE NOT (
           (lifecycle_status IN ('pending','cancelled','expired')
            AND handoff_ref IS NULL AND handoff_ciphertext IS NULL AND shredded_at IS NULL)
           OR
           (lifecycle_status IN ('consumed','handoff_finalization_pending')
            AND handoff_ref IS NOT NULL AND handoff_ciphertext IS NOT NULL
            AND shredded_at IS NULL)
           OR
           (lifecycle_status = 'shredded'
            AND handoff_ref IS NOT NULL AND handoff_ciphertext IS NULL
            AND shredded_at IS NOT NULL)
         )
      ) THEN
        RAISE EXCEPTION 'incoherent provider authorization handoff lifecycle'
          USING ERRCODE = 'check_violation';
      END IF;

      IF EXISTS (
        SELECT 1
          FROM provider_connection_operations
         WHERE NOT (
           (status NOT IN ('cleanup_pending','finalized')
            AND provider_cleanup_status = 'not_required'
            AND credential_cleanup_status = 'not_required'
            AND provider_cleanup_error_code IS NULL
            AND credential_cleanup_error_code IS NULL)
           OR
           (status = 'cleanup_pending'
            AND (provider_cleanup_status <> 'not_required'
                 OR credential_cleanup_status <> 'not_required')
            AND (provider_cleanup_error_code IS NULL
                 OR provider_cleanup_status = 'pending')
            AND (credential_cleanup_error_code IS NULL
                 OR credential_cleanup_status = 'pending'))
           OR
           (status = 'finalized'
            AND provider_cleanup_status IN ('confirmed','not_required')
            AND credential_cleanup_status IN ('confirmed','not_required')
            AND provider_cleanup_error_code IS NULL
            AND credential_cleanup_error_code IS NULL)
         )
      ) THEN
        RAISE EXCEPTION 'incoherent provider operation cleanup lifecycle'
          USING ERRCODE = 'check_violation';
      END IF;
    END;
    $$
    """)

    execute("""
    ALTER TABLE provider_authorization_backend_records
    ADD CONSTRAINT provider_authorization_backend_records_handoff_coherence_check
    CHECK (
      (lifecycle_status IN ('pending','cancelled','expired')
       AND handoff_ref IS NULL AND handoff_ciphertext IS NULL AND shredded_at IS NULL)
      OR
      (lifecycle_status IN ('consumed','handoff_finalization_pending')
       AND handoff_ref IS NOT NULL AND handoff_ciphertext IS NOT NULL
       AND shredded_at IS NULL)
      OR
      (lifecycle_status = 'shredded'
       AND handoff_ref IS NOT NULL AND handoff_ciphertext IS NULL
       AND shredded_at IS NOT NULL)
    ) NOT VALID
    """)

    execute("""
    ALTER TABLE provider_authorization_backend_records
    VALIDATE CONSTRAINT provider_authorization_backend_records_handoff_coherence_check
    """)

    execute("""
    ALTER TABLE provider_connection_operations
    ADD CONSTRAINT provider_connection_operations_cleanup_coherence_check
    CHECK (
      (status NOT IN ('cleanup_pending','finalized')
       AND provider_cleanup_status = 'not_required'
       AND credential_cleanup_status = 'not_required'
       AND provider_cleanup_error_code IS NULL
       AND credential_cleanup_error_code IS NULL)
      OR
      (status = 'cleanup_pending'
       AND (provider_cleanup_status <> 'not_required'
            OR credential_cleanup_status <> 'not_required')
       AND (provider_cleanup_error_code IS NULL
            OR provider_cleanup_status = 'pending')
       AND (credential_cleanup_error_code IS NULL
            OR credential_cleanup_status = 'pending'))
      OR
      (status = 'finalized'
       AND provider_cleanup_status IN ('confirmed','not_required')
       AND credential_cleanup_status IN ('confirmed','not_required')
       AND provider_cleanup_error_code IS NULL
       AND credential_cleanup_error_code IS NULL)
    ) NOT VALID
    """)

    execute("""
    ALTER TABLE provider_connection_operations
    VALIDATE CONSTRAINT provider_connection_operations_cleanup_coherence_check
    """)
  end

  def down do
    execute("""
    ALTER TABLE provider_connection_operations
    DROP CONSTRAINT provider_connection_operations_cleanup_coherence_check
    """)

    execute("""
    ALTER TABLE provider_authorization_backend_records
    DROP CONSTRAINT provider_authorization_backend_records_handoff_coherence_check
    """)
  end
end
