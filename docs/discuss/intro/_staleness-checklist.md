# intro/ 文档过时清单（main e2abc02f → b6818123，+59 提交）

> 审阅时间：2026-06-22。审阅基准：上游 main 已从 `e2abc02f` 推进到 `b6818123`。
> 本清单只列**确有变化处**，每条给【哪篇 / 原文 / 应改成什么】。已核实的代码事实见文末「核实记录」。

## 两大已核实变化（贯穿全篇）

1. **world 落地、liveview 退役**：`apps/ezagent_plugin_liveview` 已**物理删除**；新增 `apps/ezagent_plugin_world`——它是新的统一前端（React/shadcn + Vite，跑在一层 LiveView SSR/comms shell `WorldLive` 里，用 `phx-hook="WorldRenderer"` 注水 React/TSX islands），**复刻并取代了原 LiveView 管理面**，挂在 `host: "world."`。仍 21 个 app（liveview 删 1、world 加 1）。
   - ⚠️ 边界（别改过头）：world 目前**只接管运营/作者面（operator/author surface）**。**客户面**（`/socialware/chat`、`/socialware/customer`）**仍在旧栈** `ezagent_web` + `ezagent_domain_socialware` 上没动。"world 最终也收编客户面"这件事**仍然是 future**（socialware skill §Future 明确还没做）。所以凡是讲"客户看到的 React + json-render SPA""两个公开面控制器在 ezagent_web"这类**客户面描述都没过时，保留**。
2. **agent-contract / agent-schema 落地**：`apps/ezagent_core/lib/ezagent/agent_manifest/tools.ex`、`apps/ezagent_core/lib/ezagent/agent_manifest.ex`、`apps/ezagent_cli/lib/ezagent_cli/agent_manifest_facade.ex` 已存在（agent manifest 工具契约、versioned artifact pin、ledger-tracked migrate_session）。socialware skill 已把 world + agent-definition-contract 标为"**已落地 landed on main**"（#882），不再是 future。

---

## 00-总览.md

| # | 原文 | 应改成 |
|---|---|---|
| 00-1 | 第 3 行 `> 上游最新 main（`e2abc02f`，2026-06-21）。` | SHA 改 `b6818123`（日期相应更新到本次审阅日 2026-06-22；下同，每篇头部 SHA 都要改）。 |
| 00-2 | 第 26 行插件层清单 `... feishu(渠道) · liveview(前端)` | `liveview(前端)` 改成 `world(统一前端/管理面)`。liveview 已删。 |
| 00-3 | 第 44-48 行「产品方向」：`上游正在建两条线把客户产品"产品化"：- **world** = 新的**统一前端**，会退役 LiveView 管理面、最终收编客户面 →…- **agent-schema** = 编排契约…` | 改成「**world 与 agent-schema/agent-contract 已落地 main**」：world = 已落地的统一前端，**已退役并取代 LiveView 管理面**（运营/作者面），收编客户面仍是 future；agent-schema/agent-contract = 已落地的编排契约（versioned 模板 + 编排器工具目录 + ledger-tracked migrate_session）。`loom/autoservice` 仍是设计词汇没进代码——这条保留。 |
| 00-4 | 第 52 行 `前端 liveview 当前有一批确定性失败` | 主语 `liveview` 已不存在；改为「前端 world 当前有一批确定性失败」或按 bootstrap 新产物重述（liveview 已删，原失败描述需以 world 为准重新核对）。 |

## 01-核心框架层.md

| # | 原文 | 应改成 |
|---|---|---|
| 01-1 | 第 3 行 `> 上游最新 main（`e2abc02f`）。` | SHA 改 `b6818123`。 |
| 01-2 | 第 26 行分发链路图 `外部入口(webhook/CLI/API/LiveView)` | `LiveView` 改 `world`（或写 `web`）。这是举例入口，liveview 已退役。 |
| — | （其余 core 的 file:line：`invocation.ex:88`、`router.ex:79` 抽查**仍准确**，不动。） | — |

## 02-领域层全览.md

| # | 原文 | 应改成 |
|---|---|---|
| 02-1 | 第 6 行 `> 上游 main：`e2abc02f`。` | SHA 改 `b6818123`。 |
| — | 本篇讲 domain 层（10 个 domain app），不涉及 liveview/world（那是 plugin 层）。`public_view.ex:38`、socialware/identity 各 file:line 抽查**仍准确**。**正文无需改，仅改头部 SHA。** | — |

## 03-插件与传输层.md

