defmodule EzagentCore.Repo.Migrations.PgCreateRoutingTraces do
  use Ecto.Migration

  def change do
    create table(:routing_traces) do
      add :message_id, :string, null: false
      add :workspace_uri, :string, null: false
      add :rule_id, :string, null: false
      add :receivers, {:array, :string}, null: false, default: []
      add :hop, :integer
      add :drop_reason, :string
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:routing_traces, [:message_id])
    create index(:routing_traces, [:workspace_uri])
  end
end
