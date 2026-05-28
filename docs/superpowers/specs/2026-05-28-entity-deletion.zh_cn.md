# SPEC —— Kind 生命周期 CRUD 对等（destroy callback + DB-backing spawn）

**状态：** r7 —— 整体重写。Allen pushback 2026-05-28 03:36–03:43：(1)"tombstone 永久不允许 re-register 很奇怪 —— 重走创建流程就该可以"；(2)"更深层 Kind 缺 D（destroy）callback，所有 Kind 应该有完整 CRUD"。选项 B —— inline 重写 SPEC #440，从 "EntityDeletion + tombstone" 转向 "Kind 生命周期 CRUD 对等"。r7 不跑 codex round（Allen 指令）。

**r7 变更 —— 整体 scope pivot：**

- **删除** 整个 tombstone 设计（r1–r6 机制）：`entity_tombstones` DB 表、ETS 镜像、`Ezagent.SpawnRegistry.tombstone_and_kill/1` 原子 primitive、三 spawn 路径的多边界 `tombstoned?/1` 检查、append-only "permanent deny" 语义、OQ-1 TTL 讨论，以及全部 r1–r6 codex review 关于 tombstone 正确性的回复。
- **新增** `Ezagent.Kind.destroy/2` callback 到 `Ezagent.Kind` behaviour。这是结构性修复 —— 目前 Kind 暴露 `type_name/0`、`behaviors/0`、`persistence/0`、`uri_from_args/1`、`snapshot_version/0`、`supervisor/0`、`spawn_strategy/0`、`terminate_strategy/0`、`holds_cap?/2`（CRUD 的 C 和 R 加操作元数据）但**没有 D**。r7 关闭这道缺口。
- **新增** `Ezagent.Kind.Server.destroy/2` 公共 API，编排：`Adapter.can_destroy?/2` → `kind.destroy/2`（每 Kind 自洁）→ `DynamicSupervisor.terminate_child/2`（优雅 —— **不是** `:brutal_kill`）→ snapshot purge → DB 行删除 → cross-ref scrub → audit emit。
- **新增** DB-backing check 到每个已注册的 SpawnRegistry entity callback。若 `Users.get_by_uri(uri) == nil` 对于 `entity://user/...`，spawn fn 返回 `{:error, :no_backing_entity}` 而不是 spawn。这用 "DB-row-is-truth" 语义替代 tombstone 的 "permanent deny"：删除 = DB 行去除，再创建 = DB 行 insert，下次 spawn = 全新 Kind。
- **扩展** `Ezagent.AgentBridge.Adapter` behaviour，加 `teardown/1` 可选 callback（默认 no-op）—— 与 `deliver/2` / `handle_client_event/3` / `join_info/2` 平行。每 flavor sidecar 清理（cc unbind BridgeRegistry，codex 停 sidecar+app_server+PTY+ 删 per-agent dir，echo no-op，curl no-op，np 停嵌套进程状态）。Agent Kind 的 `destroy/2` 委托给 `AgentBridge.Adapter.teardown/1` 保 plugin isolation。
- **Workspace 删除不再排除** —— 自然归入同一机制。`Workspace.Kind.destroy/2` 遍历 member entities 并对每个 call `Ezagent.Kind.Server.destroy/2`（cross-Kind cascade）。Workspace 删除与所有 Kind 共用本 SPEC 定义的 primitives。
- **§1 问题陈述重新 scope**，从 "ghost user 是特例" 转为 "Kind 契约缺 CRUD 的 D"。`system/linyilun` ghost 只是更大缺口的一个实例。
- **Re-register 自然支持** —— `Users.create(deleted_uri, ...)` 写新行；下次 `SpawnRegistry.spawn` 成功因 DB-backing check 通过；新 Kind 启动**无继承状态**（caps、memberships、snapshot —— 全消失，fresh init）。
- **PR 序列重订** —— PR-A（本 SPEC）→ PR-B 核心（Kind.destroy callback + Kind.Server.destroy/2 + SpawnRegistry DB-backing check + AgentBridge.Adapter.teardown 扩展）→ PR-C 域 Kind 实现（User.destroy + Agent.destroy + Session.destroy + Workspace.destroy + Worker.destroy）→ PR-D 插件 bridge teardown 实现（cc / codex / echo / curl / np）→ PR-E admin LV destroy UI + CLI。
- **§5 INV** 重编号：tombstone 专用 INV（INV-2 `:tombstoned`、INV-2a/2b 边界 check、INV-11 ETS reload、INV-13a system principal）移除；用 `:no_backing_entity` 语义替换。两个**新** INV：**INV-13** 同 URI re-register 工作（无继承状态）；**INV-14** cross-Kind cascade（Workspace.destroy 级联到 member）。
- **§10 OQ 精简**：OQ-1（tombstone TTL）+ OQ-8（NOT NULL migration 时机 —— backfill 保留如原文但不再是开放问题）**移除**。一个新 OQ：`Ezagent.Kind.destroy/2` 应该 REQUIRED 还是 OPTIONAL（默认 no-op）？推荐 REQUIRED —— 强制每个 Kind 作者思考清理。

**r1–r6 历史（压缩）：** 六次前序修订解决 codex 对 tombstone 设计的发现（多边界强制、原子 primitive、Session owner scrub 走 Chat action、Worker URI 列添加、entity_tokens cascade、system principal 窄化、三 data_owner 站点 cold-load 防御、Chat behavior 5-part 接线）。这些机制在 r7 下作废；幸存的教训（"DB-row-is-truth"、"每个读站点问 source of truth"、"behavior 注册是 N-part —— actions / required_caps / cap_subjects / invoke / interface / register_chat_behaviors"、"结构清理 over policy flag"）支撑 r7 设计，但 tombstone artifact 完全移除。

**层级：** `Ezagent.Kind` behaviour 扩展（`apps/ezagent_core/`）+ `Ezagent.Kind.Server` 公共 destroy API（`apps/ezagent_core/`）+ `Ezagent.AgentBridge.Adapter.teardown/1` 扩展（`apps/ezagent_domain_agent_bridge/`）+ per-Kind `destroy/2` 实现在自家 domain app + per-flavor teardown 实现在自家 plugin。Admin LV 集成在 `apps/ezagent_plugin_liveview/`。

**触发：** Allen 2026-05-28 —— 观察到 `system/linyilun` ghost-user 问题（DB + snapshot 已删，但 Kind 继续通过 SpawnRegistry catch-all 重生）。r1–r6 试图用 tombstone 修复；r7 转向 Allen 指出的结构性修复：每个 Kind 都需要 `destroy` callback，且 SpawnRegistry 的 entity callback 必须检 DB-backing 而非维护单独 "tombstoned" flag。

**伴侣：** `2026-05-28-entity-deletion.md`（按 `feedback_bilingual_docs_convention`）。

**先验记忆（load-bearing）：**
- `feedback_let_it_crash_no_workarounds` —— r7 pivot 本身就是它的应用：tombstone flag 是 POLICY（append-only deny-list、单独表、多边界强制）。DB-row-is-truth + Kind.destroy 是 STRUCTURAL（DB 行就是 source of truth；缺席即缺席；存在即存在；删除不写额外东西）。
- `feedback_north_star_plugin_isolation` —— `Ezagent.Kind.destroy/2` 是 behaviour callback（每 plugin 的 Kind 实现它）；`AgentBridge.Adapter.teardown/1` 是 per-flavor callback（每 bridge plugin 实现它）；通用编排在 `Kind.Server.destroy/2`。写新 Kind 的 plugin 作者加 `destroy/2`；写新 bridge flavor 的 plugin 作者加 `teardown/1`。零碰核心。
- `feedback_completion_requires_invariant_test` —— INV-13（同 URI re-register 工作）是架构目标 gate：INV-13 通过证明 "DB-row-is-truth" 语义为真，不只是声称。INV-14（cross-Kind cascade）是 workspace-as-Kind gate。
- `feedback_uuid_is_canonical_identifier` —— 操作 URI 不操作显示名。同 URI re-register 被允许**因为** URI 是规范的；第二个 incarnation 与第一个结构上不同（不同 snapshot、不同 caps、不同 memberships）但运行在同一地址。
- `feedback_destructive_migration_anti_pattern` —— 生产中销毁 LIVE entity 需 operator 知情。SPEC 含 LV confirm dialog + `mix ezagent.kind.destroy` CLI gate。
- `feedback_register_lookup_key_parity` —— entity spawn lookup 与 Kind.destroy 必须用同一 identity key（URI）。Key 分叉 = ghost 重引入风险。

**Parent / 历史背景：**
- `system/linyilun` retire（2026-05-26）：经验上的触发源。部分删除留下 in-memory Kind 通过 SpawnRegistry catch-all 重生，因为 entity callback 对 backing 数据**无**check —— 对任何 `entity://user/...` URI 无条件 spawn User Kind。r7 用 DB-backing check 修复；更大的缺口（CRUD 缺 D）由 `Kind.destroy/2` 解决。
- `2026-05-27-workspace-cap-based-visibility.md`：`Workspace.list_workspaces_for/2` 用 cap-membership 派生 visibility。被销毁用户的 caps 在 `User.destroy/2` 中被撤销，所以 visibility 作为结果消失。
- `2026-05-27-uri-canonicalization.md`：destroy 在每个 cascade step 用严格等号比 URI；canonical URI 形式让 cascade audit 可靠。

---

## §1 问题陈述 —— Kind 契约缺 CRUD 的 D

### 1.1 经验观察

Allen 在 2026-05-26 尝试通过 DB 端清理 retire `entity://user/system/linyilun`：

