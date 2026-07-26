# Handoff: unfurl → world 通用能力（从 kanban 抽出）

> **Date:** 2026-07-24 · **From:** jjkysy（lead）· **To:** an independent developer (human + cc/codex)
> **Tracking:** PR #1569 · **Base:** `origin/main` @ `b9b548c8`（含 #1531 world 去 kanban + C0–C4）
> **Status:** confirmed — world 消息链接 unfurl 从 kanban 专属抽成通用能力，镜像 plugin-page-renderers manifest。

## 0. Mission

把原本 kanban 专属、写死在 world `Conversation.tsx` 里的「聊天消息里的链接 unfurl 成气泡」机制，抽成 **world 的通用能力**——任何插件都能声明自己的 unfurl 渲染器（链接模式 + 气泡组件），world 消息渲染时命中就渲成气泡代替裸链接。#1531（world 甩掉 kanban）之后 world 必须保持通用，unfurl 不能是 kanban 特例。

## 1. Required reading (before writing code)

1. Skill `ezagent-developer` — P1–P26 原则 + arch gate（本任务撞 `PluginWorkspaceLocalityContractTest` 行锚 baseline，见 §5/§9）。
2. `docs/guide/world-coordination.md` — 本任务动 `world` 前端，REQUIRED。
3. 参照实现：#1476 plugin-owned UI surfaces（`mix world.renderers.manifest` → `plugin-page-renderers.tsx` 的声明式生成模式，本任务照抄这套姿势做 unfurl）。
4. `dev-together` skill — 流程 + handoff 标准。

## 2. Locked decisions (settled — do not re-litigate)

| # | Decision | Value |
|---|----------|-------|
| 1 | 通用化姿势 | 镜像 plugin-page-renderers manifest（声明式 + 构建期生成 + Vite 静态打包，零动态加载） |
| 2 | 本 PR 边界 | **纯 world、零 kanban**——kanban 侧的 unfurl 声明 + Bubble 组件属下游 #1474 |
| 3 | 空注册表行为 | 无插件声明 unfurl 时 `pluginUnfurlRenderers=[]` → `matchUnfurl` 恒 null → 与 main 行为完全一致（单独 merge 零风险） |
| 4 | 类型依赖方向 | 类型（`UnfurlBubbleProps`/`UnfurlRendererEntry`）都定义在 world `unfurl.tsx`，生成的 manifest 只 `import type` 它们（单向，无运行时循环） |

## 3. Architecture primer

- `Ezagent.World.PluginPageRegistry.pages()`（`apps/ezagent_plugin_world/lib/ezagent/world/plugin_page_registry.ex`）= 插件页面声明的运行时索引；每条经 `Ezagent.World.UiSurfaceProvider.validate_page/1` fail-closed 校验。
- `mix world.renderers.manifest`（`apps/ezagent_plugin_world/lib/mix/tasks/world.renderers.manifest.ex`）读 `pages()` 生成 `apps/ezagent_plugin_world/assets/src/generated/plugin-page-renderers.tsx`（含 `--check` CI 模式）。
- world 前端 `Conversation.tsx` import 生成的注册表，`activeMode` 经 `pluginPageRenderers[activeMode]` 渲染插件页。
- **本任务的接入点**：给上述三处各加一条 unfurl 平行车道。

## 4. Design & phased plan（单 PR）

1. **pages() 声明扩展**：可选 `unfurl: [%{id, pattern, renderer: %{source, export}}]`；`UiSurfaceProvider.valid_unfurl_renderer?/1` fail-closed 校验（id 过 key 正则 / pattern 非空 binary / source 限 `assets/src/` + `.ts(x)` 无 `..` / export 非空）。**注意**：registry 的 `@type page` **不要**加 unfurl typespec 行——它会移位后面 baselined 的访问行、撞行锚 baseline（见 §5）；字段靠 validate_page 校验 + `resolve/1` 的 `Map.put(page, :provider, provider)` 整体透传即可工作，无需 typespec。
2. **manifest 生成**：`generated_source/1` 追加 `pluginUnfurlRenderers`（每条 `{id, pattern: new RegExp(...), component}`）；`import_path` 泛化供 unfurl 条目复用。无声明 → 空数组。
3. **world 通用 `unfurl.tsx`**：`UnfurlContext`/`UnfurlBubbleProps`/`UnfurlRendererEntry` 类型 + `matchUnfurl(text)`（读生成注册表，第一个命中即返回 `{entry, url, rest}`）。
4. **Conversation.tsx 集成**：消息渲染点 `const unfurl = matchUnfurl(text)`；命中 `React.createElement(unfurl.entry.component, {url, rest, ctx})`，未命中裸文本。**最小侵入**。

## 5. Definition of Done — 闭合清单

- [x] `pages()` 接受 unfurl 声明，`valid_unfurl_renderer?/1` fail-closed（**证据**：`ui_surface_provider_test.exs` 合法/非法 + `validate_page(:unfurl)` 用例，green）
- [x] `mix world.renderers.manifest` 生成 `pluginUnfurlRenderers`（**证据**：`world_renderers_manifest_test.exs` 断言 + `--check` in sync）
- [x] world `matchUnfurl` + Conversation.tsx 集成（**证据**：`pnpm typecheck` 0 err、`pnpm test` vitest green；空注册表 → 行为同 main）
- [x] 本 PR 零 kanban（**证据**：`git status` 无 kanban 文件；生成的 `pluginUnfurlRenderers=[]`）
- [x] All gates green: **`PluginWorkspaceLocalityContractTest`（行锚 baseline）green**、format
- [x] CI（frontend / gate / gitleaks）green on PR head + 分支 rebased on `main`（机器返回闸）

## 6. Discuss-first vs Deferred

- **Clarify-first?** 无——设计直接镜像 #1476 已确认模式，非新 trigger。
- **Deferred（lead-adjudicated）**：kanban 侧 unfurl 声明 + Bubble 组件搬迁 → 下游 **#1474**（rebase 到本 PR 后做）。
- **Never deferred here**：行锚 baseline 的维护（改 manifest.ex 必然移位其 baselined 行 → 必须同 PR 更新 baseline）。

## 7. Conflict-avoidance

owns：`ui_surface_provider.ex` / `world.renderers.manifest.ex` / `generated/plugin-page-renderers.tsx` / `components/unfurl.tsx`（新）/ `Conversation.tsx`（消息渲染点一处）。touches world → 已核 world-coordination；与 #1474（kanban assets）无文件重叠。**core `legacy_dynamic_receiver_baseline.ex` 的 manifest.ex 条目**本 PR 更新（外科，其它文件条目不动）。

## 8. Merge model

PR #1569 → `main`（lead 合）；保持 rebased on `main`。

## 9. Gates, 文件/LOC, open questions

- 新文件：`components/unfurl.tsx`（~60）。改：ui_surface_provider（+valid_unfurl_renderer? + validate_unfurl，~30）/ manifest task（+unfurl 生成，~25）/ Conversation.tsx（+12）/ 生成文件（+空导出）/ baseline（manifest.ex 条目 12→15）/ 2 测试。
- **踩坑（team 参考）**：改任何 baselined 插件文件（加行 / 改函数 arity）都撞 core 行锚 baseline；建功能时**本地必须连 `apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs` 一起跑**，不能只跑 app 级测试（首次 CI 挂就是漏跑它）。
- open questions：无。
