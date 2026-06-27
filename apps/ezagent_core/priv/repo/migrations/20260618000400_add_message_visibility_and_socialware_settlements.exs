defmodule EzagentCore.Repo.Migrations.AddMessageVisibilityAndSocialwareSettlements do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :visibility, :string, null: false, default: "external_visible"
    end

    create index(:messages, [:visibility], name: :messages_visibility_index)

    create table(:socialware_settlements, primary_key: false) do
      add :turn_id, :string, primary_key: true
      add :session_uri, :string, null: false
      add :workspace_uri, :string, null: false
      add :target_surface_version, :integer
      add :expected_prior_approved, :integer
      add :subwrites_done, {:array, :string}, null: false, default: []
      add :status, :string, null: false, default: "pending"
      add :committed_at, :utc_datetime_usec
      add :conflict_reason, :string
      timestamps(type: :utc_datetime_usec)
    end

    create index(:socialware_settlements, [:session_uri, :status],
             name: :socialware_settlements_session_status_index
           )

    create table(:socialware_settlement_messages, primary_key: false) do
      add :turn_id,
          references(:socialware_settlements,
            column: :turn_id,
            type: :string,
            on_delete: :delete_all
          ),
          null: false

      add :message_id, :string, null: false
      add :workspace_uri, :string, null: false
    end

    create unique_index(:socialware_settlement_messages, [:turn_id, :message_id],
             name: :socialware_settlement_messages_pkey
           )

    create index(:socialware_settlement_messages, [:message_id],
             name: :socialware_settlement_messages_message_id_index
           )

    create table(:socialware_delivery_outbox, primary_key: false) do
      add :turn_id,
          references(:socialware_settlements,
            column: :turn_id,
            type: :string,
            on_delete: :delete_all
          ),
          primary_key: true

      add :session_uri, :string, null: false
      add :workspace_uri, :string, null: false
      add :message_ids, {:array, :string}, null: false
      add :emitted_at, :utc_datetime_usec, null: false
    end
  end
end
