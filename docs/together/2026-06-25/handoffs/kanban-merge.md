# Handoff: kanban-merge — review + merge PR #964（`kanban-clean` → main）

> **Date:** 2026-06-25 · **From:** allen(lead) · **To:** an independent developer (human + cc/codex)
> **Tracking:** PR #964 / task `kanban-merge` · **Base:** `origin/main` @ `e3b6ffba`（kanban-clean 已 rebase 其上）
> **Status:** confirmed — review+merge 阶段。代码已交、已 rebase、**#964 整个 CI 已绿（含 Plan B `9b2ede5b`）**、tip `5f5de0fa`（+ e2e 截图）；本任务是 **review→merge**，不是 build。

## 0. Mission
PR #964 交付新插件 `ezagent_plugin_kanban`（产品自举开发流程看板：9 阶段接力链 positioning→…→pr，24 action，per-node CapBAC，出站 GitHub/Miro/CI/Markmap/BoardConfig）+ world↔kanban 解耦（出站/CI/配置/spawn 下沉进 Behavior，world 退成薄 dispatcher + UI-state reader）。代码已在 `kanban-clean`、已 rebase 当前 main、CI 失败已修（`56ab78ba`+`beebdfdd`）+ **`resource://` spawn 已走 Plan B 落地（`9b2ede5b`）、#964 整个 CI 已绿**。**你的活：拉 PR、过一遍 review、确认 DoD 4 截图 + CI 已绿、然后 lead 合 `kanban-clean`→main。** Plan B 剩 3 个归属决策待 Allen（见 §6 + `spawn-ownership-planb.md`，不阻塞本次合并）。

## 1. Required reading（review 前）
1. Skill **ezagent-developer** — 17 条 invariants 是 review gate；尤其 P14（dispatch 唯一跨 Kind 路径）、不变式 8（plugin 不拥有核心 scheme dispatcher）。
2. `docs/guide/world-coordination.md` — **必读**：本 PR 改 `world`（kanban_actions/data/routes/world_live）。
3. Skill **dev-together** — 本工作流 + handoff standard（demonstrable-DoD）。
4. 本 PR 的 return：`docs/together/2026-06-24/returns/kanban-plugin.md`。
5. 当前设计 spec：`docs/superpowers/specs/2026-06-25-kanban-current-design.md`（本 PR 清理后保留的）。
6. `resource://` spawn 归属 —— **Plan B 已落地（commit `9b2ede5b`）**，详见 `docs/together/2026-06-25/handoffs/spawn-ownership-planb.md`（+ 摘要在本 handoff §6）。剩 3 个归属决策待 Allen，不阻塞本次合并。

## 2. Locked decisions（已定，勿翻案）
| # | Decision | Value |
|---|----------|-------|
| 1 | 真相源 | 真相源在 ezagent；GitHub/Miro/excalidraw/Markmap 纯**出站投影**，不回写 |
| 2 | 跨 Kind | 所有 kanban 动作经 `Ezagent.Invocation.dispatch/1`（P14），world 不直引 kanban plugin 连接器 |
| 3 | spawn 入口 | spawn 走 owner-gated chokepoint `Ezagent.LocalRuntime.ensure_started/1`（`world/kanban_data.ex:89` 一行替原 `SpawnRegistry.spawn`，同修 locality + chokepoint） |
| 4 | per-node CapBAC | 在 Behavior 内如实判，world 层不放水（ctx 带 `current_entity_uri`/`current_caps`） |
| 5 | world↔kanban 依赖 | world 声明 kanban umbrella dep（过 UndeclaredDep gate）；下沉 world 操作面是**后续更大重构**，本 PR 不做（§6 deferred） |
| 6 | CI 修法（**不引入 Allen 决策**） | **8 个** architecture/invariant 真失败分两批修：**`56ab78ba`**（6 个：spawn 单入口走 `LocalRuntime.ensure_started` 同修 locality+chokepoint、`miro_sync` sidecar 豁免、3 处 uri-query、`kanban.ex` 拆 Connectors+Shared 1085→779、web 接线）+ **`beebdfdd`**（DocCoverage：Connectors 9 个内部函数加 `@doc false` 401→392；EffectDiscipline：拆模块的 4 处注释 `{:set,:tree}` 字面被 scanner 误数→改措辞 132→128，真 `commit/1` 收口站点不动）。验证：全量 arch+invariants 串行 **329/0** + doc.scan 392/392 + uri_query 0 + check_invariants clean + format。web router 接线在解耦 commit `2315bf7f` |

