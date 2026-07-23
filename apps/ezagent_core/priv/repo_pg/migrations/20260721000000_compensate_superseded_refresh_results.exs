defmodule EzagentCore.Repo.Migrations.CompensateSupersededRefreshResults do
  use Ecto.Migration

  # Final-review Important (system-closure acceptance): a provider-owned
  # `prepared` refresh operation superseded by a successor refresh
  # (`refreshing -> refreshing` advances the connection generation) had NO
  # legal durable convergence. Every cleanup/final state in the 04000/05000
  # algebra required the credential result tuple (`result_ref` +
  # `result_credential_version`) that this crash window never produced, and
  # `fenced` requires the all-NULL proof — so the journaled provider-minted
  # credential sealed behind `handoff_ref` could never be routed to
  # `discard_refresh_result/1`, and the row retried its lost generation
  # forever.
  #
  # Extend the two ownership CHECKs with exactly one new legal shape each,
  # scoped to `operation_class = 'refresh'`; every previously-valid shape
  # stays valid and every previously-invalid shape still violates.
  #
  # New legal shapes (refresh only):
  #   cleanup_pending (obligation): provider-owned tuple
  #     (provider_result_ref, handoff_ref, result_permission_digest NOT NULL)
  #     + result_ref/result_credential_version NULL
  #     + provider_cleanup_status IN ('pending','confirmed')
  #   finalized (compensated terminal): the same provider-owned tuple
  #     + result tuple NULL + provider_cleanup_status = 'confirmed'
  #     (credential side 'not_required' through the untouched cleanup
  #     coherence constraint)

  def up do
    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_durable_ownership_check
      )
    )

    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_ownership_stage_check
      )
    )

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_durable_ownership_check,
        check: """
        status NOT IN ('prepared','backend_committed','connection_committed','finalized','fenced','cleanup_pending')
        OR (
          (
          (status = 'finalized' AND next_recovery_at IS NULL)
          OR
          (status IN ('prepared','backend_committed','connection_committed','fenced','cleanup_pending')
           AND next_recovery_at IS NOT NULL)
          )
          AND (
          operation_class NOT IN ('store','replace')
          OR status NOT IN ('backend_committed','connection_committed','finalized','cleanup_pending')
          OR (result_external_account_id IS NOT NULL AND
              result_execution_identity IS NOT NULL AND
              result_authorization_ref IS NOT NULL AND
              result_authorization_version IS NOT NULL AND
              result_ref IS NOT NULL AND result_credential_version IS NOT NULL AND
              provider_result_ref IS NOT NULL)
          )
          AND (
          operation_class <> 'refresh'
          OR status NOT IN ('backend_committed','connection_committed','finalized','cleanup_pending')
          OR (provider_result_ref IS NOT NULL AND
              result_ref IS NOT NULL AND result_credential_version IS NOT NULL)
          OR (status = 'cleanup_pending' AND provider_cleanup_status = 'not_required')
          OR (operation_class = 'refresh' AND status = 'cleanup_pending'
              AND provider_result_ref IS NOT NULL AND handoff_ref IS NOT NULL
              AND result_ref IS NULL AND result_credential_version IS NULL
              AND provider_cleanup_status IN ('pending','confirmed'))
          OR (operation_class = 'refresh' AND status = 'finalized'
              AND provider_result_ref IS NOT NULL AND handoff_ref IS NOT NULL
              AND result_ref IS NULL AND result_credential_version IS NULL
              AND provider_cleanup_status = 'confirmed')
          )
          AND (
          status <> 'cleanup_pending'
          OR provider_cleanup_status <> 'not_required'
          OR credential_cleanup_status <> 'not_required'
          )
        )
        """
      )
    )

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_ownership_stage_check,
        check: """
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
          OR
          (status = 'cleanup_pending' AND operation_class = 'refresh'
           AND provider_result_ref IS NOT NULL AND handoff_ref IS NOT NULL
           AND result_permission_digest IS NOT NULL
           AND result_ref IS NULL AND result_credential_version IS NULL
           AND result_external_account_id IS NULL AND result_display_login IS NULL
           AND result_execution_identity IS NULL AND result_authorization_ref IS NULL
           AND result_authorization_version IS NULL
           AND provider_cleanup_status IN ('pending','confirmed'))
          OR
          (status = 'finalized' AND operation_class = 'refresh'
           AND provider_result_ref IS NOT NULL AND handoff_ref IS NOT NULL
           AND result_permission_digest IS NOT NULL
           AND result_ref IS NULL AND result_credential_version IS NULL
           AND result_external_account_id IS NULL AND result_display_login IS NULL
           AND result_execution_identity IS NULL AND result_authorization_ref IS NULL
           AND result_authorization_version IS NULL
           AND provider_cleanup_status = 'confirmed')
        )
        """
      )
    )
  end

  def down do
    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_ownership_stage_check
      )
    )

    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_durable_ownership_check
      )
    )

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_durable_ownership_check,
        check: """
        status NOT IN ('prepared','backend_committed','connection_committed','finalized','fenced','cleanup_pending')
        OR (
          (
          (status = 'finalized' AND next_recovery_at IS NULL)
          OR
          (status IN ('prepared','backend_committed','connection_committed','fenced','cleanup_pending')
           AND next_recovery_at IS NOT NULL)
          )
          AND (
          operation_class NOT IN ('store','replace')
          OR status NOT IN ('backend_committed','connection_committed','finalized','cleanup_pending')
          OR (result_external_account_id IS NOT NULL AND
              result_execution_identity IS NOT NULL AND
              result_authorization_ref IS NOT NULL AND
              result_authorization_version IS NOT NULL AND
              result_ref IS NOT NULL AND result_credential_version IS NOT NULL AND
              provider_result_ref IS NOT NULL)
          )
          AND (
          operation_class <> 'refresh'
          OR status NOT IN ('backend_committed','connection_committed','finalized','cleanup_pending')
          OR (provider_result_ref IS NOT NULL AND
              result_ref IS NOT NULL AND result_credential_version IS NOT NULL)
          OR (status = 'cleanup_pending' AND provider_cleanup_status = 'not_required')
          )
          AND (
          status <> 'cleanup_pending'
          OR provider_cleanup_status <> 'not_required'
          OR credential_cleanup_status <> 'not_required'
          )
        )
        """
      )
    )

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_ownership_stage_check,
        check: """
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
      )
    )
  end
end
