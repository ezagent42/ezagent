# Agent Console 现状分析与缺口

> 任务 B 前置分析。gagameow（黄佳佳），2026-06-25。
> 分支：`feat/agent-console`（待开，off `main`）

---

## 1. 当前架构

### 1.1 三层结构

```
React UI (Identities.tsx, 945行)
  │  world:dispatch 事件 → LiveView socket
  ▼
WorldLive (world_live.ex, 856行)
  │  handle_event("world:dispatch", ...) → 按 action 路由
  ├─ agents.create/delete/config.* → AgentActions.handle_dispatch/3
  └─ 其他事件 → ConversationActions / AdminActions / ...
  ▼
AgentActions (agent_actions.ex, 381行)
  │  调用 Workspace.create_agent / Invocation.dispatch / AgentConfig facade
  ▼
IdentityData (identity_data.ex, 692行)
  │  构建 per-route 的 world:state JSON
  │  读 KindRegistry / UriQuery / Domain.Agent / AgentConfig / Sandbox / Bridge
  ▼
后端 facades（AgentConfig / Domain.Agent / Workspace）
```

### 1.2 路由表（routes.ex）

| 路径 | 组件 | 功能 |
|---|---|---|
| `/identities` | `identities` | 目录视图（卡片 + 过滤器） |
| `/identities/agents` | `agents_table` | 表格视图 |
| `/identities/agents/new` | `agent_new_form` | 创建表单 |
| `/identities/agents/:uri` | `agent_detail` | 详情页 |
| `/identities/agents/:uri/caps` | `entity_caps` | CapBAC 授权 |
| `/identities/agents/:uri/api-keys` | `agent_api_keys` | API Keys 管理 |
| `/identities/agents/:uri/config` | `agent_config` | 配置编辑器 |
| `/identities/agents/:uri/extensions` | `agent_extensions` | 扩展列表 |
| `/identities/agents/:uri/terminal` | `pty_terminal` | PTY 终端 |

### 1.3 事件表（WorldLive → AgentActions）

| 事件 action | 处理函数 | 功能 |
|---|---|---|
| `agents.create` | `dispatch_agent_create` | 创建 agent |
| `agents.delete` | `dispatch_agent_delete` | 删除 agent |
| `agents.config.update` | `dispatch_config_update` | 配置 delta 写入 |
| `agents.config.delete_path` | `dispatch_config_delete_path` | 配置字段删除 |
| `agents.config.repoint` | `dispatch_config_repoint` | 配置指针重定向 |

---

## 2. 前后端契约（当前 main 分支）

### 2.1 核心认知：存在两套独立的 Agent 配置存储

这是理解当前契约的关键——agent 的配置分属两个**完全不同的存储系统**：

| 维度 | 存储 A：Config Cascade | 存储 B：Template Data |
|---|---|---|
| **存储位置** | `ConfigStore` 表（`ConfigObject` + `ConfigPointer`） | Kind 快照的 `respawn_template_data` 字段（Sandbox slice） |
| **key** | `"advisor.behavior"`（默认）+ 任意 key | 无 key——整个 template 是一个 map |
| **写入时间** | **运行时**（console `AgentConfigEditor` → `agents.config.update`） | **创建时**（`create_agent` → template instantiate → Kind snapshot） |
| **读取路径** | `AgentConfig.read_cascade/4` → dispatch → `ConfigEvolve.handle_read_cascade/2` | sandbox read（`Invocation.dispatch → :sandbox/:read`） |
| **消费端** | `ConfigProjection.render_soul/1` → 写入 `CLAUDE.md` → cc agent 启动时加载 | `sdk_sidecar_params/2` → 传给 Python SDK worker 环境变量 |
| **典型字段** | `soul_md` + 任意 key-value | `model`、`effort`、`permission_mode`、`allowed_tools`、`disallowed_tools`、`mcp_servers`、`system_prompt`、`cwd`、`claude_session_id` |
| **运行时可编辑** | ✅（通过 `AgentConfigEditor`） | ❌（需要改 template + respawn agent） |

### 2.2 当前 world:state JSON 契约（详情页）

```typescript
// 当前 IdentityData.state_for(:agent_detail) 实际返回的字段
{
  // 路由信息
  component: "agent_detail",
  title: "Agent Detail",
  path: "/identities/agents/...",
  
  // 基础标识
  agent_uri: string,
  workspace_uri: string,
  flavor: string,                    // UriQuery.resolve(:flavor, uri)
  
  // 运行时状态
  agent_status: {
    phase: "alive" | "not_found" | "error",
    flavor: string | null,
    detail: object | null
  },
  bridge: object | null,             // AgentBridge.Registry.list_connected
  
  // Sandbox 数据（来自 respawn_template_data）
  project_cwd: string | null,
  config_dir: string | null,
  source_template: string | null,    // "cc" | "codex" | null
  
  // CapBAC
  granted_caps: CapRow[],
  
  // 导航
  config_path: string | null,
}
```

### 2.3 当前 world:state JSON 契约（Config 面板）

```typescript
// 当前 IdentityData.state_for(:agent_config) 实际返回的字段
{
  component: "agent_config",
  agent_uri: string,
  cascade: {
    agent_uri: string,
    workspace_uri: string,
    default_key: "advisor.behavior",
    layer_order: ["workspace", "user", "session"],
    keys: [{
      key: string,                   // 如 "advisor.behavior"
      effective_body: Record<string, unknown>,  // 合并后的配置 body
      editable: boolean,
      editable_layer: "user",
      layers: {
        workspace: { body: object | null, config_id: string | null } | null,
        user:      { body: object | null, config_id: string | null } | null,
        session:   { body: object | null, config_id: string | null } | null,
      }
    }]
  },
  config_error: string | undefined,  // 读取失败时的错误消息
}
```

