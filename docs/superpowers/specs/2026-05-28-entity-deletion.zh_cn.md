# SPEC — Entity 删除生命周期（User / Agent / Worker）

**状态：** r1 — 草稿，待 codex 对抗性评审。2026-05-28。

**层级：** `Ezagent.Behavior.EntityDeletion`（新）位于 `apps/ezagent_core/`，per-entity-type `DeletionAdapter` 模块位于 `apps/ezagent_domain_identity/` (User), `apps/ezagent_domain_chat/` (Agent), `apps/ezagent_domain_external_mirror/` (Worker)。Admin LV 集成在 `apps/ezagent_plugin_liveview/`。

**触发：** Allen 2026-05-28 —— 观察到 `system/linyilun` 鬼魂用户问题（从 DB + snapshot 删除了但 Kind 持续 respawn，所以"已删除"用户仍能通过 LV / Feishu binding 路由 / dispatch 寻址）。Allen 的判断："是不是应该在 User.Deletion 时增加强制 logout（不仅仅是 LV，而是 runtime 层面）？"

**伴随：** `2026-05-28-entity-deletion.md`（按 `feedback_bilingual_docs_convention`）。

**前置记忆（load-bearing）：**
- `feedback_let_it_crash_no_workarounds` — 无 shim、无 dual-path。删除是原子 cascade-或-显式失败。无 "soft delete with flag"（§7 已讨论 + 拒绝）
- `feedback_north_star_plugin_isolation` — 通用 `EntityDeletion` Behavior 住 `ezagent_core`；per-entity-type cascade 逻辑住自己的 domain app via `DeletionAdapter` callback。未来 entity types (Worker, Cap, Template — 见 §3.6) 加 DeletionAdapter，从不碰 core
- `feedback_completion_requires_invariant_test` — merge gate 是不变量测试，证明已删除 entity 通过**每一个** routing surface 都不可达（KindRegistry / SpawnRegistry / LV mount / Feishu sender 解析 / dispatch）
- `feedback_uuid_is_canonical_identifier` — 按 URI 操作，不按 display name。Cascade 按 URI 清除所有引用
- `feedback_destructive_migration_anti_pattern` — production 上删 LIVE entity 需要 operator 知晓。SPEC 含 LV confirm-dialog 流程 + `mix ezagent.entity.delete` CLI gate

**父级 / 历史上下文：**
- `system/linyilun` 退役（2026-05-26）：暴露 gap 的局部删除。caps_json 清空、password_hash 设 nil、users 行删除、snapshot 删除 —— 但内存 Kind 通过 SpawnRegistry catch-all 持续 respawn。这是 DB 端 cleanup 不足的经验证据
- `2026-05-27-workspace-cap-based-visibility.md`：`Workspace.list_workspaces_for/2` 用 cap-membership 推导可见性。已删除用户也应该不可达 —— 他们 caps + memberships 一起删
- `2026-05-27-uri-canonicalization.md`：删除 cascade 用严格相等比较 URI；canonical URI form 让 cascade audit 可靠
- `feedback_register_lookup_key_parity`：entity spawn lookup (`SpawnRegistry.spawn → entity_spawn_fn → User.from_uri`) 和删除必须用**同一**身份 key。Key 分叉 = 鬼魂重生风险

---

## §1 问题陈述 — 没有删除生命周期

### 1.1 经验观察

Allen 2026-05-26 试图退役 `entity://user/system/linyilun`：

1. **DB 层（手动 SQL via Ecto）** — 已完成：
   - `users` 行：DELETED ✓
   - `entity_profiles` 行：DELETED ✓
   - `kind_snapshots` 行：DELETED ✓
   - `feishu_user_bindings` 重 bind 到 `system/admin` ✓（正确缓解）

2. **Runtime 层** — 遗留：
   - `KindRegistry.lookup("entity://user/system/linyilun")` 仍返回 `{:ok, pid}`
   - `Process.exit(pid, :brutal_kill)` → supervisor 重启 → 新 pid（仍活）
   - 删除 snapshot 后连续 3 次 brutal_kill：鬼魂在下次 lookup 还是活

3. **用户面症状**（Allen 2026-05-28 报告）：
   - "我还能以 system/linyilun 身份进 system 空间" — caller_uri 保持有效因为 Kind 响应
   - "切到 h2oslabs 仍显示 system/linyilun" — LV display name + cookie session identity 仍解析到鬼魂
   - 以 system/linyilun 身份 dispatch 得到 `chat.join` cap 拒绝 — caps_json 是 `[]`（正确）所以授权失败，但身份本身不是 "deleted"；是 "exists but has no permissions"

caps 清空 + DB 行删除的半删鬼魂是最坏的半删状态：**操作看起来像权限拒绝，不是 identity-not-found 错误**。Operator UX 暗示 "this user has no caps" 而不是 "this user does not exist"。

### 1.2 为什么这很关键（更大的契约）

**本代码库中身份的运行性定义是 "URI 通过 dispatch 可达"**。用户 URI 是 "deleted" 当且仅当：

- `Users.get_by_uri/1` 返回 `nil`
- `Ezagent.SpawnRegistry.spawn(uri)` 返回 `{:error, :not_found}`（NOT 自动创建）
- `Ezagent.KindRegistry.lookup(uri)` 返回 `:error`
- 没有 Kind 从任何路径 respawn（snapshot, workspace member, Feishu binding, LV session cookie, 来自另一个 agent reply 的 dispatch, …）
- `Workspace.list_workspaces_for/2` 把它们从每一个 caller 的 view 中排除
- 所有 URI 的历史引用 (sessions.owner_uri, caps.granted_by, audit rows) 要么指向 tombstone sentinel，要么作为历史记录留存（caller 选择；见 §3.7）

