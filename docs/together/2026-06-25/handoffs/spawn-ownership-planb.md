# Handoff: spawn-ownership-planb — review / cherry-pick Plan B（`resource://` spawn 归属重构，commit `9b2ede5b`）

> **Date:** 2026-06-25 · **From:** jjkysy(dev) · **To:** allen(lead) — review / cherry-pick
> **Tracking:** task `spawn-ownership-planb` · commit `9b2ede5b`（在 `kanban-clean`，HEAD）· **Base:** `origin/main` @ `a56ca149`
> **Status:** confirmed（代码已交、确定性 gate 全绿、真浏览器 e2e 已跑通 commit `5f5de0fa`）— 本任务是 **Allen review + 3 个归属决策确认**，不是 build。reviewer 可重启 phx 复跑确认。

## 0. Mission
`kanban-merge.md` §6 当时把 `resource://` spawn 归属列为 **#964 合并后的非阻塞清理**，给了 Plan A / Plan B 两条路。本 commit `9b2ede5b` 落地的就是 **Plan B**：照搬已验证的 `entity://` 范式——**domain 拥 scheme spawn dispatcher + 按 type 查表路由 plugin Kind，plugin 只声明 type**——把原先 kanban `application.ex` 在 `after_boot` 里调 `SpawnRegistry.register("resource", …)` 的"plugin 注册核心 scheme 启动器"后门彻底拆掉。这一步同时解掉 **#964 唯一真正的 CI 阻塞**（invariant 8 + `:ezagent_plugin_check` check 7 卡死 plugin 的 `*Registry.register`）。**你的活：review `9b2ede5b` 的 core/domain 改动 + 确认 §6 三个归属决策，然后决定 cherry-pick / 合 `kanban-clean`→main。** 代码已交、确定性 gate 全绿、真浏览器 e2e 已跑通（commit `5f5de0fa`，§5）；reviewer 可重启 phx 复跑确认。

## 1. Required reading（review 前）
1. Skill **ezagent-developer** — 17 条 invariants 是 review gate；本任务直接动 **invariant 8**（六个 URI scheme 全部 core/domain 拥有，plugin 永不拥有 scheme dispatcher，见 `apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex:646-661`）+ **P22**（可靠性原语/ETS 归 core，`EtsOwner` 拥表，plugin 绕不过）。
2. `docs/guide/world-coordination.md` — kanban 经 `world` 起活，本 commit 不动 world dispatcher，但归属决策影响 world 的 spawn 链路。
3. Skill **dev-together** — 本工作流 + handoff standard（demonstrable-DoD）。
4. **前序 handoff** `docs/together/2026-06-25/handoffs/kanban-merge.md` §6 —— Plan A/B 的来历（本 commit = 那里说的 Plan B）。
5. 本任务 return：`docs/together/2026-06-25/returns/spawn-ownership-planb.md`。
6. **对照范式（review 时并排看）**：`entity://` 已验证范式——
   - core 注册表：`apps/ezagent_core/lib/ezagent/agent_flavor_registry.ex`（本 commit 的 `ResourceKindRegistry` 是它的 `resource`-scheme 同构体）。
   - domain 拥 `entity` dispatcher：`apps/ezagent_domain_session/lib/ezagent_domain_instance_message/application.ex:674`（`SpawnRegistry.register("entity", …)` 按 `Ezagent.URI.type/1` 分流 user/agent，agent 查 `AgentFlavorRegistry`）+ `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex:358`。本 commit 的 workspace `resource` dispatcher 与之对等。

