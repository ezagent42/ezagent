defmodule EzagentCore.Repo.Migrations.AddCheckoutFingerprintToGitTaskWorkspaceProvisions do
  use Ecto.Migration

  def change do
    alter table(:git_task_workspace_provisions) do
      add(:checkout_fingerprint, :text)
    end
  end
end
