# SPEC — Entity 删除生命周期（User / Agent / Worker）

**状态：** r2 — codex r1 评审（REJECT）已应对：6 个 critical blocker + 3 个 nit。2026-05-28。

**r2 变更（codex r1 verdict REJECT —— 6 个 blocker + 3 个 nit 解决）：**

- **B1（CRIT —— 多边界 tombstone 强制）：** r1 §3.3 + PR-B 仅在 `Ezagent.SpawnRegistry.spawn/1` 守 tombstone。但生产中还有直接 `Ezagent.Kind.spawn/2`（`apps/ezagent_core/lib/ezagent/kind.ex:293-308`）+ `Ezagent.ExternalMirror.WorkerSpawn`（`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/worker_spawn.ex:72-113`）这些路径走 `DynamicSupervisor.start_child/2` 直接构 child spec —— 绕开 SpawnRegistry。Boot 路径也没解决：`Ezagent.Kind.Server.init/1`（`apps/ezagent_core/lib/ezagent/kind/server.ex:103-130`）load slice state 时未查 tombstone。**修复：** §3.3 + §4.1 重写，在 **三个** 边界做强制：(1) `Ezagent.Kind.Server.init/1`（唯一的"每个 Kind 启动必经"chokepoint）—— source-of-truth 检查；(2) `Ezagent.Kind.spawn/2`（在 `DynamicSupervisor.start_child` 前的预检）；(3) `Ezagent.SpawnRegistry.spawn/1`（scheme-dispatch 前预检）。Tombstone ETS 表在 `EzagentCore.Application.start/2` 中 **早于** `KindSupervisor` 启动前 load。Backfill mix 任务降级为 DISCOVERY/CLEANUP（不是 source of truth），见 §9.3。
- **B2（CRIT —— 原子 primitive 替代 race-prone 序列）：** r1 对 kill-vs-tombstone 顺序有 **三处** 互相矛盾（§3 :110-112 sequential、§10 OQ-2 :495-498 "kill FIRST then DB"、§11 q2 :528-530 "kills the Kind THEN installs the tombstone"）；只 Appendix A 显示 `SpawnRegistry.tombstone_and_kill/1` 原子。**修复：** `Ezagent.SpawnRegistry.tombstone_and_kill/1` 提升为 §3.3 的 **唯一** normative primitive，附原子性契约：tombstone DB 行 + ETS 行 + Kind brutal_kill 一次同步完成；部分失败时 rollback 纪律。OQ-2 删除（被原子性解决，移到 §10 RESOLVED）。§11 q2 改成攻击新 primitive，不再攻击已过时的 race。
- **B3（CRIT —— Session owner scrub 指向不存在的 DB 表）：** r1 §3.5 写 `:scrub_owner_uri_to_tombstone → UPDATE sessions SET owner_uri = '<deleted>' WHERE owner_uri = target`。但 **没有 `sessions` DB 表** —— Session `owner_uri` 只活在 LIVE `:chat` slice（`apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:132-145`），并通过标准 `kind_snapshots` 机制持久化。已删用户的 URI 仍会驱动 `data_owner/1`（`chat.ex:1318-1336`），意味着被删 owner 仍能授权 grant。**修复：** cascade step 现在 dispatch 新的 `Behavior.Chat.invoke(:scrub_owner, ...)` action，对每个 live slice 的 `owner_uri == target_user_uri` 的 Session Kind 执行，内存内 mutate slice 并通过 Kind 既有 snapshot 策略持久化。新 cascade step `:scrub_session_owner_uri`。新 INV-13 断言 User 删除后 `data_owner/1` 对原 owned session 返回 `:no_owner`。
- **B4（CRIT —— workspace 删除范围矛盾）：** r1 PR-C 加 `workspaces_live.ex` delete 按钮，但 `workspace://<name>` URI 不能走 `entity_scheme/0 + entity_subscheme/0` Adapter dispatch（scheme 完全不同）。**修复：** Workspace 删除 **排除** 出本 SPEC 范围。PR-C 项删除。§10 OQ-4 标 RESOLVED（out of scope），附前瞻 note 指向未来独立的 Workspace lifecycle SPEC。理由：workspace 删除结构上完全不同（cascade-delete 所有成员 + 模板 + sessions + bindings；比单 URI entity 删除复杂得多），应单独 SPEC 而非借道本 Adapter 机制。
- **B5（CRIT —— Worker cascade `bound_by` 列错位）：** r1 §3.5 Worker cascade 是 `:drop_external_mirror_bindings → delete external_mirror_bindings WHERE bound_by = target`，其中 target 是 worker URI。但 `bound_by` 记的是 **创建用户 URI**（`apps/ezagent_core/priv/repo/migrations/20260607000000_pr_em_3_external_mirror_bindings.exs:54`），而 Worker URI 是从 `(session_uri, adapter_id, target_id)` 通过 `Ezagent.ExternalMirror.WorkerSpawn.worker_uri_for/3`（`worker_spawn.ex:217-230`）派生 —— **不存在表里**。这查询对任何 Worker 删除都会匹配 0 行。**修复：** 按 `feedback_let_it_crash_no_workarounds`（结构 over policy），向 `external_mirror_bindings` 加持久化 `worker_uri` 列（forward-only schema migration；新列；`:bind` action body 在写入时填充；同 PR-A backfill mix 任务回填）。Worker cascade 现用 `WHERE worker_uri = target` 直接查。Bonus：`bound_by` 不变 —— 仍记 creator identity for audit（User cascade 单独 scrub）。
- **B6（CRIT —— entity_tokens 未在 cascade 里）：** r1 完全漏了 `entity_tokens` 表。Token 行按 `entity_uri` 持久化（`apps/ezagent_core/priv/repo/migrations/20260525000000_pr142_entity_tokens.exs:24-35`）；`Ezagent.Entity.Token.verify/2`（`apps/ezagent_domain_identity/lib/ezagent/entity/token.ex:155-181`）只看 token 行存在不存在 —— principal entity 是否存在不查。User 或 Agent 删除后，残留 token 仍能认证鬼魂。**修复：** `:revoke_entity_tokens → delete entity_tokens WHERE entity_uri = target` 加到 User cascade **和** Agent cascade（§3.5）。新 INV-14：`Token.verify/2` 对 tombstoned URI 的 token 即使行未删也拒绝（defense-in-depth）。
- **N1（Nit —— SpawnRegistry 公共 API 泄露）：** r1 §3.3 公开了 `tombstone/1` 和 `tombstone_and_kill/1` 两个。按 plugin isolation north-star，adapter 不应直接碰 tombstone。**修复：** `tombstone/1` 改成 private（仅内部原子 primitive 用）；`tombstone_and_kill/1` 是 **唯一** 公开 primitive。`tombstoned?/1` 保持公开（只读 check，给 Kind.Server.init/1 用）。
- **N2（Nit —— audit row trace_id parent grouping）：** r1 §3.5 说 cascade 每步发 audit row 但没说 trace 关联。现有 `invocations` 表（`apps/ezagent_core/priv/repo/migrations/20260515160000_phase1_audit_dlq_snapshots.exs:5-20`）已有 `trace_id`。**修复：** §3.5 显式说所有 cascade sub-row 共享 parent `entity.deleted` row 的 `trace_id`，audit consumer 可按 trace group。无 schema change。
- **N3（Nit —— bilingual sync）：** EN + ZH 在 r1 已经核对一致。r2 改动同步到 `.zh_cn.md`。

**r1 变更（保留）：** 初版草稿；问题陈述 + Behavior + Adapter + tombstone + cascade + INV 表。

**层级：** `Ezagent.Behavior.EntityDeletion`（新）位于 `apps/ezagent_core/`，per-entity-type `DeletionAdapter` 模块位于 `apps/ezagent_domain_identity/` (User), `apps/ezagent_domain_chat/` (Agent), `apps/ezagent_domain_external_mirror/` (Worker)。Admin LV 集成在 `apps/ezagent_plugin_liveview/`。

**触发：** Allen 2026-05-28 —— 观察到 `system/linyilun` 鬼魂用户问题（从 DB + snapshot 删除了但 Kind 持续 respawn，所以"已删除"用户仍能通过 LV / Feishu binding 路由 / dispatch 寻址）。Allen 的判断："是不是应该在 User.Deletion 时增加强制 logout（不仅仅是 LV，而是 runtime 层面）？"

**伴随：** `2026-05-28-entity-deletion.md`（按 `feedback_bilingual_docs_convention`）。

**前置记忆（load-bearing）：**
- `feedback_let_it_crash_no_workarounds` —— 无 shim、无 dual-path。删除是原子 cascade-或-显式失败。无 "soft delete with flag"（§7 已讨论 + 拒绝）。r2 B5 按本原则选结构性列添加，而非 lookup hack。
- `feedback_north_star_plugin_isolation` —— 通用 `EntityDeletion` Behavior 住 `ezagent_core`；per-entity-type cascade 逻辑住自己的 domain app via `DeletionAdapter` callback。未来 entity types (Worker, Cap, Template —— 见 §3.6) 加 DeletionAdapter，从不碰 core。
- `feedback_completion_requires_invariant_test` —— merge gate 是不变量测试，证明已删除 entity 通过 **每一个** routing surface 都不可达（KindRegistry / SpawnRegistry / LV mount / Feishu sender 解析 / dispatch）。r2 加 INV-13 + INV-14。
- `feedback_uuid_is_canonical_identifier` —— 按 URI 操作，不按 display name。Cascade 按 URI 清除所有引用。
- `feedback_destructive_migration_anti_pattern` —— production 上删 LIVE entity 需要 operator 知晓。SPEC 含 LV confirm-dialog 流程 + `mix ezagent.entity.delete` CLI gate。

