defmodule EzagentCore.Repo.Migrations.SocialwareMountsPersonScope do
  use Ecto.Migration

  @moduledoc """
  挂载表 person-scope(㊵ 人本位前置,自有过渡 infra):

    * 加 `scope` 列(`"session"` | `"person"`,默认 `"session"`,存量行自动归 session);
    * `session_uri` 放宽为可空 —— person 行(人持钥匙,跨会话)没有 session 轴;
    * person 行的自然键 = `(target_uri, grantee_uri, behavior)`,补 partial unique
      index 兜 DB 侧幂等(原四列 unique index 对 NULL session 各行互不相等,罩不住)。

  选「显式 scope 列」而非哨值:语义显式、查询各走各,且将来 mount 折
  CompositionBinding 时 scope 维度可列对列机械平移。

  ## 回滚说明

  `down` **先删全部 person 行**(person 行只在本形态下有意义,收回 NOT NULL 前必须
  清掉 NULL session 行,否则 `SET NOT NULL` 失败),再删 partial index、收回
  `session_uri NOT NULL`、去掉 `scope` 列 —— 回滚后表回到纯 session-scope 形态,
  session 行零损失。person 行对应的已发钥匙不在本表,回滚不撤钥匙(如需撤,先在
  应用层 `Mount.unmount_for_person/3` 逐行撤再回滚)。
  """

  def up do
    alter table(:socialware_mounts) do
      add(:scope, :string, null: false, default: "session")
      modify(:session_uri, :string, null: true)
    end

    create(
      unique_index(
        :socialware_mounts,
        [:target_uri, :grantee_uri, :behavior],
        where: "scope = 'person'",
        name: :socialware_mounts_person_key_index
      )
    )
  end

  def down do
    execute("DELETE FROM socialware_mounts WHERE scope = 'person'")

    drop(
      index(:socialware_mounts, [:target_uri, :grantee_uri, :behavior],
        name: :socialware_mounts_person_key_index
      )
    )

    alter table(:socialware_mounts) do
      modify(:session_uri, :string, null: false)
      remove(:scope)
    end
  end
end