1. **DB 层** —— 完成：`users` 行已删，`entity_profiles` 已删，`kind_snapshots` 已删，`feishu_user_bindings` 重绑到 `system/admin`。
2. **Runtime 层** —— 留尾巴：`KindRegistry.lookup("entity://user/system/linyilun")` **仍** 返回 `{:ok, pid}` 因 entity callback（`SpawnRegistry.register("entity", fn ...)`）无 DB-backing check；任何调 `SpawnRegistry.spawn(deleted_uri)` 的路径都从 defaults 复活 Kind。三次 `brutal_kill` 配每次删 snapshot：下次 lookup ghost 仍活。
3. **用户面症状：** caller_uri 仍合法；LV 显示名 + cookie session identity 解析到 ghost；以 system/linyilun 身份 dispatch 拿 `chat.join` cap denied（caps 已被清空）但 IDENTITY 本身**不是** "已删" —— 是 "存在但无权限"。Operator UX 暗示 "此用户无 caps" 而不是 "此用户不存在"。

### 1.2 诊断：Kind 契约 CRUD 缺 D

`Ezagent.Kind`（`apps/ezagent_core/lib/ezagent/kind.ex:1-182`）是每个 Kind 实现的 behaviour。当前 callback 覆盖：

- **C（Create）：** `uri_from_args/1` + `spawn_strategy/0` + Kind args 接线。
- **R（Read）：** `behaviors/0` + slice 访问通过 `Ezagent.Kind.get_slice/2` + `holds_cap?/2`。
- **U（Update）：** Behavior dispatch（`Behavior.invoke/4`）变更 slice state；`persistence/0` policy + snapshot。
- **D（Destroy）：** **缺失**。没有 callback 表示 "拥有此 URI 的 Kind 正被永久 retire；在 supervisor 终止 GenServer 前做 per-Kind 清理（in-memory teardown、外部资源释放、side-effect 通知）"。

Ghost 问题是症状。更深的缺口是 operator（以及我们要建的通用 destroy 编排器）无处可问 Kind："你正被销毁 —— 你需要清理什么？" 今天每个 Kind 必须被一个知其内部的外部 cascade 拆掉 —— 这违反 plugin isolation。

`system/linyilun` 案例让此具体化：User 有 Feishu binding、profile 行、entity_tokens、workspace membership、它拥有的 session。**没一项**是 core 的责任；**全部**是 User 内部。无 `User.destroy/2` callback，destroy 编排器（或跑 SQL 的 operator）必须知 User 内部 —— 而这正是 Kind 边界本应隐藏的。

### 1.3 destroy 后的 identity 可达性

一个 URI "已销毁" iff：

- `Users.get_by_uri/1`（或 per-Kind 等价）返回 `nil`（DB 行是 source of truth）
- `Ezagent.SpawnRegistry.spawn(uri)` 返回 `{:error, :no_backing_entity}`（entity callback 检 DB；无行就拒 spawn）
- `Ezagent.KindRegistry.lookup(uri)` 返回 `:error`（Kind 已终止；Registry drop 死 pid）
- 没有 Kind 从任何路径重生（workspace member 遍历、Feishu binding lookup、LV session cookie、其它 agent reply 的 dispatch、adapter reconcile、……），因为每个最终调 `SpawnRegistry.spawn/1` 的路径拿到 `:no_backing_entity`
- `Workspace.list_workspaces_for/2` 在每个 caller 视图中排除他们（caps 撤销 + memberships 由 `User.destroy/2` 删除）
- 交叉引用（sessions slice owner_uri、audit rows）由责任 Kind 的 `destroy/2` scrub 或置 nil
- per-Kind 外部资源被释放（Agent 的 sidecar 通过 `AgentBridge.Adapter.teardown/1`，Worker 的 adapter terminate，等）

这些不是分立的临时清理 —— 它们是 `Ezagent.Kind.Server.destroy/2` 调 Kind 自己 `destroy/2` callback 的输出。同 URI 重加一行 re-enable spawn，下次 spawn 产生全新 Kind（无继承状态）。

### 1.4 本条预防的 bug class

- "我删了 user X 但他们仍能发 Feishu 消息"（binding lookup 命中重生 Kind，因无 DB-backing check）
- "我删了 user X 但他们拥有的 session 仍路由到他们"（Session.destroy/2 从未调；或 User.destroy/2 没 scrub Session.owner_uri）
- "我删了 user X 但旧 cli token 仍认证"（User.destroy/2 没撤销 entity_tokens）
- "我删了 agent Y 但它的 cc bridge 仍连着"（Agent.destroy/2 没调 AgentBridge.Adapter.teardown/1）
- "我把 user X 从 workspace W 移除但他们仍能在下拉里看到 W"（caps 未由 User.destroy/2 撤销）
- "罕见 boot，已删 user X 复活"（SpawnRegistry entity callback 无 DB-backing check）
- "我删了 Worker W 但 external_mirror_bindings 仍让 adapter reconcile spawn 新的"（Worker.destroy/2 没删 bindings；`worker_uri` 列让查询直接定位行）
- "我删了 Workspace W 但其 member User Kind 仍活"（Workspace.destroy/2 没遍历 + 对每个 member 调 Kind.Server.destroy/2）

全部八条在 `Ezagent.Kind.destroy/2` + DB-backing check 下成为回归测试。前六条今日已观察到或理论上可观察；#7 是 r1–r2 重发的 B5 bug；#8 是先前 SPEC 显式排除的 workspace 删除 case。

---

## §2 决策：**`Ezagent.Kind.destroy/2` callback + `Kind.Server.destroy/2` 编排器 + DB-backing spawn**

`Ezagent.Kind` behaviour 获得 `destroy/2` callback（D）。`Ezagent.Kind.Server` GenServer 获得公共 `destroy/2` API 编排结构序列。SpawnRegistry entity callback 获得 DB-backing check（无行就拒 spawn）。`AgentBridge.Adapter` behaviour 获得可选 `teardown/1` callback 用于 per-flavor sidecar 清理。

```elixir
# Ezagent.Kind behaviour 扩展
defmodule Ezagent.Kind do
  # ... 已有 callback：type_name/0、behaviors/0、persistence/0、
  #     uri_from_args/1、snapshot_version/0、supervisor/0、
  #     spawn_strategy/0、terminate_strategy/0、holds_cap?/2 ...

  @doc """
  CRUD 的 D。由 `Ezagent.Kind.Server.destroy/2` 在 GenServer 终止
  **前** 调。Per-Kind 清理：释放外部资源（sidecar、文件句柄、
  socket），scrub Kind 自己持有的 cross-reference（User scrub 它
  创建的 Session.owner_uri，Agent scrub 它的 bridge registry
  binding），撤销 caps，删除 memberships。

  接收被销毁的 URI + destroy 上下文（caller、reason、trace_id）。
  完全成功返回 `{:ok, summary}`，per-Kind 清理失败返回
  `{:error, reason}`。返回错误**不**阻止 GenServer 终止 ——
  destroy 从 per-Kind 视角是 best-effort；编排器记录部分结果并
  继续终止。
  """
  @callback destroy(uri :: URI.t(), ctx :: %{caller: URI.t(), reason: String.t(), trace_id: binary()}) ::
              {:ok, summary :: map()} | {:error, reason :: term()}
end
```

```elixir
# 公共 destroy API —— operator / admin LV / CLI 用的入口
defmodule Ezagent.Kind.Server do
  @doc """
  销毁 `target_uri` 处的 Kind。编排：
    1. `Adapter.can_destroy?/2`（per-Kind 预检）—— 拒绝则中止
    2. `kind.destroy/2`（per-Kind 清理 callback）—— best-effort
    3. `DynamicSupervisor.terminate_child(supervisor, pid)`（优雅，
       **不是** brutal_kill —— Kind 的 `terminate/2` 运行；当前
       slice 的 :on_terminate snapshot 跳过，因 §3.4 紧接着删除该行）
    4. Snapshot purge：`Repo.delete(KindSnapshot, uri_str)`
    5. DB 行删除：`kind.delete_db_row(uri)`（per-Kind 钩入
       Users.delete / Agents.delete / Workspace.delete / 等）
    6. Audit emit：`invocations` 行 `action = "kind.destroyed"`
       含 trace_id、caller、reason、per-step 子行

  Destroy 后重 spawn：SpawnRegistry entity callback 见
  `Users.get_by_uri(uri) == nil` 并返回 `{:error, :no_backing_entity}`。
  无需 tombstone —— DB 行**就是** source of truth。

  返回 `:ok | {:error, {:partial, ...}} | {:error, {:precheck_failed, _}}`。
  """
  @spec destroy(URI.t(), ctx :: %{caller: URI.t(), reason: String.t()}) ::
          {:ok, summary :: map()}
          | {:error, {:partial, map()}}
          | {:error, {:precheck_failed, term()}}
  def destroy(%URI{} = target_uri, ctx), do: ...
end
```

```elixir
# Ezagent.AgentBridge.Adapter behaviour 扩展
defmodule Ezagent.AgentBridge.Adapter do
  # ... 已有 callback：flavor/0、agent_uri_prefix/0、deliver/2、
  #     handle_client_event/3、join_info/2 (可选)、socket_path/0、
  #     channel_topic_prefix/0 ...

  @doc """
  Per-flavor bridge teardown。Agent.destroy/2 销毁 Agent 时调。
  默认 no-op（echo / curl）。持有外部状态的 plugin 实现：cc unbind
  BridgeRegistry，codex 停 sidecar + app_server + PTY + 删
  per-agent dir，np 停嵌套进程状态。

  Best-effort —— 错误被记录但不阻塞 destroy 流水线。Agent Kind
  反正要消失。
  """
  @callback teardown(agent_uri :: URI.t()) :: :ok | {:error, term()}

  @optional_callbacks teardown: 1, join_info: 2, socket_path: 0,
                      channel_topic_prefix: 0
end
```

