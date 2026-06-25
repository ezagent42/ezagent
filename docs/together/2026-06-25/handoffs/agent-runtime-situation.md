# Agent 运行时后端现状分析

> 写给 `allenwoods` 的 agent 运行时后端整合前置材料。
> 覆盖：cc-headless sidecar + protocol_api + LocalRuntime + 所有 flavor 的当前 spawn 路径 + 接缝 + 未决问题。
> 写完日期：2026-06-25。作者：gagameow（黄佳佳）。

---

## 0. 概念框架：三个正交维度

理解当前混乱的关键——ezagent 的 agent 系统有三个**正交维度**，它们在不同时间加入、各自独立演化，导致了今天的接缝：

| 维度 | 含义 | 变化方式 |
|---|---|---|
| **入口协议** | 外部怎么调用 agent | console UI（dispatch）、OpenAI HTTP API（protocol_api）、Feishu 消息 |
| **Agent 运行时（Kind）** | Agent Kind 进程跑在哪、怎么 spawn | `Entity.Agent` + `Entity.Echo` 两个 Kind 模块，通过 SpawnRegistry 管理 |
| **Sidecar（子进程）** | Agent 的"手和嘴"——实际执行 AI 模型调用的 OS 进程 | PTY（claude TUI）、SdkSidecar（Python SDK）、AppServer+BridgeSidecar |

**核心认知**：
- **protocol_api 换的是"入口协议"，不是"agent 运行时"**——agent 仍然 spawn 在同一个 BEAM 节点上，只是调用方式从内部 dispatch 变成了 OpenAI-compatible HTTP API
- **cc-headless/codex-remote 换的是"sidecar 类型"，不是"Kind 模块"**——它们和 cc/codex 共用 `Entity.Agent` Kind，区别只是把 PTY 换成了程序化 SDK sidecar
- **LocalRuntime 的定位是"运行时维度的唯一 chokepoint"**——它应该统一 Kind + sidecar 的生杀，但对入口协议不感知

---

## 0.1 演化时间线：为什么会有三套并行系统

```
Phase 1 — 本地 agent（2026-05 中旬 ~ 06-20 左右）
  curl / cc / codex / echo / np
  - Kind 进程 + 各自 sidecar（PTY 或纯进程）
  - 全部通过 console 创建和管理
  - SpawnRegistry / KindRegistry 是 agent 生杀的唯一路径
  - 没有 LocalRuntime，没有 cascade，没有 per-agent config_dir

Phase 2 — + protocol_api（2026-06-22 ~ 06-23）
  外部入口协议（OpenAI HTTP API）
  - 同一套 Agent Kind，换了一种入口方式
  - 通过 ApiKeyStore 做 token→agent 映射
  - ❌ 问题是：直接调 SpawnRegistry，绕过所有后来加的抽象
    （LocalRuntime、cascade、per-agent config_dir、grant mint）
  - ❌ 原因：protocol_api 合入时这些抽象还不存在 ——
    不是"故意绕过"，而是后续抽象层叠在上面后，它没被迁过去

Phase 3 — + headless sidecar 变体（2026-06-23 ~ 06-24）
  无 PTY 的 agent 运行时
  - cc-headless（06-24）：PTY → SdkSidecar（Python cc SDK via Port）
  - codex-remote（06-23）：PTY → AppServer + BridgeSidecar only
  - 各自手写 spawn + rollback 逻辑
  - ❌ 问题是：每个 flavor 的 Template.instantiate 自我重复
    （ensure_agent_kind → create_config_dir → start_sidecar → rollback_on_failure）

Phase 4 — + LocalRuntime + cascade（2026-06-24，最近一天）
  PR #95 / #17 cascade / per-agent config_dir
  - LocalRuntime：owner-gated facade（72 行，commit d0a7f4f2）
  - #17 cascade：凭据隔离 + grant mint
  - 部分调用点迁了（cc、codex、codex-remote、echo），部分没迁（cc-headless 的 spawn、curl、protocol_api）
  - ❌ 问题是：LocalRuntime 能力不足（URI-only，不支持 behaviors），
    导致 cc-headless/curl 被迫绕过它直接调 Kind.spawn

Phase 5（当前，06-25）— 整合
  收敛三套系统到 LocalRuntime 一个 chokepoint
```

