defmodule EzagentCore.Repo.Migrations.CreateCapGranteeIndex do
  @moduledoc """
  Reverse cap index — "who currently holds a cap toward target T" (URI-share A2-2).

  A derived, read-only projection of the authoritative `identity_caps` store,
  written in the Store's write transaction (`GranteeIndex.reindex_in_txn/2`).
  This migration creates the empty projection table; normal Store writes are
  its only population path.
  """
  use Ecto.Migration

  def up do
    create table(:cap_grantee_index, primary_key: false) do
      add :id, :string, primary_key: true
      add :target_uri, :string, null: false
      add :grantee_uri, :string, null: false
      add :behavior, :string
      add :action, :string
      add :key_id, :string
      add :granted_by, :string
      add :workspace_uri, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Read path: `(target_uri, key_id)` — grantees of a target at the current
    # active generation. Plus grantee (reindex delete-all) and workspace scoping.
    create index(:cap_grantee_index, [:target_uri, :key_id])
    create index(:cap_grantee_index, [:grantee_uri])
    create index(:cap_grantee_index, [:workspace_uri])
  end

  def down do
    drop table(:cap_grantee_index)
  end
end