## 3. Architecture primer（给新接手 review 的 dev）
- **新插件** `apps/ezagent_plugin_kanban/`：
  - Behavior：`lib/ezagent/behavior/kanban.ex`（**779 行**，已从 1085 拆出 `kanban/connectors.ex` + `kanban/shared.ex`）。**契约用 `use Ezagent.Lifecycle` + `action(:foo, …)` 宏 + `create/1` + `handle_<action>/2`**（不是 CLAUDE.md 泛述的 `use Ezagent.Behavior`）；24 个动作经 `action/3` 宏声明，与 `world_live.ex` 的 24-action allowlist 对齐。
  - 出站连接器：`lib/ezagent_plugin_kanban/{github,miro,miro/sync,miro_sync,ci,markmap,board_config}.ex`。
  - 注意 `lib/ezagent_plugin_kanban/kanban.ex`（34 行）是 thin 入口，**不是** Behavior 主体；主体在 `lib/ezagent/behavior/kanban.ex`。
- **world 解耦**（`apps/ezagent_plugin_world/`）：
  - `lib/ezagent/world/kanban_actions.ex`（386 行）= **纯 dispatcher**，moduledoc 明说"退成纯 dispatcher，原直引 kanban plugin 连接器逻辑全部下沉进 Behavior"。
  - `lib/ezagent/world/kanban_data.ex`（256 行）= UI-state reader + spawn chokepoint（`LocalRuntime.ensure_started/1` @ line 89）。
  - 前端：`assets/src/components/{Kanban,KanbanCanvas,ExcalidrawModal,Conversation}.tsx`、`slots.manifest.json`、`scripts/check-mounts.mjs`。
- **web 接线**：`apps/ezagent_web/lib/ezagent_web/router.ex`。
- **core 不变式测试**：`apps/ezagent_core/test/invariants/single_spawn_entry_test.exs` + `test/architecture/arch_baseline_manifest.exs`（CI 修的一部分）。

> ⚠️ **要校正 return 文档一处措辞**：return 说 world "0 kanban 引用 / 纯 dispatcher"。**字面不准**——world `lib/` 里仍有多处 `kanban` 名字（`world_live.ex` 的 24-action allowlist、`kanban_actions.ex` 路由、`kanban_data.ex` UI 读、`routes.ex`/`slot_registry.ex`/`conversation_actions.ex`）。**准确说法**：出站/CI/配置/spawn 的**逻辑**下沉进 Behavior，world 不再**直引 kanban plugin 连接器模块**；但 world 仍保留薄 dispatcher + UI-state reader + action allowlist。review 时按这个准确边界看，别因为"0 引用"措辞误判解耦不彻底。

## 4. Design（+ review status）& phased plan
**已是成品 PR，无需再 build。** review-merge 单元如下：
- **Phase R1 — 拉 PR + rebase 确认**：确认 `kanban-clean` tip `5f5de0fa`（= Plan B `9b2ede5b` + e2e 截图 `5f5de0fa`，接在 #964 PR 链 `beebdfdd` 之后）已含当前 main `e3b6ffba`（已核对 = YES）。若 main 又前进，先 rebase。
- **Phase R2 — code review**：按 §1 invariants 过 diff。重点：P14 dispatch、spawn 单入口（`LocalRuntime.ensure_started`，grep 确认无残留 `SpawnRegistry.spawn`/`DynamicSupervisor.start_child` 在 world kanban 路径）、per-node CapBAC world 层不放水、出站连接器只在 plugin 内。
- **Phase R3 — gate 跑绿**：见 §5。CI 重跑中（8 个真实失败已修，全量 arch+invariants 串行 329/0）。
- **Phase R4 — lead merge**：DoD 全绿后，**lead** 合 `kanban-clean`→main。

## 5. Definition of Done（可展示产物 — 不止"测试绿"）
- [ ] **浏览器 e2e 4 截图**（已有，肉眼可看）：`docs/superpowers/evidence/assets/{code-1-config,code-2-file,code-3-stages,drop-history}.png`（每图配置 / 挂代码文件 SHA 链接 / 9 阶段接力链树 / drop 历史侧栏）。
- [x] **#964 整个 CI 已绿（含 Plan B）**：8 个 architecture/invariant 真实失败已在 `56ab78ba`+`beebdfdd` 修（含 DocCoverage、EffectDiscipline）+ Plan B `9b2ede5b` 解掉 `resource://` spawn 的 invariant 8 + check 7 真阻塞；**全量 architecture+invariants 串行 `--max-cases 1` = 329 tests, 0 failures**（Plan B 后基线，含新 7 个 registry/dispatcher 测试）。⚠️ **并行下有预存的异步 test-isolation flaky（locality-text / sandbox-ownership，与本 PR 无关）；串行干净** —— 判 CI 结果时按串行基线，flaky 不算回归。
- [ ] **全 gate 绿**：`arch.scan`、`doc.scan`、`uri_query.scan`、`check_invariants`（8/8）、`format`、`test`、`:ezagent_plugin_check`。
- [ ] **本 PR 自带回归测试**：`drop_subtree` 图级别 drop 历史断言（`apps/ezagent_plugin_kanban/test/behavior/kanban_test.exs`）+ `single_spawn_entry_test.exs`。