| # | 原文 | 应改成 |
|---|---|---|
| 03-1 | 第 2 行 `> …（worktree HEAD `e2abc02f`）…` | SHA 改 `b6818123`。 |
| 03-2 | 第 96-99 行整节「### liveview —— 实时网页 / 管理面」（讲 `apps/ezagent_plugin_liveview/.../application.ex:52`、"它本身就是那套网页管理界面"） | **整节重写为 world**：标题改「### world —— 统一前端 / 管理面」。world 是 React/shadcn(+Vite) 前端跑在一层 LiveView SSR/comms shell（`WorldLive`）上，注水 TSX islands，取代了原 liveview 管理面。入口 `apps/ezagent_plugin_world/lib/ezagent_plugin_world/application.ex`（`start/2` 即 `Ezagent.Plugin.boot/1`）。它**声明了一个 behavior**（`{Ezagent.Entity.Workspace, :manage, Ezagent.World.Behavior.Layout}`，与旧 liveview "不带任何实体/行为"不同，原文那句要删/改），并有 `after_boot/0`（`LayoutBootstrap.ensure_system_admin_manage_cap`）。挂在 `host: "world."`。 |
| 03-3 | 第 126-130 行「⚠️ 两点提醒」第 1、2 条（"liveview 当前有一批测试确定性失败""liveview 这套管理面未来会被退役…正在建一条叫 world 的新线…见 08 篇 Future"） | 第 2 条作废：world 已落地、liveview **已退役删除**，不再是 future。改为陈述现状（world 即现行管理面）。第 1 条的"liveview 测试失败"改为按新 bootstrap 产物以 world 为准重述。 |
| 03-4 | 第 143 行 `- socialware 产品线与 world/Future：`docs/discuss/intro/08-socialware深入.md`` | 措辞 "world/Future" 暗示 world 是 future，改为「socialware 产品线与 world（已落地）」。 |

## 04-如何使用ezagent.md

| # | 原文 | 应改成 |
|---|---|---|
| 04-1 | 第 5 行 `> 上游最新 main（`e2abc02f`）。` | SHA 改 `b6818123`。 |
| 04-2 | 第 56-59 行「⚠️ 已知坑（这版前端）」：`LiveView 管理面有一批确定性测试失败…` + 第 59 行 `world 这条线在建、会退役并替换这套 LiveView 管理面（见 08 Future）` | 第 59 行作废（world 已落地、liveview 已删，非 future）。前面"LiveView 管理面坏按钮"那段需按 world 现状重核——主语已不是 liveview。整段以新 bootstrap 产物为准重写。 |
| 04-3 | 第 63 行 `当前不是全绿(前端那批确定性失败)` | "前端那批"主语从 liveview 改为 world（或按新产物重述）。 |

## 05-编排器与客户界面生成.md

| # | 原文 | 应改成 |
|---|---|---|
| 05-1 | （本篇头部无 SHA 行，正文以 file:line 为主。cc 编排器 MCP / turn / CustomerFeed / json_render 各 file:line 属客户面+编排链路，**未受 world/liveview 变化影响，正文保留**。） | — |
| 05-2 | 第 35 行 `运营/管理员那套手写界面（今天是 LiveView）是另一回事。` | `（今天是 LiveView）` 改 `（今天是 world）`。 |
| 05-3 | 第 162 行 `**产品化方向（还没进 main，别当已有）**：`world`（统一前端，最终吃掉客户面）+ `agent-schema`（编排契约规范）。今天 `/socialware/chat` 这套…是过渡形态。` | "还没进 main"已过时：world + agent-schema **已落地**。改为：world（统一前端，已落地、已取代管理面；**收编客户面仍是 future**）+ agent-schema/agent-contract（编排契约，已落地）。"`/socialware/chat` 仍是当前客户面形态"这点保留（客户面确实还在旧栈）。 |

## 08-socialware深入.md

