# Codex Handoff — Agent 故障上报与恢复 (v6 + main-drift amendment)

**Spec:** `docs/superpowers/specs/2026-07-14-agent-fault-report-and-recovery.md` (v6 + amendment, **NOT LOCKABLE for implementation**)
**Plan:** `docs/superpowers/plans/2026-07-14-agent-fault-report-and-recovery-impl-plan.md` (v6 + amendment; P2→P1→P3→P4→P5→P6)
**Target branch:** `fix/agent-fault-report-and-recovery`

## Mission

先停在 P3/P4 durable-delivery 实现门前：lead/doc-team 必须先决定与 #1394 共用的物理机制及 §12-bis-B cap-revoke 选项。决定落文档后，严格按 amended SPEC + plan 的 bounded phases 实施。不得从旧版恢复 session 扫 `agent_faults` 的机制。

## 不可 re-litigate（v6 spec-locked）

1. **不诊断，只看 shape。** 不得把 `AuthObservers`、`ParkedDialogWatch`、`CredentialPrecondition.check_materialized/2` 接入 readiness/liveness/fault classification。无凭证 claude 已实测启动 MCP 并发 `initialize`；「无凭证 ⇒ bridge 不 join」是假的，真正病因未知。日志、通知、注释不得伪装知道。
2. **豁免只改 delivery，不改 authorization。** 集合精确为 `pty.write` + `pty.restart`；action 显式 flag，默认 false；CI allowlist 多一个就红。仅穿透 `:not_ready` / `:unreachable`；`:failed` 对所有 action 硬闭。
3. **豁免依然 fencing incarnation。** cast 路径留在同一 `PendingDelivery` URI lock 内并检查 expected PID。`KindRegistry.lookup_kind/1` miss 统一 fail closed + telemetry；不信 URI behavior prefix。
4. **豁免缓存一致性按 SPEC §6.6。** 真实 chokepoint 是 `CapabilityRegistry.register/3`/`unregister/3`。metadata mutation lock 包三表；register 按 Subjects→BehaviorRegistry→cache，unregister 反向；反序补偿 + compare-delete 防 half install/迟到 unload 误删 replacement。
5. **`:unreachable` 是 15-site audit，不是人工声称的小补丁。** 包括 #15 `test/support/ezagent_template_agent_spawn.ex:131`，9 处必改 + 3 处应改 + 3 处测试钉住 + 3 public specs + classified-callsite CI ratchet。集合新增或消失都要审计。
6. **readiness projection 可重建。** arm row 线程化 exact incarnation PID + absolute deadline。listener 拥有 timer/monitor，`init/1` 从 ETS 重建；`:DOWN`/timeout 比较 generation + PID。删掉 `arm_timeout/3` Task/sleep fallback；listener 不在则 arm fail loud。late bind 只 settle 原 incarnation。
7. **arm 不需要 DB，spawn 不依赖 Repo。** `require_transport_join/2` 在 `PendingDelivery.with_lock/2` + `:global.trans/4` 内做 arm row transition（transport_readiness.ex:57-90,507-523）；临界区内禁止 Faults/Repo I/O。CC `ensure_pty_server/4` 在启 PTY 前 arm（spawn.ex:442-443），Repo down 不得阻止这条路径。
8. **durable `fault_epoch` 在 timeout 后锁外惰性分配。** timeout 锁内只做 generation/incarnation 检查 + `:unreachable`；锁外从独立 `agent_fault_epoch_counters` row allocate epoch，再用 generation/PID/gate 条件附着到 readiness row，锁外用 epoch-greater CAS open + 写后重读。allocator 不得改 `agent_faults`，因此 superseded epoch 只留 counter gap，不能关闭/改标较新 fault。没有路径需要 epoch allocation 与 arm insert 原子。
9. **DB failure 不撤销 shape verdict。** timeout 时 Repo down，gate 仍 `:unreachable` + loud log/telemetry；不降级为无 fencing durable write。workspace-owner source reconciler 周期重试 allocate→attach→open。
10. **Option B；不许从 #1402 门下钻。** domain_agent owns `agent_faults` 并产 self-contained durable envelope；session 永不调用 `Ezagent.Agent.Faults`、raw query/claim/backfill `agent_faults`，也不为这条新边加 allowlist。session owns `agent_fault_notification_obligations`，owner resolution、claim、handler、notify/retry 全在该表。
11. **durable processing 不靠 PubSub。** PubSub 只 wakeup hint；fault handoff 与 #1394 必须共用 durable-delivery substrate，直到 session durable-ingest obligation 才 ack。不得各建一套 sweeper/backoff/recovery loop。物理机制 deferred to lead/doc-team review。
12. **resolved envelope 抑制通知。** 同 `{agent_uri, fault_epoch}` 的 opened/resolved 可重排；session obligation 幂等折叠，resolved 后零 notify，不得回读 agent row 修补。
13. **WorkspaceOwnerGate 决定 cluster truth。** 只有 workspace-owner node 可用 local ReadyGate/readiness row 推进 shared fault row；`:any` workspace 返回 `workspace_scope_required` 并 fail loud。非 owner/无 armed row 不得猜测。
14. **分层不变。** `ezagent_domain_agent` deps = core + domain_identity + domain_agent_bridge；只发布 envelope，不调 domain_session/domain_pty。session 用显式 owner-resolution service，不公开 `CredentialNotifier` 私有函数。
15. **URI 持久化形状。** `workspace_of/1` 给 `%URI{} | :any`；schema 用 `Ezagent.Ecto.URI` (`ecto/uri_type.ex`)，raw SQL 用 `URI.to_string/1`；不存 NULL/`"any"`/裸 workspace name。
16. **通知零补救指令。** 只说 shape 现状并给终端入口。`:no_owner` loud log + telemetry。
17. **Delivery catch-all 不裸删。** 显式 `{:error, reason}` trace/telemetry/rate-aware log，加 loud `other` branch。
18. **不碰** `pty.restart` 语义、#1382、Bug A/B、bridge 不 join 病因。