**父级 / 历史上下文：**
- `system/linyilun` 退役（2026-05-26）：暴露 gap 的局部删除。caps_json 清空、password_hash 设 nil、users 行删除、snapshot 删除 —— 但内存 Kind 通过 SpawnRegistry catch-all 持续 respawn。这是 DB 端 cleanup 不足的经验证据。
- `2026-05-27-workspace-cap-based-visibility.md`：`Workspace.list_workspaces_for/2` 用 cap-membership 推导可见性。已删除用户也应该不可达 —— 他们 caps + memberships 一起删。
- `2026-05-27-uri-canonicalization.md`：删除 cascade 用严格相等比较 URI；canonical URI form 让 cascade audit 可靠。
- `feedback_register_lookup_key_parity`：entity spawn lookup (`SpawnRegistry.spawn → entity_spawn_fn → User.from_uri`) 和删除必须用 **同一** 身份 key。Key 分叉 = 鬼魂重生风险。

---

## §1 问题陈述 —— 没有删除生命周期

### 1.1 经验观察

Allen 2026-05-26 试图退役 `entity://user/system/linyilun`：

1. **DB 层（手动 SQL via Ecto）** —— 已完成：
   - `users` 行：DELETED ✓
   - `entity_profiles` 行：DELETED ✓
   - `kind_snapshots` 行：DELETED ✓
   - `feishu_user_bindings` 重 bind 到 `system/admin` ✓（正确缓解）

2. **Runtime 层** —— 遗留：
   - `KindRegistry.lookup("entity://user/system/linyilun")` 仍返回 `{:ok, pid}`
   - `Process.exit(pid, :brutal_kill)` → supervisor 重启 → 新 pid（仍活）
   - 删除 snapshot 后连续 3 次 brutal_kill：鬼魂在下次 lookup 还是活

3. **用户面症状**（Allen 2026-05-28 报告）：
   - "我还能以 system/linyilun 身份进 system 空间" —— caller_uri 保持有效因为 Kind 响应
   - "切到 h2oslabs 仍显示 system/linyilun" —— LV display name + cookie session identity 仍解析到鬼魂
   - 以 system/linyilun 身份 dispatch 得到 `chat.join` cap 拒绝 —— caps_json 是 `[]`（正确）所以授权失败，但身份本身不是 "deleted"；是 "exists but has no permissions"

caps 清空 + DB 行删除的半删鬼魂是最坏的半删状态：**操作看起来像权限拒绝，不是 identity-not-found 错误**。Operator UX 暗示 "this user has no caps" 而不是 "this user does not exist"。

### 1.2 为什么这很关键（更大的契约）

**本代码库中身份的运行性定义是 "URI 通过 dispatch 可达"**。用户 URI 是 "deleted" 当且仅当：

- `Users.get_by_uri/1` 返回 `nil`
- `Ezagent.SpawnRegistry.spawn(uri)` 返回 `{:error, :tombstoned}`（NOT 自动创建）
- `Ezagent.Kind.spawn(kind_module, %{uri: uri, ...})` 返回 `{:error, :tombstoned}`（**另**一个 spawn 边界）
- `Ezagent.Kind.Server.init/1` 拒绝 boot（最后一道防线，Kind 启动的 chokepoint）
- `Ezagent.KindRegistry.lookup(uri)` 返回 `:error`
- 没有 Kind 从任何路径 respawn（snapshot, workspace member, Feishu binding, LV session cookie, 来自另一个 agent reply 的 dispatch, adapter reconcile, …）
- `Workspace.list_workspaces_for/2` 把它们从每一个 caller 的 view 中排除
- 所有 URI 的历史引用（live slice 的 sessions owner_uri, caps.granted_by, audit rows）要么指向 tombstone sentinel，要么被 scrub（见 §3.7）
- `Token.verify/2` 对每个 `entity_uri` tombstoned 的 token 都拒绝（defense in depth）

今天这些一项都没作为单元强制。每一项都是单独的 ad-hoc cleanup。Operator 尝试"删除用户"无 playbook；漏一步就有鬼魂。

### 1.3 为什么 "logout" 不够（Allen framing 的精细化）

Allen 的初始 framing："User.Deletion 时强制 runtime logout"。仅 logout 是 **必要不充分**：

- Logout drop LV/web session cookie → caller_uri 对未来请求无效
- 但 Kind GenServer 仍活在内存 → 其它 dispatch 到这个 URI 仍成功
- Kind 在下次 lookup respawn → logout 需要无限重复

结构性修复是 `EntityDeletion`：原子的、审计的 cascade 操作，让 URI **结构性不可达**通过每一条 routing path —— logout 是诸多后果中的一个。

### 1.4 这条预防的 bug class

- "我删了用户 X 但他们还能发 Feishu 消息"（Feishu binding lookup 命中仍活的 Kind）
- "我删了用户 X 但他们 own 的 session 仍 route 给他们"（sessions slice owner_uri 未清 → Chat.data_owner 返回死 URI）
- "我删了用户 X 但他们老 cli token 仍能认证"（entity_tokens 行残留）
- "我删了 agent Y 但它的 cc bridge 还连着"（sidecar / PTY / bridge_registry entry 孤儿）
- "我把用户 X 从 workspace W 移走但他们仍能在 dropdown 看到 W"（caps 没 revoke）
- "罕见 boot 上，已删用户 X 复活"（snapshot reload race + 缺 tombstone）
- "我删了 Worker W 但 external_mirror_bindings 仍让 adapter reconcile spawn 一个新 Worker"（cascade 列错位 —— r1 bug）

七条全部今天可观察。EntityDeletion + DeletionAdapter 把每一条变成 regression test。

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

1. **Pre-check** —— `Adapter.can_delete?/2`（如"不能删 bootstrap admin"、"不能删 own workspace 的唯一成员"，per-adapter business rules）
2. **原子 tombstone-and-kill** —— `Ezagent.SpawnRegistry.tombstone_and_kill/1`（新的唯一 normative primitive —— 见 §3.3）；一次同步操作完成 DB + ETS tombstone 立 + Kind brutal_kill
3. **Snapshot purge** —— 删 `kind_snapshots` 行，audited
4. **DB cascade** —— 按顺序运行 `Adapter.cascade_steps/2`（每步幂等 + audited，共享 parent trace_id）
5. **Cross-reference scrub** —— sessions slice owner_uri / caps.granted_by / membership lists → tombstone sentinel（live-Kind dispatch 适用时；见 §3.5 B3 修复）
6. **Audit emission** —— 单一 `entity.deleted` 事件附完整 cascade 摘要

每步记录到 `invocations` audit 表；从 operator 视角看，操作是原子的（成功 = 所有 cascade 步完成 AND tombstone 已立）。

字段名平行是有意的：本 SPEC 复用已建立的 Behavior 契约（`actions/0`, `required_caps/0`, `invoke/4`）+ PR-G 的 Adapter 模式，所以写新 entity type 的 plugin 作者跟着他们已知的 wire format 走。

---

## §3 语义 —— `Behavior.EntityDeletion` 精确定义

### 3.1 输入

- `target_uri` —— 被删 entity 的 `%URI{}`。必须 match 一个 `DeletionAdapter` 的 `entity_scheme/0 + entity_subscheme/0` filter（所以 `entity://user/...` 路由到 UserDeletionAdapter，`entity://agent/...` 路由到 AgentDeletionAdapter，等等）。
- `caller_uri` —— 执行删除的 operator。必须持 `:delete` cap（按 `required_caps/0`）。默认 admin-only；per-adapter policy 可以收窄（如 workspace admin 可以删自己 workspace 的用户，但不能跨 workspace；见 `Adapter.can_delete?/2`）。
- `reason` —— operator 提供的自由文本。存进 audit row。**非可选**。

### 3.2 输出

```elixir
{:ok, %{
  deleted_uri: URI.t(),
  steps_completed: [step_name :: atom()],
  cascade_summary: %{deleted: integer(), scrubbed: integer(), tombstoned: integer()},
  audit_event_id: binary(),
  trace_id: binary()
}}
| {:error, {:partial, %{
   step_failed: atom(),
   steps_completed: [atom()],
   reason: term(),
   recovery_hint: String.t(),
   trace_id: binary()
}}}
| {:error, {:precheck_failed, term()}}
```

**三个返回 shape** 平行 Generator-Reconciler 三臂（`:ok | :partial | :error`）：

- `{:ok, summary}` —— 每个 cascade step 完成，tombstone 已立，audit 已发。
- `{:error, {:partial, _}}` —— pre-check 通过、tombstone-and-kill 完成（不可逆），但至少一个 DB cascade step 失败。Kind 死透 + tombstoned（不能复活），但 cross-reference scrub 不完整。`recovery_hint` 告诉 operator 哪步 + 怎么手动重跑。
- `{:error, {:precheck_failed, _}}` —— 没改任何 state。Adapter 的 `can_delete?/2` 拒绝（如 bootstrap admin 保护）。

