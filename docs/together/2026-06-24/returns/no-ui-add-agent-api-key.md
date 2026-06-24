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

## DoD artifact —— 🟡 UI 渲染活体验证通过；端到端持久化留人肉复核（merge gate）

**已活体验证（agent-browser，运行中 world UI）**：
- 后端活体编译通过（cp 进运行中主仓后 `/login` 200）。
- **加-key 表单正常渲染**：admin 进 agent 的 api-keys 页 → 我新增的「Provider + API key 输入 +
  Save key 按钮」正确出现（截图 `evidence/f10-add-api-key/01-add-key-form-rendered.png`）。这正是
  F10 交付物（此前完全无此 UI）。
- **`can_edit`/unsupported 门控正确**：echo agent（不支持 key）正确显示「does not support API
  keys」、无表单；cc agent（claude-bot）因 `:activate_timeout`（F5，cc 在本环境起不来）显示 error
  分支——均符合代码预期。

**未演示**：加 key → 持久化 → masked 行出现 的端到端一跳。原因经层层定位**确证与本改动无关**：
运行中 server 的 world LiveView **对任何 dispatch 都不响应**（cmdk 按钮 / nav 链接 / create agent /
本 put 点击后服务端 `delta=0`，但 socket `isConnected:true`、纯客户端 React 正常）。**决定性判定**：
把 world_live.ex 还原成 origin/main 原版后 cmdk 仍不响应 → 非本改动引起，是 server 在「崩溃→重启」
后退化（疑 cc agent `:activate_timeout` 拖累 world LiveView mount）。今天人肉验证时这些 dispatch 是
好的（F14 加规则 / L2 建 agent 都成功过）。

**merge gate**：在健康 server / 你本人浏览器上补「填 provider+key → Save → masked 行出现」端到端
截图（curl flavor 最贴切——curl 既支持 key 又能干净激活）。代码路径低风险（后端镜像已验证的
`dispatch_agent_create`、前端镜像已验证的 `onCreateAgent`）。

## Merge request

- 分支 `fix/no-ui-add-agent-api-key`（push 后 tracking）。
- 改动文件：world_live.ex + main.tsx + Identities.tsx，与他人 owned surface 无冲突。
- 顺序无依赖，可独立 merge。
- **merge gate**：UI 渲染已活体验证（见 DoD 截图）；端到端持久化一跳在健康 server / 人肉浏览器
  复核后再并入 `main`。

## 同 owner 其余 finding 状态

F3 ✅ 已 PR #949（活体验证+修了 submit 吞噬 bug）· F13 ⏸ 暂停（非纯前端：chat feed 无
inbound send 路径 + anon 刻意只读，待 Allen/@林懿伦 决策）· F9（绑群 UI，待）· F14（UI Disable）。