### 2.4 契约缺口总结

| 缺口 | 说明 |
|---|---|
| **详情页缺 template data 字段** | `respawn_template_data` 里有 model/effort/permission_mode/system_prompt/allowed_tools/disallowed_tools/mcp_servers，但 `IdentityData.state_for(:agent_detail)` 只解了 project_cwd/config_dir/source_template，其他字段没有放入 state |
| **详情页缺 config cascade soul** | `advisor.behavior` body 里的 `soul_md` 没有在详情页展示 |
| **详情页缺 sections/skills/KB** | 这些概念的 UI/管理面在 main 不存在。domain 层有 `Ezagent.Role` 结构体（`skills`/`plugins`/`prompt`/`behaviors`/`requested_caps`）和 `AgentTemplate.desired_skills`/`desired_caps` 字段，但缺少 operator 可视化管理面（见 §5-6） |
| **Config 面板缺结构化编辑** | 当前是通用 kv 编辑器，没有按字段类型选择 widget（见 §3.3） |

---

## 3. 功能完成度矩阵

### 3.1 CRUD 操作

| 操作 | 状态 | 路径 | 备注 |
|---|---|---|---|
| **Create** | ✅ 完成 | UI 表单 → `agents.create` → `Workspace.create_agent/3` → dispatch → cascade | 含 flavor/cwd/caps/with_pty 字段；有客户端验证 |
| **Read（列表）** | ✅ 完成 | `IdentityData.list_entities/2` → `KindRegistry.list_all/0` | 卡片 + 表格双视图；支持按 flavor 过滤 |
| **Read（详情）** | ⚠️ 部分 | `IdentityData.state_for/2` → `agent_status` + sandbox + bridge | 见 §3.2 |
| **Update（配置）** | ⚠️ 部分 | `AgentConfigEditor` → `agents.config.update` → `AgentConfig.apply_delta/4` | 通用 kv 编辑器；见 §3.3 |
| **Delete** | ✅ 完成 | 详情页确认 → `agents.delete` → dispatch → `Kind.terminate` | 含 live-session 绑定检查 |
| **API Keys** | ✅ 完成 | 列表 + 添加表单 → `agent.api_key.put` | 含 can_edit 鉴权 |
| **Extensions** | ✅ 完成 | 只读列表 → sandbox read | 支持 no_config_dir / error 降级 |

### 3.2 详情页字段：逐字段状态

#### 已接线（今天就有数据）

| 字段 | 数据来源 | 实现位置 |
|---|---|---|
| URI | route params | 前端 `state.agent_uri` |
| Phase | `Domain.Agent.lifecycle_status/1` → `agent_status.phase` | 后端 `identity_data.ex:agent_status/1` |
| Flavor | `UriQuery.resolve(:flavor, uri)` | 后端 `identity_data.ex:flavor_for/2` |
| project_cwd | sandbox read → `respawn_template_data.project_cwd` | 后端 `identity_data.ex:sandbox_project_cwd/1` |
| config_dir | sandbox read → `config_dir_path` | 后端 `identity_data.ex:sandbox_config_dir/1` |
| Template | sandbox read → `respawn_template_data.flavor` | 后端 `identity_data.ex:sandbox_source_template/1` |
| Bridge | `AgentBridge.Registry.list_connected/0` | 后端 `identity_data.ex:bridge_entry/1` |
| Granted caps | `Invocation.dispatch → :identity/:list_caps` | 后端 `identity_data.ex:list_entity_caps/3` |

#### 有数据但未读取（今天后端加 ~30 行即可展示）

| 字段 | 数据在哪 | 状态 |
|---|---|---|
| **soul / soul_md** | 存储 A：config cascade `advisor.behavior.body.soul_md` | ⚠️ `IdentityData` 没读 config cascade |
| **model** | 存储 B：`respawn_template_data.model` | ⚠️ sandbox read 返回了，`IdentityData` 没解 |
| **effort** | 存储 B：`respawn_template_data.effort` | ⚠️ 同上 |
| **permission_mode** | 存储 B：`respawn_template_data.permission_mode` | ⚠️ 同上 |
| **system_prompt** | 存储 B：`respawn_template_data.system_prompt` | ⚠️ 同上 |
| **allowed_tools** | 存储 B：`respawn_template_data.allowed_tools` | ⚠️ 同上 |
| **disallowed_tools** | 存储 B：`respawn_template_data.disallowed_tools` | ⚠️ 同上 |
| **mcp_servers** | 存储 B：`respawn_template_data.mcp_servers` | ⚠️ 同上 |

#### 真正缺失（后端无存储、无机制）

| 字段 | 现状 | 状态 |
|---|---|---|
| **skills** | 无存储/分发机制 | ❌ 标"还没接线" |
| **tools** | 无注册/分发机制 | ❌ 标"还没接线" |
| **KB** | 无 KB 存储/检索机制 | ❌ 标"还没接线" |
| **lifecycle 详情** | `Domain.Agent.lifecycle_status/1` 只返回 phase+flavor，无更多详情 | ❌ 标"还没接线" |
| **settings 管理** | cc operator_settings 在 template data 里，无独立管理面 | ❌ 标"还没接线" |
| **fork (parent template)** | `Behavior.Template` 有 `:fork` action（domain 层存在），但无 UI 触发入口 | ❌ 标"Deferred（domain 层已有，缺 UI）" |