`trace_id` 传播到 `invocations` 表里每一行 cascade sub-row，用于下游 audit grouping（N2 修复 —— 见 §3.5）。

### 3.3 Tombstone —— 多边界强制（B1）+ 原子 primitive（B2）

**这是鬼魂 respawn 问题的结构性修复**。r1 有两个明显 gap：

(a) **单边界 check**。r1 仅在 `SpawnRegistry.spawn/1` 守 tombstone。但生产代码有 **多条** 绕开 SpawnRegistry 的 Kind-spawn path：

- `Ezagent.Kind.spawn/2`（`apps/ezagent_core/lib/ezagent/kind.ex:293-308`）—— 直接 `DynamicSupervisor.start_child` 启 `{Ezagent.Kind.Server, {kind_module, params}}`。每个 domain Application boot 都调，SpawnRegistry 自己注册的 fn 也调。
- `Ezagent.ExternalMirror.WorkerSpawn.spawn/4`（`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/worker_spawn.ex:72-113`）—— 建 PerBindingSupervisor child spec；从 `Behavior.ExternalMirror.invoke(:bind, ...)` 和 `AdapterInstall.reconcile_persisted_bindings/1`（`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_install.ex:193-220`）adapter 安装时调。
- Boot 时 `Kind.Server.init/1` 从 snapshot reload（`apps/ezagent_core/lib/ezagent/kind/server.ex:103-130`）—— 任何把 `(kind_module, args)` 对交给 `Kind.Server` GenServer 的路径。

(b) **race-prone 非原子序列**。r1 三处 normative passage 互相矛盾，先 kill 还是先 tombstone。任何非原子顺序都允许 race：kill 和 tombstone-install 之间，并发 spawn 能复活 Kind。

**r2 修复 —— 三边界 + 一个原子 primitive：**

**原子 primitive** 是唯一的公开 mutation API：

```elixir
defmodule Ezagent.SpawnRegistry do
  @doc """
  原子 tombstone + kill。立 tombstone 的唯一公开 primitive。
  Plugin 代码（DeletionAdapters）必须走这个。

  原子性契约：
    1. INSERT entity_tombstones 行（DB）。
       失败 → 返回 {:error, {:tombstone_db_failed, _}}；没有其它 mutation。
    2. :ets.insert(@tombstone_table, ...)（ETS 镜像）。
       失败（极不可能 —— protected ETS） → DELETE 步骤 1 插入的 DB 行；
       返回 {:error, {:tombstone_ets_failed, _}}。
    3. Process.exit(pid, :brutal_kill) + 等 terminate-monitor。
       注册 pid 没了（或本来就没）后返回 :ok。

  因为 DB 行在 kill 之前 commit，BEAM 在步骤 1 和 3 之间 crash 也会让
  下次 boot 时 tombstone 权威 —— Kind 不能复活，因为 Kind.Server.init/1
  （下面的边界 1）拒绝 boot 任何 tombstoned URI。
  """
  @spec tombstone_and_kill(URI.t()) :: :ok | {:error, term()}
  def tombstone_and_kill(%URI{} = uri), do: ...

  @doc "只读 check，给下面边界 1/2/3 + 诊断用。"
  @spec tombstoned?(URI.t()) :: boolean()
  def tombstoned?(%URI{} = uri), do: :ets.member(@tombstone_table, URI.to_string(uri))

  # PRIVATE —— 原子 primitive 内部用。
  # 任何 plugin 代码都不能直接调。（N1 修复）
  defp tombstone(uri), do: ...
end
```

**三条强制边界**：

**边界 1（权威 —— 每个 Kind 启动必经）：** `Ezagent.Kind.Server.init/1`。`Ezagent.Kind.Snapshot.load_or_init/3` 运行前，check `SpawnRegistry.tombstoned?(uri)`。如 true，返回 `{:stop, :tombstoned}` 且 GenServer 永不注册。这是 source-of-truth check 因为 **每一个** Kind 启动 —— 不管是通过 `Kind.spawn/2`、`WorkerSpawn.spawn/4`、plugin 自定 DynamicSupervisor 的 `DynamicSupervisor.start_child/2`、还是从 snapshot 的 supervisor restart —— 最终都调 `Kind.Server.init/1`。另两个边界是 defense-in-depth。

**边界 2：** `Ezagent.Kind.spawn/2`。`DynamicSupervisor.start_child` 之前预检 tombstone。tombstoned 返回 `{:error, :tombstoned}`。省下了启动一个被边界 1 杀掉的 process 的 supervisor cycle。

**边界 3：** `Ezagent.SpawnRegistry.spawn/1`。scheme-dispatch 之前预检 tombstone。同边界 2 道理 —— 短路 dispatch fn（dispatch fn 会调 `Kind.spawn/2`，触发边界 2）。给 SpawnRegistry 层 caller（`Workspace.list_workspaces_for/2` 的 reconciler、LV mount 等）一个更清晰的 error。

**Boot-order load。** `Ezagent.SpawnRegistry.Tombstone.load_into_ets/0` **必须** 在 `EzagentCore.Application.start/2` 中 `Ezagent.KindSupervisor` 启动 **之前**（因此在任何 plugin Application 的 boot-time spawn 路径触发之前）运行。按当前 application children 顺序，slot 在 `EzagentCore.Repo`（children ④）之后、`Ezagent.KindSupervisor`（children ⑨）之前。ETS 表由 `EzagentCore.EtsOwner`（children ①）创建；load fn 从 DB populate。

**Backfill 是 DISCOVERY，不是 source of truth。** §9.3 把 `mix ezagent.entity.deletion.backfill_tombstones` 降级为 discovery/cleanup 工具：它扫 `kind_snapshots` 找无对应 `users` / `agents` 行的 `entity_uri`，列给 operator review（可选 tombstone）。Backfill **不是** 生产删除的工作方式。

**`entity_tombstones` 是 append-only** —— 没有 `untombstone/1` API。要 "复用" 已删 URI，operator 必须在另一个 URI 创建 **新** entity；已删的 URI 永久不可复用。这是 "immutable identity" 的结构性表亲（见 `feedback_uuid_is_canonical_identifier` 类比：URI 是 canonical identity；删除是永久的）。Admin-only SQL 行删 documented in §9.4（rollback）用于 forensic recovery，但 **不是** 正常 operator workflow。

### 3.4 Snapshot purge

`kind_snapshots` 行删除。Trivial，**在 `tombstone_and_kill` 之后**（这样如果后续步骤失败，snapshot 指向虚空且 tombstone 拒绝 respawn —— fail-safe；鬼魂不能复活）。

### 3.5 Adapter cascade —— 含 B3、B5、B6 修复 + N2 trace correlation

`Adapter.cascade_steps/2` 返回 `[{step_name, step_fn}]` 有序列表。Behavior 按顺序迭代，应用每步。每步幂等（重跑是 no-op 如果 state 已应用）。

**Trace 关联（N2）：** Behavior 入口处生成 **一个** `trace_id`。每行 cascade sub-row（`action = "entity.deleted.<step_name>"`）携带与 parent `entity.deleted` 行相同的 `trace_id`，audit consumer 可 `WHERE trace_id = ?` 取出完整 cascade。无 schema change —— `invocations.trace_id` 已存在（`apps/ezagent_core/priv/repo/migrations/20260515160000_phase1_audit_dlq_snapshots.exs:8`）。

**User cascade**（`Ezagent.Domain.Identity.UserDeletionAdapter.cascade_steps/2`）：

```
:revoke_all_caps               → Identity.revoke_all_caps(target_uri)
:revoke_entity_tokens          → Repo.delete_all(from t in EntityToken, where: t.entity_uri == ^target_uri_str)    [B6]
:drop_feishu_bindings          → delete feishu_user_bindings WHERE user_uri = target
:drop_entity_profile           → delete entity_profiles WHERE entity_uri = target
:drop_workspace_memberships    → Enum.each(workspaces, &Workspace.remove_member/2)
:drop_session_memberships      → Enum.each(sessions, &Chat.leave/2)
:scrub_session_owner_uri       → Enum.each(owned_sessions, &dispatch_chat_scrub_owner/1)    [B3 —— 见下]
:delete_users_row              → Repo.delete(user)
```

**B3 —— Session owner scrub 通过真实 Behavior.Chat action。** `Behavior.Chat`（`apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:88`）今天声明 actions `[:send, :receive, :join, :leave, :set_working_copy]`。本 SPEC 新增 Session-side action `:scrub_owner`：

- `actions/0`: `[:send, :receive, :join, :leave, :set_working_copy, :scrub_owner]`
- `required_caps/0`: `:scrub_owner` 通过 `cap(:any, __MODULE__, :scrub_owner)` 守 bootstrap-admin shape（只有 EntityDeletion cascade 会 invoke 它 —— operator-level dispatch 在 `Adapter.can_delete?/2` 的 admin-only path 结构性拒绝）
- `invoke(:scrub_owner, slice, %{deleted_uri}, _ctx)`：如 `slice.owner_uri == deleted_uri`，set `owner_uri: nil`（**不是** sentinel URI —— `nil` 落到 `data_owner/1` 在 `chat.ex:1337` 的 `:no_owner` clause，保留系统 sessions 既有语义）。返回 `{:ok, %{owner_scrubbed: true}, slice_with_nil_owner, dispatch_envelope}` 让标准 `Kind.Runtime` step 9.5 通过 `:on_change` 策略持久化。