```elixir
# 每个 SpawnRegistry entity callback 注册的扩展
# (apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex:222,
#  apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:493)
SpawnRegistry.register("entity", fn uri ->
  case uri.host do
    "user" ->
      # 新增：DB-backing check。行是 source of truth。
      if Users.get_by_uri(uri) == nil do
        {:error, :no_backing_entity}
      else
        initial_caps = User.initial_caps_for_spawn(uri)
        Ezagent.Kind.spawn(User, %{uri: uri, initial_caps: initial_caps})
      end

    "agent" ->
      # 同模式；Agents.get_by_uri/1 是 per-Kind 等价。
      if Agents.get_by_uri(uri) == nil do
        {:error, :no_backing_entity}
      else
        # ... 已有 Agent spawn 逻辑 ...
      end

    other -> {:error, {:no_entity_host_handler, other}}
  end
end)
```

字段名平行刻意：`destroy/2` 镜像 `init_slice/1`（Behavior callback 创建 Kind 初始状态）。已经知道写 CRUD 的 C 的 plugin 作者现在有写 D 的明确去处。

---

## §3 语义 —— `Kind.destroy/2` + `Kind.Server.destroy/2` 精确定义

### 3.1 `Kind.Server.destroy/2` 输入

- `target_uri` —— 被销毁 Kind 的 `%URI{}`。必须在 SpawnRegistry scheme 中已注册。
- `ctx.caller` —— 做 destroy 的 operator URI。必须持销毁此 Kind 的 cap（见 §3.2 cap shape）。
- `ctx.reason` —— operator 提供的自由文本。存到 audit 行。**非可选**。

### 3.2 Cap-gating

Destroy 操作是 cap-gated。Cap shape：

```
Capability{
  kind: <target_kind_module>,   # e.g. Ezagent.Entity.User
  behavior: Ezagent.Kind,        # 拥有 destroy/2 的 behaviour
  action: :destroy,
  instance: :any | <specific_uri>,
  workspace_uri: :any | <workspace>
}
```

默认仅 admin（`system://bootstrap/default` 携带 `instance: :any` + `workspace_uri: :any`）。Workspace admin **可** 持窄化 cap（`workspace_uri: <他们的 workspace>` 内 `instance: :any`）。Per-Kind 政策可通过 `can_destroy?/2` 细化（§3.3）。

### 3.3 通过 `Adapter.can_destroy?/2` 预检

每 Kind 预检，在任何 mutation 前运行。用于 cap 系统表达不了的不变性（如 "bootstrap admin 不可销毁"、"不能销毁唯一 workspace admin"）。返回 `:ok | {:error, reason}`。如 `{:error, _}`，destroy 中止 `{:error, {:precheck_failed, reason}}`，**无** state mutate。

```elixir
@callback can_destroy?(uri :: URI.t(), ctx :: map()) ::
            :ok | {:error, reason :: atom() | {atom(), term()}}
```

每个 Kind 模块定义自己的 `can_destroy?/2`。不变性示例：
- `User.can_destroy?` 拒绝 bootstrap admin URI
- `Workspace.can_destroy?` 拒绝含 operator 不能一并销毁的活 member 的 workspace
- `Agent.can_destroy?` **可** 拒绝当前服务 in-flight session 的 Agent（operator-policy 决策）

### 3.4 编排序列（§2 编号列表，展开）

`Kind.Server.destroy/2` 体：

1. **预检。** 调 `kind_module.can_destroy?(target_uri, ctx)`。出错 → 返回 `{:error, {:precheck_failed, reason}}`；无 mutation。
2. **生成 `trace_id`。** 新 UUID；穿过每个 sub-row。
3. **调 `kind_module.destroy(target_uri, ctx_with_trace)`。** Per-Kind 清理（释放 sidecar、scrub cross-ref、撤销 caps、删 memberships）。返回 `{:ok, summary} | {:error, reason}`。出错：audit 记录 per-Kind 失败但**继续**（destroy 从 per-Kind 视角是 best-effort；Kind 反正要走）。
4. **定位活 pid。** `KindRegistry.lookup(target_uri)`。两支：
   - `{:ok, pid}` —— 进 step 5。
   - `:error` —— Kind 当前不活（仅 snapshot）。跳 step 5；进 step 6。
5. **优雅终止 GenServer。** `DynamicSupervisor.terminate_child(kind_module.supervisor(), pid)`。运行 Kind 的 `terminate/2` callback（若有），给 Behavior 最后一公里 drain 的机会。**不是** `:brutal_kill` —— 此处无 vs 重生竞速，因 step 6 删 DB 行后 SpawnRegistry entity callback 即见 `:no_backing_entity`。Kind 不能重生即使并发 dispatch 在 step 5 和 6 之间触发，因为：
   - 终止后的 registry lookup 返回 `:error`（Registry drop 死 pid）；
   - entity callback 的 DB-backing check 还未翻转（DB 行 step 6 前仍在），所以 step 5 和 6 间并发 spawn **会** 成功 —— 但产生的新 Kind 自身无害：其 `init_slice/1` 在空 snapshot 路径运行（step 7 仅在 step 5 后删 snapshot，所以中间竞速进来的 Kind 仍从即将被删的 snapshot load）；重 spawn 它的 dispatch 看到的 Kind 带有先前 state。窗口由 `terminate_child/2` 返回与 `Repo.delete(user)`（step 6）间的时间限制 —— 单 Repo transaction 内 < 1ms。
   - **要完全闭合竞速**，step 5 + 6 包在 Repo transaction 内：step 6 的 DB 行删除与 pre-step-6 audit 行**原子**提交，Registry 的死-pid-drop 保证在任何并发 `SpawnRegistry.spawn` 调走新 entity-callback 路径前发生（因 `Registry.unregister` 在 `terminate_child/2` 内同步）。竞速详析见 §3.6。
6. **DB 行删除。** `kind_module.delete_db_row(target_uri)` —— per-Kind 钩入 domain 的 `delete/1`（如 `Users.delete/1`）。这是 "DB 行是 truth" 的提交：此后**每个** `SpawnRegistry.spawn(target_uri)` 调用返回 `{:error, :no_backing_entity}`，因 entity callback 的 `get_by_uri/1` 返回 `nil`。
7. **Snapshot purge。** `Repo.delete(Ezagent.Ecto.KindSnapshot, uri_str)`。幂等。排在 step 5 + 6 **后** 以让 step 5 的重生竞速仍 load 有效 snapshot state；排在 step 8 audit emit **前** 以让 audit 见干净 post-state。
8. **Audit emit。** 单 `invocations` 行 `action = "kind.destroyed"` + step 3 `kind.destroy/2` summary 的 per-step 子行。共享 `trace_id`。

### 3.5 Per-Kind `destroy/2` 责任

每个 Kind 的 `destroy/2` callback 做 Kind 内部清理。下方清理步骤替换 r1–r6 SPEC 称为 "cascade steps" 的东西 —— 它们现在是 Kind 责任，不是编排器责任。

**User cascade（User.destroy/2）：**

```
:revoke_all_caps                Identity.revoke_all_caps(user_uri)
:revoke_entity_tokens           Repo.delete_all(EntityToken WHERE entity_uri = user_uri)
:drop_feishu_bindings           Repo.delete_all(feishu_user_bindings WHERE user_uri = user_uri)
:drop_entity_profile            Repo.delete(EntityProfile, uri_str)
:drop_workspace_memberships     Enum.each(workspaces, &Workspace.remove_member/2)
:drop_session_memberships       Enum.each(sessions, &Chat.leave/2)
:scrub_session_owner_uri        Enum.each(owned_sessions, &dispatch Chat.scrub_owner/0)
```

注意 `:scrub_session_owner_uri` 仍走 `Behavior.Chat.invoke(:scrub_owner, ...)` dispatch 模式（r1–r6 设计正确识别 —— 这是 cross-Kind state mutation 的对的形状）。Cap-gating + system principal（`system://kind-destroy-cascade`）详见 §3.7。

**Agent cascade（Agent.destroy/2）：**

```
:teardown_bridge                AgentBridge.Adapter.teardown(agent_uri)   [新 per-flavor callback]
:revoke_entity_tokens           Repo.delete_all(EntityToken WHERE entity_uri = agent_uri)
:drop_session_memberships       Enum.each(sessions, &Chat.leave/2)
:scrub_mention_routing_rules    RoutingRules.remove_by_target(agent_uri)
:revoke_agent_api_keys          AgentApiKeys.revoke_all(agent_uri)
:drop_agent_lineage             AgentLineage.delete(agent_uri)
:delete_workspace_template      Workspace.remove_template/3 (若已注册)
```

`:teardown_bridge` 步骤委托给 `AgentBridge.Adapter.teardown/1` —— 每个 flavor adapter 清理**自家** sidecar，不需 Agent.destroy 知道 cc vs codex vs echo 内部。这是 plugin isolation 应用到 teardown 表面。

**Session cascade（Session.destroy/2）：**

```
:drop_session_members           清 member 列表
:emit_session_destroyed         PubSub.broadcast({:session_destroyed, session_uri})
:unsubscribe_publisher          Publisher.unsubscribe_all(session_uri)
```

Session 除 slice 外大多无状态 —— 其 "member" 多是指针（User URI），非自有 state。Destroy 因此比 User / Agent 轻。

**Workspace cascade（Workspace.destroy/2）：**

```
:cascade_member_destroys        Enum.each(member_uris, &Kind.Server.destroy(_, ctx_with_parent_trace))
:cascade_template_destroys      Enum.each(template_uris, &Kind.Server.destroy(_, ctx_with_parent_trace))
:cascade_session_destroys       Enum.each(workspace_sessions, &Kind.Server.destroy(_, ctx_with_parent_trace))
:drop_workspace_caps            CapabilityRegistry.drop_workspace(workspace_uri)
:delete_workspace_row           Workspaces.delete(workspace_uri)
```