### 3.3 Config 面板：字段编辑现状 vs 目标

当前 `AgentConfigEditor` 是**通用 kv 编辑器**：
- 所有字段默认 `<Input type="text">`
- 仅有 `soul_md` 特殊处理为 `<textarea rows=4>`
- 不支持类型感知（boolean → toggle、enum → select、JSON → structured form）

**升级方案**：在 `AgentConfigKeySection` 中增加字段名 → widget 类型映射（纯前端改动，后端 contract 不变）：

| 字段名 | widget 类型 | 说明 |
|---|---|---|
| `soul_md` | `textarea` | ✅ 已有 |
| `system_prompt` | `textarea` | 和 soul_md 类似 |
| `model` | `select` | 已知模型列表（deepseek-chat / deepseek-v4-pro / claude-sonnet-4-6 等） |
| `effort` | `select` | low / medium / high / xhigh / max |
| `permission_mode` | `select` | default / acceptEdits / plan / bypass |
| `allowed_tools` | `tag-editor` | 逗号分隔列表 → tag UI |
| `disallowed_tools` | `tag-editor` | 同上 |
| `mcp_servers` | `json-textarea` | JSON 对象，第一版用 textarea（加 JSON 校验提示） |
| `provider` | `select` | deepseek / anthropic / openai 等 |
| 未知字段 | `input` (text) | 回退——保留通用性 |

---

## 4. 测试覆盖缺口

### 4.1 现有测试（5 个文件，1129 行）

| 测试文件 | 行数 | 类型 | 覆盖 |
|---|---|---|---|
| `agent_config_dispatch_test.exs` | 302 | **dispatch seam** | 配置 update/delete/repoint 的后端逻辑 |
| `agent_config_state_test.exs` | 176 | **数据层** | `AgentConfig` facade 的 state 构建 |
| `agent_create_appears_in_list_test.exs` | 125 | **数据层** | `IdentityData.list_entities/2` 读取验证 |
| `agent_delete_dispatch_test.exs` | 296 | **dispatch seam** | 删除的 session-binding 检查 |
| `agent_detail_live_status_test.exs` | 149 | **数据层** | 详情页 Phase 字段回归 |
| `identity_data_test.exs` | 81 | **数据层** | `IdentityData` 基本功能 |

### 4.2 缺失：挂路由的 LiveViewTest

**当前所有测试都直接在数据层/dispatch seam 层调函数，零个通过 LiveView socket 走完整路由**。

| 测试场景 | 路由 | 验证点 |
|---|---|---|
| 列表渲染 | `GET /identities/agents` | LiveView mount → state 含 agents 列表 |
| 创建流程 | `GET /identities/agents/new` → POST | 填表 → submit → redirect → agent 出现在列表 |
| 详情渲染 | `GET /identities/agents/:uri` | LiveView mount → state 含所有已接线字段 |
| 配置编辑 | `GET /identities/agents/:uri/config` → 编辑 → 保存 | 改字段 → Save → re-read → 验证持久化 |
| 配置字段删除 | 同上 → 删字段 | 删字段 → re-read → 字段消失 |
| 删除确认 | `GET /identities/agents/:uri` → 删除 | 确认 → redirect → agent 不在列表 |

---

## 5. autoservice-dev-v3 参考方案（不合并，可移植）

> ⚠️ 本节标注的所有能力均来自分支 `autoservice-dev-v3`（`0b6eeaec`）。
> 该分支**不会合并**到 main。实现时**参考代码逻辑、移植需要的部分**。
> 每个移植项明确标注依赖和范围。

### 5.1 autoservice-dev-v3 的 Agent Config 四层模型

```
Layer 1 (Content):  soul | slots | skills | kb
Layer 2 (Worker):   flavor | provider | model | endpoint
Layer 3 (Registry): agent 定义 (YAML) → create/delete/list + template 预设
Layer 4 (Runtime):  Workspace.create_agent + CustomerSession.provision
```

### 5.2 可参考移植的模块

#### A. SkillStore + PlatformSkillStore（技能 CRUD）

> **依赖**: `ezagent_plugin_content` 不存在于当前 main（main 的 content plugin 只有 `priv/` 骨架，无 `.ex` 代码）
> **范围**: 移植到 main 的 `apps/ezagent_plugin_content/` 下
> **需要新增的文件**:
> - `lib/ezagent_plugin_content/skill/skill_store.ex` — 读取 SKILL.md 文件（4 层 fallback：tenant → industry → platform → framework）
> - `lib/ezagent_plugin_content/skill/skill_loader.ex` — 按 layer 列出 skill 目录
> - `lib/ezagent_plugin_content/skill/skill_indexer.ex` — 生成 skill index markdown
> - `lib/ezagent_plugin_content/platform/platform_skill_store.ex` — 读写 `priv/platform/skills/` 模板

**参考代码**（autoservice-dev-v3 `apps/ezagent_plugin_content/lib/ezagent_plugin_content/skill/skill_store.ex`）:

```elixir
# 核心 API（可直接移植）
@spec read(base_dir, tid, role, name) :: {:ok, binary()} | :not_found
@spec write(base_dir, tid, role, name, content) :: :ok
@spec delete(base_dir, tid, role, name) :: :ok | {:error, :not_found}
```

#### B. SoulStore + SoulRenderer（Soul 模板 + 插槽渲染）

