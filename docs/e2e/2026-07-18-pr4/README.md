# D5 正路 RPC 导入 socialware manifest — 真栈 e2e 证据(2026-07-18)

任务:开工单 PR-D(⑪ / D5 已拍板,`docs/together/2026-07-18/handoffs/D5-socialware-import-rpc.md`)。
dev 不开 boot-scan(`config/config.exs:29` `socialware_manifest_boot_scan: config_env() in [:prod]`,红线零改动),
新增 `mix ezagent.socialware.import_remote`:读本地 YAML 字节 → 一次 `:erpc.call` 到**运行节点**内执行
`Ezagent.Socialware.ManifestSeed.import_package/2`(parse → resolve → conformance → governed
`publish_or_upgrade`,与 boot-scan 同一条治理链,零绕过;同目录 `recipes.yaml` 按 boot 路先行 seed)。

## 环境

- 分支 `feat/kb-dev-import-rpc` @ 基线 `origin/main` `d533a5d73`
- Postgres:`ezagent-pg-compat-audit-postgres`(55432,已跑 2 天的 dev 审计库)
- server:`PORT=10062 EZAGENT_RUNTIME_NODE=ezagent_r4@127.0.0.1 mix phx.server`
  (签名种子/pepper 从既有 dev 凭证注入;boot 日志 `Running EzagentWeb.Endpoint with Bandit 1.11.1 at 0.0.0.0:10062`)
- cookie:默认 `~/.ezagent/default/runtime/cookie`(与 `Ezagent.Runtime.ensure_cookie!/0` 同源)

## 步骤与输出(全部零重启)

### 0. 导入前 erpc 读注册表(read-only 取证)

```
PRE-IMPORT: kanban PRESENT (version="0.1.0")
```

(审计库里 kanban 已由早前 prod-boot-scan 姿势的运行发布过 —— 正好走幂等与升级两条路。)

### 1. `--dry-run`(本地解析,不连节点)

```
$ mix ezagent.socialware.import_remote apps/ezagent_web/priv/socialware_seed/kanban/manifest.yaml --dry-run
[dry-run] manifest .../kanban/manifest.yaml parses OK — name: kanban
[dry-run] sibling .../kanban/recipes.yaml parses OK — recipes: kanban-assistant, dev-together
[dry-run] would import via node RPC — nothing published
```

### 2. 原样导入 → 幂等 `:exists`

```
$ mix ezagent.socialware.import_remote apps/ezagent_web/priv/socialware_seed/kanban/manifest.yaml \
    --node ezagent_r4@127.0.0.1 --cookie-file ~/.ezagent/default/runtime/cookie
seeding sibling recipes from .../kanban/recipes.yaml on ezagent_r4@127.0.0.1 ...
socialware kanban → exists (on ezagent_r4@127.0.0.1)
```

### 3. dev 改 manifest(version 0.1.0 → 0.1.1 的临时副本)→ `:upgraded`

```
$ sed 's/^version: "0.1.0"/version: "0.1.1"/' .../manifest.yaml > /tmp/pr4-kanban-edit/manifest.yaml
$ cp .../recipes.yaml /tmp/pr4-kanban-edit/
$ mix ezagent.socialware.import_remote /tmp/pr4-kanban-edit/manifest.yaml \
    --node ezagent_r4@127.0.0.1 --cookie-file ~/.ezagent/default/runtime/cookie
seeding sibling recipes from /tmp/pr4-kanban-edit/recipes.yaml on ezagent_r4@127.0.0.1 ...
socialware kanban → upgraded (on ezagent_r4@127.0.0.1)
```

### 4. 导入后 erpc 验 DefinitionRegistry / RecipeRegistry

```
POST-IMPORT: kanban PRESENT (version="0.1.1")
RECIPE kanban-assistant PRESENT (skills=["kanban-assistant"])
```

即 DoD:「dev 改 manifest → import → 零重启生效」+「重复 import 幂等(:exists / :upgraded 语义
与 publish_or_upgrade 一致)」。conformance / parse 失败路径在单测里 loud 验证(Mix.raise / raise)。

## 测试

- `mix test apps/ezagent_cli/test/mix/tasks/ezagent_socialware_import_remote_test.exs`
  → **8 tests, 0 failures**(参数/文件/cookie loud 错误 + `--dry-run` 解析路径)
- `mix test apps/ezagent_domain_session/test/ezagent/socialware/{manifest_import_package,manifest_seed_recipes,manifest_seed,manifest_yaml}_test.exs`
  → **20 tests, 0 failures**(新增 `import_package/2` 字节导入 3 例:recipes 先 seed + 发布 + 幂等
  `:exists`、缺 name、recipes 非列表 fail-loud;其余为 boot 路回归)

## 红线自查

- `config/config.exs:29` boot-scan 口径:**零改动**(git diff 不含 config/)
- 治理链零绕过:task 本地只读文件,发布全在节点内 `import_package/2` → `ManifestYaml.import`(operator_admin_ctx 现姿势)
- 收编 `.iex.exs` 手工 workaround(seed! + 临时目录 scan_dir!)为正路;task `@requirements` 为空,不 app.start、不撞运行 server 的 _build(全部预编译后仅 erpc)