这是 r1–r6 SPEC 排除为 out of scope 的 cross-Kind cascade。在 r7 下它只是另一个 `destroy/2` 实现，恰好对其 member 调 `Kind.Server.destroy/2`。递归终止因每个 member 是叶 Kind（User / Session / Agent），其 `destroy/2` 不递归回 workspace。Trace correlation：所有子 destroy 共享父 workspace destroy 的 `trace_id` 以便 audit 分组。

**Worker cascade（Worker.destroy/2）：**

```
:drop_external_mirror_bindings  Repo.delete_all(BindingRow WHERE worker_uri = worker_uri)
:unsubscribe_session_publisher  Publisher.unsubscribe(worker_uri)
:terminate_adapter              adapter_module.terminate(worker_uri)
```

要 `external_mirror_bindings.worker_uri` 是真列（r1–r2 的 B5 列添加）。列保留（它结构正确 —— `worker_uri` 是有用的去规范化索引，与 tombstone 无关）。r1–r6 §4.1 + §9.1 的两-migration + backfill 任务原样保留；r7 下该列由 Worker.destroy/2 消费而非 cascade Adapter。CRIT-4.2 的 BindingRow schema / cast / validate_required 更新也保留。

### 3.6 竞速分析 —— destroy 期间的并发 dispatch

r7 设计用 Repo-transaction-based 顺序替代 r1–r6 的 tombstone-based 竞速消除。关键不变性：**DB 行删除提交早于 GenServer 的 Registry 注册可重用于新 spawn**。

五个竞速窗：

1. **Dispatch 在 step 1 前到达。** 正常 dispatch；Kind 活；无 destroy 进行。已有 CapBAC 处理。
2. **Dispatch 在 step 1 和 3 之间到达。** 预检通过但无 mutation。Dispatch 见健康 Kind；成功。后续 destroy 独立进行。无竞速 —— dispatch 效应在 destroy mutate 任何东西前由仍活 Kind 处理。
3. **Dispatch 在 step 3 和 5 之间到达。** Per-Kind `destroy/2` 已跑（caps 撤销、memberships 删除）。Kind 仍活。Dispatch 的 cap-check 可能现在失败（caps 撤销）—— 这是**正确** 行为；entity 在 destroy 中且不再被授权。如 dispatch 恰好调不需被撤销 caps 的 Behavior，它对垂死 Kind 成功 —— 也可接受；Kind 的 slice 变更即将和 step 7 的 snapshot purge 一起被丢。
4. **Dispatch 在 step 5 和 6 之间到达。** GenServer 在终止；`KindRegistry.lookup/1` 返回 `:error`（Registry 在 `terminate_child/2` 返回路径中同步 drop 死 pid）。如 dispatch 走 `SpawnRegistry.spawn/1`，entity callback 见 DB 行仍在（step 6 还未跑）并 spawn 新 Kind。这个 Kind 从仍在的 snapshot load，snapshot 即将在 step 7 删除。Step 5 返回与 step 6 提交间的窗口在单 Repo transaction 内 < 1ms。**缓解：** step 5 + 6 + 7 包在 `Repo.transaction/1`。Transaction 提交是线性化点；transaction 内 step 5 和 step 6 间无 spawn 可能，因 step 6 的 `Repo.delete(user)` 从 transaction 开始就持 `users` 行的 row-level lock，任何并发 `SpawnRegistry.spawn → Users.get_by_uri` 要么 (a) 读 pre-delete state 并进行 spawn（可接受 —— destroy 还未提交，所以重 spawn 逻辑上是被 destroy 最终提交取消的 no-op + 产生的 Kind 在下次 supervisor-restart 周期见 snapshot purge），要么 (b) 读 post-delete state 并返回 `:no_backing_entity`。窗口由 transaction 结构限定。
5. **Dispatch 在 step 6 提交后到达。** DB 行已没。`SpawnRegistry.spawn/1` 的 entity callback 返回 `{:error, :no_backing_entity}`。Dispatch 干净失败。这是 destroy 后稳态。

**为什么这比 r1–r6 的 tombstone 结构更干净：** 先前设计需要**单独**表（`entity_tombstones`）+ ETS 镜像 + 多边界 check + 原子 primitive 专为 destroy 后阻止重生。r7 下 `users` 行的缺席**就是**预防；无额外东西需保持一致。代价是每次 spawn 多一次 DB 读（`get_by_uri/1` check），由 Repo 连接池限制并均摊到 spawn fn 已有成本。

### 3.7 Destroy 期间的 cross-Kind dispatch —— system principal

当 User.destroy/2 对每个 owned Session dispatch `Behavior.Chat.invoke(:scrub_owner, ...)`，dispatch 需 CapBAC 授权。Operator 在 User Kind 上的 `:destroy` cap **不** 满足 Session Kind 的 `Chat:scrub_owner`。Cascade 因此以专用窄 system principal `system://kind-destroy-cascade` 身份 dispatch（**仅** 携带 Chat:scrub_owner cap，按 r1–r6 CRIT-3.1 模式 —— 除命名外原样保留）。

`Behavior.Chat.invoke(:scrub_owner, ...)` action 体、`:scrub_owner` action 注册（5-part Chat behavior 接线：actions / required_caps / cap_subjects / invoke / interface + `register_chat_behaviors/0`）、`Chat.data_owner/1` 读站点 nil-owner 处理（现在无 tombstone 防御 —— 当 `owner_uri == nil` 按已有语义 fall through 到 `:no_owner`）、`Session.owner/1` cold-load 语义**全部**继承 r1–r6 设计。唯一 delta：读站点 SpawnRegistry tombstone 防御 check **替换** 为 `Users.get_by_uri(owner)` DB check，行缺席返回 `:no_owner`。这应用到全部三个 data_owner 解析器（Chat / ExternalMirror / Publisher.SessionImpl）—— CRIT-5.2 教训用不同 check 函数保留。

### 3.8 边界情况 —— bootstrap admin 保护

`entity://user/system/admin` **必须** 不可销毁。`User.can_destroy?/2` 硬编码这个（见 §3.3）：

```elixir
def can_destroy?(%URI{} = uri, _ctx) do
  if URI.to_string(uri) == URI.to_string(Ezagent.Entity.User.admin_uri()) do
    {:error, :bootstrap_admin_undestroyable}
  else
    :ok
  end
end
```

其他 Kind **可** 加类似受保护 URI（如 system orchestrator agent）。

### 3.9 边界情况 —— operator 销毁自己

工作区 admin 调 `Kind.Server.destroy(their_own_uri, ctx)` 继续：action 跑到完成因他们的 caps 在 step 1 评估 BEFORE User.destroy/2 剥离它们。LV 在 `users_live.ex` 拦截自销毁配 confirm-dialog 警告（"你正在销毁自己；你将被登出"）但不阻止 —— operator 可能有正当理由。（OQ-5 —— Allen 可能想要 second-admin gate。）

### 3.10 边界情况 —— destroy 后 re-register

`Kind.Server.destroy(uri)` 完成后，operator 可立即调 `Users.create(uri, ...)`。这：

1. 在同 URI 插新 `users` 行（新 password_hash、新 initial caps、新 metadata）。
2. 下次 `SpawnRegistry.spawn(uri)` 见 `Users.get_by_uri(uri)` 返回新行并 spawn。
3. 新 Kind 的 `init_slice/1` 从 defaults 跑 —— **无** snapshot（destroy 的 step 7 已 purge）、**无**继承 caps（step 3 撤销）、**无**继承 memberships（step 3 删）。
4. 新 Kind 与前 incarnation 结构上不同，尽管在同 URI 操作。URI 是名字，不是 identity；行的主键才是 identity。

这是 §5 的 INV-13。r1–r6 设计禁止（tombstone 是 append-only）；Allen pushback（2026-05-28 03:36）纠正方向。

### 3.11 边界情况 —— 销毁当前不活的 Kind

如 `KindRegistry.lookup(target_uri)` 返回 `:error`（Kind 无活 pid —— 仅 snapshot），step 5 跳过。DB 行删 + snapshot purge 仍进行。这没问题：无活 pid 可终止，post-destroy state 相同。

### 3.12 边界情况 —— `destroy/2` 返回 `{:error, _}`（per-Kind 清理失败）

编排器（§3.4 step 3）audit 记录 per-Kind 错误并继续。Step 5–8 仍执行。Destroy 返回 `{:error, {:partial, %{step_failed: :kind_destroy, kind_error: <内层>, steps_completed: [...]}}}` 让 operator 知 Kind 清理不完整（如 AgentBridge.Adapter.teardown 失败因 sidecar 已死 —— 通常无害）。DB 行 + snapshot 已没；URI 不再可达。Operator-runbook 决策：调查内层错误**或**接受 partial。

---

## §4 迁移方案

### 4.1 新代码（按 PR 顺序）

**PR-A（本 SPEC）。**

**PR-B 核心 —— Kind.destroy callback + Kind.Server.destroy/2 + SpawnRegistry DB-backing check + AgentBridge.Adapter.teardown 扩展：**

