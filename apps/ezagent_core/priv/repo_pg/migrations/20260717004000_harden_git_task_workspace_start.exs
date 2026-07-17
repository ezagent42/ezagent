defmodule EzagentCore.Repo.Migrations.HardenGitTaskWorkspaceStart do
  use Ecto.Migration

  def up do
    alter table(:git_task_workspace_provisions) do
      add :start_claim_token, :string
      add :start_lease_until, :utc_datetime_usec
      add :resolved_base_commit, :string
      add :local_branch_ref, :string
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
  end

  def down do
    drop_if_exists index(:git_task_workspace_provisions, [:status, :start_lease_until],
                     name: :git_task_workspace_provisions_start_recovery_index
                   )

    alter table(:git_task_workspace_provisions) do
      remove :start_claim_token
      remove :start_lease_until
      remove :resolved_base_commit
      remove :local_branch_ref
    end
  end
end