> **依赖**: skill 模块同上
> **范围**: 同上
> **需要新增的文件**:
> - `lib/ezagent_plugin_content/soul/soul_store.ex` — YAML slot_values CRUD（sandbox/release 双路径）
> - `lib/ezagent_plugin_content/soul/soul_renderer.ex` — `{{key}}` 模板渲染引擎
> - `lib/ezagent_plugin_content/soul/soul_loader.ex` — 从 `priv/platform/` 加载 soul 模板
> - `lib/ezagent_plugin_content/soul/soul_slot_parser.ex` — 从模板中提取所有 `{{key}}` 占位符

**核心 API**:

```elixir
# SoulStore
@spec read_slots(base_dir, tid, role, :sandbox | :release) :: {:ok, map()} | {:error, term()}
@spec write_slots(base_dir, tid, role, values, :sandbox | :release) :: :ok | {:error, term()}
@spec defaults(tid, role) :: map()

# SoulRenderer
@spec render([binary()], map()) :: binary()           # 模板 + slot_values → 渲染文本
@spec full_claude_md([binary()], map(), binary()) :: binary()  # preamble + soul + skill_index
```

#### C. KbStore（知识库 CRUD）

> **依赖**: Python MCP script `kb_search_mcp.py`（SQLite + embedding search）
> **范围**: 同上
> **需要新增的文件**:
> - `lib/ezagent_plugin_content/kb/kb_store.ex` — SQLite-backed search/upsert/delete/fetch_url
> - `lib/ezagent_plugin_content/kb/kb_rebuilder.ex` — 重建 KB 索引
> - `lib/ezagent_plugin_content/kb/kb_mcp_provider.ex` — 为 cc agent 生成 MCP server 配置
> - `lib/ezagent_plugin_content/kb/source_tracker.ex` — 追踪 KB 条目来源（URL/手动）

**核心 API**:

```elixir
@spec search(kb_dir, query) :: [map()]       # 语义搜索
@spec upsert(kb_dir, entry) :: :ok | {:error, term()}  # 创建/更新条目
@spec delete(kb_dir, id) :: :ok              # 删除条目
@spec fetch_url(kb_dir, url, opts) :: :ok | {:error, term()}  # 从 URL 抓取内容
```

#### D. ContentAdmin Behavior（dispatch 端点）

> **依赖**: A + B + C 的 store 模块
> **范围**: 同上
> **需要新增的文件**:
> - `lib/ezagent_plugin_content/behavior/content_admin.ex`

**已定义的 action**:

```elixir
action(:write_soul_slot,       args: %{role, key, value},  caps: [:write_soul_slot])
action(:write_skill,           args: %{role, name, content}, caps: [:write_skill])
action(:delete_skill,          args: %{role, name},         caps: [:write_skill])
action(:upsert_kb,             args: %{entry: map},        caps: [:write_kb])
action(:delete_kb,             args: %{id: string},        caps: [:write_kb])
action(:publish_cr,            args: %{},                  caps: [:publish_cr])
action(:preview_sandbox,       args: %{role: string},      caps: [:preview_sandbox])
action(:write_agents_yaml,     args: %{content: string},   caps: [:write_agents_yaml])
action(:create_agent_skeleton, args: %{name, template},    caps: [:create_agent_skeleton])
```

#### E. TenantRuntime（租户路径管理）

> **依赖**: 无外部依赖，纯路径计算
> **需要新增的文件**:
> - `lib/ezagent_plugin_content/tenant/tenant_runtime.ex`
> - `lib/ezagent_plugin_content/tenant/tenant_config.ex`
> - `lib/ezagent_plugin_content/tenant/tenant_provisioner.ex`

**核心 API**:

```elixir
@spec sandbox_path(tid) :: String.t()   # → "<base>/<tid>/sandbox"
@spec release_path(tid) :: String.t()   # → "<base>/<tid>/release/_current"
@spec ensure_sandbox(tid) :: :ok | {:error, term()}
@spec promote(tid) :: :ok | {:error, term()}
```

#### F. AgentConfig YAML 模型（agent 定义注册）

> **依赖**: `apps/ezagent_plugin_autoservice` 不在 main（整个插件需新增）
> **参考文件**: `autoservice-dev-v3` 的 `ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/agent_config.ex`
> **注意**: 这个模型有 autoservice 特有概念（fast/slow/loom templates），移植时需要简化

**核心 API**（通用化后）:

```elixir
@type agent_def :: %{
  name: String.t(),
  sections: [:soul | :slots | :skills | :kb],
  worker: %{flavor: String.t(), provider: String.t(), model: String.t(), endpoint: String.t()}
}

@spec list(tid) :: [agent_def()]
@spec get(tid, name) :: {:ok, agent_def()} | {:error, :not_found}
@spec create(tid, name, template) :: {:ok, map()} | {:error, term()}
@spec delete(tid, name) :: {:ok, map()} | {:error, term()}
```

### 5.3 移植优先级评估

| 优先级 | 模块 | 理由 | 阻塞条件 |
|---|---|---|---|
| **P0（今天）** | Config 面板结构化编辑 | 纯前端，后端 contract 不变 | 无 |
| **P0（今天）** | 详情页展示已有数据 | 后端 ~30 行 + 前端 ~50 行 | 无 |
| **P0（今天）** | 标"还没接线" | 纯前端 | 无 |
| **P1（本任务可做）** | SkillStore + SoulStore + TenantRuntime | 为 agent console 提供 skills/soul 管理能力 | 需要移植 content plugin 代码（~6 个文件） |
| **P1（本任务可做）** | ContentAdmin Behavior | 让 skills/soul 操作走 dispatch（CapBAC + audit） | 依赖 SkillStore/SoulStore 先移植 |
| **P2（后续）** | KbStore | KB 需要 Python MCP script（`kb_search_mcp.py`） | 依赖 P1 基础设施 + Python 依赖 |
| **P2（后续）** | AgentConfig YAML 模型 | agent 定义注册（sections/worker 结构） | 需要先确定简化版模型，去掉 autoservice 特定概念 |
| **Deferred** | fork (parent template) | `Behavior.Template.:fork` action 存在，缺 UI | — |

