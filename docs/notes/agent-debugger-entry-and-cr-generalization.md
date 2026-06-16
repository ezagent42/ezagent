# Agent Debugger 入口 + CR 通用化设计

> 2026-06-17

## 一、Agent Debugger 入口设计

### 问题

当前所有 agent 调试相关代码都在 `autoservice/admin/`，入口硬编码为 tenant → customer agent。
但 ezagent 有 6+ 种 agent kind，需要一个通用入口。

### 现有可用的 Agent 发现机制

| 机制 | 模块 | 能力 |
|------|------|------|
| KindRegistry | `Ezagent.KindRegistry` | 所有运行中的 Kind 进程（实时） |
| KindSnapshot | `Ezagent.Ecto.KindSnapshot` | 所有持久化的 Kind 快照（历史） |
| AgentFlavorRegistry | `Ezagent.AgentFlavorRegistry` | 所有注册的 agent flavor |
| AgentLineage | `Ezagent.AgentLineage` | agent 生成关系（谁 spawn 了谁） |
| EntitiesLive | 已有页面 | 列出 KindRegistry 中所有 live Kind |

### 入口设计：三级入口

```
Level 1: 全局 Agent 浏览器（新页面，平台级）
  Route: /debug/agents
  功能:
    ┌──────────────────────────────────────────────────────┐
    │ 🧪 Agent Debugger                                     │
    │                                                       │
    │ Filter: [All Kinds ▾] [All Workspaces ▾] [Search]    │
    │                                                       │
    │ ┌─────────┬──────────┬──────────┬─────────┬────────┐ │
    │ │ Agent   │ Kind     │ Workspace│ Status  │ Actions │ │
    │ ├─────────┼──────────┼──────────┼─────────┼────────┤ │
    │ │ customer│ CcAgent  │ demo-acme│ 🟢 live │ [Debug] │ │
    │ │ admin   │ CcAgent  │ system   │ 🟢 live │ [Debug] │ │
    │ │ echo-1  │ EchoAgent│ system   │ ⚪ cold │ [Debug] │ │
    │ │ curl-pg │ CurlAgent│ team-api │ 🟢 live │ [Debug] │ │
    │ └─────────┴──────────┴──────────┴─────────┴────────┘ │
    └──────────────────────────────────────────────────────┘

Level 2: Workspace 上下文入口
  每个 workspace 的 dashboard 中显示该 workspace 的 agents
  "Debug" 按钮 → 跳转 Agent Debugger

Level 3: AutoService Tenant 快捷入口（便利）
  Sidebar "🧪 Debug Customer Agent" → 自动填入:
    agent_uri = session://cs/demo-acme/customer
    source = sandbox
  （背后是同一个通用 Agent Debugger，只是参数预填）

Level 4: 直接 URI
  /debug/agents?uri=entity://agent/system/echo-1&source=release
  任何地方都可以链接过来
```

### 入口与现有 UI 的关系

```
现有:
  entities_live.ex — "所有 live Kind" 列表（已有）
  agent_api_keys_live.ex — agent API key 管理（已有）
  profile_live.ex — 系统 profile（已有）

新增:
  agent_debugger_live.ex — agent 调试器

增强:
  entities_live.ex — 每行加 [Debug] 按钮 → 跳转 Agent Debugger
```

---

## 二、CR 是否通用化？

### 当前 CR 的 AutoService 耦合点

```elixir
# CrEngine.ensure_active_cr  → 创建 cr:<tid>:active key
# CrEngine.record_file_change → 记录 sandbox_diff: %{files_changed, paths, lines...}
# CrEngine.publish           → lint (CrLint) → snapshot (CrSnapshot) → flip symlink
# CrEngine.list_crs          → 列出 cr:<tid>:* keys
# CrLint.check               → 检查 soul/skill/kb 文件完整性
# CrSnapshot.snapshot        → 复制 sandbox/ → release/v<N>/
```

AutoService 特有的：
- Lint 规则：检查 `{{slot}}` 匹配、skill 目录非空、symlink 有效性
- 文件类型：souls/, slots/, skills/, kb/
- Tenant 概念：`cr:<tid>:active`

通用的（可提取）：
- sandbox → release 复制（snapshot）
- `_current` symlink 原子翻转
- 版本号递增
- 变更追踪（哪些文件改了）

### 方案 A：保持现状，仅补文档

```
ezagent_plugin_cr          ← AutoService CR（不改）
ezagent_plugin_agent_debug ← 通用 Debug（新建，只读 CR 数据）
```

- CR 不通用化
- Agent Debugger 对 non-AutoService agent 不显示 CR/Version
- 对 AutoService agent 提供跳转链接到 CR Dashboard

**优点**：零改动成本
**缺点**：如果以后 curl agent / echo agent 也需要版本管理，得重复造轮子

### 方案 B：提取通用 Agent Version Manager

```
ezagent_plugin_agent_version   ← 🆕 通用 Agent 版本管理
  ├── AgentVersionManager
  │   ├── snapshot(agent_uri)        # 通用 snapshot，不限定文件类型
  │   ├── publish(agent_uri)         # 通用 publish
  │   ├── list_versions(agent_uri)   # 通用版本列表
  │   └── rollback(agent_uri, ver)   # 通用回滚
  │
  └── AgentVersionLive
      ├── Version Timeline（通用）
      └── Diff View（通用文件 diff）

ezagent_plugin_cr (重构)
  └── 删除 CrEngine/CrLint/CrSnapshot → 改为依赖 AgentVersionManager
  └── 只保留 AutoService 特有的 Lint 规则（作为 AgentVersionManager 的 hook）
```

**优点**：以后所有 agent kind 都能用版本管理
**缺点**：改动量大，需要从 CR plugin 中提取通用部分

### 方案 C：分步走（推荐）

```
Phase 1 (P1): Agent Debugger 独立 plugin
  - 只做测试/调试，不做版本管理
  - 对 autoservice agent 提供跳转 CR 的链接
  - 对其他 agent 只提供 chat test + source view

Phase 2 (P2): 评估 CR 通用化需求
  - 等 admin session 做起来后，看实际是否需要
  - 如果确实有 curl/echo agent 需要版本管理，再做通用化
  - 目前 autoservice 是唯一的 sandbox/release 使用者

Phase 3 (P3+): 如果需要，提取 AgentVersionManager
```

---

## 三、建议结论

| 决策 | 结论 |
|------|------|
| Agent Debugger 入口 | 三级：全局浏览器 → workspace 上下文 → tenant 快捷入口 |
| 入口实现 | 新页面 `/debug/agents` + 增强 `entities_live` |
| CR 通用化 | **暂不**（Phase 2 再评估），先走方案 C |
| Agent Debugger 对非 autoservice agent | Chat Test + Source View，不显示 CR/Version |
| Agent Debugger 对 autoservice agent | 完整 sandbox vs release 对比 + 跳转 CR Dashboard |
