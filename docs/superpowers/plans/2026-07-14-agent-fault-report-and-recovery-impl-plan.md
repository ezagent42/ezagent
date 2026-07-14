# Agent 故障上报与恢复 — Implementation Plan (v6 + main-drift amendment)

**Spec:** `docs/superpowers/specs/2026-07-14-agent-fault-report-and-recovery.md` (v6)
**Order:** P2 → P1 → P3 → P4 → P5 → P6
**Scope:** 通用 agent-fault 机制；首个 `fault_kind` 是 `transport_not_joined`。

## Ground rules

- 判据只能是 shape；不得把 `AuthObservers`、`ParkedDialogWatch`、`CredentialPrecondition.check_materialized/2` 接入 readiness/liveness/fault classification。无凭证 claude 会启 MCP 并发 `initialize`；bridge 为何不 join 未知。
- 豁免只改 delivery，不改 authorization。集合精确为 `pty.write` + `pty.restart`，action 显式 flag，默认 `false`，CI allowlist 钉死。只穿透 `:not_ready` / `:unreachable`；`:failed` 对全部 action 硬闭。`KindRegistry.lookup_kind/1` miss 必须 fail closed。
- cast 豁免仍在同一 `PendingDelivery` URI lock 内并检查 incarnation。
- `ezagent_domain_agent` 仅依赖 core + domain_identity + domain_agent_bridge；只发布事件，不调 domain_session/domain_pty。
- **Option B：** session 不得调用 `Ezagent.Agent.Faults`、扫描/claim/backfill `agent_faults`，也不为此加 #1402 allowlist。domain_agent 产 self-contained durable envelope；session 只拥有 `agent_fault_notification_obligations`。
- #1394 与 fault handoff 必须共用 durable-delivery substrate；本 plan 只固定 producer/envelope/durable-ingest consumer seam，不选择 table/worker/event grammar。该选择 deferred to lead/doc-team review，选择前 P3/P4 不实施 retry machinery。
- `workspace_uri` 使用 `Ezagent.URI.workspace_of/1`；schema 用真实模块 `Ezagent.Ecto.URI`，raw query 显式 `URI.to_string/1`；`:any` 返回 `workspace_scope_required` 并 fail loud。
- arm transport gate **不依赖 DB**；不得在 `with_transition_locks/2` 内做 Faults/Repo I/O。DB 在 timeout 时不可用也不阻止 gate 进 `:unreachable`；durable projection 由 reconciler 重试。
- 不改 `pty.restart` 语义，不碰 #1382、Bug A/B、bridge 病因调查。

## P2 — `:unreachable` + 15-site audit + readiness ownership

### Changes

1. `ReadyGate` 增加 `:unreachable` 类型与 `put/2` guard；timeout 用 `mark_unreachable_locked`，已 buffer cast 进 DLQ，reason `:unreachable`。
2. `settle_join_event_locked` / `drain_pending_then_mark_ready_locked` 接受 `:unreachable`，仍只拒绝 `:failed`；late bind 只能 settle 原 incarnation。
3. 按 SPEC §5 分类并覆盖 15 个 production/support site，含 #15 `test/support/ezagent_template_agent_spawn.ex:131`。修改 9 处必改、3 处应改，为 3 处已正确分支加测试，同步 `Invocation`、`ReadyGate.await/2`、`PendingDelivery.buffer_if_not_ready*` 三个 public spec。
4. 增 CI ratchet：保存 `apps/` + `test/support/` 内已分类 `ReadyGate.await/status` callsite 集合；新增或消失都红。
5. readiness row 写 `{uri, timeout_ms, deadline_unix_ms, generation, incarnation_pid}`；精确 PID + absolute deadline 传给 listener。listener 拥有 timer + monitor，`:DOWN`/timeout 均重读 row 并比较 generation + PID。
6. listener `init/1` 从 ETS 枚举重建所有 timer/monitor；deadline 已过则立即 self-timeout，PID 死/mismatch/unregistered 则 generation-conditional clear。删除 `arm_timeout/3` 的 `Task.start + sleep` fallback；listener 不在则 arm fail loud。

### Gate

- 15 sites 逐一喂 `:unreachable`：无 `CaseClauseError`，#15 fail loud，callsite set 漂移使 ratchet 红。
- `:unreachable` + 当前 incarnation bind → `:ready`；换回只 settle `:not_ready` 时测试红。旧 incarnation bind 不恢复新 gate。
- `:unreachable` cast 不 buffer；到界时原 buffer 全部 DLQ。`await/2` / `Identity.await_ready/2` 立即返回。
- 优雅退出、崩溃、`Process.exit(pid, :kill)` 后 row 均清理。杀 listener 但保留 ETS owner/Kind，新 listener 按原 deadline/PID 重建并正常 timeout/clear。

## P1 — 豁免契约 + metadata cache consistency

### Changes