Cascade step body：

```elixir
def scrub_session_owner_uri(target_user_uri, _ctx) do
  # Lookup 走 live registry —— 只匹配 Kind 活着且 slice owner_uri = target
  # 的 session。Snapshot 中但未驻留的 session 不重要：它们 rehydrate 时，
  # merged slice 被 post-tombstone DB cascade 的 audit 叠加，下次 reconcile
  # （Kind.Snapshot.load_or_init/3）会见 User URI tombstoned —— 但这里不对
  # 非驻留 Session 执行 action。
  # SAFETY：任何之后用 stale owner_uri = deleted 的 Session load 时，在
  # chat.join 时被 reconcile（被删用户不能 join，所以 session 不能代表他们
  # 行事；owner authority 通过 chat.ex:1337 落到 :no_owner 因为已删 URI
  # tombstoned 且 Session.owner/1 返回 error path）。
  alive_sessions =
    Ezagent.KindRegistry.list_matching(scheme: "session")
    |> Enum.filter(fn {_uri, pid} -> alive_session_owned_by?(pid, target_user_uri) end)

  Enum.reduce(alive_sessions, %{scrubbed: 0, errors: []}, fn {session_uri, _pid}, acc ->
    case Ezagent.Invocation.dispatch(%Invocation{
           kind: Ezagent.Entity.Session,
           behavior: Ezagent.Behavior.Chat,
           action: :scrub_owner,
           target: session_uri,
           args: %{deleted_uri: target_user_uri},
           ctx: %{caller: cascade_caller_uri, trace_id: cascade_trace_id}
         }) do
      {:ok, _} -> %{acc | scrubbed: acc.scrubbed + 1}
      {:error, reason} -> %{acc | errors: [{session_uri, reason} | acc.errors]}
    end
  end)
end
```

**Session 在 lookup-到-dispatch 之间被删的 race：** 如 Session Kind 在 `KindRegistry.list_matching/1` 和 `Invocation.dispatch/1` 之间死了，dispatch 返回 `{:error, :noproc}`。Cascade 视为成功（session 没了，没什么要 scrub 的）。如 Session tombstoned（被并发 Session 删除），dispatch 从边界 1 返回 `{:error, :tombstoned}` —— 也视为成功。Cascade step 的幂等性契约保持：重跑是 no-op。

**Agent cascade**（`Ezagent.Domain.Chat.AgentDeletionAdapter.cascade_steps/2`）：

```
:stop_sidecars                 → flavor-specific (cc bridge / codex PTY+app-server / curl ...)
:unbind_bridge_registry        → BridgeRegistry.unbind(agent_uri)
:revoke_entity_tokens          → Repo.delete_all(from t in EntityToken, where: t.entity_uri == ^target_uri_str)    [B6]
:drop_session_memberships      → Enum.each(sessions, &Chat.leave/2)
:scrub_mention_routing_rules   → RoutingRules.remove_by_target(agent_uri)
:revoke_agent_api_keys         → AgentApiKeys.revoke_all(agent_uri)
:drop_agent_lineage            → AgentLineage.delete(agent_uri)
:delete_workspace_template     → Workspace.remove_template/3 (if registered)
```

**Worker cascade**（`Ezagent.Domain.ExternalMirror.WorkerDeletionAdapter.cascade_steps/2`）：

```
:drop_external_mirror_bindings → delete external_mirror_bindings WHERE worker_uri = target    [B5 —— 见下]
:unsubscribe_session_publisher → Publisher.unsubscribe(target)
:terminate_adapter             → adapter_module.terminate(target)
```

**B5 —— Worker cascade 列修复。** r1 的 `WHERE bound_by = target` 错了：`bound_by` 记 **创建用户 URI**（`apps/ezagent_core/priv/repo/migrations/20260607000000_pr_em_3_external_mirror_bindings.exs:54`），Worker URI 从 `(session_uri, adapter_id, target_id)` 通过 `WorkerSpawn.worker_uri_for/3`（`worker_spawn.ex:217-230`）派生 **不存表里**。

按 `feedback_let_it_crash_no_workarounds`（结构 over policy），r2 修复给 `external_mirror_bindings` 加持久化 `worker_uri` 列：

- **Forward-only migration**（`apps/ezagent_core/priv/repo/migrations/<timestamp>_pr_a_worker_uri_column.exs`）：`add :worker_uri, :string, null: true` 初期（允许 backfill），然后通过 PR-A 同 backfill mix 任务 populate，最后 follow-up migration 设 `NOT NULL`。Greenfield 部署（dev/test）立即 `NOT NULL` 因为无 pre-existing 行。
- **写路径：** `Behavior.ExternalMirror.invoke(:bind, ...)` 的持久化步骤（写 `external_mirror_bindings` 的 action body）更新以 populate `worker_uri = WorkerSpawn.worker_uri_for(session_uri, adapter_id, target_id) |> URI.to_string()`。
- **读路径：** `AdapterInstall.reconcile_persisted_bindings/1`（`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_install.ex:193-220`）仍结构性派生 Worker URI（行里有 session_uri + adapter_id + target_id）；新列给删除 cascade 用，不是 reconcile 路径。
- **Cascade 查询：** `Repo.delete_all(from b in BindingRow, where: b.worker_uri == ^target_uri_str)` —— 直接 + race-free。
- **`bound_by` 不变。** 仍记 creator identity。User cascade 单独 scrub `bound_by` 引用（实际上 `bound_by` 不需 cascade 因为被删用户并不让他们 **创建** 的 binding 无效；binding 仍 bound 到活的 Worker/Session，只有 cascade 跑 `:scrub_audit_owner_refs` step 时 operator-of-record 才被改写到 tombstone sentinel，那是 User-scope，不是 Binding-scope）。见 §3.7 跨引用 scrub 策略。

每步在调用内部函数前记录到 `invocations` audit（这样部分失败的 audit 显示哪步炸了）。Audit row 的 `target` 字段是删除目标 URI；`caller` 是 operator；`action` 是 `entity.deleted.<step_name>`；`trace_id` 是 parent cascade 的 trace。

### 3.6 未来 entity types

新的 `entity://<subscheme>/<workspace>/<name>` 类型加 `DeletionAdapter` 实现；不改 `Behavior.EntityDeletion` 或 `SpawnRegistry`。例：

- `entity://tool/<workspace>/<name>` (假想 Tool entity)：adapter 清 ToolRegistry，drop permissions
- `entity://group/<workspace>/<name>` (假想 Group)：adapter cascade-removes from member lists

Behavior + Adapter 契约封闭；cascade 词汇开放。写新 domain 的 plugin 作者跟着他们已知的 AgentBridge.Adapter / Ezagent.Plugin shape 走。

### 3.7 Cross-reference scrub 策略 —— tombstone-sentinel vs hard-delete

历史引用（audit rows、其它 Kind 提到已删 URI 的 snapshot、completed-session metadata），有两种清理策略：

**(a) Tombstone-sentinel**（默认）：rewrite 历史行中的 URI 为静态 `entity://tombstone/deleted/<original_subscheme>` sentinel。保留 audit trail（你能看到 user X 做过什么，只是不知道 WHO 他们是）。可逆-ish（sentinel 不带身份，但 row count 保留）。

**(b) Hard-delete**：删除每条引用 URI 的历史行。DB 更轻。摧毁 audit 历史。

Cascade adapter 按 cross-reference 表选 (a) 或 (b)。默认是 audit-bearing 表 (a)（`invocations`），非 audit 操作状态 (b)（membership lists, registry entries, entity_tokens, feishu_user_bindings）。

对 LIVE-slice 引用（Session `owner_uri`），scrub 走 `Behavior.Chat.invoke(:scrub_owner, ...)`（见上面 B3），把字段设 `nil` —— 保留列类型，通过 `data_owner/1` 已有 `:no_owner` clause 表达 "no owner"。DB snapshot 通过 `:on_change` 自然持久化。

§10 OQ-3 提议加 config knob 翻转默认；保留 Allen 决定。

### 3.8 边界情况 —— bootstrap admin 保护

`entity://user/system/admin` **必须不可删**。`UserDeletionAdapter.can_delete?/2` 硬编码：

```elixir
def can_delete?(%URI{} = uri, _ctx) do
  if URI.to_string(uri) == URI.to_string(Ezagent.Entity.User.admin_uri()) do
    {:error, :bootstrap_admin_undeletable}
  else
    :ok
  end
end
```

其它 adapter 可能加类似保护 URI（如 system orchestrator agent, system feishu binding）。

### 3.9 边界情况 —— 删除中的并发 dispatch

原子 `tombstone_and_kill/1`（§3.3）关闭了原始 kill-vs-tombstone race。剩余并发：

