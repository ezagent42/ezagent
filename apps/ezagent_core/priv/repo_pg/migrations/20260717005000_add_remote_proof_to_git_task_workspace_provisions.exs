defmodule Ezagent.Repo.Migrations.AddRemoteProofToGitTaskWorkspaceProvisions do
  use Ecto.Migration

  def change do
    alter table(:git_task_workspace_provisions) do
      add :remote_url, :text
    end
  end
end
