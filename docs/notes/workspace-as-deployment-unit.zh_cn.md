# Workspace = 部署单元 (Deployment Unit)

> **状态 (2026-05-20)**：描述性 + roadmap 混合。既说明 `workspace://` 今天是什么，也说明我们要把它带到哪里。从头读到尾。

## TL;DR

**workspace 是 ezagent 的部署单元 (deployment unit)。**

- **今天 (Phase 8c)**：workspace 是 session 所属的配置 bundle —— members、session templates、routing rules。Session 继承 workspace 的上下文用于路由；entity (users, agents) 仍是全局的。
- **目标 (Phase 9+)**：workspace 成为完整的隔离边界 —— per-workspace 的 entity、per-workspace 的 capability、跨 workspace 的 dispatch 策略。部署单元同时也是 auth/隔离单元。

这份文档替代散落在各 phase notes 中对 "workspace" 的部分描述。本仓库内 **"部署单元 (deployment unit)"** 是首选术语；"tenant" 和 "namespace" 是合理的英文同义词，意思等价。

---

## workspace 今天是什么

具体来说，一个 workspace 是 [`Ezagent.Workspace.Store`][workspace-store] 里的一条记录，含以下字段：

| 字段 | 含义 |
|---|---|
| `name` | 短字符串 (`default`、`team-alpha`) |
| `uri`  | 计算字段：`workspace://<name>` |
| `members` | 允许参与该 workspace session 的 entity URI 列表 |
| `session_templates` | `<template_name>` → template config 的 map |
| `routing_rules` | 该 workspace 内的 mention / session-receive 规则 |

Session 通过 [`Ezagent.Entity.Session.spawn_from_template/2`][session-spawn] 或 `EzagentDomainInstanceMessage.create_session/2` 创建。流程：

1. 把 Session Kind spawn 进 KindRegistry
2. 通过 [`Ezagent.WorkspaceRegistry.bind/2`][workspace-registry] 绑定到一个 workspace —— 这是 **运行时查询表**（"这个 session 归哪个 workspace?"）
3. 把创建者作为成员 join
4. 来自绑定 workspace 的 templates 和 routing rules 在后续 dispatch 中生效

`workspace://default` 是创建时没有显式指定 workspace 的 session 的隐式归属者。它 **已经持久化**（Phase 8c PR-M 加了启动时的 `Ezagent.Workspace.create("default", %{})` idempotent seed），所以它和其它 workspace 一样出现在 `/workspaces` 中。

**workspace 今天已经隔离了什么**：

- ✅ Session 归属（`WorkspaceRegistry` 1-to-many session→workspace）
- ✅ Routing rules（每个 workspace 有自己的 MentionRouting / SessionRouting 表）
- ✅ Session templates（每个 workspace 自己声明能 spawn 哪种 session）
- ✅ Workspace 成员列表（声明的参与者）

**workspace 今天还没隔离什么**（30% 的 gap）：

- ❌ Entity（`entity://user/admin` 是全局的，不是 `entity://workspace/team-alpha/user/admin`）
- ❌ Capability（cap grant 是全局 per-entity 的，没按 workspace scoping）
- ❌ 跨 workspace dispatch（没有强制让 workspace A 的 session 不能 dispatch 到 workspace B 的 entity）
- ❌ 持久化隔离（一个共享 SQLite DB；没有 per-workspace tablespace）

## 为什么叫 "部署单元 (deployment unit)"

一个 workspace 是你**可以独立部署**的最小粒度。两个 workspace 可以：

- 跑在不同主机上（multi-tenant SaaS）—— 不同 DB、不同 Phoenix endpoint、不同 routing rules
- 同主机共存（单机 operator 跑多个环境 —— staging / prod / demo）—— 独立 workspace 记录，共享 backend
- 独立备份 / 恢复 / 迁移 —— workspace 导出 bundle 包含 `members + session_templates + routing_rules + sessions + messages`

叫它 "tenant" 对单机 operator 部署偏 SaaS-y；叫 "namespace" 偏 Kubernetes-y。**"部署单元"** 抓住的是运维属性：这是你 scale、隔离、整体运维的最小一致粒度。

## 为什么 30% gap 今天能接受

剩下的 tenant-ness（per-workspace entity scoping + caps + dispatch enforcement）是 **Phase 9 的工作**。今天的 gap 能接受是因为：

