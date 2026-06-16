# AutoService 拆解为可复用 Plugin 组合 — 架构评估

> 2026-06-17

## 用户提案

将 AutoService 从一个垂直 monolith 拆解为多个可复用 plugin 的组合：

```
AutoService = Orchestrator + Set Agent + Debug Agent + Tenant + CR
```

## 拆解映射

### 现有 AutoService → 通用 Plugin 映射

| 现有 AutoService 功能 | 抽取为 Plugin | 通用性 | 可独立使用？ |
|----------------------|--------------|--------|:--:|
| Soul/Skill/KB/Slot 编辑器 | `ezagent_plugin_agent_config` (Set Agent) | 所有 file-based agent | ✅ |
| Fast/Slow agent + Operator 路由 | `ezagent_plugin_agent_orchestrator` (Routeset) | 所有多 agent 编排 | ✅ |
| Agent 对话测试 + sandbox vs release | `ezagent_plugin_agent_debug` (Debug) | 所有 agent kind | ✅ |
| CR 版本管理 + Publish | `ezagent_plugin_agent_version` (CR) | 所有 agent 版本管理 | ✅ |
| 租户创建/管理 | `ezagent_plugin_tenant` (Tenant) | workspace 隔离 | ✅ |
| InitWizard | 留在 AutoService | AutoService 特有 | ❌ |
| FastPrompt Editor | 合并到 Set Agent | 通用 prompt 编辑 | ✅ |
| Operators UI | 留在 AutoService / 通用化 | 混合 | 🤔 |

### 每个 Plugin 的职责边界

```
┌──────────────────────────────────────────────────────────────┐
│ ezagent_plugin_agent_config   (Set Agent)                    │
│                                                               │
│  通用 Agent 配置文件编辑器                                     │
│  ┌──────────────────────────────────────────────────────┐    │
│  │ Agent Config Editor                                    │    │
│  │  给定一个 agent URI + work-dir:                        │    │
│  │  - 列出该 agent 的所有配置文件                          │    │
│  │  - 文本编辑器（Markdown / YAML）                       │    │
│  │  - Diff 视图（sandbox vs release）                     │    │
│  │  - 保存 → CR 追踪                                      │    │
│  │                                                        │    │
│  │  AutoService 定制:                                      │    │
│  │  - SoulEditor    = ConfigEditor(file=souls/*.md)       │    │
│  │  - SlotEditor    = ConfigEditor(file=slots/*.yaml)     │    │
│  │  - SkillManager  = ConfigEditor(dir=skills/)           │    │
│  │  - KbManager     = ConfigEditor(dir=kb/, special UI)   │    │
│  │  - FastPrompt    = ConfigEditor(file=fast_ack_prompt)  │    │
│  └──────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ ezagent_plugin_agent_orchestrator  (Routeset)                 │
│                                                               │
│  多 Agent 编排 + 路由配置                                      │
│  ┌──────────────────────────────────────────────────────┐    │
│  │ Routeset Editor                                        │    │
│  │  可视化编辑 RoutingRules:                              │    │
│  │                                                        │    │
│  │  customer message ──→ fast agent (quick reply)         │    │
│  │      │                                                 │    │
│  │      ├─ resolved? → ✅ done                            │    │
│  │      └─ unresolved? → slow agent (deep thinking)       │    │
│  │            │                                           │    │
│  │            ├─ resolved? → ✅ done                      │    │
│  │            └─ unresolved? → operator (human handoff)   │    │
│  │                                                        │    │
│  │  每个节点: agent URI + condition + 超时 + fallback     │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                               │
│  可编排的 agent 类型:                                          │
│    - 任何已注册的 agent flavor (cc, curl, echo, codex, ...)  │
│    - 条件路由: 基于关键词 / intent / confidence               │
│    - 超时 fallback                                            │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ ezagent_plugin_agent_debug  (Debug)                           │
│                                                               │
│  通用 Agent 调试器                                             │
│  ┌──────────────────────────────────────────────────────┐    │
│  │ Agent Debugger                                         │    │
│  │  给定 agent_uri + source(sandbox|release):             │    │
│  │  - Chat Test Tab: 实际对话测试                         │    │
│  │  - Source Tab: CLAUDE.md 完整合成                      │    │
│  │  - Diff Tab: sandbox vs release 对比                   │    │
│  │  - Context Tab: caps / workspace / lineage             │    │
│  └──────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ ezagent_plugin_agent_version  (CR/Version)                    │
│                                                               │
│  通用 Agent 版本管理                                           │
│  ┌──────────────────────────────────────────────────────┐    │
│  │ Agent Version Manager                                  │    │
│  │  给定 agent work-dir:                                  │    │
│  │  - sandbox_diff: 追踪文件变更                          │    │
│  │  - Lint: 可插拔的校验规则                              │    │
│  │  - Snapshot: sandbox → release/v<N>                   │    │
│  │  - Publish: _current symlink flip                     │    │
│  │  - Version Timeline: v1, v2, ...                      │    │
│  │  - Rollback: 回滚到历史版本                            │    │
│  └──────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│ ezagent_plugin_tenant  (Tenant)                               │
│                                                               │
│  租户/Workspace 管理                                          │
│  ┌──────────────────────────────────────────────────────┐    │
│  │ Tenant Manager                                         │    │
│  │  - 创建/删除租户                                       │    │
│  │  - 租户列表 + 状态总览                                 │    │
│  │  - 租户级 CapBAC 配置                                  │    │
│  │  - Operators 管理                                      │    │
│  └──────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

## AutoService 作为组合

```
AutoService = 以下 plugins 的组合 + AutoService 特有的 InitWizard:

  ezagent_plugin_tenant           ← 租户管理
  ezagent_plugin_agent_config     ← 编辑 Soul/Skill/KB/Slot/Prompt
  ezagent_plugin_agent_orchestrator ← Fast→Slow→Operator 路由编排
  ezagent_plugin_agent_debug      ← 测试 Customer Agent
  ezagent_plugin_agent_version    ← CR 版本管理 + Publish
  ezagent_plugin_autoservice      ← InitWizard + 垂直特有逻辑