---

## 6. Skill / KB 设计讨论（后续，不在本任务范围）

> 本节记录讨论结论，供后续实施参考。当前不在 agent console 任务（Step 1-5）范围内。

### 6.1 当前 ezagent 已有的 Skill 机制

ezagent 已有三层 skill 架构，只是目前仅用于 orchestrator role：

```
Layer 1: Role 模型 (ezagent_core)
  %Role{skills: ["ref1", "ref2"], plugins: [], prompt: ...}
  → 这是 flavor-agnostic 的"agent 角色配方"

Layer 2: Bootstrap (ezagent_plugin_cc)
  resolve_skill_source("ref") → 从 priv/ 向上搜索 .claude/skills/<ref>/SKILL.md
  install_role_sandbox → copy 到 config_dir/.claude/skills/<ref>/
  → 在 agent 创建时运行（bootstrap-time injection）

Layer 3: Claude Code 原生加载
  Claude 读取 CLAUDE_CONFIG_DIR → 发现 .claude/skills/ → 自动加载
  → ezagent 不介入运行时
```

**关键设计**：ezagent 只负责"在正确的时间把正确的文件放到正确的位置"。Claude Code 自己发现并加载。不是运行时动态加载——是 **创建时一次性注入**。

### 6.2 当前缺失

- **Skill 编辑**：domain 层已有 `Ezagent.Role` 结构体（`skills`/`plugins`/`prompt`/`behaviors`/`requested_caps`）和 `AgentTemplate.desired_skills`/`desired_caps`，但 Role 目前是代码写死的（`OrchestratorRole.compose()`），operator 不能通过 console 编辑 role 或上传 skill 文件
- **KB 完全不存在**：没有 KB store、没有 KB MCP provider、没有 KB Role 字段
- **Role 持久化**：Role 没有 DB 存储，没有 Template URI（当前是代码内联的 `@skill_ref`）

### 6.3 KB 设计方向：作为独立 Plugin

```
ezagent_plugin_kb (新 plugin)
├── KbStore（存储层，plugin 自决：SQLite/DB/外部向量DB）
├── Behavior.KbAdmin
│   ├── action(:search_kb, ...)   → CapBAC gating
│   ├── action(:upsert_kb, ...)   → 通过 dispatch → audit
│   └── action(:delete_kb, ...)
├── KbMcpProvider
│   └── 生成 .mcp.json 片段，注入到 agent 的 MCP config
│       { "kb-search": { "command": "uv", "args": [...], "env": {...} } }
└── KbBootstrap（扩展 OrchestratorBootstrap）
    └── install_role_sandbox 读取 sandbox_content.kb → 生成 MCP config → 合并
```

**Role 模型扩展**（core 层，~5 行）：

```elixir
defstruct skills: [], plugins: [], kb: nil, prompt: nil, ...
```

**和 autoservice-dev-v3 的关键差异**：

| 维度 | ezagent 设计 | autoservice-dev-v3 |
|---|---|---|
| Skill 来源 | Role 声明 ref → plugin priv/ 搜索 → copy | YAML agents.yaml → sections: [:skills] → platform/ 读取 |
| Skill 加载时机 | 创建时 bootstrap（一次性 copy） | 启动时 symlink（sandbox 改了自动生效） |
| Skill 编辑 | 不可运行时改（改 Role → 重建 agent） | 运行时改文件 → publish_cr → 重启生效 |
| KB 存储 | Plugin 自决 | 固定：文件系统 SQLite `kb.db` |
| KB 加载 | Role → bootstrap → MCP config → claude 调 MCP | symlink kb.db → Python MCP script 直读 |
| 存储模型 | ezagent DB（不可变 + pointer）或 plugin 自决 | 裸文件系统 I/O |
| UI 层 | React world:state JSON | 旧 Phoenix LiveView |

### 6.4 对 agent console 任务的影响

**今天不需要等 KB plugin**。详情页标"还没接线"即可。后续做 KB 时的实施顺序：

1. **移植 KB 存储**：可借鉴 autoservice 的 SQLite + Python MCP script（这部分适合搬——它不依赖 ezagent 架构）
2. **扩展 Role 模型**：加 `kb` 字段
3. **加 KbAdmin Behavior**：dispatch → CapBAC + audit
4. **扩展 Bootstrap**：在 `install_role_sandbox` 中处理 `kb` ref → 生成 MCP config
5. **前端加 KB 管理面板**：通过 world:state JSON 对接

---

## 7. 实施计划（按优先级，分里程碑）

### 前置认知：各 Flavor 字段不同（以 `template_data_extra/1` 为权威源）

在进入计划之前，必须明确：**不同 flavor 的 agent 有完全不同的配置字段**。不能假设"所有 agent 都有 model/effort/permission_mode"。

真实字段来源是各 Template Class 的 `template_data_extra/1` + `AgentTemplate.to_template_data/2` 的通用键（`class`、`agent_uri`、`cwd`、`config_dir`、`desired_skills`、`desired_caps`）。以下是各 flavor **额外**字段的概况（非完整清单）：

