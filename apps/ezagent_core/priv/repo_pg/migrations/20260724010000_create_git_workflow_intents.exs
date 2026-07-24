defmodule EzagentCore.Repo.Migrations.CreateGitWorkflowIntents do
  use Ecto.Migration

  def change do
    create table(:git_workflow_bindings, primary_key: false) do
      add :id, :string, null: false, primary_key: true
      add :generation, :integer, null: false, default: 1
      add :workspace_uri, :string, null: false
      add :task_receiver_uri, :string, null: false
      add :credential_owner_uri, :string, null: false
      add :repository_uri, :string, null: false
      add :provider_adapter, :string, null: false
      add :provider_host, :string, null: false
      add :external_id, :string, null: false
      add :owner_path, :string, null: false
      add :base_ref, :string, null: false
      add :visibility, :string, null: false
      add :allowed_head_namespace, :string, null: false
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create table(:git_workflow_runs, primary_key: false) do
      add :id, :string, null: false, primary_key: true
      add :binding_id, :string, null: false
      add :binding_generation, :integer, null: false
      add :external_task_id, :string, null: false
      add :status, :string, null: false, default: "accepted"
      add :state_version, :integer, null: false, default: 1
      add :input_digest, :string, null: false
      add :source_task_uri, :string, null: false
      add :source_revision, :string
      add :requested_head_ref, :string
      add :last_error_code, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:git_workflow_runs, [:binding_id, :binding_generation, :external_task_id])
    create index(:git_workflow_runs, [:binding_id])
    create index(:git_workflow_runs, [:status])
  end
end
