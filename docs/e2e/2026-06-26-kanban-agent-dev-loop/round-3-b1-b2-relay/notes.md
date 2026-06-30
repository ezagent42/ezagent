# Round 3 — B1（动作进路由）+ B2（github 硬 CI 门）+ §7（agent/routing 编排）

> 实现细节 + 决策见 `docs/status/kanban-agent-e2e/b1-b2-impl.md`。这里记 e2e 角度的验证。

## B2 — github 硬 CI status check（done）

`push_pr` = 软留言（`requirement_digest`）+ **硬 commit status**（`check_pr_gate` verdict → `create_commit_status` 推到固定 context `ezagent/ci-gate`）。
- 改动：`ci.ex`(+`gate_state/1`)、`github.ex`(+`create_commit_status/5`、`get_pull` 扩 `head_sha`)、`connectors.ex push_pr`、`kanban.ex` push_pr returns。
- 架构：**规则焊死（branch protection 一次性设 required check）+ 数据每 PR 变（agent 推 verdict）+ 标准活在看板**（改标准=改看板=零 GitHub 权限）。贴「一 admin / 大家 PR / admin 合」场景。
- 测试：`ci_test.exs` gate_state（满分→success / 扣分→failure / 无判据→pending）。

## B1 — 看板动作吐 {:dispatch} 进路由（done）

接力动作（claim/set_status/register_pr）成功后经 **`post_handle/4` 注入** `{:dispatch}` 到板绑定会话的 `session.send`，重入路由触发下一个 agent。
- 改动：`shared.ex`(+`session_dispatch/3`，照搬 cc_headless 范式)、`board_config.ex`(+`session_uri`、write 改合并)、`kanban.ex`(+`bind_session` 第 25 动作 + `post_handle`)、`connectors.ex`(+`bind_session`)。
- 消息带机器可读标记 `[kanban:<event>] by <caller>`（路由按标记匹配）；节点细节由被触发 agent 经 get_tree 读真相源（消息只做触发器）。
- 测试：`shared_test.exs`（纯函数）、`relay_test.exs`（post_handle 注入全链 + 合并写不互相覆盖）。

## §7 — agent/routing 编排 seed（`kanban_dev_loop_seed.exs`）

拓扑：board（kanban-manager，绑会话）+ ci-gate（接力 agent）+ routing 规则 `text_contains("[kanban:pr_registered]") → ci-gate`（字面 URI、无环 DAG）。
- **闭环**：board register_pr → B1 注入 `session.send([kanban:pr_registered])` → 路由命中 → ci-gate 收到 → dispatch push_pr 到 board → B2 推 github status。
- **真 claude brain 升级**：ci-gate 的 flavor `native` → `cc-headless`（main 已有 `ezagent_domain_agent/.../cc_headless_agent.ex`），收到 inbound 即用真 claude 决策。

## 已知问题（非本实现引入）

- **5s dispatch transient 超时**：`Workspace.create_agent` 偶发 5s GenServer.call 超时（kernel slice-lookup leg，Allen perf-bug）。scenario-v2 多次复跑 27/27、role 测试全过，证明逻辑正确；retry 即过。
- **lifecycle gate NP-2**：`mix ezagent.check_invariants.lifecycle` 报 5 个 NP-2，全在 `ezagent_core`（agent_manifest/workspace_placement/workspace_owner_gate）——**main 既存、team 自己的代码、非本实现引入、gate 基线不拦**。
