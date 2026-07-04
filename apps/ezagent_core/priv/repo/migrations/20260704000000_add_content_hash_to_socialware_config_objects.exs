defmodule EzagentCore.Repo.Migrations.AddContentHashToSocialwareConfigObjects do
  @moduledoc """
  P0 §11.1 (D-3) — promote the socialware content-hash to a first-class,
  queryable column on `socialware_config_objects`. Nullable + index: legacy rows
  predate it (lazy/one-time backfill); the catalog (P1) and promotion checks (P3)
  query by hash. SQLite tree — mirrored in `priv/repo_pg/`.
  """
  use Ecto.Migration

  def change do
    alter table(:socialware_config_objects) do
      add(:content_hash, :string)
    end

    create(
      index(:socialware_config_objects, [:content_hash],
        name: :socialware_config_objects_content_hash_index
      )
    )
  end
end