## Execution order and phase gates

- **P2:** 15 sites + ratchet、`:unreachable` settle/incarnation、listener timer/monitor reconstruction + brutal-kill cleanup。
- **P1:** exact two-action exemption、authorization/stale/miss hardening、三表缓存异常/unload/replacement tests。
- **P3:** state table + `Ezagent.Ecto.URI`、arm-no-DB static/runtime gates、lazy epoch race tests、Repo-down timeout/recovery test。
- **P4:** #1394 shared durable handoff + session-owned obligation reconciler/claim，PubSub-loss/restart/reorder/no-owner/layering tests；Session→`Ezagent.Agent.Faults` fixture 必须 RED。
- **P5:** 全 reason dropped trace + loud unexpected branch。
- **P6:** World fault list + terminal entry，invariants/arch gate，SPEC §13 falsifier 全部对账。

## Return contract

当前先返回两项 lead/doc-team 决策，不实施 P3/P4 retry machinery。解锁后按 plan 的 7 条闭集 DoD 返回：每 phase Gate 证据、SPEC §13 falsifier 映射、完整 CI 日志、rebase base SHA、尚未解决风险。不得以 PubSub 测试代替 durable-ingest 测试，不得以人工 callsite 计数代替 ratchet，不得自行宣布可合 main。

## Deferred review / lockability

- 共用 #1394 durable-delivery 的 table/module/event grammar：lead/doc-team 决定。
- inherited cap-revoke drop 的选项 1/2/3：lead/doc-team 决定；Option B 使 **选项 2 最便宜**，但未选择。
- 三文档一致 verdict：**NOT LOCKABLE for implementation**；Option **B** boundary 已锁定。

## Grounding index

`transport_readiness.ex:57-90,131-165,319-366,370-401,507-523` · `transport_readiness_listener.ex:33-50,63-66,75-125` · `spawn.ex:442-443` · `ecto/uri_type.ex:1,23-26,69-73` · `invocation.ex:188,218,261,321-326` · `ready_gate.ex:134-159` · `pending_delivery.ex:62,82,107` · `test/support/ezagent_template_agent_spawn.ex:131` · SPEC §5, §6.5-§6.6, P2-a, P3-b, P4, §11, §13.

## Final lockability verdict（written after three-doc cross-check）

**Option B is LOCKED; the implementation package is NOT LOCKABLE yet.** SPEC、plan、handoff 已核对一致；只剩 lead/doc-team 拥有的 #1394 physical-unification mechanism 与 §12-bis-B cap-revoke option 1/2/3 两项决定。两项落文档后才可改判 LOCKABLE。