---

## 1. 全景：6 个 Agent Flavor 的真实架构

ezagent 当前有 6 个核心 AI agent flavor（本 handoff 聚焦范围；不包括 `np`/`hello_builder` 等专用 flavor），**5/6 共用同一个 Kind 模块** `Ezagent.Entity.Agent`（区分靠 `:behaviors` 参数），只有 echo 有自己的 Kind `Ezagent.Entity.Echo`。

### 1.1 Flavor 一览

| Flavor | Kind 模块 | 子进程（sidecar） | Bridge Adapter | Template Class |
|---|---|---|---|---|
| **echo** | `Entity.Echo` | 可选 PTY（`/bin/bash -i`） | — | `EchoAgent` |
| **curl** | `Entity.Agent` | 无 | — | `CurlAgent.Template`（已注册，但 `create_agent` 走 direct spawn 不用它） |
| **cc** | `Entity.Agent` | PtyServer（erlexec 跑 `claude` TUI） | `BridgeAdapter`（`subprocess_ws`） | `CcAgent` |
| **cc-headless** | `Entity.Agent` | SdkSidecar（Python cc SDK via Port，stdin/stdout JSON lines） | `CcHeadlessBridgeAdapter`（`in_process_sync`） | `CcHeadlessAgent` |
| **codex** | `Entity.Agent` | PtyServer + AppServer + BridgeSidecar | `BridgeAdapter`（`subprocess_ws`） | `CodexAgent` |
| **codex-remote** | `Entity.Agent` | AppServer + BridgeSidecar（无 PTY） | `CodexRemoteBridgeAdapter`（delegate 到 codex 的） | `CodexRemoteAgent` |

### 1.2 Kind 模块解析（AgentModuleResolver）

当一个 `entity://agent/<ws>/<name>` URI 需要 spawn 时，3 步 fallback 解析 Kind 模块：

```
1. KindSnapshot.kind_type（DB 快照，快速路径）
   → "agent" → Entity.Agent | "echo" → Entity.Echo
2. Workspace session_templates 里的 "class" 字段
   → "cc.agent" → Entity.Agent | "echo.agent" → Entity.Echo
3. AgentFlavorRegistry（按 flavor 查）
   → "cc" / "curl" / "codex" / "cc-headless" / "codex-remote" → Entity.Agent
   → "echo" → Entity.Echo
```

每个 agent plugin 的 `agent_flavors/0` 声明 `flavor → {kind, template_class, bridge_adapter}`。`AgentFlavorRegistry` 是 ETS table `:ezagent_agent_flavor_registry`。

### 1.3 Behavior 区分（共用 `Entity.Agent` 的 5 个 flavor）

`Entity.Agent` 的 `init/1` 根据传入的 `:behaviors` 参数决定生效哪些 Behavior：

- **cc**：`:behaviors` 缺失 → `Entity.Agent` 的 `nil` 分支 → `base_behaviors/0`（不含 PTY 之外的特定 flavor behavior）
- **cc-headless**：`cc_headless_behaviors()` → 包含 `Behavior.CcHeadlessAgent`（支持 `:sync_result`）等 headless 专属 behavior
- **codex**：`:behaviors` 缺失 → 同 cc，走 `nil` → `base_behaviors/0`
- **codex-remote**：`:behaviors` 缺失 → 同 cc/codex，走 `nil` → `base_behaviors/0`。**没有独立的 `codex_remote_behaviors` 函数**，codex-remote 只是不启动 PTY sidecar，Kind 的 behavior set 和 codex 一样
- **curl**：`instance_behaviors` thunk → `curl_behaviors()` → 包含 `Behavior.CurlAgent`

---

## 2. 三条 Agent 生成路径（当前各自为政）

### 2.1 路径 1：Template 路径（create_agent → cascade）