| Flavor | 额外字段（来自 `template_data_extra/1`） |
|---|---|
| **cc / cc-headless** | `model`, `effort`, `permission_mode`, `allowed_tools`, `disallowed_tools`, `mcp_servers`, `system_prompt`, `operator_settings_path`, `operator_mcp_config_path`, `api_key_helper`, `role`, `credential_source`。cc-headless 额外有 SDK 运行时参数：`claude_session_id`, `claude_cli_path`, `uv_path`, `python_path`, `sdk_worker_path` |
| **codex / codex-remote** | `model`, `approval_policy`, `sandbox`, `bridge_ws_url`, `codex_path` |
| **curl** | `provider`, `api_url`, `model`, `system_prompt`, `max_history` |
| **echo** | 无额外字段 |

**结论**：前端不能硬编码字段列表。M1 按已知字段 case/when 解出实际存在的字段，M2 后通过 `config_schema/0` 自动发现。

---

### 里程碑总览

```
M1 ─── 详情页完整化（纯展示，无编辑）
  │    详情页 6→按 flavor 展示全部字段 + LiveView 测试 + 精准标注
  │    改动：后端 ~30行 + 前端 ~60行 + 测试 ~150行
  │    契约变化：world:state 新增 config_fields 字段
  │
  ▼  ← 阻塞点：需要决定 Flavor Config Schema 的声明方式
  │
M2 ─── Flavor Config Schema 声明
  │    每个 Template Class 声明自己能接受哪些配置字段 + 字段类型/选项
  │    改动：后端 ~50行（Template Class × 4）
  │    契约变化：world:state 新增 config_schema 字段
  │
  ▼
M3 ─── Config 面板结构化编辑
  │    前端按 schema 选择 widget，不再是通用 kv
  │    改动：前端 ~80行
  │    契约变化：无（M2 已提供了 schema）
  │
  ▼
M4 ─── 创建表单增强
  │    新建 agent 时可设 flavor 特有字段（model/effort 等）
  │    改动：前端 ~60行 + 后端 ~20行
```

---

### M1：详情页完整化 + 回归保护（今天能做，不依赖设计决策）

**目标**：详情页从 6 个通用字段 → 按 flavor 展示所有已有数据

#### 范围

| 层 | 文件 | 改什么 | 行数 |
|---|---|---|---|
| **后端** | `identity_data.ex` | `component_state(:agent_detail)` 中从 `respawn_template_data` 解出 flavor 所有字段；从 config cascade 读 `soul_md`；以统一 shape 放入 state | ~30 |
| **前端** | `Identities.tsx:AgentDetail` | 遍历 `config_fields` 逐行展示；`ContractCoverage` 改为精准标注 | ~60 |
| **测试** | `agent_console_live_test.exs`（新） | 3 个 LiveView 路由测试：列表渲染、详情渲染、配置编辑 | ~150 |
| **截图** | `evidence/` | agent-browser 截图 | — |

#### 契约变化

当前 `world:state` 详情页字段（§2.2）加上：

```typescript
// 新增：按 flavor 展示的配置字段（只读展示）
config_fields: Array<{
  key: string,          // "model" | "effort" | "permission_mode" | ...
  value: string | null, // "deepseek-v4-pro" | "high" | null
  source: "template" | "cascade" | "runtime"  // 数据来源
}>
```

后端逻辑（伪代码，M1 临时用 case/when，M2 切换到 `config_schema/0`）：

```elixir
# identity_data.ex — M1 版本（M2 后改为读 config_schema/0 解字段）
defp config_fields_for(agent_uri, flavor, sandbox_state) do
  respawn = sandbox_state |> Map.get(:respawn_template_data, %{})
  
  # M1: 临时 case/when，每个 flavor 已知字段
  # M2: 改为通过 AgentFlavorRegistry → template_class.config_schema() 自动发现
  template_fields = case flavor do
    f when f in ["cc", "cc-headless"] ->
      ~w(model effort permission_mode allowed_tools disallowed_tools mcp_servers system_prompt)
    f when f in ["codex", "codex-remote"] ->
      ~w(model approval_policy sandbox)
    "curl" ->
      ~w(model provider api_url)
    _ -> []
  end
  
  # 从 config cascade 读 soul_md
  soul = case AgentConfig.read_key(uri, "advisor.behavior", caller, caps) do
    {:ok, %{effective_body: %{"soul_md" => md}}} -> [%{key: "soul_md", value: md, source: "cascade"}]
    _ -> []
  end
  
  template_fields |> Enum.map(fn key ->
    %{key: key, value: Map.get(respawn, key), source: "template"}
  end) ++ soul
end
```

#### 前端展示

```tsx
// AgentDetail 中新增，遍历 config_fields 而不是硬编码字段名
{state.config_fields?.map(field => (
  <div key={field.key}>
    <dt>{field.key}</dt>
    <dd>
      {field.value ?? <span className="text-muted-foreground text-xs">还没接线</span>}
    </dd>
  </div>
))}

// 真正没有数据的标注（不在 config_fields 里的）
{!hasField("skills") && <NotWired label="skills" reason="需 Role 模型 + skill store" />}
{!hasField("tools")  && <NotWired label="tools"  reason="需 tool registry" />}
{!hasField("kb")     && <NotWired label="KB"     reason="需 ezagent_plugin_kb" />}
{!hasField("lifecycle_detail") && <NotWired label="lifecycle 详情" reason="Domain.Agent 仅返回 phase+flavor" />}
{!hasField("settings_mgmt")    && <NotWired label="settings 管理" reason="需 settings store" />}
{!hasField("fork")   && <Deferred label="fork" />}
```