- 到死亡 Kind 的 dispatch：`GenServer.call` 阻塞到 terminate 完成，然后返回 `{:error, :noproc}`。可接受 —— caller 拿到 clean error。
- dispatch 在 `tombstone_and_kill` 之后但在后续 cascade step 之前到达：SpawnRegistry.spawn 拒绝 `:tombstoned`（边界 3）；dispatch 给出 clean error。
- 从已在 Kind mailbox 排队的消息：`Kind.Server.terminate/2` 按 OTP 语义自然 drain mailbox；排队消息得到 `{:error, :noproc}`。

不需要 "transactional dispatch barrier"。

### 3.10 边界情况 —— operator 删除自己

调用 `Behavior.EntityDeletion.invoke(:delete, slice, %{target: their_own_uri})` 的 workspace admin 结构上没问题：action 跑到完成（因为他们的 caps 在 dispatch step 5.5 BEFORE cascade 剥去 evaluate），cascade 后他们的 session 在下次 refresh 时失效。LV 在 `users_live.ex` 用 confirm-dialog 警告拦截 self-delete（"你在删自己；你会被登出"）但不阻塞 —— operator 可能有合法理由。

---

## §4 迁移方案

### 4.1 新代码（按 PR 顺序）

**PR-A（本 SPEC）→ PR-B Behavior + tombstone + UserDeletionAdapter**：

- `apps/ezagent_core/lib/ezagent/behavior/entity_deletion.ex`（新）—— `Ezagent.Behavior.EntityDeletion`
- `apps/ezagent_core/lib/ezagent/entity_deletion/adapter.ex`（新）—— adapter behaviour 契约
- `apps/ezagent_core/lib/ezagent/entity_deletion/adapter_registry.ex`（新）—— flavor-style 注册器（镜像 `Ezagent.AgentBridge.AdapterRegistry`）
- `apps/ezagent_core/lib/ezagent/spawn_registry/tombstone.ex`（新）—— 内部 ETS + DB store；`load_into_ets/0` 由 `EzagentCore.Application.start/2` 调
- `apps/ezagent_core/priv/repo/migrations/<timestamp>_entity_tombstones.exs`（新）—— tombstone DB 表
- `apps/ezagent_core/priv/repo/migrations/<timestamp>_pr_a_worker_uri_column.exs`（新）—— 给 `external_mirror_bindings` 加 `worker_uri`（B5）
- **改** `apps/ezagent_core/lib/ezagent/spawn_registry.ex` —— 加 `tombstone_and_kill/1` 公开 primitive + `tombstoned?/1` 只读 + 在 `spawn/1` 入口加 tombstone check（边界 3）
- **改** `apps/ezagent_core/lib/ezagent/kind.ex` —— 在 `spawn/2` 入口加 tombstone check（边界 2）
- **改** `apps/ezagent_core/lib/ezagent/kind/server.ex` —— 在 `init/1` 入口加 tombstone check，tombstoned 时 return `{:stop, :tombstoned}`（边界 1 —— 权威）
- **改** `apps/ezagent_core/lib/ezagent_core/application.ex` —— slot `Ezagent.SpawnRegistry.Tombstone.load_into_ets/0` 在 `Repo` 迁移 **之后** 且在 `Ezagent.KindSupervisor` boot **之前**
- **改** `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex`（`:bind` action body）—— 在 insert 时 populate `worker_uri` 列（B5）
- **改** `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex` —— 加 `:scrub_owner` action（B3）；更新 `actions/0` + `required_caps/0` + `invoke/4`
- `apps/ezagent_domain_identity/lib/ezagent_domain_identity/user_deletion_adapter.ex`（新）
- 测试：§5 invariant test + adapter 单测 + boundary-1 单测（Kind.Server 拒绝 tombstoned URI） + boundary-2 + boundary-3 + chat.scrub_owner 单测

**PR-C admin LV 集成**：

- 改 `users_live.ex` —— 加 delete button + confirm dialog + reason input
- 改 `identities_live.ex` —— 加 per-row delete action
- 改 `agent_detail_live.ex` —— 在 agent detail 页加 delete action
- 加 `mix ezagent.entity.delete <uri> --reason "<reason>"` CLI 任务
- **在 r2 中删除（B4）：** `workspaces_live.ex` delete button。Workspace 删除 out of scope，延后到未来 Workspace lifecycle SPEC。

**PR-D Agent + Worker DeletionAdapter**：

- `apps/ezagent_domain_chat/lib/ezagent/domain/chat/agent_deletion_adapter.ex`（新）
- `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/worker_deletion_adapter.ex`（新）—— 用新的 `worker_uri` 列（B5）
- Per-flavor sidecar 终止（cc / codex / echo / curl / np —— 各 domain 加自己的 teardown）

### 4.2 向后兼容

**不**移除任何现有代码路径。`Users.delete/1` 语义**不变** —— 该路径仍存在作为 LOW-LEVEL DB-only delete，但会发 deprecation warning 建议用 `EntityDeletion.delete/3`。Migration 目标：follow-up PR-E 中标 `Users.delete/1` 为 `@deprecated` 并把 operator-facing 调用点路由通过 `EntityDeletion`。

历史孤儿 discovery：`mix ezagent.entity.deletion.discover_orphans` mix 任务扫 `kind_snapshots` 找无对应 `users` 或 `agents` 行的 Kind URI 并 **打印**。Operator 决定每个是否 tombstone。**这是 DISCOVERY，不是 source of truth** —— 见 §3.3 boundary-1 段。

### 4.3 无 production data 的 DB migration

`entity_tombstones` 是新表；没有 existing rows。`external_mirror_bindings.worker_uri` 是新列，forward-only 添加（初始 `null: true` → backfill → 后续 `NOT NULL`）。无 destructive schema change。按 `feedback_destructive_migration_anti_pattern` 两者都是 operator-可跑，但后续 `NOT NULL` 切换在 production-shaped 环境标显式 operator action（stop phx, migrate, restart）。

### 4.4 协同 PR 序列

PR-A（本 SPEC）先 land。后续 PRs (B/C/D) dispatch 为独立 subagent 跑，各自独立 merge 带 codex review。Behavior + tombstone + UserDeletionAdapter (PR-B) 是**最小可发布**单元 —— 关闭 User 鬼魂问题。PR-C unlock operator-facing UI；PR-D 扩到 Agent + Worker。

Plugin-isolation north-star 保留：PR-B+ 加契约；PR-C/D 插入。未来 entity types (Tool, Group, etc) 加 `DeletionAdapter` 不碰 core。

---

## §5 Invariant 测试 —— merge gate

按 `feedback_completion_requires_invariant_test`，本 SPEC "done" 当且仅当下列测试通过 AND 在任意 partial impl 上失败。

**文件：** `apps/ezagent_core/test/invariants/entity_deletion_invariant_test.exs`

**Setup** (DataCase, `async: false`)：

1. 创建非 admin User: `entity://user/team-alpha/test-deletable` via `Users.create/3`
2. 授予 caps + 加进 workspace + bind feishu open_id + 通过 `Token.create/2` 铸 token（这样 cross-references 存在，含 entity_tokens 行）
3. 创建 `owner_uri = target` 的 Session（这样 B3 的 scrub 路径被执行）
4. Spawn User Kind: `SpawnRegistry.spawn("entity://user/team-alpha/test-deletable")` → `{:ok, pid}`
5. 调 `Behavior.EntityDeletion.invoke(:delete, slice, %{target: target, reason: "test"}, %{caller: admin_uri, caps: admin_caps})`

**断言**（任一违反则测试失败）：

| # | 断言 | 抓什么 |
|---|---|---|
| INV-1 | delete 后 `KindRegistry.lookup(target)` 立即返回 `:error` | Kind 未杀 → 鬼魂 route 仍活 |
| INV-2 | `SpawnRegistry.spawn(target)` 返回 `{:error, :tombstoned}`（NOT fresh pid） | Tombstone 缺失或边界 3 未强制 → respawn 鬼魂 |
| INV-2a | `Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: target})` 返回 `{:error, :tombstoned}` | 边界 2 未强制 —— 直接 Kind.spawn path bypass (B1) |
| INV-2b | 手动启 `Ezagent.Kind.Server` with `{Ezagent.Entity.User, %{uri: target}}` 返回 `{:error, :tombstoned}`（或 GenServer 以 `{:stop, :tombstoned}` 终止） | 边界 1 未强制 —— 权威 chokepoint (B1) |
| INV-3 | `Users.get_by_uri(target)` 返回 `nil` | DB row leak |
| INV-4 | `Repo.get(EntityProfile, target_uri_str)` 返回 `nil` | Profile leak |
| INV-5 | `Repo.get(KindSnapshot, target_uri_str)` 返回 `nil` | Snapshot leak → 下次 boot 复活 |
| INV-6 | `Repo.all(from f in feishu_user_bindings, where: f.user_uri == ^target_uri_str)` 返回 `[]` | Feishu sender 解析 → 死亡用户 |
| INV-7 | 对每个 target 曾是成员的 workspace W：`target NOT IN W.member_uris` | Membership leak |
| INV-8 | 对每个 target 曾是成员的 session S：`target NOT IN S.members` | Session membership leak（可能在 `chat.join` 时 re-resurrect Kind） |
| INV-9 | `Workspace.list_workspaces_for(target, ...)` raises 或返回 `[]`（target 本身不存在了） | Visibility leak |
| INV-10 | 一条 audit row 存在：`invocations` 含 `action = "entity.deleted"`, `target = target_uri_str`, `caller = admin_uri_str`，AND 每个 cascade step 有 sub-row 共享相同 `trace_id`（N2） | Audit trail 不完整或 trace correlation 断 |
| INV-11 | Kill BEAM (模拟重启 via `Application.stop(:ezagent_core) + Application.start(:ezagent_core)`)。重启后 INV-1 + INV-2 + INV-2a + INV-2b + INV-3 仍 hold。具体：`Kind.Server.init/1` 对 target URI 返回 `{:stop, :tombstoned}`，证明边界 1 从 boot-time-populated ETS 表 load 自己的 check | Tombstone DB 持久化失败 OR boot-time load 漏 |
| INV-12 | `Behavior.EntityDeletion.invoke(:delete, ..., %{target: Ezagent.Entity.User.admin_uri()})` 返回 `{:error, :bootstrap_admin_undeletable}` | Bootstrap admin 保护缺失 |
| INV-13 | 对 setup 中创建的 `owner_uri = target` Session S：dispatch `Behavior.Chat.data_owner(S_uri)` 返回 `:no_owner`（不是已删 target URI），AND 看 S 的 live slice：`slice.owner_uri == nil` | B3 —— Session owner 未通过新 `:scrub_owner` action scrub → 已删用户仍驱动 data_owner authz |
| INV-14 | 对 setup 中给 target 铸的 token：`Token.verify(plain_token, target)` 返回 `{:error, :tombstoned}`（NOT `{:error, :invalid_credentials}` 且 NOT `{:ok, _}`） | B6 —— token 行 escape cascade 或 Token.verify 缺 tombstone defense check |

