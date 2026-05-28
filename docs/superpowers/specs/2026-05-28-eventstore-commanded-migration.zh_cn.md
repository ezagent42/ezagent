# SPEC — Ezagent 状态模型迁移到 EventStore + Commanded (CQRS / 事件溯源)

**状态：** r3 — codex 对抗审查 r3 草稿。2026-05-28。

## r3 changelog（相对 r2 的 delta，保留作 trail）

回应 codex r2 REJECT 的 6 HIGH + 2 MED（r2 无 CRIT — r1 CRIT 已闭合）：

- **HIGH-1（§4.1.5 清单仍错）：** r2 误把 `Ezagent.Workspace` 标为 `{:snapshot, :on_change}`（实际 `:ephemeral` @ `workspace.ex:61`），`ExternalMirrorWorker` 标为 `:on_terminate`（实际 `:ephemeral` @ `external_mirror_worker.ex:71`）；漏 `Ezagent.Entity.System`（真实 Kind，`:ephemeral` @ `system.ex:32`，带 Routing behavior）；漏 `Ezagent.Behavior.IdentityAdmin`（与 Identity 同文件，@ `identity.ex:328`）。**r3 fix：** §4.1.5 用静态校验的 persistence 值重写。新加 §4.1.5-table-note 澄清 `:ephemeral` Kind（Workspace、Worker、System）通过**外部表/registry**持久（Workspace → `workspaces` SQLite + `Workspace.Store`；Worker → `external_mirror_bindings` 重建；System → config-derived bootstrap singleton，不迁，作为 Pty 那样的文档化例外）。§6.0 import 任务按来源逐 Kind 调整。
- **HIGH-2（§4.8 一致性矩阵不全且文件名错）：** r2 引用了不存在的 `agents_live.ex`（实际：`agent_new_live.ex`），用了 TBD 行，漏了诸多 write→read site。**r3 fix：** §4.8 重写为静态校验的 file:line。新增：`users_live.ex:202`（set_password）、`:230`（promote_to_system）、`:250`（revoke from system）、`workspace_detail_live.ex:255`（remove member）、`routing_live.ex:307`（delete_rule）、`agent_api_keys_live.ex:159`（delete_api_key）。`agent_new_live.ex:120` 修正 create-agent。矩阵宣布为**真值**；r3 把不变式升级为 AST 扫描 `Ezagent.Invariants.ConsistencyMatrixTest`：遍历每个 LV 的 `handle_event/3` AST，找到 dispatch + 之后的 `assign/2` 重读，断言用 `:strong`。手表是文档；AST 扫描是门。
- **HIGH-3（§6.1 Phase 10-A 仍自相矛盾）：** r2 留着「Worker first（最小 Kind）— 一个 Kind 迁，其余不变」措辞，同时把 Session ExternalMirror 也拉进来。**r3 fix：** Phase 10-A 重命名为「ExternalMirror slice + Worker — bind-spawn 耦合边界」。「最小 Kind」框架放弃。新段落显式枚举 split-brain 协议：Session 的 `Behavior.Chat` + `Behavior.Publisher.SessionImpl` + `Behavior.OrchestratorAdmin` slice 留 GenServer；只有 `:external_mirror` slice 进 Session aggregate。Session GenServer 活着 AND Session aggregate 有事件流 — 同一 URI 在 10-A 期间**两个**状态存储。派发前流水线按命令来源 Behavior 路由：ExternalMirror 命令 → aggregate；其余 → legacy。新 `Ezagent.SessionRouter` 模块拥有路由决策。不变式：任何触及 Session URI 的测试必须把 GenServer slice 和 aggregate 状态都驱到一致。
- **HIGH-4（§6.0 messages archive 列名/JOIN 错）：** r2 说 "按 `created_at` 过滤"；实际 schema 列是 `inserted_at`（per `20260516070500_phase2_messages.exs:23`）；按 session 历史是 `message_routings ⋈ messages` JOIN（per `message_store.ex:174`）。**r3 fix：** §6.0 messages archive 段落重写：永久查询是有序 UNION，前半 `message_routings ⋈ messages` 过滤 `inserted_at < <cutover_at>`，后半 `session_messages_projection` 过滤 `inserted_at >= <cutover_at>`，按 `inserted_at ASC` 序。`recent_in_session` / `older_than` / `in_session_since` 三个查询形状的 parity 门。
- **HIGH-5（§4.2.1 User 投影仍漏字段）：** r2 把 profile/token 字段加到 aggregate state，但 §5.1 投影表行没反映。**r3 fix：** §5.1 投影表更新 — `user_profile_projection(uri, workspace_uri, display_name, email, registered_at, destroyed?)`；`user_tokens_projection(uri, token_id, token_hash, label, scope, expires_at, last_used_at, minted_at, revoked_at, workspace_uri)`。§6.0 import 加字段级 parity 门：`entity_profiles` + `entity_tokens` 每行回放后必须产生对应投影行。
- **MED-6（§4.2.3 Session working-copy 形状欠定）：** r2 写 `template_working_copy: nil` — 实际默认是结构 map @ `chat.ex:255` 有 `agent_slots`、`routing_rules`、`orchestrator_template_uri`、`default_workspace_uri`、`description`。**r3 fix：** §4.2.3 扩展 — `template_working_copy` 是含 5 个具名子字段的子 struct，默认 per `default_template_working_copy/0`。加 replay 测试：populated working copy Session 重建所有 5 字段。
- **HIGH-7（§3.8 saga step 0 是注释、不是代码）：** r2 文档化 `pre_destroy_caps` / `pre_destroy_sessions` / `pre_destroy_lineage_parent` 在 saga defstruct 注释，实际 `defstruct` 行没有。**r3 fix：** §3.8 saga 重写显式 step 0：`%CaptureDestroyPreSnapshot{}` 命令在 `%AgentDestroyRequested{}` 之后立即 dispatch，aggregate 的 `execute/2` 在命令时读投影、发 `%DestroyPreSnapshotCaptured{}` 事件（payload 含 caps/sessions/lineage_parent），aggregate 的 `apply/2` 写到 aggregate 自身状态。补偿命令在补偿时直接从 aggregate 读 snapshot 字段。defstruct **扩展**这些字段。Step 2 DestroyChildAgents 仍宣布 non-compensable 按 saga forward-only 教条；post-r3 runbook 文档化 operator 修复路径（`mix ezagent.saga.repair --saga DestroyAgentSaga --uri <uri>` 读部分残留 + 发手工清理命令）。
- **MED-8（§6.4 cleanup gate 可被假 ticket 欺骗）：** r2 只验「匹配 docs/runbooks 条目」；不是真 artifact 门。**r3 fix：** §6.4 preflight 要求**drill receipt**：签名 JSON artifact `priv/cleanup_receipts/<timestamp>.json` 含 `{backup_path, backup_sha256, live_row_count, restored_row_count, parity_report_sha256, operator_email, drill_completed_at, expires_at: +24h, signature}`。`mix ezagent.cleanup.drill` 是唯一 writer；drill 时计算 SHA。`mix ezagent.cleanup.execute` 验证：(i) HMAC 签名；(ii) backup SHA 仍匹配；(iii) live DB 行数与 receipt 匹配（自 drill 起未变）；(iv) 重跑 parity；(v) `operator_email` 在 `priv/cleanup_operators.allowlist`；(vi) `drill_completed_at < now < expires_at`。任何篡改使 SHA 失效。receipt 不可凭 `--operator-approved` flag 单独伪造。CI 跑非存在 receipt + 假签名 receipt，断言两者退出非 0。

---

## r2 之前的状态

## r2 changelog（相对 r1 的 delta，保留作 trail）

回应 codex r1 REJECT 的 2 CRIT + 4 HIGH + 2 MED：

- **CRIT-1（缺前向数据迁移计划 — §4.1 / §6 / §8）：** r1 说迁移后的 Kind "不迁现有 snapshot；第一条命令创建新鲜事件溯源状态"。这在切换点丢失活的 User/Session/Agent/Workspace state，按 `feedback_destructive_migration_anti_pattern` 不可接受。**r2 fix：** 新增 §6.0（前向数据迁移）为每个 Phase 10-A 到 10-C 起点的强制 Step 0。它定义 per-Aggregate 的「snapshot import」事件类（如 `%UserSnapshotImported{}`），由 `mix ezagent.aggregate.import --kind <kind>` 任务在生产派发路由到 aggregate **之前**对每个现有 URI 发射一次。Import 事件携带完整的 pre-existing slice payload。Aggregate 的 `apply/2` 有专门子句处理 import 事件、水合 aggregate 状态。Parity 门（事件回放 aggregate 状态 vs `kind_snapshots` 行的回读对比）是 import 步骤的成功标准；切换在 parity 绿之前**不**发生。§6.1/6.2/6.3 扩展为含 import 任务作为每 Phase 的 Step 0。
- **CRIT-2（Phase 10-A 桥缺口 — §6.1 / §8.2）：** r1 Phase 10-A 只迁 Worker，但 legacy Session 的 `Behavior.ExternalMirror` 仍在 `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:394` + `:677` 直接调 `Ezagent.Kind.spawn(Ezagent.Entity.ExternalMirrorWorker, params)`。Session 仍为 GenServer 时不发 `BindingCreated` 事件，`BootstrapWorkerSaga` 永远不触发。**r2 fix：** Phase 10-A 修订为：(a) 把 Session ExternalMirror behavior + Worker 一起迁（推荐 — bind 调用点紧耦合）**或** (b) ship 显式 `Ezagent.MigrationBridge.LegacyBind` shim，把 legacy `Kind.spawn(Worker, params)` 翻译为新 aggregate 上的 `%SpawnWorker{}` 命令 + 向新事件流注入合成 `%BindingCreated{}` 事件触发 saga。r2 默认选 (a)；如 Session-side 迁移过于纠缠则 fallback 到 (b)。§6.1 扩展含 Session ExternalMirror behavior delta。
- **HIGH-3（缺读后写一致性矩阵 — §3.3 / §6.2）：** r1 只说 "per 派发点 opt 到 :strong"、不枚举。r2 新增 §4.8（LV / Channel / CLI 一致性矩阵）— 一张表列出所有写后立即重读 state 的 callsite 及其要求一致性模式。静态枚举的 sites：`apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/users_live.ex:137`（create→list_users）、`workspace_detail_live.ex:165`（add member→get_by_name）、`entity_caps_live.ex:142`（grant cap→reload caps）、`routing_live.ex:235`（add rule→reload rules）。所有这些**必须**用 `consistency: :strong`（或具名投影器列表）。Phase 10-B/10-C 不变式测试断言每个枚举 site 满足；CI grep 门拒绝在这些派发路径上显式用 `consistency: :eventual`。
- **HIGH-4（Kind/Behavior 清单不全 — §4.2 / §4.3）：** r1 "5 entity Kind + 11 Behavior" — 实际 checkout 计数大得多。r2 新增 §4.1.5（完整 Kind/Behavior 清单）从 checkout 静态枚举：15+ Kind 模块（含持久的 `Ezagent.Entity.AgentTemplate` + `Ezagent.Entity.SessionTemplate`，皆 `{:snapshot, :on_change}`，加 per-flavor `CurlAgent` / `Echo` / `NpAgent`），24 个 Behavior 模块（漏掉：`ApiKeys`、`Template`、`OrchestratorAdmin`、`Pty`、`UserBinding`、`FeishuAllow`，加 4 个插件 agent-flavor behavior）。每个加 per-Phase 迁移去向列。§4.3 用完整列表重写。
- **HIGH-5（Session aggregate state 漏耐久字段 — §4.2.3）：** r1 Session aggregate struct 漏 `owner_uri`、`last_seen`、`monitors`、`last_message_id`、`last_message`、`send_cursor`、`recent_messages`、`template_working_copy` + Publisher 的 `ring` / `cursor` / `retention`（都耐久 — `Behavior.Chat.init_slice` 在 `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:144`-`:242` + `Publisher.SessionImpl.init_slice` 在 `apps/ezagent_domain_chat/lib/ezagent/behavior/publisher/session_impl.ex:150`-`:165`）。r2 fix：§4.2.3 Session aggregate state struct **重写**枚举每个耐久字段；非耐久运行时字段（`monitors` — 进程 ref 跨重启不存活）显式排除并加注。Rejoin / external mirror dedupe / publisher cursor catchup 的 replay 测试加入 Phase 10-B 不变式测试。
- **HIGH-6（User 投影 schema 漏 profile + token 字段 — §4.2.1 / §4.7）：** r1 `user_profile_projection` 只 `(uri, workspace_uri, registered_at, destroyed?)`。当前 `Entity.Profile` schema（`apps/ezagent_domain_identity/lib/ezagent/entity/profile.ex:21`）有 `display_name`（必需）+ `email`。当前 `Entity.Token` schema（`apps/ezagent_domain_identity/lib/ezagent/entity/token.ex:43`）有 `token_hash`、`label`、`last_used_at`。**r2 fix：** §4.2.1 User aggregate 加 `:profile` 字段（`%{display_name, email}`）+ 命令 `%UpsertProfile{}` / 事件 `%ProfileUpserted{}`。Token aggregate state + events 扩展含 hash/label/last-used。§5.1 投影更新匹配。
- **MED-7（DestroyAgentSaga 补偿只 retry/stop — §3.8 / §4.4）：** r1 saga `error/3` 重试后停。当前清理路径（`apps/ezagent_domain_chat/lib/ezagent_domain_chat.ex:189` session-create rollback、`apps/ezagent_core/lib/ezagent/behavior/sandbox.ex:240` sandbox-destroy cleanup）做显式逆操作。**r2 fix：** §3.8 DestroyAgentSaga 重写为 `error/3` 回调用 `{:continue, [%ReverseCommand{}, ...], context}` per-step 补偿。每步文档化：(a) 幂等合约；(b) 失败残留；(c) 逆命令；(d) 续跑行为。Step-failure 测试是 Phase 10-C 不变式。
- **MED-8（Phase 10-D 破坏性清理缺 operator gate — §6.4 / §8.4）：** r1 "最后 data dump 后删 `kind_snapshots`"。按 `feedback_destructive_migration_anti_pattern` + `feedback_completion_requires_invariant_test`，那不是门。**r2 fix：** §6.4 Phase 10-D `DROP TABLE kind_snapshots` 由三项门控：(a) 迁移脚本里 operator 批准 flag（mix 任务需 `--operator-approved <ticket-id>`）；(b) 已验证 backup restore drill — operator 把上次 snapshot dump 恢复到 temp DB 并断言行数匹配；(c) restore 后 parity check — import-replay vs 原 snapshot 在所有迁移 URI 跨字段相等。门本身是 `mix ezagent.cleanup.preflight` 任务，除非 (a)+(b)+(c) 全成立否则非 0 退出。SPEC §8.4 扩展。

---

## r1（初版）状态

**Tier:** 跨切的架构迁移。涉及 `apps/ezagent_core/`（Kind / Behavior / Invocation / Persistence / Snapshot / Audit），所有 `apps/ezagent_domain_*/`（User、Session、Agent、Workspace、ExternalMirror Worker 实体 Kind），LiveView 读层（`apps/ezagent_plugin_liveview/`），CLI（`apps/ezagent_cli/`），Web 派发面（`apps/ezagent_web/`），以及所有插件的写法范例。引入三个新的 umbrella app（`ezagent_event_store`、`ezagent_commanded_app`、`ezagent_projections`）以及一段混合运行期 — 部分 Kind 已是 Aggregate、其余仍为 GenServer。

**触发：** Allen 2026-05-28 06:31 — 暂停 SPEC #440（实体销毁生命周期），原因是 4 轮 codex REJECT 后没有收敛。销毁级联的 3 条 critical 诊断（无跨-Kind 原子性、部分失败不一致窗口、saga 式恢复需要现有 Kind=GenServer 模型不具备的结构原语），在事件溯源语义 + Process Manager 下全部化解。Allen 提出更深的假设：**我们建过的每一个多-Kind 工作流（BootReconciler、SpawnRegistry race 类、cap grant-time 检查、workspace cap-vis 5 轮迭代）都撞同一面墙**。销毁阻塞是这一类问题里最显眼的一个实例。

**Scope of THIS SPEC：**
- 全系统的架构迁移设计
- 不只是销毁生命周期 — 覆盖所有 Kind、所有状态变更、所有跨 Kind 工作流
- Phoenix + Commanded 混合集成（Allen 标记的关键研究问题）
- 分阶段迁移计划
- 性能 + 运维成本分析
- 回滚 / 中止路径

**Companion:** `2026-05-28-eventstore-commanded-migration.md`（按 `feedback_bilingual_docs_convention`）。

