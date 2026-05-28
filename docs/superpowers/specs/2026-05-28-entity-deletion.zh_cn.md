# SPEC — Entity 删除生命周期（User / Agent / Worker）

**状态：** r5 — codex r4 评审（REJECT）已应对：2 CRIT + 1 HIGH + 1 MED + 1 LOW。2026-05-28。

**r5 变更（codex r4 verdict REJECT —— 5 个 finding 解决）：**

- **CRIT-5.1（`:scrub_owner` 注册管道不完整）：** codex r4 发现 r4 的 Chat 变更列表提到 `actions/0`、`required_caps/0`、`invoke/4`、`data_owner/1`，但漏了 Chat behavior 必须接线的 **三处** 额外位置：(a) `register_chat_behaviors/0` 在 `apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:605-614` 把每个 action 注册到 BehaviorRegistry —— 该处无条目，`Kind.Runtime.authorize/4` 在 `apps/ezagent_core/lib/ezagent/kind/runtime.ex:212-216` 返回 `{:unknown_action, :scrub_owner}`；(b) `cap_subjects/0` 在 `chat.ex:108-116` 声明 cap shape 给 `CapabilityRegistry.register/3`（`apps/ezagent_core/lib/ezagent/capability_registry.ex:61-98`）—— 无它注册 raise；(c) `interface/0` 在 `chat.ex:1036-1072` 声明 action 的 args validator —— 无它，`Kind.Runtime` 在 `invoke/4` 之前拒绝 dispatch（`runtime.ex:615-628`）。**修复：** §4.1 PR-B 变更列表扩展枚举 Chat 触及的 **全部五项** 改动：actions、required_caps、invoke、data_owner、**和** `register_chat_behaviors`、`cap_subjects`、`interface`。§3.5 现显式说 `:scrub_owner` 注册是 five-part 改动，不是 four-part。
- **CRIT-5.2（cold-load 防御不完整 —— 额外的 data_owner 站点）：** codex r4 发现 r4 仅在 `Chat.data_owner/1` 放 tombstone 防御，但生产中还有 **两个** data-owner 解析器读同一 stale slice 不查 tombstone：(a) `Ezagent.Behavior.ExternalMirror.data_owner/1` 在 `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:593-600` 直接读 Session 的 `:chat.owner_uri` slice 并为 CapBAC 返回；(b) `Ezagent.Behavior.Publisher.SessionImpl.data_owner/1` 在 `apps/ezagent_domain_chat/lib/ezagent/behavior/publisher/session_impl.ex:136-144` 调 `Session.owner/1` 直接返回 owner。两者都是 CapBAC 路径，不是显示读 —— cold-loaded Session 仍通过这些解析器授权已删用户。**修复：** §3.5 + §4.1 在 **两个** 额外站点要求 **相同** tombstone 防御。防御模式（调 `SpawnRegistry.tombstoned?(owner)`；如 true 返回 `:no_owner`）在三处都相同。INV-13b 扩展为断言 cold-load 时 **三个** data_owner 解析器都返回 `:no_owner`。
- **HIGH-5.3（kill_timeout 高估结构性不可达）：** codex r4 发现 r4 §3.3 + §3.9 声称 `:kill_timeout` 留 URI "通过 dispatch 结构性不可达"。这对已 ready 的活 pid **错的**：`Invocation.dispatch/1`（`apps/ezagent_core/lib/ezagent/invocation.ex:87-107`）调 `KindRegistry.lookup/1`（`kind_registry.ex:59-64`）返回仍注册的 pid，然后 `GenServer.cast`/`call`（`invocation.ex:111-130`）直送 pid；**不** 查 tombstone 表。边界 1/2/3 阻止 RE-SPAWN，不阻止投递给边界 1 尚未来得及拒绝的活进程。**修复：** §3.9 + §3.3 澄清 —— `:kill_timeout` 时，活 pid 在挺过 kill 信号的短暂窗口内 **仍** 可通过 dispatch 到达。结构性不可达声明窄化为：(a) URI 死后不能 RE-SPAWN（边界 1/2/3 hold）；(b) 进程最终死后 `KindRegistry.lookup/1` 返回 `:error`（Registry drop 死 pid）；(c) 活 pid 在死前可能收到最后一阵 cast/call。Operator runbook 现正确说：SIGKILL BEAM 节点强制活 pid 下来 —— `:partial` 删除结构性有界但非瞬时完成。`Behavior.EntityDeletion` 返回不变（`{:error, {:partial, step_failed: :tombstone_and_kill_kill_timeout, ...}}`）。
- **MED-5.4（Capability 示例 struct 缺 `granted_at`）：** codex r4 发现 §3.5 `system://entity-deletion-cascade` cap 示例用 raw `%Capability{}` 字面带 `granted_by` 但无 `granted_at`，但 `Ezagent.Capability` 在 `apps/ezagent_core/lib/ezagent/capability.ex:36-46` 有 `@enforce_keys [:kind, :behavior, :instance, :workspace_uri, :granted_by, :granted_at]` —— 字面会 compile/runtime fail。其它 Catalog 条目用 `Capability.cap/3` 助手填必需字段。**修复：** §3.5 cap 示例切到 `Capability.cap(Ezagent.Entity.Session, Ezagent.Behavior.Chat, :scrub_owner, :any, :any)`，附注 `granted_by` + `granted_at` 由 catalog 既有模式填。
- **LOW-5.5（ZH §11 stale r2 questions 尾巴）：** codex r4 发现 EN §11 在 q9 干净结束，但 ZH 在 q9 后续接被取代的 r2 时代 B1/B2/B3/B5 prompts。**修复：** ZH §11 尾巴裁剪到匹配 EN 的 q0-q9 集。

**r4 变更（保留 —— codex r3 verdict REJECT —— 6 个 finding 解决）：**