- **修改** `apps/ezagent_core/lib/ezagent/kind.ex` —— 加 `destroy/2` 到 `@callback` 列表。要么加到 `@optional_callbacks`（配 `Kind.default_destroy/2` 默认 no-op）**或**保 required（OQ-NEW —— Allen 决策）。
- **修改** `apps/ezagent_core/lib/ezagent/kind/server.ex` —— 加公共 `destroy/2` API 按 §2 + §3.4。包 step 5–7 在 `Repo.transaction/1` 内按 §3.6。
- **修改** `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex:222-258` —— 在 `"user" ->` arm 加 DB-backing check：`if Users.get_by_uri(uri) == nil, do: {:error, :no_backing_entity}, else: ...已有 spawn 逻辑...`。
- **修改** `apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:493+` —— `"agent" ->` 和 `"user" ->` arm 同模式。
- **修改** `apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/adapter.ex` —— 加 `teardown/1` 到 `@callback`，列在 `@optional_callbacks` 配默认 no-op（默认实现在 Adapter 模块自身用于 fallthrough）。
- **加** `Ezagent.SystemPrincipal.Catalog` 条目：`{"system://kind-destroy-cascade", [Capability.cap(Ezagent.Entity.Session, Ezagent.Behavior.Chat, :scrub_owner, :any, :any)]}`（从 r1–r6 的 `system://entity-deletion-cascade` 重命名）。
- **修改** `apps/ezagent_core/lib/ezagent_core/application.ex` —— 在已有 principal ensure 后加 `SystemPrincipal.ensure(SystemPrincipal.uri("kind-destroy-cascade"))`。
- **修改** `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex` —— 加 `:scrub_owner` action（完整 5-part Chat behavior 接线：actions、required_caps、cap_subjects、invoke、interface）。加 `Chat.data_owner/1` 变更：若 `Session.owner/1` 返回 `{:ok, owner}` 且 `Users.get_by_uri(owner) == nil`，返回 `:no_owner`（用 DB-backing check 替换 r1–r6 的 tombstone check）。
- **修改** `apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex` `register_chat_behaviors/0` —— 加 `CapabilityRegistry.register(Session, :scrub_owner, Chat)`。
- **修改** `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex` `data_owner/1` —— 同 DB-backing check 模式。
- **修改** `apps/ezagent_domain_chat/lib/ezagent/behavior/publisher/session_impl.ex` `data_owner/1` —— 同 DB-backing check 模式。
- **修改** `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex` `verify/2` —— 把 r1–r6 的 `SpawnRegistry.tombstoned?(uri)` check 替换为 `Users.get_by_uri(uri) == nil`（或 per-Kind 等价 —— `Agents.get_by_uri/1`）。同 defense-in-depth 目的；同 `Bcrypt.no_user_verify()` timing-leak 处理；新错误 tag `{:error, :no_backing_entity}`。
- `external_mirror_bindings.worker_uri` 列的 **migration**（Migration A `null: true` + backfill 任务 `mix ezagent.entity.backfill_worker_uri` + Migration B `NOT NULL`）—— 原样保留自 r1–r6 §4.1；它们独立有用，Worker.destroy/2 仍需要该列。
- **修改** `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/binding_row.ex` —— 加 `:worker_uri` 到 schema + `@type t` + cast + validate_required（CRIT-4.2 原样保留）。
- **修改** `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex` `:bind` action 体 —— 在 attrs map 填 `worker_uri`（B5 原样保留）。
- **从先前 PR-B 计划 REMOVE：**
  - `apps/ezagent_core/lib/ezagent/spawn_registry/tombstone.ex` —— 从未创建
  - `apps/ezagent_core/priv/repo/migrations/<timestamp>_entity_tombstones.exs` —— 从未创建
  - `Kind.Server.init/1` + `Kind.spawn/2` + `SpawnRegistry.spawn/1` 的三边界 tombstone 强制 —— 被每个 entity callback 的单 DB-backing check 替换
  - `Ezagent.SpawnRegistry.tombstone_and_kill/1` + `tombstoned?/1` —— 被 `Kind.Server.destroy/2` 的优雅 `terminate_child/2` + DB 行删除替换
  - `Ezagent.Behavior.EntityDeletion` + `EntityDeletion.Adapter` + `EntityDeletion.AdapterRegistry` —— 被 `Ezagent.Kind` 的 `Kind.destroy/2` callback + per-Kind 实现替换
- 测试：§5 invariant test + per-Kind destroy 单测 + 每个 entity callback 的 DB-backing-check 单测 + AgentBridge.Adapter.teardown 单测 + Chat.scrub_owner 单测 + 三站点 data_owner DB-backing-check 测试 + Token.verify DB-backing-check 测试。

**PR-C 域 Kind —— per-Kind `destroy/2` 实现：**

- `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex` —— 加 `destroy/2`（User cascade 按 §3.5）+ `can_destroy?/2`（bootstrap admin 保护）+ `delete_db_row/1` 钩入 `Users.delete/1`。
- `apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex` —— 加 `destroy/2`（Agent cascade 按 §3.5，委托 `AgentBridge.Adapter.teardown/1`）+ `can_destroy?/2`。
- `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex` —— 加 `destroy/2`（Session cascade 按 §3.5）+ `can_destroy?/2`。
- `apps/ezagent_domain_workspace/lib/ezagent/entity/workspace.ex` —— 加 `destroy/2`（Workspace cascade 按 §3.5，通过 `Kind.Server.destroy/2` 递归）+ `can_destroy?/2`。
- `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/worker.ex` —— 加 `destroy/2`（Worker cascade 按 §3.5，用 `worker_uri` 列）+ `can_destroy?/2`。

**PR-D 插件 bridge teardown 实现（每个 plugin 在其 `AgentBridge.Adapter` 实现加 `teardown/1`）：**

- `apps/ezagent_plugin_cc/...` —— `teardown/1` 调 `BridgeRegistry.unbind(agent_uri)`。
- `apps/ezagent_plugin_codex/...` —— `teardown/1` 停 sidecar + app_server + PTY + 删 per-agent dir。
- `apps/ezagent_plugin_echo/...` —— `teardown/1` no-op（无外部 state）。
- `apps/ezagent_plugin_curl_agent/...` —— `teardown/1` no-op。
- `apps/ezagent_plugin_np/...` —— `teardown/1` 停嵌套进程 state。

**PR-E admin LV destroy UI + CLI：**

- 修改 `users_live.ex` —— 加 destroy 按钮 + confirm dialog + reason input + type-the-URI 确认（OQ-9 默认）。
- 修改 `identities_live.ex` —— per-row destroy action。
- 修改 `agent_detail_live.ex` —— agent 详情页 destroy action。
- 修改 `workspaces_live.ex` —— destroy workspace（r7 下**现在在 scope** —— 见 §3.5 Workspace cascade）。
- 加 `mix ezagent.kind.destroy <uri> --reason "<reason>"` CLI 任务。

### 4.2 向后兼容

**无**已有代码路径被移除。**无**对 `Users.delete/1`（或 per-Kind 等价）语义的变更 —— 这些路径仍作为 LOW-LEVEL DB-only 删除存在，但会发出 deprecation 警告建议 `Kind.Server.destroy/2`。迁移目标：在后续 PR（PR-E 之后），把每个 `XXX.delete/1` 标为 `@deprecated` 并将 operator-facing 调用站点经 `Kind.Server.destroy/2`。

不实现新 `destroy/2` callback 的已有 Kind：若 callback OPTIONAL（OQ-NEW 默认），它们得到默认 no-op（仅 DB 行删 + snapshot purge —— 无 per-Kind 清理）。若 callback REQUIRED（推荐），PR-C 必须给**每个**已有 Kind 加 `destroy/2` 实现（User、Agent、Session、Workspace、Worker —— `apps/` 扫描显示当今唯五）。post-PR-B 加的新 plugin Kind 必须按 behaviour 契约实现 `destroy/2`。

### 4.3 生产数据 DB 迁移

`external_mirror_bindings.worker_uri` 列添加（forward-only）+ backfill 任务 + NOT NULL toggle —— 原样保留自 r1–r6。**无新表**（r1–r6 的 `entity_tombstones` 表从迁移计划**移除**）。Operator-可跑的 migration；NOT NULL toggle 在生产形态环境上 flag 为 operator action（停 phx、migrate、重启）。

### 4.4 协同 PR 序列

PR-A（本 SPEC）先 land。PR-B（核心）是**最小可上线** —— 加契约 + DB-backing check + AgentBridge.Adapter.teardown 扩展。PR-C（per-Kind destroy 实现）紧接 land；PR-C land 前每个 Kind 要么有默认 no-op `destroy/2`（若 optional），要么 PR-C 是单个原子加法（若 required）—— PR-C 不能在 PR-B 前 land 因 callback 不存在。PR-D（plugin teardown）可与 PR-C 并行 land（不同文件）。PR-E（LV UI + CLI）最后 land；依赖 PR-C 完成因 LV "destroy" 按钮必须调 `Kind.Server.destroy/2` 它 dispatch 到 per-Kind `destroy/2`。

Plugin-isolation north-star 保留：PR-B 加契约；PR-C/D/E 插入它。未来 Kind 加 `destroy/2` 不碰核心；未来 bridge flavor 加 `teardown/1` 不碰核心。

---

## §5 Invariant 测试 —— merge gate

按 `feedback_completion_requires_invariant_test`，本 SPEC "完成" iff 下面测试通过 AND 若任何部分实现被发货它会失败。

**文件：** `apps/ezagent_core/test/invariants/kind_lifecycle_invariant_test.exs`（从 r1–r6 的 `entity_deletion_invariant_test.exs` 重命名）。

**Setup**（DataCase, `async: false`）：

1. 创建非-admin User：`entity://user/team-alpha/test-destroyable` 通过 `Users.create/3`。
2. 授 caps + 加到 workspace + 绑 Feishu open_id + 通过 `Token.create/2` 铸 token。
3. 创建一个 `owner_uri = target` 的 Session（让 Session.owner_uri scrub 路径被运动）。
4. Spawn User Kind：`SpawnRegistry.spawn(target)` → `{:ok, pid}`。
5. 调 `Kind.Server.destroy(target, %{caller: admin_uri, reason: "test"})`。

