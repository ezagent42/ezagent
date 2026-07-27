defmodule EzagentCore.Repo.Migrations.DropSocialwareMounts do
  use Ecto.Migration

  # 挂载表已废弃：发钥匙改走 CompositionCaps.mint_cap（cap durable 于 identity slice，
  # 不落表），撤销走 Cap.revoke_all_to。Mount/MountRow 模块已删除。
  def up do
    drop table(:socialware_mounts)
  end

  # down 恢复的是删表前的最终形态(0714 建表 + 0718 person-scope 演进的叠加):
  # session_uri 可空、带 scope 列、person 轴 partial unique index。数据不可恢复。
  def down do
    create table(:socialware_mounts, primary_key: false) do
      add :id, :string, primary_key: true
      add :session_uri, :string, null: true
      add :target_uri, :string, null: false
      add :grantee_uri, :string, null: false
      add :behavior, :string, null: false
      add :actions_json, :text, null: false, default: "[]"
      add :access, :string, null: false
      add :granted_by, :string, null: false
      add :workspace_uri, :string, null: false
      add :mounted_at, :utc_datetime_usec, null: false
      add :scope, :string, null: false, default: "session"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :socialware_mounts,
             [:session_uri, :target_uri, :grantee_uri, :behavior],
             name: :socialware_mounts_natural_key_index
           )

    create unique_index(
             :socialware_mounts,
             [:target_uri, :grantee_uri, :behavior],
             where: "scope = 'person'",
             name: :socialware_mounts_person_key_index
           )

    create index(:socialware_mounts, [:session_uri])
    create index(:socialware_mounts, [:target_uri])
    create index(:socialware_mounts, [:grantee_uri])
  end
end