- **CRIT-4.1（`SystemPrincipal.caps/1` 参数 shape）：** codex r3 发现 r3 cascade 代码示例调 `Ezagent.SystemPrincipal.caps("entity-deletion-cascade")`，但 `SystemPrincipal.caps/1`（`apps/ezagent_core/lib/ezagent/system_principal.ex:156-163`）通过 `parse!/1` 解析输入并强制 `scheme == "system"`（`:168-176`）—— 裸 service-name 字符串在返回任何 cap 之前 ArgumentError。**修复：** cascade 现在用 `cascade_principal = SystemPrincipal.uri("entity-deletion-cascade")`（返回 `%URI{}`），既作 caller 字段也作 `SystemPrincipal.caps/1` 参数。§3.5 r3 示例代码更新调 `SystemPrincipal.caps(cascade_principal)`。INV-13a 更新断言 cascade dispatch 干净运行（不 raise ArgumentError）。
- **CRIT-4.2（BindingRow schema 缺 `worker_uri`）：** codex r3 发现 r3 的 `:bind` action body 改在 `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:747-758` 不够 —— 生产持久化经 `Ezagent.ExternalMirror.BindingRow.insert/1`（`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/binding_row.ex:42-50, :87-108`），其 `schema "external_mirror_bindings"` block 不含 `:worker_uri`，`cast`/`validate_required` 列表也排除。不改 BindingRow，Ecto 静默 drop `worker_uri`（cast 忽略未知字段），Migration B（NOT NULL）之后 insert 会失败。**修复：** §4.1 PR-B 变更列表显式加 BindingRow 更新：(1) schema block 加 `field(:worker_uri, :string)`，(2) `@type t` 加 `worker_uri: String.t()`，(3) `:worker_uri` 加进 `cast` **和** `validate_required` 两个列表。`:bind` action body 在 attrs map 中传派生的 `worker_uri` 值。无这些 BindingRow 改动，列从 Elixir 代码不可达。
- **HIGH-4.3（INV-13a "exactly one cap" 过严）：** codex r3 正确观察到 `SystemPrincipal.ensure/1`（`apps/ezagent_core/lib/ezagent/system_principal.ex:88-92`）把 principal spawn 为 User Kind，`Behavior.Identity.init_slice/1`（`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:91-122`）对任何 URI（包括 `system://...`）**无条件** 加一个 SELF `:list_caps` cap。所以 principal 的 slice 携带 **两个** cap：cascade 的 `Chat:scrub_owner` cap **和** `kind: :system, behavior: Identity, action: :list_caps, instance: <self>, workspace_uri: ...` 自查 cap。**修复：** INV-13a 从 "exactly one cap" 弱化为 "cascade 的 `Chat:scrub_owner` cap 存在 **且** principal 的 caps 集是 `Catalog.caps_for!(uri)` 与 `Identity.init_slice/1` 给每个 Entity Kind 的结构性自-`:list_caps` cap 的并集"。威胁模型现承认：principal 可以读自己的 caps（`Identity.list_caps` on `system://entity-deletion-cascade`）—— no-op 操作不升级（返回同一个 MapSet）。Cascade principal **不能** invoke 除 Chat:scrub_owner on Session **或** Identity.list_caps on 自己之外任何东西。结构性自 cap 按既有 PR-OWN-3 设计（`identity.ex:100-122` 理由）文档化为良性。
- **MED-4.4（B2 timeout 返回 shape 未规范）：** codex r3 发现 r3 §3.3 step 4 引入 Process.monitor + receive 配短超时，但 **没** 说 timeout 时什么。§3.2 列三种返回 shape（`:ok | :partial | :error`），但都没描述 post-tombstone-timeout 状态。§3.9 假设 pid 已死。**修复：** §3.3 显式文档化 timeout 路径：如 DOWN 在超时内不到，`tombstone_and_kill/1` 返回 `{:error, :kill_timeout}` **并** 保留 tombstone（DB + ETS 持久；kill 是唯一可重试步骤）。Behavior 在 §3 把它映射为 `{:error, {:partial, %{step_failed: :tombstone_and_kill_kill_timeout, ...}}}`，因为 tombstone 不可逆（边界 1/2/3 阻止任何 future dispatch 复活 Kind）但 live process 还在占资源。Operator runbook：SIGKILL BEAM 节点或等 OS supervisor restart。§3.9 更新："Kind dead" 改写为 "Kind dead OR scheduled to die —— 两种都通过 dispatch 结构性不可达"。
- **MED-4.5（INV-15 不测 pre-backfill NULL 行）：** codex r3 发现 INV-15 只断言 POST-backfill 状态（NULL 行不存在）；**不** 测过渡 cascade 查询的第二 clause（§3.5 的 NULL-safety 分支）。**修复：** 新 INV-15a 显式构造 pre-backfill 场景：插一行 `worker_uri: nil`，然后对从该行 `(session_uri, adapter_id, target_id)` 派生的 URI invoke Worker 删除；断言行被删（通过过渡分支）。INV-15 仍断言 post-backfill steady state。
- **LOW-4.6（§11 stale r2 prompts）：** codex r3 发现 §11 仍含 r3 解决或更正过的 review prompt（KindRegistry.list_matching 引用、operator-caller authorization 声明、terminate/2 drain 声明、Session.owner/1 返回 error path 声明）。**修复：** §11 q1-9 措辞与 r3 normative text 对齐。问题主干保留（codex r4 仍攻击这些区域）但 framing 匹配 post-r3 现实。

**r3 变更（保留 —— codex r2 verdict REJECT —— 6 个 finding 解决）：**

- **CRIT-3.1（`:scrub_owner` 对 cascade caller 不可满足）：** codex r2 发现新 Chat action `:scrub_owner` 配 `cap(:any, Chat, :scrub_owner)` 会在 `Kind.Runtime.authorize/4`（`apps/ezagent_core/lib/ezagent/kind/runtime.ex:249`）失败 CapBAC —— operator 在 EntityDeletion 上的 `:delete` cap **不**满足 `Chat:scrub_owner`，且 r2 示例 dispatch 未提供 `ctx.caps` 或 system caller。**修复：** cascade 以新的专用 system principal `system://entity-deletion-cascade` 的身份 dispatch `:scrub_owner`（在 `Ezagent.SystemPrincipal.Catalog` 中新增条目，**仅** 携带 `Capability{kind: Ezagent.Entity.Session, behavior: Ezagent.Behavior.Chat, action: :scrub_owner, instance: :any, workspace_uri: :any}` —— 按 `feedback_let_it_crash_no_workarounds` 结构上窄化）。`Behavior.EntityDeletion` 在 PR-B Application boot 时通过 `SystemPrincipal.ensure/1` 一次性确保该 principal 存在，cascade 用 `caller = SystemPrincipal.uri("entity-deletion-cascade")` + `caps = SystemPrincipal.caps("entity-deletion-cascade")` 构建 dispatch envelope。该 principal 结构性地不能做其它事。§3.5 + Catalog 条目 + INV-13a 相应更新。
- **CRIT-3.2（cold-session `Session.owner/1` 不查 tombstone）：** codex r2 发现生产 `Session.owner/1`（`apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:649-657`）仅通过 `Ezagent.Kind.get_slice/2` 读 live `:chat` slice 并无条件返回 `{:ok, owner_uri}` —— **不**查 User 存在或 tombstone。带有 stale `owner_uri = target` 的 cold-load Session 仍把已删用户作为 data owner，瓦解了 B3 的安全论证。**修复：** `Chat.data_owner/1`（`apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:1333-1342`）增加 tombstone 防御 check —— `Session.owner/1` 返回 `{:ok, %URI{} = owner}` 后，调 `SpawnRegistry.tombstoned?(owner)`；如 true，返回 `:no_owner` 而不是该 URI。这是读站点的 defense-in-depth（与 INV-14 的 Token.verify check 平行），并且 cascade 仍对 live Session 做主动 in-memory scrub。新增 INV-13b：删除后 cold-load 一个 stale `owner_uri` 的 Session；断言 `Chat.data_owner/1` 返回 `:no_owner`。
- **CRIT-3.3（B5 backfill 路径未完全规范）：** codex r2 发现 §9.3 只定义了 snapshot 孤儿的 discovery 任务，**没有** 幂等的 `worker_uri` backfill；cascade 的 `WHERE worker_uri = target` 静默跳过 NULL 行；NOT NULL migration 没有文档化的前置检查。**修复：** 新 mix 任务 `mix ezagent.entity.deletion.backfill_worker_uri` 在 §4.2 + §9.1 显式定义 —— 幂等（**仅**在 NULL 行 set `worker_uri`，通过 `WorkerSpawn.worker_uri_for/3` 派生，log row count），并附文档化前置检查（`SELECT count(*) FROM external_mirror_bindings WHERE worker_uri IS NULL`），follow-up `NOT NULL` migration 先跑此 check，非零则 abort。PR-B 还附防御读路径：cascade 做 `Repo.delete_all(...)` 对 `WHERE worker_uri = target OR worker_uri IS NULL AND <派生匹配>` 作为过渡安全网，`NOT NULL` migration 落地后的 follow-up PR 中移除。新增 INV-15：PR-B + backfill 后，每行 `worker_uri` 非 NULL 且匹配 `WorkerSpawn.worker_uri_for(session_uri, adapter_id, target_id)`。
- **HIGH-3.4（B6 Token.verify 防御不在 PR-B 变更列表）：** codex r2 发现 INV-14 要求 `Token.verify/2` 拒绝 tombstoned URI，但 §4.1 的 PR-B 变更列表漏了 `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex`。**修复：** §4.1 显式加 Token.verify 修改：在 `verify/2` 入口（bcrypt 比较 **之前**，`uri_str` 派生之后），调 `Ezagent.SpawnRegistry.tombstoned?(uri)`；如 true，跑 `Bcrypt.no_user_verify()`（timing-leak-safe，按 `token.ex:112` 既有模式）并返回 `{:error, :tombstoned}`。结构性地放在 bcrypt 之前是正确的：我们不应暗示 token 行存在或 URI 曾被供给。INV-14 措辞更新。
- **MED-3.5（§3.9 brutal_kill / cast 语义陈述错误）：** codex r2 发现 `:brutal_kill` **完全** 绕过 `terminate/2`（所以"drains the mailbox"的说法是错的），且 `GenServer.cast` 到被杀进程**返回 `:ok`**（cast 已发出；进程死后消息悄悄丢弃 —— 不会返回 `{:error, :noproc}` for casts）。**修复：** §3.9 重写为真相：(1) `brutal_kill` 跳过 `terminate/2`；mailbox 消息被丢弃，不是 drained；(2) in-flight `cast` 发送方返回 `:ok` 然后静默丢失（可接受 —— 边界 3 拒绝 respawn，下次 dispatch 干净拿到 `:tombstoned`）；(3) in-flight `call` 从 link-monitor 返回 `{:error, :noproc}`；(4) 持久化通过 `tombstone_and_kill/1` 的 **同步** pre-kill DB tombstone insert 保证（Appendix A —— DB tombstone insert 发生在 kill 之前，即使任何 in-flight cast 丢失，entity 结构性已没）。具体：§3.3 原子 primitive 顺序更新为 (1) DB insert, (2) ETS insert, (3) `Process.exit(pid, :brutal_kill)`, (4) Process.monitor + receive `{:DOWN, ...}`（**不是** `terminate/2` drain —— 没有这一步）。"wait for terminate to complete" 措辞替换为 "wait for the registered pid's DOWN message via Process.monitor"。
- **LOW-3.6（ZH §3.5 cascade 表非 byte-identical）：** codex r2 发现 EN cascade 标记 `[B3 — see below]` / `[B5 — see below]` / `[B6]` 不同于 ZH `[B3 —— 见下]` / `[B5 —— 见下]` / `[B6]`。指令是 "byte-for-byte" 不是 "semantically aligned"。**修复：** ZH §3.5 cascade 表 code block 现在 **逐字** 使用 EN annotation（`[B3 — see below]`, `[B5 — see below]`, `[B6]`）—— 这些是结构性标记不是叙述散文，byte-identical 规则适用。周围段落保持翻译。