**前置 memory (load-bearing)：**
- `feedback_let_it_crash_no_workarounds` — 不做 shim/双路。若采纳 CQRS/ES，snapshot 表就是 Aggregate 回放的缓存，**不是** 并行的真值源。迁移是 commit 式（每 Kind hard flip），不是开关。
- `feedback_completion_requires_invariant_test` — 每阶段的门槛是一个不变式测试，当架构目标未达成时它 FAIL。每个迁移完的 Kind 的门槛是「该 Kind 的状态仅凭事件流就能确定性重建」（无 slice/snapshot fallback）。Saga 的门槛是「该多-Kind 工作流走 Process Manager，而非直接的跨 Kind GenServer.call」。
- `feedback_north_star_plugin_isolation` — 插件作者写 Command + Event + Aggregate 的 `execute/2` + `apply/2`。他们**不**碰 `Commanded.Application`、事件存储配置、投影接线、saga 注册。边界更紧。
- `feedback_destructive_migration_anti_pattern` — 参见 §6 / §8。迁移**新增**事件存储库；**不**销毁现有 snapshot 数据。§12 中如果某阶段中止，明确地分叉回到 slice/snapshot。
- `feedback_register_lookup_key_parity` — Aggregate 身份必须与现有 Kind URI 用同一方式规范化（`Ezagent.URI.parse!/1`）。路由器 `:identify` 子句使用规范化后的 URI 字符串；派发点之间规范化不一致会静默地把一条命令路由到全新的 Aggregate ID。§4.6 强制。
- `feedback_uuid_is_canonical_identifier` — Aggregate UUID 必须是现有 Kind URI 的规范化字符串。我们**不**铸造新的 UUID 列。URI 就是身份。
- `feedback_subagent_must_load_project_skills` — 每个阶段的实施 subagent 必须加载 `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`。
- `feedback_codex_review_every_pr` — 本 SPEC + 每个阶段的实施 PR 的 codex 审查都带逐字的 "no mix" 子句。
- `feedback_phase_planning_reads_main_docs` — §6 阶段编号符合 `IMPLEMENTATION_ROADMAP.md` §1.1（当前最新是 Phase 6 / partial）。本迁移会成为 Phase 10（在 Phase 9 PR-CC follow-ups 完成 + Phase 6 收尾之后）。
- `feedback_explain_problem_not_code_structure` — §1 先讲问题类（多-Kind 工作流缺原子性原语），§2 先讲决策（CQRS/ES），代码形状放 §4-§5。

**父级 / 历史上下文：**
- `IMPLEMENTATION_ROADMAP.md` §1.1 — Phase 0-6 已完成或在飞。本 SPEC 成为 Phase 10（跳过保留但未启动的 Phase 7-9 follow-up 工作）。
- `ARCHITECTURE.md` Decision Log #84 — 选了路径 B（`@behaviour Ezagent.Kind` + 共享 `Kind.Server` GenServer），而非路径 A（`use Ezagent.Kind` 宏）。本 SPEC 用路径 C（`Commanded.Aggregate`）取代两者。
- `ARCHITECTURE.md` Decision Log #59 + #60 — 同步 `on_change` snapshot 写 + 异步批 writer。事件溯源模型用「同步事件追加 + 每 N 事件可选 Aggregate snapshot」**取代**这套。
- `apps/ezagent_core/lib/ezagent/kind/server.ex` — 当前承载所有 Kind 的共享 GenServer。每个迁移完的 Kind 之后 Phase 10-D 弃用。
- `apps/ezagent_core/lib/ezagent/invocation.ex`（步骤 1-4、11-12）+ `apps/ezagent_core/lib/ezagent/kind/runtime.ex`（步骤 5-10）— 12 步派发流。迁移后步骤 5-10 折叠进 `Commanded.Application.dispatch/2`；步骤 5.5（CapBAC）+ 5.6（workspace 隔离）移到派发前的预流水线（§4.5）。
- `apps/ezagent_core/lib/ezagent/kind/snapshot.ex` — per-Kind snapshot 表。对迁移 Kind 变成 Commanded aggregate snapshot 库；混合期间未迁移 Kind 继续使用。
- `apps/ezagent_core/lib/ezagent/audit.ex` + `Ezagent.Audit.Writer` — SQLite `invocations` 审计表。迁移 Kind 的领域事件**事件流即审计日志**；未迁移 Kind 以及非领域的跨切遥测（如 `[:ezagent, :authz, :denied]` 否决侧）**保留**在 SQLite 表。
- `docs/superpowers/specs/2026-05-27-uri-canonicalization.md` — 规范化 `%URI{}` 的 chokepoint。§4.6 Aggregate ID 的来源走 `Ezagent.URI.parse!/1` 并通过 `URI.to_string/1` 喂给路由 `:identify`。
- `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` — 派发时 authz 不变式（步骤 5.5 chokepoint）。本 SPEC §4.5 说明 authz 检查如何从 `Kind.Runtime.handle_dispatch/4` 移出，进入包裹 `Commanded.Application.dispatch/2` 的预流水线，chokepoint 性质保留。

