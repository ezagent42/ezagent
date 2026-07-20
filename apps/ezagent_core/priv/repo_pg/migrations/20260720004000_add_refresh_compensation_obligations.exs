defmodule EzagentCore.Repo.Migrations.AddRefreshCompensationObligations do
  use Ecto.Migration

  def up do
    alter table(:provider_connection_operations) do
      add(:provider_cleanup_status, :text, null: false, default: "not_required")
      add(:credential_cleanup_status, :text, null: false, default: "not_required")
      add(:provider_cleanup_error_code, :text)
      add(:credential_cleanup_error_code, :text)
    end

    execute("""
    UPDATE provider_connection_operations
       SET provider_cleanup_status = 'not_required',
           credential_cleanup_status = CASE
             WHEN status = 'cleanup_pending' THEN 'pending'
             ELSE 'not_required'
           END
    """)

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_provider_cleanup_status_check,
        check: "provider_cleanup_status IN ('not_required','pending','confirmed')"
      )
    )

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_credential_cleanup_status_check,
        check: "credential_cleanup_status IN ('not_required','pending','confirmed')"
      )
    )

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_provider_cleanup_error_check,
        check: """
        provider_cleanup_error_code IS NULL OR provider_cleanup_error_code IN
        ('invalid_subject','invalid_method','invalid_host','state_mismatch','pkce_mismatch',
         'callback_expired','callback_replayed','callback_in_progress','correlation_conflict',
         'account_conflict','stale_version','reauthentication_failed','backend_unavailable',
         'credential_conflict','credential_revocation_failed','refresh_lease_lost',
         'provider_denied','provider_protocol_failed','cleanup_pending','connection_terminal')
        """
      )
    )

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_credential_cleanup_error_check,
        check: """
        credential_cleanup_error_code IS NULL OR credential_cleanup_error_code IN
        ('invalid_subject','invalid_method','invalid_host','state_mismatch','pkce_mismatch',
         'callback_expired','callback_replayed','callback_in_progress','correlation_conflict',
         'account_conflict','stale_version','reauthentication_failed','backend_unavailable',
         'credential_conflict','credential_revocation_failed','refresh_lease_lost',
         'provider_denied','provider_protocol_failed','cleanup_pending','connection_terminal')
        """
      )
    )

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_provider_cleanup_result_check,
        check: "provider_cleanup_status = 'not_required' OR provider_result_ref IS NOT NULL"
      )
    )

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_credential_cleanup_result_check,
        check:
          "credential_cleanup_status = 'not_required' OR (result_ref IS NOT NULL AND result_credential_version IS NOT NULL)"
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
      index(
        :provider_connection_operations,
        [:provider_cleanup_status, :credential_cleanup_status, :next_recovery_at, :id],
        where: "provider_cleanup_status = 'pending' OR credential_cleanup_status = 'pending'",
        name: :provider_connection_operations_cleanup_due_index
      )
    )
  end

  def down do
    drop(
      index(:provider_connection_operations, [],
        name: :provider_connection_operations_cleanup_due_index
      )
    )

    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_durable_ownership_check
      )
    )

    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_credential_cleanup_result_check
      )
    )

    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_provider_cleanup_result_check
      )
    )

    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_credential_cleanup_status_check
      )
    )

    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_credential_cleanup_error_check
      )
    )

    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_provider_cleanup_error_check
      )
    )

    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_provider_cleanup_status_check
      )
    )

    alter table(:provider_connection_operations) do
      remove(:credential_cleanup_error_code)
      remove(:provider_cleanup_error_code)
      remove(:credential_cleanup_status)
      remove(:provider_cleanup_status)
    end
  end
end
