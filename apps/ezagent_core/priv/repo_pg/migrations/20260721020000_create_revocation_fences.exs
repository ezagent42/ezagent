defmodule EzagentCore.Repo.Migrations.CreateRevocationFences do
  use Ecto.Migration

  def change do
    create table(:revocation_fences, primary_key: false) do
      add :principal_uri, :string, primary_key: true
      add :enrolled_at, :utc_datetime_usec, null: false
      add :cleared_at, :utc_datetime_usec
    end

    create index(:revocation_fences, [:cleared_at, :enrolled_at])
  end
end