#### 优先顺序

| 顺序 | 项 | 依赖 |
|---|---|---|
| 1 | LiveView 测试 3 个场景 | 无（先写，确保后续有安全网） |
| 2 | 后端 `identity_data.ex` 解字段 | 无 |
| 3 | 前端 `AgentDetail` 展示 + 标注 | 依赖 2（需要 state 里有 `config_fields`） |
| 4 | agent-browser 截图 | 依赖 1-3 |

---

### M2：Flavor Config Schema 声明（~82 行，6 文件）

**目标**：后端能告诉前端"每个 flavor 有哪些可配置字段、每个字段是什么类型、枚举选项是什么"

#### 设计决策（已定，经 codex review 确认）

**最终方案：Option A（`@callback config_schema/0` 在 `Kind.Template`）+ Option C（shape 在 core，data 在 plugin）**

核心澄清：**变的是 data，不是 shape**。

| 层 | 内容 | 位置 | 变化频率 |
|---|---|---|---|
| **Shape** | `config_field` 类型定义（`key`、`type`、`options`、`editable`、`source`） | core `kind/template.ex` | **极低**——只在加新字段类型时变 |
| **Data** | model 列表、effort 级别、permission_mode 值 | plugin Template Class | **高**——每次出新 model 就变 |

**为什么是 `Kind.Template` 而不是 `agent_flavor_decl`**（codex 分析要点）：

> `agent_flavor_decl` 保存的是**布线引用**（`template_class` 是 module atom、`bridge_adapter` 是 module atom），不是 **UI schema**。把嵌套数组结构塞进 ETS 行，违反 declaration / wiring / UI 的分离。Template Class 已经是 flavor 的配置知识权威——`template_data_extra/1` 返回字段、`validate/1` 校验字段、`sdk_sidecar_params/2` 消费字段。`config_schema/0` 只是把这份知识声明式写出来。

**enum 选项的数据来源完全自由**：Template Class 可以硬编码、从 `priv/config/` YAML 读取、或用 `Application.get_env`——core 不关心。

#### Core 改动

**一个文件**：`apps/ezagent_core/lib/ezagent/kind/template.ex`（+~20 行）

```elixir
# 新增 type 定义（一次性，后续改 data 不动 core）
@type config_field_type :: :string | :enum | :list | :json | :text | :boolean

@type config_field :: %{
  required(:key) => String.t(),
  required(:type) => config_field_type(),
  optional(:options) => [String.t()],
  optional(:editable) => boolean(),
  optional(:source) => :template | :cascade
}

# 新增 optional callback
@callback config_schema() :: [config_field()]
```

`@optional_callbacks` 中加 `config_schema: 0`。

#### Plugin 改动（每个 Template Class ~15-18 行）

cc（model 列表通过 `Application.get_env` 可覆盖）：

```elixir
# cc_agent.ex
@default_models ["deepseek-chat", "deepseek-v4-pro", "deepseek-v4-flash",
                 "claude-sonnet-4-6", "claude-opus-4-8"]

@impl true
def config_schema do
  models = Application.get_env(:ezagent_plugin_cc, :models, @default_models)
  [
    %{key: "model",            type: :enum, options: models,                    source: :template, editable: false},
    %{key: "effort",           type: :enum, options: ["low","medium","high","xhigh","max"], source: :template, editable: false},
    %{key: "permission_mode",  type: :enum, options: ["default","acceptEdits","plan","bypass"], source: :template, editable: false},
    %{key: "system_prompt",    type: :text,                                     source: :template, editable: false},
    %{key: "allowed_tools",    type: :list,                                     source: :template, editable: false},
    %{key: "disallowed_tools", type: :list,                                     source: :template, editable: false},
    %{key: "mcp_servers",      type: :json,                                     source: :template, editable: false},
    %{key: "soul_md",          type: :text,                                     source: :cascade, editable: true},
  ]
end
```

codex：

```elixir
# codex_agent.ex
def config_schema do
  [
    %{key: "model",           type: :enum, options: ["codex-default"],                source: :template, editable: false},
    %{key: "approval_policy", type: :enum, options: ["never","on-request","always"],  source: :template, editable: false},
    %{key: "sandbox",         type: :enum, options: ["enabled","disabled"],           source: :template, editable: false},
    %{key: "soul_md",         type: :text,                                            source: :cascade, editable: true},
  ]
end
```

curl：

```elixir
# curl_agent.ex
def config_schema do
  [
    %{key: "model",    type: :enum,   options: ["deepseek-chat","deepseek-v4-pro"], source: :template, editable: false},
    %{key: "provider", type: :enum,   options: ["deepseek","openai","anthropic"],    source: :template, editable: false},
    %{key: "api_url",  type: :string,                                               source: :template, editable: false},
  ]
end
```

echo：不实现 → 默认返回 `nil`（`@optional_callback` 自动处理）。

#### 发现路径

```
identity_data.ex
  → AgentFlavorRegistry.list_all()
  → [{flavor, %{template_class: tc}, ...]
  → tc.config_schema()  （不实现则为 nil/[]）
  → 放入 world:state
```

**不改** `AgentFlavorRegistry`。发现路径通过已有的 `template_class` 字段隐式完成。

#### 改动清单