今天这些一项都没作为单元强制。每一项都是单独的 ad-hoc cleanup。Operator 尝试"删除用户"无 playbook；漏一步就有鬼魂。

### 1.3 为什么 "logout" 不够（Allen framing 的精细化）

Allen 的初始 framing："User.Deletion 时强制 runtime logout"。仅 logout 是**必要不充分**：

- Logout drop LV/web session cookie → caller_uri 对未来请求无效
- 但 Kind GenServer 仍活在内存 → 其它 dispatch 到这个 URI 仍成功
- Kind 在下次 lookup respawn → logout 需要无限重复

结构性修复是 `EntityDeletion`：原子的、审计的 cascade 操作，让 URI **结构性不可达**通过每一条 routing path —— logout 是诸多后果中的一个。

### 1.4 这条预防的 bug class

- "我删了用户 X 但他们还能发 Feishu 消息"（Feishu binding lookup 命中仍活的 Kind）
- "我删了用户 X 但他们 own 的 session 仍 route 给他们"（sessions.owner_uri 未清）
- "我删了 agent Y 但它的 cc bridge 还连着"（sidecar / PTY / bridge_registry entry 孤儿）
- "我删了 workspace 但里面的 agent 还在跑"（workspace 删除没 cascade 删 agent）
- "我把用户 X 从 workspace W 移走但他们仍能在 dropdown 看到 W"（caps 没 revoke）
- "罕见 boot 上，已删用户 X 复活"（snapshot reload race + 缺 tombstone）

六条全部今天可观察。EntityDeletion + DeletionAdapter 把每一条变成 regression test。

---

## §2 决策：**`Ezagent.Behavior.EntityDeletion` + per-entity-type `DeletionAdapter`**

单一 Behavior own 删除生命周期。Per-entity-type cascade 细节住在 `DeletionAdapter` 模块里，entity 的 domain 实现 + 注册（同 PR-G 的 `Ezagent.AgentBridge.Adapter` 模式）。

```elixir
defmodule Ezagent.Behavior.EntityDeletion do
  # Behavior actions: :delete (cap-gated, audited, cascade)
  # actions/0: [:delete]
  # required_caps/0: kind: :entity, behavior: __MODULE__, action: :delete
end

defmodule Ezagent.EntityDeletion.Adapter do
  # Behaviour callbacks every entity-type domain implements
  @callback entity_scheme() :: String.t()                 # "entity"
  @callback entity_subscheme() :: String.t()              # "user", "agent", "worker"
  @callback cascade_steps(URI.t(), %{caller: URI.t(), reason: String.t()}) ::
              [{step_name :: atom(), Ezagent.EntityDeletion.CascadeStep.t()}]
  @callback can_delete?(URI.t(), %{caller: URI.t()}) ::
              :ok | {:error, reason :: atom() | {atom(), term()}}
end
```

Behavior own **结构序列**：

1. **Pre-check** — `Adapter.can_delete?/2`（如"不能删 bootstrap admin"、"不能删 own workspace 的唯一成员"，per-adapter business rules）
2. **Runtime kill** — kill Kind GenServer，**在 SpawnRegistry 立 tombstone** 防 respawn（今天缺失的关键件；见 §3.3）
3. **Snapshot purge** — 删 `kind_snapshots` 行，audited
4. **DB cascade** — 按顺序运行 `Adapter.cascade_steps/2`（每步 idempotent + audited）
5. **Cross-reference scrub** — sessions.owner_uri / caps.granted_by / membership lists → tombstone sentinel
6. **Audit emission** — 单一 `entity.deleted` 事件附完整 cascade 摘要

每步记录到 `invocations` audit 表；从 operator 视角看，操作是原子的（成功 = 所有 cascade 步完成 AND tombstone 已立）。

字段名平行是有意的：本 SPEC 复用已建立的 Behavior 契约（`actions/0`, `required_caps/0`, `invoke/4`）+ PR-G 的 Adapter 模式，所以写新 entity type 的 plugin 作者跟着他们已知的 wire format 走。

---

## §3 语义 — `Behavior.EntityDeletion` 精确定义

### 3.1 输入

- `target_uri` — 被删 entity 的 `%URI{}`。必须 match 一个 `DeletionAdapter` 的 `entity_scheme/0 + entity_subscheme/0` filter（所以 `entity://user/...` 路由到 UserDeletionAdapter，`entity://agent/...` 路由到 AgentDeletionAdapter，等等）
- `caller_uri` — 执行删除的 operator。必须持 `:delete` cap（按 `required_caps/0`）。默认 admin-only；per-adapter policy 可以收窄（如 workspace admin 可以删自己 workspace 的用户，但不能跨 workspace；见 `Adapter.can_delete?/2`）
- `reason` — operator 提供的自由文本。存进 audit row。**非可选**

### 3.2 输出

```elixir
{:ok, %{
  deleted_uri: URI.t(),
  steps_completed: [step_name :: atom()],
  cascade_summary: %{deleted: integer(), scrubbed: integer(), tombstoned: integer()},
  audit_event_id: binary()
}}
| {:error, {:partial, %{
   step_failed: atom(),
   steps_completed: [atom()],
   reason: term(),
   recovery_hint: String.t()
}}}
| {:error, {:precheck_failed, term()}}
```

**三个返回 shape** 平行 Generator-Reconciler 三臂（`:ok | :partial | :error`）：

- `{:ok, summary}` — 每个 cascade step 完成，tombstone 已立，audit 已发
- `{:error, {:partial, _}}` — pre-check 通过、runtime kill 完成，但至少一个 DB cascade step 失败。Kind 死透 + tombstoned（不能复活），但 cross-reference scrub 不完整。`recovery_hint` 告诉 operator 哪步 + 怎么手动重跑
- `{:error, {:precheck_failed, _}}` — 没改任何 state。Adapter 的 `can_delete?/2` 拒绝（如 bootstrap admin 保护）

