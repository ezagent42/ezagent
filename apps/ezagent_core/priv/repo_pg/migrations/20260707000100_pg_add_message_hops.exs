defmodule EzagentCore.Repo.Migrations.PgAddMessageHops do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :hops, :integer, null: false, default: 8
    end
  end
end