**r2 变更（保留 —— codex r1 verdict REJECT —— 6 个 blocker + 3 个 nit 解决）：**

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
- `{:error, {:partial, _}}` —— pre-check 通过、tombstone-and-kill 完成（DB + ETS 不可逆），但至少 (a) kill 确认（`{:DOWN, ...}`）超时（MED-4.4），**或** (b) 下游 DB cascade step 失败。Tombstone 持久（边界 1/2/3 拒绝 re-spawn）但 cross-reference scrub 可能不完整。两种 `:partial` 子 shape 由 `step_failed` 区分：
  - `step_failed: :tombstone_and_kill_kill_timeout` —— tombstone 已立，kill 信号已发，但 DOWN 消息没及时到。Live process 可能还占资源。Operator runbook 在 `recovery_hint`：SIGKILL BEAM 节点或等 OS supervisor cycle。已删 URI 通过 dispatch 已结构性不可达 —— 这是清理问题，不是正确性问题。
  - `step_failed: :<cascade_step_name>` —— 某 cascade step raise。其它 cascade step 可能已跑；`steps_completed` 列已成功的。
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
    3. Process.exit(pid, :brutal_kill) —— 完全绕过 terminate/2
       （故意如此；见 §3.9 为什么 cascade 不依赖 graceful terminate
       语义来处理已删 Kind）。
    4. Process.monitor(pid) + receive {:DOWN, _ref, :process, pid, _reason}
       配短超时（默认 5s —— 防 stuck linked process 持 C-NIF）。三种终止：
       - DOWN 已到：返回 :ok。
       - pid 本来就没（从未注册或在 call 中死）：返回 :ok（步骤 1+2 仍 hold）。
       - timeout 没等到 DOWN：返回 {:error, :kill_timeout}。
         Tombstone（DB + ETS）**仍** 立 + 持久，活 pid 死后边界 1/2/3
         拒绝 RE-SPAWN。但 —— 见 §3.9 HIGH-5.3 —— 活 pid 挺过 brutal_kill
         信号的短暂窗口（如陷在 C-NIF），Invocation.dispatch/1
         （apps/ezagent_core/lib/ezagent/invocation.ex:87-107 +
         kind_registry.ex:59-64）调 KindRegistry.lookup/1 返回仍注册的
         pid 直送 cast/call **不** 查 tombstone 表。Behavior 在 §3 按
         §3.2 映射为 {:error, {:partial, step_failed:
         :tombstone_and_kill_kill_timeout, ...}} —— 结构性清理有界
         （URI 永久不能 respawn）但非瞬时完成（活 pid 可能短暂续
         服消息）。

  因为 DB 行在 kill 之前 commit，BEAM 在步骤 1 和 4 之间 crash 也会让
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
:scrub_session_owner_uri       → Enum.each(owned_sessions, &dispatch_chat_scrub_owner/1)    [B3 — see below]
:delete_users_row              → Repo.delete(user)
```

**B3 —— Session owner scrub 通过真实 Behavior.Chat action（以 system principal 身份 dispatch —— CRIT-3.1 修复）。** `Behavior.Chat`（`apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:88`）今天声明 actions `[:send, :receive, :join, :leave, :set_working_copy]`。本 SPEC 新增 Session-side action `:scrub_owner`：

- `actions/0`: `[:send, :receive, :join, :leave, :set_working_copy, :scrub_owner]`
- `required_caps/0`: `:scrub_owner` 声明 `cap(Ezagent.Entity.Session, __MODULE__, :scrub_owner, :any, :any)` —— per-action cap，**不是** `:any`。按 capability-action-axis SPEC §3.6.1，是具体 atom。
- `invoke(:scrub_owner, slice, %{deleted_uri}, _ctx)`：如 `slice.owner_uri == deleted_uri`，set `owner_uri: nil`（**不是** sentinel URI —— `nil` 落到 `data_owner/1` 在 `chat.ex:1337` 的 `:no_owner` clause，保留系统 sessions 既有语义）。返回 `{:ok, %{owner_scrubbed: true}, slice_with_nil_owner, dispatch_envelope}` 让标准 `Kind.Runtime` step 9.5 通过 `:on_change` 策略持久化。

**Dispatch 授权（CRIT-3.1）。** Operator 在 `Behavior.EntityDeletion` 上的 `:delete` cap **不** 满足 `Kind.Runtime.authorize/4`（`apps/ezagent_core/lib/ezagent/kind/runtime.ex:249-298`）的 `Behavior.Chat.scrub_owner`。因此 cascade 以专用窄化 system principal 身份 dispatch `:scrub_owner`：

```
system://entity-deletion-cascade
  caps: [
    # MED-5.4 (r5) —— 用助手不用 raw struct 字面。
    # Ezagent.Capability 有 @enforce_keys 含 :granted_at；助手填充。
    # Catalog 其它条目用同模式
    # (apps/ezagent_core/lib/ezagent/system_principal/catalog.ex:132-149).
    Ezagent.Capability.cap(
      Ezagent.Entity.Session,           # kind
      Ezagent.Behavior.Chat,            # behavior
      :scrub_owner,                     # action
      :any,                             # instance (dispatch 时窄化)
      :any                              # workspace_uri (dispatch 时窄化)
    )
    # `granted_by` 按 catalog 约定（catalog.ex:101）默认到 system://bootstrap/default；
    # `granted_at` 由助手设。
  ]