## 2. Locked decisions（已定，勿翻案）
| # | Decision | Value |
|---|----------|-------|
| 1 | 范式 | 照搬 `entity://`：domain 拥 scheme spawn dispatcher，按 `Ezagent.URI.type/1` 查 core 注册表找 Kind 模块；plugin 只在声明回调里给 `{type, kind_module}`，`boot/1` 代登记。plugin 永不碰 `SpawnRegistry`（invariant 8） |
| 2 | core 注册表 | 新 `Ezagent.ResourceKindRegistry`（bare ETS，house style 同 `AgentFlavorRegistry`），表名 `:ezagent_resource_kind_registry`（`:set`，key=type 字符串，value=Kind 模块），由 `EzagentCore.EtsOwner` 拥（进 `@tables`，P22，plugin 不能 lazy-init 绕过） |
| 3 | plugin 契约扩展 | `Ezagent.Plugin` 加 sanctioned `@callback resource_kinds() :: [resource_kind_decl()]`，默认 `[]`（`defoverridable`）；`boot/1` 消费→`assert_resource_kind!/2`（校验 Kind 实现 `Ezagent.Kind`）→`ResourceKindRegistry.register/2` |
| 4 | gate 认可 | `:ezagent_plugin_check` check 3（modules-implement-behaviour）新增一段，把 `resource_kinds/0` 的 Kind 当 sanctioned 声明出口（`ezagent_plugin_check.ex:247-256`）——plugin 用它**代替**被 check 7 拒的 `SpawnRegistry.register` boot hook |
| 5 | dispatcher 归属 | **workspace domain** 拥 `resource://` dispatcher（`ezagent_domain_workspace/application.ex` 的 `register_resource_spawn_fn/0`），对等 session domain 拥 `entity://`。dispatcher runtime 经 registry 解析 Kind，**不 compile-depend** plugin 模块 |
| 6 | kanban plugin | 删 `after_boot` 的 `SpawnRegistry.register`；改 `def resource_kinds, do: [{"kanban", EzagentPluginKanban.Kanban}]`。Kind/24 action/URI/world dispatch **零改动** |
| 7 | LOC 收口 | 加回调后 `plugin.ex` 破 1000 红线 → 抽 `Ezagent.Plugin.ConfigSurface`（把 `assert_config_surface!/2` 逐字搬出，行为 byte-for-byte 不变，单 caller=`publish/1`），降回 998。照 2026-06-23 >1000-LOC burn-down 既有先例，**不回弹 cap** |
| 8 | 注册表语义 | `register/2` 幂等（同 `{type,module}` 重登 = `:ok`）；同 type 不同 module → `raise ArgumentError`（两 plugin 抢同一 resource type = 真 bug）。`lookup/1` 返 `{:ok, module}` \| `:error`；未注册 type → dispatcher 返 `{:error, {:no_resource_kind, type}}`（不静默起空 Kind） |

## 3. Architecture primer（给 review 用）
三层各动一处，每处都贴着已验证范式：

- **core（`ezagent_core`）** — 4 文件 + 1 抽出 + 1 测试 + 1 manifest：
  - `lib/ezagent/resource_kind_registry.ex`（**新，84 行**）：`register/2` / `lookup/1` / `list_all/0` / `table/0`。moduledoc 直说"`AgentFlavorRegistry` 的 `resource`-scheme 同构体"。
  - `lib/ezagent_core/ets_owner.ex`：`@tables` 加 `{Ezagent.ResourceKindRegistry, :set}`（紧挨 `AgentFlavorRegistry`）。
  - `lib/ezagent/plugin.ex`：加 `resource_kind_decl/0` typedoc + `@callback resource_kinds/0` + `defoverridable` 默认 `[]` + `boot/1` 里一段 `Enum.each(plugin_module.resource_kinds(), …)` 登记 + `assert_resource_kind!/2`（镜像 `assert_agent_flavor!/2`）。同 commit 把内联 `assert_config_surface!/2` 全删、改调 `Plugin.ConfigSurface.assert!`。
  - `lib/ezagent/plugin/config_surface.ex`（**新，49 行**）：纯抽出，行为不变。
  - `lib/mix/tasks/compile/ezagent_plugin_check.ex`：check 3 链尾加 `check_modules(resource_kinds 的 kind_modules, Ezagent.Kind, "resource_kinds/0")`。
  - `test/architecture/arch_baseline_manifest.exs`：`undocumented_public_defs` 392→**393**（+1 = `resource_kinds/0` 的 `defoverridable` 默认 stub，macro-emit 的 public head 挂不了 `@doc`，与已有 11 个 sibling plugin-callback 默认同性质，注释里有 `arch-cap-bump` 理由）。
- **domain（`ezagent_domain_workspace`）** — `lib/ezagent_domain_workspace/application.ex`：`start/2` 加 `register_resource_spawn_fn/0`，注册 `resource` 的 spawn fn：`URI.type/1` → `ResourceKindRegistry.lookup/1` → `Ezagent.Kind.spawn/2`；type 查不到 → `{:error, {:no_resource_kind, type}}`，URI 无 type 段 → `{:error, {:resource_uri_has_no_type, …}}`。
- **plugin（`ezagent_plugin_kanban`）** — `lib/ezagent_plugin_kanban/application.ex`：删整个 `after_boot/0`（含旧 `SpawnRegistry.register("resource", …)`）；加 `def resource_kinds, do: [{"kanban", EzagentPluginKanban.Kanban}]`；moduledoc 改述"怎么起活（Plan B）"。

