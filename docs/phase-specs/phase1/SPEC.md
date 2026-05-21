# Phase 1 — SPEC

> Phase 1: ezagent_core MVP + LiveView `/admin` + CC stdio bridge 原型。
> 本文件是 Phase 1 brainstorm 的产出。配套: `VERIFICATION.md` / `PLAN.md` / `DECISIONS.md`
> 上游: `IMPLEMENTATION_ROADMAP.md` §4(Phase 1 entry)、Phase 1 design HTML(brainstorm step 5)。

## 目标

让 dispatch 链路第一次端到端通起来,Allen 能从 LiveView `/admin` 看到 audit log 实时流并通过 manual dispatch / Echo 测试按钮触发 invocation;1b 时进一步能通过 LiveView 向远程开发机里的 Claude Code 发指令并看到 reply。

## 测试员体验 / demo

1a 完成时(`phase1a` tag):浏览器从 tailnet `http://100.64.0.27:4000/admin` 打开 → 看到 audit log 表(空)+ "Echo 测试" 按钮 + manual dispatch form;点 Echo 按钮 → audit log 实时流出 2 行(invocation + Echo reply),authz 列显示 `:stub_grant`。

1b 完成时(`phase1b` = phase1 整体):LiveView `/admin` 多一个 "CC bridge" 区,显示已连入的 CC 实例;manual dispatch 表单选 target = remote CC URI → CC 收到 → reply 回到 LiveView audit log。

## Sub-step 结构

**2 个 sub-step,顺序 1a → 1b**(Q3 决策:1a 合并 ezagent_core MVP + LiveView /admin)。

| sub-step | 主题 | LOC | tag |
|---|---|---|---|
| **1a** | ezagent_core MVP + `ezagent_web_liveview` /admin | ~600 core + ~150 plugin(详见 §1a Deliverables 模块表) | `phase1a` |
| **1b** | CC stdio bridge 原型(`_v1_prototype`)+ LiveView wire-up | ~80 Python + 少量 Elixir | `phase1b` = phase1 整体完成 |

## 1a Deliverables

**核心 5 决策**(详见 DECISIONS.md):
- Wire: stdio + JSON-RPC(Q1)
- 不用宏,单 server + behaviour callbacks(Q2)
- 6 internal PLAN steps + checkpoint commits(Q3)
- LiveView audit 流 = `Phoenix.LiveView.stream` + last-50(Q4)
- admin 常量挂在 `Ezagent.Entity.User` stub 模块,无 Bootstrap 命名空间(Q5)

**模块层(core,在 `apps/ezagent_core/lib/esr/`)**:

| 模块 | step | ~LOC | 说明 |
|---|---|---|---|
| `uri.ex` | 2 | ~25 | URI parser + scheme registry |
| `invocation.ex` | 2 | ~95 | %Invocation{} struct + dispatch/1 + reply/2(7-case reply 表) |
| `interface_validator.ex` | 2 | ~35 | @interface schema 递归校验 |
| `idempotency.ex` | 1 | ~20 | bounded ETS LRU dedup |
| `capability.ex` | 1 | ~30 | struct + matches?/2 + revoke/2(admin-protected) |
| `behavior.ex` | 2 | ~15 | @behaviour Ezagent.Behavior callback 契约 |
| `kind.ex` | 2 | ~15 | @behaviour Ezagent.Kind callback 契约(**不是宏**) |
| `kind/server.ex` | 2 | ~70 | 共享 GenServer(init / handle_continue / handle_call / handle_cast / handle_info) |
| `kind/runtime.ex` | 2 | ~50 | handle_dispatch helper(Appendix A step 5-10) |
| `kind/snapshot.ex` | 3 | ~20 | Phase 1 骨架(load_or_init + maybe_save;Echo 是 ephemeral 实际不调) |
| `kind_registry.ex` | 1 | ~30 | thin wrapper over stdlib Registry,put_new + lookup |
| `behavior_registry.ex` | 1 | ~50 | 裸 ETS,`{kind, action} → behavior_module` |
| `ready_gate.ex` | 1 | ~20 | ETS 三态(:unknown/:not_ready/:ready) |
| `pending_delivery.ex` | 1 | ~25 | per-URI bounded buffer(默认 100),flush/1 |
| `audit.ex` | 3 | ~30 | telemetry handler + fan-out(PubSub + cast Writer) |
| `audit/writer.ex` | 3 | ~30 | 异步 batch flush GenServer,SQLite `invocations` 表 |
| `dlq.ex` | 3 | ~25 | bounded FIFO,失败/超时/异常落库(SQLite `dlq` 表) |
| `telemetry.ex` | 3 | ~15 | event 命名 helpers |

