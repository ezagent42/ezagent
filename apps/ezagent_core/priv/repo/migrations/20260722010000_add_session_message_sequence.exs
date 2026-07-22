defmodule EzagentCore.Repo.Migrations.AddSessionMessageSequence do
  use Ecto.Migration

  def change do
    create table(:session_message_sequences, primary_key: false) do
      add :session_uri, :string, primary_key: true
      add :workspace_uri, :string, null: false
      add :last_seq, :bigint, null: false, default: 0
    end

    create index(:session_message_sequences, [:workspace_uri])

    alter table(:messages) do
      add :session_seq, :bigint
    end

    create unique_index(:messages, [:session_uri, :session_seq],
             where: "session_seq IS NOT NULL",
             name: :messages_session_sequence_unique
           )
  end
end