> ⚠️ **review 时一处要校准认知**：新 e2e 测试 `apps/ezagent_plugin_kanban/test/e2e/spawn_via_resource_dispatcher_test.exs` **不加载真的 workspace domain**——kanban 的 per-app test deps 只 dep core，不 dep `ezagent_domain_workspace`。该测试在 `setup` 里**复刻**了 `register_resource_spawn_fn/0` 的同构闭包（逐字一致），再断言"经 `SpawnRegistry.spawn` 起活 + add_node/per-node CapBAC/drop"。**真正"两域同 boot"的端到端由真浏览器 e2e（commit `5f5de0fa`，§5）+ umbrella `mix test` + `ezagent_web` 覆盖**——这正是 §5 DoD 那条"真浏览器 e2e"为什么 load-bearing（现已跑通）：per-app 测试证明了"闭包逻辑对"，但没证明"真 workspace domain 真注册了这个闭包、真起活了 kanban"；真浏览器 e2e 补上了这一证。

## 4. Design（+ review status）& 这是 review/cherry-pick 任务
**已是成品 commit，无需 build。** review 单元：
- **Phase R1 — 并排 diff 看范式对齐**：把 `ResourceKindRegistry` 对照 `AgentFlavorRegistry`、把 workspace `register_resource_spawn_fn/0` 对照 session 的 `entity` dispatcher（§1.6 路径）。确认是同构、不是新发明。
- **Phase R2 — 三个归属决策定夺**（§6 Discuss-first，这是本 handoff 的核心）。
- **Phase R3 — gate 复核**：确定性 gate 已绿（§5），reviewer 复跑确认。
- **Phase R4 — 合并决策**：真浏览器 e2e 已跑通（commit `5f5de0fa`，§5）；reviewer 可重启 phx 复跑确认，绿则 cherry-pick `9b2ede5b` 或合 `kanban-clean`→main。

设计未经独立 codex 对抗复审（dev 侧自审见 return §对抗自审）；本 handoff 请 lead 把 §6 三点当**对抗点**审。

## 5. Definition of Done（可展示产物 — 不止"测试绿"）
- [x] **确定性 gate 全绿**（dev 已确认）：
  - 全量 **architecture + invariants 串行 329 tests / 0 failures**。
  - 本 commit 新测试 **7/0**：`resource_kind_registry_test.exs` **5**（register/lookup/list_all/幂等/冲突 raise）+ `spawn_via_resource_dispatcher_test.exs` **2**（经 dispatcher 起活跑 add_node/CapBAC/drop + 未注册 type → `{:error, {:no_resource_kind, …}}` 不误起）。
  - `doc.scan` **393/393**、`arch.scan`（`set_effect_sites` **128/128**、spawn / oversized PASS）、`check_invariants` clean、`format` 过、`:ezagent_plugin_check` per-app 过、各 app 0 failures。
  - ⚠️ 全量**并行** 20 个失败 = 环境性超时；降并行 `--max-cases 4` → **0 failures**（与 #964 串行基线同性质的预存 flaky，**非本 commit 回归**）。
- [x] **真浏览器 e2e（已跑通）**：Plan B 后重启 df-tech 真浏览器跑通——`/plugins/kanban` 建板 / 加节点 / 认领 / 改状态 / 挂代码文件出站 / 9 阶段链 / drop，**全程经新 workspace `resource` dispatcher 起活**（看板经新 workspace dispatcher 起活；drop 截图实锤：节点砍掉 + drop 历史显示）。截图 commit `5f5de0fa`，产物在 `docs/superpowers/evidence/assets/{code-1-config,code-2-file,code-3-stages,drop-history}.png`。**reviewer 可重启 phx 复跑确认。** 理由见 §3 ⚠️：per-app 测试不加载真 workspace domain，故这条 e2e 是 load-bearing 验证。
- [x] **本任务自带回归测试**：上面 7 个（5 registry + 2 dispatcher-e2e）。

## 6. Discuss-first vs Deferred（都显式）
**Discuss-first（要 Allen 定夺，本 commit 已实现但归属待确认 — 这是 invariant-8 相关的架构决策，按 handoff-standard "touches core / cross-cutting invariant" 触发）：**
1. **`resource://` dispatcher 归 workspace domain 对不对？** —— `resource` scheme 该不该承载 **live Kind**（而非只 FS 寻址数据）?若该，dispatcher 放 **workspace** domain 对不对，还是别的 domain（identity / session / 新 domain）更合归属语义?这决定 invariant 8 在 `resource` 上的具体落点。**（核心决策，请先定这条）**
2. **新 core `Ezagent.Plugin` 回调 `resource_kinds/0`** —— 这是 plugin 契约扩展（与 `agent_flavors/0` 完全同范式）。core 契约面新增一个 sanctioned 声明出口，要不要进 GLOSSARY Decision Log?
3. **顺手抽 `Ezagent.Plugin.ConfigSurface`** —— 非本任务核心，是加回调撞 1000 红线后的内聚拆分（行为 byte-for-byte 不变，照 2026-06-23 既有 burn-down 先例，不回弹 cap）。确认这处"搭车改动"可接受 / 还是该单独成 PR?