## 6. Discuss-first vs Deferred（都显式）
**Discuss-first（本次合并不需要、但 Allen 该看的非阻塞架构备注）：**
- `resource://` scheme spawn 归属：**Plan B 已落地（commit `9b2ede5b`）** —— 原先 kanban `after_boot` runtime 注册 `resource://` scheme spawn fn（字面擦**不变式 8**）的后门**已删**、搬到 **workspace domain** 拥 `resource` dispatcher + core `ResourceKindRegistry`（`{type→Kind}` 注册表，照 `AgentFlavorRegistry`），kanban 只声明 `resource_kinds/0`。**CI 已绿**（含解掉 invariant 8 + check 7 的真阻塞）。剩 **3 个归属决策待 Allen**（dispatcher 归 workspace 对不对 / `resource_kinds/0` 契约扩展进 Decision Log / `ConfigSurface` 搭车抽出），见 `docs/together/2026-06-25/handoffs/spawn-ownership-planb.md` §6。**不阻塞本次合并。**

**Deferred（已 flag + 有去向）：**
- agent 自动改看板（Track 2，分支 `kanban-agent-mcp`，暂停中）→ `docs/superpowers/handoffs/2026-06-25-kanban-agent-mcp-build-handoff.md`（在该分支；通用 Kind-MCP 桥，kanban 首个消费者）。
- world→kanban umbrella 依赖下沉进 `ezagent_plugin_kanban`（更大重构）→ return 文档 §Merge request 注。

**Never deferred here：** CI 必须真绿（不是"串行绿就跳过 CI"）；spawn 单入口；per-node CapBAC 不放水。

## 7. Conflict-avoidance
- **本 PR owns**：`apps/ezagent_plugin_kanban/**`、`apps/ezagent_plugin_world/**`（kanban 操作面 + 前端）、`apps/ezagent_web/lib/ezagent_web/router.ex`、`apps/ezagent_core/test/{invariants/single_spawn_entry_test,architecture/arch_baseline_manifest}.exs`、`apps/ezagent_web/mix.exs`。
- **碰 world** → 已读 `world-coordination.md`（§1.2）；解耦后 world kanban 面是 dispatcher，不与其他 in-flight world 工作抢同一 handler。
- **与 watcher-merge（#963）零冲突**：watcher 只动 `config/dev.exs`，**本 PR 自身 commit 不碰 `config/dev.exs`**（已核对 `comm -12` 交集为空）。两 PR 任意顺序合。

## 8. Merge model
PR #964 的所有改动已在任务分支 `kanban-clean`（不直接进 main）；保持 rebase 在 `main`；**DoD 满足后，lead 合 `kanban-clean`→main**（dev-together `close`）。lead 是唯一进 main 的路径。

## 9. Gates, file/LOC estimate, open questions
- **Gates**：`arch.scan` / `doc.scan` / `uri_query.scan` / `check_invariants`(8/8) / `format` / `test`（串行基线 28/0）/ `:ezagent_plugin_check`。
- **改动规模**（本 PR 自身 5 commit）：114 文件，43 在 apps/config/mix；Behavior 主体 779 行（自 1085 拆 Connectors+Shared）；spec 清理删 **7**（含 `_em-design-review.md`、4 个 mindmap-* 旧设计、2 个 agent-* ）+ 建 1（`2026-06-25-kanban-current-design.md`），与 return"删 7 留 4 建 1"一致。
- **Open questions（给 lead）**：
  1. CI 重跑结果——若并行出 test-isolation flaky，按串行基线判（非回归）还是要先稳住 flaky 再合？
  2. return 的 "world 0 kanban 引用" 措辞要不要顺手在 merge commit / PR 描述里改成 §3 的准确边界，避免后人误读？
  3. §6 的 resource-spawn：**Plan B 已落地（`9b2ede5b`）、CI 已绿**，剩 3 个归属决策待 Allen（见 `spawn-ownership-planb.md` §6）。这 3 点不阻塞本次合并，OK 合后单独确认/cherry-pick？