### 3.3 Step 2: Tombstone（缺失的结构性件）

**这是鬼魂 respawn 问题的结构性修复**。今天的 `SpawnRegistry` 没有 "this URI is deleted; 拒绝 spawn" 的概念。任何人在已删除 URI 上调 `SpawnRegistry.spawn(uri)` 都得到 fresh Kind，因为 entity spawn fn（chat / identity application 注册的）盲目地创建一个。

**EntityDeletion** 引入 `SpawnRegistry` tombstone：

```elixir
defmodule Ezagent.SpawnRegistry do
  # NEW API
  @spec tombstone(URI.t()) :: :ok
  def tombstone(uri), do: :ets.insert(@tombstone_table, {URI.to_string(uri), :tombstoned, DateTime.utc_now()})

  @spec tombstoned?(URI.t()) :: boolean()
  def tombstoned?(uri), do: :ets.member(@tombstone_table, URI.to_string(uri))

  # MODIFIED spawn — refuses tombstoned URIs
  def spawn(uri) do
    if tombstoned?(uri) do
      {:error, :tombstoned}
    else
      # ... existing scheme-dispatch logic ...
    end
  end
end
```

Tombstone 是个 one-bit "this URI is gone, 不要复活" flag。持久化在 ETS（`EzagentCore.EtsOwner` own，加入它已 own 的其它系统表）+ 同时镜像到新的 `entity_tombstones` DB 表，所以 tombstone 存活 BEAM 重启。

`Adapter.cascade_steps/2` 的 "kind_killed" 步骤在 brutal_kill 同原子块中写 ETS tombstone。`entity_tombstones` 行 write 在 kill 完成前 committed（这样即使 BEAM 在 delete 中途 crash，重启会看到 tombstone 拒绝 respawn）。

Tombstone 是 append-only —— 没有 `untombstone/1`。要 "复用"已删 URI，operator 必须在另一个 URI 创建**新** entity；已删的 URI 永久不可复用。这是 "immutable identity" 的结构性表亲（见 `feedback_uuid_is_canonical_identifier` 类比：URI 是 canonical identity；删除是永久的）。

### 3.4 Step 3: Snapshot purge

`kind_snapshots` 行删除。Trivial，**在 tombstone 之后**（这样如果 delete 中途失败，snapshot 指向虚空且 tombstone 拒绝 respawn —— fail-safe；鬼魂不能复活）。

### 3.5 Step 4: Adapter cascade

`Adapter.cascade_steps/2` 返回 `[{step_name, step_fn}]` 有序列表。Behavior 按顺序迭代，应用每步。每步幂等（重跑是 no-op 如果 state 已应用）。

**User cascade**（`Ezagent.Domain.Identity.UserDeletionAdapter.cascade_steps/2`）：

```
:revoke_all_caps               → Identity.revoke_all_caps(target_uri)
:drop_feishu_bindings          → delete feishu_user_bindings WHERE user_uri = target
:drop_entity_profile           → delete entity_profiles WHERE entity_uri = target
:drop_workspace_memberships    → Enum.each(workspaces, &Workspace.remove_member/2)
:drop_session_memberships      → Enum.each(sessions, &Chat.leave/2)
:scrub_owner_uri_to_tombstone  → UPDATE sessions SET owner_uri = '<deleted>' WHERE owner_uri = target
:delete_users_row              → Repo.delete(user)
```

**Agent cascade**（`Ezagent.Domain.Chat.AgentDeletionAdapter.cascade_steps/2`）：

```
:stop_sidecars                 → flavor-specific (cc bridge / codex PTY+app-server / curl ...)
:unbind_bridge_registry        → BridgeRegistry.unbind(agent_uri)
:drop_session_memberships      → Enum.each(sessions, &Chat.leave/2)
:scrub_mention_routing_rules   → RoutingRules.remove_by_target(agent_uri)
:revoke_agent_api_keys         → AgentApiKeys.revoke_all(agent_uri)
:drop_agent_lineage            → AgentLineage.delete(agent_uri)
:delete_workspace_template     → Workspace.remove_template/3 (if registered)
```

**Worker cascade**（`Ezagent.Domain.ExternalMirror.WorkerDeletionAdapter.cascade_steps/2`）：

```
:drop_external_mirror_bindings → delete external_mirror_bindings WHERE bound_by = target
:unsubscribe_session_publisher → Publisher.unsubscribe(target)
:terminate_adapter             → adapter_module.terminate(target)
```

每步在调用内部函数前记录到 `invocations` audit（这样部分失败的 audit 显示哪步炸了）。Audit row 的 `target` 字段是删除目标 URI；`caller` 是 operator；`action` 是 `entity.deleted.<step_name>`。

### 3.6 未来 entity types

新的 `entity://<subscheme>/<workspace>/<name>` 类型加 `DeletionAdapter` 实现；不改 `Behavior.EntityDeletion` 或 `SpawnRegistry`。例：

- `entity://tool/<workspace>/<name>` (假想 Tool entity)：adapter 清 ToolRegistry，drop permissions
- `entity://group/<workspace>/<name>` (假想 Group)：adapter cascade-removes from member lists

Behavior + Adapter 契约封闭；cascade 词汇开放。写新 domain 的 plugin 作者跟着他们已知的 AgentBridge.Adapter / Ezagent.Plugin shape 走。

### 3.7 Cross-reference scrub 策略 — tombstone-sentinel vs hard-delete

历史引用（audit rows、其它 Kind 提到已删 URI 的 snapshot、completed-session metadata），有两种清理策略：

