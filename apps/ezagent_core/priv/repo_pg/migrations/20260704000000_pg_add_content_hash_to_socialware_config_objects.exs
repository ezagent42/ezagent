defmodule EzagentCore.Repo.Migrations.PgAddContentHashToSocialwareConfigObjects do
  @moduledoc """
  P0 §11.1 (D-3) — PostgreSQL mirror of the SQLite `content_hash` column on
  `socialware_config_objects`. Nullable + index; new writes populate it via
  `Ezagent.Socialware.ContentHash.of/1`.
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