1. action metadata 加显式 delivery-exemption flag，默认 false；只标 `pty.write` / `pty.restart`。
2. 权威链为 `URI.behavior_action` 取 action → `KindRegistry.lookup_kind` 取 kind → `BehaviorRegistry.lookup` → `__actions__` metadata。不信 URI behavior prefix。lookup miss 返普通硬门结果并发 `gate_exemption_metadata_missing` telemetry。
3. 在 `CapabilityRegistry.register/3`/`unregister/3` 这个真实 chokepoint 维护 ExemptionCache，含 plugin unload。一把 node-local metadata mutation lock 包住三表序列。
4. register 顺序 Subjects → BehaviorRegistry → ExemptionCache；异常时反序 compare-delete 本 behavior 写入。unregister 顺序 ExemptionCache → BehaviorRegistry → Subjects，全部 compare-delete，迟到 unload 不得删 replacement。
5. sync/cast 两条 dispatch 路径只在 `:not_ready`/`:unreachable` 应用 flag；`:failed` 不查豁免即硬闭；cap check 不变。

### Gate

- 两个 action 在 `:not_ready`/`:unreachable` 且 incarnation 当前时到 handler；`:failed`、destroyed、stale incarnation 仍拒绝。
- 无权调用仍 `:unauthorized`；`publish_cr`/`reconfigure`/`apply_config_delta`/`delete`/`agent.receive` 仍被门挡。
- registry miss 在 `:not_ready`/`:unreachable` 对两个 action fail closed + telemetry；terminate 的 `:failed` miss 窗口仍硬闭。
- 每个注入异常点无 half-installed exemption；replacement race 不被迟到 compare-delete 清理；unregister 先移除 cache。第三个 exempt action 使 CI allowlist gate 红。

## P3 — durable `agent_faults` + lazy fencing

### Changes

1. migration 建一行/agent 的 CAS 状态表：`agent_uri` PK、`workspace_uri` NOT NULL、`fault_epoch`、`status` open/resolved、`fault_kind`、timestamps、observations。永不 DELETE；**不含** `handler_uri`/`notified_epoch`。另建内部 `agent_fault_epoch_counters(agent_uri PK, last_epoch)`，只负责分配，绝不改 fault state。Context 为 `Ezagent.Agent.Faults`，仅 domain_agent 使用。
2. **arm 无 DB**；arm row 不含 epoch。timeout 在现有 lock 内只做 generation/incarnation 检查 + `:unreachable` transition，锁内无 Repo/Faults 调用。
3. timeout 后或 workspace-owner source reconciler 在锁外从独立 counter row 原子 allocate epoch；再短暂进 lock，仅当 generation/PID/gate 仍匹配时 conditional attach；被 supersede 的 epoch 只留 counter gap，不得改 `agent_faults`。锁外用 `excluded.fault_epoch > existing.fault_epoch` CAS open 同 epoch，写前/写后都重读 armed row + gate；失配按 epoch 立即 resolve。
4. 明确不需要 epoch allocation 与 arm-row insertion 原子：`{generation, incarnation_pid}` 线性化 node-local row，epoch 只 fencing durable writers。
5. DB 在 timeout 时不可用：gate 仍 `:unreachable` + loud log/telemetry；不做无 fencing 写入。source reconciler 固定周期重试 allocate→attach→open。
6. workspace scope 使用 `Ezagent.URI.workspace_of/1` + `Ezagent.Ecto.URI`；`:any` 是 `workspace_scope_required` + telemetry/log，DB 不落 row。observations 只存 shape，不存 credential/screen diagnosis。
7. successful open/resolve 产 self-contained typed envelope，经 #1394 shared durable-delivery seam enqueue；payload 足以让 session 永不回读 `agent_faults`。P3 不建 fault-specific sweeper/backoff worker。

### Gate

- Repo down 时 arm 成功，spawn 路径无 Repo 调用；静态 gate 拒绝 transition lock 内 DB I/O。
- generation A timeout 的 allocator 被阻塞时 re-arm B 并让 B open；放行 A 后其 epoch 不得附着 B、改动 B row、open/通知 A。将 allocator counter 合并回 fault state row 的 sabotage 必须红。
- timeout 期 Repo down 仍 `:unreachable`；Repo 恢复且无 PubSub 时 reconciler 最终建 open row。
- timeout open 被阻塞 → settle → 放行 open；写后门必须 resolve 且零通知。旧 epoch 不覆盖新 epoch；VM/node 变更后 epoch 仍单调。
- schema/raw 两路 workspace URI 形状正确；`:any` fail loud 且无 row。

## P4 — Option B durable handoff + session-owned notification obligation

### Changes