| # | 原文 | 应改成 |
|---|---|---|
| 08-1 | 第 3 行 `> 基于上游最新 main（`e2abc02f`，2026-06-21）…` | SHA 改 `b6818123`，日期更新。 |
| 08-2 | 第 35 行 `运营/管理员那套手写界面（今天是 LiveView）是另一回事。` | `（今天是 LiveView）` 改 `（今天是 world）`。 |
| 08-3 | 第 50 行坑 #2 `LiveView 管理界面和 world 里都还没有勾选框（world 会加）` | 与 skill 现状冲突：skill 称 world 已有「Public socialware app」toggle + Session templates 作者流。改为「world 已提供 `public_view` 作者面（Session templates / toggle）」，liveview 已删不再提。**建议读 skill §Path-A world UI 核实 toggle 现状后定稿。** |
| 08-4 | 第 65-71 行整节「## 产品方向：world + agent-schema（还没进 main，别当已有）」（含"两条在建的线""world 第一目标是复刻并退役管理端 LiveView 插件…最终也会吃掉对外/客户面""今天 /socialware/chat 是过渡形态""agent-schema —— 一份规范…"） | **整节重写**：world + agent-schema/agent-contract **已落地 main**（#882，skill §"landed on main"）。world 已复刻并退役 liveview 管理面（operator/author surface 现在就是 world）；**"world 吃掉客户面"仍是 future**（保留为 future）；agent-schema/agent-contract 已落地（versioned 模板 + 编排器工具目录 + ledger-tracked migrate_session）。`loom/autoservice` 仍没进代码——保留。 |
| 08-5 | 第 56-63「关键模块速查」未列 world | 可补一行 world 作者面模块：`EzagentPluginWorld.WorldLive` + `Ezagent.World.WorkspacePluginActions`（`save_session_template/2` 写 `public_view`）。 |

## 09-如何在ezagent上搭建新app.md

| # | 原文 | 应改成 |
|---|---|---|
| 09-1 | 第 3 行 `> 基于上游最新 main（`e2abc02f`）。` | SHA 改 `b6818123`。 |
| 09-2 | 第 104-109 行「## 产品方向」：`- **world** = 正在建的**统一前端**，会退役 LiveView 管理面…- **agent-schema** = 编排契约…- **loom/autoservice** = …没进代码` + 第 109 行结论"在建的 world/agent-schema 方向上设计" | world/agent-schema 从"正在建"改为"已落地"：world = 已落地的统一前端，**已退役/取代 LiveView 管理面**（`public_view` toggle、作者 UX 已在 world），收编客户面仍 future；agent-schema/agent-contract = 已落地编排契约。loom/autoservice 仍没进代码——保留。第 109 行"在建的 world/agent-schema 方向"相应改为"已落地的 world/agent-schema 底座"。 |
| 09-3 | 第 24 行 `（参见 [05 插件层](./05-插件层.md)）`、第 38 行 `[01 core](./01-core-框架层.md)` | 顺带修：链接文件名错（应为 `03-插件与传输层.md`、`01-核心框架层.md`）。与本次 main 推进无关，但既然要改这篇可一并修。 |

---

## 核实记录（本次审阅实查，供改稿引用）

- **app 数 = 21**：`ls apps/` 21 项；`ezagent_plugin_liveview` 不存在，`ezagent_plugin_world` 存在。
- **world 形态**：`application.ex` moduledoc 自述 "React/shadcn ezagent app over a LiveView comms shell"；`assets/` 下有 `vite.config.ts`、`src/main.tsx`、`tsconfig.json`（React/TSX + Vite）；声明 behavior `{Ezagent.Entity.Workspace, :manage, Ezagent.World.Behavior.Layout}` + `after_boot` LayoutBootstrap。
- **客户面仍在旧栈**：`apps/ezagent_web/.../router.ex` 中 `/socialware/customer`、`/socialware/chat` 仍指向 `Socialware.CustomerController` / `Socialware.ChatFeedController`；world scope 是独立的 `host: "world."`。→ 客户面相关文档段落**不过时**。
- **agent_manifest 落地**：`apps/ezagent_core/lib/ezagent/agent_manifest.ex`、`.../agent_manifest/tools.ex`、`apps/ezagent_cli/lib/ezagent_cli/agent_manifest_facade.ex` 均存在。
- **socialware skill 现状**（`.claude/skills/ezagent-socialware/SKILL.md`）：明文 "world + agent-definition-contract have already landed on main"；"old `ezagent_plugin_liveview` admin plugin is fully removed"；"operator/author surface is now `ezagent_plugin_world`"；"world subsuming the customer surface" 列在 §Future（仍未做）。
- **抽查 file:line 仍准确**：`invocation.ex:88`（dispatch 收口）、`router.ex:79`(shim)、`public_view.ex:38`、feishu `application.ex:70` 均对得上，无需改。
- **残留 liveview 引用**：仅测试文件名里有 `lv_cli_parity` / `lv_parity`（是 world↔CLI parity 守卫，含 `refute File.dir?(.../ezagent_plugin_liveview)` 断言删除），代码/config 无 liveview app 引用。