**不能通过 partial impl** —— 任意 cascade step 或边界跳过，对应 INV fail：

- 跳 "tombstone install"：INV-2 + INV-2a + INV-2b + INV-11 fail
- 仅跳边界 1：INV-2b fail（和 INV-11 boot path）
- 仅跳边界 2：INV-2a fail
- 仅跳边界 3：INV-2 fail
- 跳 "users row delete"：INV-3 fail
- 跳 "feishu bindings drop"：INV-6 fail
- 跳 "memberships drop"：INV-7 + INV-8 fail
- 跳 "session owner scrub" (B3)：INV-13 fail
- 跳 "revoke_entity_tokens" (B6)：INV-14 fail（行删除一半）
- 跳 Token.verify tombstone check (B6 defense-in-depth)：INV-14 fail（verify-rejects 一半）
- 跳 "audit emit"：INV-10 fail
- 跳 "bootstrap protection"：INV-12 fail

测试在第一个 mismatch 失败，带消息标识 leak。Operator 看到 cascade-step name + leaked row。

---

## §6 Plugin isolation 分析

按 `feedback_north_star_plugin_isolation`，架构 seam：

| 层 | 知道 | 不知道 |
|---|---|---|
| `ezagent_core` | `Behavior.EntityDeletion` action, `EntityDeletion.Adapter` behaviour, `SpawnRegistry.tombstone_and_kill/1`（公开）, `SpawnRegistry.tombstoned?/1`（公开只读）, 三条强制边界 | 怎么 drop Feishu binding、怎么终止 cc bridge、怎么 scrub session membership |
| `ezagent_domain_identity` | `UserDeletionAdapter` (User-specific cascade: caps, Feishu bindings, profile, memberships, tokens, owned-session-owner scrub via dispatch) | Agent / Worker cascade；内部 `tombstone/1`（core 私有）；边界 2/3 内部 |
| `ezagent_domain_chat` | `AgentDeletionAdapter` (Agent-specific cascade: sidecars, bridge registry, lineage, tokens)；`:scrub_owner` Chat action body（cascade dispatch 进 Chat，不反过来） | User / Worker cascade |
| `ezagent_domain_external_mirror` | `WorkerDeletionAdapter` (Worker cascade: bindings via 新 `worker_uri` 列, publisher unsubscribe, adapter terminate) | User / Agent cascade |
| `ezagent_plugin_codex` (等) | 怎么停 **它的** sidecar | 怎么终止 cc 的 sidecar |
| `ezagent_plugin_liveview` | 怎么渲染 "Delete" button + confirm dialog | cascade 语义 |

未来 plugin 作者加新 entity type (如假想的 `entity://tool/...`) 写 `ToolDeletionAdapter` + 注册。**零** changes 到 `ezagent_core` 需要。这是 north-star 应用到删除生命周期。

Tiebreaker test（"keeps plugin authors out of core"）：`Behavior.EntityDeletion` 把内部 cascade state 暴露给 plugin 代码吗？答：**否**。Behavior 调 `Adapter.cascade_steps/2` 拿回 `{step_name, function}` 列表。Plugin 的 adapter 永不看 deletion target 的 slice state，永不看其它 adapter 的 cascades，永不直接碰 `SpawnRegistry.tombstone/1`（它私有；只 `tombstone_and_kill/1` 公开，且仅由 `Behavior.EntityDeletion` step 2 调 —— 不由 adapter 代码调）。✅

---

## §7 权衡 / 拒绝过的方案

### 7.1 "Soft delete" 加 `deleted_at` flag（拒绝）

`users.deleted_at` column + filter 每个 read site 排除 `deleted_at != nil` 的 row。

**拒绝**：这是身份删除的 canonical anti-pattern。每个 read site 负责 filter；漏一个 = 鬼魂复活。Discipline 问题等同于 `2026-05-27-workspace-cap-based-visibility.md` 拒绝的 `visible: false` 问题。Cap-based + tombstone 是结构性修复；flag-based 是 policy-based。

### 7.2 "Hard delete + 无 tombstone，希望 SpawnRegistry 找不到 URI"（拒绝）

只删 row + snapshot。靠"没有 path 会试图 spawn 不存在 URI"。

**拒绝**：经验上错。2026-05-26 system/linyilun 退役 **做了这个** —— DB row 没了 snapshot 没了 —— Kind 仍 respawn。某条 path **在**试 spawn URI (LV mount, Feishu binding lookup, dispatch from another Kind)，entity spawn fn 高兴地创建一个 fresh Kind 因为 SpawnRegistry 层没有 "deleted" signal。Tombstone 就是缺失的 signal。

### 7.3 "用 Ecto soft-delete 库"（拒绝）

拉 `ecto_soft_delete` 或类似。

**拒绝**：这是 7.1 加库包装。库让 discipline **更易**维护但不改其根本脆弱。按 `feedback_let_it_crash_no_workarounds` 优选结构 over policy。

### 7.4 "Per-entity-type Behavior"（拒绝）

`Behavior.UserDeletion`, `Behavior.AgentDeletion`, `Behavior.WorkerDeletion` —— 三个独立 Behaviors 并行结构。

**拒绝**：复制结构序列 (pre-check / kill / tombstone / cascade / audit) 三遍。一个 Behavior 的 bug fix 需要三路复制。Adapter 模式 (一个 Behavior, 三个 adapters) 是结构性去重；per-entity Behaviors 是 policy-based。

### 7.5 "不允许 runtime deletion；要求 operator-side DB script + phx restart"（拒绝）

今天的实际路径。Operator 做 SQL deletes + restart phx 让所有 in-memory state rebuild clean。

**拒绝**：在 scale 1 工作（system/linyilun migration），在 scale N 失败。租户 routine 创建 + 删除 test users 不能容忍"每次 delete restart phx"。Production-grade SaaS 需要 runtime deletion。（且 Allen 显式要求 runtime fix。）

### 7.6 "仅在 SpawnRegistry.spawn/1 单边界 tombstone"（r1 —— r2 按 B1 拒绝）

r1 原仅守 `SpawnRegistry.spawn/1`。codex r1 指出生产有额外的 spawn path（`Kind.spawn/2` 直接、`WorkerSpawn.spawn/4`、从 snapshot supervisor-restart）绕开 SpawnRegistry。**拒绝**：单边界 tombstone 结构上不够。r2 修复把 check 装在 **三个** 边界，`Kind.Server.init/1` 作为权威 source-of-truth（唯一的 "每个 Kind 启动必经" chokepoint）。

### 7.7 "删除时 Worker→binding lookup 不持久化 worker_uri"（r1 —— r2 按 B5 拒绝）

B5 的替代：删除时给定 worker URI，从行 reverse 工程 `(session_uri, adapter_id, target_id)` triple 或迭代每行调 `WorkerSpawn.worker_uri_for/3` 匹配。**拒绝**：O(N) lookup hack 替代 O(1) indexed 列；按 `feedback_let_it_crash_no_workarounds`（结构 over policy）；也脆弱 —— `worker_uri_for/3` 是私有 hash-派生契约，任何 hash 函数变化（截断长度、salting、scheme）silently invalidate reverse lookup。持久化列是更简单更鲁棒的答案。

### 7.8 "Workspace 删除走同一 Adapter dispatch"（r2 按 B4 拒绝）

r1 PR-C 加 `workspaces_live.ex` delete button 走 `Behavior.EntityDeletion`。但 `workspace://<name>` URI 不 match `entity_scheme/0 + entity_subscheme/0` Adapter dispatch 索引的 `entity://<scheme>/<subscheme>` shape。**拒绝**：workspace 删除结构上不同 —— cascade-deletes workspace 内 **所有** 成员 + 模板 + sessions + bindings；语义不同于 entity 删除（per-URI）。强行让两者共用一个 Adapter 契约混淆两个不相干的 lifecycle 责任。Workspace 删除走未来独立 SPEC。