```

加到 `Ezagent.SystemPrincipal.Catalog` 作为新条目，与 `system://chat-router`、`system://chat-reply` 等并列（`apps/ezagent_core/lib/ezagent/system_principal/catalog.ex:135+`）。结构性窄化带下面一个 CAVEAT。`Ezagent.SystemPrincipal.ensure(SystemPrincipal.uri("entity-deletion-cascade"))` 在 `EzagentCore.Application.start/2` 已有 system kinds 注册 **之后** 调一次，确保任何 deletion 触发前 principal 的 `:identity` slice 已就绪。

**HIGH-4.3 —— 结构性自-`:list_caps` cap。** `Ezagent.SystemPrincipal.ensure/1`（`apps/ezagent_core/lib/ezagent/system_principal.ex:88-92`）把 principal spawn 为 `Ezagent.Entity.User` Kind。`Ezagent.Behavior.Identity.init_slice/1`（`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:91-122`）对任何 Entity Kind 无条件加 SELF `:list_caps` cap —— `:100-122` 的 PR-OWN-3 设计这样注入让 entity 能读 **自己** 的 caps（用户面读路径 `Identity.list_caps_for/1` 需要）。Cascade principal 的 `:identity` slice 因此 ensure 后携带 **两个** cap：

1. cascade 目的 cap（从 `initial_caps`）：`Capability{kind: Ezagent.Entity.Session, behavior: Ezagent.Behavior.Chat, action: :scrub_owner, ...}`
2. 结构性自 cap（从 `Identity.init_slice/1`）：`Capability{kind: <kind_for_uri(system://...)>, behavior: Ezagent.Behavior.Identity, action: :list_caps, instance: <self>, workspace_uri: <self>}`

自 cap 按设计良性：`Identity.list_caps_for(self_uri)` 返回授权了 call 的同一个 MapSet —— 没有升级面。Cascade principal **不能** invoke 除 Session 上的 `Chat:scrub_owner` **和** 自己 URI 上的 `Identity:list_caps` 之外任何东西。威胁模型：以某种方式 assume 这个 principal 的攻击者不能拿它做跳板去访问其它 Kind 上的其它 action。INV-13a（下）显式断言 disjoint-union shape 而不是原始的 "exactly one cap"。

Cascade step body：

```elixir
def scrub_session_owner_uri(target_user_uri, _ctx) do
  # Lookup 走 live registry。KindRegistry 暴露 `list_all/0`
  # （无 list_matching —— 见 apps/ezagent_core/lib/ezagent/kind_registry.ex:73）；
  # 我们过滤到 session:// URI 然后逐一 probe owner match。
  # Snapshot 中但未驻留的 session 由读时的 Chat.data_owner/1 tombstone
  # 防御（CRIT-3.2 修复）处理 —— 见下。
  # CRIT-4.1 (r4): SystemPrincipal.caps/1 强制 scheme == "system" 并通过
  # parse!/1 解析输入；裸 service-name 字符串在 apps/ezagent_core/lib/
  # ezagent/system_principal.ex:168-176 ArgumentError。传 SystemPrincipal.uri/1
  # 返回的 %URI{}。
  cascade_principal = Ezagent.SystemPrincipal.uri("entity-deletion-cascade")
  cascade_caps = Ezagent.SystemPrincipal.caps(cascade_principal)

  alive_sessions =
    Ezagent.KindRegistry.list_all()
    |> Enum.filter(fn {uri_str, _pid} -> String.starts_with?(uri_str, "session://") end)
    |> Enum.filter(fn {uri_str, _pid} ->
      case Ezagent.Entity.Session.owner(uri_str) do
        {:ok, %URI{} = owner} -> URI.to_string(owner) == URI.to_string(target_user_uri)
        _ -> false
      end
    end)

  Enum.reduce(alive_sessions, %{scrubbed: 0, errors: []}, fn {uri_str, _pid}, acc ->
    session_uri = Ezagent.URI.parse!(uri_str)

    case Ezagent.Invocation.dispatch(%Invocation{
           kind: Ezagent.Entity.Session,
           behavior: Ezagent.Behavior.Chat,
           action: :scrub_owner,
           target: session_uri,
           args: %{deleted_uri: target_user_uri},
           ctx: %{
             caller: cascade_principal,
             caps: cascade_caps,
             trace_id: cascade_trace_id
           }
         }) do
      {:ok, _} -> %{acc | scrubbed: acc.scrubbed + 1}
      {:error, :noproc} -> %{acc | scrubbed: acc.scrubbed}  # session 死了 —— 没问题
      {:error, :tombstoned} -> %{acc | scrubbed: acc.scrubbed}  # session 被删了 —— 没问题
      {:error, reason} -> %{acc | errors: [{uri_str, reason} | acc.errors]}
    end
  end)
end
```

**Cold-load 防御（CRIT-3.2 修复）。** 生产 `Session.owner/1`（`apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:649-657`）只读 live `:chat` slice 并无条件返回 `{:ok, owner_uri}` —— **不** 查 tombstone。所以删除 **之后** 从 snapshot load 的 Session 仍报告已删 URI 为 owner。修复在 data-owner 读站点：

`Behavior.Chat.data_owner/1`（`apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:1333-1342`）增加 tombstone 防御 check：

```elixir
@impl Ezagent.Behavior
def data_owner(%URI{scheme: "session"} = session_uri) do
  case Ezagent.Entity.Session.owner(session_uri) do
    {:ok, %URI{} = owner} ->
      # CRIT-3.2 防御 —— 即使 live slice（或 cold-loaded snapshot）携带
      # stale owner_uri，tombstone check 拒绝把已删 URI 作 data_owner。
      if Ezagent.SpawnRegistry.tombstoned?(owner) do
        :no_owner
      else
        owner
      end
    _ -> :no_owner
  end
end
```

这是读站点的 defense-in-depth（与 INV-14 的 Token.verify check 平行）。主动 in-memory scrub（上面）立即处理 live Session；读站点 check 覆盖 cold load + lookup/dispatch race 窗口。

**CRIT-5.2 —— 还有 **两个** data_owner 站点需要同样防御。** codex r4 发现 `Chat.data_owner/1` 不是生产中唯一读 Session ownership 的 CapBAC data-owner 解析器。还有两处需要 tombstone check：

- `Ezagent.Behavior.ExternalMirror.data_owner/1`（`apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:593-600`）—— 直接读 Session 的 `:chat.owner_uri` slice 并为 ExternalMirror cap-grant authz 返回。无 tombstone check，cold-loaded 带 stale `owner_uri = target` 的 Session 仍通过 ExternalMirror cap（如 binding 管理）授权已删用户。
- `Ezagent.Behavior.Publisher.SessionImpl.data_owner/1`（`apps/ezagent_domain_chat/lib/ezagent/behavior/publisher/session_impl.ex:136-144`）—— 调 `Session.owner/1` 直接为 Publisher cap-grant authz 返回 owner URI。

两者都要同一模式：拿到 owner URI 后调 `Ezagent.SpawnRegistry.tombstoned?(owner)`；如 true 返回 `:no_owner`。§4.1 PR-B 变更列表显式加这两个文件改动。

INV-13b 的断言扩展为单一 cold-load 场景测全 **三个** data_owner 解析器。

