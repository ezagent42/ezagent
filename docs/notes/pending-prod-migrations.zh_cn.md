# 待执行的生产迁移

已合入 `main`、但下次部署时必须对**生产**数据库执行的 Ecto 迁移。dev/test 库走常规
`mix ecto.migrate` / `mix ezagent.db.reset` 即可；生产需要在此显式记录一次运维动作。

> 某条迁移在生产执行完后，从本文件删除对应条目。

## 如何执行

```bash
# 在 umbrella 根目录，对 prod profile/env 执行
MIX_ENV=prod mix ecto.migrate
```

## 待办条目

### `20260616000000_agent_lineage_durable_backing` — agent_lineage 持久化表

- **落地于**：#493（post-lifecycle remediation，remediation C-B / #114）。
- **作用**：纯新增 `CREATE TABLE agent_lineage` —— 给 `Ezagent.AgentLineage` 加持久化
  后备（SQLite 为真相源 + ETS 读缓存），使 `agent_uri → spawned_by` 映射能跨重启存活。
  没有它，重启前 spawn 的每个 agent 都会变成「外来」，重启后 `{:spawned_by, P}` 的
  CapBAC 匹配（Decision #137 第 5.5 步）会**静默失效**。
- **风险**：纯新增（仅建表）；无数据重写、无停机。
- **为何标注**：被 live e2e 抓到 —— 合并后的代码首次启动崩在
  `no such table: agent_lineage`，因为开发期这条迁移只跑过 dev 库。生产尚未迁移。
- **再水合**：启动时 `Ezagent.AgentLineage.rehydrate/0` 从该表回填 ETS 缓存；生产首次
  启动时表为空（历史 lineage 行不存在），之后随 agent spawn 逐步填充 —— 可接受，因为
  原来的纯 ETS 方案本来每次启动就丢这份映射。