```
Workspace.create_agent/3
  → Router.dispatch → Behavior.Workspace.:create_agent
    → AgentCreate.handle_create_agent/2
      → 验证 flavor / name / cwd
      → compose agent URI
      → do_create_agent(flavor, ...)
```

**File-flavor（cc / cc-headless / codex / codex-remote）**：
```
do_create_agent → file_flavor_template → register_and_invoke_template
  → Store.update_templates（持久化 template 到 DB）
  → instantiate_template_now
    → 检测到 file_flavor_class?（实现 CredentialAdapter）
    → spawn_file_flavor_via_cascade
      → Agent.spawn_from_template_content/5（#17 cascade chokepoint，ezagent_domain_session）
        → 分配 per-agent config_dir
        → #17 credential cascade（grant mint + 用户默认凭据解析）
        → 调用 Template.instantiate/3
```

**Non-file-flavor（echo）**：
```
do_create_agent → register_and_invoke_template → Loader.invoke_template
  → Template.instantiate/3（直接，不经过 cascade）
```

**Direct-spawn（curl）**：
```
do_create_agent → direct_spawn_flavor_agent/2
  → AgentFlavorRegistry.lookup(flavor) → 拿到 decl.kind + instance_behaviors thunk
  → Ezagent.Kind.spawn(decl.kind, %{uri: ..., behaviors: thunk.()})
  → 不注册 template，不走 cascade
```

### 2.2 路径 2：protocol_api 路径（完全绕过所有抽象）

```
POST /v1/chat/completions
  → OpenaiChatPlug.call/2
    → ApiKeyStore.verify(token) → 拿到 entity_uri / workspace_uri / target_agent
    → ConversationRegistry.resolve(conversation_id, workspace, entity)
      → SpawnRegistry.spawn(session_uri)        ← 直接调！不经过 LocalRuntime
    → join_agent(session_uri, entity, target_agent)
      → maybe_register_flavor(agent)
      → SpawnRegistry.spawn(agent)              ← 直接调！不经过 LocalRuntime
      → wait_for_kind_registry(agent)            ← 直接调！KindRegistry.lookup
      → Router.dispatch(session, :session, :join)
```

`ConversationRegistry` 两条 spawn 路径都直接调 `SpawnRegistry.spawn/1`：
- `resolve(nil, ...)` → `create_stateless` → `SpawnRegistry.spawn(session_uri)`
- `resolve(conversation_id, ...)` → `create_and_bind` → `SpawnRegistry.spawn(session_uri)`

### 2.3 路径 3：Cold Restart / Boot 恢复路径

```
Workspace.Loader.load_all/0
  → 遍历所有 workspace 的 session_templates
    → Loader.invoke_template(workspace_uri, tmpl_name)
      → Template.instantiate/3
        → agent_kind_alive?(agent_uri) 检查
        → 如果 Kind 活着但 sidecar 死了 → ensure_subprocess_alive/2
        → 如果 Kind 也死了 → 重新 spawn（走上述路径）
```

### 2.4 三条路径的对比

| 维度 | Template 路径 | protocol_api 路径 | Cold Restart |
|---|---|---|---|
| 入口 | `Workspace.create_agent` | `POST /v1/chat/completions` | `Workspace.Loader` |
| Agent spawn | cascade（file-flavor）/ Loader / Kind.spawn | **`SpawnRegistry.spawn` 直调** | Template.instantiate |
| Sidecar spawn | Template.instantiate 内手写 | ❌ 不启动 sidecar（只 spawn Kind；已 provisioning 的 sidecar 可能独立存活）| ensure_subprocess_alive |
| LocalRuntime 感知 | cc/codex/codex-remote/echo 走；cc-headless spawn 不走 | ❌ 完全绕过 | 取决于模板实现 |
| Config dir | cascade 分配 + grant | 无 | 从 respawn_data 恢复 |
| 原子性 | 有 rollback（Store + Kind.terminate） | 无 | 无 |

---

## 3. 三套 sidecar 运行时（各自独立）