1. **单 operator 部署占多数**。大部分用户跑一个 ezagent 实例、一个 workspace。这 30% gap 对他们不可见。
2. **per-workspace entity scoping 是个困难的分布式系统问题**。它涉及 URI scheme 设计、dispatch resolution、snapshot keyspace、auth token。Phase 8c 不是干这个的地方。
3. **现有 70% 是基础**。Routing scoping (PR #146-149) 和 session-to-workspace binding (PR-M) 是更难的部分。后续加 entity scoping 是 backend-only 改动 —— 不用重做 UI。

## 30% 最终会长什么样（roadmap）

下面是草图，不是承诺。Phase 9 SPEC 会细化。

### Per-workspace entity URI

讨论中有两个方案：

**Option A —— workspace 名作为 path 段**（Allen 2026-05-20 偏好的形状）：
```
entity://user/team-alpha/admin
entity://user/team-beta/admin
entity://agent/team-alpha/cc_demo
```
Scheme 保持 `entity://`；host 保持 kind (`user` / `agent`)；workspace 名是 **第一个 path 段**，原本的 entity 名顺位变成第二段。
- ✅ 相对今天的 `entity://user/admin` delta 最小 —— 迁移就是 "在 path 前面插入 workspace 名"
- ✅ 符合 agent flavor-prefix convention 的精神（path 按 qualifier 分层，不是 authority 分层）
- ✅ 全局唯一，self-describing
- ❌ 现有 URI 需要迁移 pass（path layout 变了）
- ❌ Snapshot key 改变；entity rehydrate 逻辑要碰每个 domain

System-scope（跨 workspace）的 entity 需要一个 sentinel path 段 —— 大概是 `_system`，或者直接用 legacy 两段形式（`entity://user/admin` 继续表示隐式 `workspace://default`）。决策推到 Phase 9 SPEC。

**Option B —— 在 dispatch envelope 里携带 workspace 上下文**：
```
URI 不变：entity://user/admin
Dispatch ctx: %{workspace: workspace://team-alpha, ...}
```
- ✅ 现有 URI 直接 work
- ✅ 同一个 entity 可以同时是多个 workspace 的 member（entity sharing 是有意的）
- ❌ Auth + cap lookup 变成 2-key: (entity, workspace)
- ❌ 如果 dispatch ctx 没 validate，跨 workspace 数据泄漏风险

Option A 更接近 "URI 告诉你一切"（没有隐藏的 ambient 上下文，不会忘）。Option B 更接近 routing rule 今天的工作方式（URI 跟 workspace 无关；rule 自己是 workspace-scoped）。Phase 9 SPEC 会选一个 —— 现在倾向 Option A 因为 explicitness。

### Per-workspace 的 capability grant

今天：`Ezagent.Identity.grant_cap(entity_uri, cap, granter)` —— 单表，没 workspace 维度。

明天：`Ezagent.Identity.grant_cap(entity_uri, cap, granter, workspace: ws_uri)` —— cap 限定在它适用的 workspace 内。在 workspace A 是 admin 的人在 workspace B 里就是普通 member。

### 跨 workspace 的 dispatch 策略

今天：dispatch.ex resolve target → 查 cap → fire。没有 workspace 检查。

明天：插入一个 CapBAC 风格的 workspace-isolation 检查："caller 的 workspace 必须 = target 的 workspace，OR caller 有 `cross-workspace:dispatch` cap"。大部分 dispatch 是 intra-workspace；少见的 cross-workspace 场景显式授权（比如系统管理 agent 跨所有 workspace 工作）。

### Tenant-aware auth

今天：登录只决定 `current_entity_uri`。LV 的 `live_session :require_entity` on_mount 设置这个 assign。

明天：登录决定 `current_entity_uri` + `current_workspace_uri`。avatar dropdown 的 workspace selector (PR-L) 变成 workspace 上下文的切换器 —— dispatch 上下文自动 pick up 当前 workspace。

---

## 对当前开发的实用 implication

**现在 (Phase 8c) 写新代码时**，遵循下面这些规则，让 Phase 9 transition 是机械的而非架构性的：

1. **Session 永远走 `Ezagent.Entity.Session.spawn_from_template/2`**（或包装它的 `EzagentDomainInstanceMessage.create_session/2`）。永远不要直接 spawn 进 `EzagentDomainInstanceMessage.SessionSupervisor`。这保证 workspace 绑定。
2. **Entity (User / Agent) 永远走标准 create API**（`Ezagent.Users.create/3`、`Ezagent.SpawnRegistry.spawn/1` + `Identity.grant_cap`）。永远别用 static supervisor child。这是 PR-M 干的清理。
3. **Cap 永远通过 `Ezagent.Identity.grant_cap/3` 授权**，永远别手动插入。当 per-workspace cap 落地时，这个 API 多一个可选 workspace 参数，调用点保持向后兼容。
4. **Routing rules 永远 per-workspace**（每条 rule 有 `workspace_uri` 字段）。PR #146-149 之后已经如此。
5. **UI 永远在左上角显示 workspace 上下文**（Phase 8c PR-L）。当 active workspace 成为 server-side 概念 (Phase 9)，这个 dropdown 就成了真正的上下文切换器。

这 5 条规则是让 70%→100% Phase 9 transition 安全的 **invariant**。记忆 `feedback_let_it_crash_no_workarounds` 适用：别加 per-call 的 workspace shim，做结构性 fix。

---

## 参考

- **Phase 8c 中触及 workspace 概念的 PR**：
  - PR-E (`1e39b48`)：WorkspaceRegistry `default_workspace_uri/0` + sessions_have_workspace_test invariant
  - PR-F (`563c458`)：左上 `ezagent / <workspace-name>` 显示
  - PR-L (`7f38ef8` + `59ab87d`)：workspace dropdown + Manage workspaces…
  - PR-M (`d7cc887`)：3 个 built-in entity 创建标准化（催生这份文档的工作）

- **代码**：
  - [`Ezagent.WorkspaceRegistry`][workspace-registry] —— session↔workspace ETS 绑定
  - [`Ezagent.Workspace.Store`][workspace-store] —— DB 持久化
  - [`Ezagent.Entity.Session.spawn_from_template/2`][session-spawn] —— canonical session 创建器
  - `EzagentDomainInstanceMessage.create_session/2` —— 面向用户的 facade
  - `apps/ezagent_core/test/invariants/sessions_have_workspace_test.exs` —— 强制 workspace 绑定的 invariant

- **术语表**：
  - **Workspace** = 部署单元（本文档）
  - **Session** = 一次对话，绑定到一个 workspace
  - **Entity** = 参与者 (user 或 agent)；今天全局，Phase 9 将 per-workspace scoping
  - **Capability (cap)** = (kind, action) pair 上的权限授权；今天 per-entity，Phase 9 加 per-workspace 维度

[workspace-store]: ../../apps/ezagent_domain_workspace/lib/ezagent/workspace/store.ex
[workspace-registry]: ../../apps/ezagent_core/lib/ezagent/workspace_registry.ex
[session-spawn]: ../../apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex
