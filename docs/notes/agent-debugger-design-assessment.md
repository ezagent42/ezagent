# Agent Debugger — 通用设计评估

> 2026-06-16 | 基于 autoservice-dev 当前架构

## 问题

当前 SandboxPreviewLive 存在两个设计问题：

1. **硬编码在 AutoService 插件内** (`autoservice/admin/sandbox_preview_live.ex`)
2. **只做了 Claude.md 渲染**，不是真正的 agent 对话测试

## ezagent 现有 Agent 种类

ezagent 是一个多 agent 平台，不止 customer：

| Agent Kind | 插件 | 用途 |
|-----------|------|------|
| `CcAgent` | ezagent_plugin_cc | Claude Code agent（通用） |
| `CurlAgent` | ezagent_plugin_curl_agent | HTTP API agent |
| `EchoAgent` | ezagent_plugin_echo | Echo 测试 agent |
| `CodexAgent` | ezagent_plugin_codex | Codex agent |
| `CustomerAgent` (fast/slow) | ezagent_plugin_autoservice | 客服 agent |
| `OperatorAgent` | ezagent_plugin_autoservice | 人工客服 agent |
| `AdminAgent` (future) | ezagent_plugin_autoservice | 管理 agent |

**所有 agent 都遵循同一个模式**：work-dir → CLAUDE.md → behavior → session chat。

## 现有可复用的 Agent 交互 UI

### 1. OperatorLive（已有）
- 路径：`apps/ezagent_plugin_liveview/lib/.../autoservice/operator_live.ex`
- 功能：列出 workspace 内的 customer sessions，选择后进入实时聊天
- 模式：`User → send message → Agent responds`（真实的 dispatch → PTY → response 流程）
- 局限：硬编码 customer session 类型，只连 release agent

### 2. CustomerLive（已有）
- 路径：`apps/ezagent_plugin_liveview/lib/.../autoservice/customer_live.ex`
- 功能：客户聊天界面
- 模式：同上

## 通用 Agent Debugger 设计方案

### 核心概念

不应该叫 "SandboxPreviewLive for autoservice"，而应该是：

> **Agent Debugger** — ezagent 平台级的 agent 调试工具，对所有 agent kind 通用

### 参数化

```
Agent Debugger 输入参数：
  - agent_uri:    entity://agent/<workspace>/<name>  或  session URI
  - source:       sandbox | release
  - role:         (可选，autoservice 场景下区分 customer/operator)
```

### 功能矩阵

| 功能 | 适用范围 | 说明 |
|------|---------|------|
| **Chat Test** | 所有 agent | 发送消息 → 观察 agent 响应。复用 OperatorLive 的 chat pipeline |
| **Source View** | 所有 agent | 查看 agent 的 CLAUDE.md 完整合成（SoulRenderer.full_claude_md 或等价） |
| **Sandbox vs Release Diff** | 有 sandbox/release 的 agent | 两边发相同消息，并排对比响应差异 |
| **Slot/Skill Diff** | autoservice 特有 | 显示哪些 slot/skill 改了，响应差异溯源 |
| **Effective Caps View** | 所有 agent | 展示 agent 当前的 caps，调试权限问题 |
| **Workspace Context** | 所有 agent | 显示 agent 的 work-dir、模板、KB 等上下文 |

### 建议位置

```
方案 A: ezagent_web 平台级
  apps/ezagent_web/lib/ezagent_web/live/agent_debugger_live.ex
  Route: /admin/agents/debug?agent_uri=...&source=sandbox

方案 B: 新插件 ezagent_plugin_agent_debug
  apps/ezagent_plugin_agent_debug/
  Route: /debug/agents/:agent_uri

推荐方案 A — agent 调试是平台核心能力，不应放在某个垂直插件里
```

### 与现有 UI 的关系

```
当前 (autoservice-dev):
  SandboxPreviewLive → 独立页面，只渲染 Claude.md ❌

改为:
  Agent Debugger → 通用平台功能
    ├── Chat Tab: 实际对话测试（复用 chat pipeline）
    ├── Source Tab: CLAUDE.md 源码查看
    ├── Diff Tab: sandbox vs release 对比（消息级 + 源码级）
    └── Context Tab: caps / slots / skills / KB 上下文

  AutoService 中:
    不再有独立的 SandboxPreviewLive
    而是在 TenantDashboard / Sidebar 中放置 "🧪 Debug Agent" 链接
    自动填入: agent_uri=session://cs/<tid>/customer&source=sandbox
```

### 对 Sidebar 的影响

```
🔍 Verify 组改为统一入口:

  当前设计:
    🧪 Sandbox Preview  → 独立页面，autoservice 专用

  建议改为:
    🧪 Agent Debugger   → 平台通用，按当前 tenant context 自动填充参数
                          autoservice → customer agent
                          其他场景 → 手动选择 agent URI
```

## 建议优先级

| 步骤 | 内容 | 优先级 |
|------|------|:--:|
| 1 | 评估确认：Agent Debugger 作为通用平台功能 | — |
| 2 | 实现 Chat Test（复用 OperatorLive pipeline） | P1 |
| 3 | 实现 Sandbox vs Release 并排对比 | P1 |
| 4 | 实现 Source View + Context View | P1 |
| 5 | 将 AutoService SandboxPreviewLive 入口改为 Agent Debugger | P1 |
| 6 | 扩展支持非 autoservice agent（curl/echo/codex）| P2 |

## 当前的 SandboxPreviewLive 代码

本 worktree 的 `sandbox_preview_live.ex`（86行）:
- 只做了 Claude.md 渲染
- 硬编码 `role: "customer"`
- 不应作为最终实现，应替换为通用 Agent Debugger

autoservice-dev 没有独立的 SandboxPreviewLive 文件（在 36 项 checklist 的 Batch 5 #31 标记为待实现）。

## 结论

- **不做** AutoService 专用的 SandboxPreviewLive
- **改做** ezagent 平台级的 Agent Debugger
- Sidebar 中的 "🧪 Sandbox Preview" 改为 "🧪 Debug Agent"，通用入口
- 当前 tenant context 自动推断 agent URI
- 复用 OperatorLive 的 chat pipeline 做实际对话测试