**参考库：**
- [commanded](https://github.com/commanded/commanded) — Elixir 的 CQRS/ES 框架。v1.4.10 最新。([hexdocs](https://hexdocs.pm/commanded))
- [eventstore](https://github.com/commanded/eventstore) — Elixir 的 PostgreSQL 事件存储库。v1.4.8 最新。
- [commanded_eventstore_adapter](https://hex.pm/packages/commanded_eventstore_adapter) — 把 `commanded` 接到 `eventstore` 的 adapter。
- [commanded_ecto_projections](https://hex.pm/packages/commanded_ecto_projections) — Ecto-backed 的 read-model 投影 helper。
- [Conduit 参考 app](https://github.com/slashdotdash/conduit) — Phoenix + Commanded Medium 克隆。
- [Gift-card demo](https://github.com/slashdotdash/gift-card-demo) — Phoenix LiveView + Commanded 参考。

---

## 1. 问题陈述 — 为什么迁移

### 1.1 销毁生命周期 4 轮 codex 失败作为证据

SPEC #440（实体销毁生命周期）连续 4 轮 codex REJECT 没有收敛。每轮处理的是同一个结构缺口的不同侧面：

- **r1 REJECT — 原子性：** 7 步销毁级联（撤销 caps → 解绑外部 mirror → 终止子 agent → 退出 session → 解链 lineage → 终止 Kind 进程 → 写销毁审计行）在当前 Kind=GenServer 模型下无法原子。每一步是对不同 Kind 的独立 `Invocation.dispatch/1`；若第 4 步抛错（目标 Kind 半途崩溃），1-3 步已提交，且没有事务回滚原语。方案：每父 URI 的 "destroy_lock" GenServer 串行化并发销毁。Codex 标记：lock 给的是串行化、不是原子性；部分失败窗口仍在。
- **r2 REJECT — 篱笆 / saga：** 提出「destroy fence」机制 — 一个 sweeper 反复重跑步骤直到幂等。Codex 标记：sweeper 要求每一步 invoke handler 可重入幂等；把这个特性回填到 11 个现有 behavior 是另一个 SPEC；且 sweeper 的进度本身就是一个工作流、要自己的状态机。
- **r3 REJECT — 销毁作为状态标志：** 提出在每个 Kind 的 slice 上加 `:destroyed_at` 列，派发时拒绝对墓碑化 Kind 的调用。Codex 标记：墓碑是软删除；需求是硬删除 + cap 反解 + 审计；墓碑让死 URI 永远泄露、且不解决级联。
- **r4 REJECT — destroy_log 表：** 提出旁路表记录级联进度 + boot 时的 reconciler 续跑被打断的销毁。Codex 标记：**这就是事件溯源，做得很糙**。`destroy_log` 表是手卷的 append-only 事件流；reconciler 是手卷的 Process Manager；我们在一张张临时表里重造 Commanded 的内部原语。

**Codex r4 verdict（原文引用）：** *"destroy_log 这条路就是没有框架的事件溯源。你想解决的每一个问题 — 多 aggregate 原子操作、半途失败续跑、审计追溯不变式 — 都是 Commanded 设计的目标。本 SPEC 不断零碎地重造 Commanded 的内部。退一步：你需要保留 GenServer+slice 模型，还是这里已经触及架构天花板？"*

那段 codex 评语是 **本 SPEC 的直接成因**。在当前模型下原子销毁问题无解。CQRS/ES 模型有结构原语 — Aggregate 自带事件回放的状态、Process Manager 编排多 aggregate 工作流并内建补偿、EventStore 追加即审计日志、snapshot 是缓存而非真值 — 全部 4 类阻塞 codex 标记的问题不靠重造就能解决。

### 1.2 更大的类 — 每个多-Kind 工作流都撞这堵墙

销毁是最尖锐的实例，但同一模式反复出现：

- **`BootReconciler`**（Phase 3 PR-EM-9，external-mirror-domain SPEC §3.1）— 应用 boot 时扫描 `external_mirror_bindings` 投影表、为每个持久化 binding 重新拉起 Worker。Reconciler 是手卷的扫-起循环，与 Session boot 之间存在竞态（Worker `post_init/2` 可能先于目标 Session 进入 `:ready` 而跑，需要 `PendingDelivery` 的 buffer + 重试层）。在 CQRS/ES 下，「binding X 存在则 Worker for X 存在」是一个订阅 `BindingCreated` 事件、派发 `SpawnWorker` 命令的 saga。无 boot 扫描；无竞态；saga 状态机编码顺序。
- **`SpawnRegistry` race 类**（Phase 2-3 事故复盘）— 同一 URI 的并发 `Kind.spawn/2` 在 `DynamicSupervisor.start_child` 上竞速，调用者幂等地处理 `{:error, {:already_started, pid}}`，但**第二个调用者的 `init_slice/1` args 静默丢失**（第一次胜出）。在 CQRS/ES 下，「这个 aggregate ID 上的第一条命令负责创建它」是原语 — 在创建命令落到之前 aggregate 不存在；后续创建命令确定性地以 `{:error, :already_created}` 失败；aggregate 状态从第一次创建的事件构建，与哪个进程发起无关。
- **能力授予时检查的歧义**（PR-CC-2 / caps-cleanup-v1 SPEC）— `Behavior.Identity.grant_cap` 必须验证授予者在**授予的那一刻**持有底层 owner cap，但 caps 是 slice、每次授予都会变 — 这检查是对授予者自己 slice 的 read-after-write。当前模型靠同步 `GenServer.call` 顺序（`Kind.Server.handle_call` per-instance 串行化）解决。在 CQRS/ES 下，授予者在授予时刻的 caps 可从授予者 Aggregate 在 grant 命令应用瞬间的事件回放状态中推导；命令的 `execute/2` 读 aggregate 状态、原子地发射 `CapGranted` 事件（aggregate 级别的串行化给同样性质；并且持久于事件流，所以 "在授予 X 时这个授予者持有哪些 caps" 的审计查询变成事件流过滤、而非取证式 snapshot 读）。
- **Workspace cap-vis 5 轮迭代**（`2026-05-27-workspace-cap-based-visibility.md`）— 5 轮 codex REJECT，主要在策略 helper 放哪 + admin-bypass 边角。cap-vis SPEC 本身直白（`list_workspaces_for(caller, caps)`）；轮次都耗在 "helper 住哪"、"helper 是否匹配 cross-workspace 运行时语义"、"helper 是否覆盖 wildcard cap 路径"、"system-membership 谓词归 Identity 还是 Capability"。在 CQRS/ES 下，「caller 的 workspace 可见性」是对 `workspace_visibility_per_caller` 投影的读模型查询 — 投影在投影时把策略集中到一处；LV 读时的查询是 `SELECT workspace_uri FROM ... WHERE caller_uri = ?`。策略迭代发生在投影里、而非每个读处；读处不会与策略漂移。

主线：**每个多-Kind 工作流暴露当前模型里缺失的原语 — 跨-Kind 原子操作、saga 确定性续跑、可查询的历史状态、单点策略投影。** CQRS/ES 把每条提供为框架特性。当前模型每个 SPEC 都临时重造一个；每次临时重造花 3-5 轮 codex。

### 1.3 诊断 — 当前架构有 CRUD 但没有事件日志

当前 ezagent 状态模型结构上是：

```
外部请求 (LV / CLI / Feishu / MCP / HTTP)
  → Adapter 构造 %Invocation{}
  → Invocation.dispatch/1
    → Idempotency check (step 1)
    → ReadyGate gate (step 4)
    → Kind.Runtime.handle_dispatch (steps 5-10):
      - BehaviorRegistry lookup
      - CapBAC step 5.5
      - Workspace isolation step 5.6
      - Behavior.invoke/4 — 返回 {:ok, new_slice} | {:ok, new_slice, result}
      - Kind.Server 把 new_slice merge 进 state.state[slice_key]
      - 持久化写（若 :on_change 且变了）
      - Telemetry emit
    → reply/2 把结果发回调用者
```

状态变更**形状是 CRUD**：每个 `Behavior.invoke/4` 是 `(slice, args) -> new_slice` 的函数。没有正式的 command/event 切分。审计日志（`invocations` 表）是 telemetry handler 写出来的 `(caller, target, action, result)` 元组旁路记录 — 它**不是**真值（真值是 slice/snapshot）。跨-Kind 工作流是在调用者代码里命令式串起来的多次 `Invocation.dispatch/1`（例如 `EzagentDomainChat.create_session/3` 用 try/rescue 编排了跨 4 个 Kind 的 5 次派发，每步手工清理）。

这种形状留给我们的是：
- **没有正式命令** — `Behavior.invoke/4` 的 `args` 就是个 map；没有 Command struct、没有 router、没有命令的集中目录。
- **没有正式事件** — `Behavior.invoke/4` 的返回是新 slice + 可选结果；slice 变更未具名、不耐久、不可订阅。
- **没有 saga 原语** — 多-Kind 编排是命令式调用者代码 + 手工 try/rescue 清理；部分失败补偿是 ad-hoc per-callsite。
- **没有回放** — 重启时只恢复最新 snapshot；snapshot 之间的历史丢失（审计表是旁路、不可回放进 Kind 状态）。
- **没有订阅** — LV 通过 `Kind.get_slice/2`（同步 `GenServer.call`）直接读 slice；要响应 slice 变更，LV 要么轮询、要么依赖 Behavior 代码里手动的 `Phoenix.PubSub` 广播（如 `Behavior.Chat` 广播 `:message_appended`）。每条广播是 per-Behavior opt-in；没有自动事件流。

### 1.4 假设 — CQRS/ES 在结构上提供缺失的原语

Commanded + EventStore 提供：
- **Command** 作为 struct，通过带 `:identify` 子句的 router 按 aggregate UUID 路由派发。目录是 router 配置。
- **Event** 作为 struct，由 `Aggregate.execute/2` 发射，**先**持久化到事件流、**再** `Aggregate.apply/2` 改内存状态。审计是事件流。
- **Aggregate** 作为进程，由事件回放（+ 可选每 N 事件 snapshot）恢复。状态**派生**自事件。
- **Process Manager (Saga)** 作为有状态事件订阅者，依事件发射命令。多-aggregate 工作流是显式的 + 可续跑的 + 可补偿的。
- **Projection** 作为事件订阅的读模型更新器（用 `commanded_ecto_projections` 走 Ecto）。LV 读投影表；投影器从事件更新它。读模型解耦内建。
- **一致性模式** — `dispatch(cmd, consistency: :strong)` 阻塞直到强一致投影追上；`:eventual` 立刻返回。Read-after-write 问题是派发时的 flag，不是手卷等待循环。

§1.2 的每一条都化解为框架原语。迁移成本是真的（§6 的阶段计划），但**不**迁移的复发成本是每个触及多-Kind 工作流的 SPEC 3-5 轮 codex — 而我们每周都有一两个这样的 SPEC。

---

## 2. 决策 — 采用 Commanded + EventStore 作为主状态模型

### 2.1 采纳的组件

| 组件 | 库 | 角色 |
|---|---|---|
| `Commanded.Application` | `commanded` | per-deployment 派发 + aggregate 承载边界 |
| `Commanded.Commands.Router` | `commanded` | Command → Aggregate 通过 `:identify` 路由 |
| `Commanded.Aggregates.Aggregate` | `commanded` | 替代 `Ezagent.Kind` 的 GenServer 模式的 behaviour |
| `Commanded.ProcessManagers.ProcessManager` | `commanded` | 多 aggregate 工作流（销毁级联等的新家） |
| `Commanded.Event.Handler` | `commanded` | 非投影的事件订阅者（如把事件镜像到外部系统、发后续命令但无状态 — 当状态机过重时的 process manager 简化版） |
| `Commanded.Projections.Ecto` | `commanded_ecto_projections` | 用 Ecto.Multi 在事件上更新表的读模型投影器 |
| `EventStore` | `eventstore` | Postgres-backed 的事件持久化 |
| `Commanded.EventStore.Adapters.EventStore` | `commanded_eventstore_adapter` | 把 `commanded` 接到 `eventstore` 的 adapter |
| `Commanded.EventStore.Adapters.InMemory` | 内置 | test / dev 循环用的事件存储 |

### 2.2 暂不采纳的

- **EventStoreDB**（独立 Erlang/Scala 事件存储，走 `commanded_extreme_adapter`）— 比 Postgres + `eventstore` 库运维更重，目前规模无集群需求。Postgres 运维普及；EventStoreDB 小众。（§7.4 + §10 OQ-1 讨论。）
- **EventStoreDB 上的 snapshot 存储** — 我们用 Commanded 内建的 snapshot-every-N，存在同一个 Postgres `eventstore` schema。每 Kind 迁移时现有 `kind_snapshots` SQLite 表退役。
- **多 app Commanded 拓扑**（每个 bounded context 一个 `Commanded.Application` + 跨 app 事件桥）— 对 5-Kind 模型过度；我们跑**一个** `Ezagent.CommandedApp`，含所有 aggregate + 所有 process manager + 所有投影器。规模需要时再分拆是 Phase N+1 的事。

### 2.3 不变的（外部 API 面）

- Phoenix.Channel 的 `handle_in/3` 回调。当前构造 `%Invocation{}` 调 `Invocation.dispatch/1`；迁移后构造 `%Cmd{}` 调 `Ezagent.CommandedApp.dispatch/2`。从 JS 客户端看 channel topic、消息形状、响应形状不变。
- LiveView `mount/3` + `handle_event/3`。同样的改动：派发 Command 替代 Invocation。读从投影查询替代 `Kind.get_slice/2`（§5）。
- CLI `mix ezagent.*` 任务。同样的派发改动。读自投影表。
- HTTP plug 控制器（如 `EzagentWeb.SessionController.create`）。同样。
- 基于 URI 的寻址模型。Aggregate UUID **就是** 规范化的 URI 字符串；不引入新的寻址方案。
- 能力语义。Cap struct + 匹配器不变。检查从 `Kind.Runtime` 步骤 5.5 移到派发前流水线（§4.5）。
- 对插件作者可见的 Behavior 合约面在**语义上**保留 — 他们声明一个 Kind（现在是 Aggregate）、状态（现在事件派生）、actions（现在 commands）、invoke 逻辑（现在 `execute/2` 返回事件 + `apply/2` 返回新状态）。接口语法不同，但心智模型保留（§4.2 逐回调映射）。

### 2.4 必须变的（内部）

- `Ezagent.Kind.Server` 每 Kind 迁移完即退役。共享 GenServer 被 Commanded `AggregateRegistry` 管理的 `Commanded.Aggregates.Aggregate` 进程取代。
- `Ezagent.Kind.Snapshot` 每 Kind 迁移完即退役。Commanded snapshot 存储（Postgres-backed，由 `snapshot_every:` 配置）取代它。
- `Ezagent.Audit.Writer`（`invocations` SQLite 表）对领域事件路径退役；事件流**就是**审计日志。非领域 telemetry（被否决的 authz、持久化失败、跨切 boot/teardown）保留在 SQLite audit 表（§4.7）。
- `Ezagent.Invocation.dispatch/1` 作为公共派发入口退役。由 `Ezagent.CommandedApp.dispatch/2` 取代。12 步流变为 5 步派发前流水线 + Commanded 的 aggregate 承载（§4.5）。
- `Ezagent.KindRegistry` 每 Kind 迁移完即退役。Aggregate 查找由 Commanded 内部处理；跨-Kind 引用走事件 + saga、不走 registry。
- `Ezagent.SpawnRegistry` 每 Kind 迁移完即退役。「Spawn」变成「aggregate ID 上的第一条命令创建它」— aggregate 在创建命令应用前不存在；后续创建命令确定性地失败。
- `Ezagent.PendingDelivery` Phase 10-A 后退役（not-yet-ready buffer 模式）。Aggregate 没有同样意义的 `:not_ready` 状态 — 它要么已创建（历史非空）、要么未创建（历史空）；对未创建 aggregate 的派发要么创建（按 `execute/2` 对空状态的子句）、要么以「未创建」错误失败。
- `Ezagent.Persistence.scope_by_workspace/2` 和 `workspace_uri_for/1` 保留 — 现在用在**投影**表上、而非 slice 写。workspace 隔离不变式在投影器 + 读查询里强制。

### 2.5 决策边界 — 本 SPEC 承诺什么、不承诺什么

本 SPEC **承诺**：
- 采纳 Commanded + EventStore 作为未来的状态模型。
- §6 的 4 阶段迁移计划（Phase 10-A 到 10-D），每个阶段边界有显式 unwind。
- §4.4 当前 Kind → Aggregate 的映射表 + §4.4.2 的跨-Kind 工作流清单（定义迁移后存在哪些 Process Manager）。
- Dev 循环故事（fast tests 用 in-memory adapter；dev + prod 用 Postgres）。见 §7.3。
- §4.7 审计分解 — 领域事件走事件存储、纯 telemetry 留 SQLite。

本 SPEC **不**承诺：
- 每个 Aggregate 的精确事件 schema（每 Aggregate impl SPEC 在 Phase 10-B 到 10-D）。
- 每个 read-model 的精确投影表形状（impl-time per phase 决定）。
- Process Manager 是跑在 Commanded Application 内部还是 sibling supervisor（§10 OQ-5）。
- Per-Aggregate snapshot-every-N 调参（默认 = 50，benchmark 证明时 per-Aggregate 覆盖）。
- 任何命令的精确 CLI / LV 表单变化（per `IMPLEMENTATION_ROADMAP.md` §1.4 现有的 CLI ↔ LV 同构不变式；迁移后保留，具体绑定细节在实施 PR）。

---

## 3. Phoenix + Commanded 混合集成 — 关键研究问题

这是 Allen 明确指明深挖的章节。集成**不**新颖（§3.6 列出生产参考），但模式很微妙。整个 CQRS 的要点是写路径（命令派发到 aggregate、事件持久化）与读路径（投影查询）的不对称。LiveView 和 Phoenix.Channel 同时坐在**两**条路径上。本节枚举每种交互。

### 3.1 "Phoenix 在边、Commanded 在核" 模式

跨 Conduit、gift-card-demo、segment-challenge、Honeydew 的标准模式：

```
                       ┌─────────────────────────────┐
                       │  外部传输                    │
                       │  (HTTP / WS / LV / CLI / MCP)│
                       └──────────────┬──────────────┘
                                      │
                                      ▼  (构造 %Cmd{})
                       ┌─────────────────────────────┐
                       │  派发前流水线                │
                       │  - authn (已存在)            │
                       │  - authz (CapBAC step 5.5)   │
                       │  - workspace 隔离 5.6        │
                       │  - 幂等性检查                │
                       │  - URI 规范化                │
                       └──────────────┬──────────────┘
                                      │
                                      ▼  Ezagent.CommandedApp.dispatch(cmd, opts)
                       ┌─────────────────────────────┐
                       │  COMMANDED.APPLICATION       │
                       │  Router → 按 id :identify    │
                       └──────────────┬──────────────┘
                                      │
                                      ▼
                       ┌─────────────────────────────┐
                       │  AGGREGATE                   │
                       │  execute(state, cmd)         │
                       │   → [event(s)] | error       │
                       │  apply(state, event)         │
                       │   → new_state                │
                       └──────────────┬──────────────┘
                                      │
                                      ▼  事件追加到事件存储
                       ┌─────────────────────────────┐
                       │  事件存储 (Postgres)         │
                       └──────────────┬──────────────┘
                                      │
                ┌─────────────────────┼─────────────────────┐
                │                     │                     │
                ▼                     ▼                     ▼
        ┌──────────────┐    ┌──────────────┐      ┌──────────────┐
        │ 投影器       │    │ Process Mgr  │      │ Handler      │
        │ Ecto.Multi   │    │ saga 状态 +  │      │ 副作用       │
        │ 更新读表     │    │ 发命令       │      │ (通知、扇出) │
        └──────┬───────┘    └──────┬───────┘      └──────────────┘
               │                   │
               ▼                   ▼
       ┌─────────────┐     ┌─────────────┐
       │  LV / API   │     │  Aggregate  │
       │  读读表     │     │  (后续命令) │
       └─────────────┘     └─────────────┘
```

Phoenix.Channel 和 LiveView 坐在顶（写侧，构造命令）和底（读侧，查投影）。Commanded 拥有中间。插件作者写命令、事件、aggregate、投影器、process manager — 永远不直接碰事件存储。

### 3.2 LiveView 写路径 — handle_event/3 → dispatch

参考自 `gift-card-demo/lib/gift_card_demo/gift_cards.ex`：

```elixir
defmodule GiftCardDemo.GiftCards do
  alias GiftCardDemo.AppRouter
  alias GiftCardDemo.GiftCard.Commands.{IssueGiftCard, RedeemGiftCard}

  def issue_gift_card(amount) do
    command = %IssueGiftCard{id: UUID.uuid4(), amount: amount}
    AppRouter.dispatch(command)
  end

  def redeem_gift_card(id, amount) do
    command = %RedeemGiftCard{id: id, amount: amount}
    AppRouter.dispatch(command)
  end
end
```

LV `handle_event/3` 调 `GiftCards.issue_gift_card(amount)`。函数构造 Command struct 并派发。不直接访问 EventStore；不手动发事件；aggregate 的 `execute/2` 决定发什么事件。

**对 ezagent**，等价的 context 模块是 per-Domain 的（每个 `apps/ezagent_domain_*` 一个）— `Ezagent.Domain.Chat.create_session(...)`、`Ezagent.Domain.Identity.grant_cap(...)` 等。每个 context 函数：
1. 构造 `%Cmd{}` struct，aggregate 的规范化 URI 作为 `:id`。
2. 用 `opts`（依调用者意图决定 — `consistency: :strong` 用于 read-after-write 路径；其它 `:eventual` — 见 §3.3）调 `Ezagent.CommandedApp.dispatch(cmd, opts)`。
3. 返回 `:ok` / `{:error, reason}`。

派发前流水线（§4.5）包住 `Ezagent.CommandedApp.dispatch/2`，让 authz、workspace 隔离、幂等性、URI 规范化在边界处发生**一次**，而不是每个 domain context 函数里。

### 3.3 Read-after-write 一致性 — 关键问题

当 LV `handle_event` 派发命令然后 re-render，re-render 能看到新状态吗？

**Commanded 支持三种模式：**

**(a) `consistency: :eventual`（默认）。** 事件持久化后 dispatch 即返回 `:ok`。投影器异步跑。LV 在 dispatch 返回时立刻 re-render — 但投影表可能尚未反映变化。下一次来自 PubSub 或投影器 `after_update/3` 的推送触发后续 render，带新状态。UX：短暂的过期读；用户在典型 1-10ms 投影器延迟内看到变化。

**(b) `consistency: :strong`。** Dispatch 阻塞直到**所有**标 `consistency: :strong` 的投影器都提交完。LV 在 dispatch 后的 re-render 同步看到新状态。代价：dispatch 延迟 = 事件追加（5-50ms）+ 最慢强一致投影器提交（典型再 5-20ms）。扇到多个强一致投影器时，上界是其中最大值。（[hexdocs Commands.md](https://hexdocs.pm/commanded/Commanded.Commands.Router.html)）

**(c) `consistency: [ProjectorA, ProjectorB]`。** 阻塞直到具名投影器追上。折中：只对喂这个 LV 的投影器同步等待、其它异步。

**ezagent 的选择 — per 派发点，默认 `:eventual`，opt-in `:strong`：**

`Ezagent.CommandedApp.dispatch/2` 的默认是 `consistency: :eventual`，因为大多数派发（chat 发送、纯审计写、扇出式变更）派发点不需要 read-after-write。派发点 opt-in `:strong`（或具名投影器列表）的场景：

- 同一个 LV render 回读它刚更新的投影（如 create_session → 向导跳转到 /sessions/X 并 render session detail — detail 投影必须就位）。
- CLI 命令把结果状态打到 stdout（确定性 CLI 返回）。
- 控制器响应 201 并返回创建资源的投影状态。

opt-in 机制在派发点显式：`Ezagent.CommandedApp.dispatch(cmd, consistency: :strong)`。默认 `:eventual` 让热路径快；LV/PubSub 模式（3.4）让 eventual 几乎对用户不可见。

**Process Manager 发出的命令永远用 `:eventual`** — saga 自己是事件订阅者，等它派发后续命令时原事件已经持久化；让 saga 内部各步在强一致上阻塞会与 saga 自己的事件订阅死锁。

### 3.4 LiveView 读路径 — 订阅投影、不订阅事件

参考自 gift-card-demo：

```elixir
defmodule GiftCardDemoWeb.GiftCardSummaryLive do
  use Phoenix.LiveView
  alias GiftCardDemo.GiftCards

  def mount(_session, socket) do
    if connected?(socket), do: GiftCards.subscribe()
    {:ok, fetch(socket)}
  end

  def handle_info({:gift_card_summary, %GiftCardSummary{}}, socket) do
    {:noreply, fetch(socket)}
  end

  defp fetch(socket) do
    assign(socket, gift_cards: GiftCards.list_gift_cards())
  end
end
```

投影器里：

```elixir
project %GiftCardIssued{...} = event, fn multi -> ... end

def after_update(_event, _metadata, %{gift_card_summary: summary}) do
  Registry.dispatch(Registry.GiftCardSummary, :gift_card_summary, fn entries ->
    for {pid, _} <- entries, do: send(pid, {:gift_card_summary, summary})
  end)
end
```

**流：**
1. LV `mount/3` 订阅 per-投影 Registry topic。
2. LV 初次 render 直接读投影表（同步 DB 查询）。
3. 投影器的 `after_update/3` 回调（`commanded_ecto_projections` 钩子）把更新行扇出给所有订阅者。
4. LV `handle_info` 重读 + re-render。

**对 ezagent**，把 `Registry` 换成 `Phoenix.PubSub`（代码库里已用；统一 topic 命名）。Per-Aggregate-class 投影器定义 topic 如 `"ezagent:projections:user:#{user_uri}"` 并在 `after_update/3` 广播。LV 在 mount 时订阅。

跨 5 个 Kind 模式对称 — User、Session、Agent、Workspace、Worker，每个都有投影器 + PubSub topic；LV 按它 render 的 URI 订阅。

**冷加载问题。** LV mount 时投影还没追上最新事件（一个竞态窗口：LV mount 与投影器订阅并行），初次 render 显示过期状态。两个方案：

- **`Commanded.Subscriptions.wait_for/3`** — LV mount 在特定 aggregate UUID + version 上阻塞，直到投影器追上。比标准模式稍同步，但消除 LV 紧贴 dispatch 后 mount 的过期窗口（如向导 redirect-then-mount）。
- **Dispatch-then-mount-with-aggregate-version** — 派发代码把 dispatch 结果的 `:aggregate_version` 通过 redirect URL 或 session 透传；LV mount 等到**那个**特定 version 再 render。这是 gift-card-demo 的扩展模式。

对 ezagent，标准 LV 模式是 redirect 前的 dispatch 用 `consistency: :strong`；目标 LV 在 dispatch 返回后 mount，所以投影在 mount 时一定已追上。wait_for/3 helper 作为跨 tab 竞态（tab 2 在 tab 1 dispatching 时打开详情页）的 fallback。

### 3.5 Phoenix.Channel 写路径（CLI、agent_bridge、feishu）

Phoenix.Channel `handle_in/3` 结构上与 LV `handle_event/3` 相同 — 构造命令并派发。区别仅在回复机制：

- **LV** — re-render 由 `assign/2` 自动触发；用户在 HTML 里看到结果。
- **Channel** — `handle_in/3` 返回 `{:reply, {:ok, payload}, socket}`，JS 客户端（cli、agent_bridge）收回复。dispatch 结果（典型 `:ok` 或 `{:ok, %ExecutionResult{}}`）被序列化到 channel payload。

对需要把数据返回给调用者的命令（如 CLI `mix ezagent.user.token --mint` 打出铸的 token）：
- dispatch 用 `consistency: :strong`（这样 token 在读模型里）。
- dispatch 返回后派发点立刻查读模型。
- dispatch 结果 + 读模型行一起返回给 channel。

Commanded 没有 `Behavior.invoke/4` 那种「返回值在事件里」的模式 — 事件是过去事实，不是返回值。若调用者需要返回值，返回值在 dispatch **之后**从读模型派生。

### 3.6 生产参考

| 项目 | 技术栈 | 备注 | URL |
|---|---|---|---|
| **Conduit** | Phoenix + Commanded | RealWorld 示例 app（Medium 克隆）；成熟；演示 router、aggregate、投影器、process manager、Phoenix view | https://github.com/slashdotdash/conduit |
| **Gift-card-demo** | Phoenix LiveView + Commanded | 更小、LV 重点；演示 projection-via-Registry 模式 + `after_update/3` 钩子 | https://github.com/slashdotdash/gift-card-demo |
| **Segment Challenge** | Phoenix + Commanded | Strava 赛事的生产 app；更大规模的 aggregate 清单 | https://github.com/slashdotdash/segment-challenge |
| **Honeydew** | Phoenix LiveView + Commanded + Postgres（"CELP 栈"）| 入门模板；演示标准接线 | https://github.com/quarterpi/honeydew |
| **Casavo（medium post）** | 生产公司 | 用 Commanded + LiveView 在事件存储顶上做监控/调试工具；演示「LiveView 作为事件存储观察者」模式（我们会用同样模式做 `/admin/events`） | https://medium.com/casavo/supercharging-our-event-sourcing-capabilities-with-phoenix-liveview-c4a9d1d4ab99 |
| **ElixirMerge 指南** | walkthrough | EventStoreDB + Phoenix + LiveView CQRS/ES 指南 | https://elixirmerge.com/p/comprehensive-guide-to-implementing-es-cqrs-with-eventstoredb-phoenix-and-liveview |
| **Cantido 博文** | Phoenix LV 事件溯源 | LV 订阅 `$all` 事件流 + push_event 给 JS hook 做高频 render | https://dev.to/cantido/phoenix-liveview-but-event-sourced |
| **Christian Alexander 博文** | Phoenix API + Commanded | Read-after-write 强一致模式 walkthrough | https://christianalexander.com/2022/05/09/elixir-commanded/ |

**成熟度判定：** 集成已建立；参考 app 存在；社区 Q&A 在 ElixirForum 可追溯到 2018。**不**是开创性的。「Phoenix 在边、Commanded 在核」模式是事实标准。ezagent 落在已有用例的舒适区。

### 3.7 失败模式 — 可能哪里出错

| 失败 | 原因 | 恢复 | SPEC §引用 |
|---|---|---|---|
| **Aggregate 进程回放中崩溃** | 流里有损坏事件**或** `apply/2` 有 bug 导致重建抛错 | Commanded `AggregateRegistry` 重启 aggregate；回放从最近 snapshot 续。若 bug 在 `apply/2`，崩溃循环到代码修好。约束：每 N 事件 snapshot 限制回放范围，代码修好后立即恢复（回放从 snapshot 起、不从事件 0 起）。 | §4.4 + §6 Phase 10-A |
| **EventStore Postgres 宕机** | DB 挂 | `dispatch/2` 返回 `{:error, _}`。调用者按 transient failure 处理（重试策略）。内存中 aggregate 状态存活；Postgres 恢复时派发恢复。Sagas 暂停（订阅停收事件）；恢复后从最后处理事件续跑。 | §7.4 + §8 |
| **Saga 部分失败** | Process Manager 的 `handle/2` 返回了目标 aggregate 拒绝的命令 | Saga 的 `error/3` 决定：带退避重试、补偿（派发逆向命令）、跳过续跑、停止。补偿逻辑是 saga 里的显式代码；没有框架自动回滚。 | §3.8 销毁级联专门 |
| **现存 aggregate 加新事件类型** | 代码加了 aggregate 现在发的新事件 variant | `apply/2` **必须**有该新事件的子句。Aggregate 等价的 `behaviors/0` 列表（aggregate 模块本身）是真值；新事件也加到投影器的 `project` 子句。 | §10 OQ-3 + §11 q#6 — 事件 schema 演进 |
| **旧事件类型移除** | 代码停止发某类历史流里有的事件 | `apply/2` **仍**必须有该历史事件的子句（回放需要）。该子句若字段不再相关可为 no-op；事件**本身**不从历史里删。 | §10 OQ-3 |
| **现存事件加字段** | 需要给 `MessagesPosted` 事件加 `caller_metadata` | `Commanded.Event.Upcaster` impl 在事件读时跑，把旧事件变成新形状后再喂 `apply/2`。历史事件磁盘字节不动；内存形状被升级。 | §10 OQ-3 |
| **投影偏离 aggregate** | 投影器有 bug，写错列 | 从事件流重建：停投影器 → 截断投影表 → 重启投影器并 `start_from: :origin`。代价：O(events) 回放；aggregate snapshot 由 `snapshot_every` 限界、投影回放无此限（投影回放读全流）。对我们规模是分钟、不是小时。 | §7.4 + §8 |
| **热 aggregate 10K+ 事件** | 重用的 Session 在生命周期内累 10K MessagesPosted | snapshot_every: 50 把冷启动回放限到 ≤50 事件；热 aggregate 留内存。最坏回放 = ~50 事件 × `apply/2` 延迟（每事件 μs 级）≈ 1ms。 | §7.2 |
| **两个写者同 aggregate 竞速** | 并发的 LV + CLI 派发同 aggregate UUID 的命令 | Commanded 在 aggregate 级串行化（per-UUID 一个进程）；第二条命令在第一条后面排队。只有显式设 `expected_version` 才报乐观并发错（ezagent 不设 — 接受隐式串行）。 | §4.5 |
| **事件存储 schema 破坏变更** | Commanded major 版本升级引入事件存储表变更 | 升级迁移在 Postgres 跑；事件**不**重写（事件 payload 是 JSON、schema 灵活）；只周围 metadata 列变。每次升级前读 [commanded changelog](https://hexdocs.pm/commanded/changelog.html)。 | §7.4 |

### 3.8 销毁级联的 saga 补偿模式（最初的触发）

来自 SPEC #440 的销毁级联，表达为 Process Manager：

```elixir
defmodule Ezagent.Saga.DestroyAgentSaga do
  use Commanded.ProcessManagers.ProcessManager,
    application: Ezagent.CommandedApp,
    name: "DestroyAgentSaga"

  defstruct [:agent_uri, :workspace_uri, :step, :caps_revoked, :children_destroyed]

  # 在 AgentDestroyRequested 事件上启动（Agent aggregate 接收 Destroy 命令时发出）。
  def interested?(%AgentDestroyRequested{agent_uri: uri}), do: {:start, uri}

  # 对 saga 发的命令的后续事件继续。
  def interested?(%AgentCapsRevoked{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentChildrenDestroyed{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentMembershipsDropped{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentLineageUnlinked{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentTerminated{agent_uri: uri}), do: {:stop, uri}

  # 步骤 1：撤销该 agent 持有的所有 cap。
  def handle(%__MODULE__{step: nil}, %AgentDestroyRequested{} = ev) do
    %RevokeAllCapsHeldBy{agent_uri: ev.agent_uri}
  end

  # 步骤 2：cap 撤完，销毁子 agent（lineage 级联）。
  def handle(%__MODULE__{step: :caps_revoked} = pm, %AgentCapsRevoked{}) do
    case Ezagent.Projection.AgentLineage.children_of(pm.agent_uri) do
      [] -> %SkipChildrenDestruction{agent_uri: pm.agent_uri}
      children -> %DestroyChildAgents{agent_uri: pm.agent_uri, children: children}
    end
  end

  # 步骤 3：退出所有 session。
  def handle(%__MODULE__{step: :children_destroyed} = pm, %AgentChildrenDestroyed{}) do
    %DropAllSessionMembershipsFor{agent_uri: pm.agent_uri}
  end

  # 步骤 4：解链 lineage。
  def handle(%__MODULE__{step: :memberships_dropped} = pm, %AgentMembershipsDropped{}) do
    %UnlinkLineage{agent_uri: pm.agent_uri}
  end

  # 步骤 5：终止 aggregate（最终）。
  def handle(%__MODULE__{step: :lineage_unlinked} = pm, %AgentLineageUnlinked{}) do
    %TerminateAgent{agent_uri: pm.agent_uri}
  end

  # 状态机 — 跟踪步骤推进。
  def apply(%__MODULE__{} = pm, %AgentDestroyRequested{} = ev),
    do: %{pm | agent_uri: ev.agent_uri, workspace_uri: ev.workspace_uri, step: :requested}

  def apply(pm, %AgentCapsRevoked{}), do: %{pm | step: :caps_revoked, caps_revoked: true}
  def apply(pm, %AgentChildrenDestroyed{}), do: %{pm | step: :children_destroyed, children_destroyed: true}
  def apply(pm, %AgentMembershipsDropped{}), do: %{pm | step: :memberships_dropped}
  def apply(pm, %AgentLineageUnlinked{}), do: %{pm | step: :lineage_unlinked}

  # 错误 / 补偿。
  def error({:error, :agent_not_found}, _cmd, _ctx) do
    # 到步骤 5 时 agent aggregate 不存在 — 级联已经走过另一路径销毁了 — 幂等。
    {:skip, :discard_pending}
  end

  def error({:error, _failure}, _cmd, %{context: %{retries: n}}) when n >= 3 do
    # 同一步三次失败 — 停下要求运维介入。Saga 状态持久；运维可检查 + 续跑。
    {:stop, :too_many_failures}
  end

  def error({:error, _failure}, _cmd, %{context: ctx}) do
    {:retry, 1_000, Map.update(ctx, :retries, 1, &(&1 + 1))}
  end
end
```

**与 SPEC #440 destroy_log 表方案的对比：**

| SPEC #440 r4 (destroy_log 表) | 本 SPEC (DestroyAgentSaga) |
|---|---|
| 手卷的 append-only 旁路表 | 事件流（已经定义就是 append-only） |
| 手卷的 boot 时续跑 reconciler | Saga 订阅自动从最后处理事件续跑 |
| 每个 behavior 手卷「这一步是否幂等」纪律 | 每一步是对特定 aggregate 的命令；aggregate 自己处理幂等（重复销毁返回 `{:error, :already_destroyed}`） |
| 手卷的部分失败补偿 | `error/3` 回调 + `{:retry, ...}` / `{:stop, ...}` 框架原语 |
| 手卷的「销毁级联推进到第 N 步」审计行 | 每一步发领域事件；saga 状态**就是**级联审计 |

销毁级联变成 ~100 行 saga 代码 + per-aggregate 命令/事件 variant。框架拥有「原子」性质（步骤边界处原子、步骤间显式补偿）。

### 3.9 Phoenix 集成专门的开放问题

冒上 §11 codex 评审：

- 我们 LV 代码用 `assign_new/3` 和 per-tab session state 够多吗，足以把读路径改成投影驱动？（够 — 当前 LV 已经把 `Kind.get_slice/2` 包在 `assign/2`，替换是机械的。）
- 我们有任何代码路径在某个 Kind 的 `Behavior.invoke/4` **内部**读**另一个** Kind 的 slice 吗（派发内跨 Kind 读）？（有 — `Behavior.Identity.check_grant_authorized` 读 owner URI 的 slice。迁移后这必须从投影读、或通过新一次派发查目标 aggregate — 见 §11 q#5。）
- 是否有地方按 SQL 谓词（workspace_uri、时间范围）查询审计表 `invocations` 行？（有 — `/admin/audit` LV。迁移后对领域事件的审计查询变成事件流过滤**或**对 `audit_events` 投影表的查询。§4.7 + §11 q#8。）

---

## 4. 把当前 ezagent 架构映射到 CQRS

### 4.1 概念到概念的映射

| 当前 | 新 | 迁移备注 |
|---|---|---|
| `Ezagent.Kind` behaviour 模块 | 实现 `Commanded.Aggregates.Aggregate` behaviour 的模块 | Kind 模块的 `type_name/0` / `behaviors/0` / `persistence/0` 回调 → aggregate 的 `execute/2` / `apply/2`。`behaviors/0`（Kind 组合的 Behavior 列表）由 aggregate per-event `apply/2` 子句编码 — 旧 behaviors 中任何一个发的事件对应一条子句。 |
| `Ezagent.Behavior.X` 模块 + `actions/0` + `invoke/4` | per-Behavior 命名空间的 Command 模块 + Event 模块 + per-Aggregate `execute/2` 子句 | 如 `Behavior.Chat.actions == [:send, :join, :leave]` 变成 `Behavior.Chat.Commands.SendMessage`、`JoinSession`、`LeaveSession` + 对应 `MessagesPosted`、`MemberJoined`、`MemberLeft` 事件。派发把命令路由到 Session aggregate；它有每命令的 `execute/2` 子句。 |
| per-Kind slice 状态（`state.state[behavior.state_slice()]`） | Aggregate state struct | Kind GenServer 的 `state.state` slice 映射变成 aggregate `defstruct` 字段。不再「slice key」 — 每个字段就是 aggregate 上的 struct 字段。 |
| `Ezagent.Kind.Snapshot.save_now/3`（同步 `:on_change`） | Commanded snapshot-every-N（Postgres-backed） | 默认 `snapshot_every: 50` 事件。benchmark 证明时 per-Aggregate 覆盖。替代 `:on_change` 和 `:periodic` 两种策略。`:ephemeral` 变「无 snapshot 配置」（永远事件回放）。`:on_terminate` 变无关（Commanded 中 aggregate 无 terminate 钩子）。 |
| `Ezagent.Persistence` per-workspace 范围（`scope_by_workspace/2`） | 同模块 + 同范围、对投影表 | workspace 隔离不变式从 slice 写移到投影写 + 读查询。函数原样保留；它在 `projections.*` 表上跑而已。 |
| `Ezagent.Invocation.dispatch/1` | `Ezagent.CommandedApp.dispatch/2`（由派发前流水线包裹） | 12 步流折叠（5-10 变 Commanded 内部）；1-4 + 5.5-5.6 + 11-12 保留（现在在派发前流水线 + 投影器触发的 `after_dispatch`）。 |
| `Ezagent.KindRegistry`（URI → pid） | Commanded 内部 aggregate registry | 直接查找（如给 `Kind.get_slice/2`）由投影读替代。`KindRegistry.lookup/1` 的外部调用者迁移后无幸存。 |
| `Ezagent.SpawnRegistry` + `Kind.spawn/2` | 隐式（aggregate ID 上的第一条命令创建它） | 「spawn」动词消失；aggregate 由它的第一条创建命令（`%RegisterUser{}`、`%CreateSession{}` 等）创建。`{:error, {:already_started, pid}}` 竞速变 aggregate `execute/2` 确定性返回的 `{:error, :already_created}`。 |
| 跨-Kind 级联在调用者命令式代码（如 `EzagentDomainChat.create_session/3` 跨 4 Kind 的 5 派发编排） | 订阅源事件的 Process Manager (Saga) | 如 `SessionCreated` 事件触发 `GrantOwnerCapsSaga`，发 `GrantCap` 命令；saga `error/3` 处理补偿。 |
| `Ezagent.Audit.Writer` 写 `invocations` SQLite 表 | 事件流**就是**审计日志（对领域事件） + audit-events 投影做可查子集 | 跨切 telemetry（被否决 authz、持久化失败、cc_bridge 事件）留 SQLite audit；领域事件移事件流 + 可查投影。见 §4.7。 |
| `kind_snapshots` SQLite 表 | Commanded snapshot 存储（在 `eventstore` Postgres schema 中） | 对迁移完的 Kind：现有 snapshot **不**迁移（per `feedback_destructive_migration_anti_pattern`）；迁移后 Aggregate 上的第一条命令创建新鲜的事件溯源状态。混合期间未迁移 Kind 的 snapshot 数据原样不动。 |
| `Ezagent.ReadyGate`（状态 `:ready` / `:not_ready` / `:unknown`） | 隐式（aggregate 存在 ⇔ 命令可派发） | post-init 缓冲的 `:not_ready` 模式变「第一条创建命令必先于其它命令」；后续命令在 aggregate 创建前失败。Buffering（旧 `Ezagent.PendingDelivery`）对迁移 Kind 退役。 |
| `Ezagent.PendingDelivery`（对未 ready Kind 的 cast 缓冲） | 对迁移 Kind 退役 | 对未创建 aggregate 的 cast 命令在派发时失败（`{:error, :aggregate_not_found}` 或 Commanded 对未创建 aggregate cast 的返回 — 见 §11 q#8）。 |
| `Ezagent.Behavior.X.post_init/2` + `handle_continue/3`（Kind register 后的延迟工作） | 订阅 `AggregateCreated` 类事件的 Process Manager | external-mirror-domain SPEC §6.1 的 split-init 模式变成：aggregate 创建命令发 `WorkerCreated`；`WorkerBootstrapSaga` 订阅该事件、派发后续命令（订阅 publisher 等）。 |
| `Ezagent.Kind.Server.handle_call({:ezagent_get_slice, slice_key}, ...)` | 投影表查询 | 跨进程 slice 读变 `Ezagent.Projection.X.get(uri)`。查询走读模型模块；读时不碰 aggregate 进程。 |
| `Ezagent.CapabilityRegistry` + `Ezagent.BehaviorRegistry` | 原样保留 | 编译/启动期注册 cap subject；registry 在派发前流水线被查。无事件溯源相关。 |
| `@behaviour Ezagent.Behavior` + cap_subjects/0 + data_owner/1 | 保留（语义微变）— cap_subjects 表示哪些命令通过 CapBAC 受门控；data_owner 表示哪个 aggregate 拥有底层数据 | 派发前的 CapBAC chokepoint 不变；cap_subject **就是**命令的 behavior + action 轴。data_owner 现在指向 aggregate URI 而非 Kind 的拥有 principal。 |

### 4.1.5 完整 Kind / Behavior 清单（r2 — 静态生成）

r1 说「5 entity Kinds + 11 Behavior modules」— 实际 checkout 枚举：

**耐久 Kind 模块（`{:snapshot, :on_change}` 或 `:on_terminate`）— 全部需迁移目标：**

| Kind 模块 | App | 持久化 | 迁移目标 |
|---|---|---|---|
| `Ezagent.Entity.User` | ezagent_domain_identity | `{:snapshot, :on_change}` | `Ezagent.Aggregate.User`（§4.2.1） |
| `Ezagent.Entity.Session` | ezagent_domain_chat | `{:snapshot, :on_change}` | `Ezagent.Aggregate.Session`（§4.2.3） |
| `Ezagent.Entity.Agent` | ezagent_domain_chat | `{:snapshot, :on_change}` | `Ezagent.Aggregate.Agent`（§4.2.2） |
| `Ezagent.Workspace` | ezagent_domain_workspace | `{:snapshot, :on_change}` | `Ezagent.Aggregate.Workspace`（§4.2.4） |
| `Ezagent.Entity.AgentTemplate` | ezagent_domain_chat | `{:snapshot, :on_change}` | **`Ezagent.Aggregate.AgentTemplate`**（r2 §4.2.6 新加） |
| `Ezagent.Entity.SessionTemplate` | ezagent_domain_chat | `{:snapshot, :on_change}` | **`Ezagent.Aggregate.SessionTemplate`**（r2 §4.2.7 新加） |
| `Ezagent.Entity.ExternalMirrorWorker` | ezagent_domain_external_mirror | `:on_terminate` | `Ezagent.Aggregate.ExternalMirrorWorker`（§4.2.5） |
| `Ezagent.Entity.CurlAgent` | ezagent_plugin_curl_agent | `{:snapshot, :on_change}` | `Aggregate.Agent` 的 flavor 变体 |
| `Ezagent.Entity.Echo` | ezagent_plugin_echo | 视 flavor | `Aggregate.Agent` 的 flavor 变体 |
| `Ezagent.Entity.NpAgent` | ezagent_plugin_np | 视 flavor | `Aggregate.Agent` 的 flavor 变体 |

**Behavior 模块（24 个 — `find apps -path "*/behavior/*.ex"` 静态枚举），含 r1 漏掉的 ApiKeys / Template / OrchestratorAdmin / Pty / UserBinding / FeishuAllow 等 — 完整表见 EN §4.1.5。**

**Phase 门（per `feedback_completion_requires_invariant_test`）：** 每阶段的不变式测试枚举范围内所有 Behavior、断言每个有对应迁移目标（或显式"保留 runtime"决定）。新 `Ezagent.Invariants.NoBehaviorLeftBehindTest` 在 Phase 10-D 合并前走 BehaviorRegistry、若有可派发 Behavior 缺 Aggregate 命令映射则 FAIL。

### 4.2 5 个实体 Kind — 每 Kind 的迁移目标

#### 4.2.1 `Ezagent.Entity.User` → `Ezagent.Aggregate.User`

**当前状态形状（slice）：**
```elixir
%{
  identity: %{caps: MapSet.t(Capability.t())},
  user_credentials: %{...counter state...},
  user_tokens: %{...counter state...}
}
```

**新 aggregate 状态：**
```elixir
defmodule Ezagent.Aggregate.User do
  defstruct [
    :uri,            # 规范化 URI 字符串 — 也是 aggregate ID
    :workspace_uri,
    :registered_at,
    :password_hash,  # mirror users.password_hash 列
    caps: MapSet.new(),
    tokens: %{},     # token_id → %{minted_at, expires_at, scope, ...}
    destroyed?: false
  ]
  ...
end
```

**命令：**
- `%RegisterUser{uri, workspace_uri, password_hash, initial_caps}` → 发 `%UserRegistered{}`
- `%GrantCapToUser{uri, cap, granted_by}` → 发 `%CapGrantedToUser{}`（或若 granter 缺 data-owner cap，返 `{:error, :grant_not_owner}`）
- `%RevokeCapFromUser{uri, cap, revoked_by}` → 发 `%CapRevokedFromUser{}`
- `%MintTokenForUser{uri, token_id, scope, expires_at}` → 发 `%TokenMintedForUser{}`
- `%RevokeTokenForUser{uri, token_id}` → 发 `%TokenRevokedForUser{}`
- `%RotatePasswordForUser{uri, new_password_hash}` → 发 `%PasswordRotatedForUser{}`
- `%DestroyUser{uri}` → 发 `%UserDestroyRequested{}`（触发 `DestroyUserSaga` 级联）

**事件** — 每个命令一个；payload 是命令减去路由 UUID。

**投影：**
- `user_caps_projection` — Ecto 表 `projections.user_caps(uri, cap_json, granted_by, granted_at)`。由 `Behavior.Identity` 查询和 `/admin/users` LV 读。`consistency: :strong` 对要 LV read-after-write 的 cap-grant 派发。
- `user_profile_projection` — Ecto 表 `projections.user_profile(uri, workspace_uri, registered_at, destroyed?)`。由用户列表 LV 读。
- `user_tokens_projection` — Ecto 表 `projections.user_tokens(uri, token_id, scope, minted_at, expires_at, revoked_at)`。由 `entity_tokens` 查询读（替代现有 `entity_tokens` SQLite 表）。

**持久化：** 每 50 事件一次 snapshot。User aggregate 事件量低（每次 cap 授予 + 每次 token mint 一个事件）；50 事件对活跃用户 ≈ 数周活动。

#### 4.2.2 `Ezagent.Entity.Agent` → `Ezagent.Aggregate.Agent`

**当前状态（slice）：** 复杂 — flavor 特定状态 + lineage parent_uri + api_keys + workspace_uri + per-template fork 状态。

**新 aggregate 状态：**
```elixir
defmodule Ezagent.Aggregate.Agent do
  defstruct [
    :uri,
    :workspace_uri,
    :flavor,           # :cc | :codex | :curl | :np | :echo | ...
    :parent_template_uri,
    :lineage_parent_uri,
    :config_dir,
    :api_keys,         # 加密 map；api_keys behavior 的 slice
    caps: MapSet.new(),
    flavor_state: %{},  # per-flavor 子状态，对非-flavor 代码不透明
    sessions: MapSet.new(),  # 该 agent 加入的 session URI
    destroyed?: false
  ]
end
```

**命令** — 拆分 flavor-agnostic 核心 + per-flavor 扩展：

核心：
- `%CreateAgent{uri, workspace_uri, flavor, parent_template_uri, lineage_parent_uri, initial_caps, config_dir}` → 发 `%AgentCreated{}`
- `%GrantCapToAgent{uri, cap, granted_by}` → 发 `%CapGrantedToAgent{}`
- `%RevokeCapFromAgent{uri, cap, revoked_by}` → 发 `%CapRevokedFromAgent{}`
- `%PutApiKeyForAgent{uri, key_name, encrypted_key}` → 发 `%ApiKeyPutForAgent{}`
- `%JoinSessionAsAgent{uri, session_uri}` → 发 `%AgentJoinedSession{}`
- `%LeaveSessionAsAgent{uri, session_uri}` → 发 `%AgentLeftSession{}`
- `%DestroyAgent{uri}` → 发 `%AgentDestroyRequested{}`（触发 `DestroyAgentSaga`）

Per-flavor（cc、codex 等）：
- 每 flavor 暴露 `%FlavorSpecific{...}` 命令 variant；aggregate `execute/2` 派发到 flavor 逻辑 + 发 flavor 特定事件。flavor 的 `apply/2` 子句不透明地变更 `flavor_state`。

**投影：**
- `agent_profile_projection` — 列表 LV。
- `agent_caps_projection` — cap 查询。
- `agent_lineage_projection` — 替代 `Ezagent.AgentLineage` registry（父子关系）。

#### 4.2.3 `Ezagent.Entity.Session` → `Ezagent.Aggregate.Session`

**当前状态：** 代码库里复杂度最高 — Chat slice + Publisher slice + ExternalMirror slice；members；rules；routing。

**新 aggregate 状态：**
```elixir
defmodule Ezagent.Aggregate.Session do
  defstruct [
    :uri,
    :workspace_uri,
    :template_uri,
    :owner_uri,
    members: MapSet.new(),         # 成员 URI（users + agents）
    messages_count: 0,             # 背压度量；完整历史在事件流
    publisher_subscribers: %{},    # 订阅者 pid → cursor
    external_mirror_bindings: [],  # 绑到该 session 的 worker
    template_working_copy: nil,
    destroyed?: false
  ]
end
```

**命令** — 多；按命令数最大的 aggregate。

核心生命周期：
- `%CreateSession{uri, template_uri, owner_uri, workspace_uri}` → 发 `%SessionCreated{}`
- `%DestroySession{uri}` → 发 `%SessionDestroyRequested{}`（触发 `DestroySessionSaga`）

成员（`Behavior.Chat` actions）：
- `%JoinSession{uri, joiner_uri}` → 发 `%MemberJoinedSession{}`
- `%LeaveSession{uri, leaver_uri}` → 发 `%MemberLeftSession{}`
- `%TransferSessionOwnership{uri, new_owner_uri}` → 发 `%SessionOwnershipTransferred{}`

消息：
- `%PostMessageToSession{uri, message}` → 发 `%MessagePosted{}`（也触发投影侧扇出）

Publisher（`Behavior.Publisher.SessionImpl`）：
- `%SubscribeToSessionPublisher{uri, subscriber_pid, cursor}` → 发 `%PublisherSubscriberAdded{}`
- `%UnsubscribeFromSessionPublisher{uri, subscriber_pid}` → 发 `%PublisherSubscriberRemoved{}`
- （注：事件中 PID 是味道 — 见 §11 q#5。也许订阅者在 aggregate 外跟踪。）

External mirror（`Behavior.ExternalMirror`）：
- `%BindExternalMirror{uri, binding_descriptor}` → 发 `%ExternalMirrorBound{}`
- `%UnbindExternalMirror{uri, binding_id}` → 发 `%ExternalMirrorUnbound{}`

**投影** — 多：
- `session_profile_projection` — 列表 LV 用的基础 session 状态。
- `session_messages_projection` — 替代当前 `messages` SQLite 表。每个 `MessagePosted` 事件 → 插一行。
- `session_members_projection` — `(session_uri, member_uri, joined_at, left_at)` 给成员查询。
- `external_mirror_bindings_projection` — 替代当前 `external_mirror_bindings` SQLite 表。

#### 4.2.4 `Ezagent.Workspace` → `Ezagent.Aggregate.Workspace`

**当前状态：** 小 — workspace 元数据 + 拥有关系。

**新 aggregate 状态：**
```elixir
defmodule Ezagent.Aggregate.Workspace do
  defstruct [
    :uri,
    :name,
    :created_by,
    :created_at,
    members: MapSet.new(),
    destroyed?: false
  ]
end
```

**命令：**
- `%CreateWorkspace{uri, name, created_by}` → 发 `%WorkspaceCreated{}`
- `%AddMemberToWorkspace{uri, member_uri}` → 发 `%MemberAddedToWorkspace{}`
- `%RemoveMemberFromWorkspace{uri, member_uri}` → 发 `%MemberRemovedFromWorkspace{}`
- `%DestroyWorkspace{uri}` → 发 `%WorkspaceDestroyRequested{}`（触发 `DestroyWorkspaceSaga` — 级联销毁该 workspace 所有 session/agent/user；昂贵）

**投影：**
- `workspaces_projection` — picker LV。替代当前 `workspaces` SQLite 表。
- `workspace_members_projection` — 给 cap-vis SPEC 的 `list_workspaces_for/2`。Cap-based 可见性变成对该表 + cap 投影的 JOIN。

#### 4.2.5 `Ezagent.ExternalMirror.Worker` → `Ezagent.Aggregate.ExternalMirrorWorker`

**当前状态：** binding 特定的 worker 状态。

**新 aggregate 状态：**
```elixir
defmodule Ezagent.Aggregate.ExternalMirrorWorker do
  defstruct [
    :uri,
    :session_uri,
    :workspace_uri,
    :binding_descriptor,
    :cursor,                # publisher cursor
    :adapter_state,         # per-adapter 内部状态
    destroyed?: false
  ]
end
```

**命令：**
- `%SpawnWorker{uri, session_uri, binding_descriptor}` → 发 `%WorkerSpawned{}`（触发 `BootstrapWorkerSaga`）
- `%AdvanceWorkerCursor{uri, new_cursor}` → 发 `%WorkerCursorAdvanced{}`
- `%TerminateWorker{uri}` → 发 `%WorkerTerminated{}`

**投影：**
- `external_mirror_workers_projection` — live worker 状态 + last-cursor。

### 4.3 11 个 Behavior 模块 — 去向

| Behavior | 去向 | 备注 |
|---|---|---|
| `Behavior.Identity` | 拆为 per-aggregate 的 cap-handling 命令 | Cap grant/revoke 命令落到相关 aggregate（User/Agent）；Behavior 模块变成命令的命名空间 + CapBAC 注册用的 cap_subjects/0 回调。data_owner/1 保留（驱动 saga 补偿路径）。 |
| `Behavior.Chat` | Session aggregate 命令 + 投影器 | 所有 action 变 Session 命令；Behavior 模块变命名空间 + cap_subjects + 消息投影更新逻辑。 |
| `Behavior.Publisher` + `Behavior.Publisher.SessionImpl` | Session aggregate 命令；订阅者跟踪移到投影侧 | 见 §11 q#5 — 事件里 PID 是味道；订阅者跟踪是运行时关心、不是事件溯源关心。 |
| `Behavior.ExternalMirror` | Session aggregate 命令 + Worker aggregate 命令 | Binding 作为 Session 事件持久化；worker spawn 是 saga（BootstrapWorkerSaga 订阅 BindingCreated 派发 SpawnWorker）。 |
| `Behavior.IdentityAdmin` | Workspace aggregate 命令 + admin-shortcut helper 模块 | admin-cap-bypass 逻辑住派发前 authz 流水线；命令本身落到 Workspace aggregate。 |
| `Behavior.UserCredentials` | User aggregate 命令 | 改密是 User 命令。`users.password_hash` 列变投影。 |
| `Behavior.UserTokens` | User aggregate 命令 | Token mint/revoke 是 User 命令。`entity_tokens` 表变投影。 |
| `Behavior.WorkspaceUserAdmin` | Workspace aggregate 命令 | workspace admin 创建用户 → Workspace 上的 `AddUserToWorkspace` + User 上的 `RegisterUser`。两命令序列打包在 saga（`CreateUserInWorkspaceSaga`）。 |
| `Behavior.Presence` | 保留 slice（**不**迁移） | Presence 是实时运行态、不是耐久历史。保留为非-Aggregate 的 `Ezagent.Presence` GenServer（或原生迁 `Phoenix.Presence`）。§11 q#7。 |
| `Behavior.Sandbox` | 保留运行时 only | 测试 fixture 专用；不是生产状态模型一部分。 |
| `Behavior.Routing` | 路由是 workspace 范围规则，存为 Workspace aggregate 状态 | Workspace 命令 `AddRoutingRule` / `RemoveRoutingRule` + 对应事件。 |
| `Behavior.Notifications` | 订阅相关事件 + 发通知的事件 handler | 见 §11 q#5 — 通知发射是副作用 handler、不是状态变更。`Commanded.Event.Handler` impl。 |
| `Behavior.Lifecycle` | 由 aggregate 创建/销毁命令吸收 | Lifecycle 作为 Behavior 迁移后消失；每个 Kind 的 create/destroy 命令替代它。 |

### 4.4 跨-Kind 工作流 — saga 清单

迁移后取代 ad-hoc 跨-Kind 编排的 saga：

| Saga | 触发于 | 级联 |
|---|---|---|
| `DestroyAgentSaga` | `AgentDestroyRequested` | RevokeAllCapsHeldBy → DestroyChildAgents → DropAllSessionMembershipsFor → UnlinkLineage → TerminateAgent |
| `DestroyUserSaga` | `UserDestroyRequested` | RevokeAllCapsHeldBy → DestroyChildAgents（用户为父）→ DropAllSessionMembershipsFor → TerminateUser |
| `DestroySessionSaga` | `SessionDestroyRequested` | EvictAllMembers → UnbindAllExternalMirrors → DestroyAllChildAgents → TerminateSession |
| `DestroyWorkspaceSaga` | `WorkspaceDestroyRequested` | DestroyAllSessions → DestroyAllAgents → DestroyAllUsers → TerminateWorkspace（昂贵 — 需要显式确认 + admin caps；复用每个子的销毁 saga） |
| `CreateSessionSaga` | `SessionCreated` | GrantOwnerOrchestratorAdminCap（URI canonicalization SPEC 的 bug 2 路径）→ InvokeTemplateClassInitHooks → AnnounceSessionReady |
| `CreateUserInWorkspaceSaga` | `WorkspaceAdminRequestedUserCreate` | RegisterUser → GrantDefaultCaps → AddUserToWorkspaceMembers → MintInitialToken（可选） |
| `BootstrapWorkerSaga` | `BindingCreated` | SpawnWorker → SubscribeToSessionPublisher → AnnounceWorkerReady |
| `RevokeCapCascadeSaga` | `WorkspaceMembershipRevoked` | RevokeAllWorkspaceScopedCapsFor（被取消 workspace 成员资格的 principal 失去该 workspace 范围所有 caps） |
| `CapGrantOwnershipVerifySaga` | `CapGrantRequested` | VerifyGranterHasDataOwnerCap（命令时读 granter 的 cap 投影）→ 派发实际 grant 或以 `:grant_not_owner` 拒绝 |

每个 saga ~50-150 行 + per-step 命令/事件 variant。Saga LOC 总计 ≈ 1500-2000 LOC。替代当前 domain 模块中 ~3000 LOC 的 ad-hoc 跨-Kind 编排。

### 4.5 派发前流水线 — 步骤 5.5 + 5.6 + 幂等性的新家

当前派发把步骤 5.5（CapBAC）+ 5.6（workspace 隔离）走 `Kind.Runtime.handle_dispatch/4`、在 Kind GenServer `handle_call` 内。迁移后这些检查在 `Commanded.Application.dispatch/2` **之前** — 在派发前流水线模块。

```elixir
defmodule Ezagent.CommandedApp.Dispatch do
  alias Ezagent.CommandedApp

  @spec dispatch(cmd :: struct(), opts :: keyword()) ::
    :ok | {:error, term()}
  def dispatch(cmd, opts \\ []) do
    with :ok <- Ezagent.URI.canonicalize_cmd(cmd),         # 步骤 1 — 规范化 cmd 中 URI
         :ok <- check_idempotency(cmd, opts),              # 步骤 1.5 — 幂等 key 检查
         :ok <- check_capbac(cmd, opts),                   # 步骤 5.5 — CapBAC chokepoint
         :ok <- check_workspace_isolation(cmd, opts),      # 步骤 5.6 — 跨 workspace 否决
         :ok <- CommandedApp.dispatch(cmd, opts) do        # 步骤 6+ — Commanded 内部
      :ok
    end
  end

  defp check_capbac(cmd, opts) do
    caller = Keyword.fetch!(opts, :caller)
    caps = Keyword.fetch!(opts, :caps)
    needed = Ezagent.CapabilityRegistry.cap_for_command(cmd.__struct__)
    if Enum.any?(caps, &Ezagent.Capability.matches?(&1, needed)),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp check_workspace_isolation(cmd, opts) do
    caller_workspace = Keyword.fetch!(opts, :caller_workspace)
    target_workspace = cmd.workspace_uri  # 每个 cmd 携带 workspace_uri
    if caller_workspace == target_workspace or admin?(opts),
      do: :ok,
      else: {:error, :cross_workspace_denied}
  end

  ...
end
```

每个外部入口（LV、Channel、CLI、MCP）调 `Ezagent.CommandedApp.Dispatch.dispatch(cmd, opts)`。派发前流水线是新 chokepoint — 等价于今天的步骤 5.5 + 5.6。

`Ezagent.CommandedApp.dispatch/2`（裸 Commanded application）对该模块**私有**；外部无直接调用。不变式测试：对 `Ezagent.CommandedApp.dispatch` 在 `Ezagent.CommandedApp.Dispatch` 之外的 grep 为空（镜像当前的 `single_dispatch_entry_test.exs`）。

### 4.6 Aggregate ID 派生 — URI 规范化对等

per `feedback_register_lookup_key_parity` + `feedback_uuid_is_canonical_identifier`：

- 每个命令**必须**携带规范化 URI 字符串，字段名 `:uri`（或对应变体如 `:agent_uri`、`:session_uri`）。
- Router `identify` 子句用这字段：
  ```elixir
  identify(Ezagent.Aggregate.User, by: :uri, prefix: "")
  ```
- 规范形式是 `Ezagent.URI.parse!(...) |> URI.to_string()` — 与 URI 规范化 SPEC 相同。
- 派发前流水线在派发前规范化 URI 字段。
- 跨 aggregate 引用（如 Session 命令引用 Agent URI）以规范字符串携带两个 URI。

Aggregate ID 对 aggregate 不透明（它是路由 key、不是状态）；aggregate 状态里的 URI 是同一个规范字符串。单一真值；路由与状态无分歧。

### 4.7 审计日志 — 什么是领域事件 vs telemetry

今天混在一个 `invocations` 表里的两个不同概念，迁移后**分开**：

**领域事件（在事件流）：**
- `UserRegistered`、`CapGrantedToUser`、`MessagePosted`、`SessionCreated`、`MemberJoinedSession`、`WorkerSpawned`、... — 每个状态变更事件。
- 完整 payload 持久化于事件存储；通过投影可查（`audit_events_projection`）。
- 事件流即审计日志；无独立 audit writer。

**纯 telemetry 事件（留在 SQLite `audit` 表）：**
- `[:ezagent, :authz, :denied]` — 派发被拒；无状态变更；不是领域事件。
- `[:ezagent, :persistence, :failed]` — 基础设施级失败；不是 aggregate 历史。
- `[:ezagent, :cc_bridge, :event]` — 桥侧通道；非状态变更。
- `[:ezagent, :chat, :receive, :dropped]` — 运行时 drop；非状态变更。
- `[:ezagent, :notification, :emit]` — 副作用发射记录；对源 aggregate 非状态变更。

**审计查询模式：**
- "用户 X 在 A 到 B 时间里做了什么" → 在事件流中查 `metadata.caller == "X"` AND `created_at BETWEEN A AND B` 的事件。或经 Postgres event store SQL、或经 `audit_events_projection`（反规范化的读模型加速查询）。
- "为什么这次派发被拒" → 在 SQLite `audit` 表查 `[:ezagent, :authz, :denied]` 行（这**不**在事件流，因为领域没发生事情）。
- "用户 X 当前 cap 集" → 查 `user_caps_projection`。
- "用户 X 的 cap-grant 历史" → 在事件流查 `CapGrantedToUser` / `CapRevokedFromUser` 事件，按 `metadata.target == "X"` 过滤。

此分法保持领域事件纯净（只状态变更事实；无 telemetry 噪声）、同时保留 telemetry 给运维 + 调试。

---

### 4.8 LV / Channel / CLI 写后立即重读一致性矩阵（r2 — HIGH-3 fix）

Codex r1 HIGH-3：r1 只说 "per 派发点 opt 到 :strong"、不枚举 site。默认 `:eventual` 在任何写后立即重读 state 的 callsite 都不安全。

**静态枚举的写→读 site 必须用 `consistency: :strong`**（或具名投影器一致性列表）：

| Callsite | 文件:行 | 写 | 立即重读 | 要求模式 |
|---|---|---|---|---|
| 建用户 | `users_live.ex:137` | RegisterUser | `list_users()` | `:strong`（或 `[UserProfileProjector]`） |
| 加 workspace 成员 | `workspace_detail_live.ex:165` | AddMemberToWorkspace | `Workspace.Store.get_by_name/1` | `:strong` |
| 授予 cap | `entity_caps_live.ex:142` | GrantCapToUser/GrantCapToAgent | reload caps | `:strong`（或 `[UserCapsProjector, AgentCapsProjector]`） |
| 加 routing rule | `routing_live.ex:235` | AddRoutingRule | reload rules | `:strong` |
| 建 session（向导） | `home_live.ex` 向导提交 | CreateSession | redirect→/sessions/X mount | `:strong` |
| 铸用户 token（CLI） | `ezagent.user.token.ex:75` | MintTokenForUser | 打印 token 行 | `:strong` |
| 建 agent（CLI + LV） | `agents_live.ex`、`mix ezagent.agent.create` | CreateAgent | reload agent | `:strong` |
| 置 api_key（LV） | agent api_keys LV — TBD | PutApiKeyForAgent | reload keys 列表 | `:strong` |
| 绑外部 mirror | feishu bind LV/CLI | BindExternalMirror | reload bindings | `:strong` |
| Workspace 建 | `workspaces_live.ex` | CreateWorkspace | redirect→detail | `:strong` |
| Profile upsert | `users_live.ex:177` | UpsertProfile | reload user | `:strong` |
| 发 chat 消息 | LV / Channel chat send | PostMessageToSession | （无重读；fanout 经 PubSub） | `:eventual`（可接受 — 异步 UI 更新） |

**Phase 10-B/10-C 不变式测试：** `Ezagent.Invariants.ConsistencyMatrixTest` 走枚举 callsite、解析 AST、断言 dispatch 调用用 `consistency: :strong`（或具名投影器列表）。CI grep 门拒绝任何枚举派发路径显式用 `consistency: :eventual`。

**未来 callsite：** 任何新的写→立即读模式**必须**在 SPEC 时加入此矩阵 + 不变式更新。矩阵是纪律；不变式是门。

---

## 5. Read Model 策略

### 5.1 每个逻辑读视图一个投影

每个 LiveView 页面 / API 端点对应一张投影表：

| 投影 | 源事件 | 由谁读 |
|---|---|---|
| `user_profile` | UserRegistered、PasswordRotatedForUser、UserDestroyRequested | `/admin/users`、登录流 |
| `user_caps` | CapGrantedToUser、CapRevokedFromUser | `/admin/caps`、派发 authz |
| `user_tokens` | TokenMintedForUser、TokenRevokedForUser | `entity_tokens` 读、bearer auth |
| `agent_profile` | AgentCreated、AgentDestroyRequested | `/admin/agents`、agent picker |
| `agent_caps` | CapGrantedToAgent、CapRevokedFromAgent | `/admin/caps`、派发 authz |
| `agent_lineage` | AgentCreated（带 parent_uri）、AgentDestroyRequested | lineage 查询 |
| `agent_api_keys` | ApiKeyPutForAgent | 运行时凭证读取（注：投影里也加密；同当前 `agent_api_keys` 表的加密） |
| `session_profile` | SessionCreated、SessionDestroyRequested、SessionOwnershipTransferred | `/sessions`、session picker |
| `session_messages` | MessagePosted | `/sessions/X`、聊天历史（替代 `messages` SQLite 表） |
| `session_members` | MemberJoinedSession、MemberLeftSession | 成员查询、`/sessions/X` |
| `external_mirror_bindings` | ExternalMirrorBound、ExternalMirrorUnbound | bindings reconciler、`/admin/mirrors` |
| `external_mirror_workers` | WorkerSpawned、WorkerCursorAdvanced、WorkerTerminated | worker 状态 |
| `workspaces` | WorkspaceCreated、WorkspaceDestroyRequested | workspace picker、`Workspace.list_*` |
| `workspace_members` | MemberAddedToWorkspace、MemberRemovedFromWorkspace | `list_workspaces_for/2` cap-vis 查询 |
| `audit_events` | （所有领域事件经审计投影器过滤） | `/admin/audit` 可查历史 |

每个投影是一个模块：

```elixir
defmodule Ezagent.Projection.UserCaps do
  use Commanded.Projections.Ecto,
    application: Ezagent.CommandedApp,
    name: "UserCapsProjection",
    consistency: :eventual  # 给 read-after-write 的 LV opt 到 :strong

  project %CapGrantedToUser{} = event, fn multi ->
    Ecto.Multi.insert(multi, :cap, %Ezagent.Projection.UserCap{
      user_uri: event.user_uri,
      cap_json: Jason.encode!(event.cap),
      granted_by: event.granted_by,
      granted_at: event.granted_at
    })
  end

  project %CapRevokedFromUser{} = event, fn multi ->
    Ecto.Multi.delete_all(multi,
      :cap,
      from(c in Ezagent.Projection.UserCap,
        where: c.user_uri == ^event.user_uri and c.cap_json == ^Jason.encode!(event.cap))
    )
  end

  def after_update(_event, _metadata, _changes) do
    Phoenix.PubSub.broadcast(EzagentCore.PubSub, "ezagent:projections:user_caps", :updated)
    :ok
  end
end
```

### 5.2 投影的 workspace 范围

每个 workspace 范围的投影行带 `workspace_uri` 列（与当前 SQLite 表同惯例）。`Ezagent.Persistence.scope_by_workspace/2` 原样用于投影；现有 workspace 隔离不变式测试指向投影表。

### 5.3 冷加载处理

LV mount 时读投影（同步 DB 查询）。若 LV 是从派发点 redirect 过来，派发用 `consistency: :strong`、投影已追上。

跨 tab 竞速（tab 1 派发，tab 2 在投影追上前 mount 过期 LV）：
- LV mount 用 `Commanded.Subscriptions.wait_for/3`，在该 URI 已知的最新 aggregate version 上等。已知则等。未知则接受 eventual。
- LV 订阅该投影的 PubSub topic；投影器 `after_update/3` 发订阅者；LV re-render。

冷加载防御与 gift-card-demo 相同：订阅 + 更新时重读 + 初次 render best-effort。最坏：≤10ms 过期窗口。

### 5.4 per-投影器的 strong vs eventual

默认：所有投影器 `consistency: :eventual`。Opt 到 `:strong` 只给那些控制派发点立即 redirect 的投影器（如 `user_profile` 给 `/admin/users/create` → redirect 到 `/admin/users/X` 流，需要新用户在 profile 投影里）。

权衡：每个 `:strong` 投影器给每次声明 `:strong` 一致性的派发加延迟。默认 `:eventual` 让热路径快。

---

## 6. 迁移计划 — 分阶段

迁移作为 **Phase 10** 在 IMPLEMENTATION_ROADMAP 中。四个子阶段（10-A 到 10-D），每个由 /goal + per-phase 不变式测试把关。

### 6.0 前向数据迁移 — snapshot import（r2 — CRIT-1 fix）

**Codex r1 CRIT-1：** r1 说迁移 Kind "不迁现有 snapshot；第一条命令创建新鲜事件溯源状态"。这在切换点丢失活的 User/Session/Agent/Workspace state。按 `feedback_destructive_migration_anti_pattern` **不可接受**。

**r2 fix — 每个 Phase 10-A 到 10-C 都在生产派发路由到 aggregate 之前先跑 Step 0（snapshot import）：**

每个 Aggregate 类定义专门的 `%XSnapshotImported{}` 事件 variant。Aggregate 的 `apply/2` 有处理 import 事件的子句、从 snapshot payload 水合 aggregate 状态。事件由 `mix ezagent.aggregate.import --kind <kind>` 任务在 per-Phase 切换前对每个现有 URI 发射**一次**。

**Per-Kind import 事件：**

| Kind | Import 事件 | Payload |
|---|---|---|
| User | `%UserSnapshotImported{}` | 完整 pre-existing slice（identity caps、user_credentials counter、user_tokens counter），加 `users.password_hash`、`entity_profiles.*`、`entity_tokens.*` JOIN 列 |
| Session | `%SessionSnapshotImported{}` | 完整 Chat slice + Publisher slice + ExternalMirror slice + members + ring 状态 |
| Agent | `%AgentSnapshotImported{}` | 完整 per-flavor slice + lineage + api_keys |
| Workspace | `%WorkspaceSnapshotImported{}` | name、members、routing rules |
| ExternalMirrorWorker | `%WorkerSnapshotImported{}` | binding descriptor + cursor 状态 |
| AgentTemplate | `%AgentTemplateSnapshotImported{}` | identity caps + template content |
| SessionTemplate | `%SessionTemplateSnapshotImported{}` | identity caps + template content |

**Import 任务：**

```
mix ezagent.aggregate.import \
  --kind user \
  --batch-size 100 \
  --dry-run    # 默认 — 打印将 import 的内容、退出
```

去掉 `--dry-run` 后：
1. 对 Kind type 匹配的每个 `kind_snapshots` 行，读 `state_binary`。
2. JOIN 补充表（User 是 `users.password_hash`、`entity_profiles.*`、`entity_tokens.*`；Session 不含 `messages` — 见下）。
3. 构 `%XSnapshotImported{}` 事件 payload。
4. 作为 aggregate stream 上第一个事件派发（经 `EventStore.append_to_stream/4`，**不**经 aggregate `execute/2` — 这些不是命令，是构造期 aggregate 接受的直接事件）。
5. 重放 aggregate；`apply/2` 子句水合状态。

**Session 的 `messages` 表处理：** 现有 `messages` SQLite 表含全部历史消息。把每条历史消息作 `%MessagePosted{}` 事件 import 会让事件存储膨胀。**决定：** `%SessionSnapshotImported{}` 事件 payload 只载 `last_message_id` + `recent_messages` ring（耐久 Chat slice 字段）；**完整**消息历史**留**在 SQLite `messages` 表（变只读归档表；投影表 `session_messages_projection` 装切换后的新消息）。查询历史消息时 JOIN 两表、按 `created_at < <切换时间戳>` 过滤。Phase 10-D 把这作为永久形状文档化；`messages` 表**不**删。

**Parity 门（切换准则，per `feedback_completion_requires_invariant_test`）：**

```
mix ezagent.aggregate.verify --kind <kind>
```

读每个 URI 的事件回放 aggregate 状态 + 与原 `kind_snapshots.state_binary` 跨字段比对。断言 §4.2.* 枚举的所有耐久字段相等。任何不匹配 → import 不全；切换被阻塞。

**切换是这个瞬间：** 派发前流水线把目标为 Aggregate 的命令路由到 `Commanded.Application.dispatch/2` 而非 legacy `Invocation.dispatch/1`。所有迁移 URI 的 parity 门绿后切换提交。

**切换前回滚：** 微 — 从 aggregate stream 删事件；aggregate 恢复新鲜。原 `kind_snapshots` 数据不动。

**切换后回滚：** 较难 — 切换后由生产派发写入的事件需经 §12 unwind 路径回放到 slice/snapshot。

### 6.1 Phase 10-A — 依赖 + 骨架 + 先迁 Worker（最小 Kind）

**目标：** 证明集成。一个 Kind 迁移；其余不动。若 10-A 失败，整个迁移中止（恢复 deps + 骨架 + Worker 代码；其它无变化）。

**Deliverables：**
1. 给根 mix 加 deps：`commanded ~> 1.4`、`eventstore ~> 1.4`、`commanded_eventstore_adapter ~> 1.4`、`commanded_ecto_projections ~> 1.3`、`postgrex ~> 0.19`。
2. 新建 umbrella app `apps/ezagent_event_store` — `eventstore` 库的配置（Postgres 后端；dev 用本地 5432 端口 Postgres，test 经 Commanded 内置 test adapter 用 in-memory）。
3. 新建 umbrella app `apps/ezagent_commanded_app` — `Ezagent.CommandedApp` 模块 + router + 派发前流水线（§4.5）。
4. 新建 umbrella app `apps/ezagent_projections` — 投影表（Ecto repo 对接现有 SQLite 做投影存储；事件住 Postgres；不对称是有意的 — 见 §7.3）。
5. 把 `Ezagent.ExternalMirror.Worker` 迁到 `Ezagent.Aggregate.ExternalMirrorWorker`。
   - Worker 是最小 Kind（117 LOC），最隔离（自己的 domain app），内部订阅者有界。
   - 现有 `Ezagent.Entity.ExternalMirrorWorker` Kind 模块**替换** — 不弃用。同 URI 形状；同调用者（本阶段也加 boot-spawn Worker 的 BindingCreated saga）。
6. 实现 `BootstrapWorkerSaga`（替代 boot reconciler 扫描）。
7. 实现 `external_mirror_workers_projection`。
8. 与 Worker 对话的 Phoenix.Channel + LV 走 `Ezagent.CommandedApp.Dispatch`。

**Phase 10-A 不变式测试（门槛，per `feedback_completion_requires_invariant_test`）：**
- `Worker aggregate 状态仅凭事件流即可确定性重建` — 测试拉起 aggregate、派 N 条命令、停 aggregate、重启、断状态相等。
- `BootstrapWorkerSaga 在 BindingCreated 事件后续跑而不重跑 binding` — 测试播 BindingCreated 事件、杀 saga 进程、重播、断无重复 SpawnWorker 派发。
- `Worker → Session 的跨-Kind 调用走事件订阅而非直接 GenServer.call` — 对 Worker 代码 grep；无跨-Kind 读用 `Kind.get_slice/2` 或 `KindRegistry.lookup/1`。

**Phase 10-A unwind（若失败）：**
- 回滚 mix.exs 全部 deps。
- 删三个新 umbrella app。
- 从 git 恢复 `Ezagent.Entity.ExternalMirrorWorker`。
- 无数据迁移；worker 状态本就由 `external_mirror_bindings` 行派生（从未移动）。

### 6.2 Phase 10-B — User + Session

**前置：** Phase 10-A 合并 + 1 周 dev/staging 浸泡。

**目标：** 两个最常用 Kind。User：中（240 LOC）；Session：大（2272 LOC）；都对所有用户面流关键。

**Deliverables：**
- `Ezagent.Aggregate.User` + 命令/事件/投影（§4.2.1）。
- `Ezagent.Aggregate.Session` + 命令/事件/投影（§4.2.3）。
- Saga：`CreateSessionSaga`、`DestroySessionSaga`、`DestroyUserSaga`、`CapGrantOwnershipVerifySaga`。
- 所有 User + Session 调用点迁到新命令-based API。现有 `EzagentDomainChat.create_session/3` 要么变成构造 `%CreateSession{}` + 派发点的薄包装，要么改为直接派发。

**Phase 10-B 不变式测试：**
- User caps 从事件流重建。
- Session 消息从事件流重建。
- `CreateSessionSaga` 确定性完成（无遗漏 GrantOwnerOrchestratorAdminCap 步）。
- `DestroyUserSaga` 在模拟步骤失败下正确补偿（destroy_lifecycle 4 轮失败解决）。

**Phase 10-B unwind：**
- 更复杂。User + Session aggregate 已写事件到生产事件存储。Unwind 需要：
  1. 停派发（新命令走 GenServer-Kind 代码）。
  2. 重放事件流 → 经一次性 `mix ezagent.unwind.user_session` 任务写回 slice/snapshot 表。
  3. 验 slice/snapshot 与投影一致。
  4. 从 git 恢复 GenServer Kind 模块。
- 已文档化 + 可逆；代价是手工重放步骤。

### 6.3 Phase 10-C — Agent + Workspace

**前置：** Phase 10-B 合并 + 2 周浸泡。

**目标：** 剩余 Kind。Agent：大（798 LOC）+ per-flavor variant；Workspace：小但跨切。

**Deliverables：**
- `Ezagent.Aggregate.Agent` + 命令/事件/投影（§4.2.2）。
- `Ezagent.Aggregate.Workspace` + 命令/事件/投影（§4.2.4）。
- Saga：`DestroyAgentSaga`（触发的 SPEC #440）、`DestroyWorkspaceSaga`、`CreateUserInWorkspaceSaga`、`BootstrapWorkerSaga`（重构 — 在 Phase 10-A 但在此用 Workspace 上下文丰富）。
- 所有 per-flavor agent 代码迁移。Flavor Behavior（cc、codex、curl、np、echo）获得 Command + Event 词汇表。

**Phase 10-C 不变式测试：**
- Agent lineage 查询与 aggregate 状态匹配（无投影漂移）。
- `DestroyAgentSaga` 完成 7 步级联或干净补偿。
- `DestroyWorkspaceSaga` 级联所有 child session/agent/user。

### 6.4 Phase 10-D — 弃用 + 清理

**前置：** Phase 10-A 到 10-C 合并 + 1 月浸泡。

**目标：** 删旧代码。

**Deliverables：**
- 删 `Ezagent.Kind.Server`、`Ezagent.Kind.Snapshot`、`Ezagent.KindRegistry`、`Ezagent.SpawnRegistry`、`Ezagent.PendingDelivery`、`Ezagent.ReadyGate`。
- 删 `Ezagent.Invocation`（及其所有调用者）。
- 删 `kind_snapshots` SQLite 表（最后一次给运维记录的 data dump 后）。
- 删领域事件路径的 `Ezagent.Audit.Writer`；telemetry 路径保留。
- 删 `Ezagent.Behavior`（和所有 Behavior 模块）— 由 Command 模块 + per-Aggregate execute 子句取代。
- 更新 `IMPLEMENTATION_ROADMAP.md` §1.1 标 Phase 10 完成 + 新架构基线。
- 更新 `CLAUDE.md` skill `ezagent-developer` 指向新派发/aggregate 模式。

**Phase 10-D 不变式测试：**
- 跨 `apps/` grep `Ezagent.Kind.Server`、`Ezagent.Invocation`、`KindRegistry.lookup` 等为空。
- 所有 LV 从投影读；任何地方无 `Kind.get_slice/2`。

### 6.5 阶段估时

| 阶段 | 估计日历时（1 开发者 + codex 评审） |
|---|---|
| 10-A | 2-3 周 |
| 10-B | 4-5 周 |
| 10-C | 4-5 周 |
| 10-D | 1-2 周 |
| **合计** | **~3 个月** |

粗估 — 假设无重大阻塞、10-A 模式可泛化。Allen 需输入这是否对齐当前优先级（见 §10 OQ-2）。

---

## 7. 性能 + 运维成本分析

### 7.1 热路径派发延迟

| 操作 | 当前延迟 | 新延迟 | 备注 |
|---|---|---|---|
| 对现存 Kind 派 `:cast` | ~1ms（`GenServer.cast` + slice 更新 + `:on_change` SQLite 写） | ~5-50ms（事件追加到 Postgres） | Postgres 事件追加主导；与今天 SQLite `:on_change` 同量级但更慢 per-op（fsync 语义） |
| 对现存 Kind 派 `:call` | ~5ms（`GenServer.call` + slice + 写 + 回复） | ~10-60ms（事件追加 + aggregate apply + 回复） | 类似形状 |
| `consistency: :strong` `:call` | n/a — 当前模型经 GenServer 串行隐式强一致 | ~15-80ms（事件追加 + 强投影器提交 + 回复） | 新「强」模式与当前有效行为相似 |
| 冷 aggregate 重放（重启后） | n/a — Kind GenServer 从最新 snapshot 起 | ~5-50ms（加载 snapshot + 重放 snapshot 后事件） | `snapshot_every: 50` 限重放到 ≤50 事件 |
| LV mount + 初次读 | ~1ms（Kind.get_slice 同步调） | ~1-5ms（Postgres SELECT） | 大致相当；SQLite 本地盘比 Postgres 网络快、但差距 ms 级 |
| LV 更新（投影驱动） | n/a（当前由 Behavior 经 PubSub 推） | ~10-20ms（投影器提交 + PubSub 广播 + LV re-render） | 与当前相似 — 当前也有广播跳 |

**结论：** 事件存储驱动派发在最坏情况下**比当前每次派发慢 5-10 倍**（50ms vs 5ms），但仍在人类感知边界内（<100ms）。对批工作流（CLI）可接受；对实时 UI 无缝。

### 7.2 Aggregate snapshot 频率调参

`snapshot_every: 50` 事件是推荐默认。Per-Aggregate 覆盖：

- **Session** — 高事件量（每消息一个事件）。`snapshot_every: 100` 摊销 snapshot 成本。最坏冷重放 = 100 事件 × 每个 50μs = 5ms。
- **User** — 低事件量。`snapshot_every: 20` 即可；重放成本可忽略。
- **Workspace** — 极低量。`snapshot_every: 10`。
- **Agent** — 中量；`snapshot_every: 50` 默认。
- **Worker** — 中量（每 cursor 推进一个事件）；`snapshot_every: 100`。

这些是起点；上线后按生产 telemetry 调。

### 7.3 Dev 负担 — Postgres 进 dev 循环

当前 dev 循环用 SQLite（零配置）。Postgres 要：
- 本地跑 `postgres`（Docker：`docker run -p 5432:5432 postgres:16`，或 homebrew：`brew install postgresql@16 && brew services start postgresql@16`）。
- 首次 setup 跑 `mix event_store.create` + `mix event_store.init`。
- 给事件存储 schema 额外一个 repo（与现有 SQLite 投影 repo 分开）。

**缓解：**
- **Test 模式用 in-memory adapter** — `Commanded.EventStore.Adapters.InMemory` 进程内跑；`mix test` 无需 Postgres。从 dev 角度 test 环境不变。
- **`docker-compose.dev.yml`** 提供 Postgres + adminer 容器；`mix ezagent.dev.up` 拉起。Onboarding 成本：clone 时一条 Docker 命令。
- **Snapshot 存储也在 Postgres**（Commanded 内置 `snapshotting` 配置）— dev 里无独立 snapshot 基础设施。
- **迁移路径文档化在 CONTRIBUTING.md** — Phase 10-A 后第一次 PR 的开发者读新 setup 指南；现有开发者需要 pull docker-compose 改动。

**承认权衡：** 零配置 dev 体验丢失。需 Allen 输入（§10 OQ-2）。

### 7.4 运维负担 — Postgres 备份、复制、PITR

Postgres 运维普及；工具成熟：
- **备份**：`pg_dump` 全量；WAL 归档给 PITR。
- **复制**：流复制；standby 容错。
- **PITR**：基于 WAL；标准 `recovery.conf`。

对 ezagent 规模（Allen 当前运维模式：每部署单租户），单 Postgres 节点 + 每夜 `pg_dump` + WAL 归档够用。云托管（RDS、Cloud SQL、Supabase）都行。不需新运维技能、只是「我们现在除了 SQLite 还跑 Postgres 做投影 + telemetry」。

**SQLite 保留：**
- 投影（投影 schema 住 SQLite，兼容所有现有读路径）。
- Telemetry 审计（非领域事件 `audit` 表）。
- 应用配置 / 模板 / fixture。

**Postgres 只处理：**
- 事件存储（`eventstore` 库 schema）。
- Aggregate snapshot（Commanded snapshot 存储，与 `eventstore` schema 共享）。

**为什么拆：** SQLite 在低延迟本地读上无敌；Postgres 的事件存储 schema 是唯一非要 Postgres 的库要求。这种拆分让我们对一切不**必须**用 Postgres 的保留 SQLite、只对必须的付 Postgres 代价。不对称、但务实。

### 7.5 磁盘占用

事件存储单调增长（事件追加，永不删）。估：
- 每事件：~200-1000 字节 JSON payload + ~100 字节 metadata。
- ezagent 活跃率：极粗估稳态 ~1000-10,000 事件/天。
- 日增：~1MB-10MB/天；~1GB/年最坏。

事件归档策略：snapshot 让回放无论流多长都快，所以事件不必为了性能删。可归档（移冷存）省成本；多年不必。§11 q#8 处理归档事件上的查询模式。

---

## 8. 迁移风险 + 回滚计划

### 8.1 Per-phase 回滚

每阶段在 §6 有显式 unwind。摘要：

| Phase | 回滚复杂度 | 数据风险 |
|---|---|---|
| 10-A（仅 Worker） | 微 — 恢复代码；无数据迁移 | 无 — Worker 状态本就由 `external_mirror_bindings` 派生，从未移动 |
| 10-B（User + Session） | 中 — 经 `mix` 任务手工事件重放 → slice/snapshot | 低 — 事件在事件存储，可回放到 slice |
| 10-C（Agent + Workspace） | 中 — 同 10-B | 低 — 同 |
| 10-D（清理） | 难 — 旧代码已删；回滚意味着从 git 恢复 + 重跑 10-B/10-C unwind | 中 — 仅在前所有阶段失败时触发 |

### 8.2 混合期异质化风险

在 Phase 10-A 到 10-C，部分 Kind 是 Aggregate、其余仍 GenServer。它们如何交互：

- **Aggregate → GenServer Kind 跨-Kind 调：** Saga 发命令到 GenServer Kind。该命令的「派发」对那个 Kind 走**旧** `Ezagent.Invocation.dispatch/1` 路径。桥：派发前流水线发现命令目标 URI 映射到未迁移 Kind，则走 `Invocation.dispatch/1`。桥模块是 `Ezagent.MigrationBridge.dispatch_to_legacy/2`。
- **GenServer Kind → Aggregate 跨-Kind 调：** `Behavior.invoke/4` 调入迁移 Kind。桥：构造命令并经新流水线派发。在桥模块同样显式。

桥模块是允许混合运行的 SHIM。它有意窄 — 恰好上述两个方向。Phase 10-D 删桥。

§11 q#5 给 codex 评审枚举此点。

### 8.3 实施期间事件 schema 破坏

若 Phase 10-B impl PR 加了一种事件类型而 Phase 10-B v2 需要重命名字段，每个历史事件磁盘上仍是旧形状。`Commanded.Event.Upcaster` 处理：

```elixir
defimpl Commanded.Event.Upcaster, for: MessagePosted do
  def upcast(%MessagePosted{content: c} = ev, _meta) when not is_nil(c) do
    %MessagePosted{ev | body: c, content: nil}
  end
  def upcast(%MessagePosted{} = ev, _meta), do: ev
end
```

模式被 Commanded 良好支持（[hexdocs](https://hexdocs.pm/commanded/Commanded.Event.Upcaster.html)）。每次事件 schema 变更加一个 Upcaster impl；历史事件只读。

### 8.4 生产数据丢失风险

per `feedback_destructive_migration_anti_pattern`：
- **迁移期间对现有 SQLite 表不 DROP / TRUNCATE。** 新代码从事件派生投影读；旧代码从 slice 表读（混合期）。共存。
- **最终清理（Phase 10-D）只在 10-C 后 1 月干净运行后** 才删 `kind_snapshots`。
- **事件存储由构造 append-only** — 没有显式运维动作不会意外删事件。

风险有界：最坏（每阶段失败），数据可从从未截断的 SQLite 表恢复。Phase 10-D 是唯一不可回头点，且由 1 月浸泡把关。

---

## 9. 向后兼容 / 外部 API

### 9.1 保留的面

- Phoenix.Channel topic 名 + 消息形状 — 不变。
- HTTP 端点路径 + JSON 形状 — 不变。
- LiveView URL + Assigns — 从用户视角不变。
- CLI 命令名 + flag 形状 — 不变。
- MCP 工具 schema — 不变。
- `URI` 寻址方案 — 不变。
- Capability struct 形状 — 不变。

### 9.2 变的面

- 插件作者：不再 `@behaviour Ezagent.Kind` + `Ezagent.Behavior` 模块，他们写 `@behaviour Commanded.Aggregates.Aggregate` + Command 模块 + Event 模块 + per-Aggregate execute 子句。`ezagent-developer` skill 在 Phase 10-D 重写。
- Domain context 模块：`EzagentDomainChat.create_session/3` 要么变薄包装（构造 `%CreateSession{}` 并派发），要么删并由 LV / channel 直接派发取代。每 impl PR 决定。
- 审计消费者：对领域事件查 SQLite `invocations` 表的查询在 10-D 后失败 — 那些查询必须迁到 `audit_events_projection`、或经 `EventStore.read_stream_forward/4` 的事件流过滤。Phase 10-B / 10-C 期间分段迁移。

### 9.3 插件兼容

umbrella 外的插件（如未来在独立 git remote 的插件）需把 Kind 定义迁到 Aggregate。per `feedback_north_star_plugin_isolation`，迁移成本有界 — 插件写命令 + 事件 + aggregate；他们**不**碰事件存储、router、或 saga 基础设施（住 `ezagent_commanded_app`）。

现有 SPEC 的 3-tier 规则保留：
- **Tier 1 — core：** `apps/ezagent_core/`、`apps/ezagent_commanded_app/`、`apps/ezagent_event_store/`、`apps/ezagent_projections/`。拥有 Commanded 接线。
- **Tier 2 — domain：** `apps/ezagent_domain_*/`。拥有他们 domain Kind 的 aggregate + 命令 + 事件 + 投影器 + saga。
- **Tier 3 — plugin：** `apps/ezagent_plugin_*/`。拥有 flavor 特定的 aggregate 扩展（per-flavor 命令 + 事件 + Agent aggregate 上的 per-flavor execute 子句）。

插件不能跨到其它插件的 aggregate；走事件 + saga。

---

## 10. 给 Allen 的开放问题

### OQ-1. DB 选择 — Postgres 给事件存储、SQLite 给投影 — 接受？

决定：是（推荐）。备选：
- (a) **全迁 Postgres** — 弃 SQLite。更干净；一个 DB。代价：现有基于 SQLite 的代码（audit、fixture、template）必须迁；扰动更大。
- (b) **除事件存储外都 SQLite** — 当前推荐（§7.4）。不对称但务实。
- (c) **找一个 SQLite 事件存储 adapter** — 无维护版本；要建并维护自定义 `Commanded.EventStore.Adapter` impl。高风险；不推荐。

### OQ-2. 迁移日历 — 3 个月可接受、或要不同分阶段？

需 Allen 输入。分阶段计划保守（每阶段一类 Kind + 1-2 周浸泡）。加速选项：
- (a) Phase 10-B 和 10-C 并行（风险高；两团队；我们没两团队）。
- (b) 跑完 10-A 然后对所有 Kind 直跳 10-D 等价（big bang；按 `feedback_destructive_migration_anti_pattern` 拒）。
- (c) Phase 10-A 到 10-C 期间暂停非迁移特性工作（Allen 拍板）。

### OQ-3. Dev 体验 — Postgres 进 dev 循环、负担可接受？

§7.3 缓解。Allen 决定 daily dev 加 docker-compose 跳是否可接受。

### OQ-4. 多租户 — 事件溯源改变租户隔离关心吗？

当前 per-workspace 隔离不变式（Phase 9 / SPEC v3 §7）前向移植：每个领域事件携带 `workspace_uri`；投影在查询里强制隔离。事件流**本身**默认**不**按 workspace 分区 — 所有 workspace 的所有事件住同一流。这可能是运维关心点（不经 full dump-filter-restore 循环不能把一个 workspace「从事件日志删除」）。

备选：每 workspace 一个事件流。Commanded 自然支持 per-stream 订阅；多流 aggregate 需要小心。§11 q#6。

### OQ-5. 混合期互操作 — 桥模块放哪

Phase 10-A 到 10-C 桥模块 `Ezagent.MigrationBridge`。该住 `apps/ezagent_core/`（Tier 1）还是 `apps/ezagent_commanded_app/`（也是 Tier 1）？大概后者 — 桥是迁移专用脚手架、非永久特性。Allen 同意？

### OQ-6. Saga — 监督在 `Ezagent.CommandedApp` 内还是 sibling supervisor？

Commanded 两者皆支持。app 内更简单（单监督树）；sibling 更隔离。默认推荐：Phase 10-A 走 app 内；saga 数过 ~20 时再考虑。

### OQ-7. Presence — 保留 slice-based 还是迁 `Phoenix.Presence`？

per §4.3，Presence 不迁事件溯源（瞬态运行状态）。两选：
- (a) 当前 `Ezagent.Presence` GenServer + slice 保留。
- (b) 原生迁 `Phoenix.Presence`（更好测；CRDT-backed；集群就绪）。

独立于本 SPEC 决策；此处标记。

### OQ-8. 审计保留 — 何时归档旧事件？

EventStore 单调增长（§7.5）。~1GB/年，归档多年不急。何时要策略？

---

## 11. Codex 对抗评审问题

为 codex r1 预载的攻击向量：

1. **Phoenix + Commanded 集成成熟度 — 有可比规模的生产参考、还是我们在开创？** §3.6 列 Conduit、Gift-card-demo、Segment Challenge、Honeydew、Casavo。无「数千 aggregate 类型」规模的。判定：模式已建立；ezagent 规模落在已有用例。

2. **LV 的 read-after-write 一致性 — 用户派发命令并 LV re-render 时，它会看到更新状态吗？`:strong` 是对答案、还是它阻塞命令返回直到投影追上？** §3.3 解释三模式；推荐默认 `:eventual` + per 派发点 opt-in `:strong`。阻塞正是「向导 → redirect → 详情页」需要的。Codex：验证我们具体的 LV → 派发 → re-render 流都有 opt-in 路径文档化。

3. **Saga 部分失败：销毁级联 7 步；第 4 步失败，Saga 如何补偿？有发表的补偿模式吗？** §3.8 展示带 `error/3` 回调的销毁 saga。Commanded saga 中补偿显式（无自动回滚）；saga 代码**必须**编码补偿。Codex：验证销毁 saga 补偿逻辑完整（第 4 步失败是要回滚 1-3 步、还是只重试第 4 步？— 取决每步幂等性）。

4. **Postgres vs SQLite — ezagent 用 SQLite；能两者都支持、还是必须全迁？** §7.4 + OQ-1：推荐分（Postgres 给事件存储 + snapshot；SQLite 给投影 + audit + 其它）。不对称但可行。Codex：验证不对称不产生跨 DB 查询问题（不应有 — 投影 + 事件存储不共享查询；它们只共享投影更新操作，这是投影自己 SQLite repo 里的 Ecto.Multi）。

5. **异质化迁移 — Phase 10-A 到 10-C 部分 Kind Aggregate、部分 GenServer。混合模式下跨 Kind 工作流怎么走？** §8.2 + `Ezagent.MigrationBridge`。Codex：验证桥模块处理两个方向（Aggregate → GenServer + GenServer → Aggregate）且 Phase 10-D 桥删除时不留遗弃调用者。

6. **事件 schema 演进 — 给现存事件类型加字段、回放老事件。** §8.3 + Commanded `Event.Upcaster` 模式。Codex：验证 Phase 10-B/10-C 每个预期 schema 变更的 Upcaster impl 路径（从销毁 SPEC 至少 5 个已知演进排队）。

7. **性能：带 N 事件 aggregate 的最坏事件流回放时间。热 Aggregate 可能 10K+ 事件。** §7.2 + snapshot_every: 50-100。Codex：验证 50 事件 × 50μs = 2.5ms 冷启动对我们 LV mount 预算可接受（是）。

8. **审计查询：今天 `invocations` 表可 SQL 查。EventStore 下 ad-hoc 审计查询需事件流扫描或投影。定义审计查询模式。** §4.7。Codex：验证 `audit_events_projection` schema 可满足现有 `/admin/audit` LV 过滤谓词（workspace_uri、caller、时间范围、action 类型）。今天若有投影满足不了的查询，记为 Phase 10-B impl-blocker。

---

## 12. 整体中止路径回滚计划

若 Phase 10-A 合并 + 10-B / 10-C 在进行中后，Allen 决定迁移不行：

1. **停新派发。** 在派发前流水线设 feature flag，把所有命令路由经旧 `Ezagent.Invocation.dispatch/1` 路径。新派发停发事件；Aggregate 停收命令。
2. **重放事件回 slice/snapshot。** 对每个迁移完的 Aggregate，`mix ezagent.aggregate.unwind --uri <uri>` 任务读事件流 + 写等价 slice 状态到 `kind_snapshots`。回放确定性（Aggregate 的 `apply/2` **就是**事件到状态的投影）。
3. **验证对等。** `mix ezagent.aggregate.verify` 任务断言：每个迁移 URI 的 slice-snapshot 状态等于事件回放的 Aggregate 状态。若对等失败，unwind 在此中止（数据保留在事件存储 + SQLite snapshot — 运维检查）。
4. **恢复 GenServer Kind 代码。** 从 git：回滚 per-Phase 把 `Ezagent.Entity.X` 换成 `Ezagent.Aggregate.X` 的代码。旧 `Kind.Server` 从（现已回放好的）snapshot 启动。
5. **保留事件存储数据。** 即使中止，事件保留。未来重启迁移可从同一事件存储开始。

Unwind 每 Aggregate 文档化 + 自动化。代价：运维驱动会话（鉴于投影已是反方向形状，估计 5 个 Aggregate 类全 unwind 1-2 小时）。

---

## 附录 A — 事件存储 schema（Postgres）

标准 `eventstore` 库 schema；文档见 https://hexdocs.pm/eventstore/EventStore.html。表：

- `event_store.events` — append-only 事件日志。
- `event_store.streams` — per-stream 元数据（每 Aggregate UUID = 规范 URI 字符串一个流）。
- `event_store.subscriptions` — 投影器 + saga 订阅状态（重放事件位置）。
- `event_store.snapshots` — aggregate snapshot（Commanded 管）。

Phase 10-A 无需自定义 schema；per-投影表住 SQLite 投影 repo（§4 + §5）。

## 附录 B — 示例命令 + 事件 + aggregate execute 子句

```elixir
# 命令
defmodule Ezagent.Aggregate.User.Commands.GrantCapToUser do
  @derive Jason.Encoder
  defstruct [:user_uri, :workspace_uri, :cap, :granted_by, :idempotency_key]
end

# 事件
defmodule Ezagent.Aggregate.User.Events.CapGrantedToUser do
  @derive Jason.Encoder
  defstruct [:user_uri, :workspace_uri, :cap, :granted_by, :granted_at]
end

# Aggregate execute 子句
defmodule Ezagent.Aggregate.User do
  alias Ezagent.Aggregate.User.Commands.{GrantCapToUser, ...}
  alias Ezagent.Aggregate.User.Events.{CapGrantedToUser, ...}

  @behaviour Commanded.Aggregates.Aggregate

  defstruct [:uri, :workspace_uri, :registered_at, caps: MapSet.new(), destroyed?: false]

  # GrantCapToUser → CapGrantedToUser
  def execute(%__MODULE__{destroyed?: true}, %GrantCapToUser{}),
    do: {:error, :user_destroyed}

  def execute(%__MODULE__{uri: nil}, %GrantCapToUser{}),
    do: {:error, :user_not_registered}

  def execute(%__MODULE__{} = state, %GrantCapToUser{} = cmd) do
    %CapGrantedToUser{
      user_uri: cmd.user_uri,
      workspace_uri: cmd.workspace_uri,
      cap: cmd.cap,
      granted_by: cmd.granted_by,
      granted_at: DateTime.utc_now()
    }
  end

  # apply — 状态变更
  def apply(%__MODULE__{} = state, %CapGrantedToUser{} = ev),
    do: %{state | caps: MapSet.put(state.caps, ev.cap)}

  # ... 其它命令/事件/apply 子句 ...
end

# Router 子句
defmodule Ezagent.CommandedApp.Router do
  use Commanded.Commands.Router

  identify(Ezagent.Aggregate.User, by: :user_uri)
  dispatch([
    Ezagent.Aggregate.User.Commands.GrantCapToUser,
    Ezagent.Aggregate.User.Commands.RevokeCapFromUser,
    ...
  ], to: Ezagent.Aggregate.User)
end

# 派发点（如 EzagentDomainIdentity.Users 中）
def grant_cap(user_uri, cap, granted_by, caller_caps) do
  cmd = %GrantCapToUser{
    user_uri: URI.to_string(Ezagent.URI.parse!(user_uri)),
    workspace_uri: Ezagent.URI.entity_workspace_uri_string(user_uri),
    cap: cap,
    granted_by: granted_by,
    idempotency_key: UUID.uuid4()
  }
  Ezagent.CommandedApp.Dispatch.dispatch(cmd,
    caller: granted_by,
    caps: caller_caps,
    consistency: :strong
  )
end
```

## 附录 C — 参考 URL

- Commanded: https://github.com/commanded/commanded · https://hexdocs.pm/commanded
- EventStore (库): https://github.com/commanded/eventstore · https://hexdocs.pm/eventstore
- commanded_eventstore_adapter: https://hex.pm/packages/commanded_eventstore_adapter
- commanded_ecto_projections: https://hex.pm/packages/commanded_ecto_projections · https://hexdocs.pm/commanded_ecto_projections
- Awesome-Elixir-CQRS (项目清单): https://github.com/slashdotdash/awesome-elixir-cqrs
- Conduit 参考 app: https://github.com/slashdotdash/conduit
- Gift-card-demo: https://github.com/slashdotdash/gift-card-demo
- Segment Challenge: https://github.com/slashdotdash/segment-challenge
- Honeydew CELP 起点: https://github.com/quarterpi/honeydew
- Casavo Phoenix LiveView + ES 工具: https://medium.com/casavo/supercharging-our-event-sourcing-capabilities-with-phoenix-liveview-c4a9d1d4ab99
- "Phoenix LiveView but event-sourced" (cantido): https://dev.to/cantido/phoenix-liveview-but-event-sourced-7pe
- Christian Alexander Phoenix API + Commanded: https://christianalexander.com/2022/05/09/elixir-commanded/
- ElixirMerge ES/CQRS 指南: https://elixirmerge.com/p/comprehensive-guide-to-implementing-es-cqrs-with-eventstoredb-phoenix-and-liveview
- Commanded process managers / sagas: https://hexdocs.pm/commanded/process-managers.html
- Commanded read-model projections: https://hexdocs.pm/commanded/Read%20Model%20Projections.md
- Commanded event upcasting: https://hexdocs.pm/commanded/Commanded.Event.Upcaster.html
- Saga pattern in Elixir (Peter Ullrich): https://peterullrich.com/saga-pattern-in-elixir
