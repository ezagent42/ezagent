# 场景 31：完整 ezagent-home 备份 + 恢复迁移

**类别**：6 — 持久化 / 恢复
**状态**：✅ implemented-and-tested
**最近验证**：2026-05-30（home portability #120）

双语 lockstep 镜像：[`scenario.md`](./scenario.md)。

## 证明什么

把 `$EZAGENT_HOME/$EZAGENT_PROFILE/` 复制/恢复到另一台机器或另一个路径，能**完整重建系统** —
数据库（用户、caps、会话、路由规则、Kind 快照）+ 磁盘上的每-agent config 目录 —
并且每一个被持久化的绝对路径都会被改写到新位置。

## 前置条件

- 一个已 seed 的 ezagent home（通过 `EZAGENT_HOME` / `EZAGENT_PROFILE` 激活）。
- PATH 上有 `sqlite3`（用于 `VACUUM INTO` 一致性拷贝；若缺失则回退到 NIF
  checkpoint-then-copy）。

## 角色

- **调用方**：运行 `mix ezagent.home.*` 的运维（Category A — 围绕运行时 BEAM 的
  FS/DB 操作，类似 `ezagent.home.adopt_db`）。

## 路径可移植性模型（见 `docs/notes/home-portability-audit.md`）

唯一被持久化的绝对路径是 Sandbox slice 的 `config_dir_path`，以及
`respawn_template_data` 里嵌入的 `agent_config_dir`/`claude_config_dir` —
二者都在 `<profile_dir>/cc-agents/...` 下，都埋在 `kind_snapshots.state_binary`
（`term_to_binary`）里。`restore` 会解码每个快照 blob，把 源-profile-dir 前缀
（从备份的 `MANIFEST.json` 读取）改写为目标 profile dir，再重新编码。解码故意
**不带** `:safe` 标志 —— restore 任务只启动 `:exqlite`，插件的 `template_class`
atom 不在该进程的 atom 表里，`:safe` 否则会拒绝整个 blob（静默跳过改写 —— 本场景
手动验证时抓到："rewrote 0" → "rewrote 1"）。

## SQLite 一致性模型

`backup` 用 `sqlite3 <db> "VACUUM INTO '<dst>'"` 拷贝活动 DB：读取单个一致事务，
写出全新、完全 checkpoint 的文件 —— 即使存在活动 `-wal` 也正确，且从不触碰源文件。
服务运行时取的备份内部一致；要保证完全静默拷贝则先停服务。

## 步骤（自动化测试）

`apps/ezagent_core/test/integration/home_migration_test.exs`（3 个测试，全绿）：

1. 在磁盘上 seed 临时 home A：一个带 caps 的 User 快照、一个 `config_dir_path`
   为 A 下绝对路径的 Agent Sandbox 快照、一个真实的
   `cc-agents/<ws>/<name>/.credentials.json`、一个 profile 级凭据。
2. `Ezagent.Home.Migration.backup/1` → `.tar.gz`。
3. `Ezagent.Home.Migration.restore/4` 到**不同路径**的 home B。
4. 对 home B 的 DB 启动 Repo；通过**正常读路径**
   （`Ezagent.Ecto.KindSnapshot.get/1` + `decode_state/1`）读取。
5. 断言：user caps 存在；`config_dir_path` 改写 A→B；嵌入的
   `respawn_template_data` 路径改写；`template_class`/`pty_phase` 保留；
   config-dir 文件内容存活；改写后的路径是真实目录。
   另外：非空目标无 `--force` 时 restore 拒绝。

## 手动 e2e（2026-05-30 验证，临时 home）

```
# Seed home A（ecto-only 迁移 + 插入一个带 home A 下绝对 config_dir_path 的
# Sandbox 快照），然后：

$ EZAGENT_HOME=/private/tmp/esr-home-test1 EZAGENT_PROFILE=default \
    mix ezagent.home.backup --out /private/tmp/esr-backup.tar.gz
✓ Backed up /private/tmp/esr-home-test1/default
  → /private/tmp/esr-backup.tar.gz

$ mix ezagent.home.restore --from /private/tmp/esr-backup.tar.gz \
    --home /private/tmp/esr-home-test2 --profile default
✓ Restored into /private/tmp/esr-home-test2/default
  rewrote 1 snapshot path(s) to the new home

# 在 home B 的 DB 中验证（原始 term 解码）：
config_dir_path = /private/tmp/esr-home-test2/default/cc-agents/team-alpha/cc_demo
respawn agent_config_dir = /private/tmp/esr-home-test2/default/cc-agents/team-alpha/cc_demo
dir_exists = true        # 改写后的路径指向真实的已恢复目录
template_class = EzagentPluginCc.Template.CcAgent   # 非路径字段保留
```

## 预期结果

- 备份是单一一致产物；瞬态（`logs/`、`pty-pids/`、`runtime/`）被省略，
  恢复时重建为空。
- 恢复后，已恢复 home 下没有任何路径仍指向源 home。
- 已恢复的 DB 通过生产读路径读回完全一致。

## 要测的失败模式

- 非空目标无 `--force` → `{:error, {:target_not_empty, _}}`。
- 快照 blob 携带 restore 进程未加载的插件 atom → 仍必须改写（`:safe` 解码回归）。
- 还没有 DB 的全新 home → 备份/恢复成功，改写 0 条。

## 交叉引用

- `docs/notes/home-portability-audit.md` —— 绝对路径审计。
- `mix ezagent.home.adopt_db` / `ezagent.home.init` —— 同类 Category A home 操作。
- `apps/ezagent_core/lib/ezagent/home/migration.ex` —— 备份/恢复核心。
