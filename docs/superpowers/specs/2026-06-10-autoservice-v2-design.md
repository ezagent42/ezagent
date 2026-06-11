# AutoService v2 on ezagent — 完整架构设计

> 状态: **设计稿 v2** | 日期: 2026-06-11
> 基线: ezagent `autoservice` = `main` HEAD (`0a094410`) + 设计文档，core/domain 零差异
> 旧 Phase 1-4 代码已归档: `archive/autoservice-phase1-4` (tag)
> socialware P3 (#716 render_soul, #727 CustomerFeed :pull, #728 PublisherRead) 已纳入
> 目标: 一个完整可用的多租户客服 vertical,纯 plugin 实现,core/domain 零改动

---

## 目录

1. [总体架构](#1-总体架构)
2. [Plugin 拆分设计](#2-plugin-拆分设计)
3. [数据架构: Soul / Skill / KB](#3-数据架构)
4. [用户管理与权限模型](#4-用户管理)
5. [CR 发布流](#5-cr-发布流)
6. [Customer 路径: loom + Turn + CustomerFeed](#6-customer-路径)
7. [Operator 接管](#7-operator-接管)
8. [Admin 界面](#8-admin-界面)
9. [租户生命周期](#9-租户生命周期)
10. [实施计划](#10-实施计划)

---

## 1. 总体架构

### 1.1 三层角色

```
Customer  → ezagent_plugin_autoservice (customer_live.ex, 后用 loom SPA)
            - 编排: TurnAdapter (autoservice) — fast(deepseek) + slow(cc) agent
            - Turn 状态机接入 (socialware Turn Behavior)
            - CustomerFeed 门控订阅 (socialware CustomerFeed.topic)

Operator  → ezagent_plugin_autoservice
            - OperatorLive: 客服工作台
            - Turn.claim → 编辑 → settle 接管流程

Admin     → ezagent_plugin_liveview
            - Master Admin: 全平台管控
            - Tenant Admin: 单租户管理
```

### 1.2 Plugin 架构图

```
┌─────────────────────────────────────────────────────────────┐
│                   ezagent_plugin_loom                        │
│  Customer 前端 (Next.js SPA)                                 │
│  deepseek.ex (fast) / claude_code.ex (slow) / knowledge.ex  │
│  filler_loop.ex                                              │
└──────────────────────────┬──────────────────────────────────┘
                           │ Turn.open/compose/settle
                           │ CustomerFeed.subscribe
┌──────────────────────────▼──────────────────────────────────┐
│               ezagent_plugin_autoservice (容器外壳)           │
│  autoservice_assembly.ex  — 组装协调                         │
│  customer_session.ex      — session 创建(代理到 content)     │
│  operator_live.ex         — 客服工作台 + Turn.claim/settle   │
│  turn_adapter.ex          — Turn 编排(给 loom 调)            │
│  roles.ex, uris.ex, chat_ui.ex                              │
└──┬────────────┬──────────────┬──────────────┬───────────────┘
   │            │              │              │
   ▼            ▼              ▼              ▼
┌───────┐ ┌───────┐ ┌──────────┐ ┌────────────────────────┐
│content│ │  cr   │ │liveview  │ │   ezagent_domain_*     │
│plugin │ │plugin │ │ plugin   │ │   (不动,复用)           │
│(新)   │ │(新)   │ │(扩展)    │ │                        │
└───────┘ └───────┘ └──────────┘ │ socialware:            │
   │            │              │  │   Turn, CustomerFeed,  │
   ▼            ▼              ▼  │   ConfigStore,         │
┌────────────────────────────────┐ │   ConfigProjection,   │
│   ezagent_domain_socialware    │ │   SocialwareSession,  │
│   Turn / CustomerFeed / ...    │ │   CustomerAuth        │
└────────────────────────────────┘ │                        │
                                   │ identity:              │
                                   │   WorkspaceUserAdmin,  │
                                   │   Identity, Users      │
                                   └────────────────────────┘
```

### 1.3 核心原则

```
core (ezagent_core)     — 零改动
domain (ezagent_domain_*) — 零改动,纯复用
plugin (ezagent_plugin_*) — 所有新功能
autoservice             — 精简为容器外壳,组装协调
```

---

## 2. Plugin 拆分设计

### 2.1 ezagent_plugin_content (新)

通用内容管理 — soul/skill/KB 的 CRUD、渲染、初始化。

**数据存储分层:**

```
priv/ (只读, OTP release 打包)          ~/.ezagent/<profile>/tenants/ (可变,运行时)
  platform/                                <tid>/
    framework/<role>/soul.md                 souls/<role>_soul.md         (租户自有的 soul 覆盖)
    platform/<role>.md                       skills/<role>/<name>/SKILL.md (租户自有的 skill)
    industry/<industry>/<role>/soul.md       kb/kb.db                     (可重建)
    templates/<role>/soul.md                 kb/glossary.json
    skills/<name>/SKILL.md                   kb/escalation_keywords.json
    industry/<industry>/skills/<name>/SKILL.md  kb/synonym-map.json
  skeleton/                                  kb/kb_search_mcp.py
    soul/soul.md                             kb/query_expansion.py
    skills/.gitkeep
    kb/.gitkeep
```

**核心原则:**
- `priv/` = 只读模板 + 平台级 soul/skill(master admin 编辑,走 git version)
- `~/.ezagent/<profile>/tenants/<tid>/` = 租户可变数据(tenant admin 编辑,不走 git,走 CR)
- 租户创建时从 skeleton 复制基线到运行时路径;后续 tenant admin 编辑直接写运行时路径
- ConfigStore 存储 slot_values、CR 状态等结构化配置(不存大文件)

```
apps/ezagent_plugin_content/
  mix.exs
  lib/
    ezagent_plugin_content.ex
    ezagent_plugin_content/application.ex

    # --- 平台层 (master admin 管控, 数据在 priv/platform/) ---
    platform/
      platform_soul_store.ex     — L0/L1/L2 soul 模板 CRUD
      platform_skill_store.ex    — Platform/Industry skill CRUD
      platform_kb_store.ex       — escalation_keywords 管理

    # --- 租户层 (tenant admin 管控, 数据在 ~/.ezagent/.../tenants/<tid>/) ---
    tenant/
      tenant_content.ex           — 统一入口: content_for(tenant_id, layer, role)
      tenant_provisioner.ex       — 从 skeleton 创建租户(复制 priv/ → 运行时路径)
      tenant_config.ex            — 租户配置(brand_name, channels 等,存 ConfigStore)
      tenant_runtime.ex           — 运行时路径管理(替换旧 CinnoxRuntime)

    # --- Soul ---
    soul/
      soul_loader.ex              — 4 层加载(tenant runtime > industry > platform > framework)
      soul_slot_parser.ex         — 解析 {{key}} 占位符,按 section 分组
      soul_renderer.ex            — {{slot}} 渲染 + CLAUDE.md 生成
      soul_store.ex               — 读写租户 slot_values(走 ConfigStore)

    # --- Skill ---
    skill/
      skill_loader.ex             — 4 层扫描(tenant runtime > industry > platform > framework)
      skill_indexer.ex            — 生成 Skill Index markdown
      skill_store.ex              — skill 文件 CRUD(tenant runtime 路径)

    # --- KB ---
    kb/
      kb_store.ex                 — KB 条目增删改查(tenant runtime 路径)
      kb_rebuilder.ex             — kb.db FTS5 重建(调 Python MCP script)
      kb_mcp_provider.ex          — MCP server 配置生成
      kb_curator_agent.ex         — KB 管理 cc agent

  priv/
    skeleton/                      — 新租户模板(只读,OTP release 打包)
      soul/soul.md
      skills/.gitkeep
      kb/.gitkeep
    platform/                      — 平台级模板(只读,master admin 编辑走 git)
      framework/<role>/soul.md
      platform/<role>.md
      industry/<industry>/<role>/soul.md
      templates/<role>/soul.md     (含 {{key}})
      skills/<name>/SKILL.md
      industry/<industry>/skills/<name>/SKILL.md
```

**模块对照(旧→新):**

| 旧模块 (autoservice) | 新模块 (content) |
|---|---|
| `CinnoxAssets.soul_path` | `soul_loader.load(tid, role)` — 4 层合并 |
| `CinnoxAssets.render_slots` | `soul_renderer.render(template, values)` |
| `CinnoxAssets.build_skill_index` | `skill_indexer.build(tid, role)` |
| `CinnoxAssets.default_soul_slot_values` | `soul_store.defaults(tid, role)` — 从 skeleton 模板解析 |
| `CinnoxAssets.build_cc_claude_md` | `soul_renderer.full_claude_md(tid, role, values)` |
| `CinnoxRuntime.materialize_cinnox_cc!` | `tenant_runtime.materialize(tid, role)` — 从 runtime 路径 symlink |
| `CinnoxRuntime.kb_mcp_servers` | `kb_mcp_provider.config(tid)` |
| `KbCuratorAgent` | `kb_curator_agent.ex` (迁移) |

### 2.2 ezagent_plugin_cr (新)

CR 驱动的发布流 — scope/lock/release/snapshot/rollback。

```
apps/ezagent_plugin_cr/
  mix.exs
  lib/
    ezagent_plugin_cr.ex
    ezagent_plugin_cr/application.ex
    ezagent_plugin_cr/
      cr_engine.ex               — CR 核心: 创建 / scope 管理 / lock / release
      cr_lint.ex                 — 引用检查 R01-R05
      cr_snapshot.ex             — sandbox → release 快照
      cr_rollback.ex             — 回滚到历史版本
```

**CR 数据模型(ConfigStore key: `cr:<tid>:<cr_id>`):**

```yaml
# ConfigStore key: cr:<tid>:<cr_id>
cr_id: "cr-20260610-001"
tenant_id: "cinnox"
status: open | approved | rejected | stale | published
target_kind: soul_slot | skill | kb | bundle
scope:
  - kind: soul_slot
    role: customer
    section_ids: [identity, brand-structure, gate]
  - kind: skill
    file: skills/customer/lead-collection/SKILL.md
scope_hash:
  "soul_slot:customer/identity": "sha256:abc123..."
  "skill:lead-collection": "sha256:def456..."
scope_locked_at: "2026-06-10T10:00:00Z"
scope_lock_ttl_hours: 24
created_by: "entity://user/cinnox/admin"
created_at: "2026-06-10T10:00:00Z"
published_at: null
published_version: null
```

**CR 生命周期:**

```
sandbox 编辑 → 自动 ensure_active_cr()
     ↓
CR scope 收集改动
     ↓
Admin 点 "Publish" → lint check
     ↓ (通过)
scope_hash 冻结 → promote 到 released/<tid>/v<N>/
     ↓
翻 _current 指针 → recycle agent pool
```

**4 层防漏:**

| Layer | 机制 | 触发时机 |
|---|---|---|
| L1 | Publish 按钮主动提示未发布依赖 | Publish 点击 |
| L2 | 引用 lint 硬挡(R01/R03/R04) + 软警告(R02/R05) | CR 提交 |
| L3 | Dashboard "悬挂改动" 视图 | 常驻 |
| L4 | Daily digest 通知 | cron 每日 |

### 2.3 ezagent_plugin_autoservice (精简)

精简为容器外壳,组装协调各 plugin。

```
apps/ezagent_plugin_autoservice/
  lib/
    ezagent_plugin_autoservice/
      application.ex              — OTP app + Plugin contract
      autoservice_assembly.ex     ← 新: 组装协调(唯一胶水模块)
      customer_session.ex         — 精简: 代理到 content plugin
      operator_live.ex            — 加 Turn.claim/settle
      turn_adapter.ex             ← 新: Turn 编排(loom 侧调)
      roles.ex                    — 扩展: 加 master_admin
      uris.ex                     — URI 推导
      chat_ui.ex                  — 共享 UI 组件
    mix/tasks/
      ezagent.tenant.seed.ex      — 重构: 通用租户 seed
```

**autoservice_assembly.ex 职责:**

```elixir
defmodule EzagentPluginAutoservice.AutserviceAssembly do
  @moduledoc """
  组装协调 — autoservice 唯一的胶水模块。

  不包含业务逻辑,只做 wiring:
  - provision_session → 调 content plugin 取 soul/skill/KB
  - create_agents → 调 workspace + cc plugin
  - install_routing → 调 routing registry
  - open_turn → 调 socialware Turn Behavior
  - preview_provision(tid, role, admin_uri) → 创建预览环境(数据源=sandbox)
  - preview_teardown(session_uri) → 销毁预览环境
  """
end
```

### 2.4 ezagent_plugin_liveview (扩展)

Admin UI — Master Admin 和 Tenant Admin 两个视角。

```
apps/ezagent_plugin_liveview/
  lib/ezagent_plugin_liveview/
    # === 已有,保留 ===
    soul_slot_editor_live.ex      — {{slot}} 表单编辑
    template_editor_live.ex       — AI 辅助模板编辑
    template_diff_live.ex         — 模板 diff + 合并
    bot_creator_live.ex           — Bot 创建
    users_live.ex                 — 用户管理(已有)
    workspaces_live.ex            — 工作区管理(已有)

    # === 新增: Master Admin 视角 ===
    master/
      master_dashboard_live.ex     — 全平台概览(租户数/CR数/版本)
      platform_content_live.ex     — 平台级 soul/skill 模板编辑
      tenant_onboard_live.ex       — 创建租户向导

    # === 新增: Tenant Admin 视角 ===
    tenant/
      tenant_dashboard_live.ex     — 租户概览(CR/版本/预览)
      skill_editor_live.ex         — Skill 浏览/编辑(4 层)
      kb_manager_live.ex           — KB 来源管理+条目编辑
      cr_dashboard_live.ex         — CR 列表/详情/发布
      operators_live.ex            — 管理本租户 operator
```

### 2.5 ezagent_plugin_loom (改动)

Customer 前端 — Next.js SPA 嵌入 + 编排。

```
apps/ezagent_plugin_loom/
  lib/
    deepseek.ex           — 改动: fast agent ACK 后 → Turn.open
    claude_code.ex        — 改动: cc 回复后 → Turn.compose → Turn.settle
    filler_loop.ex        ← 新: FillerLoop 协程
    LoomSessionView       — 改动: 订阅从 broadcast 改为 CustomerFeed
```

---

## 3. 数据架构

### 3.1 Soul / Skill / KB 三层模型

```
             Framework     Platform      Industry      Tenant
             ────────     ────────      ────────      ──────
Soul          有 ✅         有 ✅          有 ✅          {{slot}} 渲染
Skill         有 ✅         有 ✅          有 ✅          有 ✅
KB            无           escalation    glossary      产品知识
                          _keywords
```

### 3.2 Soul (inline ~30KB)

**始终在 cc system prompt 中** — 身份、安全约束、行为规则。

加载顺序(后覆盖前):
```
Framework  agents/<role>/soul.md            ← L0
    +
Platform   master/platform/<role>.md         ← L1
    +
Industry   master/<industry>/<role>/soul.md ← L2
    +
Tenant     {{slot}} 渲染                     ← L3 (template + slot_values)
```

**数据存储:**

| 层 | 存储位置 | 类型 | 可变 | 管理者 |
|---|---|---|---|---|
| L0 Framework | `content/priv/platform/framework/<role>/soul.md` | 文件 | 只读(git) | master admin |
| L1 Platform | `content/priv/platform/platform/<role>.md` | 文件 | 只读(git) | master admin |
| L2 Industry | `content/priv/platform/industry/<industry>/<role>/soul.md` | 文件 | 只读(git) | master admin |
| L3 Template | `content/priv/platform/templates/<role>/soul.md` (含 `{{key}}`) | 文件 | 只读(git) | master admin |
| L3 Tenant Soul | `~/.ezagent/<profile>/tenants/<tid>/sandbox/souls/<role>_soul.md` | 文件 | 可变 | tenant admin |
| L3 Slot Values | `~/.ezagent/<profile>/tenants/<tid>/sandbox/slots/<role>.yaml` | 文件(YAML) | 可变 | tenant admin |
| L3 Skill Index | 动态生成,注入 soul 末尾 | — | — | content plugin 自动 |

### 3.2.1 存储分层原则

```
Filesystem (runtime path)               ConfigStore (DB, body: :map)
  内容文件 + cc agent/MCP 直接读取         小型结构化配置 + 原子翻转
  ────────────────────────               ────────────────
  soul.md          (~30KB)               tenant config   (~500B)
  SKILL.md         (~5KB)                CR 元数据       (~2KB)
  slot_values.yaml (~5KB)  ← 沙箱/发布天然隔离
  kb.db            (binary)              
  kb_search_mcp.py (Python)
  glossary.json, synonym-map.json
  escalation_keywords.json
  fast_ack_prompt.md, cc_preamble.md, welcome.md
```

> **为什么 slot_values 走文件系统而非 ConfigStore:** ConfigStore 只有一个 pointer，
> 不支持 sandbox/release 双区。slot_values 放在 `sandbox/slots/<role>.yaml` 和
> `release/v<N>/slots/<role>.yaml` 下,通过 `_current` 符号链接区分。
> ConfigStore 仅用于 tenant config(静态) + CR 元数据(小 JSON,需原子翻转)。

### 3.2.2 Soul 渲染流程 (模板 + slot 分离)

**核心原则: 模板文件只含 `{{key}}` 占位符，不预填充。Agent 启动时实时渲染。**

```
Agent 启动 (cc agent provision):
  1. soul_loader:
     L0 framework soul.md (priv/)                         ─┐
     L1 platform soul.md  (priv/)                          │ 含 {{key}}
     L2 industry soul.md  (priv/)                          │ 占位符
     L3 template soul.md  (priv/platform/templates/)      ─┘
     L3 tenant override   (sandbox/souls/) (如有)         ─┐ 含 {{key}}
                                                           │ 或纯覆盖
  2. soul_store:
     取 slot_values ← 文件系统 当前 release              ─┐
       release/_current/slots/<role>.yaml                 │ YAML

  3. soul_renderer.render(templates, slot_values):
     {{identity.bot_full_name}} → "CINNOX AI Bot"        ─┘
     缺失的 key 保留 raw {{key}} 作为 "未配置" 信号

  4. skill_indexer.build(tid, role):
     扫描 sandbox/skills/ → 生成 Skill Index markdown

  5. 拼接完整 CLAUDE.md:
     preamble + 渲染后 soul + skill_index → agent work dir
     可选: 通过 `ConfigProjection.render_soul/1` (socialware #716) 输出 soul_md 分支
     ~/.ezagent/<profile>/tenants/<tid>/cc-agents/<role>-work/CLAUDE.md (临时产物)
```

> **slot_values 翻指针后新 agent 自动拿到新值，无需重写 soul 文件。**
> agent work dir 里的 CLAUDE.md 是渲染后的临时产物，每次 agent 启动重新生成。
> socialware #716 已支持 `render_soul` soul_md 分支，可复用。

### 3.2.3 Skill 文件格式 (含 {{slot}} 支持)

租户 skill 文件同样支持 `{{key}}` 占位符(可选)，渲染时机与 soul 相同。

```markdown
---
name: lead-collection-flow
description: Lead 收集流程
---
# Flow: Lead Collection for {{identity.brand_short_name}}

收集以下字段: ...
```

渲染后 cc agent Read 到的内容:
```markdown
# Flow: Lead Collection for CINNOX
收集以下字段: ...
```

**ConfigStore key (仅小型结构化配置):**

```
CR 元数据:
  cr:<tid>:<cr_id>                                — CR 状态/scope/lock

租户配置:
  tenant:<tid>:config                             — brand_name, channels
```

> ConfigStore 只存这两类(小 JSON,需原子翻转)。slot_values 走文件系统。

**文件系统 sandbox/release 双区 (所有内容数据):**

```
~/.ezagent/<profile>/tenants/<tid>/
  sandbox/                           — 编辑区,tenant admin 直接编辑
    slots/<role>.yaml                — slot_values (YAML)
    souls/<role>_soul.md
    skills/<role>/<name>/SKILL.md
    kb/kb.db
    kb/glossary.json, escalation_keywords.json, synonym-map.json
  release/
    v1/                               — 发布快照(不可变)
      slots/<role>.yaml
      souls/<role>_soul.md
      skills/<role>/<name>/SKILL.md
      kb/kb.db
      ...
    v2/
      ...
    _current -> v1                    — 符号链接,指向当前版本
```

**{{slot}} 模板语法:**

```markdown
## 1. IDENTITY
You ARE the {{identity.bot_full_name}}.
Stay in character from the very first message.
...
If asked "who are you?":
  "{{identity.self_intro_en}}"
  中文："{{identity.self_intro_zh}}"
```

**slot_values 存储(ConfigStore):**

```yaml
# key: slot_values:cinnox:customer
identity:
  bot_full_name: "CINNOX AI Bot"
  host_site_descriptor: "CINNOX/M800"
  domain_descriptor: "CINNOX products and services"
  self_intro_en: "Hi! I am CINNOX AI, your virtual assistant..."
  self_intro_zh: "您好，我是 CINNOX 的 AI 助手..."
brand-structure:
  parent_company: "M800 Limited"
  parent_hq: "Hong Kong"
  flagship_product: "CINNOX"
gate:
  escalation_phrase: "这个具体数字我得帮您核实一下..."
  escalation_triggers: "转人工, 找真人, 我要人工, 投诉"
classification:
  brand_short_name: "CINNOX"
  ...
```

### 3.3 Skill (on-disk, Read 按需加载)

**cc 通过 Read tool 按需加载的 .md 文件**。统一了旧的 `skill`、`flow_directive`、`references` 概念——全部是 flat .md 文件放在 `skills/<role>/<name>/SKILL.md` 下。

> 旧 design 中独立的 `flow_chunks/` 和 `references/` 目录已废弃，内容统一到 `skills/`。
```markdown
---
name: lead-collection-flow
description: Lead 收集 — 4 字段逐步询问
intent_trigger: purchase_intent
---

# Flow: Lead Collection
...
```

**4 层加载优先级(同名文件 — 后覆盖前):**

```
1. Framework:  content/priv/platform/skills/<name>/SKILL.md
2. Platform:   content/priv/platform/skills/<name>/SKILL.md
3. Industry:   content/priv/platform/industry/<industry>/skills/<name>/SKILL.md
4. Tenant:     ~/.ezagent/<profile>/tenants/<tid>/sandbox/skills/<role>/<name>/SKILL.md  ← 最高优先
```

> cc agent 通过 Read tool 读取 skill 文件。Skill Index 中写相对路径
> (如 `skills/customer/lead-collection-flow/SKILL.md`),
> agent work dir 下 `plugins/<tid>/skills/` → symlink → `sandbox/skills/`。详见 §6.5。

**Skill Index(注入 soul):**

```markdown
## Skill Index
需要时 Read 对应文件:
  - **Lead 收集流程** — `skills/customer/lead-collection-flow/SKILL.md`: Lead 收集 — 4 字段逐步询问
  - **Bug 报告路由** — `skills/customer/bug-routing-flow/SKILL.md`: Bug 报告路由
  - **Discovery 问题** — `skills/customer/discovery-questions/SKILL.md`: Discovery 问题
  ...
```

### 3.4 KB (queryable, MCP 查询)

**SQLite + FTS5 + `kb_search` MCP server**。

| 内容 | 存储 | 管理者 |
|---|---|---|
| product_knowledge | `kb.db` (SQLite FTS5) | tenant admin |
| glossary | `glossary.json` | tenant admin |
| synonym-map | `synonym-map.json` | tenant admin |
| escalation_keywords | `escalation_keywords.json` | tenant admin |
| source_friendly_names | `kb/source_friendly_names.yaml` | tenant admin |
| kb_sources (去重追踪) | `kb/_sources/_sources.yaml` | tenant admin |

> `_sources/` 记录 KB 内容来源(URL/文件路径→ingested_at→hash)，用于去重和友好名映射。
> MVP 阶段做最小设计：一个 yaml 文件存 `{source_id: {type, path, friendly_name, ingested_at, hash}}`。
> 完整 ingestion pipeline（URL 抓取、文件解析、定时更新）后续迭代。

**MCP 配置(per-agent, 参数化):**

```json
{
  "mcpServers": {
    "<tid>-kb": {
      "command": "uv",
      "args": ["run", "--script", "<sandbox_path>/kb/kb_search_mcp.py"],
      "env": {
        "KB_DB_PATH": "<sandbox_path>/kb/kb.db"
      }
    }
  }
}
```

> MCP server name 用 `<tid>-kb` (如 `cinnox-kb`),不硬编码。

### 3.5 Agent 配置 + Prompt 管理

**三层，租户可定制 prompt 但不可改 agent 环境:**

```
Agent 环境配置 (master only, 不进 CR):
  priv/skeleton/config/agents.yaml     — model, endpoint, max_tokens, thinking, effort
  部署环境变量                          — DEEPSEEK_API_KEY 等 secrets
  → 修改走 git PR + 部署,租户不可见

Prompt 模板 (skeleton 提供默认,租户可定制,走 CR):
  priv/skeleton/config/fast_ack_prompt.md    — 默认,创建租户时复制到 sandbox/config/
  priv/skeleton/config/cc_preamble.md        — 默认,创建租户时复制到 sandbox/config/
  → 租户可在 sandbox/config/ 编辑,C R publish 后生效

Tenant 内容配置 (租户编辑,走 CR):
  sandbox/config/fast_ack_prompt.md     — 租户定制 ACK prompt
  sandbox/config/cc_preamble.md         — 租户定制 cc preamble
  sandbox/config/welcome.md             — 欢迎语
  sandbox/slots/<role>.yaml             — slot_values
  sandbox/souls/<role>_soul.md          — soul 覆盖
  sandbox/skills/<role>/<name>/SKILL.md — skill(统一 flow_chunks + references)
  sandbox/kb/                           — kb.db, glossary, escalation
```

**Agent provision 数据流:**

```
  1. 读 agents.yaml(平台) → model, endpoint, max_tokens 等
  2. 读部署环境变量 → API key
  3. 读 release/_current/config/*.md(租户) → prompt 内容(已发布版本,如有)
     (admin preview agent 才读 sandbox/config/)
  4. 读 release/_current/slots/ + souls/ + skills/ + kb/ → soul/skill/KB 内容
  5. 渲染 CLAUDE.md → agent work dir (symlink → release/_current)
  6. API key → agent Identity slice
```

> **生产 agent 始终读 release，不读 sandbox。** admin 预览时使用单独的临时 agent + 独立 preview session 指向 sandbox。fast agent prompt 同样从 release 读取，不是 sandbox。

**Admin preview 隔离规则:**

```
创建 (autoservice_assembly.preview_provision/3):
  → 输入: tid, role, admin_uri
  → 创建 preview session:
      session_uri = session://preview/<tid>/<role>-<timestamp>
      (带时间戳,防止多次预览冲突)
  → 创建 preview fast agent:
      entity://agent/<ws>/fast-preview-<admin>-<timestamp>
      AgentTemplate: curl.agent, system_prompt ← sandbox/config/fast_ack_prompt.md
  → 创建 preview cc agent:
      entity://agent/<ws>/cc-preview-<admin>-<timestamp>
      cwd ← ~/.ezagent/<profile>/tenants/<tid>/cc-agents/preview-<role>-work/
      CLAUDE.md ← soul_renderer 从 sandbox/slots/ + sandbox/souls/ 渲染
      skills/ symlink → sandbox/skills/
      kb.db symlink → sandbox/kb/kb.db
      .mcp.json → kb_mcp_provider 生成(参数化 <tid>-kb, sandbox 路径)
  → 安装 preview routing:
      {:in_session, preview_uri} {:from, admin_uri} → fast_uri + cc_uri
  → 返回: %{session_uri, fast_uri, cc_uri}
  → 前端打开 preview LiveView,订阅 CustomerFeed(preview session)

使用 (与生产路径相同):
  → admin 发消息 → fast agent(读 sandbox prompt) → Turn.open
  → cc agent(cwd 指向 sandbox/) → Turn.compose → Turn.settle
  → CustomerFeed(仅 preview session 订阅) → 前端渲染
  → 唯一差异: 数据源 = sandbox (非 release)

销毁 (autoservice_assembly.preview_teardown/1):
  → SpawnRegistry.terminate(fast_uri) + SpawnRegistry.terminate(cc_uri)
  → RuleStore.delete(preview_routing_rule)
  → Session.destroy(preview_uri) 或等超时自动回收
  → File.rm_rf(preview_work_dir)
  → 超时保护: preview session 闲置 30min 自动触发 teardown

生产客户:
  → session://cs/<ws>/<name>
  → 走相同路径: fast agent → Turn.open → cc agent → Turn.compose → Turn.settle → CustomerFeed
  → 唯一差异: 数据源 = release/_current (非 sandbox)
```

> **preview 和生产走相同的完整路径。** 差异仅在于数据源(sandbox vs release)和 session 类型(preview vs cs)。
> 这样 preview 通过 = 生产必然通过。

**agents.yaml 格式 (priv/skeleton/config/agents.yaml — master-only，不进 sandbox):**

```yaml
fast:
  provider: deepseek                          # curl agent 直连 DeepSeek HTTP API
  model: deepseek-v4-flash
  endpoint: https://api.deepseek.com/chat/completions
  max_tokens: 256
  thinking: disabled

slow:
  provider: claude                            # cc harness 后端: claude | deepseek
  model: claude-sonnet-4-6                    # provider=claude 时的模型
  # model: deepseek-v4-flash                  # provider=deepseek 时替换上面
  effort: low                                 # provider=claude 时生效 (Claude CLI --effort)
                                              # provider=deepseek 时不生效
```

**slow agent 走 DeepSeek 时需要额外部署环境变量 (master 管控，不进仓库，不进 CR):**

```bash
# 让 cc harness 的 Claude CLI 指向 DeepSeek Anthropic 兼容端点:
ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
ANTHROPIC_API_KEY=sk-xxx
# cc CLI 参数 --model 从 agents.yaml slow.model 读取
```

> **已验证**: cc harness + deepseek-v4-flash 在线上 Linux 环境运行。
> `effort` 是 Claude CLI 原生参数，provider=deepseek 时 DeepSeek 不支持，忽略即可。

**配置生效时机 (租户侧):**

| 配置项 | agent 读取源 | CR publish 后 | 需要重建 agent? |
|---|---|---|---|
| soul.md + slot_values | `release/_current/` | agent 重渲染 CLAUDE.md | 否 |
| skill 文件 | `release/_current/skills/` | symlink 跟随 `_current` | 否 |
| kb.db | `release/_current/kb/kb.db` | symlink 跟随 `_current` | 否 |
| fast ACK prompt | `release/_current/config/` | Template system_prompt 字段 dispatch 更新 | 否 |
| cc preamble | `release/_current/config/` | agent 重渲染 CLAUDE.md | 否 |

> **生产 agent 始终读 release。** sandbox 仅用于 admin preview (临时 agent)。
> fast agent prompt 因 AgentTemplate 固化,CR publish 后需手动重建。

**配置生效时机 (平台侧, master admin 管控):**

| 配置项 | 存储 | 生效方式 |
|---|---|---|
| model/endpoint/max_tokens | priv/skeleton/config/agents.yaml | git PR → 部署 → 重建 AgentTemplate |
| fast ACK prompt 默认模板 | priv/skeleton/config/fast_ack_prompt.md | git PR → 部署,新租户创建时复制到 sandbox |
| cc preamble 默认模板 | priv/skeleton/config/cc_preamble.md | git PR → 部署,新租户创建时复制到 sandbox |
| API key (DeepSeek) | 部署环境变量 | 运维管理,重启 agent 后生效 |

**CR publish 后的自动更新:**

```
CR publish(v1 → v2):
  → cp sandbox/ → release/v2/
  → ln -sf release/v2 → _current
  → PubSub broadcast {:content_published, tid, "v2"}
       ├─ 活跃 cc agent: 重渲染 CLAUDE.md, symlink 自动跟随 _current → v2
       ├─ 活跃 curl agent: 重读 ACK prompt 文件
       └─ 新 agent provision: 取 _current → 自动拿最新版本
  → 如 scope 含 model 变更:
       额外 broadcast {:agent_reprovision_needed, tid, [:fast_model]}
       → admin 看到提示,手动重建 agent(或等自然回收后新 agent 自动用新参数)
```

> **设计理由**: 内容(soul/skill/KB/prompts)热更新,与旧 AutoService 一致。
> 模型参数和 secrets 需重建 agent——变更频率低,变更时 admin 手动操作。

---

## 4. 用户管理

### 4.1 三层角色模型

```
Master Admin (平台管理员)
  ├─ 管控: 所有 workspace
  ├─ 管理: 平台级 soul/skill 模板, 创建租户, 指派 tenant admin
  └─ Caps: workspace:* + content:platform:write + user:create:any

Tenant Admin (租户管理员)
  ├─ 管控: 一个 workspace (如 workspace://cinnox)
  ├─ 管理: 租户 soul slot/skill/KB, 管理 operator, CR 审批
  └─ Caps: workspace:<ws>:any + content:tenant:<ws>:write + user:<ws>:create

Operator (客服人员)
  ├─ 管控: 在一个 workspace 内
  ├─ 操作: 查看 CS 会话列表, 接管客户, Turn.claim/settle
  └─ Caps: session:<ws>:join + turn:<ws>:claim + turn:<ws>:settle

Customer (客户)
  ├─ 管控: 自己的 session
  ├─ 操作: 收发消息
  └─ Caps: session:<ws>:send + session:<ws>:receive
```

### 4.2 CapBAC 表达

```elixir
# Master Admin — 全域
%Capability{kind: :workspace, behavior: :any, action: :any,
            instance: :any, workspace_uri: :any}
%Capability{kind: :content,  behavior: :any, action: :write,
            instance: :any, workspace_uri: :any}
%Capability{kind: :user,    behavior: :any, action: :create,
            instance: :any, workspace_uri: :any}

# Tenant Admin — workspace://cinnox
%Capability{kind: :workspace, behavior: Behavior.Workspace, action: :any,
            instance: %URI{host: "cinnox"}, workspace_uri: %URI{host: "cinnox"}}
%Capability{kind: :content,  behavior: :any, action: :write,
            instance: %URI{host: "cinnox"}, workspace_uri: %URI{host: "cinnox"}}
%Capability{kind: :user,    behavior: Behavior.WorkspaceUserAdmin, action: :create_user,
            instance: %URI{host: "cinnox"}, workspace_uri: %URI{host: "cinnox"}}

# Operator — workspace://cinnox
%Capability{kind: :session, behavior: :any, action: :join,
            instance: :any, workspace_uri: %URI{host: "cinnox"}}
%Capability{kind: :turn, behavior: Behavior.Turn, action: :claim,
            instance: :any, workspace_uri: %URI{host: "cinnox"}}
%Capability{kind: :turn, behavior: Behavior.Turn, action: :settle,
            instance: :any, workspace_uri: %URI{host: "cinnox"}}

# Customer — workspace://cinnox
%Capability{kind: :session, behavior: :any, action: :send,
            instance: :any, workspace_uri: %URI{host: "cinnox"}}
%Capability{kind: :session, behavior: :any, action: :receive,
            instance: :any, workspace_uri: %URI{host: "cinnox"}}
```

### 4.3 Roles 模块扩展

```elixir
defmodule EzagentPluginAutoservice.Roles do
  @type role :: :master_admin | :tenant_admin | :operator | :customer

  def bundle(:master_admin, _workspace_uri) do
    # 全域管控 — instance: :any, workspace_uri: :any
  end

  def bundle(:tenant_admin, %URI{host: ws} = workspace_uri) do
    # workspace 内全部管理权限
  end

  def bundle(:operator, %URI{host: ws} = workspace_uri) do
    # session join + turn claim/settle
  end

  def bundle(:customer, %URI{host: ws} = workspace_uri) do
    # session send/receive
  end
end
```

### 4.4 用户管理流程

```
1. 创建 Master Admin
   mix ezagent.user.create --uri entity://user/system/admin --password <pw> --role master_admin

2. Master Admin 创建租户 + Tenant Admin
   tenant_onboard_live → TenantProvisioner.create_tenant("cinnox", "CINNOX", %{
     admin_handle: "admin",
     admin_password: "<pw>"
   })
   → 创建 workspace://cinnox
   → 初始化 soul/skill/KB from skeleton
   → 创建 entity://user/cinnox/admin + 授予 tenant_admin caps

3. Tenant Admin 添加 Operator
   operators_live → WorkspaceUserAdmin.create_user("entity://user/cinnox/op-zhang")
   → 授予 operator caps

4. Customer 自助注册 (loom)
   loom → 匿名生成 entity://user/cinnox/cust-<uuid>
   → 授予 customer caps
   → provision session + agent
   > 注(M4): MVP 阶段为匿名模式,每次新浏览器 = 新用户。
   > 后续可选加 CustomerAuth token 持久化,支持跨设备历史记录。
```

---

## 5. CR 发布流

### 5.1 双区模型 (全文件系统)

```
sandbox (编辑区)                          release (生产区)
─────────────────                        ─────────────────
~/.ezagent/<profile>/tenants/<tid>/      ~/.ezagent/<profile>/tenants/<tid>/
  sandbox/                                 release/v<N>/
    slots/<role>.yaml                        slots/<role>.yaml
    souls/<role>_soul.md                     souls/<role>_soul.md
    skills/<role>/<name>/SKILL.md            skills/<role>/<name>/SKILL.md
    kb/kb.db                                kb/kb.db
    kb/glossary.json                        kb/glossary.json
    kb/escalation_keywords.json             kb/escalation_keywords.json
    skills/<role>/<name>/SKILL.md            skills/<role>/<name>/SKILL.md
                                             │
                                           _current -> v<N>  (符号链接)
```

> **不混合 ConfigStore + 文件系统。** 所有内容数据统一走文件系统,
> sandbox/release 通过目录天然隔离。ConfigStore 仅存 CR 元数据 + tenant config。

CR snapshot 机制:
1. `cr_engine` 创建 CR 时计算 sandbox/ 下 scope 内资源的 sha256 → scope_hash
2. Publish 时 `cp -r sandbox/ → release/v<N>/` (全量拷贝 scope 内资源)
3. `ln -sf release/v<N> → _current` (原子翻指针)

```yaml
cr_id: "cr-20260610-001"
tenant_id: "cinnox"
status: open
target_kind: soul_slot
scope:
  - kind: soul_slot
    role: customer
    section_ids: [identity, brand-structure, gate]
  - kind: skill
    file: skills/customer/lead-collection/SKILL.md
scope_hash:
  "soul_slot:customer/identity": "sha256:abc123..."
  "skill:lead-collection": "sha256:def456..."
scope_locked_at: "2026-06-10T10:00:00Z"
scope_lock_ttl_hours: 24
created_by: "entity://user/cinnox/admin"
created_at: "2026-06-10T10:00:00Z"
published_at: null
published_version: null
```

### 5.2 CR 模型 (简化: 全量发布)

> **一个租户一个 active CR。所有 sandbox 改动 = 一个发布单元。无选择性发布。**
> 好处: 实现简单、原子操作(`cp -r sandbox/ → release/v<N>/`)、与原 AutoService 一致。
> CR 价值: 版本历史 + 回滚 + lint gate + 防误发。

| 属性 | 说明 |
|---|---|
| scope | 始终 = 整个 sandbox (不区分 soul/skill/kb) |
| 锁 | 无 (编辑直接写 sandbox，不需要锁) |
| 并发 | 一个租户一个 active CR，多个 editor 共享 |
| 发布 | `cp -r sandbox/ → release/v<N>/` → `ln -sf release/v<N> → _current` |
| 回滚 | `ln -sf release/v<旧版本> → _current` |

CR 元数据 (ConfigStore `cr:<tid>:<cr_id>`):
```yaml
cr_id: "cr-20260610-001"
tenant_id: "cinnox"
status: open | published | cancelled
created_by: "entity://user/cinnox/admin"
created_at: "2026-06-10T10:00:00Z"
published_at: "2026-06-10T10:30:00Z"
published_version: "v1"
```

### 5.3 CR 工作流 — 从编辑到发布

#### 阶段 1: 编辑 (写 sandbox)

```
Admin 在 SoulSlotEditor / SkillEditor / KbManager 中编辑:
  -> 槽值修改 -> 写 sandbox/slots/<role>.yaml
  -> skill 编辑 -> 写 sandbox/skills/<role>/<name>/SKILL.md
  -> KB 编辑   -> 写 sandbox/kb/kb.db / glossary.json / escalation_keywords.json
  -> prompt 编辑 -> 写 sandbox/config/fast_ack_prompt.md / cc_preamble.md
  -> 每个编辑操作后调 cr_engine.track_change(tid, resource)
```

#### 阶段 2: 预览 (测试 sandbox)

```
Admin 点 "预览 sandbox":
  -> autoservice_assembly.preview_provision(tid, role, admin_uri)
    -> 创建 preview session + fast agent + cc agent (数据源=sandbox)
  -> Admin 在 preview LiveView 中测试
  -> 验证 bot 行为、skill 触发、KB 检索、slot 渲染
  -> 满意 -> 进入发布; 不满意 -> 继续编辑 -> 再预览
```

#### 阶段 3: 发布 (全量)

```
Admin 打开 CR 详情页:
  -> 显示 sandbox vs release 的 diff 摘要
  -> [预览 sandbox] 验证改动
  -> [Publish] 全量发布
  -> [Cancel] 放弃 CR
```

**发布执行 (全量 cp):**

```
Admin 点 "Publish":
  -> 1. Lint check (R01-R05)
  -> 2. cp -r sandbox/ -> release/v<N>/  (全量拷贝)
  -> 3. ln -sf release/v<N> -> _current  (原子翻指针)
  -> 4. PubSub broadcast {:content_published, tid, "<version>"}
  -> 5. CR status -> published
```

### 5.4 Lint 规则

| Rule | Severity | 检查内容 |
|---|---|---|
| R01 | error | scope 内资源引用了 release 不存在的 ID |
| R02 | warning | scope 内资源引用了 sandbox 有 diff 但未在 scope 的依赖 |
| R03 | error | rename/delete 操作导致其他资源引用断裂 |
| R04 | error | slot `_template_version` 与 release 模板不匹配 |
| R05 | warning | L1/L2 资源 publish 时,列出受影响租户 |

---

## 6. Customer 路径

### 6.1 整体流程

```
客户发消息
  ↓
loom (LoomSessionView)
  ├─ Turn.open (立即,记录客户消息 — 即使后续 agent 失败,Turn 也可见)
  ├─ deepseek.ex: fast agent 即时安抚 ACK
  ├─ claude_code.ex: cc agent 主回复 + kb_search + skill Read
  ├─ Turn.compose (收集 cc 回复)
  ├─ Turn.settle (标记完成,锁定回复)
  └─ CustomerFeed.deliver (门控投递)
  ↓
Customer 收到消息 (CustomerFeed 订阅)
```

> **时序修正 (H2):** Turn.open 在 fast agent 之前执行。客户消息到达后立即 open turn,
> 即使 fast/slow agent 失败,operator 也能在 OperatorLive 中看到未处理的 turn。

### 6.2 Turn 状态机 (socialware Behavior.Turn — 已有,复用)

```
open → dispatch → deliver → compose → claim → settle
                                      ↓
                                   cancelled
```

**autoservice 使用:**

| Turn action | 触发时机 | 调用方 |
|---|---|---|
| `open` | 客户消息到达后立即(在 fast agent 之前) | loom (TurnAdapter) |
| `compose` | cc agent 完成主回复 | loom claude_code.ex (via TurnAdapter) |
| `settle` | compose 完成后,锁定回复,投递 CustomerFeed | loom claude_code.ex (via TurnAdapter) |
| `claim` | operator 接管 | autoservice operator_live.ex (via TurnAdapter) |
| `settle` | operator 编辑完成后,翻转可见性为 `:customer_visible` | autoservice operator_live.ex (via TurnAdapter) |

### 6.3 CustomerFeed 门控

> **2026-06-11 修正**: 基于 socialware 真实 API (#727 #728) + Stage-1 (#715) 验证。

```
CustomerFeed 真实机制 (socialware):
  - topic/1:  PubSub topic "socialware:customer:<session_uri>"
  - snapshot/2: 返回当前可见消息快照 (受 visibility 门控)
  - history/2:  完整已提交消息列表
  - Settlement → CustomerOutbox → {:customer_delivery} PubSub 广播

loom/customer_live:
  Phoenix.PubSub.subscribe(CustomerFeed.topic(session_uri))
  → 收到 {:customer_delivery, %{message_ids: [...]}}
  → CustomerFeed.snapshot(session_uri, token) 拉取可见消息
  → 渲染

operator_live:
  同一 PubSub topic → 收到 {:customer_delivery}
  → SocialwarePublisherRead (#728) snapshot/history
  → 接管时: Turn.claim → visibility = :operator_only
    → customer snapshot 不再返回该 turn 的消息
    → operator snapshot 包含 :operator_only 消息
  → 编辑完成后: Turn.settle → visibility = :customer_visible
    → customer snapshot 恢复可见
```

> **不额外广播 operator 状态。** operator 接管/提交隐含在 Turn visibility 翻转
> + CustomerFeed snapshot 变化中。遵守 P14 (dispatch is the only path between Kinds)。

### 6.4 Agent 模型

| Agent | 模型 | 职责 | 实现 |
|---|---|---|---|
| **fast** (DeepSeek) | `deepseek-v4-flash`, no thinking | 即时安抚 ACK (12-30字,<2s) | `curl.agent` template, plain-text output, `thinking: {type: "disabled"}`, `max_tokens: 256` |
| **slow** (cc) | cc harness (Claude CLI), model 可配: 默认 Claude, 可切 DeepSeek-v4-flash | 主回复 + kb_search + skill Read | cc agent, CLAUDE.md(soul) + MCP．effort 等 cc harness 参数从 agents.yaml 读取 |
| **KB MCP** | SQLite FTS5 | KB 检索 (被 cc 作为 tool 调用) | Python MCP server sidecar |

### 6.5 租户运行时

```
per-tenant per-agent 工作目录:
  ~/.ezagent/<profile>/tenants/<tid>/cc-agents/<role>-work/
    ├── CLAUDE.md          (soul + skill index, 渲染后: 取 release/_current)
    ├── .mcp.json          (kb_search MCP + esr-bridge, KB_DB_PATH→release/_current/kb/)
    ├── plugins/<tid>/
    │   └── skills/        (symlink → release/_current/skills/   ← 统一 skill)
    └── kb.db              (symlink → release/_current/kb/kb.db)
```

> **sandbox vs release 隔离**: agent 工作目录始终指向 `release/_current`(生产版本),
> 不是 `sandbox`。tenant admin 在 sandbox 编辑,CR publish 后才进入 release。
> Admin preview 使用单独的 preview agent(指向 sandbox)。

### 6.6 autoservice 集成接口

#### 6.6.1 TurnAdapter (给 loom 调)

loom 不直接调 socialware domain,通过 `turn_adapter.ex`。
实现使用 `%Invocation{}` 格式，与 Stage-1 (#715) 一致：

```elixir
defmodule EzagentPluginAutoservice.TurnAdapter do
  alias Ezagent.Invocation

  defp system_ctx, do: %{caller: Ezagent.SystemPrincipal.uri("turn-adapter"),
                          caps: Ezagent.SystemPrincipal.caps("system://turn-adapter"),
                          reply: {:caller_inbox, self()}}

  def open_turn(session_uri, %{customer_uri: cu, text: text}) do
    Invocation.dispatch(%Invocation{
      target: URI.new!("#{URI.to_string(session_uri)}?action=turn.open"),
      mode: :call,
      args: %{trigger: %{msg: text, from: cu}, opened_at: System.system_time(:second)},
      ctx: system_ctx()
    })
  end

  def compose_turn(session_uri, turn_id, %{agent_uri: au, text: text}) do
    Invocation.dispatch(%Invocation{
      target: URI.new!("#{URI.to_string(session_uri)}?action=turn.compose"),
      mode: :call,
      args: %{turn_id: turn_id, result_refs: [%{agent: au, text: text}]},
      ctx: system_ctx()
    })
  end

  def settle_turn(session_uri, turn_id) do
    Invocation.dispatch(%Invocation{
      target: URI.new!("#{URI.to_string(session_uri)}?action=turn.settle"),
      mode: :call,
      args: %{turn_id: turn_id}, ctx: system_ctx()
    })
  end

  def claim_turn(session_uri, turn_id, %{operator_uri: op}) do
    Invocation.dispatch(%Invocation{
      target: URI.new!("#{URI.to_string(session_uri)}?action=turn.claim"),
      mode: :call,
      args: %{turn_id: turn_id, by: op}, ctx: system_ctx()
    })
  end
end
```

#### 6.6.2 TenantContent.provision_context (autoservice 调 content)

```elixir
defmodule EzagentPluginContent.Tenant.TenantContent do
  @doc """
  为 agent provision 准备完整上下文。
  返回渲染后的 CLAUDE.md、MCP 配置、工作目录路径等。
  """
  @spec provision_context(tid :: String.t(), role :: String.t()) :: %{
    claude_md: binary(),           # 渲染后的完整 CLAUDE.md
    mcp_json: binary(),            # .mcp.json 内容
    work_dir: binary(),            # agent 工作目录路径
    kb_db_symlink_src: binary(),   # kb.db symlink 源 (release/_current/kb/kb.db)
  }
end
```

---

## 7. Operator 接管

### 7.1 接管流程

> **P14 合规**: operator 状态隐含在 Turn visibility 翻转 + CustomerFeed snapshot 变化中，
> 不额外跨 Kind 广播。

```
1. Operator 打开 OperatorLive
   → 列出 workspace 内 CS 会话 (snapshot + live, 过滤 session://cs/<ws>/*)
   → 选择会话

2. 查看会话消息
   → Phoenix.PubSub.subscribe(CustomerFeed.topic(session_uri))
   → 收到 {:customer_delivery} → CustomerFeed.snapshot 拉取

3. 接管 (Turn.claim)
   → TurnAdapter.claim_turn(session_uri, turn_id, %{operator_uri: operator_uri})
   → visibility: :customer_visible → :operator_only
   → customer 的 CustomerFeed.snapshot 不再返回该 turn 消息 (自动，无需通知)
   → RuleStore.disable(rule_id)  ← 暂停 fast/slow agent

4. 编辑回复
   → operator 输入消息，预览

5. 提交 (Turn.settle)
   → TurnAdapter.settle_turn(session_uri, turn_id)
   → visibility: :operator_only → :customer_visible
   → {:customer_delivery} 触发 → customer snapshot 恢复可见
```

### 7.2 Route 调整

使用已有的 `RuleStore.disable/1` + `RuleStore.enable/1` (零 core 改动):

```
接管前:  customer msg → route → fast + slow agent
接管时:  RuleStore.disable(rule.id) → agent 不再接收
接管结束: RuleStore.enable(rule.id)  → agent 恢复接收
```

---

## 8. Admin 操作 (租户核心)

### 8.1 操作总览

```
Tenant Admin 日常工作:
  Soul 编辑   → 填 slot_values(表单) / 上传 soul.md 覆盖 / 定制 prompt
  Skill 管理  → 浏览 4 层 skill / 创建 / 编辑 / 删除
  KB 管理     → URL 抓取 / 文件上传 / 条目增删改 / 重建 kb.db
  CR 发布     → 查看改动 / lint check / Publish / 回滚
  Operator 管理 → 添加/禁用 operator 账号
```

### 8.2 Soul 编辑

**slot_values 编辑 (表单式，按 section 分组):**

```
SoulSlotEditorLive (已有):
  1. soul_slot_parser 解析 soul 模板 -> 提取 {{key}} 列表，按 section 分组
  2. soul_store 读取 sandbox/slots/<role>.yaml -> 当前值
  3. 渲染表单: section > field，每个 field 对应一个 {{key}}
  4. 保存: 写 sandbox/slots/<role>.yaml -> cr_engine.track_change
```

**soul.md 覆盖 (高级，直接编辑 markdown):**

```
  -> 编辑 sandbox/souls/<role>_soul.md (覆盖 L3 模板)
  -> 保存后 cr_engine.track_change({:soul, role})
  -> CR publish 时生效
```

**prompt 定制 (租户可编辑):**

```
  -> 编辑 sandbox/config/fast_ack_prompt.md  (fast agent ACK prompt)
  -> 编辑 sandbox/config/cc_preamble.md      (cc CLAUDE.md preamble)
  -> 编辑 sandbox/config/welcome.md          (欢迎语)
  -> CR publish 后 agent 自动重载
```

### 8.2.5 AI 辅助 Agent (已有，保留)

**两个 cc agent 辅助 admin 管理内容:**

| Agent | 职责 | 界面 | 实现 |
|---|---|---|---|
| **Template Authoring Agent** | 辅助 master admin 创建/编辑 soul 模板 | `TemplateEditorLive` (已有) | cc agent, 系统 workspace, 通过 Read/Write 工具改模板文件 |
| **KB Curator Agent** | 辅助 tenant admin 管理 KB 条目 | `KbCuratorAgent` (已有), 无独立 UI | cc agent, Read/Write/grep 工具操作 glossary.json + kb.db 重建 |

**工作方式:**

```
Template Authoring Agent:
  Admin 在 TemplateEditorLive 中对话:
    "帮我把 identity section 的 bot_full_name 改成可配置的 slot"
  -> cc agent Read 当前模板 -> 修改 {{key}} 占位符 -> Write 写回
  -> 保存到 priv/platform/templates/ (平台模板, 走 git PR)
  -> Admin 审核 diff (TemplateDiffLive) -> 确认

KB Curator Agent:
  Admin 在 terminal/session 中对话:
    "查一下 DID 相关的 KB 条目"
  -> cc agent grep glossary.json + 调 kb_search MCP
    "添加一个新术语: SMS, 短信服务, 用于用户验证"
  -> cc agent 验证唯一性 -> 更新 glossary.json -> 重建 kb.db
  -> 保存到 sandbox/kb/ -> cr_engine.track_change
```

> 这两个 agent 已有实现，不需要新开发。在 content plugin 重构时从 autoservice plugin 迁移过去即可。

### 8.3 Skill 管理

**4 层浏览 (SkillEditorLive):**

```
+-- Skill 管理 --------------------------------------+
|  Tenant (cinnox)                    [当前层]        |
|  +-- customer/                                      |
|  |   +-- customer-type-clarifier/SKILL.md   [编辑]  |
|  |   +-- lead-collection-flow/SKILL.md       [编辑]  |
|  |   +-- discovery-questions/SKILL.md        [编辑]  |
|  Industry (cloud-comms)               [切换层]       |
|  Platform                             [切换层]       |
|  Framework                            [切换层]       |
|  [+ 新建 Skill]                                     |
+----------------------------------------------------+
```

**Skill CRUD (skill_store.ex):**

```elixir
# content plugin 提供:
skill_store.list(tid, role, layer)  -> [%{name, path, layer}]
skill_store.read(tid, role, name)   -> {:ok, content} | :not_found
skill_store.write(tid, role, name, content) -> :ok  # 写 sandbox
skill_store.delete(tid, role, name) -> :ok
```

**Skill 同步到 agent:**

```
  保存 -> 写 sandbox/skills/<role>/<name>/SKILL.md
       -> cr_engine.track_change({:skill, name})
       -> CR publish -> release/_current symlink 更新
       -> agent 自动感知(symlink 跟随 _current)
```

### 8.4 KB 管理

**kb.db 条目 CRUD (kb_store.ex):**

```elixir
kb_store.search(tid, query)        -> [%{id, content, source, ...}]
kb_store.get(tid, entry_id)        -> {:ok, entry}
kb_store.upsert(tid, entry)        -> :ok   # 写 sandbox/kb/kb.db
kb_store.delete(tid, entry_id)     -> :ok
```

**URL 抓取 + 文件上传 (沿用旧 AutoService 设计):**

```
KbManagerLive:
  [URL 抓取]
    -> 输入 URL
    -> 后端调 kb_search_mcp.py --fetch-url <url>
    -> 解析内容 -> 写入 sandbox/kb/kb.db
    -> 记录 sandbox/kb/_sources/_sources.yaml (去重: url + hash)
    -> cr_engine.track_change({:kb, :source, url})

  [文件上传]
    -> 上传 .pdf/.xlsx/.md/.txt
    -> 后端调 kb_search_mcp.py --ingest-file <path>
    -> 解析 -> 写入 sandbox/kb/kb.db
    -> 记录 _sources/_sources.yaml
    -> cr_engine.track_change({:kb, :source, filename})

  [条目编辑]
    -> 直接编辑 glossary.json / escalation_keywords.json / synonym-map.json
    -> 保存后可选触发 kb.db 重建
```

**kb.db 重建:**

```
  -> 调 Python: uv run --script kb_search_mcp.py --rebuild
    --db-path sandbox/kb/kb.db
    --glossary sandbox/kb/glossary.json
    --synonyms sandbox/kb/synonym-map.json
    --sources sandbox/kb/_sources/
  -> CR publish 后新的 kb.db 进入 release
```

**Escalation keywords 编辑:**

```
  编辑 sandbox/kb/escalation_keywords.json
  -> JSON 格式: {"keywords": ["转人工", "投诉", "退款", ...]}
  -> kb_search MCP 在查 SQLite 前先扫这份列表
  -> CR publish 后生效
```

### 8.5 页面路由

```
Master Admin:
  /admin                        -> master_dashboard_live
  /admin/workspaces             -> workspaces_live (已有)
  /admin/workspaces/new         -> tenant_onboard_live
  /admin/users                  -> users_live (已有)
  /admin/platform/soul          -> platform_content_live (L0/L1/L2 soul)
  /admin/platform/skills        -> platform_content_live (skills tab)
  /admin/platform/kb            -> platform_content_live (escalation keywords)

Tenant Admin (per workspace):
  /admin/tenants/<tid>          -> tenant_dashboard_live
  /admin/tenants/<tid>/soul     -> soul_slot_editor_live (已有)
  /admin/tenants/<tid>/skills   -> skill_editor_live
  /admin/tenants/<tid>/kb       -> kb_manager_live
  /admin/tenants/<tid>/crs      -> cr_dashboard_live
  /admin/tenants/<tid>/operators -> operators_live
  /admin/tenants/<tid>/bots     -> bot_creator_live (已有)
  /admin/tenants/<tid>/templates -> template_editor_live (已有)
```

### 8.6 Dashboard 页面

**master_dashboard_live:**
```
+-- 平台概览 ----------------------------------------+
|  租户数: 3 (活跃: 2)                              |
|  Active CRs: 5                                    |
|  最近发布: cinnox v12 (10 min ago)                |
|                                                   |
|  +-- 租户列表 -------------------------------- +  |
|  | cinnox    v12  2 active CRs  [进入]          |  |
|  | acme      v3   1 active CR   [进入]          |  |
|  | demo      v1   0 active CRs  [进入]          |  |
|  +----------------------------------------------+  |
+---------------------------------------------------+
```

**tenant_dashboard_live:**
```
+-- cinnox 概览 -------------------------------------+
|  当前版本: v12 (已发布 2026-06-10 10:30)           |
|  Active CRs: 2                                     |
|  悬挂改动: 3 项未在任何 CR 中                       |
|  Operator: 2 人在线                                |
|                                                    |
|  [预览 sandbox] [查看版本历史] [创建 CR]            |
+---------------------------------------------------+
```

---

## 9. 租户生命周期

### 9.1 创建租户

```
Master Admin → Tenant Onboard 向导

Step 1: 基本信息
  tenant_id:   "cinnox"
  brand_name:  "CINNOX"
  industry:    "cloud-comms"
  role:        "customer"

Step 2: Admin 账号
  admin_handle:   "admin"
  admin_password: "<pw>"

Step 3: 初始化
  → 创建 workspace://cinnox
  → 创建 entity://user/cinnox/admin + tenant_admin caps
  → 文件系统: 从 skeleton 复制到 sandbox
      priv/skeleton/soul/soul.md → ~/.ezagent/<profile>/tenants/cinnox/sandbox/souls/customer_soul.md
      priv/skeleton/skills/      → ~/.ezagent/<profile>/tenants/cinnox/sandbox/skills/customer/
      priv/skeleton/slots.yaml   → ~/.ezagent/<profile>/tenants/cinnox/sandbox/slots/customer.yaml
  → 创建空的 kb.db:
      uv run --script kb_search_mcp.py --init-empty \
        --db-path ~/.ezagent/<profile>/tenants/cinnox/sandbox/kb/kb.db
  → 写入默认 escalation_keywords.json, glossary.json (到 sandbox/kb/)
  → ConfigStore: 写入租户配置
      tenant:cinnox:config → {brand_name: "CINNOX", ...}
  → 创建首个 CR (scope=全部初始化资源,status=open)
      → Tenant admin 可在 preview 页面预览 sandbox 效果(指向 sandbox/ 的临时 agent)
      → 确认无误后手动 Publish:
          cp -r sandbox/ → release/v1/
          ln -sf release/v1 → _current
      → 后续修改走正常 CR 流程: v1 → v2 → v3 ...
```

### 9.2 租户配置

```yaml
# ConfigStore: tenant_config:<tid>
brand_name: "CINNOX"
industry: "cloud-comms"
channels:
  - web
  - general_bot
roles:
  - customer
default_language: "zh"
welcome_message: "您好！我是 CINNOX 的 AI 助手，请问需要帮您了解哪方面？"
```

---

## 10. 实施计划

### 10.1 Phase 划分

```
Phase A: 提炼 content + cr plugin, 通用化 (本期核心)
  A1: ezagent_plugin_content — soul/skill/KB CRUD + tenant provision
  A2: ezagent_plugin_cr — CR engine + lint + snapshot
  A3: CinnoxAssets/Runtime 重构 → content plugin
  A4: cinnox 数据从 autoservice priv/cinnox/ 迁移到 runtime 路径 ~/.ezagent/<profile>/tenants/cinnox/

Phase B: autoservice 精简 + Turn 接入
  B1: autoservice_assembly.ex — 组装协调
  B2: Customer 路径: Turn 接入(CustomerLive 先验证,loom API 后续对接 — 决议 D1)
  B3: operator_live Turn.claim/settle
  B4: CustomerFeed 订阅替换 session_events_topic
      (CustomerFeed.notify 暂无则走 PubSub — 决议 D6)

Phase C: Admin UI 补齐
  C1: master_dashboard + tenant_onboard
  C2: tenant_dashboard + operators_live
  C3: skill_editor_live + kb_manager_live
  C4: cr_dashboard_live

Phase D: FillerLoop + 优化 (可 defer)
  D1: filler_loop.ex (loom)
  D2: cc 超时处理
```

### 10.2 文件统计

```
                    新 plugin     plugin 改动      说明
Phase A:
  content plugin       ~18           —          soul/skill/KB CRUD + tenant
  cr plugin             ~4           —          CR 发布流
  autoservice           —           ~4          Cinnox→content 迁移
Phase B:
  autoservice           —           ~3          精简+Turn接入
  loom                  —           ~4          Turn+CustomerFeed
Phase C:
  liveview              —           +8          admin UI 补齐
─────────────────────────────────────────────────
合计: 2 个新 plugin / ~19 文件 plugin 改动
core: 0 / domain: 0
```

---

## 附录 A: 与原 AutoService (Python) 对照

| 能力 | 原 AutoService | ezagent v2 |
|---|---|---|
| Customer 聊天 | WebSocket + SSE | loom (Next.js SPA) |
| Fast agent (DeepSeek) | fast_phase JSON ACK | curl agent plain-text ACK |
| Slow agent (cc) | cc_pool + soul + KB MCP | cc agent + CLAUDE.md + MCP |
| FillerLoop | deepseek 填充语 / N 秒 | filler_loop.ex (Phase D) |
| Turn 状态机 | 无 (单轮回复) | Turn Behavior (open→compose→settle) |
| CustomerFeed | 无 (原始广播) | CustomerFeed 门控 |
| Operator 接管 | DIRECT_TRANSFER (cinnox 特有) | Turn.claim → 编辑 → settle (通用) |
| Soul 编辑 | Admin Portal V2 | SoulSlotEditor + tenant_content |
| Skill 管理 | skill_loader 4 层 | skill_loader + SkillEditor |
| KB 管理 | KB Manager (URL 抓取/上传) | KbManager + KbCuratorAgent |
| CR 发布流 | sandbox→CR→publish→release | cr plugin |
| 多租户 | per-tenant sandbox | workspace + tenant_provisioner |
| 权限 | 简单 RBAC | CapBAC (5 维) + Roles |
| 用户管理 | 文件密码 | Identity + WorkspaceUserAdmin |
| Voice | WS + ASR/TTS | 不在本期范围 |

---

## 附录 B: 术语对照

| 原 AutoService | ezagent |
|---|---|
| tenant | workspace |
| soul.md (plugins/<tid>/souls/) | content/priv/tenants/<tid>/souls/ |
| skill (旧子目录) / flow_directive (KB行) | content/priv/tenants/<tid>/skills/ (flat .md) |
| kb.db + MCP server | 同上 (content/priv/tenants/<tid>/kb/) |
| sandbox → release | CR plugin + ConfigStore |
| cc_pool | cc agent (per-session, via Template) |
| Pipeline v2 orchestrator | loom deepseek.ex + claude_code.ex |
| Admin Portal V2 | ezagent_plugin_liveview |
| Soul Editor (§1-17) | SoulSlotEditorLive + platform_content_live |
| CR scope/lock | cr_engine.ex |
| escalate_confirm | Turn.claim (通用接管机制) |
| DIRECT_TRANSFER | cinnox 特有,不进通用框架 |

---

## 附录 D: 设计缺口 & 待决策

> 2026-06-10 最终审查

### 需修正 (文档内部不一致)

| # | 位置 | 问题 | 修正 |
|---|---|---|---|
| F1 | §2.2 CR 数据模型 | yaml 示例中路径写 `.autoservice/crs/<tid>/<cr_id>.yaml`,与 ConfigStore 不一致 | 改为 ConfigStore key `cr:<tid>:<cr_id>` |
| F2 | §3.3 Skill 4 层路径 | 第 4 层写 `content/priv/tenants/<tid>/skills/` | 改为 `~/.ezagent/<profile>/tenants/<tid>/sandbox/skills/<role>/` |
| F3 | §3.4 KB MCP 配置 | MCP server name 硬编码 `cinnox-kb` | 改为 `<tid>-kb`,参数化 |
| F4 | §6.2 Turn 时序表 | 表写 "fast agent ACK 后" 但 §6.1 文本写 "立即" | 统一为 "客户消息到达后立即,在 fast agent 之前" |
| F5 | §6.5 租户运行时 | kb.db symlink 源路径未更新 | 改为 `~/.ezagent/<profile>/tenants/<tid>/sandbox/kb/kb.db` |
| F6 | §10.1 Phase A4 | 写 "content/priv/tenants/cinnox/" | 改为运行时路径 |

### 需决策 (设计未覆盖)

| # | 级别 | 问题 | 选项 |
|---|---|---|---|
| D1 | HIGH | **loom 分支不在当前 autoservice。** Design 依赖 loom 做 Customer 前端,但 loom 在独立分支 `feat/loom`(zyli/zhangning)。 | A) 先合 loom 到 autoservice B) autoservice 提供 REST API,loom 后续对接 C) Customer 路径 Phase B 之前用现有 CustomerLive 验证 |
| D2 | HIGH | **`ensure_active_cr()` 机制**: 一个租户同时只有一个 active draft CR。多个 editor(Soul/KB/Skill) 并发编辑时如何分配到同一个 CR? | `cr_engine.ensure_active_cr(tid)` — 有 active CR 就返回它,没有就创建新的。所有 editor 共享同一个 active CR |
| D3 | HIGH | **初始发布 (v1)**: 租户创建后 sandbox 有内容但无 release。首次发布流程? | **手动 CR publish**: 租户创建后自动创建首个 CR(scope=全部资源,status=open)。Tenant admin 预览 sandbox → 确认 → 手动 Publish → 生成 v1。与后续发布流程一致,不搞特殊路径 |
| D4 | HIGH | **agent 重启策略**: CR publish 后 "recycle cc_pool" — ezagent 没有 cc_pool。cc agent 是 per-session 的 Template 实例。 | A) 不主动重启,等 agent 自然回收(max_queries) B) publish 时发 signal 让活跃 agent 重载 CLAUDE.md C) CR publish 仅影响新 session,旧 session 继续用旧版本 |
| D5 | MEDIUM | **skill 文件路径解析**: Skill Index 写 `skills/customer/lead-collection/SKILL.md`,cc agent Read 时如何找到实际文件? | Symlink 结构: agent work dir 下 `plugins/<tid>/skills/` → symlink → `sandbox/skills/`。skill_loader 生成 Index 时用相对路径 |
| D6 | MEDIUM | **CustomerFeed.notify/2**: 当前 socialware domain 是否有此函数? | 需验证。如无,在 socialware domain 加 `CustomerFeed.notify(session_uri, event)` 或直接走 PubSub |
| D7 | MEDIUM | **Master admin 创建**: `mix ezagent.user.create --role` 不存在 | A) 扩展 mix task 支持 --role B) 手动传 --caps '<json>' C) tenant_onboard 时自动创建首个 master admin |
| D8 | MEDIUM | **Admin 视角切换**: LiveView 如何区分 master vs tenant 视图? | 基于 caps: 有 `workspace_uri: :any` cap → master 视图; 有 workspace-scoped cap → tenant 视图。页面路由自动判断 |
| D9 | LOW | **租户删除/暂停**: 设计未覆盖 | 本期不覆盖。删除 = 移除 workspace + 清理 runtime 路径。暂停 = 禁用 routing rules |
| D10 | LOW | **测试策略**: 多 plugin 系统如何测试? | Phase A 每个 plugin 独立 ExUnit; Phase B 集成测试 via `mix ezagent.demo.seed_autoservice` + agent-browser |
| D11 | LOW | **现有 cinnox demo 数据迁移**: priv/cinnox/ → 新路径 | Phase A4: 写迁移脚本 `mix ezagent.content.migrate_cinnox` |

### 推荐决议

| D# | 推荐 | 理由 |
|---|---|---|
| D1 | **C → B**: 先 CustomerLive 验证,后续 loom API 对接 | loom 团队独立,不应阻塞 autoservice Phase B |
| D2 | `ensure_active_cr(tid)` 共享 CR | 一个租户一个 draft,简单且与原 AutoService 一致 |
| D3 | **手动 CR publish** | 与后续发布流程一致,先预览 sandbox 再发布 |
| D4 | **B**: publish 时通知 agent 重载 CLAUDE.md | 已有 session 的客户应尽快看到新内容 |
| D5 | symlink 结构 | 最小改动,cc agent Read tool 天然支持 |
| D6 | 走 PubSub broadcast | 不依赖 CustomerFeed 扩展,用现有机制 |
| D7 | **B**: 手动传 --caps,文档写明 | 不改 core mix task,保持简单 |
| D8 | 基于 caps 自动判断 | CapBAC 已提供足够信息 |
| D9 | 本期不覆盖,后续单独设计 | — |
| D10 | 独立 ExUnit + agent-browser 集成 | 分层测试 |
| D11 | Phase A4 写迁移脚本 `mix ezagent.content.migrate_cinnox` | 一次性迁移 |

### 修正完成 (文档不一致 F1-F6)

| # | 问题 | 状态 |
|---|---|---|
| F1 | CR 路径 `.autoservice/crs/...yaml` | ✅ §2.2: 改为 ConfigStore key |
| F2 | Skill 第 4 层路径 `content/priv/tenants/` | ✅ §3.3: 改为 runtime path |
| F3 | MCP server 名硬编码 `cinnox-kb` | ✅ §3.4: 参数化为 `<tid>-kb` |
| F4 | Turn.open 时序描述不一致 | ✅ §6.2: 统一为"客户消息到达后立即" |
| F5 | kb.db symlink 路径 | ✅ §6.5: 改为 sandbox/kb/kb.db |
| F6 | Phase A4 路径 | ✅ §10.1: 改为 runtime 路径 |

### 第二轮审查新增 (多 plugin 协调 + socialware 对接)

| # | 级别 | 问题 | 决议 | 状态 |
|---|---|---|---|---|
| C4 | CRITICAL | Agent symlink 指向 sandbox,应指向 release | §6.5: symlink → `release/_current/`,不是 sandbox | ✅ |
| C5 | CRITICAL | content ↔ cr 插件接口未定义 | §5.3: `cr_engine.track_change(tid, resource)` — editor 写 sandbox 后调 | ✅ |
| H4 | HIGH | autoservice ↔ content 集成点模糊 | §6.6: content plugin 提供 `TenantContent.provision_context(tid, role) → %{...}` | ✅ |
| H5 | HIGH | skill symlink 来源不明确(platform vs tenant) | §6.5: platform 模板 symlink→priv/(只读), tenant skill→release/_current/skills/ | ✅ |
| H6 | HIGH | ConfigStore 滥用 — slot_values 存 sandbox/release 双区 | §3.2.1: slot_values 走文件系统(slots/<role>.yaml),ConfigStore 仅 CR+config | ✅ |
| H7 | HIGH | RuleStore.pause_rule 需改 core | §7.2: 用已有 `RuleStore.disable/1` + `enable/1`,零 core 改动 | ✅ |
| H8 | HIGH | TurnAdapter 内部实现未说明 | §6.6: 通过 `Router.dispatch` 调 socialware Turn Behavior | ✅ |
| M5 | MEDIUM | Admin preview sandbox 功能 | §9.1: 临时 cc agent 指向 sandbox(非 release),通过 AgentTemplate cwd | ✅ |
| M6 | MEDIUM | §7.1 仍写 CustomerFeed.notify | §7.1: 改为 PubSub.broadcast | ✅ |
| M7 | MEDIUM | workspace 创建归属不清 | §2.3: autoservice_assembly 负责; content plugin 只管数据 | ✅ |

### 追加设计决策

| # | 内容 | 位置 |
|---|---|---|
| D12 | `soul_renderer` 渲染失败保留 `{{key}}` raw 文本 | §3.2.2 |
| D13 | Skill `{{slot}}` 与 soul 同步渲染 | §3.2.3 |
| D14 | CR publish 后发 PubSub `{:content_published, tid, version}` → agent 重载 | §5.3 |

### 多 Plugin 协调规则

```
ezagent_plugin_content → 无依赖(纯数据管理,读写文件系统 + ConfigStore)
ezagent_plugin_cr      → 依赖 content(读 sandbox 状态)
ezagent_plugin_autoservice → 依赖 content + cr + socialware(组装)
ezagent_plugin_liveview → 依赖 content + cr + autoservice(admin UI)

调用链:
  admin 编辑 Soul Slot → liveview 调 autoservice.assembly.write_slot(tid, role, key, val)
    → autoservice 调 content.soul_store.write(tid, role, sandbox path, key, val)
    → autoservice 调 cr_engine.track_change(tid, {:soul_slot, role, section_id})
    → cr_engine ensure_active_cr + 更新 scope

  agent provision → autoservice.assembly.provision_agent(tid, role)
    → autoservice 调 content.tenant_content.provision_context(tid, role) → %{claude_md, mcp_json, ...}
    → autoservice 调 workspace.create_agent 创建 cc agent(传入 work_dir + CLAUDE.md)
  
  operator takeover → autoservice TurnAdapter.claim_turn(session_uri, turn_id, attrs)
    → 内部 dispatch 到 socialware Turn Behavior
    → RuleStore.disable(rule_id)  ← 暂停 agent route
    → PubSub.broadcast(session_topic, {:operator_joined, operator_uri})
```

| # | 级别 | 问题 | 决议 | 状态 |
|---|---|---|---|---|
| C1 | CRITICAL | 租户可变数据不应放 `priv/` | §2.1: `priv/`(只读) + `~/.ezagent/<profile>/tenants/<tid>/`(可变) | ✅ §2.1, §3.2 |
| C2 | CRITICAL | CR 与 ConfigStore 映射不明确 | §3.2: ConfigStore key 命名约定 `content:sandbox:` / `content:release:` / `cr:` / `tenant:` | ✅ §3.2, §5.1 |
| C3 | CRITICAL | sandbox/release 目录结构与 ConfigStore 并存 | §5.1: 统一走 ConfigStore,CR promote 时拷贝 sandbox key → release key | ✅ §5.1 |
| H1 | HIGH | loom 依赖 loom 团队,需接口契约 | §6.6: `TurnAdapter` 模块暴露 `open_turn/2`, `compose_turn/3`, `settle_turn/2`, `claim_turn/3` | ✅ §6.6 |
| H2 | HIGH | Turn.open 应在 fast agent 之前 | §6.1: 客户消息到达 → Turn.open → fast agent → compose → settle | ✅ §6.1 |
| H3 | HIGH | Operator 接管通知 loom 机制 | §7.1: `CustomerFeed.notify(session_uri, :operator_joined)` | ✅ §7.1 |
| M1 | MEDIUM | `auto ensure_active_cr()` 触发点 | §5.3: editor 写 sandbox 后调 `cr_engine.track_change/2` | ✅ §5.3 |
| M2 | MEDIUM | Route 调整机制 | §7.2: `RuleStore.pause_rule/2` + `resume_rule/2` | ✅ §7.2 |
| M3 | MEDIUM | 租户创建时 kb.db 初始化 | §9.1: provision 时同步 `uv run --script kb_search_mcp.py --init-empty` | ✅ §9.1 |
| M4 | MEDIUM | Customer 身份持久化 | §4.4: MVP 匿名 `cust-<uuid>`,后续 CustomerAuth | ✅ §4.4 |
| — | DONE | fast agent 模型 | §6.4: `deepseek-v4-flash`, no thinking, `max_tokens: 256` | ✅ §6.4 |

---

### 第三轮更新 (2026-06-11) — 团队审查修正

| # | 级别 | 问题 | 决议 |
|---|---|---|---|
| ①② | MUST-FIX | slow runtime 混淆 + P14 PubSub | slow=cc harness(model 可配)；operator 状态走 CustomerFeed visibility，不额外广播 |
| ③ | MUST-FIX | CustomerFeed API 不存在 | 改用真实 API: topic/1 + snapshot/2 + history/2 + {:customer_delivery} |
| ④ | MUST-FIX | TurnAdapter 代码编不过 | 改为 %Invocation{target: "...?action=turn.open"} |
| ⑤ | SHOULD-FIX | macOS Keychain 隔离 | Linux only 部署约束，不处理 macOS |
| ⑥ | WATCH | CR 选择性发布矛盾 | **去掉选择性发布**，CR = sandbox 全量 → release |
| ⑦ | WATCH | agents.yaml 租户可写 | **确认 master-only**，priv/skeleton/config/ 不进入 sandbox |
| ⑧ | WATCH | Phase B 归属模糊 | **编排归属 autoservice TurnAdapter**，loom 只是前端渲染 |

**6 个开放问题回答**: slow=cc harness、CR=全量发布、cc 凭证=Linux 部署解决、编排=autoservice、CR 并发=一个租户一个 CR 无并发、版本不一致=可接受。

### 第四轮更新 (2026-06-11) — main 同步

| # | 内容 | 状态 |
|---|---|---|
| — | autoservice 重置到 main HEAD (`0a094410`) + 14 文档 commit | ✅ |
| — | socialware #727 CustomerFeed :pull ExternalAdapter 纳入 §6.3 | ✅ |
| — | socialware #728 PublisherRead 纳入 operator_live | ✅ |
| — | socialware #716 render_soul soul_md 纳入 §3.2.2 | ✅ |
| — | 旧 Phase 1-4 代码归档 `archive/autoservice-phase1-4` | ✅ |
| — | core #721 G1-b routing boot hydration 确认设计正确 | ✅ |

*文档版本: 2026-06-11 · 下一步: 进 Phase A 实施*
