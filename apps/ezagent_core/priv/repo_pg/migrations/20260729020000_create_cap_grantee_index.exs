defmodule EzagentCore.Repo.Migrations.CreateCapGranteeIndex do
  use Ecto.Migration

  # Reverse cap index (URI-share A2-2): a derived, read-only projection of
  # "who holds a cap toward target T", written at the single cap-store funnel
  # (`persist_entity_caps`). Rows are NEVER a source of truth for re-minting keys
  # — they are filtered at read by the target's current authority generation
  # (`key_id`), so a revoke-by-generation invalidates stale rows without a delete.
  def change do
    create table(:cap_grantee_index, primary_key: false) do
      add :id, :string, primary_key: true
      add :target_uri, :string, null: false
      add :grantee_uri, :string, null: false
      add :behavior, :string, null: false
      add :action, :string, null: false
      # Generation stamp copied from the signed cap; matched against the target's
      # active authority key_id at read time. Null only for unsigned legacy caps
      # (which then never match an active generation).
      add :key_id, :string
      add :granted_by, :string
      add :workspace_uri, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :cap_grantee_index,
             [:target_uri, :grantee_uri, :behavior, :action],
             name: :cap_grantee_index_natural_key_index
           )

    create index(:cap_grantee_index, [:target_uri])
    create index(:cap_grantee_index, [:grantee_uri])
  end
end