| 文件 | 改动 | 行数 |
|---|---|---|
| `kind/template.ex`（core） | 加 `@type config_field` + `@callback config_schema()` + `@optional_callbacks` | +20 |
| `cc_agent.ex` | `def config_schema` → 8 个字段 + env override | +18 |
| `cc_headless_agent.ex` | `def config_schema` → 同 cc | +18 |
| `codex_agent.ex` | `def config_schema` → 4 个字段 | +8 |
| `codex_remote_agent.ex` | `def config_schema` → 同 codex | +8 |
| `identity_data.ex` | `state_for` 中读 schema 放入 world:state | +10 |
| **总计** | | **~82 行** |

#### 契约变化

`world:state` 新增 `config_schema`（在详情页和 config 页都下发）：

```typescript
config_schema: Array<{
  key: string,              // "model" | "effort" | "soul_md" | ...
  type: "string" | "enum" | "list" | "json" | "text" | "boolean",
  options?: string[],       // enum 类型的可选值
  editable: boolean,        // 是否可运行时编辑
  source: "template" | "cascade",
}>
```

#### 消费路径

```
Template Class.config_schema/0
  → identity_data.ex: AgentFlavorRegistry.list_all → tc.config_schema()
  → 放入 world:state JSON
  → M1: React 读 config_schema 遍历展示
  → M3: React 按 config_schema.type 选择 widget
  → M4: React 按 config_schema 动态渲染创建表单
```
### M3：Config 面板结构化编辑（依赖 M2）

**目标**：Config Cascade 的字段不再是通用 kv Input，而是按 schema 选 widget

#### 范围

| 层 | 文件 | 改什么 |
|---|---|---|
| **前端** | `Identities.tsx:AgentConfigKeySection` | 按 `config_schema` 的 `type` 选择 widget：`enum`→`<select>`，`text`→`<textarea>`，`list`→tag-editor，`json`→json-textarea，`string`→`<Input>`（回退） |

#### 契约变化

**无**——`config_schema` 已在 M2 下发，M3 只是前端消费。

---

### M4：创建表单增强（依赖 M2 的 schema）

**目标**：新建 agent 时，除了 flavor/name/cwd，还能设 flavor 特有字段

#### 范围

| 层 | 文件 | 改什么 |
|---|---|---|
| **后端** | `agent_create.ex` / `agent_actions.ex` | `create_agent` 接受额外字段（model/effort 等），传入 template instantiate |
| **前端** | `Identities.tsx:AgentNewForm` | 选 flavor 后，动态展示该 flavor 的额外配置字段（从 `config_schema` 读取） |

---

### 不在本任务范围

| 项 | 原因 |
|---|---|
| Skill/Soul/KB 存储 | 需要先确定存储方案（DB vs 文件）+ Role 模型扩展（见 §6） |
| Template Data 运行时编辑 | 需要改 template + respawn agent 流程 |
| fork | `Behavior.Template.:fork` action 已存在，缺 UI 触发入口 |

---

## 8. 关键文件

| 关注点 | 文件 |
|---|---|
| React UI | `apps/ezagent_plugin_world/assets/src/components/Identities.tsx`（945 行） |
| 路由定义 | `apps/ezagent_plugin_world/lib/ezagent/world/routes.ex`（281 行） |
| 数据构建 | `apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex`（692 行） |
| 事件处理 | `apps/ezagent_plugin_world/lib/ezagent/world/agent_actions.ex`（381 行） |
| LiveView shell | `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`（856 行） |
| AgentConfig facade | `apps/ezagent_domain_identity/lib/ezagent/agent_config.ex` |
| ConfigEvolve behavior | `apps/ezagent_domain_identity/lib/ezagent/behavior/config_evolve.ex` |
| ConfigProjection | `apps/ezagent_domain_identity/lib/ezagent/socialware/config_projection.ex` |
| Domain.Agent facade | `apps/ezagent_domain_session/lib/ezagent/domain/agent.ex`（162 行） |
| 现有测试 | `apps/ezagent_plugin_world/test/ezagent/world/agent_*_test.exs`（5 文件） |
| LV parity gate | `apps/ezagent_plugin_world/test/ezagent/world/lv_parity_test.exs` |
| **autoservice SkillStore 参考** | `origin/autoservice-dev-v3:apps/ezagent_plugin_content/lib/ezagent_plugin_content/skill/skill_store.ex` |
| **autoservice SoulStore 参考** | `origin/autoservice-dev-v3:apps/ezagent_plugin_content/lib/ezagent_plugin_content/soul/soul_store.ex` |
| **autoservice KbStore 参考** | `origin/autoservice-dev-v3:apps/ezagent_plugin_content/lib/ezagent_plugin_content/kb/kb_store.ex` |
| **autoservice ContentAdmin 参考** | `origin/autoservice-dev-v3:apps/ezagent_plugin_content/lib/ezagent_plugin_content/behavior/content_admin.ex` |
| **autoservice AgentConfig 参考** | `origin/autoservice-dev-v3:apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/agent_config.ex` |

---

## 9. 依赖与风险

- **依赖**：无外部阻塞。echo 接入（#918）未完成不算缺（lead 裁定）。
- **风险**：autoservice-dev-v3 的 content plugin 代码（SkillStore/SoulStore/KbStore）移植到 main 时需要适配——autoservice 用的是 tenant→workspace→sandbox 模型，main 的 agent console 可能需要简化的路径约定。
- **world-coordination**：console 由我单一所有，无冲突面。`Identities.tsx` 是唯一修改的 React 文件。