---

## §8 SPEC 交互 —— 并行 specs

### 8.1 [2026-05-27-workspace-cap-based-visibility.md](2026-05-27-workspace-cap-based-visibility.md) (merged)

`Workspace.list_workspaces_for/2` 用 cap-membership 算可见性。EntityDeletion 的 cascade 撤用户 caps + 从 workspace.member_uris 移除。删除后 `list_workspaces_for/2` 对该 caller 返回 `[]`（cap-membership union 空）。INV-9 pin 这个交互。

### 8.2 [2026-05-27-uri-canonicalization.md](2026-05-27-uri-canonicalization.md) (merged)

EntityDeletion 在每个 cascade step 比较 URI。所有 URI 解析用 `Ezagent.URI.parse!/1`；INV 断言用 `URI.to_string` 比较（canonical-form-invariant）。无新 URI-parsing path 引入；SPEC #431 的 chokepoint 已够。

### 8.3 [2026-05-27-capability-action-axis.md](2026-05-27-capability-action-axis.md) (merged)

`Behavior.EntityDeletion` 的 `required_caps/0` 声明 `action: :delete` —— **具体** 原子，不是 `:any`。按 SPEC §3.6.1(b)（wildcard-action-grant gate），意味着 cap grant flow 总是产 per-action cap，从不 `:any`。对齐 BindingPolicy fix (#426) 教训。

### 8.4 [2026-05-27-reconciler-return-shape.md](2026-05-27-reconciler-return-shape.md) (merged)

EntityDeletion 返回 shape 是 `:ok | :partial | :error` —— 同三臂模式。`:partial` 这里意思是 "Kind killed + tombstoned (不可逆) but DB cascade 不完整"。Caller 同 Reconciler caller 那样处理 `:partial`：retry-the-cascade-steps OR escalate 到 operator。两个模式同一个 precedent ratified。

### 8.5 [2026-05-27-agent-bridge-domain-extraction.md](2026-05-27-agent-bridge-domain-extraction.md) (merged)

Agent 删除需要终止 sidecars。PR-G 引入 `Ezagent.AgentBridge.Adapter.deliver/2` for outbound + `handle_client_event/3` for inbound。AgentDeletionAdapter 需要并行 "teardown" path。两个选项：

- 给 `Ezagent.AgentBridge.Adapter` 加 `teardown/1` callback —— flavor adapter 知道怎么停自己的 bridge
- 或 `AgentDeletionAdapter` 直接调已知 sidecar shutdown API (cc: `BridgeRegistry.unbind`, codex: `BridgeSidecar.stop`)

**推荐**：给 `Ezagent.AgentBridge.Adapter` 加 `teardown/1`（optional callback，默认 no-op）。PR-D 含此扩展；PR-G 现有 adapter 各加一个 `teardown/1` impl。Plugin isolation 保留。

---

## §9 向后兼容 / 外部 API

### 9.1 Operator workflows

- `mix ezagent.user.create`（existing）—— 不变
- `mix ezagent.user.delete`（当前行为：low-level DB delete）—— **DEPRECATED**，会发 warning + 建议用 `mix ezagent.entity.delete`
- `mix ezagent.entity.delete <uri> --reason "<reason>"`（新）—— 调 `Behavior.EntityDeletion.invoke(:delete, ...)`
- `mix ezagent.entity.deletion.discover_orphans`（新）—— DISCOVERY only（扫 snapshot 孤儿、打印、**不**自动 tombstone 立）

### 9.2 外部 callers

`external_mirror_bindings` 表多一个 `worker_uri` 列（B5），由 `:bind` action body populate。读这张表的外部 caller 多见一个字段；现有读不受影响。

无外部 HTTP / RPC / Phoenix.Channel 消费者今天 pattern-matches 身份删除行为；本 SPEC 引入 **新** Phoenix.PubSub broadcast `{:entity_deleted, target_uri, reason}` for LV 消费者（admin dashboard 在用户被删时刷新）。

### 9.3 Snapshots —— boot-time tombstone load 是 source of truth（r2 B1 降级）

引用已删 entity 的 pre-SPEC snapshots 不自动 rewrite。结构性保护是 boot-time tombstone load：

- `EzagentCore.Application.start/2` 在 `Repo` + Migrator **之后** 且在 `Ezagent.KindSupervisor` boot **之前** 跑 `Ezagent.SpawnRegistry.Tombstone.load_into_ets/0`
- 之后所有 `Kind.Server.init/1` 调用查 ETS（边界 1）并拒绝 boot 任何 tombstoned URI
- 引用 tombstoned URI 的 snapshot 行 **惰性** —— 它躺在 DB 但没有 Kind 会 load；`kind_snapshots` 孤儿行操作上不可见

`mix ezagent.entity.deletion.discover_orphans` 任务是 DISCOVERY/CLEANUP —— 给 forensic 好奇心或 DB hygiene 用。**它不是删除的 source of truth。** Source of truth 是边界 1 在每个 Kind 启动时的 tombstone check。

### 9.4 Rollback plan

删除是 **append-only**；没有 `undelete`。要 "恢复"误删 entity，operator 必须：

1. 手动从 `entity_tombstones` 移除 tombstone row（admin-only SQL）
2. 手动用同 URI 重新创建 user/agent/etc（fresh entity, 无历史连续性）

这是有意 friction。SPEC 大声 documented。LV confirm dialog 警告 "这是不可逆的；URI 不能复用"。

---

## §10 留给 Allen 的 OQ

### OQ-1 —— tombstone TTL?

`entity_tombstones` 默认永久。是否应该有 TTL 之后 URI 变可复用？默认：**否**（永久），按 `feedback_uuid_is_canonical_identifier` 类比（immutable identity）。Allen 可 per-tenant override 如果有真 tenant lifecycle 原因。

### OQ-2 —— RESOLVED in r2 —— cascade 顺序通过 `tombstone_and_kill/1` 原子化

(r1: "先杀 Kind，然后 DB。理由：...") **由 B2 解决。** 触发此 OQ 的 race 通过把 `SpawnRegistry.tombstone_and_kill/1` 提为唯一 normative primitive 而消除。不再有 "先 kill 后 tombstone" 或 "先 tombstone 后 kill" 序列 —— 按 §3.3 是一次原子操作。Cascade 顺序（按 §3）现在是：pre-check → `tombstone_and_kill`（原子）→ snapshot purge → cascade steps → audit emit。

### OQ-3 —— cross-reference scrub 默认

§3.7 列了 tombstone-sentinel vs hard-delete。提议默认：audit-bearing rows (preserve history) tombstone-sentinel，操作 state hard-delete。Allen 确认？也可以 per-tenant config。

### OQ-4 —— RESOLVED in r2 —— Workspace 删除 OUT OF SCOPE

(r1: "如果 workspace 被删，workspace 内的所有 entity 怎么办？") **由 B4 解决。** Workspace 删除 OUT OF SCOPE for 本 SPEC。`workspace://<name>` URI shape 不 match `entity://<scheme>/<subscheme>` Adapter dispatch，workspace cascade 语义（members + templates + sessions + bindings）和 entity 删除结构不同。前瞻 note：未来 Workspace lifecycle SPEC 会用它自己的 cascade 机制设计，可能复用 `Behavior.EntityDeletion` 作 sub-call 单 entity teardown，也可能不。本 SPEC 聚焦 User / Agent / Worker。

### OQ-5 —— admin LV self-delete

§3.10 允许 operator 删自己 with confirm dialog。是否应该允许 self-delete?有些系统要求 "second admin" 确认 self-deletion。默认：允许 with single confirm。Allen 可能想 gate 第二 admin 要求。

### OQ-6 —— Feishu binding cascade

User 被删时，他们 `feishu_user_bindings` rows 被 drop (§3.5)。但：production 中，用户 Feishu open_id 仍有效（他们仍在 Feishu 平台上）；他们的消息会开始 fail to resolve。Cascade 是否应尝试 re-bind open_id 到 fallback (如 `system/deleted` sentinel user) 这样消息得到 clean "user deleted" reply？默认：drop binding 完全；该 open_id 的 Feishu 消息在 routing 层得到 "no user found"（可接受 error）。Allen 可能想 sentinel-rebind。

### OQ-7 —— Tombstone DB 表 partitioning

`entity_tombstones` 一行 per 已删 URI。Scale 上 (如 10K tenants × 100 test users × delete cycles)，表增长。是否应按 workspace partition？默认：否，单表；性能问题时 revisit。Document for 未来 awareness。

### OQ-8 —— `external_mirror_bindings.worker_uri` NOT NULL 时机（r2 —— 加）

B5 修复加 `worker_uri` 初始 `null: true`，follow-up migration 在 backfill 后设 `NOT NULL`。Allen 确认两步可接受，OR 偏向一次 migration 要 phx-stopped 维护窗口？默认：两步（greenfield 部署立即 NOT NULL 因为无 pre-existing 行；production-shaped 部署做 backfill + flag）。

---

## §11 Codex 对抗性 review 问题 (for r2)

1. **多边界 tombstone 强制（B1 验证）：** r2 修复在 **三个** 边界装 check（Kind.Server.init/1 权威 + Kind.spawn/2 + SpawnRegistry.spawn/1）。trace apps/ 树里每条以 Kind 活在内存结束的代码路径。`Kind.Server.init/1` 真的是 **唯一的** 每个 Kind 启动必经 chokepoint，还是有路径构造 Kind.Server-like GenServer 不走 `init/1`？（从另一节点 hot-takeover？直接 `:proc_lib.start_link`？某些 plugin 自定 DynamicSupervisor child_spec 不用 `Kind.Server`？）找任何 r2 修复都活下来的 bypass path。

2. **原子性契约 soundness（B2 验证）：** `SpawnRegistry.tombstone_and_kill/1` 做 (1) DB insert, (2) ETS insert, (3) brutal_kill + 等。SPEC 说 "步骤 2 失败 → rollback 步骤 1"。但如步骤 1 成功、步骤 2 成功、步骤 3 失败（如 Kind 的 terminate/2 callback 在外部 IO 上无限阻塞）？Tombstone 已立但 Kind 活着 —— 后续 dispatch 命中边界 1（运行的 Kind 继续到下次 supervisor cycle restart，那时 init/1 拒绝）？走一遍失败模式；找出任何半立 tombstone 的 state。

3. **Session owner scrub well-defined（B3 验证）：** cascade 对每个 `owner_uri == target` 的 live Session dispatch `Behavior.Chat.invoke(:scrub_owner, ...)`。三个 concern：
   (a) live-session lookup race-free？`KindRegistry.list_matching(scheme: "session")` 和 per-session dispatch 之间，session Kind 可能死/被 tombstone。SPEC 说 dispatch 返回 `{:noproc, :tombstoned}` 视为成功。验证这在所有 session-lifecycle state 下正确。
   (b) 新 `:scrub_owner` Chat action 有 `required_caps/0` shape。Cascade 从 operator 的 caller_uri（有 `:delete` on EntityDeletion）dispatch。Dispatch 满足 `:scrub_owner` cap 吗？还是需要 system-principal cap injection？trace cap check 路径。
   (c) 那些 snapshot stale `owner_uri = target` 但不在 KindRegistry（之后 cold-load）的 Session 呢？SPEC 论证它们安全因为 `Session.owner/1` 在 User URI tombstoned 时返回 error path —— 但验证这是 `Session.owner/1` 实际解析方式（或修 SPEC 如果不是）。

4. **Worker cascade race-free（B5 验证）：** 新 `worker_uri` 列由 `Behavior.ExternalMirror.invoke(:bind, ...)` populate。但 backfill 窗口期通过 `AdapterInstall.reconcile_persisted_bindings/1` 从 pre-r2 `worker_uri` NULL 行 spawn 的 Worker 呢？验证 backfill mix 任务幂等且 cascade 的 `WHERE worker_uri = target` 不悄悄跳过未 backfill 的 NULL 行。也验证 `NOT NULL` follow-up migration 的前置条件 check。

5. **r2 引入矛盾文本？**（cap-vis r2 codex 找到 bug —— 小心）—— 重读 r2 SPEC §3、§10 RESOLVED、§11。任何两条关于 ordering、atomicity、scope 的陈述互相矛盾？具体 check：§3.3 atomic claim vs §3.9 concurrent-dispatch 段；§3.5 trace_id 共享 vs §3.2 return-shape 的 `trace_id` 字段；§3.5 B5 段 vs §4.1 migration 列表。

6. **Bilingual lockstep 维持？** 验证 `2026-05-28-entity-deletion.zh_cn.md` r2 对应 section 反映同 B1-B6 + N1-N3 解决。具体 check §3.5 cascade 表逐字节匹配（cascade 表是结构性，不是 narrative）。

7. **Plugin isolation tiebreaker check（post-r2）：** r2 后 §6 表仍声明 plugin adapter 永不直接碰 `SpawnRegistry.tombstone/1`。验证：是否有任何代码路径让 DeletionAdapter（在 domain 或 plugin 层）NOT 通过 `tombstone_and_kill/1` 调进 SpawnRegistry tombstone 机制？如有，修或合理化。

8. **Entity_tokens defense-in-depth（B6 验证）：** INV-14 断言 `Token.verify` 拒绝 tombstoned URI 即使行 escape cascade。验证 verify 侧 check 结构性安放（在 bcrypt 比较之前？之后？在 `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex:159-181` 的哪里 tombstone check 该放？）。

9. **LV confirm dialog UX（从 r1 q9 保留）：** PR-C admin LV 加 "Delete" button。Confirm dialog 询问 reason。是否还应要求 operator **TYPE 被删的 URI**（与 GitHub 的 "type the repo name to delete" 平价）？加 friction 但防误点。提议默认：irreversible 操作 type-the-name confirmation。Allen 确认？

---

## §12 Rollback plan

本 SPEC 的 impl 是 forward-only（已应用 deletion 不可 rollback）。SPEC 本身 rollback（reverse PR-A → PR-B → ...）：

1. Reverse 顺序 revert merge commits
2. `entity_tombstones` 表保留在 DB（孤儿，没代码读它）
3. `external_mirror_bindings.worker_uri` 列保留（NULL-able 孤儿列；无害）
4. 依赖 `Behavior.EntityDeletion` 的 operator 失去访问；fallback 是手动 SQL delete
5. Pre-existing tombstones 保持惰性（无强制直到 SPEC re-applied）

DB schema 添加是非破坏性；任意时间 rollback 安全。Deletion 语义 LOSS 可接受（operator 回到今天的手动 workflow）。

---

## Appendix A —— 序列图

```
Operator (admin LV)
  │ 点击 "Delete" + 填 reason + confirm
  ▼
Behavior.EntityDeletion.invoke(:delete, slice, %{target, reason}, ctx)
  │ step 5.5 CapBAC: caller 有 :delete cap?  → audit "granted"
  │ 生成 trace_id = audit row uuid
  │
  ▼ step 1
Adapter.can_delete?(target, ctx)
  │ adapter-specific pre-check
  ▼ :ok 或 {:error, :precheck_failed_reason}
  │
  ▼ step 2 (THE 原子 primitive —— B2)
SpawnRegistry.tombstone_and_kill(target):
  │   - INSERT entity_tombstones row (DB)
  │   - :ets.insert(@tombstone_table, ...) (失败时 rollback DB)
  │   - Process.exit(Kind pid, :brutal_kill)
  │   - 等 terminate 完成
  ▼ tombstone 已立；Kind 死；边界 1/2/3 拒绝 respawn
  │
  ▼ step 3
删 kind_snapshots row
  │
  ▼ step 4 (按 Adapter.cascade_steps/2 迭代；每行共享 parent trace_id)
for each {step_name, step_fn} in adapter steps:
  │   audit "cascade.<step_name>.start" (trace_id = parent)
  │   step_fn.()
  │   audit "cascade.<step_name>.complete" (trace_id = parent)
  │   [B3: :scrub_session_owner_uri dispatch Chat.invoke(:scrub_owner, ...) per session]
  │   [B5: :drop_external_mirror_bindings 用 WHERE worker_uri = target]
  │   [B6: :revoke_entity_tokens 删 entity_tokens]
  ▼
  │
  ▼ step 5 (audit emit)
audit "entity.deleted" {target, caller, reason, steps_completed, summary, trace_id}
  │
  ▼ step 6 (broadcast)
Phoenix.PubSub.broadcast(@entity_deletion_topic, {:entity_deleted, target, reason})
  │
  ▼
{:ok, %{deleted_uri, steps_completed, cascade_summary, audit_event_id, trace_id}}
```

## Appendix B —— 为什么本 SPEC 比其它长

引入两个新结构 (Behavior + Adapter + tombstone + cascade 契约)，每个有自己语义。§3.5 cascade 表是穷举；§5 INV 表现在 14 条（每个 leak vector + B1 三个边界测试 + B3 owner-scrub + B6 token defense）；§10 OQ 列 8 个（每个是真 product decision Allen 可 override）。r2 加多边界 tombstone 强制 section + 通过 Chat action 的 Session-owner-scrub + Worker URI 列添加 + entity_tokens cascade —— 全由 codex r1 REJECT 发现驱动。

## Appendix C —— 作者推荐

PR-A (本 SPEC) + PR-B (Behavior + UserDeletionAdapter + 3 边界 tombstone + Chat `:scrub_owner` + Worker URI 列添加) 作为 **一对** land。PR-C (admin LV 无 workspace delete) + PR-D (Agent + Worker adapters) 可并行 —— 它们独立。4-PR sequence 按 cap-vis / URI-canonical 节奏不超过 1.5-2 天；r2 让 PR-B scope ~30% 增长（边界 1 + Chat action + Worker 列迁移）所以估算时考虑。

2026-05-28 surfaced 的 `system/linyilun` 鬼魂是经验动机。PR-B land 后 + operator 跑 discovery mix 任务清点 orphan，鬼魂结构性不可能（边界 1 在每个 Kind 启动 chokepoint 拒绝每个 tombstoned URI）。

🤖 Generated with [Claude Code](https://claude.com/claude-code)