**(a) Tombstone-sentinel**（默认）：rewrite 历史行中的 URI 为静态 `entity://tombstone/deleted/<original_subscheme>` sentinel。保留 audit trail（你能看到 user X 做过什么，只是不知道 WHO 他们是）。可逆-ish（sentinel 不带身份，但 row count 保留）

**(b) Hard-delete**：删除每条引用 URI 的历史行。DB 更轻。摧毁 audit 历史

Cascade adapter 按 cross-reference 表选 (a) 或 (b)。默认是 audit-bearing 表 (a)（`invocations`, `sessions.owner_uri`），非 audit 操作状态 (b)（membership lists, registry entries）

§10 OQ-3 提议加 config knob 翻转默认

### 3.8 边界情况 — bootstrap admin 保护

`entity://user/system/admin` 必须**不可删**。`UserDeletionAdapter.can_delete?/2` 硬编码：

```elixir
def can_delete?(%URI{} = uri, _ctx) do
  if URI.to_string(uri) == URI.to_string(Ezagent.Entity.User.admin_uri()) do
    {:error, :bootstrap_admin_undeletable}
  else
    :ok
  end
end
```

其它 adapter 可能加类似保护 URI（如 system orchestrator agent, system feishu binding）

### 3.9 边界情况 — 删除中的并发 dispatch

Step 1 (pre-check) 和 step 5 (cross-ref scrub) 之间，目标 Kind 在 mid-tear-down。这窗口的 dispatch 三种结果：

- 到死亡 Kind 的 dispatch：`GenServer.call` 阻塞到 terminate 完成，然后返回 `{:error, :noproc}`。可接受 —— caller 拿到 clean error
- 到 tombstoned-but-Kind-still-dying URI 的 dispatch：`SpawnRegistry.spawn` 在抵达死 Kind 前拒绝 `:tombstoned`。lookup-then-call 模式（大多数调用站点用）优雅处理 —— lookup 要么命中死亡 Kind（上述情况），要么 tombstone 拒绝 re-spawn
- 从已在 Kind mailbox 排队的消息：`Kind.Server.terminate/2` 按 OTP 语义自然 drain mailbox；排队消息得到 `{:error, :noproc}`

不需要 "transactional dispatch barrier"

### 3.10 边界情况 — operator 删除自己

调用 `Behavior.EntityDeletion.invoke(:delete, slice, %{target: their_own_uri})` 的 workspace admin 结构上没问题：action 跑到完成（因为他们的 caps 在 dispatch step 5.5 BEFORE cascade 剥去 evaluate），cascade 后他们的 session 在下次 refresh 时失效。LV 在 `users_live.ex` 用 confirm-dialog 警告拦截 self-delete（"你在删自己；你会被登出"）但不阻塞 —— operator 可能有合法理由

---

## §4 迁移方案

### 4.1 新代码（按 PR 顺序）

**PR-A（本 SPEC）→ PR-B Behavior + tombstone + UserDeletionAdapter**：

- `apps/ezagent_core/lib/ezagent/behavior/entity_deletion.ex`（新）— `Ezagent.Behavior.EntityDeletion`
- `apps/ezagent_core/lib/ezagent/entity_deletion/adapter.ex`（新）— adapter behaviour 契约
- `apps/ezagent_core/lib/ezagent/entity_deletion/adapter_registry.ex`（新）— flavor-style 注册器
- `apps/ezagent_core/lib/ezagent/entity_deletion/tombstone.ex`（新）— ETS + DB store
- `apps/ezagent_core/priv/repo/migrations/<timestamp>_entity_tombstones.exs`（新）— DB 表
- 改 `apps/ezagent_core/lib/ezagent/spawn_registry.ex` — 在 `spawn/1` 入口加 tombstone 检查
- `apps/ezagent_domain_identity/lib/ezagent_domain_identity/user_deletion_adapter.ex`（新）
- 测试：§5 invariant test + adapter 单测

**PR-C admin LV 集成**：

- 改 `users_live.ex` — 加 delete button + confirm dialog + reason input
- 改 `workspaces_live.ex` — 加 delete button（调 Workspace deletion → cascade 到所有成员 + 模板 + sessions）
- 改 `identities_live.ex` — 加 per-row delete action
- 改 `agent_detail_live.ex` — 在 agent detail 页加 delete action
- 加 `mix ezagent.entity.delete <uri> --reason "<reason>"` CLI 任务

**PR-D Agent + Worker DeletionAdapter**：

- `apps/ezagent_domain_chat/lib/ezagent/domain/chat/agent_deletion_adapter.ex`（新）
- `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/worker_deletion_adapter.ex`（新）
- Per-flavor sidecar 终止（cc / codex / echo / curl / np — 各 domain 加自己的 teardown）

### 4.2 向后兼容

**不**移除任何现有代码路径。`Users.delete/1` 语义**不变** —— 该路径仍存在作为 LOW-LEVEL DB-only delete，但会发 deprecation warning 建议用 `EntityDeletion.delete/3`。Migration 目标：follow-up PR-E 中标 `Users.delete/1` 为 `@deprecated` 并把 operator-facing 调用点路由通过 `EntityDeletion`

历史删除 backfill：`mix ezagent.entity.deletion.backfill_tombstones` mix 任务扫 `kind_snapshots` 找孤儿行（无对应 `users` 或 `agents` 行的 Kind URI）+ 立 tombstone。Deploy 时跑一次

### 4.3 无 production data 的 DB migration

`entity_tombstones` 是新表；没有 existing rows。无 destructive schema change。按 `feedback_destructive_migration_anti_pattern` 这是 operator-可跑无需 phx restart

### 4.4 协同 PR 序列