**Session 在 lookup-到-dispatch 之间被删的 race：** 如 Session Kind 在 `KindRegistry.list_all/0` 和 `Invocation.dispatch/1` 之间死了，dispatch 返回 `{:error, :noproc}`。Cascade 视为成功（session 没了，没什么要 scrub 的）。如 Session tombstoned（被并发 Session 删除），dispatch 从边界 1 返回 `{:error, :tombstoned}` —— 也视为成功。Cascade step 的幂等性契约保持：重跑是 no-op。

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
:drop_external_mirror_bindings → see B5 cascade query below                                   [B5 — see below]
:unsubscribe_session_publisher → Publisher.unsubscribe(target)
:terminate_adapter             → adapter_module.terminate(target)
```

**B5 —— Worker cascade 列修复 + r3 backfill 规范化（CRIT-3.3）。** r1 的 `WHERE bound_by = target` 错了：`bound_by` 记 **创建用户 URI**（`apps/ezagent_core/priv/repo/migrations/20260607000000_pr_em_3_external_mirror_bindings.exs:54`），Worker URI 从 `(session_uri, adapter_id, target_id)` 通过 `WorkerSpawn.worker_uri_for/3`（`worker_spawn.ex:217-230`）派生 **不存表里**。

按 `feedback_let_it_crash_no_workarounds`（结构 over policy），r2 修复给 `external_mirror_bindings` 加持久化 `worker_uri` 列。r3 完整规范化 backfill + cascade race-free 行为：

- **Forward-only Migration A**（`apps/ezagent_core/priv/repo/migrations/<timestamp>_pr_a_worker_uri_column.exs`）：`add :worker_uri, :string, null: true` 初期（允许 pre-r2 行 backfill）。给 cascade 查询加 index `create index(:external_mirror_bindings, [:worker_uri])`。Greenfield 部署（dev/test/全新 prod）从第一天就有列。
- **Backfill 任务 `mix ezagent.entity.deletion.backfill_worker_uri`**（PR-B 新增，与 discovery 任务不同 —— 那是不同工具）：
  - **幂等：** `WHERE worker_uri IS NULL` filter；只 NULL 行被更新。
  - **派生：** 每个 NULL 行，parse `session_uri`，算 `WorkerSpawn.worker_uri_for(parsed, adapter_id, target_id)`，写回为 string。
  - **日志：** 打印已更新行数 + 剩余 NULL 行数。完全成功退出 0；任何派生 raise 则非零退出（按 `feedback_let_it_crash_no_workarounds` —— 坏行是 bug，不是 soft-fail）。
  - **Operator 流程：** Migration A 和 Migration B 之间运行一次；mix 任务无需 phx restart。
- **Forward-only Migration B**（`apps/ezagent_core/priv/repo/migrations/<later_timestamp>_pr_a_worker_uri_not_null.exs`）：`NOT NULL` 标志。Alter 前执行前置检查：`SELECT count(*) FROM external_mirror_bindings WHERE worker_uri IS NULL`；非零则 migration abort 并给出明确 error 指引 operator 跑 backfill 任务。Follow-up migration 属于 PR-A（本 SPEC 实现对），但 **仅** 在 backfill 任务跑过后运行；§9.1 文档。
- **写路径（CRIT-4.2 —— 三处都要改，不只 action body）：**
  1. **Schema：** `Ezagent.ExternalMirror.BindingRow`（`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/binding_row.ex:42-50`）在 `schema "external_mirror_bindings"` block 加 `field(:worker_uri, :string)`。`@type t`（`:54-65`）加 `worker_uri: String.t() | nil`（类型 union 承认过渡 NULL 窗口 —— Migration B 后窄化为 `String.t()`）。
  2. **Changeset：** `BindingRow.insert/1`（`:87-108`）把 `:worker_uri` 加进 `Ecto.Changeset.cast` 字段列表（`:90-99`）**和** `Ecto.Changeset.validate_required` 列表（`:100-108`）。无这些，Ecto 静默 drop attrs map 里的字段（cast 忽略未知 key），Migration B 后 insert 在 DB 层失败而不是 changeset 层。
  3. **Action body：** `Behavior.ExternalMirror.invoke(:bind, ...)` 的持久化步骤在 `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex`（约 `:747-758`）在传给 `BindingRow.insert/1` 的 attrs map 中 populate `worker_uri = WorkerSpawn.worker_uri_for(session_uri, adapter_id, target_id) |> URI.to_string()`。PR-B 之后所有 **新** 行有非 NULL `worker_uri`。
- **读路径：** `AdapterInstall.reconcile_persisted_bindings/1`（`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_install.ex:193-220`）仍结构性派生 Worker URI（行里有 session_uri + adapter_id + target_id）；新列给删除 cascade 用，不是 reconcile 路径。Reconcile 路径不变。
- **Cascade 查询（过渡期，PR-B 实现）：**

  ```elixir
  # Migration B 落地且 pre-r2 NULL 行 backfill 之前，cascade 防御性地匹配
  # worker_uri 等值 AND 任何仍 NULL 行的派生匹配。Migration B 断言 NOT
  # NULL 后，第二个 clause 是 dead，可在 follow-up PR 移除。
  worker_uri_str = URI.to_string(target_worker_uri)

  # 直接匹配 —— 已 populate 行。
  Repo.delete_all(
    from b in BindingRow,
    where: b.worker_uri == ^worker_uri_str
  )

  # 过渡安全网 —— 防御性 re-derive Worker URI 对任何仍 NULL 行并比较。
  # Migration B NOT NULL 生效后在 follow-up PR 移除（届时 NULL 行按
  # invariant 不能存在）。
  null_rows = Repo.all(
    from b in BindingRow,
    where: is_nil(b.worker_uri)
  )

  Enum.each(null_rows, fn row ->
    derived =
      WorkerSpawn.worker_uri_for(
        Ezagent.URI.parse!(row.session_uri),
        row.adapter_id,
        row.target_id
      )
      |> URI.to_string()

    if derived == worker_uri_str do
      Repo.delete(row)
    end
  end)
  ```

  Race-free + NULL-safe。过渡第二 clause 由同 `null:` filter 守门；Migration B 前置检查断言零 NULL 行后，第二 clause 是 dead。INV-15（新增）pin post-backfill invariant。
- **`bound_by` 不变。** 仍记 creator identity。`bound_by` 的 User cascade scrub 属于 User cascade 的 audit-tombstone-sentinel step；不是 Worker-scope。

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

### 3.9 边界情况 —— 删除中的并发 dispatch（MED-3.5 —— 修正 BEAM/OTP 语义）

原子 `tombstone_and_kill/1`（§3.3）关闭了原始 kill-vs-tombstone race。剩余并发故事依赖 `:brutal_kill` 和 `GenServer` 语义的真相，**不** 依赖 graceful terminate drain：

1. **`:brutal_kill` 完全绕过 `terminate/2`。** Kind.Server GenServer 的 `terminate/2` callback（`apps/ezagent_core/lib/ezagent/kind/server.ex:752-791`，处理 `:on_terminate` snapshot save + Behavior teardown drain）当 parent 做 `Process.exit(pid, :brutal_kill)` 时 **不** 被调。这是故意的：被删 Kind 即将 snapshot 的任何 state 现在都无关紧要（entity 正被永久移除）。持久性反而来自先于 kill 的 **同步** DB tombstone insert —— kill 触发时，持久性承诺（"这个 URI 永久没了"）已在 DB 里。

2. **in-flight `GenServer.cast` 到被杀 pid。** 生产 dispatch 在 `apps/ezagent_core/lib/ezagent/invocation.ex:111` 用 raw `GenServer.cast`。kill 之前已发出的 cast **给发送方返回 `:ok`**（cast 已入队；发送方不知道是否被处理）。kill 之后 mailbox 被悄悄丢弃 —— **不会** 给 cast 返回 `{:error, :noproc}`。**这是可接受的** 因为：(a) 边界 3（SpawnRegistry.spawn）在下次 dispatch 尝试拒绝 re-spawn，系统不会 respawn 一个 Kind 来处理丢失的 cast；(b) entity 正被结构性移除 —— 对已删 entity 静默丢失 cast 是 **正确** 结果，不是 bug。

3. **in-flight `GenServer.call` 到被杀 pid。** Call 用 `GenServer.call(pid, ..., timeout)`。如 call 在 kill **之前** 发出且 pid 被 monitor（标准 call 路径），link/monitor 触发后 call 返回 `{:error, :noproc}`（或 raise `:exit, {:noproc, _}` 取决于 `GenServer.call` vs `GenServer.cast` 语义）。用 `Invocation.dispatch_call/1`（`:call` mode）的 caller 把这表面化为 LV/HTTP caller 的 clean error。

4. **`tombstone_and_kill` 之后但后续 cascade step 完成之前到达的 dispatch。** Lookup phase（`KindRegistry.lookup/1`）返回 `:error`（pid 在进程死亡时从 Registry drop），或 SpawnRegistry 路径返回 `{:error, :tombstoned}`（边界 3）。两种都给出 clean error。

5. **完整删除序列之后到达的 dispatch（正常路径）。** 全三个边界拒绝 —— caller 取决于走的路径拿到 `:tombstoned` 或 `:noproc`。

6. **HIGH-5.3 —— `:kill_timeout` 窗口期内到达的 dispatch。** 如 `tombstone_and_kill/1` 因 brutal_kill 信号未完（陷 C-NIF 等不可杀状态）返回 `{:error, :kill_timeout}`（§3.3 step 4 timeout），活 pid **仍** 在 KindRegistry 注册。`Invocation.dispatch/1`（`apps/ezagent_core/lib/ezagent/invocation.ex:87-107`）调 `KindRegistry.lookup/1` 返回仍注册 pid 并直送 cast/call —— **不** 在 dispatch 热路径查 tombstone 表。所以活 pid 在挺过 kill 信号的短暂窗口内可能续服消息。这作为已知的清理-有界边界 case 文档化：(a) `Behavior.EntityDeletion` 返回 `:partial` 含 `step_failed: :tombstone_and_kill_kill_timeout`，告诉 operator 删除已不可逆 committed（DB + ETS tombstone）但清理不完整；(b) operator runbook 说 SIGKILL BEAM 节点 OR 等 OS supervisor restart，之后 `Registry` drop 死 pid + 边界 1 拒绝 re-spawn。URI 永久不能 respawn（边界 1/2/3 结构性 hold）但非瞬时 dead-on-the-wire。

不需要 "transactional dispatch barrier"。(a) DB-tombstone-before-kill（持久性）+ (b) `:brutal_kill`（立即终止，无 graceful drain）+ (c) 三个强制边界（无 re-spawn）+ (d) 接受 cast-loss 作为已删 entity 的正确语义，组合起来对 **正常** 路径结构性 race-free。`:kill_timeout` 路径把结构性保证从 "瞬时不可达" 窄化为 "永久不能 respawn + 仅活的不可杀 pid 短暂可达"。

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
- `apps/ezagent_core/priv/repo/migrations/<timestamp>_pr_a_worker_uri_column.exs`（新）—— 给 `external_mirror_bindings` 加 `worker_uri` 作 `null: true`（B5 Migration A）
- `apps/ezagent_core/priv/repo/migrations/<later_timestamp>_pr_a_worker_uri_not_null.exs`（新）—— 设 `worker_uri NOT NULL` 配文档化前置检查（CRIT-3.3 Migration B）
- `apps/ezagent_core/lib/mix/tasks/ezagent_entity_deletion_backfill_worker_uri.ex`（新）—— 幂等 backfill mix 任务（CRIT-3.3）；**必须** 在 Migration A 和 Migration B 之间运行
- **改** `apps/ezagent_core/lib/ezagent/spawn_registry.ex` —— 加 `tombstone_and_kill/1` 公开 primitive + `tombstoned?/1` 只读 + 在 `spawn/1` 入口加 tombstone check（边界 3）；primitive 的 kill 步骤按 §3.3 用 `Process.exit(pid, :brutal_kill)` + `Process.monitor` + `receive {:DOWN, ...}`（MED-3.5）
- **改** `apps/ezagent_core/lib/ezagent/kind.ex` —— 在 `spawn/2` 入口加 tombstone check（边界 2）
- **改** `apps/ezagent_core/lib/ezagent/kind/server.ex` —— 在 `init/1` 入口加 tombstone check，tombstoned 时 return `{:stop, :tombstoned}`（边界 1 —— 权威）
- **改** `apps/ezagent_core/lib/ezagent_core/application.ex` —— slot `Ezagent.SpawnRegistry.Tombstone.load_into_ets/0` 在 `Repo` 迁移 **之后** 且在 `Ezagent.KindSupervisor` boot **之前**；加 `SystemPrincipal.ensure(SystemPrincipal.uri("entity-deletion-cascade"))` 调用在 `register_system_kind/0` **之后**，让 cascade principal 在任何 deletion 触发前已存在（CRIT-3.1）
- **改** `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex` —— 加 `{"system://entity-deletion-cascade", [<窄 Chat:scrub_owner cap>]}` 条目（CRIT-3.1）
- **改** `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/binding_row.ex`（CRIT-4.2）—— schema block 加 `field(:worker_uri, :string)`，更新 `@type t`，把 `:worker_uri` 加进 `insert/1` 的 `cast` **和** `validate_required` 两个列表
- **改** `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex`（`:bind` action body）—— 在传给 `BindingRow.insert/1` 的 attrs map 中 populate `worker_uri`（B5）
- **改** `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex` —— 加 `:scrub_owner` action（B3）；按 CRIT-5.1 的 **五处分别更新**：(1) `actions/0`（chat.ex:88）—— `:scrub_owner` 加进列表；(2) `required_caps/0`（chat.ex:~102）—— 加 `:scrub_owner` 的 cap shape；(3) `cap_subjects/0`（chat.ex:108-116）—— 声明 cap subject 让 `CapabilityRegistry.register/3` 注册它；(4) `invoke/4` —— 按 §3.5 实现 slice mutation；(5) `interface/0`（chat.ex:1036-1072）—— 声明 args validator（`{:deleted_uri, :uri}`）；**也** (6) `data_owner/1`（`chat.ex:1333-1342`）—— 加 tombstone 防御 check（CRIT-3.2）
- **改** `apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex`（`:605-614` `register_chat_behaviors/0`）—— 加 `CapabilityRegistry.register(Session, :scrub_owner, Chat)` 调用（CRIT-5.1）
- **改** `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex`（`:593-600` `data_owner/1`）—— 加 **同样** tombstone 防御（CRIT-5.2）；从 Session slice 拿到 owner 后调 `SpawnRegistry.tombstoned?(owner)`；如 true 返回 `:no_owner`
- **改** `apps/ezagent_domain_chat/lib/ezagent/behavior/publisher/session_impl.ex`（`:136-144` `data_owner/1`）—— 加 **同样** tombstone 防御（CRIT-5.2）
- **改** `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex` —— 在 `verify/2` 入口（bcrypt **之前**），调 `SpawnRegistry.tombstoned?(uri)`；如 true，跑 `Bcrypt.no_user_verify()` 并返回 `{:error, :tombstoned}`（HIGH-3.4 —— INV-14 defense-in-depth）
- `apps/ezagent_domain_identity/lib/ezagent_domain_identity/user_deletion_adapter.ex`（新）
- 测试：§5 invariant test + adapter 单测 + boundary-1 单测（Kind.Server 拒绝 tombstoned URI） + boundary-2 + boundary-3 + chat.scrub_owner 单测 + chat.data_owner cold-load 测试（INV-13b） + token.verify tombstone 测试（INV-14）

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

Worker URI backfill（CRIT-3.3，与 discover_orphans 分开）：**第二个** mix 任务 `mix ezagent.entity.deletion.backfill_worker_uri` 为 pre-r2 行 populate 新的 `external_mirror_bindings.worker_uri` 列。幂等（filter `WHERE worker_uri IS NULL`）。**必须** 在 B5 Migration A（`null: true` 加列）和 Migration B（`NOT NULL`）之间运行；Migration B 在仍有 NULL 行时 abort。

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
| INV-13 | 对 setup 中创建的 `owner_uri = target` Session S：删除后 dispatch `Behavior.Chat.data_owner(S_uri)` 返回 `:no_owner`（不是已删 target URI），AND 看 S 的 live slice：`slice.owner_uri == nil` | B3 —— Session owner 未通过新 `:scrub_owner` action scrub → 已删用户仍驱动 data_owner authz |
| INV-13a | `EzagentCore.Application.start/2` 后 `system://entity-deletion-cascade` principal 存在 KindRegistry 中，且其 caps 集是 (1) `SystemPrincipal.Catalog.caps_for!(self_uri)`（含 cascade `Chat:scrub_owner` cap）和 (2) `Identity.init_slice/1` 给每个 Entity Kind 的结构性自-`Identity:list_caps` cap（HIGH-4.3）的 **不相交并集**。**无** 其它 cap。另：实际 cascade dispatch（按 CRIT-4.1 修复调 `SystemPrincipal.caps(cascade_principal)`）完成不 raise ArgumentError。 | CRIT-3.1 + CRIT-4.1 + HIGH-4.3 —— 窄 system principal 未正确安装，或 caps 漂移宽于必要，或 caps/1 调用 crash |
| INV-13b | **（CRIT-3.2 + CRIT-5.2）** 在 User 删除 **之后**（且 restart 后让 principal 不在 KindRegistry 直到 lookup 驱动 respawn）cold-load 一个 snapshot 中 `:chat` slice 含 `owner_uri = target` 的 Session。然后调 **三个** 生产 data-owner 解析器并断言每个都返回 `:no_owner`（**不是** 已删 target URI）：(1) `Behavior.Chat.data_owner(S_uri)`；(2) `Behavior.ExternalMirror.data_owner(S_uri)`；(3) `Behavior.Publisher.SessionImpl.data_owner(S_uri)`。每处都必须在读站点应用 SpawnRegistry tombstone 防御。 | CRIT-3.2 + CRIT-5.2 —— cold-Session 安全依赖 **所有** data_owner 解析器的读站点 tombstone check；三处任一漏检留下权限暴露面 |
| INV-14 | 对 setup 中给 target 铸的 token：`Token.verify(plain_token, target)` 返回 `{:error, :tombstoned}`（NOT `{:error, :invalid_credentials}` 且 NOT `{:ok, _}`）。验证：`Token.verify/2` 入口的 tombstone check 在 bcrypt 比较 **之前** 触发，且 `Bcrypt.no_user_verify()` 被调以防 timing leak。 | B6 + HIGH-3.4 —— token 行 escape cascade 或 Token.verify 缺 tombstone defense check 或 check 放在 bcrypt **之后**（timing leak） |
| INV-15 | PR-B + backfill 任务运行 + Migration B 应用后，`external_mirror_bindings` 中每行：`worker_uri` 非 NULL 且等于 `WorkerSpawn.worker_uri_for(parsed_session_uri, adapter_id, target_id) |> URI.to_string()`。另：cascade 查询里的 `Repo.delete_all(WHERE worker_uri IS NULL)` 过渡分支结构性 dead（返回 0 affected rows）。 | CRIT-3.3 —— backfill 任务未运行，或派生错，或 Migration B 前置检查被绕过 |
| INV-15a | **（MED-4.5 —— 过渡分支覆盖）** Backfill 之前：直接 INSERT 一个 `worker_uri: nil` 的 `BindingRow`（绕过 `:bind` action body，如通过 raw struct 的 `Repo.insert/1`）。通过 `WorkerSpawn.worker_uri_for(session_uri, adapter_id, target_id)` 结构性派生目标 Worker URI。对该 URI invoke Worker 删除。断言：(a) cascade 查询的过渡第二 clause 匹配 NULL 行并 `Repo.delete/1` 它；(b) 表中删除后无此行。 | MED-4.5 —— 过渡 NULL-safety 分支静默坏；pre-backfill Worker 删除漏行 |

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