### 3.1 SdkSidecar（cc-headless）

```
ezagent_plugin_cc/application.ex:
  {Registry, keys: :unique, name: EzagentPluginCc.SdkSidecarRegistry}
  {DynamicSupervisor, name: EzagentPluginCc.SdkSidecarSupervisor}
```

- **形态**：GenServer，通过 `Port.open({:spawn_executable, ...})` 起 Python SDK worker
- **协议**：stdin/stdout JSON lines（`id` + `op: "query"` → `id` + `ok: true/false`）
- **生命周期 API**：`start/2` / `stop/1` / `alive?/1` / `query/3` / `lookup/1` / `recent_output/1`
- **注册**：`via Registry, {SdkSidecarRegistry, agent_uri_string}`
- **启动参数**：`cwd` / `config_dir` / `session_id` / `permission_mode` / `model` / `effort` / `cli_path` / `system_prompt` / `allowed_tools` / `disallowed_tools` / `mcp_servers` / `uv_path` / `python_path` / `sdk_worker_path`
- **Bridge 投递**：`CcHeadlessBridgeAdapter.deliver/2` → `SdkSidecar.query(agent_uri, text)` — **同步**、in-process
- **回执路径**：`Behavior.CcHeadlessAgent.:sync_result` 持久化 + session reply

### 3.2 PtyServer（cc / codex / echo-with-pty）

```
ezagent_domain_pty（Tier-2 Domain app）:
  Ezagent.Domain.Pty.start(agent_uri, params)
  → 通过 :via Registry 去重
  → erlexec 起子进程（claude / codex / bash）
```

- **形态**：GenServer + erlexec 管理的 OS 进程
- **协议**：PTY I/O（xterm.js 终端）
- **生命周期 API**：`start/2` / `alive?/1` / `status/1` / `phase/1`
- **cc 的 cmd**：`claude --settings ... --mcp-config ...`（argv list，无 shell）
- **Bridge 投递**：`BridgeAdapter.deliver/2` → WebSocket `agent_bridge_push` → channel 进程

### 3.3 AppServer + BridgeSidecar（codex / codex-remote）

```
ezagent_plugin_codex:
  EzagentPluginCodex.AppServer (DynamicSupervisor + Registry)
  EzagentPluginCodex.BridgeSidecar (DynamicSupervisor + Registry)
```

- **AppServer**：Codex app-server，暴露 Unix domain socket
- **BridgeSidecar**：Python bridge，连接 app-server socket → WebSocket → ezagent AgentBridge
- **thread_id**：bridge 启动后写入文件，codex-remote 轮询等待
- **Bridge 投递**：通过 AgentBridge WebSocket（`subprocess_ws` transport class）

### 3.4 Sidecar 和 Agent Kind 之间没有原子性保证

每个 flavor 的 `Template.instantiate/3` 手写了 rollback 逻辑：
- cc-headless：`rollback_runtime(agent_uri)` = `SdkSidecar.stop + Kind.terminate`
- cc：`Kind.terminate(agent_uri)` + `handle_spawn_failure`（清除 config_dir）
- codex-remote：`rollback_remote_sidecars(agent_uri)` = `BridgeSidecar.stop + AppServer.stop`，然后 `Kind.terminate(agent_uri)`

这些 rollback 是每个 flavor 独立手写的，没有统一的框架保证。

---

## 4. LocalRuntime：设计意图 vs 现状

### 4.1 是什么

`Ezagent.LocalRuntime`（72 行，`apps/ezagent_core/lib/ezagent/local_runtime.ex`）是 PR #95 引入的 owner-gated facade。三个函数：

```elixir
kind_alive?(uri)              # KindRegistry.lookup + owner-gate
ensure_started(uri)           # SpawnRegistry.spawn（透传）
ensure_started_detailed(uri)  # SpawnRegistry.spawn_detailed（透传）
```

### 4.2 设计意图（来自 moduledoc）