PR-A（本 SPEC）先 land。后续 PRs (B/C/D) dispatch 为独立 subagent 跑，各自独立 merge 带 codex review。Behavior + tombstone + UserDeletionAdapter (PR-B) 是**最小可发布**单元 —— 关闭 User 鬼魂问题。PR-C unlock operator-facing UI；PR-D 扩到 Agent + Worker

Plugin-isolation north-star 保留：PR-B+ 加契约；PR-C/D 插入。未来 entity types (Tool, Group, etc) 加 `DeletionAdapter` 不碰 core

---

## §5 Invariant 测试 — merge gate

按 `feedback_completion_requires_invariant_test`，本 SPEC "done" 当且仅当下列测试通过 AND 在任意 partial impl 上失败。

**文件：** `apps/ezagent_core/test/invariants/entity_deletion_invariant_test.exs`

**Setup** (DataCase, `async: false`)：

1. 创建非 admin User: `entity://user/team-alpha/test-deletable` via `Users.create/3`
2. 授予 caps + 加进 workspace + bind feishu open_id（这样 cross-references 存在）
3. Spawn User Kind: `SpawnRegistry.spawn("entity://user/team-alpha/test-deletable")` → `{:ok, pid}`
4. 调 `Behavior.EntityDeletion.invoke(:delete, slice, %{target: target, reason: "test"}, %{caller: admin_uri, caps: admin_caps})`

**断言**（任一违反则测试失败）：

| # | 断言 | 抓什么 |
|---|---|---|
| INV-1 | delete 后 `KindRegistry.lookup(target)` 立即返回 `:error` | Kind 未杀 → 鬼魂 route 仍活 |
| INV-2 | `SpawnRegistry.spawn(target)` 返回 `{:error, :tombstoned}`（NOT fresh pid） | Tombstone 缺失或在 spawn 边界未强制 → respawn 鬼魂 |
| INV-3 | `Users.get_by_uri(target)` 返回 `nil` | DB row leak |
| INV-4 | `Repo.get(EntityProfile, target_uri_str)` 返回 `nil` | Profile leak |
| INV-5 | `Repo.get(KindSnapshot, target_uri_str)` 返回 `nil` | Snapshot leak → 下次 boot 复活 |
| INV-6 | `Repo.all(from f in feishu_user_bindings, where f.user_uri == target)` 返回 `[]` | Feishu sender 解析 → 死亡用户 |
| INV-7 | 对每个 target 曾是成员的 workspace W：`target NOT IN W.member_uris` | Membership leak |
| INV-8 | 对每个 target 曾是成员的 session S：`target NOT IN S.members` | Session membership leak（可能在 `chat.join` 时 re-resurrect Kind） |
| INV-9 | `Workspace.list_workspaces_for(target, ...)` raises 或返回 `[]`（target 本身不存在了） | Visibility leak |
| INV-10 | 一条 audit row 存在：`invocations` 含 `action = "entity.deleted"`, `target = target_uri_str`, `caller = admin_uri_str`，AND 每个 cascade step 有 sub-row | Audit trail 不完整 |
| INV-11 | Kill BEAM (模拟重启 via `Application.stop(:ezagent_core) + Application.start(:ezagent_core)`)。重启后 INV-1 + INV-2 + INV-3 仍 hold | Tombstone DB 持久化失败 |
| INV-12 | `Behavior.EntityDeletion.invoke(:delete, ..., %{target: Ezagent.Entity.User.admin_uri()})` 返回 `{:error, :bootstrap_admin_undeletable}` | Bootstrap admin 保护缺失 |

**不能通过 partial impl** — 任意 cascade step 跳过，对应 INV fail：

- 跳 "kind_killed": INV-1 fail
- 跳 "tombstone install": INV-2 fail
- 跳 "snapshot purge": INV-5 + INV-11 fail
- 跳 "users row delete": INV-3 fail
- 跳 "feishu bindings drop": INV-6 fail
- 跳 "memberships drop": INV-7 + INV-8 fail
- 跳 "audit emit": INV-10 fail
- 跳 "bootstrap protection": INV-12 fail

测试在第一个 mismatch 失败，带消息标识 leak。Operator 看到 cascade-step name + leaked row

---

## §6 Plugin isolation 分析

按 `feedback_north_star_plugin_isolation`，架构 seam：

| 层 | 知道 | 不知道 |
|---|---|---|
| `ezagent_core` | `Behavior.EntityDeletion` action, `EntityDeletion.Adapter` behaviour, `SpawnRegistry.tombstone` | 怎么 drop Feishu binding、怎么终止 cc bridge、怎么 scrub session membership |
| `ezagent_domain_identity` | `UserDeletionAdapter` (User-specific cascade: caps, Feishu bindings, profile, memberships) | Agent / Worker cascade |
| `ezagent_domain_chat` | `AgentDeletionAdapter` (Agent-specific cascade: sidecars, bridge registry, lineage) | User / Worker cascade |
| `ezagent_plugin_codex` (等) | 怎么停**它的** sidecar | 怎么终止 cc 的 sidecar |
| `ezagent_plugin_liveview` | 怎么渲染 "Delete" button + confirm dialog | cascade 语义 |

未来 plugin 作者加新 entity type (如假想的 `entity://tool/...`) 写 `ToolDeletionAdapter` + 注册。**零** changes 到 `ezagent_core` 需要。这是 north-star 应用到删除生命周期

Tiebreaker test（"keeps plugin authors out of core"）：`Behavior.EntityDeletion` 把内部 cascade state 暴露给 plugin 代码吗？答：**否**。Behavior 调 `Adapter.cascade_steps/2` 拿回 `{step_name, function}` 列表。Plugin 的 adapter 永不看 deletion target 的 slice state，永不看其它 adapter 的 cascades，永不碰 SpawnRegistry tombstone（Behavior own 那个）。✅

