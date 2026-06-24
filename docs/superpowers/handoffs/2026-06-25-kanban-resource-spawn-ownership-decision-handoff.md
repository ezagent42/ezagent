# Handoff（架构决策，待 Allen 拍）：kanban resource:// scheme spawn 归属

> **Date:** 2026-06-25 · **From:** Claude(with Sy) · **To:** Allen
> **Tracking:** kanban PR(#964)解耦后留下的唯一架构决策点 · **Base:** `upstream/main` @ `a56ca149`
> **Status:** decision-pending — 代码能跑、过全 gate、当下安全；要 Allen 定"正式化 vs 重构"。

## 0. Mission（一句话）
kanban 是全仓**第一个把 `resource://` 当 live Kind** 的 plugin。它在自己的 `after_boot/0` 里 runtime 注册了 `resource` scheme 的 spawn fn（按 type 分流，只认 `kanban`）。这在字面上**绕过了 `spawns/0` gate**（plugin 不该注册 scheme 启动器，不变式 8）。需 Allen 定：把这个范式**正式化成 Decision**（代码不动），还是改成 **domain/core 拥有 + 注册表分流**。

## 1. Required reading
1. Skill `ezagent-developer` — 不变式 8（plugin 不拥有核心 scheme dispatcher）+ `references/how-to-recipes.md:20-30`（plugin 贡献 Kind 两条路）。
2. `docs/guide/world-coordination.md`（碰 world）。

## 2. 已核对的事实（grounded，勿翻案）
| # | 事实 | 依据 |
|---|------|------|
| 1 | `resource` 是核心 scheme | `apps/ezagent_core/lib/ezagent/plugin.ex:88` `@core_schemes` |
| 2 | kanban 是唯一在 plugin 层注册核心 scheme spawn fn 的 | `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:32-42`（全仓仅此一处 plugin 注册 scheme spawn） |
| 3 | `entity/session/template/system` 的 spawn fn 全在 core/domain | identity `application.ex:358`、session `application.ex:674/713/764` |
| 4 | `resource://` 此前无 spawn owner（只被 FsResolver 用来寻址 FS 字节，socialware/world 都这么用） | grep `resource://` 无第二个 spawn fn |
| 5 | `SpawnRegistry.register` 是 **scheme-keyed OVERWRITE** | `apps/ezagent_core/lib/ezagent/spawn_registry.ex:64` `:ets.insert` |
| 6 | gate（`reject_spawns!`/`check_spawns_empty`）只查声明式 `spawns/0`，看不到 `after_boot` 里的 register | `plugin.ex:442/523`、`ezagent_plugin_check.ex:639` |
| 7 | hello 等 plugin 不碰这问题——它们骑现成 scheme（`session://...:hello`/`entity://...:agent`），由 domain 启动；kanban 整棵树是独立真相源（`{:snapshot,:on_change}`+23 动作），**挂不进** session/workspace 当 Behavior slice | `ezagent_plugin_hello/.../app.ex:25-26`；kanban `kanban.ex` persistence |

## 3. 决策点 + 两个选项
**问题**：核心 `resource://` scheme 的 spawn 启动器，**该谁拥有、怎么按 type 分流**？

- **选项 A（务实，代码不动）**：承认"plugin 可拥有 `resource` scheme 的 **type-routing** 启动器（kanban 是第一例）",补一条 **GLOSSARY Decision Log**。理由：resource 的 type 轴本就自由（path a），kanban 只认自己的 type、reject 其它，当下无人被覆盖。
- **选项 B（干净，防未来）**：让 **core 或某 domain 拥有 `resource://` 启动器** + 一个 **`{type → spawn_thunk}` 注册表**（照搬 `AgentFlavorRegistry` 范式，`plugin.ex:468`），kanban 只**声明**自己这型进注册表、不再 OVERWRITE 整 scheme 槽。world 调用不变（仍走 `SpawnRegistry.spawn/1`）。

## 4. 风险（为什么不是纯务实就完）
`register` 是**整 scheme 一个槽、覆盖**。现在 resource 没第二个 Kind，安全；**哪天加第二个 resource Kind（如 uploads 做成 Kind），俩 plugin 抢这一个槽、谁后 boot 谁覆盖谁**——这正是不变式 8 要防的。选项 A 不消除这个未来脆弱性（只是声明它可接受）；选项 B 消除（domain 拥唯一槽、plugins 声明 type）。

## 5. 两次 skill-1 探查的 verdict（都附上，便于 Allen 权衡）
- **探查 1**：硬伤——用 `after_boot` runtime 后门精确绕过不变式 8 的专设 gate，plugin 占了核心 scheme dispatcher，建议选项 B。
- **探查 2**：技术合法且当下安全，是 path(a) 第一个正式实现；**代码不用改**，补 Decision 即可（选项 A）。**明确反对 path(b)**（kanban 树是独立真相源，挂 session/workspace 当 slice 语义不对、无先例）。

## 6. DoD（按 Allen 选的路）
- 选 A：一条 GLOSSARY Decision Log 记录 + `spawns/0` gate 旁补注释（说明 `resource` type-routing 经 Allen 批准的例外）。
- 选 B：core/domain 拥 `resource` 启动器 + type 注册表 + kanban 改为声明 type；全 gate 绿 + `check_invariants` + 新增"plugin 不可 OVERWRITE 核心 scheme 槽"的 hardening gate（堵 `after_boot` 后门）。

## 7. Merge model
kanban PR(#964)其余部分（world↔kanban 解耦）已 gate 全绿、可独立合；**本决策不阻塞 PR 功能**，但合前需 Allen 在 A/B 间拍一下（选 A 直接合 + 补 Decision；选 B 我做完重构再合）。

## 8. Dev prompt（Allen 拍完，给执行者）
> 实现 Allen 在「kanban resource:// spawn 归属」上选定的路：
> - **若选 A**：在 `GLOSSARY.md` Decision Log 加一条决策（plugin 可拥有 `resource` scheme 的 type-routing 启动器，kanban 首例，依据 resource type 轴自由 + 当下无主），并在 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:30` 的注释里引用该 Decision 号。不改代码逻辑。
> - **若选 B**：把 `resource://` 启动器所有权挪到 <Allen 指定的 core/domain>，新增一个 `{type → spawn_thunk}` 注册表（照 `apps/ezagent_core/.../agent_flavor_registry.ex` 范式），kanban 的 `application.ex` 改为**声明** `{"kanban", thunk}` 进该注册表（不再 `SpawnRegistry.register("resource", …)`）；world 的 `kanban_data.ex:ensure_spawned` 不变；补一条"plugin 不可注册核心 scheme spawn fn（含 after_boot）"的编译期 gate。全 gate + `check_invariants` 绿。