**core 小计 ~600 LOC**(Phase 1 不包括 §14 全部模块 —— matcher / routing_registry / message / message_store / view / scheduler / plugin.ex 等是 Phase 2+ 的事)。

**Plugin 层**:

| 模块 | step | ~LOC | 说明 |
|---|---|---|---|
| `Ezagent.Entity.User`(stub,在 `apps/ezagent_core` 的 plugin 还是单独 plugin 视实施) | 1 | ~15 | @behaviour Ezagent.Kind callbacks + `admin_uri/0` + `admin_caps/0`。Phase 1 **不 spawn 实例**(没 Identity Behavior) |
| `ezagent_plugin_echo`(独立 plugin app `apps/ezagent_plugin_echo/`) | 4 | ~50 | `Ezagent.Entity.Echo` Kind + `Ezagent.Behavior.Echo`(action :say)+ Application 注册 |
| `ezagent_web_liveview` plugin app `apps/ezagent_web_liveview/` | 5 | ~150 | `/admin` route + `AdminLive` LiveView(stream + form + button)+ ctx.caller 默认填 admin |

**Application 接线**:
`Ezagent.Application.start/2`(在 `ezagent_core` 或 umbrella 根)的 children 列表加入:Registry(KindRegistry)/ DynamicSupervisor(Kind.Supervisor)/ ETS-owning processes for ReadyGate/PendingDelivery/Idempotency tables / BehaviorRegistry ETS table owner / Audit.Writer GenServer。**Phase 1 不需要 bootstrap Task**(admin 是 stub,没 boot-time 写入)。

## 1b Deliverables

> **Architecture reference**: cc-openclaw 的 MCP-stdio 模式(就是这个 chat 正在用的 openclaw-channel 走的链路)。**不要**沿用老 esr `--dangerously-load-development-channels server:esr-channel` + Phoenix Channel WebSocket pattern — 那条路在老 esr 上有问题,cc-openclaw 选了 MCP-stdio 是有原因的。

**Python MCP server / channel**(在 `apps/ezagent_plugin_cc_bridge_v1_prototype/python/esr_mcp_bridge_v1_prototype.py`):
- ~225 LOC Python:**标准 MCP stdio + channel capability**(`capabilities.experimental['claude/channel'] = {}`)
- 暴露 1 tool:`reply` — claude 调用它把消息发回 Ezagent(POST /api/cc-bridge/reply)
- 通过 MCP `notifications/claude/channel` 把来自 Ezagent 的消息推给 claude(claude 看作 `<channel source="esr-bridge" ...>` 用户消息)
- init 时自动 POST /api/cc-bridge/announce 注册 bridge(不需要 claude 显式触发)
- 启动 SSE 订阅 `GET /api/cc-bridge/events?bridge_id=X` 接收 Ezagent 推送
- 启动时通过 env var 拿 `EZAGENT_BRIDGE_URL`(默认 `http://127.0.0.1:4000`)
- claude 通过 mcp.json + `--dangerously-load-development-channels server:esr-bridge` flag 加载

**Elixir 侧**(在 `apps/ezagent_plugin_cc_bridge_v1_prototype/lib/`):
- `Ezagent.Bridge.V1Prototype.McpConfigWriter`(~20 LOC):
  - `write!/0` 写 mcp.json 到 `~/.ezagent/bridge.mcp.json`
  - 内容:`{mcpServers: {esr-bridge: {command: "uv", args: ["run", "python3", "<abs path to esr_mcp_bridge_v1_prototype.py>"]}}}`
- `Ezagent.Bridge.V1Prototype.Server`(rewrite ~30 LOC):
  - 不再 spawn Python 子进程(那是 claude 干的活)
  - 只跟踪 "当前已 connected bridges" Map<bridge_id, %{connected_at, claude_info}>
  - 暴露 `register/2`, `unregister/1`, `list_connected/0` API,被 announce endpoint 调用

**Web 侧**(在 `apps/ezagent_web/lib/ezagent_web/controllers/`):
- `EzagentWeb.CcBridgeAnnounceController` + router 加 `POST /api/cc-bridge/announce`:
  - 收到 `{"bridge_id": "...", "claude_session": "...", "tools": [...]}` body
  - 调用 `Ezagent.Bridge.V1Prototype.Server.register/2`
  - PubSub.broadcast `{:cc_connected, bridge_id, info}` 到 `esr:bridge_v1:events`

**LiveView 侧**:
- AdminLive 增量:订阅 `esr:bridge_v1:events`,渲染 connected bridge 列表(显示 bridge_id + connected_at)
- handle_info `{:cc_connected, _, _}` → 更新 assigns

