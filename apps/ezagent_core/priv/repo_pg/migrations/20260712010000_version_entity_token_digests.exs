defmodule EzagentCore.Repo.Migrations.VersionEntityTokenDigests do
  use Ecto.Migration

  def up do
    alter table(:entity_tokens) do
      modify :token_hash, :string, null: true, from: {:string, null: false}
      add :token_digest, :binary
      add :digest_version, :integer
    end

    create unique_index(:entity_tokens, [:token_digest],
             name: :entity_tokens_token_digest_index,
             where: "token_digest IS NOT NULL"
           )
  end

  def down do
    drop_if_exists index(:entity_tokens, [:token_digest], name: :entity_tokens_token_digest_index)

    execute("DELETE FROM entity_tokens WHERE token_hash IS NULL")

    alter table(:entity_tokens) do
      remove :digest_version
      remove :token_digest
      modify :token_hash, :string, null: false, from: {:string, null: true}
    end
  end
end
