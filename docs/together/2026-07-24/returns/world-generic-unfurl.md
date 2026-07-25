# Return: unfurl → world 通用能力

> **returned_at:** 2026-07-24 · **deadline:** 2026-07-24（当日）· **deadline_status:** on_time
> **Handoff:** `docs/together/2026-07-24/handoffs/world-generic-unfurl.md`
> **PR:** #1569 · **branch:** `feat/world-generic-unfurl` · **head:** `a3060e040`（rebased on `main` @ b9b548c8）
> **Merge request:** 可合入 `main`——CI 全绿、MERGEABLE、DoD 全绿。

## DoD 逐条核对

| DoD 项 | 状态 | 证据 |
|---|---|---|
| pages() 接受 unfurl + `valid_unfurl_renderer?/1` fail-closed | ✅ 达成 | `ui_surface_provider_test.exs` 合法/非法 + `validate_page(:unfurl)` 用例 green |
| manifest 生成 `pluginUnfurlRenderers` | ✅ 达成 | `world_renderers_manifest_test.exs` 断言 + `mix world.renderers.manifest --check` in sync |
| world `matchUnfurl` + Conversation.tsx 集成 | ✅ 达成 | `pnpm typecheck` 0 err · `pnpm test` vitest 33 pass · 空注册表 → 行为同 main |
| 本 PR 零 kanban | ✅ 达成 | 改动 8 文件全 world/core，无 kanban 文件；生成 `pluginUnfurlRenderers=[]` |
| `PluginWorkspaceLocalityContractTest` 行锚 baseline green | ✅ 达成 | `cd apps/ezagent_core && mix test test/invariants/plugin_workspace_locality_contract_test.exs` → **6 tests, 0 failures**（两个子测试都过） |
| CI（frontend/gate/gitleaks）green + rebased on main | ✅ 达成 | run 30095457551 重跑后 conclusion=success；head rebased 到 b9b548c8（0 落后） |

**deferred（lead-adjudicated）**：kanban 侧 unfurl 声明 + Bubble 组件搬迁 → 下游 #1474。无其它偏离。

## 做了什么（改动清单）

- `ui_surface_provider.ex`：`validate_page` 加 `validate_unfurl` + 公开 `valid_unfurl_renderer?/1`（提取共享 `valid_renderer_source?/1`）。
- `world.renderers.manifest.ex`：`generated_source/1` 追加 `pluginUnfurlRenderers` 导出；`import_path/1`→`/2` 泛化供 unfurl 复用。
- `assets/src/components/unfurl.tsx`（新）：通用 unfurl 类型 + `matchUnfurl`。
- `assets/src/generated/plugin-page-renderers.tsx`：新增空 `pluginUnfurlRenderers` + `UnfurlRendererEntry` type import（`mix world.renderers.manifest` 重新生成）。
- `Conversation.tsx`：消息渲染点集成 `matchUnfurl`（+12/-1）。
- `legacy_dynamic_receiver_baseline.ex`（core）：外科更新 `world.renderers.manifest.ex` 条目 12→15（其它文件条目不动）。
- 2 测试。

## Method-friction（给 lead 在 review 里 promote）

1. **行锚 baseline 的隐形依赖**：改任何 baselined 插件文件（加行 / 改函数 arity）都会撞 core 的 `PluginWorkspaceLocalityContractTest`——首次 CI 挂就是 manifest.ex 改动移位 baselined 行 + 一行 @type typespec 引入的漂移。**method-delta 建议**：handoff/return 的 DoD「All gates green」要显式点名 `plugin_workspace_locality_contract_test`（它在 `ezagent_core`，跑 app 级测试跳过它）；建功能改插件文件时本地必跑它。
2. **@type typespec 也算「行」**：给 `@type page` 加一行文档式 typespec 就会移位后面所有 baselined 访问 → 优先靠 validate_page 校验 + 透传，非必要不加 typespec（避免无谓 baseline churn）。
3. **子 agent 验证盲区**：委派 build 的 agent 只跑了 app 级测试（build/typecheck/vitest）没跑 core gate → 漏掉。委派规格里要显式列 core gate 测试命令。

## 关联（同批交付）

- **#1470（挂载宿主退场清理）已关闭**（作废）：`unmount_all_for_target` 被 main 的 cap-epoch `Cap.revoke_all_to`（cap.ex:245）+ `verify_against_current`（authorize.ex:66，post-C4 存活）取代；删板撤钥匙改在 #1474 内 swap 成 `Cap.revoke_all_to`。
- **#1474**（kanban 主线）rebase 到本 PR 后接入 kanban 侧 unfurl 声明 + Bubble 搬迁。