**启动脚本**(在 `scripts/cc-bridge-attach.sh`):
- ~15 LOC bash
- `mix run -e "Ezagent.Bridge.V1Prototype.McpConfigWriter.write!()"` 写 mcp.json
- `exec script -q /dev/null claude --mcp-config <abs path>` PTY 包装启动 claude(macOS/Linux `script` 命令)

**用户/agent 操作**:
- v1_prototype 阶段:**agent 自己跑 `bash scripts/cc-bridge-attach.sh`(后台启动)**,然后 agent-browser 看 LV /admin 显示 connected
- Phase 5 升级:`Ezagent.Behavior.OSProcess` 接管 PTY 启动,无 bash 脚本

**整 Phase 5 替换路径**:`ezagent_plugin_cc_bridge_v1_prototype/` 整个 app 在 Phase 5 由 `ezagent_plugin_cc/`(完整 channel + WS + CapBAC + 完整 MCP tool surface)wholesale replace;v1 不修改,直接删。

**为什么不是 Phoenix Channel WebSocket**(老 esr 路径):
- cc-openclaw 实证可用,ezagent 优先沿用工作中的 reference
- MCP-stdio 更简单(150 LOC 对比 ~400+ LOC for WS Channel)
- v1_prototype 不追求架构对齐 Phase 5 — 反正全替换。Phase 5 决定是 MCP-stdio 还是 WS Channel 时再 brainstorm

## 前序依赖

Phase 0(`phase0` tag)的:
- Phoenix umbrella + ezagent_core + ezagent_web app
- ecto_sqlite3 repo + migration 框架
- `/_health` Plug + tailnet endpoint binding
- `.claude/skills/` 5 个 skill + self-motivated(rebase 引入)
- `mix ezagent.check_invariants` skeleton + `scripts/hooks/sub-step-gate.sh` 骨架

## 当前 esr 状态对照

**可借鉴(6 处)**(直接迁 pattern,改 namespace):
1. `Ezagent.Entity.Registry` thin-wrapper-over-Elixir-Registry → `Ezagent.KindRegistry`(URI-keyed,只 Index 1)
2. Telemetry event 命名 convention `[:ezagent, area, verb]` → 对齐
3. `Ezagent.Telemetry.Buffer` 的 ETS rolling buffer + periodic prune 思路 → `Ezagent.Audit.Writer` 的 100ms batch
4. `Process.flag(:trap_exit, true)` + telemetry-emitting `terminate/2` pattern → `Ezagent.Kind.Server`
5. `PersistStore.get || initial_state` rehydrate pattern → `Ezagent.Kind.Snapshot.load_or_init/2`
6. `DynamicSupervisor` + `start_child` 模板 → `Ezagent.Kind.Supervisor`

**不借鉴(6 处反例)**:
1. `Ezagent.Entity.Server` 的 927 LOC 巨型 GenServer struct → `Ezagent.Kind.Server` 目标 ~70 LOC,3 个 top-level 字段
2. per-actor `dedup_keys: MapSet` + `dedup_order: :queue` → 改用全局 ETS LRU `Ezagent.Idempotency`,在 dispatch step 2.7 前置(Decision #69)
3. `Ezagent.Entity.Registry` 偷塞的 `:ezagent_actor_name_index` / `:ezagent_actor_role_index` → 不迁;这些是 plugin domain 二级索引,走 RoutingRegistry(Phase 2+)
4. `Ezagent.HandlerRouter` 的 Python sidecar dispatch → 不迁;新模型纯 in-BEAM dispatch
5. `Ezagent.Telemetry.Attach` 硬编码 wildcard event list → 不迁;`Ezagent.Audit` 只 attach `[:ezagent, :invoke, :stop]`(Decision #60)
6. 老 `ezagent_web` 5-socket 散布(handler/adapter/channel/cli/pty)→ 不迁;ezagent 2-socket 模型(Decision #32),Phase 1 只用 LV 内建 `/live`

## 不在 Phase 1 范围(boundary)

- ❌ `Ezagent.Message` struct / `MessageStore` / RoutingRegistry / Matcher / `Ezagent.Behavior.Chat` —— Phase 2
- ❌ Workspace / Template Class / Template Instance —— Phase 3
- ❌ Agent Kind / Identity Behavior / 真实 CapBAC(authz_check 仍是 stub permissive)—— Phase 3d
- ❌ View behaviour / Optimus CLI auto-derive —— Phase 4
- ❌ Feishu adapter / ezagent_plugin_cc(完整版)/ Pty-Web —— Phase 5

**v1_prototype 命名约定**:1b 的 CC bridge 任何文件都带 `_v1_prototype` 后缀(目录名 + 内部模块名),Phase 5 整体 wholesale replace 时清晰可识别。
