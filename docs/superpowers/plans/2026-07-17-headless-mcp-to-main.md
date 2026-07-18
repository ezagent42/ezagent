# 任务 A：#1323 headless-MCP 落 main — 实施计划

> **Handoff:** `docs/together/2026-07-16/handoffs/gaga-agent-runtime.md` §3（jjkysy → gaga）
> **Branch:** `fix/1323-headless-mcp-to-main`（off origin/main @ 66734aae5）
> **源:** Allen `fix/cc-headless-mcp-load` @ 588a694d5（PR #1323，OPEN，base 83729cddd）
> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans；同时 load
> `ezagent-developer` + `elixir-phoenix-helper`。

## 0. 勘察结论（rebase 落差 + 一个 handoff 未覆盖的事实）

### 落差(#1323 base → 当前 main)

| #1323 触碰面 | main 现状 | rebase 动作 |
|---|---|---|
| `cc_headless_agent.ex` `sdk_sidecar_params/2` 私有→公开 + `cmd_env: tmpl["cmd_env"]` | 已公开(#1324)，`cmd_env: provider_cmd_env(tmpl)` 已存在 | 只需在 provider env 基础上**并入 CLI 身份 env**（见下） |
| `worker.py` route B（读 `<config_dir>/.mcp.json` + auto-allow `mcp__<server>`） | 仍是断的半边（`EZAGENT_CC_SDK_MCP_SERVERS` 无人填）；新增了 `plugins`(#1434) 处理需保留 | 移植 Allen 的 `resolve_mcp_config` + guarded import，与 plugins 块共存 |
| python unittest（纯 helper，无 SDK 可跑） | 不存在 | 原样移植 |
| `cc_headless_agent_test.exs` threading 断言 | 文件已 +155 行演进 | 适配现文件结构后移植 |

### 事实一（DoD 措辞 vs 代码现实，不影响结果）

handoff DoD 写"助手**经 esr-bridge** dispatch `kanban.add_node`"，但 kanban-assistant
recipe（`apps/ezagent_web/priv/socialware_seed/kanban/recipes.yaml`，#1425）明确：
**看板操作走 `scripts/kanban-cli.sh`（Bash + `EZAGENT_USER_TOKEN` CLI 身份 dispatch），
"do NOT look for an MCP server or MCP kanban tools; there are none"**。esr-bridge 只有一个
`reply` tool（`ezagent_mcp_bridge.py:301`），不是看板工具面。
→ e2e 里 `kanban.add_node` 实际经 **CLI 身份**发出；因此本任务必须把 PTY 已有的
`SpawnPlan.maybe_put_cli_identity_env/3`（generic role 门控，spawn_plan.ex:324）接进
headless 的 `cmd_env`，否则助手 Bash 里 `EZAGENT_USER_TOKEN unset`，DoD e2e 不可能过。
这正是 #1323 commit message 里 "cmd_env seam" 的当代形态。

### 事实二（结构性，本任务不擅动，记录为 open decision）

`Ezagent.AgentBridge.Channel.verify_transport_class/1`（channel.ex:109-119，codex MED-2）
**拒绝 `:in_process_sync` flavor 的 WS join**；`CcHeadlessBridgeAdapter.transport_class ==
:in_process_sync`。即使给 headless 写了含 esr-bridge 的 `.mcp.json`，桥进程的
`agent_bridge:cc-headless:<uri>` join 会被 `transport_class_mismatch` 拒掉（桥无限退避重试，
log 噪音 + 白耗子进程）。headless 的 reply 本来走同步返回（`:sync_result`），不需要 esr-bridge。
→ **本任务不给 headless 物化 esr-bridge server**；#1323 的机制（config_dir 有 `.mcp.json`
就装载）原样落地并用测试锁死。"headless 是否要 WS join 以获得 reply 工具对等"是
transport-class 语义问题，列入 return 的 open decision（Allen 裁决），不在实施期自作主张
（CLAUDE.md grill 条款 + memory feedback-phased-delivery-defer-document）。

## 1. 切片（TDD，全部进本 task branch）

### Slice 1 — worker.py route B（移植 #1323 读侧）
- [ ] 移植 guarded `claude_agent_sdk` import（现文件还有 `SdkPluginConfig`，同样 guard）
- [ ] 移植 `_server_names_from_mcp_file/1` + `resolve_mcp_config/3`（docstring 原样保留）
- [ ] `Worker.start`：`resolve_mcp_config(config_dir, env_json("EZAGENT_CC_SDK_MCP_SERVERS"),
      env_json("EZAGENT_CC_SDK_ALLOWED_TOOLS"))` → `options.mcp_servers` / `allowed_tools`；
      删除旧的 env-only 两段；**保留 #1434 plugins 段**
- [ ] 移植 `test_ezagent_cc_sdk_worker.py`（6 个 case）并跑绿：
      `uv run --no-project python -m unittest apps/ezagent_plugin_cc/priv/python/test_ezagent_cc_sdk_worker.py`

### Slice 2 — headless CLI 身份 env（elixir 胶水）
- [ ] `cc_headless_agent.ex` `sdk_sidecar_params/2`：
      `cmd_env: provider_cmd_env(tmpl) |> SpawnPlan.maybe_put_cli_identity_env(agent_uri, tmpl)`
      （**复用**，不 fork；role-less agent 行为不变=纯 provider env）
- [ ] test：role 模板 → `params.cmd_env` 含 `EZAGENT_USER_TOKEN`；无 role → 不含（mint 走
      真 TokenStore？若 test env 不可 mint，则断言 mint 失败路径 fail-closed 不炸 spawn）

### Slice 3 — 回归锁 + 桥路径断言（DoD 第 2、3 条）
- [ ] python 侧已锁 "config_dir 有 `.mcp.json` → options 出现该 server + `mcp__<name>` allow"
      （Slice 1 tests）；elixir 侧补 sidecar env 断言：`SdkSidecar` 导出
      `EZAGENT_CC_SDK_CONFIG_DIR`（已有实现，补/确认测试覆盖）
- [ ] `McpConfigWriter` 桥路径断言测试：写出的 JSON 中 esr-bridge `args` 的 script path
      `== Application.app_dir(:ezagent_plugin_cc, "priv/python/ezagent_mcp_bridge.py")`，
      且 `refute encoded =~ "/.worktrees/"`、`refute encoded =~ "/worktrees/"`

### Slice 4 — 真 UI e2e（DoD 第 1 条）
- [ ] disposable 栈（`CONTRIBUTING.md` → `docs/guide/`；`EZAGENT_SIGNING_SEED_V1` 必设，DB 迁移）
- [ ] 普通用户会话装 kanban socialware → @kanban-assistant "给板加个节点" →
      助手（cc-headless）经 CLI 身份 dispatch `kanban.add_node` → 板上见节点
- [ ] agent-browser 每步截图 → `docs/e2e/2026-07-17-headless-mcp-kanban/`；真渠道 transcript

### Slice 5 — gates + return
- [ ] `mix format`(touched only) / `mix ezagent.arch.scan` / `doc.scan` / `uri_query.scan` /
      `check_invariants` / 受影响 app `mix test` / `:ezagent_plugin_check`
- [ ] CI 绿 on PR head + rebase main
- [ ] `docs/together/2026-07-17/returns/gaga-headless-mcp-to-main.md`：per-line DoD 对账 +
      两条 deviation（§0 事实一/二）+ open decision（headless×esr-bridge transport-class）

## 2. 红线遵守

- 不动 kanban plugin / BoardProvision / kanban 前端（jjkysy 在飞）；`kanban-cli.sh` 里的
  硬编码 `/home/yaosh/...` cookie 路径是他 lane 的债，**只记录不修**（写进 return 提醒）
- 不动 world 前端（zyli 在飞）
- 不动 `Channel.verify_transport_class`（架构决策，等 Allen）
- Co-author 保留 Allen 原 commit 的成果归属（cherry-pick 说明写进 commit body）