**断言**（任一被违反测试失败）：

| # | 断言 | 它捕获什么 |
|---|---|---|
| INV-1 | `KindRegistry.lookup(target)` destroy 后返回 `:error` | Kind 未终止 → ghost 路由活 |
| INV-2 | `SpawnRegistry.spawn(target)` 返回 `{:error, :no_backing_entity}` | DB-backing check 缺或接线错 |
| INV-3 | `Users.get_by_uri(target)` 返回 `nil` | DB 行删除缺 |
| INV-4 | `Repo.get(EntityProfile, target_uri_str)` 返回 `nil` | Profile leak（User.destroy 没删它）|
| INV-5 | `Repo.get(KindSnapshot, target_uri_str)` 返回 `nil` | Snapshot purge 缺 → 行重建时复活 |
| INV-6 | `Repo.all(from f in feishu_user_bindings, where: f.user_uri == ^target_uri_str)` 返回 `[]` | Feishu binding scrub 缺 |
| INV-7 | 对每个 target 曾是 member 的 workspace W：`target NOT IN W.member_uris` | Membership scrub 缺 |
| INV-8 | 对每个 target 曾是 member 的 session S：`target NOT IN S.members` | Session membership scrub 缺 |
| INV-9 | `Workspace.list_workspaces_for(target, ...)` 抛或返回 `[]` | Visibility leak（caps 未撤销）|
| INV-10 | 存在 audit 行：`invocations` 配 `action = "kind.destroyed"`、`target = target_uri_str`、`caller = admin_uri_str`，**且**每个 per-Kind destroy 子步骤有同 `trace_id` 的子行 | Audit trail 不完整或 trace 关联坏 |
| INV-11 | 杀 BEAM（用 `Application.stop(:ezagent_core) + Application.start(:ezagent_core)` 模拟重启）。重启后：INV-1 + INV-2 + INV-3 仍成立。无需 tombstone 表查询；DB 行缺席足够。 | DB 行删除持久化失败 |
| INV-12 | `Kind.Server.destroy(Ezagent.Entity.User.admin_uri(), ...)` 返回 `{:error, {:precheck_failed, :bootstrap_admin_undestroyable}}` | Bootstrap admin 保护缺 |
| INV-13 | **（新 —— Allen pushback）** Destroy 完成后调 `Users.create(target, %{password: "fresh", ...})`（同 URI re-register）。断言：(a) `Users.get_by_uri(target)` 返回新行配新 password_hash + 新 metadata；(b) `SpawnRegistry.spawn(target)` 返回 `{:ok, fresh_pid}`（**不是** `:no_backing_entity`）；(c) `fresh_pid` 的 `:identity` slice 有新用户的 bootstrap caps，**不是**被销毁用户的旧 caps；(d) `:chat` slice（或哪个 Behavior 载 memberships）显示**零**旧 memberships；(e) `Repo.get(KindSnapshot, target_uri_str)` 是新的，不是被销毁 Kind 的旧 snapshot。 | Re-register 工作 AND 无继承状态 —— r7 pivot 的核心架构目标 |
| INV-14 | **（新 —— Workspace cross-Kind cascade）** 创建 workspace `entity://workspace/team-beta` 配 3 个 member（U1、U2、U3）。调 `Kind.Server.destroy(workspace_uri, ...)`。断言：(a) `Workspaces.get_by_uri(workspace_uri)` 返回 `nil`；(b) `Users.get_by_uri(U1)` 等返回 `nil`（cascade 也销毁 member）；(c) audit emit **一**父行 `action = "kind.destroyed"` for workspace_uri + 3 个 U1/U2/U3 子行共享父 `trace_id`。 | Workspace.destroy 没级联到 member —— r1–r6 排除在 scope 之外的 case |
| INV-15 | 对 setup 中为 target 铸的 token：`Token.verify(plain_token, target)` 返回 `{:error, :no_backing_entity}`（**不是** `{:error, :invalid_credentials}` 且**不是** `{:ok, _}`）。DB-backing check 在 bcrypt 比较**前**触发；`Bcrypt.no_user_verify()` 被调以打败 timing leak。 | Token defense-in-depth 缺或放在 bcrypt 后 |
| INV-16 | **（替换 r1–r6 INV-13b）** Destroy 后 cold-load 一个 `:chat` slice 含 `owner_uri = target` 的 snapshot Session。调**全部三**生产 data-owner 解析器并断言每个返回 `:no_owner`（**不是**被销毁 target URI）：(1) `Behavior.Chat.data_owner(S_uri)`；(2) `Behavior.ExternalMirror.data_owner(S_uri)`；(3) `Behavior.Publisher.SessionImpl.data_owner(S_uri)`。每个在读站点用 `Users.get_by_uri/1` DB-backing 防御。 | 三 data_owner 解析器跨站点 cold-Session 权限泄露 |
| INV-17 | PR-B + backfill 任务 + Migration B 后：`external_mirror_bindings` 每行 `worker_uri` 非 NULL 且等于 `WorkerSpawn.worker_uri_for(parsed_session_uri, adapter_id, target_id) |> URI.to_string()`。 | Backfill 错误（原样保留自 r1–r6 INV-15）|
| INV-18 | **（Agent bridge teardown）** Spawn Agent + 通过 cc flavor adapter 绑定其 bridge。调 `Kind.Server.destroy(agent_uri, ...)`。断言：`BridgeRegistry.lookup(agent_uri)` 返回 `:error`（cc 的 `teardown/1` unbind）。对 codex Agent：断言 sidecar 进程已退 + per-agent dir 已删。 | AgentBridge.Adapter.teardown/1 未接线或未从 Agent.destroy/2 调 |

**部分实现不能通过** —— 失败映射：

- 跳过 `Kind.destroy/2` callback 加：INV-3 + INV-4 + INV-6 + INV-7 + INV-8 失败（per-Kind 清理从未跑）
- 跳过 entity callback 的 DB-backing check：INV-2 + INV-13 (c) 失败
- 跳过 `Kind.Server.destroy/2` 编排器：INV-1 + INV-10 失败
- 跳过 `AgentBridge.Adapter.teardown/1`：INV-18 失败
- 跳过 Workspace.destroy/2 cascade：INV-14 失败
- 跳过 Token.verify DB-backing check：INV-15 失败
- 跳过三站点中任一 data_owner DB-backing check：INV-16 失败
- 跳过 bootstrap 保护：INV-12 失败

测试在**首次**不匹配失败，消息标识泄漏。

---

## §6 Plugin isolation 分析

按 `feedback_north_star_plugin_isolation`：

| 层 | 知道 | **不知**道 |
|---|---|---|
| `ezagent_core` | `Ezagent.Kind.destroy/2` callback、`Ezagent.Kind.Server.destroy/2` 公共 API、编排序列 | User 如何清 Feishu binding、Agent 如何终止 sidecar、Workspace 如何级联到 member |
| `ezagent_domain_identity` | `User.destroy/2`（User 清理）、`User.can_destroy?/2`（bootstrap admin）、它 entity callback `user ->` arm 的 DB-backing check | Agent / Session / Workspace / Worker 内部 |
| `ezagent_domain_chat` | `Agent.destroy/2` + `Session.destroy/2` + `:scrub_owner` Chat action 体；它 entity callback arm 的 DB-backing check | User / Workspace / Worker 内部 |
| `ezagent_domain_workspace` | `Workspace.destroy/2` 通过 `Kind.Server.destroy/2` 级联到 member | per-member 内部（每个 member 自己是 Kind，其 `destroy/2` 做自家清理）|
| `ezagent_domain_external_mirror` | `Worker.destroy/2` 用 `worker_uri` 列 | User / Agent / Session / Workspace 内部 |
| `ezagent_domain_agent_bridge` | `AgentBridge.Adapter.teardown/1` callback 契约（默认 no-op） | cc 如何 unbind、codex 如何停 sidecar |
| `ezagent_plugin_cc` / `codex` / `np` / `echo` / `curl_agent` | 如何拆它自己 sidecar（通过 `teardown/1`）| 其他 flavor 如何拆 |
| `ezagent_plugin_liveview` | 如何渲染 "Destroy" 按钮 + confirm dialog + 调 `Kind.Server.destroy/2` | per-Kind 清理语义 |

未来 plugin 作者加新 Kind：实现 `Ezagent.Kind` behaviour 含 `destroy/2`。**零变更** `ezagent_core` 必需。

未来 plugin 作者加新 bridge-backed flavor：实现 `AgentBridge.Adapter` behaviour 含 `teardown/1`。**零变更** `ezagent_core` 或 `ezagent_domain_agent_bridge` 必需。

通用 destroy 编排活在 `Kind.Server.destroy/2`。Plugin 作者不碰 —— 他们实现 callback，非编排器。

Tiebreaker 测试（"让 plugin 作者远离核心"）：`Kind.Server.destroy/2` 暴露内部 state 给 plugin 代码吗？答：不。编排器调 `kind_module.destroy(uri, ctx)` 拿回 `{:ok, summary} | {:error, reason}`。Plugin 的 per-Kind 实现从不见其他 Kind 的 destroy 路径，从不直接碰 SpawnRegistry entity callback（那些在 domain Application 的 `start/2`），从不自己调 `terminate_child/2`。✅

---

## §7 权衡 / 拒绝过的方案

### 7.1 "Tombstone + permanent-deny re-register"（r1–r6 —— Allen 2026-05-28 03:36 在 r7 拒绝）

r1–r6 设计安装 append-only `entity_tombstones` 表 + ETS 镜像 + 三 spawn 路径多边界 check。Destroy 后 URI **永久** 不可重生。Allen pushback："tombstone 永久不允许 re-register 很奇怪——重走创建流程就该可以" —— 让 URI 永久死即便 operator 想在同地址重建是 operator-hostile。且更深的缺口是 `Ezagent.Kind` 缺 CRUD 的 D；tombstone 是缺失 callback 的 workaround。

