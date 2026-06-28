defmodule EzagentCore.Repo.Migrations.AddWorkspaceResponsibilityAssignments do
  use Ecto.Migration

  def change do
    create table(:workspace_responsibility_assignments, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workspace_uri, :text, null: false
      add :responsibility, :text, null: false
      add :holder_uri, :text, null: false
      add :assigned_by, :text
      add :config, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :workspace_responsibility_assignments,
             [:workspace_uri, :responsibility, :holder_uri],
             name: :workspace_responsibility_assignments_unique_holder
           )

    create index(:workspace_responsibility_assignments, [:workspace_uri, :responsibility],
             name: :workspace_resp_assignments_workspace_resp_index
           )

    create index(:workspace_responsibility_assignments, [:holder_uri],
             name: :workspace_resp_assignments_holder_index
           )
  end
end