**`system://entity-deletion-cascade` principal 权威备注（HIGH-4.3）：** `SystemPrincipal.ensure/1` 后 principal 携带 **两个** cap —— cascade 目的 `Chat:scrub_owner` cap（来自 Catalog）**和** `Behavior.Identity.init_slice/1` 给每个 Entity Kind 注入的结构性自-`Identity:list_caps` cap。自 cap 是 no-op 权威面（读自己的 caps 返回授权了 call 的同一个 MapSet），不是 cascade 相关问题。INV-13a 显式断言 disjoint-union shape —— caps 漂移宽于此集是 SPEC 违反。

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

### 7.8a "Cascade dispatch `:scrub_owner` 配 `ctx.caps = admin_wildcard`"（r3 —— 按 CRIT-3.1 拒绝）

CRIT-3.1 窄 system principal 的替代：在 cascade dispatch 站点注入 `Ezagent.SystemPrincipal.caps("bootstrap")`（wildcard admin caps）到 `ctx.caps`。**拒绝**：按 `feedback_let_it_crash_no_workarounds`，结构窄化 over policy-wildcard。Wildcard 会让 cascade dispatch 中任何未来 bug 升级到 **任何** Kind 上的 **任何** action。专用 `system://entity-deletion-cascade` principal 恰好携带所需 cap 不多不少，Catalog 可审计。