**r7 拒绝**：结构性清理（Kind.destroy callback + DB-row-is-truth + DB-backing spawn check）替换 policy 机制（tombstone flag + 多边界 deny）。Re-register 由结构机制自然支持（DB 行缺席 → spawn 拒；DB 行创建 → spawn 允）。新设计严格涵盖旧设计（每个 tombstone INV 映射到 DB-backing-check INV）AND 加 INV-13（re-register 工作）+ INV-14（Workspace cascade），旧设计不能满足。

### 7.2 "Soft delete" 配 `deleted_at` flag（拒绝 —— 保留自 r1）

`users.deleted_at` + 过滤每个读站点。同 anti-pattern：每个读站点变得负责过滤；漏一个 = ghost。纪律问题镜像 `2026-05-27-workspace-cap-based-visibility.md` 的 `visible: false`。r7 不加 flag —— 加 callback + 用行缺席作信号。

### 7.3 "用 Ecto soft-delete 库"（拒绝 —— 保留自 r1）

7.2 配库 wrapper。同根本脆性。r7 偏好结构 over policy 按 `feedback_let_it_crash_no_workarounds`。

### 7.4 "Per-entity-type Behavior `EntityDeletion`"（拒绝 —— r1 7.4 保留 + r7 加强）

r1–r6 设计用 `Ezagent.Behavior.EntityDeletion` 作入口 + `EntityDeletion.Adapter` 作 per-Kind cascade。r7 把这折叠进 `Ezagent.Kind.destroy/2` —— Kind 拥有它自己的清理，不是单独 adapter 模块。**为什么 r7 更干净：** PR-G（AgentBridge）的 cascade adapter 模式是给多 flavor 实现同操作的 cross-cutting 关注。Destroy 是 per-Kind，不是 per-flavor；Kind 自己是 callback 的合适去处。AgentBridge.Adapter.teardown/1 callback **仍** per-flavor（因 bridge teardown 真的是 per-flavor 且 Agent 委托给它）。

### 7.5 "不允许 runtime destroy；要求 operator-side DB script + phx restart"（拒绝 —— 保留自 r1）

今天的事实路径。在规模 N 失败（tenant 创建+销毁测试 entity 不能容忍 phx restart）。Allen 明确要 runtime 修复。r7 关闭这个。

### 7.6 "Optional `destroy/2` callback 配默认 no-op"（r7 中考虑 —— OQ-NEW）

若 `destroy/2` OPTIONAL，无实现的已有 Kind 得到默认（仅 DB 行删 + snapshot purge —— 无 per-Kind 清理）。优：迁移成本低；已有 Kind PR-C 不碰它们仍工作。缺：每个 Kind 默默泄漏 state 直到有人加 `destroy/2` —— 正是 r7 在修的情况。**推荐：REQUIRED。** 强制每个 Kind 作者在 Kind 边界思考清理。PR-C 明确枚举已有 Kind（User / Agent / Session / Workspace / Worker —— `apps/` 扫描 5 个）并给每个加 `destroy/2`。post-PR-B 加的新 Kind 必须在注册时实现。Allen 在 OQ-NEW 确认。

### 7.7 "DB-backing check 通过 FK 约束而非显式 Kernel 守卫"（考虑 —— 拒绝）

候选：加 FK 约束 `kind_snapshots.entity_uri REFERENCES users(uri) ON DELETE CASCADE`。DB 结构性强制 "无 backing 行就无 snapshot"。**拒绝**：(a) snapshot 和 users 在不同 scope-pool（Workspace / Worker URI 不 FK 到 users）；(b) 行删除上的 FK CASCADE 会默默 nuke snapshot 而不跑 `Kind.Server.destroy/2` 的 audit + per-Kind 清理；(c) 我们要销毁是 operator-mediated 的，不是行删除的 side-effect。Entity callback 的 Kernel 守卫是对的位置 —— 它是控制 spawn 的 gate，不是行 insert。

---

## §8 SPEC 交互 —— 并行 specs

### 8.1 [2026-05-27-workspace-cap-based-visibility.md](2026-05-27-workspace-cap-based-visibility.md)（merged）

`Workspace.list_workspaces_for/2` 用 cap-membership 作 visibility。`User.destroy/2` 撤销 caps + 从 `workspace.member_uris` 移除。Destroy 后 `list_workspaces_for/2` 对该 caller 返回 `[]`。INV-9 钉住。

### 8.2 [2026-05-27-uri-canonicalization.md](2026-05-27-uri-canonicalization.md)（merged）

Destroy 在每 cascade 步比 URI。所有 URI 解析用 `Ezagent.URI.parse!/1`；断言用 `URI.to_string` 比较（canonical-form-invariant）。无新 URI-parsing 路径。

### 8.3 [2026-05-27-capability-action-axis.md](2026-05-27-capability-action-axis.md)（merged）

Destroy cap 声明 `action: :destroy` —— 具体 atom，非 `:any`。按 axis SPEC §3.6.1(b)，cap grant 流总产生 per-action cap。

### 8.4 [2026-05-27-reconciler-return-shape.md](2026-05-27-reconciler-return-shape.md)（merged）

`Kind.Server.destroy/2` 返回 shape `:ok | :partial | :error` —— 同三臂模式。这里 `:partial` 意为 "DB 行 + snapshot 没（不可逆）但 per-Kind 清理不全"。Caller 同 Reconciler caller 一样处理 `:partial`。

### 8.5 [2026-05-27-agent-bridge-domain-extraction.md](2026-05-27-agent-bridge-domain-extraction.md)（merged）

PR-G 引入 `AgentBridge.Adapter.deliver/2` + `handle_client_event/3` + `join_info/2`。r7 在同 behaviour 加 `teardown/1` 作可选 callback。已有 flavor adapter 得默认 no-op；PR-D 更新每个 plugin 加真实现。端到端 plugin isolation 保留。

---

## §9 向后兼容 / 外部 API

### 9.1 Operator workflow

- `mix ezagent.user.create`（已有）—— 不变。
- `mix ezagent.user.delete`（当前行为：low-level DB 删）—— **DEPRECATED**，会发警告 + 建议 `mix ezagent.kind.destroy`。
- `mix ezagent.kind.destroy <uri> --reason "<reason>"`（新）—— 调 `Kind.Server.destroy/2`。
- `mix ezagent.entity.backfill_worker_uri`（保留自 r1–r6 —— Migration B 预 flight）。

### 9.2 外部 caller

`external_mirror_bindings.worker_uri` 列添加（保留）。外部 caller 读表见一个新字段；已有读不受影响。

新 Phoenix.PubSub 广播：`{:kind_destroyed, target_uri, reason}` for LV consumer（admin dashboard 刷新）。

### 9.3 Re-register 自然支持（r7 下新）

已销毁 URI 可立即通过 `Users.create(uri, ...)`（或 per-Kind 等价）重建。下次 `SpawnRegistry.spawn(uri)` 返回新 pid 无继承状态。这是 INV-13。Operator 不再需要在 "删后重建" 测试 entity 时编新 URI。

### 9.4 Rollback plan

`Kind.Server.destroy/2` 是 forward-only —— 无 `undestroy`。要 "恢复" 误销毁 entity，operator 用先前 metadata 重跑原 `Users.create/3`（或 per-Kind 等价）。历史（caps、memberships、snapshot、audit）**没** —— 恢复的 entity 结构上是新的。这是故意摩擦。LV confirm dialog 警 "这是永久的；同 URI 重建**不**恢复旧 state"。

---

## §10 留给 Allen 的 OQ

### OQ-3 —— cross-reference scrub 默认（保留自 r1–r6）

§3.7 隐式选 scrub-to-nil（Session.owner_uri scrub 到 `nil`；fall through 到 `data_owner/1` 的 `:no_owner`）。Allen 确认？也可 per-tenant config。

### OQ-5 —— admin LV self-destroy（保留自 r1–r6）

§3.9 允许 operator 销毁自己配 confirm dialog。该允许吗？有些系统要 "second admin" 确认自销毁。默认：允许配单 confirm。Allen 可能想 second-admin 要求。

### OQ-6 —— Feishu binding cascade（保留自 r1–r6）

User 销毁时其 `feishu_user_bindings` 行被删。User 的 Feishu open_id 在平台仍合法；该 open_id 消息将解析失败。Cascade 应尝试重绑 open_id 到 fallback（如 `system/destroyed` sentinel user）吗？默认：删 binding；消息在路由层得 "no user found"（可接受错误）。Allen **可能** 想 sentinel-rebind。

### OQ-7 —— Kind destruction audit 行 schema（从 r1–r6 OQ-7 细化）

Audit 行用已有 `invocations` 表配 `action = "kind.destroyed"` + per-step 子行。Allen 确认，**或**偏好单独 `kind_destruction_audit` 表为可查询性？

### OQ-9 —— Type-the-URI LV 确认（保留自 r1–r6 q9 / §11）

PR-E admin LV 加 "Destroy" 按钮 + confirm dialog 问 reason。也该要 operator **输入** 被销毁的 URI（GitHub repo-name-confirmation 对等）？默认提议：不可逆操作要 type-the-name 确认。Allen 确认？

### OQ-NEW —— `destroy/2` REQUIRED vs OPTIONAL

`Ezagent.Kind.destroy/2` 该是 REQUIRED callback（每个 Kind 模块**必须**实现）还是 OPTIONAL（配 `Kind.default_destroy/2` 默认 no-op）？**推荐：REQUIRED**，按 §7.6 —— 强制每个 Kind 作者在边界思考清理，阻止静默 state 泄漏。PR-C 枚举五个已有 Kind 并给每个加 `destroy/2`。Allen 确认。

