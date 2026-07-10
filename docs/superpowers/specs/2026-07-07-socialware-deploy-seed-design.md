# socialware 部署级 seed 机制 + seed-path gate — 设计

> Date: 2026-07-07 · 分支 `feat/sw-deploy-seed`（off `upstream/main` @ `258bcc62c`）
> 决策来源：Allen 在 issue #1226 拍板方案 3（部署级目录为 canonical 住址）+ 用户 2026-07-07 的模型收口（代码 seed 收窄为框架内置专属通道、autoservice 迁走、plugin-priv 车道废弃）+ 加 seed-path gate（gate-first）。

## 1. 目标 / 一句话

给 socialware 建"部署级目录 seed 机制"：**非框架 socialware 的 canonical 住址 = `$EZAGENT_HOME/<profile>/socialware/`**；随出厂的 flagship（autoservice/kanban/dealscout）从仓库源幂等 seed 进该目录，由已在 main 的晚扫描车道（`ManifestSeed.scan_all!`）发布。同时加一个 arch gate 禁止"非框架 socialware 直接走 seed"（自发布 / 非框架代码 seed / plugin-priv YAML），gate-first 抓出所有现存违规后逐个修。

## 2. 最终模型（seeding 路径职责收敛）

| channel | 谁走 | 状态 |
|---|---|---|
| 代码 seed（`DefinitionRegistry.seed_builtin_definitions`） | **仅框架内置** `chat` / `socialware` / `orchestrator`(#1223) | 保留，收窄为框架内置专属通道 |
| **部署级目录 `$EZAGENT_HOME/<profile>/socialware/`** | 其余全部（autoservice/kanban/dealscout + 未来用户安装） | **canonical 住址（本设计新增 seed）** |
| plugin/domain-priv `priv/socialware/` app_sources 扫描 | （曾 autoservice/kanban/dealscout 过渡用） | **废弃**（gate 禁止；代码路径暂留待 cleaner 清） |
| 运行时 import（`mix ezagent.socialware.import` / world / 发布为模板） | 平台用户 | 不变 |

## 3. seeding 路径清单（当前代码实况，供 cleaner 参考）

- **晚扫描车道** `ManifestSeed.scan_all!/1`（`apps/ezagent_domain_session/lib/ezagent/socialware/manifest_seed.ex:64`），触发点 `apps/ezagent_web/lib/ezagent_web/application.ex:36`。两个来源：`deploy_sources`（`manifest_seed.ex:106-115`，扫 `system://socialware`）+ `app_sources`（`:117`，扫每个 started app 的 `priv/socialware/*/manifest.yaml`）。→ **app_sources 变死路径**。
- **`system://socialware` 解析** `FsResolver`（`apps/ezagent_core/lib/ezagent/system/fs_resolver.ex:53/70`）→ `Home.path("socialware")` = `$EZAGENT_HOME/<profile>/socialware/`。
- **框架内置代码 seed** `DefinitionRegistry`（`definition_registry.ex`，chat/socialware builtin + #1223 orchestrator 经默认 session-template install）。→ **保留**。
- **autoservice**：`apps/ezagent_domain_session/priv/socialware/autoservice/`（manifest.yaml + package.yaml + kb/ + persona/）。→ **迁走**。
- **kanban 自发布**：`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex`(boot call) + `demo.ex`（Demo 自发布全链 + `manifest.yaml` 在 plugin priv）。→ **已完成**：manifest 迁至 `ezagent_web/priv/socialware_seed/kanban/`，`EzagentPluginKanban.Demo` 整模块溶解（Decision #156，`feat/sw-kanban-rework`）。
- **dealscout 自发布**：`apps/ezagent_plugin_crawler/.../application.ex` + `demo.ex`（同 kanban 形态）。→ **迁走 + 删自发布**。
- **home.init**（`apps/ezagent_core/lib/mix/tasks/ezagent.home.init.ex`）：mkdir `skeleton_dirs`（`home.ex:67`=`[:credentials,:db,:snapshots,:logs,:plugins]`）+ 幂等写文件（`unless File.exists? → File.write!`）。→ **扩展**：加 `:socialware` + seed copy。

## 4. seed 机制

**源位置**：`apps/ezagent_web/priv/socialware_seed/<name>/`（release 只打包 per-app priv，源须在某 app priv；选部署/装配顶层 `ezagent_web`，非 domain 非各 plugin；目录名 `socialware_seed` ≠ `socialware`，不被 app_sources 二次扫）。三个 flagship 的整目录（含 autoservice 资产）都搬进这里。

**seed 动作**：`Ezagent.Home.SocialwareSeed.seed!/0`（新模块，core）——枚举 `ezagent_web` 的 `priv/socialware_seed/*`，对每个 `<name>` 幂等 copy 到 `$EZAGENT_HOME/<profile>/socialware/<name>/`（`unless File.exists?` 跳过，尊重运维手改）。

**触发两处**：
1. `home.init`/`bootstrap` 安装时调 `seed!/0`（`Home.skeleton_dirs` += `:socialware`）——沿用现有幂等 seed 模式。
2. **boot 兜底**：`ManifestSeed.scan_all!` 的 `deploy_sources` 取路径前先调 `seed!/0`（幂等）——CI/dev 不跑 home.init 也能保证 flagship 在部署目录。放在车道侧（session 域）还是 web 触发点侧，实施时定；语义 = 扫描前确保部署目录已 seed。

## 5. gate（先写，driver）

新增 arch 规则（`mix ezagent.arch.scan` 扩展，与现有 AST/grep gate 同风格），禁止：
- **(a) 废弃位置**：任何 `apps/*/priv/socialware/*/manifest.yaml` 存在 = 红（只准 `socialware_seed` 源或 runtime 部署目录）。
- **(b) 非框架直接 seed**：plugin/非-core Application 在 boot 调 `ConfigGovernance.Socialware.publish_or_upgrade`（即已退役的 Demo 自发布形态）；非框架名 走 `DefinitionRegistry` builtin seed。框架内置（`chat`/`socialware`/`orchestrator`）走 allowlist。

**gate-first**：先落 gate（预期红），一次性抓出 autoservice(priv)、kanban(priv+自发布)、dealscout(priv+自发布)，然后照报错逐个修到绿。

## 6. 迁移（照 gate 报错逐个修）

- **autoservice**：`domain_session/priv/socialware/autoservice/` 整目录 → `ezagent_web/priv/socialware_seed/autoservice/`；改 `manifest_seed_test.exs:102`（原断言"从 domain priv 默认枚举发布" → 改断言"从部署目录 seed 后发布"或直接测 `seed!/0` + deploy_sources）。
- **kanban**：kanban plugin priv 旧目录 → `ezagent_web/priv/socialware_seed/kanban/`。**已完成**（`feat/sw-kanban-rework`）：自发布删除、`EzagentPluginKanban.Demo` 整模块溶解（Decision #156），manifest YAML 是唯一真相，测试直读 seed 目录。
- **dealscout**：`crawler/priv/socialware/dealscout/` → `ezagent_web/priv/socialware_seed/dealscout/`；删自发布；同 kanban。

## 7. 分支 / 执行顺序

1. 本分支 `feat/sw-deploy-seed`（off main）：seed 机制（源目录 + `SocialwareSeed.seed!` + home.init/boot 兜底）→ 写 gate（红）→ autoservice 迁移修绿 → 全套 arch/socialware 测试绿。**autoservice 是 main-resident，本 PR 内闭环**。
2. kanban（`feat/sw-kanban`）/ dealscout（`feat/sw-dealscout`）：rebase 到含本机制的 main 后，各自把 manifest 迁 `socialware_seed` + 删自发布 + 测试接线（各一个收尾 commit）。

## 8. 验证

- gate：`mix ezagent.arch.scan` 绿（无 `priv/socialware` 违规、无非框架自发布）。
- 部署目录 seed：起 scratch，`seed!/0` 后 `$EZAGENT_HOME/default/socialware/autoservice/manifest.yaml` 在；`mix ezagent.socialware.check autoservice-tier1` 13 断言绿（经部署目录发布）。
- `manifest_seed_test` + `manifest_yaml_test` + `apps/ezagent_core/test/architecture` 全绿。
- 全套 arch 重测（改了 core Home + 新 gate）。
- mise pin OTP27/1.18.4。

## 9. Follow-up

- **dead-path cleaner**（另开 issue）：迁移后 app_sources 扫描、各 plugin 退役的 Demo 自发布代码成死路径，需一个定期 cleaner 检测+清除（kanban 的 Demo 已在 `feat/sw-kanban-rework` 整体溶解，无死路径残留）。本 spec §3 是路径清单基准。
- registry / 远程 config-repo 家（#1218 提案 follow-up）：部署目录之上的"从 ezagent 直接安装"UI/registry，未来接。