1. **去中心化准备**：多节点部署时，一个 Kind 可能活在别的节点。裸 `KindRegistry.lookup` 拿到 `:error` 会误判为"已死"→ 本地重启 → 重复 agent。`kind_alive?/1` 通过 `WorkspaceOwnerGate` 区分"不是我的"vs"真的死了"。
2. **Plugin 隔离**：给 plugin 一个 chokepoint，CI grep gate 确保 plugin 代码不碰 `KindRegistry`/`SpawnRegistry` 内部。

### 4.3 现状：能力缺口

| 需求 | LocalRuntime 支持？ | 谁在做？ |
|---|---|---|
| 按 URI spawn Agent Kind | ✅ `ensure_started(uri)` | 透传到 SpawnRegistry |
| 带 `:behaviors` 参数 spawn | ❌ 只有 URI 参数 | cc-headless: `Kind.spawn(Entity.Agent, %{uri, behaviors})` 直调；curl: `Kind.spawn(decl.kind, spawn_args)` 直调 |
| 管理 sidecar 生命周期 | ❌ 完全不知道 sidecar 存在 | 各 Template.instantiate 手写 |
| sidecar + Kind 原子 spawn | ❌ | 各 Template 手写 rollback |
| protocol_api 入口 | ❌ 完全绕过 | OpenaiChatPlug / ConversationRegistry 直调 SpawnRegistry |

### 4.4 哪些调用点已经走了 LocalRuntime vs 还没走

**已迁（#95 PR-2 + PR-3）**：
- cc (`spawn.ex:210`): `LocalRuntime.ensure_started_detailed(agent_uri)`
- codex (`codex_agent.ex:554`): `LocalRuntime.ensure_started_detailed(agent_uri)`
- codex-remote (`codex_remote_agent.ex:338`): `LocalRuntime.ensure_started_detailed(agent_uri)`
- echo (`echo_agent.ex:194`): `LocalRuntime.ensure_started_detailed(agent_uri)`
- cc-headless (`cc_headless_agent.ex:182`): `LocalRuntime.kind_alive?(agent_uri)` — **只迁了 liveness probe，spawn 还是 `Kind.spawn/2` 直调**

**未迁（#99 盘点的 6 处 + 更多）**：

| 位置 | 调了什么 | 问题 |
|---|---|---|
| `openai_chat_plug.ex:109` | `KindRegistry.lookup(agent_uri)` | 裸读，无 owner-gate |
| `openai_chat_plug.ex:195` | `SpawnRegistry.spawn(agent)` | 裸 spawn |
| `openai_chat_plug.ex:240` | `SpawnRegistry.ensure_live(session_uri)` | 裸 ensure_live |
| `conversation_registry.ex:53,90` | `SpawnRegistry.spawn(session_uri)` | 裸 spawn session |
| `hello_session.ex:41` | `KindRegistry.lookup(session_uri)` | 裸读 session Kind |
| `inbound_dispatcher.ex:229` | `SpawnRegistry.ensure_live(session_uri)` | feishu session 恢复 |
| `workspace_plugin_data.ex:122,164,206` | `KindRegistry.lookup` / `KindRegistry.list_all` | world 读 Kind |
| `identity_data.ex:214` | `KindRegistry.list_all` | world agent 列表 |
| `mention_parser.ex:136` | `KindRegistry.list_all` | feishu @ 解析 |
| `cc_headless_agent.ex:174` | `Kind.spawn(Entity.Agent, %{uri, behaviors})` | 带 behaviors 的 spawn — **LocalRuntime 不支持此 arity** |
| `agent_create.ex:450` | `Kind.spawn(decl.kind, spawn_args)` | curl 的带 behaviors spawn — **LocalRuntime 不支持此 arity** |

---

## 5. 核心接缝（按严重程度排列）

### 5.1 🔴 LocalRuntime 不支持带 `:behaviors` 的 spawn

**影响范围**：cc-headless、curl、以及未来的任何 flavor 需要传 behaviors 参数时。

**当前绕过方式**：直接调 `Ezagent.Kind.spawn(kind_module, %{uri: ..., behaviors: ...})`，绕过 LocalRuntime 和 owner-gate。

