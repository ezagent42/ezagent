# Return: F10 — 无 UI 给 agent 加 API key

> **Task:** F10 — `fix/no-ui-add-agent-api-key`（world UI 配 agent API key 入口）
> **Branch:** `fix/no-ui-add-agent-api-key`
> **PR:** (push 后补)
> **Dev:** @李震宇 (zyli) + Claude（实现/验证）
> **returned_at:** 2026-06-24 18:?? +0800
> **deadline:** —（非 2026-06-24 `plan.md` 计划项；派生自当日 full-flow 验证 return 的 F10 finding）
> **deadline_status:** out_of_scope（同日 follow-up 修复，非原始日计划任务）

## Scope note

派生自验证 return 路由给 world UI 开发者本人的 5 个 finding 之一。base = 最新
`origin/main`(`c4bcebe3`)。

**阻塞状态更新**：finding 标 F10 为「半阻塞（需 @黄佳佳 暴露 put_api_key）」——但
**#938 之后后端其实已就绪**：`apps/ezagent_domain_identity/lib/ezagent/behavior/api_keys.ex`
有完整 `Behavior.ApiKeys`，含 `action(:put_api_key, args: %{provider, key}, caps:
[{:put_api_key, kind: :any}])` + `handle_put_api_key`。world 侧只差**写**路径。

## What's done

此前 agent API-keys 页只有只读 masked 表，无任何新增/替换入口 → curl/任何需 key 的
flavor 无法经产品配置下游 LLM key。

**后端**（`apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`，+60）：
- 新 `agent.api_key.put` dispatch handler → `dispatch_api_key_put/3`：把 caller scope
  穿进 `:put_api_key` invocation（target `with_action(agent_uri, :identity, :put_api_key)`）。
- `refresh_api_keys_state/2`：put 成功后经 `Routes.route_for`（路由 SoT）重解析同一页
  state 并 push `world:state` → masked 表刷新。**key 明文不回传**（list_api_keys 只返 masked）。
- 授权沿用后端 gate：data_owner（agent 创建者）或 admin，与页面已算的 `can_edit` 一致。

**前端**（`Identities.tsx` +74 / `main.tsx` +16）：
- `AddApiKeyForm`（provider + masked key 输入），**仅 `can_edit` 时渲染**。
- 经 `onPutApiKey` 走 LV socket dispatch（`preventDefault` + dispatch，**非原生 POST**——
  LiveView 会吞掉 React 岛内 form 的原生 submit，见 [[world-react-island-form-submit-swallowed]]）。
- key 输入 `type=password` + 提交后清空。

Commit: `dce6369b feat(world): add UI to store an agent's API key (F10)`

## Gate status

| Gate | 结果 |
|---|---|
| `vite build` | ✅ green |
| `check:mounts` | ✅ green |
| `mix format --check-formatted`（world_live.ex）| ✅ green |
| elixir 活体编译 | ✅ — cp 进运行中主仓后 `/login` 200（world_live.ex 编译通过） |
| `lv_parity` | ✅ 不破坏 — 反而补上 LV `put` api-key 的 parity 缺口（已 claimed covered，本 PR 使其为真） |
| 裸 `tsc` | ⚠️ 预存在环境失败（无 @types/react；非本改动） |

## DoD artifact —— ⚠️ 活体加-key 截图待补（merge gate）

后端已活体编译通过（login 200），但**加 key 的端到端 agent-browser 实测未完成**：实测途中
运行中的验证 server（:10042）宕机（beam.smp 退出；我 cp 的 world_live.ex 此前已 200 编译通过、
且 api-keys 页加载走既有 `list_api_keys` 非我新代码 → 大概率与本改动无因果，但未续测以免再扰动
operator 环境）。

**建议 merge 前补**：admin 进某 agent 的 api-keys 页 → 填 provider+key → Save → masked 行
出现 的截图（同 F3 的活体验证法：cp 进运行中主仓 + vite HMR/code_reloader + agent-browser）。

## Merge request

- 分支 `fix/no-ui-add-agent-api-key`（push 后 tracking）。
- 改动文件：world_live.ex + main.tsx + Identities.tsx，与他人 owned surface 无冲突。
- 顺序无依赖，可独立 merge。
- **merge gate**：补活体加-key 截图后再并入 `main`。

## 同 owner 其余 finding 状态

F3 ✅ 已 PR #949（活体验证+修了 submit 吞噬 bug）· F13 ⏸ 暂停（非纯前端：chat feed 无
inbound send 路径 + anon 刻意只读，待 Allen/@林懿伦 决策）· F9（绑群 UI，待）· F14（UI Disable）。