### 7.8b "B3 仅主动 in-memory scrub，跳读站点防御"（r3 —— 按 CRIT-3.2 拒绝）

替代：完全依赖 cascade 的 `:scrub_session_owner_uri` step mutate live Session，接受 cold-loaded Session 短暂带 stale `owner_uri` 直到下个用户驱动 action 触发 re-read。**拒绝**：cold load 不是唯一 race —— 还有 cascade 自己 `KindRegistry.list_all/0` 和 per-session dispatch 之间的窗口。`Chat.data_owner/1` 的读站点 tombstone 防御是 defense-in-depth（与 `Token.verify` 的 tombstone check 平行），一个 check 关 **两个** 窗口。

### 7.8c "B5 NOT NULL 单 migration 配维护窗口"（r3 —— 考虑过，延迟到 OQ-8）

CRIT-3.3 两-migration + backfill-任务方案的替代：单 migration 原子加列 + populate + NOT NULL，需要 phx 停（按 `feedback_destructive_migration_anti_pattern`）。**延迟**：这是 Allen 的真选择；两-migration 路径对 CI 和 dev 更友好（greenfield 部署完全感知不到），但 prod 要求 operator 纪律（Migration B 前必须跑 backfill 任务）。OQ-8 文档此选择。

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
- `mix ezagent.entity.deletion.backfill_worker_uri`（新 —— CRIT-3.3）—— 对 pre-r2 行幂等 backfill `external_mirror_bindings.worker_uri`。B5 Migration B（NOT NULL）的 pre-flight。Operator 在 Migration A 落地后每个环境运行一次；Migration B 在仍有 NULL 行时拒绝运行。

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

### OQ-8 —— `external_mirror_bindings.worker_uri` NOT NULL 时机（r3 —— 按 CRIT-3.3 细化）