### REMOVED 开放问题

- ~~OQ-1（tombstone TTL）~~ —— r7 无 tombstone。
- ~~OQ-8（worker_uri NOT NULL 迁移时机）~~ —— 两-migration + backfill 任务模式原样保留自 r1–r6；它工作且 Worker.destroy/2 仍需该列。不再是 OQ；作为迁移计划一部分文档于 §4.3。

---

## §11 Codex 对抗性 review 问题 (for r7+)

> r7 重置：r1–r6 问题瞄 tombstone 正确性。r7 pivot 下它们 moot。新攻击面：

1. **DB-backing check 竞速（§3.6 step 4 竞速）：** entity callback 读 `Users.get_by_uri(uri)` 并决定 spawn。并发地，`Kind.Server.destroy(uri)` 在 step 5（terminate_child）。在 get_by_uri 读和 spawn fn 最终的 `Ezagent.Kind.spawn/2` 调之间，destroy 提交 step 6（DB 行删）。Spawn fn 然后 load 一个 DB 行没的 Kind 的 snapshot 吗？走通 step 5+6+7 的 Repo transaction 边界。

2. **Workspace cross-Kind cascade 深度（§3.5 Workspace.destroy）：** workspace 含 100 user。`Workspace.destroy/2` 遍历并对每个调 `Kind.Server.destroy/2`。遍历串行（一次一个）还是并行（Task.async_stream）？串行：O(N) cascade 时间；admin LV 超时。并行：共享资源竞速（如 workspace.member_uris 列表被每个 User.destroy/2 改）。在 §3.5 选一 + 论证。

3. **AgentBridge.Adapter.teardown/1 失败隔离：** 若 codex 的 `teardown/1` 抛（如 sidecar 已死、supervisor 超时），Agent.destroy/2 传播还是吞？§3.5 说 "best-effort"；验证编排器的 audit 行记录错误 AND step 5–8 仍跑。INV-18 在编排器因 teardown 错误中止时应失败。

4. **Re-register 继承（INV-13）：** 测试断言**无**继承 caps / memberships / snapshot。但 `users` 表是新创的；新行的 `caps_json` 默认成 `Users.create/3` 设的任何东西。验证测试断言**新** caps（Users.create 安装的什么）而非**旧** caps —— 没有 "空 caps" 普遍 state。

5. **DB-backing check 在所有相关路径：** §2 + §4.1 列出两个 entity-callback 注册站点（identity + chat 域）。是否有**任何**其他路径 spawn Kind 而**不**走 `SpawnRegistry.spawn/1`？`Ezagent.Kind.spawn/2` 是这样一条路径；r1–r6 边界 2 处理它。r7 下我们也需要 `Kind.spawn/2` 的 DB-backing check 吗，还是生产中 SpawnRegistry 层是唯一入口？

6. **Behavior.Chat.scrub_owner CapBAC（r7 保留 r1–r6 窄 system principal）：** cascade 以 `system://kind-destroy-cascade`（重命名）身份 dispatch `:scrub_owner`。验证 Catalog 条目 + `SystemPrincipal.ensure/1` 调时机 + `Kind.Runtime.authorize/4` 的 cap-check。同攻击面如 r1–r6 CRIT-3.1 + CRIT-4.1 + HIGH-4.3。

7. **Token.verify DB-backing check（替换 r1–r6 INV-14）：** check 现读 `Users.get_by_uri(uri) == nil` 而非 `SpawnRegistry.tombstoned?(uri)`。验证：(a) timing-leak-safe（拒路径上 Bcrypt.no_user_verify）；(b) 在 bcrypt 比较前；(c) 覆盖 Agent token（`Agents.get_by_uri/1`）不只 User。

8. **三站点 cold-load data_owner（替换 r1–r6 INV-13b）：** 同三解析器（Chat / ExternalMirror / Publisher.SessionImpl），现配 DB-backing check 而非 tombstone check。验证无第四解析器存在，AND DB-backing check 位置在 URI 返回**前**。

9. **`destroy/2` REQUIRED 迁移成本：** 若 OQ-NEW 选 REQUIRED，每个已有 Kind 模块必须加 `destroy/2`。枚举：`apps/ezagent_domain_identity/lib/ezagent/entity/user.ex`、`apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex`、`apps/ezagent_domain_chat/lib/ezagent/entity/session.ex`、`apps/ezagent_domain_workspace/lib/ezagent/entity/workspace.ex`、`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/worker.ex`。漏什么吗？有 test-fixture Kind 需要它吗？

10. **LV confirm dialog UX（保留自 r1–r6 q9）：** type-the-URI 确认默认。Allen 在 OQ-9 确认。

---

## §12 Rollback plan

本 SPEC 实现是 forward-only（无应用 destroy 的 rollback）。SPEC 本身 rollback（revert PR-A → PR-B → ...）：

1. 按 reverse 顺序 revert merge commits。
2. `external_mirror_bindings.worker_uri` 列保留（NULL-able 孤儿列；无害）。
3. `Ezagent.Kind.destroy/2` callback 添加 revert；已有 Kind 失去 callback 契约（若 REQUIRED 编译失败 —— operator 必须随 PR-B 一并回滚 PR-C 若 REQUIRED）。
4. `AgentBridge.Adapter.teardown/1` 扩展 revert；唯一影响是默认 no-op。
5. 依赖 `Kind.Server.destroy/2` 的 operator 失去访问；手 SQL 删回 fallback。
6. 无 tombstone 表清理（r7 从未创建）。

DB schema 加是非破坏性（仅 worker_uri 列）；任何时候 rollback 安全。

---

## Appendix A —— 序列图

```
Operator (admin LV)
  │ 点 "Destroy" + 输入 reason + type-the-URI 确认
  ▼
Kind.Server.destroy(target_uri, %{caller, reason})
  │ step 1: kind.can_destroy?(target_uri, ctx)  → :ok or {:precheck_failed, _}
  │ step 2: 生成 trace_id
  │
  ▼ step 3（per-Kind 清理 callback）
kind.destroy(target_uri, ctx_with_trace)
  │   - User: 撤销 caps / 删 binding / 删 memberships / scrub session owner
  │   - Agent: AgentBridge.Adapter.teardown / 撤销 token / 删 memberships
  │   - Workspace: 递归 Kind.Server.destroy 每个 member（共享 trace_id）
  │   - Worker: 删 external_mirror_bindings（worker_uri 列）/ unsubscribe
  │   - Session: 删 member / unsubscribe publisher
  ▼ {:ok, summary} 或 {:error, reason}（best-effort；编排器继续）
  │
  ▼ step 4: KindRegistry.lookup(target_uri)
  │     {:ok, pid} → step 5
  │     :error → 跳 step 5（Kind 不活）
  │
  ▼ step 5: DynamicSupervisor.terminate_child(supervisor, pid)
  │     （优雅 —— 跑 Kind 的 terminate/2 若有）
  │
  ▼ step 6+7 包在 Repo.transaction（竞速有界）
  │     step 6: kind.delete_db_row(target_uri)  [DB 行**就是** source of truth]
  │     step 7: Repo.delete(KindSnapshot, target_uri_str)
  │
  ▼ step 8: audit emit
  │     invocations action = "kind.destroyed"
  │     step 3 summary 的 per-step 子行（共享 trace_id）
  │
  ▼ 广播
Phoenix.PubSub.broadcast({:kind_destroyed, target_uri, reason})
  │
  ▼
{:ok, %{deleted_uri, steps_completed, cascade_summary, audit_event_id, trace_id}}

# Destroy 后重 spawn
SpawnRegistry.spawn(target_uri)
  │ entity callback: Users.get_by_uri(target_uri) == nil → {:error, :no_backing_entity}
  ▼
{:error, :no_backing_entity}

# Re-register
Users.create(target_uri, fresh_attrs)  # 写新行
SpawnRegistry.spawn(target_uri)
  │ entity callback: Users.get_by_uri → 新行存在 → Kind.spawn(User, ...)
  ▼
{:ok, fresh_pid}  # 无继承状态 —— 新 Kind、新 slice、无 snapshot
```

## Appendix B —— 为什么本 SPEC 比 r6 短

r6 是 984 行。r7 是其 ~60%：tombstone 机制（entity_tombstones 表、ETS 镜像、原子 primitive、三边界强制、codex 驱动的 rev 历史）是 r6 大部。r7 完全去除该 artifact。剩下：`Kind.destroy/2` callback 契约（~20 行）、`Kind.Server.destroy/2` 编排（~50 行）、per-Kind cascade 表（保留自 r6，~80 行）、AgentBridge.Adapter.teardown 扩展（~10 行）、entity callback 的 DB-backing check（~10 行）、INV 表（16 条，~40 行）、OQ 列表（6 条，~30 行）。

## Appendix C —— 作者推荐

Land PR-A（本 SPEC）→ PR-B（核心：Kind.destroy callback + Kind.Server.destroy + DB-backing check + AgentBridge.Adapter.teardown）。PR-C（per-Kind destroy 实现）紧接因 callback 契约 required（按 OQ-NEW 推荐）；PR-D（plugin teardown 实现）可与 PR-C 并行 land；PR-E（LV UI + CLI）最后 land。

`system/linyilun` ghost —— 2026-05-28 浮现 —— 是经验动机，但结构修复更广：每个 Kind 获得干净的生命周期 CRUD 对等，已销毁 URI 的 re-register 自然工作因 DB 行是 source of truth。Allen 表述的架构目标（2026-05-28 03:43）达成："所有 Kind 应该有完整 CRUD"。

🤖 Generated with [Claude Code](https://claude.com/claude-code)
