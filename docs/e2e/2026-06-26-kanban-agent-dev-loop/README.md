# E2E — kanban 全 AI 化产品开发闭环（2026-06-26）

> 基座：`feat/kanban-agent-e2e`（off upstream/main，含 #1004/#1007 kanban-as-role + RF-1..9）。
> 验证「聊天/dispatch → kanban-manager agent 建 9 阶段产品板 → 派 worker agent 认领 → 挂 PR + CI 硬门 → 接力推进 → markmap/UI 投影」全链路。

## 轮次索引

| 轮次 | 证明什么 | 介质 | 结果 |
|---|---|---|---|
| **round-1-dispatch-loop** | dispatch 驱动全闭环：建板 + 9 阶段接力链 + worker 认领 + status 流转 + register_pr + markmap + 板持久化 | erpc → 活节点的授权 API（Workspace.create_agent / Router.dispatch） | **27/27 全绿** |
| **round-2-live-ui** | 真 world UI 渲染：看板列表(list_by_role)、9 阶段链画布、本图配置、节点属性 + CI gate 徽章 | sanctioned 路径=浏览器（headless chrome + CDP，admin 登录） | **board UI 完整渲染**（截图） |
| **round-3-b1-b2-relay** | B1（动作进路由）+ B2（github 硬 CI 门）+ §7（agent/routing 编排 seed） | ExUnit 单测/集成（gate 合规） + seed 脚本 | 单测全绿；seed 可跑 |

## 关键产物

- **round-1**：`scenario-v2.exs`（全闭环场景）、`eval.sh`（erpc 驱动）、`result.md`（27/27 输出）。
- **round-2**：`01-board-9stage-chain.png`（**核心证据**——看板 UI 全貌）、`cdp-shot.js`/`cdp-diag.js`（截图/诊断工具）、`start-server.sh`、`README.md`（复现步骤 + 前端 build 坑）。
- **round-3**：`kanban_dev_loop_seed.exs`（§7 编排 seed）、`notes.md`（B1/B2 代码改动 + 测试 + 已知超时）。

## 单元/集成测试（gate 合规，在仓库内）

- `apps/ezagent_plugin_kanban/test/ci_test.exs` — B2 `gate_state`（verdict→github status state）。
- `apps/ezagent_plugin_kanban/test/behavior/shared_test.exs` — B1 `session_dispatch` 纯函数。
- `apps/ezagent_plugin_kanban/test/behavior/relay_test.exs` — B1 post_handle 注入全链 + BoardConfig 合并写。
- `apps/ezagent_plugin_kanban/test/kanban_role_test.exs` — recipe 25 动作。
- 全绿：`mix test apps/ezagent_plugin_kanban`（35 tests, 0 failures）+ arch baseline 0 failures。

## 安全

- 截图脚本的 github token / 登录 cookie **均经 env 传入、不内嵌**（已 grep 确认无真密钥）。
- 凭证在 `system://credentials/github.yaml`（0600、admin-gated、不提交）。
