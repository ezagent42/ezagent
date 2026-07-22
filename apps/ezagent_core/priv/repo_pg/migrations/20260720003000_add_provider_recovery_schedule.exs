defmodule EzagentCore.Repo.Migrations.AddProviderRecoverySchedule do
  use Ecto.Migration

  def up do
    alter table(:provider_connection_operations) do
      add(:recovery_attempts, :integer, null: false, default: 0)
      add(:next_recovery_at, :utc_datetime_usec)
      add(:last_recovery_error_code, :text)
    end

    execute("""
    UPDATE provider_connection_operations
       SET next_recovery_at = CURRENT_TIMESTAMP
     WHERE status IN ('prepared','backend_committed','connection_committed','fenced','cleanup_pending')
    """)

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_recovery_attempts_check,
        check: "recovery_attempts >= 0"
      )
    )

    create(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_last_recovery_error_code_check,
        check: """
        last_recovery_error_code IS NULL OR last_recovery_error_code IN
        ('invalid_subject','invalid_method','invalid_host','state_mismatch','pkce_mismatch',
         'callback_expired','callback_replayed','callback_in_progress','correlation_conflict',
         'account_conflict','stale_version','reauthentication_failed','backend_unavailable',
         'credential_conflict','credential_revocation_failed','refresh_lease_lost',
         'provider_denied','provider_protocol_failed','cleanup_pending','connection_terminal')
        """
      )
    )

    create(
      index(:provider_connection_operations, [:status, :next_recovery_at, :inserted_at, :id],
        where: "next_recovery_at IS NOT NULL",
        name: :provider_connection_operations_recovery_due_index
      )
    )
  end

  def down do
    drop(
      index(:provider_connection_operations, [],
        name: :provider_connection_operations_recovery_due_index
      )
    )

    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_last_recovery_error_code_check
      )
    )

    drop(
      constraint(
        :provider_connection_operations,
        :provider_connection_operations_recovery_attempts_check
      )
    )

    alter table(:provider_connection_operations) do
      remove(:last_recovery_error_code)
      remove(:next_recovery_at)
      remove(:recovery_attempts)
    end
  end
end