1. PubSub 只是 wakeup hint。durable envelope 含 `agent_uri/workspace_uri/fault_kind/fault_epoch/state/occurred_at/observations`，dedup `{agent_uri, fault_epoch, state}`。timeout 不直接 notify。
2. domain_agent source reconciler 启动即跑、固定周期跑、事件到达时提前跑。只有 workspace-owner node 解释 local gate/armed row；为无 epoch 的 `:unreachable` row 重试 P3 协议，为已有 epoch 的缺失 open row backfill，`:ready` resolve，`:not_ready` 不建 fault。
3. shared substrate 重投 envelope，直到 session ingress 幂等写入 `agent_fault_notification_obligations` 并 durable-ack。该表 natural key `{agent_uri, fault_epoch}`，持有 envelope、state、`handler_uri`、claim/status、attempts/next retry/timestamps；属于 domain_session。
4. session notification reconciler **只扫 obligation table**，解 owner、原子 claim、notify；失败重试，成功 applied。resolved 覆盖/抑制同 epoch opened。禁止任何 `Ezagent.Agent.Faults` call 或 raw `agent_faults` query。
5. owner resolution 用显式 service，不公开 `CredentialNotifier` 私有函数。`:no_owner` loud log + telemetry。通知只有现状 + 终端入口，无硬编码补救指令。
6. retry/backoff/recovery trigger/attempt accounting 必须复用 #1394 substrate；具体物理机制 deferred to lead/doc-team review，不在本 plan 预选。

### Gate

- 抛弃 PubSub/重启 producer+consumer，shared substrate 仍最终 durable-ingest obligation，每 epoch 恰好通知一次。
- 非 workspace-owner node 的 local gate 不改 shared row。listener 遇不存在/已 resolved row 跳过。
- owner 收到通知前 obligation 的 `handler_uri` 已回填；`:no_owner` 进运维信号；通知无指令；domain_agent 无 domain_session 调用。
- architecture experiment：Session fixture 中任一 `Ezagent.Agent.Faults.*`/raw `agent_faults` read-write 必须 RED；obligation-only path GREEN。
- inventory gate/review 证明 cap/fault 没有两套 retry scheduler。resolved-before-open reorder 零通知。

## P5 — Delivery 错误可归因

将 catch-all 改为 `:ok` delivered、`{:error, reason}` dropped trace + reason telemetry/rate-aware log、`other` loud unexpected trace。Gate：`:failed`、`:unreachable`、`:unauthorized`、`:cross_workspace_denied`、`:no_such_actor`、`:activate_timeout` 均留痕；意外返回 loud 但不崩。

## P6 — World UI + invariants + architecture gate

- World 按开放 `fault_kind` 展示 `agent_faults` 并给终端入口。
- invariants：exemption set 恰好等于 allowlist；`:unreachable` 可 bind-settle；`:failed` 全 action 硬闭；15-site callsite ratchet；arm path 无 Repo/lock 内 DB I/O；plugin locality/WorkspaceOwnerGate 不绕过。
- arch gate anchor 防新的 readiness bypass。完整 CI 与 SPEC §13 falsifier 全绿。

## Definition of Done（闭集）

1. `:unreachable` 完成 15-site 分类 + ratchet + 3 specs；无 dispatch `CaseClauseError`；late bind 只 settle 原 incarnation；row 在 listener restart/全部 Kind 死法下正确重建或清理。
2. exemption 恰好 `pty.write` + `pty.restart`，只穿 `:not_ready`/`:unreachable`，`:failed` 硬闭，auth 不变，stale/miss fail closed，三表缓存协议在异常/unload/replacement 下一致。
3. arm 无 DB，spawn 不依赖 Repo，transition locks 内无 DB I/O。timeout 后 lazy DB epoch 在锁外 allocate、generation/PID-conditional attach、锁外 open + re-read；DB down 不阻止 `:unreachable`，reconciler 可恢复。
4. `agent_faults` 永不 DELETE，DB epoch 跨 VM/node 单调，旧/烧掉 epoch 不覆盖新 generation，settle/open race 不复活故障；workspace scope 形状和 `workspace_scope_required` 契约正确。
5. PubSub 只 wakeup；shared #1394 durable-delivery seam + session-owned obligation 提供 durable processing。session 不读写 `agent_faults`，claim/handler/retry 全在 obligation；timeout 不直接 notify，`:no_owner` loud，通知无补救指令，domain_agent 不调 session。
6. Delivery 全部错误可归因，保留 loud unexpected branch；World 显示故障 + 终端入口。
7. exemption/cache/callsite/arm-no-DB/workspace-owner invariants 与 arch gate 就位；Option B boundary experiment 会拒绝 Session→`Ezagent.Agent.Faults`；SPEC §13 每个 falsifier 都有会红的测试。

## Deferred lead/doc-team gates and lockability

- #1394 unified durable-delivery physical mechanism: deferred; P3/P4 implementation waits.
- §12-bis-B cap revoke drop option 1/2/3: deferred. This plan makes **option 2 cheapest** because P3/P4 already target the shared substrate, but does not select it.
- Verdict after three-doc cross-check: **NOT LOCKABLE for implementation** until both review decisions are recorded. Option B itself is normative and no longer open.

## Explicitly out of scope

Any diagnosis; bridge non-join cause; B/C/D classifiers; `pty.restart` semantics; #1382; Bug A/B.

## Final lockability verdict（written after three-doc cross-check）

**Option B is LOCKED; the implementation package is NOT LOCKABLE yet.** SPEC、plan、handoff 已核对一致；只剩 lead/doc-team 拥有的 #1394 physical-unification mechanism 与 §12-bis-B cap-revoke option 1/2/3 两项决定。两项落文档后才可改判 LOCKABLE。
