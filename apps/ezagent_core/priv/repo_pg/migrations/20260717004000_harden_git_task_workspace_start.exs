defmodule EzagentCore.Repo.Migrations.HardenGitTaskWorkspaceStart do
  use Ecto.Migration

  def up do
    drop constraint(
           :git_task_workspace_provisions,
           :git_task_workspace_provisions_status_check
         )

    alter table(:git_task_workspace_provisions) do
      add :start_claim_token, :string
      add :start_lease_until, :utc_datetime_usec
      add :resolved_base_commit, :string
      add :local_branch_ref, :string
      add :remote_url, :text
    end

    create index(:git_task_workspace_provisions, [:status, :start_lease_until],
             name: :git_task_workspace_provisions_start_recovery_index
           )

    execute """
    UPDATE git_task_workspace_provisions
       SET status = 'cleanup_pending',
           cleanup_reason = 'plan_c_hardening_upgrade',
           claim_token = NULL,
           lease_until = NULL,
           start_token = NULL
     WHERE status NOT IN ('cleaned')
    """

    create constraint(
             :git_task_workspace_provisions,
             :git_task_workspace_provisions_status_check,
             check:
               "status IN ('planned', 'provisioning', 'ready', 'starting', 'sidecar_started', " <>
                 "'blocked', 'cleanup_pending', 'cleaned')"
           )
  end

  def down do
    execute """
    UPDATE git_task_workspace_provisions
       SET status = 'cleanup_pending',
           cleanup_reason = 'plan_c_hardening_rollback',
           start_claim_token = NULL,
           start_lease_until = NULL
     WHERE status = 'starting'
    """

    drop constraint(
           :git_task_workspace_provisions,
           :git_task_workspace_provisions_status_check
         )

    create constraint(
             :git_task_workspace_provisions,
             :git_task_workspace_provisions_status_check,
             check:
               "status IN ('planned', 'provisioning', 'ready', 'sidecar_started', " <>
                 "'blocked', 'cleanup_pending', 'cleaned')"
           )

    drop_if_exists index(:git_task_workspace_provisions, [:status, :start_lease_until],
                     name: :git_task_workspace_provisions_start_recovery_index
                   )

    alter table(:git_task_workspace_provisions) do
      remove :start_claim_token
      remove :start_lease_until
      remove :resolved_base_commit
      remove :local_branch_ref
      remove :remote_url
    end
  end
end