> **阻塞 vs 非阻塞分级**：①②是**架构归属决策**——不定夺则不该把这套范式固化进 main（决定 invariant 8 与 plugin 契约的形状）。③是**风格/搭车**——不阻塞合并，确认即可。三点都已在代码里实现，请求的是 **confirm，不是 build**。

**Deferred（已 flag + 有去向）：**
- `kanban-merge.md` §6 的 **Plan A**（正式化"plugin 可拥有 resource type-routing 启动器"+ 补 gate 堵 `after_boot` 后门）—— 被本 Plan B **取代/作废**：本 commit 走的就是 Plan B，Plan A 不再需要。请在 review 时确认这条作废。
- 别的 plugin 想出 spawnable resource Kind 时复用本范式（声明 `resource_kinds/0` 即可）—— 自然延展，无需额外工作。

**Never deferred here：** §6 ①② 归属决策（load-bearing，决定要不要固化进 main）；确定性 gate 必须真绿（已绿）；真浏览器 e2e（已跑通 commit `5f5de0fa`，reviewer 可复跑确认，**没 silent scope past**）。

## 7. Conflict-avoidance
- **本 commit owns**：
  - `apps/ezagent_core/lib/ezagent/resource_kind_registry.ex`（新）、`apps/ezagent_core/lib/ezagent/plugin/config_surface.ex`（新）、`apps/ezagent_core/lib/ezagent/plugin.ex`、`apps/ezagent_core/lib/ezagent_core/ets_owner.ex`、`apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex`、`apps/ezagent_core/test/architecture/arch_baseline_manifest.exs`、`apps/ezagent_core/test/ezagent/resource_kind_registry_test.exs`（新）。
  - `apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex`。
  - `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex`、`apps/ezagent_plugin_kanban/test/e2e/spawn_via_resource_dispatcher_test.exs`（新）。
- **与 `kanban-merge`(#964) 的关系**：本 commit `9b2ede5b` 就在 `kanban-clean` 上、是 #964 PR 链的 tip 之后那一笔；它**改了 `arch_baseline_manifest.exs`**（392→393），与 #964 的 392 基线有依赖——**若 #964 已合或本 commit 一起合，manifest 取 393**；review 时确认这条 manifest 单调递增链没断。
- **碰 core 多 app**：`plugin.ex` / `ezagent_plugin_check.ex` / `ets_owner.ex` 是跨 app 共享面——按 handoff-standard "core (multi-app change)" 走 discuss-first（已在 §6）。
- 不碰 `config/dev.exs`、不碰 world dispatcher、不碰 Kind/Behavior/action 主体。

## 8. Merge model
本 commit 在任务分支 `kanban-clean`（不直接进 main）；保持 rebase 在 `main`（当前 base `a56ca149`）。**§6 ①② 归属决策 confirm + 真 e2e 截图绿后，lead 决定** cherry-pick `9b2ede5b` 单独成 PR、或随 `kanban-clean`→main 一起合（dev-together `close`）。lead 是唯一进 main 的路径。

## 9. Gates, file/LOC estimate, open questions
- **Gates**（dev 已跑绿，reviewer 复核）：`arch.scan`（`set_effect_sites` 128/128 + spawn/oversized PASS）、`doc.scan` 393/393、`check_invariants` clean、`format`、`test`（arch+invariants 串行 329/0 + 新 7/0）、`:ezagent_plugin_check`（check 3 认 `resource_kinds`、check 7 仍拦裸 `*Registry.register`）。
- **改动规模**（`git show 9b2ede5b --stat`）：**10 文件，+428 / −58**。新文件 3：`resource_kind_registry.ex`(84)、`config_surface.ex`(49)、`spawn_via_resource_dispatcher_test.exs`(112) + `resource_kind_registry_test.exs`(58)。`plugin.ex` 改后 **998 行**（< 1000 红线）。
- **Open questions（给 lead）**：
  1. §6 ① — `resource` dispatcher 归 **workspace** domain，确认归属语义对?还是该换 domain?
  2. §6 ② — `resource_kinds/0` core 契约扩展进 GLOSSARY Decision Log?
  3. §6 ③ — `ConfigSurface` 搭车抽出可接受、还是拆单独 PR?
  4. `kanban-merge.md` §6 的 **Plan A 作废**（被本 Plan B 取代）—— 确认?
  5. 本 commit `arch_baseline_manifest` 392→393 与 #964 的 392 基线 —— 一起合 / cherry-pick 时按 393，确认单调链没断?