**阻塞项**：#918（echo→Entity.Agent）需要 LocalRuntime 一个带 behaviors 的 spawn arity。

**关键决策点**：LocalRuntime 应该加什么 arity？
- 选项 A：`ensure_started(uri, opts)` 其中 `opts` 含 `:behaviors`
- 选项 B：只给 echo 开 sanctioned 例外（不推荐，问题会复现）

### 5.2 🔴 protocol_api 完全绕过所有运行时抽象

**影响范围**：所有通过 OpenAI-compatible API 进来的请求。

**问题**：
- `OpenaiChatPlug` 直接调 `SpawnRegistry.spawn` / `KindRegistry.lookup`
- `ConversationRegistry` 直接调 `SpawnRegistry.spawn` 创建 session
- 不经过 LocalRuntime，不经过 cascade，不参与 sidecar 管理
- Agent 创建时不分配 per-agent config_dir（无凭据隔离）

### 5.3 🔴 Sidecar 生命周期与 Agent Kind 生命周期分离

**影响范围**：cc-headless、cc、codex、codex-remote。

**问题**：
- Agent Kind 和 sidecar 是两次独立调用
- 失败时的 rollback 是各 flavor 手写的（逻辑重复、容易漏）
- 没有一个 `alive?/1` 能同时检查 Kind + sidecar
- Cold restart 时，`ensure_subprocess_alive/2` 需要 respawn_data 里有正确的 `cwd`/`config_dir` 等，但这些数据的持久化路径各异

### 5.4 🟡 三条 agent 生成路径行为不一致

| 行为 | Template 路径 | protocol_api 路径 |
|---|---|---|
| Config dir 分配 | ✅ cascade 分配 | ❌ 无 |
| 凭据隔离（per-agent home） | ✅ 有 | ❌ 无 |
| Grant mint | ✅ #17 cascade | ❌ 无 |
| Template 注册 | ✅ Store 持久化 | ❌ 无 |
| Agent lineage 记录 | ✅ AgentLineage.record | ❌ 无 |
| Sidecar 启动 | ✅ Template.instantiate | ❌ 不启动 |

**实际影响**：通过 protocol_api 创建的 agent 缺少 config_dir / grant，导致功能残缺（例如无法使用 MCP tools、无法加载 skill 文件等）。

### 5.5 🟡 cc-headless 的 spawn 不一致

cc-headless 的 `ensure_agent_kind` 直接调 `Kind.spawn(Entity.Agent, %{uri, behaviors: cc_headless_behaviors(), ...})`，**绕过 LocalRuntime**。原因是 LocalRuntime 只接受 URI，无法传递 `:behaviors` 参数。

相比之下，codex-remote 的 `ensure_agent_kind` 走 `LocalRuntime.ensure_started_detailed/1`（URI-only），但 codex-remote **没有注册自定义 behaviors**（`instance_behaviors` 为 nil），所以 URI-only spawn 对它不影响——它走 `Entity.Agent` 的默认 `base_behaviors/0` 即可。

cc-headless 是唯一一个**既需要自定义 behaviors、又要走 LocalRuntime** 的 flavor——这是 LocalRuntime 缺 arity 的最直接证据。

---

## 6. 整合后目标态（end-state）

### 6.1 一句话

**LocalRuntime 成为 agent 运行时的唯一入口**。无论从 console UI、protocol_api、Feishu 入口、还是 cold restart 进来，agent Kind + sidecar 的生杀都经过同一个 chokepoint。

### 6.2 目标架构

