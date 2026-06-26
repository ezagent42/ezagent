# B1 + B2 实施留档（dev-together×看板融合，feat/kanban-agent-e2e）

> 基座：upstream/main（含 #1004/#1007 kanban-as-role + RF-1..9）。全程 gate 合规、TDD。
> 全闭环 dispatch e2e 已先于本实施跑通 27/27（scenario-v2.exs）。

## B2 — github 硬 CI status check（done，单测绿）

**做了什么**：`push_pr` 从"只发软留言"升级成"软留言 + 硬 CI 门"。
- `ci.ex` +`gate_state/1`（纯函数）：verdict→`success`/`failure`/`pending`（满分=success 放行、扣分=failure 挡、无判据=pending）。
- `github.ex` +`create_commit_status/5`（`POST /repos/{repo}/statuses/{sha}`，复用 `post/2`+`headers/1`）；`get_pull` 扩出 `head_sha`。
- `connectors.ex push_pr`：发完 `requirement_digest` 软留言后，算 `check_pr_gate` verdict + 取 head sha + 推 commit status（best-effort，失败回 `gate_state:"skipped"`，非静默丢）。
- `kanban.ex` push_pr `returns` 扩 `%{url, gate_state}`。

**架构（回应用户"改CI规则触发权限"）**：rule 焊死、data 每PR变。
- **rule（一次性 admin）**：branch protection 把 `ezagent/ci-gate` 设 required check。
- **data（零权限/每PR）**：ezagent CI-gate agent 用 bot token 推 verdict 到该固定 context。
- **标准活在看板**：`check_pr_gate` 沿祖先链读看板需求当判据 → 改标准=改看板=零 GitHub 权限。
- 场景（一admin/大家PR/admin合）：admin 一次配 token+required check，贡献者零配置，gate 红挡合并，admin 手动合，`sync_prs` 合并后自动置 done。

## B1 — 看板动作吐 {:dispatch} 进路由（代码done，单测绿；live relay 待 e2e）

**做了什么**：接力动作成功后向"板绑定会话"发一条公告消息，重入路由→触发下一个 agent。
- `shared.ex` +`session_dispatch/3`（纯函数，照搬 `cc_headless_agent.ex:130`）：`session_uri→[{:dispatch, session.send Cmd}]`，自铸 session-send cap、`reply: :ignore`；未绑定→`[]`。
- `board_config.ex`：read/write 加 `session_uri`，**write 改合并语义**（bind_session 与 set_board_config 互不覆盖）。
- `kanban.ex` +`action(:bind_session)`（第 25 个动作）+ `post_handle/4`：对 `claim_node`/`set_status`/`register_pr` 成功时注入 session_dispatch（post_handle 引擎只在 `{:ok,...}` 调，故无需判成败）。
- 消息只做**触发器**（带 `[kanban:<event>] by <caller>` 标记），节点细节由被触发 agent 经 `get_tree` 读真相源。

## 决策留档（per 用户"决策留档即可"）

- **D-B1-1**：会话绑定用**板级**（BoardConfig.session_uri + bind_session 动作），非 spec §7.2 的"记节点上"。理由：MVP 先证"动作→会话→路由"链；节点级精确绑定列后续。
- **D-B1-2**：注入点用 Lifecycle **`post_handle/4`**（lifecycle.md 明列其用途=effect injection），不污染每个纯 handler。引擎只在 handler 成功时调 post_handle（runtime.ex:867/873）。
- **D-B1-3**：bind_session 作为第 25 个 kanban 动作（24→25）。同步更新 `required_caps/0` + `kanban_role_test`（24→25 断言）。recipe 经 `actions/0` 自动纳入。
- **D-B2-1**：CI 硬门走 status API（方案A），非标记留言（方案B）——后者是"不能给 agent status token"的兜底。

## gate 合规自查

- kanban 全单测 **35 tests, 0 failures**（含 role 25 动作、ci gate_state、shared session_dispatch）。
- arch baseline **0 failures**（`set_effect_sites: 128` 不变——B1/B2 零新增 `{:set}`，session_dispatch 吐 `{:dispatch}`、bind_session 写文件）。
- `mix format --check-formatted` 改动文件全过。
- 改动范围：纯 kanban 插件（ci/github/connectors/shared/board_config/kanban.ex + 测试）。

## ⚠ 给 Allen（既存 gate，非本实施引入）

`mix ezagent.check_invariants.lifecycle` 报 **NP-2 layer-vocab 违规**，全在 `ezagent_core`：
`agent_manifest.ex` / `agent_manifest/tools.ex` / `workspace_owner_gate.ex` / `workspace_placement.ex` / `workspace_placement/local_resolver.ex`（core 模块名含 upper-layer 词 Agent/Workspace）。
**upstream/main 既存**（我没碰 core）。要么加进 `@layer_vocab_allowlist`、要么改名——碰 core 高爆炸半径，留给 Allen。

## 待办

- §7：预物化 3 agent（改看板/CI-gate/dev-together，cc-headless 真 brain）+ seed routing 规则（receiver 字面 URI、无环 DAG）。
- live e2e（sanctioned 路径=world UI 浏览器，非 erpc）：重编译重启 server → 建板→bind_session→claim→看 session 收到公告→路由触发下个 agent；B2 推真 github status（需配 bot token）。每步截图。
