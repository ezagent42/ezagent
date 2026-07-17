defmodule EzagentCore.Repo.Migrations.CreateActionableErrorWorkflows do
  use Ecto.Migration

  def change do
    create table(:actionable_error_issues) do
      add :message_id, :string, null: false
      add :code, :string, null: false
      add :workspace_uri, :string, null: false
      add :agent_uri, :string, null: false
      add :session_uri, :string
      add :detail, :text
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:actionable_error_issues, [:workspace_uri, :occurred_at])
    create index(:actionable_error_issues, [:agent_uri, :occurred_at])
    create unique_index(:actionable_error_issues, [:message_id])

    create table(:actionable_error_repair_requests) do
      add :message_id, :string, null: false
      add :workspace_uri, :string, null: false
      add :agent_uri, :string, null: false
      add :error_code, :string, null: false
      add :error_title, :string, null: false
      add :requested_by, :string, null: false
      add :assigned_to, :string, null: false
      add :repair_href, :string, null: false
      add :status, :string, null: false, default: "open"
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :actionable_error_repair_requests,
             [:message_id, :requested_by],
             name: :actionable_error_repair_requests_message_requester_index
           )

    create index(:actionable_error_repair_requests, [:agent_uri, :status])
  end
end