```
                        ┌──────────────────────────┐
                        │      入口协议层           │
                        │  (不受 LocalRuntime 管)   │
                        │                          │
                        │  console UI  │ protocol_api│ Feishu │...
                        └──────┬───────┴──────┬─────┴────┬───┘
                               │              │          │
                               ▼              ▼          ▼
                        ┌──────────────────────────────┐
                        │     Router.dispatch /        │
                        │     Invocation.dispatch       │
                        │     (P14 — 唯一跨 Kind 路径)  │
                        └──────────────┬───────────────┘
                                       │
                                       ▼
                        ┌──────────────────────────────┐
                        │       LocalRuntime            │
                        │   (唯一运行时 chokepoint)      │
                        │                              │
                        │  • ensure_started(uri, opts)  │
                        │  • alive?(uri)                │
                        │  • stop(uri)                  │
                        │  • restart(uri)               │
                        └──────┬───────────┬───────────┘
                               │           │
                    ┌──────────▼──┐  ┌─────▼──────────┐
                    │ Agent Kind  │  │ Sidecar 管理     │
                    │ (Entity.Agent│  │ (统一生命周期)   │
                    │  Entity.Echo)│  │                 │
                    │             │  │ • SdkSidecar    │
                    │ • 按 behaviors│  │ • PtyServer     │
                    │   区分 flavor │  │ • AppServer     │
                    │             │  │ • BridgeSidecar │
                    └─────────────┘  └─────────────────┘
```

### 6.3 目标态特性

**对上层（入口协议）**：
- console / protocol_api / Feishu / Loader（对 agent/session Kind）都调 `LocalRuntime.ensure_started(uri, opts)`
- 入口协议**不感知** Kind 模块、SpawnRegistry、sidecar 类型——这些都是 LocalRuntime 内部细节
- `opts` 携带 flavor 特有参数：`behaviors`、`cwd`、`config_dir`、`session_id` 等
- ⚠️ Loader 还管理非 agent Kind（workspace、session 等），这些继续走 SpawnRegistry 或各自的 spawn 路径，不纳入 LocalRuntime

**对 Kind 层**：
- `LocalRuntime.ensure_started/2` 接受 `:behaviors` 参数（补当前缺口）
- 不再有 plugin 代码直调 `Kind.spawn/2` 或 `SpawnRegistry.spawn/1`
- CI grep gate 强制执行

**对 Sidecar 层**：
- 每个 flavor 声明 sidecar spec（类似 Ecto `has_many`）
- `ensure_started` 按 spec 依次启动 Kind → sidecar(s)，任一步失败整体 rollback
- `alive?/1` 检查 Kind + 全部 sidecar
- `stop/1` 停全部 sidecar + Kind（逆序）
- ⚠️ **架构约束**：`LocalRuntime` 在 `ezagent_core`，不能直接引用 plugin 模块（core 无 plugin 依赖）。Sidecar spec 需要通过 Registry 或 domain 层 behavior 回调来声明（plugin boot 时注册），不能硬编码 core → plugin 的编译期依赖

**对 protocol_api**：
- `OpenaiChatPlug` 和 `ConversationRegistry` 改为调 `LocalRuntime`
- API 创建的 agent 和 console 创建的 agent 行为一致：都有 config_dir、grant、lineage

### 6.4 不变式保证（目标态下）

| 不变式 | 如何保证 |
|---|---|
| P14 — Dispatch 是唯一跨 Kind 路径 | LocalRuntime 只管理运行时生杀；消息传递仍走 Router/Invocation.dispatch |
| P22 — 可靠原语在 core | ReadyGate / PendingDelivery / Idempotency 不受 LocalRuntime 影响 |
| Plugin 隔离（P9） | Plugin 代码只调 LocalRuntime，不碰 SpawnRegistry/KindRegistry 内部 |
| CI grep gate | `mix check_invariants` 检查 plugin 代码是否直调 SpawnRegistry/KindRegistry |
| LOC budget | `local_runtime.ex` 当前 72 行，core target ~870，red line 1100 |

---

## 7. 建议的整合步骤（供 allenwoods 参考，不代替他的设计）

### 7.1 分步建议

**Step 1 — LocalRuntime 加 behaviors arity**：

```elixir
# 现状
ensure_started(uri)
ensure_started_detailed(uri)

# 建议加
ensure_started(uri, opts)  # opts: behaviors, flavor, args...
ensure_started_detailed(uri, opts)
```

