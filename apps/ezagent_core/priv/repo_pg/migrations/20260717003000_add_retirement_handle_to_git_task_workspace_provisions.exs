defmodule EzagentCore.Repo.Migrations.AddRetirementHandleToGitTaskWorkspaceProvisions do
  use Ecto.Migration

  def change do
    alter table(:git_task_workspace_provisions) do
      add(:agent_uri, :text)
      add(:creation_attempt_id, :text)
      add(:provenance_root_uri, :text)
    end
  end
end
