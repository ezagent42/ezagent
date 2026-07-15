defmodule EzagentCore.Repo.Migrations.AgentRetirementObligations do
  use Ecto.Migration

  def change do
    create table(:agent_retirement_obligations) do
      add :agent_uri, :text, null: false
      add :workspace_uri, :text, null: false
      add :provenance_root_uri, :text, null: false
      add :creation_attempt_id, :text, null: false
      add :retirement_reason, :text, null: false
      add :status, :text, null: false, default: "pending"
      add :pending_steps, :map, null: false
      add :attempts, :integer, null: false, default: 0
      add :last_error, :text
      add :next_attempt_at, :utc_datetime_usec
      add :resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :agent_retirement_obligations,
             [:agent_uri, :creation_attempt_id, :retirement_reason],
             name: :agent_retirement_obligations_identity_index
           )

    create index(:agent_retirement_obligations, [:status, :next_attempt_at])
  end
end