---

## §7 权衡 / 拒绝过的方案

### 7.1 "Soft delete" 加 `deleted_at` flag（拒绝）

`users.deleted_at` column + filter 每个 read site 排除 `deleted_at != nil` 的 row

**拒绝**：这是身份删除的 canonical anti-pattern。每个 read site 负责 filter；漏一个 = 鬼魂复活。Discipline 问题等同于 `2026-05-27-workspace-cap-based-visibility.md` 拒绝的 `visible: false` 问题。Cap-based + tombstone 是结构性修复；flag-based 是 policy-based

### 7.2 "Hard delete + 无 tombstone，希望 SpawnRegistry 找不到 URI"（拒绝）

只删 row + snapshot。靠"没有 path 会试图 spawn 不存在 URI"

**拒绝**：经验上错。2026-05-26 system/linyilun 退役**做了这个** —— DB row 没了 snapshot 没了 —— Kind 仍 respawn。某条 path **在**试 spawn URI (LV mount, Feishu binding lookup, dispatch from another Kind)，entity spawn fn 高兴地创建一个 fresh Kind 因为 SpawnRegistry 层没有 "deleted" signal。Tombstone 就是缺失的 signal

### 7.3 "用 Ecto soft-delete 库"（拒绝）

拉 `ecto_soft_delete` 或类似

**拒绝**：这是 7.1 加库包装。库让 discipline **更易**维护但不改其根本脆弱。按 `feedback_let_it_crash_no_workarounds` 优选结构 over policy

### 7.4 "Per-entity-type Behavior"（拒绝）

`Behavior.UserDeletion`, `Behavior.AgentDeletion`, `Behavior.WorkerDeletion` —— 三个独立 Behaviors 并行结构

**拒绝**：复制结构序列 (pre-check / kill / tombstone / cascade / audit) 三遍。一个 Behavior 的 bug fix 需要三路复制。Adapter 模式 (一个 Behavior, 三个 adapters) 是结构性去重；per-entity Behaviors 是 policy-based

### 7.5 "不允许 runtime deletion；要求 operator-side DB script + phx restart"（拒绝）

今天的实际路径。Operator 做 SQL deletes + restart phx 让所有 in-memory state rebuild clean

**拒绝**：在 scale 1 工作（system/linyilun migration），在 scale N 失败。租户 routine 创建 + 删除 test users 不能容忍"每次 delete restart phx"。Production-grade SaaS 需要 runtime deletion。（且 Allen 显式要求 runtime fix。）

---

## §8 SPEC 交互 — 并行 specs

### 8.1 [2026-05-27-workspace-cap-based-visibility.md](2026-05-27-workspace-cap-based-visibility.md) (merged)

`Workspace.list_workspaces_for/2` 用 cap-membership 算可见性。EntityDeletion 的 cascade 撤用户 caps + 从 workspace.member_uris 移除。删除后 `list_workspaces_for/2` 对该 caller 返回 `[]`（cap-membership union 空）。INV-9 pin 这个交互

### 8.2 [2026-05-27-uri-canonicalization.md](2026-05-27-uri-canonicalization.md) (merged)

EntityDeletion 在每个 cascade step 比较 URI。所有 URI 解析用 `Ezagent.URI.parse!/1`；INV 断言用 `URI.to_string` 比较（canonical-form-invariant）。无新 URI-parsing path 引入；SPEC #431 的 chokepoint 已够

### 8.3 [2026-05-27-capability-action-axis.md](2026-05-27-capability-action-axis.md) (merged)