```

## 可行性评估

### ✅ 可行且有利

| 方面 | 评估 |
|------|------|
| 架构一致性 | 符合 ezagent 的 plugin 哲学（P26: Plugin contract） |
| 复用性 | Orchestrator/Debug/Version 可被其他垂直复用 |
| 测试 | 每个 plugin 独立测试，减少集成复杂度 |
| 渐进迁移 | 可以逐个 plugin 提取，不破坏现有 AutoService |

### ⚠️ 需要注意

| 风险 | 缓解 |
|------|------|
| Plugin 间依赖 | 只依赖只读接口（TenantRuntime, SoulRenderer），不依赖内部实现 |
| 跨 plugin 导航流 | 统一的 Sidebar + 路由跳转保持一致体验 |
| Set Agent 的定制 | 通用 Config Editor 需要支持 AutoService 特有的文件类型 |
| CR 通用化改动大 | 先保持 `ezagent_plugin_cr`，逐步提取通用部分 |

### ❌ 不建议

| 项 | 原因 |
|------|------|
| CR 立即重写 | 当前 CR 工作正常，重写成本高，Phase 2 再评估 |
| Set Agent 完全通用化 | Soul/Skill/KB 的 UI 差异大（table grid vs textarea vs form），强行统一会降低体验 |

## 建议分步实施

```
Phase 1 (当前 P0-P1):
  ✅ 保持现有 plugin 结构
  ✅ Admin UI 页面继续在 autoservice/admin/ 下实现
  ✅ 不拆解，先完成功能闭环

Phase 2 (P1-P2):
  🆕 ezagent_plugin_agent_debug     ← 提取通用 Agent Debugger
  🆕 ezagent_plugin_agent_orchestrator ← 提取 Routeset 编排器
  🔄 AutoService 改为依赖这些 plugin

Phase 3 (P2-P3):
  🔄 ezagent_plugin_cr → ezagent_plugin_agent_version 通用化
  🔄 ezagent_plugin_agent_config 提取通用编辑器
  🔄 AutoService = 纯组合 + InitWizard

Phase 4 (P3+):
  🆕 Admin Session（会话式管理）
  🆕 Dream（自动化提案）
```

## 结论

**提案可行**。AutoService 拆解为 5 个通用 plugin + 1 个垂直 plugin 的架构是清晰的。

但建议 **Phase 1 先不拆**，等 Admin UI 功能闭环跑通后，Phase 2 再逐步提取通用 plugin。这样不会阻塞当前进度，且提取时已有足够的实现参考。
