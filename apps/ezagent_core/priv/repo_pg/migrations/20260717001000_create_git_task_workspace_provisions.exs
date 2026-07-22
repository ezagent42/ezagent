defmodule EzagentCore.Repo.Migrations.CreateGitTaskWorkspaceProvisions do
  use Ecto.Migration

  def change do
    create table(:git_task_workspace_provisions) do
      add(:provision_id, :text, null: false)
      add(:workspace_uri, :text, null: false)
      add(:task_uri, :text, null: false)
      add(:generation, :integer, null: false)
      add(:task_access_uri, :text, null: false)
      add(:repository_uri, :text, null: false)
      add(:base_ref, :text, null: false)
      add(:allowed_head_ref, :text, null: false)
      add(:status, :text, null: false, default: "planned")
      add(:state_version, :integer, null: false, default: 0)
      add(:cache_identity, :text)
      add(:worktree_identity, :text)
      add(:worktree_path, :text)
      add(:claim_token, :text)
      add(:lease_until, :utc_datetime_usec)
      add(:start_token, :text)
      add(:start_token_consumed_at, :utc_datetime_usec)
      add(:attempts, :integer, null: false, default: 0)
      add(:blocker_code, :text)
      add(:cleanup_reason, :text)
      add(:cleaned_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :git_task_workspace_provisions,
             [:workspace_uri, :task_uri, :generation],
             name: :git_task_workspace_provisions_identity_index
           )

    create unique_index(:git_task_workspace_provisions, [:provision_id])
    create index(:git_task_workspace_provisions, [:status, :lease_until])
    create index(:git_task_workspace_provisions, [:workspace_uri, :status])

    create constraint(
             :git_task_workspace_provisions,
             :git_task_workspace_provisions_status_check,
             check:
               "status IN ('planned', 'provisioning', 'ready', 'sidecar_started', " <>
                 "'blocked', 'cleanup_pending', 'cleaned')"
           )

    create constraint(
             :git_task_workspace_provisions,
             :git_task_workspace_provisions_generation_check,
             check: "generation > 0"
           )

    create constraint(
             :git_task_workspace_provisions,
             :git_task_workspace_provisions_state_version_check,
             check: "state_version >= 0"
           )

    create constraint(
             :git_task_workspace_provisions,
             :git_task_workspace_provisions_attempts_check,
             check: "attempts >= 0"
           )
  end
end