`Behavior.EntityDeletion` 的 `required_caps/0` 声明 `action: :delete` —— **具体**原子，不是 `:any`。按 SPEC §3.6.1(b)（wildcard-action-grant gate），意味着 cap grant flow 总是产 per-action cap，从不 `:any`。对齐 BindingPolicy fix (#426) 教训

### 8.4 [2026-05-27-reconciler-return-shape.md](2026-05-27-reconciler-return-shape.md) (merged)

EntityDeletion 返回 shape 是 `:ok | :partial | :error` —— 同三臂模式。`:partial` 这里意思是 "Kind killed + tombstoned (不可逆) but DB cascade 不完整"。Caller 同 Reconciler caller 那样处理 `:partial`：retry-the-cascade-steps OR escalate 到 operator。两个模式同一个 precedent ratified

### 8.5 [2026-05-27-agent-bridge-domain-extraction.md](2026-05-27-agent-bridge-domain-extraction.md) (merged)

Agent 删除需要终止 sidecars。PR-G 引入 `Ezagent.AgentBridge.Adapter.deliver/2` for outbound + `handle_client_event/3` for inbound。AgentDeletionAdapter 需要并行 "teardown" path。两个选项：

- 给 `Ezagent.AgentBridge.Adapter` 加 `teardown/1` callback —— flavor adapter 知道怎么停自己的 bridge
- 或 `AgentDeletionAdapter` 直接调已知 sidecar shutdown API (cc: `BridgeRegistry.unbind`, codex: `BridgeSidecar.stop`)

**推荐**：给 `Ezagent.AgentBridge.Adapter` 加 `teardown/1`（optional callback，默认 no-op）。PR-D 含此扩展；PR-G 现有 adapter 各加一个 `teardown/1` impl。Plugin isolation 保留

---

## §9 向后兼容 / 外部 API

### 9.1 Operator workflows

- `mix ezagent.user.create`（existing）—— 不变
- `mix ezagent.user.delete`（当前行为：low-level DB delete）—— **DEPRECATED**，会发 warning + 建议用 `mix ezagent.entity.delete`
- `mix ezagent.entity.delete <uri> --reason "<reason>"`（新）—— 调 `Behavior.EntityDeletion.invoke(:delete, ...)`

### 9.2 外部 callers

`external_mirror_bindings` 表的 `bound_by` 列引用 user URI。如果 bound 用户被删，binding 保留（不要因为 creator 被删就 cascade-delete bindings；binding 可能仍 active）。`scrub_owner_uri_to_tombstone` adapter step rewrite `bound_by` 到 tombstone sentinel —— audit trail 保留

无外部 HTTP / RPC / Phoenix.Channel 消费者今天 pattern-matches 身份删除行为；本 SPEC 引入**新** Phoenix.PubSub broadcast `{:entity_deleted, target_uri, reason}` for LV 消费者（admin dashboard 在用户被删时刷新）

### 9.3 Snapshots

引用已删 entity 的 pre-SPEC snapshots 不自动 rewrite。两个 path：

- (a) Kind boot 时，`Kind.Server.init/1` 检查 URI 是否 tombstoned → 拒绝 boot；snapshot row 然后孤儿（operator 可手动 purge later）
- (b) PR-A backfill mix 任务在 deploy 时扫孤儿 snapshots + 立 tombstones

(b) 是 pre-existing deployments 的推荐 path

### 9.4 Rollback plan

删除是**append-only**；没有 `undelete`。要 "恢复"误删 entity，operator 必须：

1. 手动从 `entity_tombstones` 移除 tombstone row（admin-only SQL）
2. 手动用同 URI 重新创建 user/agent/etc（fresh entity, 无历史连续性）

这是有意 friction。SPEC 大声 documented。LV confirm dialog 警告 "这是不可逆的；URI 不能复用"

---

## §10 留给 Allen 的 OQ

### OQ-1 — tombstone TTL?

`entity_tombstones` 默认永久。是否应该有 TTL 之后 URI 变可复用？默认：**否**（永久），按 `feedback_uuid_is_canonical_identifier` 类比（immutable identity）。Allen 可 per-tenant override 如果有真 tenant lifecycle 原因

### OQ-2 — cascade ordering: kill before or after DB delete?

今天提议：**先**杀 Kind，**然后** DB。理由：如果 Kind 活的时候 DB row 没了，`Users.get_by_uri/1` 返回 nil → caller 认为 user-not-found → caller 可能做与仍活 Kind 冲突的操作。**先**杀给了 dispatch 短暂 "Kind is dying" 窗口在 DB row 没之前 —— clean error (`{:error, :noproc}`)。Allen 确认？

### OQ-3 — cross-reference scrub 默认

§3.7 列了 tombstone-sentinel vs hard-delete。提议默认：audit-bearing rows (preserve history) tombstone-sentinel，操作 state hard-delete。Allen 确认？也可以 per-tenant config

### OQ-4 — Workspace 删除 cascade

如果 workspace 被删，workspace 内的所有 entity 怎么办？两个 policy：

- (a) 递归 cascade：删 workspace 前**删每个** entity in workspace。慢但完整
- (b) 非空拒绝：workspace 删除如果有 entity 残留则 error。Operator 必须先删 entities

提议默认：(b)。Workspace 删除带 `:workspace_not_empty, [<entity_uris>]` error。Allen 可 override 到 (a) for tenant offboarding scripts

### OQ-5 — admin LV self-delete

§3.10 允许 operator 删自己 with confirm dialog。是否应该允许 self-delete?有些系统要求 "second admin" 确认 self-deletion。默认：允许 with single confirm。Allen 可能想 gate 第二 admin 要求

### OQ-6 — Feishu binding cascade

User 被删时，他们 `feishu_user_bindings` rows 被 drop (§3.5)。但：production 中，用户 Feishu open_id 仍有效（他们仍在 Feishu 平台上）；他们的消息会开始 fail to resolve。Cascade 是否应尝试 re-bind open_id 到 fallback (如 `system/deleted` sentinel user) 这样消息得到 clean "user deleted" reply？默认：drop binding 完全；该 open_id 的 Feishu 消息在 routing 层得到 "no user found"（可接受 error）。Allen 可能想 sentinel-rebind

### OQ-7 — Tombstone DB 表 partitioning

`entity_tombstones` 一行 per 已删 URI。Scale 上 (如 10K tenants × 100 test users × delete cycles)，表增长。是否应按 workspace partition？默认：否，单表；性能问题时 revisit。Document for 未来 awareness

---

## §11 Codex 对抗性 review 问题 (for r1)

1. **Tombstone 在 boot 时强制**：`SpawnRegistry.spawn/1` 检查 tombstone。但已活在内存中的 Kind (e.g. 从 snapshot load) 在 tombstone 检查 BEFORE 被启动呢？PR-A backfill mix 任务应该处理 pre-existing deployments —— 验证 ordering：deploy 后 first boot **BEFORE** backfill，还是 boot-time check 在 URI tombstoned 时 abort Kind boot？哪个是结构性答案？

2. **Race: deletion 中 + 并发 spawn**：`Behavior.EntityDeletion` 杀 Kind 然后立 tombstone。两步之间，并发 `SpawnRegistry.spawn(uri)` 找到 Kind 死了 → spawn fn 创建 fresh Kind → tombstone 立失败因为 Kind 又活了。需要**先**立 tombstone (atomic with Kind kill via `SpawnRegistry.tombstone_and_kill/1`?)。验证 §3.3 提议序列是 race-free

3. **跨 Kind scrub during deletion**：scrub `sessions.owner_uri = deleted_user` 时，Session Kind 在内存活带 `owner_uri` 字段。两条 path：
   - Scrub DB row + 发 Session 消息更新 slice
   - 跳过 live Sessions 的 DB scrub（Session 的 terminate/snapshot 最终 mirror DB）
   
   哪个对？如果 DB 和 live slice 短暂分歧，其它 dispatch 在意吗？

4. **Adapter 能力边界**：`Adapter.can_delete?/2` 检查 per-adapter business rules。但在 `Behavior.EntityDeletion.invoke(:delete, ...)` 的 cap check 已经强制 `:delete` cap。这两个 check 是否冗余？或 `can_delete?/2` 严格是 cascade-feasibility check（如"这个用户拥有有未完成 work 的 session；拒绝"）？澄清契约

5. **Audit row 体积**：每个 cascade step 发一个 audit row。10 workspaces + 50 sessions 的 User，每次 delete 60+ audit rows。OK 吗，还是 Behavior 应发**单一** audit row 含 cascade results 列表？Tradeoff：per-step rows = granular debugging；single row = less audit noise。Allen 可能 prefer aggregated

6. **Workspace deletion cascade depth**：§10 OQ-4 覆盖 policy 选。For (b) refuse-if-non-empty，workspace delete 检查 `member_uris == []` + `session_templates == {}` + (任何其它 workspace-owned state)。验证 check 是**完整的** —— 列每个 workspace-owned 表

7. **Tombstone DB migration 安全性**：加 `entity_tombstones` 表是 forward-only schema change。验证：**没有**现有代码路径读或写这个表；它是真新的。Greenfield migration 安全

8. **Plugin isolation tiebreaker check**：未来 plugin 作者写 `Tool` entity with `entity://tool/...` URIs 加 `ToolDeletionAdapter`。Trace 他们需要知道 `ezagent_core` 什么。应该是：`Ezagent.Behavior.EntityDeletion`, `Ezagent.EntityDeletion.Adapter` behaviour, cascade-step 契约。**没别的**。验证他们不需要知道 SpawnRegistry tombstone 内部

9. **LV confirm dialog UX**：PR-C admin LV 加 "Delete" button。Confirm dialog 询问 reason。是否还应要求 operator **TYPE 被删的 URI**（与 GitHub 的 "type the repo name to delete" 平价）？加 friction 但防误点。提议默认：irreversible 操作 type-the-name confirmation。Allen 确认？

10. **bilingual sync**：en + zh_cn lockstep 强制 —— 验证 §3 / §5 / §10 content-aligned，§3.5 cascade 表在两个文件 byte-identical（表是结构性 meaningful，不是 narrative）

---

## §12 Rollback plan

本 SPEC 的 impl 是 forward-only（已应用 deletion 不可 rollback）。SPEC 本身 rollback（reverse PR-A → PR-B → ...）：

1. Reverse 顺序 revert merge commits
2. `entity_tombstones` 表保留在 DB（孤儿，没代码读它）
3. 依赖 `Behavior.EntityDeletion` 的 operator 失去访问；fallback 是手动 SQL delete
4. Pre-existing tombstones 保持惰性（无强制直到 SPEC re-applied）

DB schema 添加是非破坏性；任意时间 rollback 安全。Deletion 语义 LOSS 可接受（operator 回到今天的手动 workflow）

---

## Appendix A — 序列图

```
Operator (admin LV)
  │ 点击 "Delete" + 填 reason + confirm
  ▼
Behavior.EntityDeletion.invoke(:delete, slice, %{target, reason}, ctx)
  │ step 5.5 CapBAC: caller 有 :delete cap?  → audit "granted"
  │
  ▼ step 1
Adapter.can_delete?(target, ctx)
  │ adapter-specific pre-check
  ▼ :ok 或 {:error, :precheck_failed_reason}
  │
  ▼ step 2 (atomic)
SpawnRegistry.tombstone_and_kill(target):
  │   - INSERT entity_tombstones row
  │   - :ets.insert(@tombstone_table, ...)
  │   - Process.exit(Kind pid, :brutal_kill)
  │   - 等 terminate 完成
  ▼ tombstone 已立；Kind 死；respawn 拒绝
  │
  ▼ step 3
删 kind_snapshots row
  │
  ▼ step 4 (按 Adapter.cascade_steps/2 迭代)
for each {step_name, step_fn} in adapter steps:
  │   audit "cascade.<step_name>.start"
  │   step_fn.()
  │   audit "cascade.<step_name>.complete"
  ▼
  │
  ▼ step 5 (audit emit)
audit "entity.deleted" {target, caller, reason, steps_completed, summary}
  │
  ▼ step 6 (broadcast)
Phoenix.PubSub.broadcast(@entity_deletion_topic, {:entity_deleted, target, reason})
  │
  ▼
{:ok, %{deleted_uri, steps_completed, cascade_summary, audit_event_id}}
```

## Appendix B — 为什么本 SPEC 比其它长

引入两个新结构 (Behavior + Adapter + tombstone + cascade 契约)，每个有自己语义。§3.5 cascade 表是穷举；§5 INV 表 12 条 (每个 leak vector)；§10 OQ 列 7 个 (每个是真 product decision Allen 可 override)。比 URI canonicalization (1 结构 5 phases) 更多表面 —— 因此长

## Appendix C — 作者推荐

PR-A (本 SPEC) + PR-B (Behavior + UserDeletionAdapter) 作为**一对** land。PR-C (admin LV) + PR-D (Agent + Worker adapters) 可并行 —— 它们独立。4-PR sequence 按 cap-vis / URI-canonical 节奏不超过 1.5 天

2026-05-28 surfaced 的 `system/linyilun` 鬼魂是经验动机。PR-B land 后 + operator 跑 backfill mix 任务，鬼魂结构性不可能

🤖 Generated with [Claude Code](https://claude.com/claude-code)