B5 修复加 `worker_uri` 初始 `null: true`（Migration A），follow-up Migration B 在 operator 跑 `mix ezagent.entity.deletion.backfill_worker_uri` 后设 `NOT NULL`。Migration B 有前置检查，仍有 NULL 行时 abort。Greenfield 部署（dev/test/全新 prod）完全跳过该 gap。Allen 确认两-migration + backfill-任务模式可接受，OR 偏向单 migration 配维护窗口？

---

## §11 Codex 对抗性 review 问题 (for r4)

0. **窄 system principal 健全性（CRIT-3.1 + CRIT-4.1 + HIGH-4.3）：** 新 `system://entity-deletion-cascade` 设计是仅授权 Session 上的 `Chat:scrub_owner`；r4 承认 `Identity.init_slice/1` 给每个 Entity Kind 加的结构性自-`Identity:list_caps` cap。验证实际 cascade dispatch 路径正确解析（`SystemPrincipal.caps/1` 不 ArgumentError，`Identity.init_slice/1` 注入不导致未授权 cap-set 漂移）。trace cascade 的 `Chat:scrub_owner` dispatch 的 `Capability.matches?/2`，以及该 principal 假设的 invoke 其它 Chat action（如 `:send`、`:join`）尝试 —— 确认那些被拒绝。

0a. **Cold-load 防御正确性（CRIT-3.2）：** `Chat.data_owner/1` 防御每次读都调 `SpawnRegistry.tombstoned?(owner)`。验证：(a) ETS lookup 对 data_owner 热路径足够快；(b) check 在 URI 返回 **之前** 跑；(c) 没有 fast-path 优化绕过 check；(d) 与 INV-13b 的 cold-load 断言一致。

0b. **r4 矛盾文本？** 重读 §3.2（`:partial` 子 shape 区分）、§3.3（4 步顺序配 timeout 返回）、§3.5（CRIT-4.2 BindingRow 写路径三处）、§3.9（修正 BEAM 语义）、§4.1（PR-B 变更列表 —— 现更大）。任何两条陈述矛盾？具体：§3.2 的 `:tombstone_and_kill_kill_timeout` step_failed vs §3.3 的 `{:error, :kill_timeout}` 原始返回；§3.5 cascade 查询 NULL-safety 分支 vs §4.1 BindingRow 的 `validate_required` 列表（过渡 vs post-Migration-B 状态）；disjoint-union INV-13a vs §6 plugin-isolation 表仍说 principal "ONLY invokes Chat:scrub_owner"。

1. **多边界 tombstone 强制（B1）：** trace apps/ 树里每条以 Kind 活在内存结束的代码路径。`Kind.Server.init/1` 真的是唯一的每个 Kind 启动必经 chokepoint？找任何 r3 修复都活下来的 bypass path（其它节点 hot-takeover？直接 `:proc_lib.start_link`？不用 `Kind.Server` 的 plugin 自定 DynamicSupervisor child_spec？）。

2. **原子性契约 + timeout 语义（B2 + MED-4.4）：** `SpawnRegistry.tombstone_and_kill/1` 4 步，receive 超时返回 `{:error, :kill_timeout}`。走失败模式：(a) 步骤 3 成功但 DOWN 消息丢失（如 monitor 没正确建）；(b) 步骤 3 返回 false（pid 已死）；(c) receive raise（如 mailbox 洪水）。找任何 tombstone 半立 **或** Behavior `:partial` 映射与 §3.3 实际返回不一致的状态。

3. **通过 system principal 的 Session owner scrub（B3 + CRIT-3.1 + CRIT-3.2 + CRIT-4.1 + HIGH-4.3）：** cascade 现在以 `system://entity-deletion-cascade` 身份 dispatch `:scrub_owner`。关注：
   (a) Lookup 走 `KindRegistry.list_all/0` + scheme filter（生产无 `list_matching/1` API 按 `kind_registry.ex:73`）。验证 EN 代码示例用正确 API 且 filter 不漏 session URI。
   (b) Cascade dispatch 的 cap-check 路径：`Kind.Runtime.authorize/4`（`apps/ezagent_core/lib/ezagent/kind/runtime.ex:249-298`）在 slice-resolved `holds_cap?` 路径 **之前** 查 `ctx.caps`。r4 设 `ctx.caps = SystemPrincipal.caps(cascade_principal)`。`Capability.matches?/2` 谓词接受这个 cap shape vs cascade 的 needed cap 吗？
   (c) Cold-load：r3/r4 修复把防御放在 `Chat.data_owner/1`。验证 **没有** 其它生产读站点（如 LV view、admin 脚本、不同 Behavior 的 `data_owner/1`）直接读 `Session.owner/1` 而仍 honor tombstoned URI。

4. **Worker cascade 完整（B5 + CRIT-3.3 + CRIT-4.2 + MED-4.5）：** r4 修 BindingRow schema/cast/required 遗漏。验证：(a) 每条写 `external_mirror_bindings` 的代码路径都经 `BindingRow.insert/1`（没其它直 SQL insert）；(b) backfill 任务从 `(session_uri, adapter_id, target_id)` 正确派生 `worker_uri`；(c) 过渡 NULL-safety cascade 分支处理 pre-backfill 场景（INV-15a）；(d) Migration B 的前置检查真的触发（Ecto migration `def change` body —— SPEC 文档具体查询还是只声明？）。

5. **r4 引入矛盾？** 同 q0b 但具体找 r4 引入 vs r3 文本未更新的矛盾。点查：§6 plugin-isolation 表声明 "exactly the cap it needs" vs HIGH-4.3 承认自-`Identity:list_caps` cap。

6. **Bilingual lockstep 在 r4 维持？** r4 §3.5 cascade 表已 byte-identical（在 LOW-3.6 修复时验证）。r4 在 BindingRow + system principal + timeout 返回周围加散文。验证 ZH §3.5 + §3.3 + §3.2 反映新 r4 文本。

7. **Plugin isolation tiebreaker check（post-r4）：** §6 表声明 plugin adapter 永不直接碰 `SpawnRegistry.tombstone/1`。验证：是否有任何代码路径让 DeletionAdapter NOT 通过 `tombstone_and_kill/1` 调进 SpawnRegistry tombstone 机制？

8. **Entity_tokens defense-in-depth（B6 + HIGH-3.4）：** 验证 `Token.verify/2` 新 tombstone check（`token.ex:106-118`）结构性放在 bcrypt **之前** 且 tombstone-hit 路径调 `Bcrypt.no_user_verify()` 以打败 timing leak。

9. **LV confirm dialog UX（从 r1 q9 保留）：** PR-C admin LV 加 "Delete" button + confirm dialog 询问 reason。是否还应要求 operator **TYPE 被删的 URI**（与 GitHub 的 "type the repo name to delete" 平价）？提议默认：irreversible 操作 type-the-name confirmation。Allen 确认？

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
  ▼ step 2 (THE 原子 primitive —— B2 + MED-3.5 修正)
SpawnRegistry.tombstone_and_kill(target):
  │   - INSERT entity_tombstones row (DB)
  │   - :ets.insert(@tombstone_table, ...) (失败时 rollback DB)
  │   - Process.exit(Kind pid, :brutal_kill)  [绕过 terminate/2 —— 故意]
  │   - Process.monitor(pid) + receive {:DOWN, ...} (短 timeout)
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
  │   [B3 + CRIT-3.1: :scrub_session_owner_uri 以 system://entity-deletion-cascade 身份 dispatch]
  │   [CRIT-3.2: Chat.data_owner/1 读站点 tombstone 防御覆盖 cold-loaded sessions]
  │   [B5 + CRIT-3.3: :drop_external_mirror_bindings 用 worker_uri = target + 过渡 null 安全网]
  │   [B6 + HIGH-3.4: :revoke_entity_tokens + Token.verify 拒绝 tombstoned URI (defense-in-depth)]
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