这个变更解锁 #918（echo→Entity.Agent），也让 cc-headless / curl 可以走 LocalRuntime 而不是直调 `Kind.spawn`。

**Step 2 — 迁 #99 的 6+ 处调用点**：

把 protocol_api、hello、world、feishu 的 `SpawnRegistry`/`KindRegistry` 直调改为 `LocalRuntime`。这是 CI grep gate 的要求，也是统一入口的前提。

**Step 3 — 统一 protocol_api 入口**：

让 `OpenaiChatPlug` 和 `ConversationRegistry` 走 LocalRuntime（而不是 SpawnRegistry），并且通过 cascade 分配 config_dir。这样通过 API 创建的 agent 和通过 console 创建的 agent 行为一致。

**Step 4 — Sidecar 生命周期纳入 LocalRuntime**：

考虑一个 `sidecar_spec`（类似 Ecto 的 `has_many`），让每个 flavor 声明"我有哪些 sidecar"：

```elixir
# 概念示例
sidecar :sdk, SdkSidecar, start: &SdkSidecar.start/2
sidecar :pty, PtyServer, start: &Domain.Pty.start/2
```

然后 LocalRuntime 的 `ensure_started` 自动管理 Kind + sidecar 的原子 spawn + rollback。

**Step 5 — Codex 的 AppServer + BridgeSidecar 纳入同模型**。

### 7.2 不变式约束

- **P14 — Dispatch is the only path between Kinds**：任何整合不能绕过 Router.dispatch/Invocation.dispatch
- **P22 — Reliability primitives live in core**：ReadyGate / PendingDelivery / Idempotency 不能因为整合而跳过
- **CI gate**：`mix check_invariants` + `plugin_workspace_locality_contract_test` 必须在整合后仍然绿
- **LOC budget**：`local_runtime.ex` 当前 72 行，core target ~870，有空间扩展但不要超过 1100 红线

---

## 8. 关键文件索引

| 关注点 | 文件 |
|---|---|
| LocalRuntime facade | `apps/ezagent_core/lib/ezagent/local_runtime.ex`（72 行） |
| SpawnRegistry | `apps/ezagent_core/lib/ezagent/spawn_registry.ex` |
| KindRegistry | `apps/ezagent_core/lib/ezagent/kind_registry.ex` |
| WorkspaceOwnerGate | `apps/ezagent_core/lib/ezagent/workspace_owner_gate.ex` |
| AgentFlavorRegistry | `apps/ezagent_core/lib/ezagent/agent_flavor_registry.ex`（ETS） |
| create_agent action | `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create.ex`（831 行，核心） |
| Workspace.create_agent | `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:760` |
| Domain.Agent facade | `apps/ezagent_domain_session/lib/ezagent/domain/agent.ex` |
| Entity.Agent Kind | `apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex` |
| AgentModuleResolver | `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/agent_module_resolver.ex` |
| cc template + spawn | `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` + `cc_agent/spawn.ex` |
| cc-headless template | `apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_agent.ex` |
| SdkSidecar | `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/sdk_sidecar.ex` |
| cc headless bridge | `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/cc_headless_bridge_adapter.ex` |
| codex-remote template | `apps/ezagent_plugin_codex/lib/ezagent/template/codex_remote_agent.ex` |
| codex remote bridge | `apps/ezagent_plugin_codex/lib/ezagent/plugin_codex/codex_remote_bridge_adapter.ex` |
| OpenaiChatPlug | `apps/ezagent_plugin_protocol_api/lib/ezagent_plugin_protocol_api/openai_chat_plug.ex` |
| ConversationRegistry | `apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/conversation_registry.ex` |
| echo template | `apps/ezagent_plugin_echo/lib/ezagent/template/echo_agent.ex` |
| CI grep gate | `mix check_invariants`（lifecycle + plugin_workspace_locality_contract_test） |
| #99 / #918 背景 | `docs/together/2026-06-24/review.zh_cn.md` |
| LocalRuntime 设计 | `docs/skill` 里的 LocalRuntime doc（#95 PR-final, commit e2807c0c） |
