# Notification + Log Systems Audit — 2026-05-24

> Read-only audit. No production code touched.
> Triggered by Allen: "当前通知机制有提供统一接口吗？通知系统是否和 Log 系统为一套系统（应该是一套系统吗）？"

## Summary verdict

1. **Unified notification entry exists** but is **brand new (PR-C, 2026-05-23) and partially adopted**: `Ezagent.Notifications.notify/3` is the cap-gated single entry, but only **one** producer has migrated to it (chat `:receive` for User Kind), and the **legacy raw `Phoenix.PubSub.broadcast` to the same topic still fires in parallel** ("transition window"). No CI gate forbids a new producer from skipping the helper.
2. **Notifications and Logs are TWO separate systems today**, with different shapes, sinks, and cap models. They share the underlying `Phoenix.PubSub`, but they share nothing else.
3. **They should NOT become one system.** Different audiences (humans vs operators), different durability (in-flight vs SQLite history), different cap models (per-user inbox vs system-wide observability), different blast radius on failure. But they **should share three things** they don't share today: (a) telemetry as the spine, (b) a documented "which topic for what" map, and (c) the unified-helper-or-CI-gate enforcement story.

The deepest finding: **the Notifications module exists but doesn't yet meet P3 (single source of truth) or P6 (completion claim requires invariant test)**. It's a helper, not a chokepoint.

---

## Section 1 — Current Notification system

### Modules + responsibilities

| Module | File:line | Role |
|---|---|---|
| `Ezagent.Notifications` | `apps/ezagent_core/lib/ezagent/notifications.ex:1` | Unified user-inbox primitive (`notify/3`, `subscribe/2`, `unsubscribe/1`, `topic/1`). |
| `Ezagent.Behavior.Notifications` | `apps/ezagent_core/lib/ezagent/behavior/notifications.ex:1` | Cap-only Behavior; subjects `:notify` and `:subscribe`. `dispatchable?: false` — cannot be invoked via `Invocation.dispatch/1`. |
| `Ezagent.Behavior.Chat` (producer) | `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:269` | Only current caller of `Ezagent.Notifications.notify/3`. |
| `EzagentPluginLiveview.AdminLive` (consumer) | `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:245` | Receives `{:notification, user_uri, payload}` envelope (currently no-ops it — the parallel legacy `:chat_message` still feeds the stream). |
| Registration | `apps/ezagent_core/lib/ezagent_core/application.ex:186-187` | `CapabilityRegistry.register(User, :notify, NB)` + `(User, :subscribe, NB)`. **Only on `User` Kind.** |

### API surface

Producers:
```elixir
Ezagent.Notifications.notify(user_uri, %{type: :atom, body: map, source: module, dedup_key: opt_binary}, ctx \\ %{caps: :system}) :: :ok
```
- Validates shape (`:type`/`:body`/`:source` required) — `ArgumentError` on bad shape (`notifications.ex:134-143`).
- Cap check via `CapabilityRegistry.needed_for(User, :notify, uri)` — `:system` bypass; otherwise needs a matching `Capability` (`notifications.ex:145-160`).
- Broadcasts `{:notification, user_uri, notification}` on `esr:user:<uri>:events`.

Consumers:
```elixir
Ezagent.Notifications.subscribe(user_uri, ctx) :: :ok    # cap-gated :subscribe
Ezagent.Notifications.unsubscribe(user_uri)    :: :ok    # no cap (only own pid)
Ezagent.Notifications.topic(user_uri)          :: String.t()
```

### Delivery channels

| Path | Mechanism | File:line |
|---|---|---|
| The "primitive" path | `Phoenix.PubSub.broadcast(EzagentCore.PubSub, "esr:user:<uri>:events", {:notification, uri, %{...}})` | `notifications.ex:94-99` |
| Legacy parallel path (still firing) | `Phoenix.PubSub.broadcast(EzagentCore.PubSub, "esr:user:<uri>:events", {:message_received, msg})` | `chat.ex:261-265` |
| External plugin mirror (Feishu) | NOT a notification — separate `:notify_external` Behavior dispatched per-Session via `Invocation.dispatch/1` | `chat.ex:231` → `feishu_outbound.ex:78` |

There is **only one URI type** routed: `entity://user/...`. Agents do not have an inbox (`notifications.ex:162-168` raises `ArgumentError` for non-user URIs); inbound to agents goes through `chat.receive` → `BridgeRegistry` → `send(channel_pid, ...)` (`chat.ex:327`).

### Cap gating

| Action | Subject Kind | Cap shape | Bypass |
|---|---|---|---|
| `:notify` | `Ezagent.Entity.User` | `%Capability{kind: :user, behavior: Ezagent.Behavior.Notifications, instance: <uri or :any>, workspace_uri: ...}` | `ctx.caps == :system` |
| `:subscribe` | `Ezagent.Entity.User` | same shape, action `:subscribe` | `ctx.caps == :system` |

**No "deny anonymous PubSub subscribers" guarantee**: `Phoenix.PubSub.subscribe(EzagentCore.PubSub, "esr:user:<uri>:events")` from anywhere in the BEAM is uncheckable — the cap gate only applies to callers of the helper. A rogue plugin can subscribe directly with no cap check. P14 dispatches go through `Invocation.dispatch/1`; notifications go through `Phoenix.PubSub` and inherit PubSub's "no auth at the topic" property.

### Tests

`apps/ezagent_core/test/ezagent/notifications_test.exs` — 8 tests covering broadcast shape, cap gating (granted + denied), shape validation, non-user URI rejection, topic format. Good for the helper API. **None** verify "every notification site goes through the helper" (the actual P3 invariant).

---

## Section 2 — Current Log / Audit system

The system is actually **four distinct subsystems** with overlapping semantics:

### 2.1 Modules + responsibilities

| Module | File:line | Role |
|---|---|---|
| `Logger` (Erlang `:logger` + Elixir Logger) | scattered (118 call sites) | Free-form text logs → BEAM logger backends → file / stderr / phx.log |
| `Ezagent.Audit` (telemetry handler) | `apps/ezagent_core/lib/ezagent/audit.ex:1` | Subscribes to 8 telemetry events; fans out to PubSub + Audit.Writer |
| `Ezagent.Audit.Writer` | `apps/ezagent_core/lib/ezagent/audit/writer.ex:1` | Async batch writer; 100ms flush / 500 row max → `EzagentCore.Repo.insert_all("invocations", ...)` |
| `Ezagent.CCEvents` | `apps/ezagent_core/lib/ezagent/cc_events.ex:1` | CC-side error report path: HTTP webhook → PubSub `cc_events:stream` + telemetry `[:ezagent, :cc_bridge, :event]` (which Audit then persists) |
| `Ezagent.DLQ` | `apps/ezagent_core/lib/ezagent/dlq.ex:1` | Dead-letter table for unroutable/exception/dup invocations; sync `Repo.insert_all` + telemetry `[:ezagent, :dlq, :write]` |
| `EzagentPluginLiveview.AdminAuthzAuditLive` | `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_authz_audit_live.ex:1` | Per-LV-pid `:telemetry.attach` for `[:ezagent, :authz, :granted/:denied]` — live operator stream |
| `EzagentPluginLiveview.ObservabilityLive` | `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/observability_live.ex:1` | `/admin/logs` page; pulls audit rows from SQLite + subscribes to `Ezagent.Audit.stream_topic()` |
| `EzagentWeb.Telemetry` | `apps/ezagent_web/lib/ezagent_web/telemetry.ex:1` | Phoenix/Repo/VM `Telemetry.Metrics` definitions; only `:telemetry_poller` is wired — no reporter, so the metrics aren't exported anywhere today |
| `Ezagent.StressMetrics` | `apps/ezagent_core/lib/ezagent/stress_metrics.ex:74` | Stress-test counters via `:telemetry.attach_many` (test-only) |

### 2.2 API surface

Producers fall into three patterns:

**Pattern A — `Logger.{info,warning,error,debug}`** (118 sites). Free-form binary text. Examples:
- `apps/ezagent_domain_pty/lib/ezagent_domain_pty/server.ex:333` (info)
- `apps/ezagent_core/lib/ezagent/audit/writer.ex:85` (error)
- `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:346` (warning — silent-drop alert; aligns with P27)

**Pattern B — `:telemetry.execute(event_name, measurements, metadata)`** at 13 production sites. Examples:
- `apps/ezagent_core/lib/ezagent/kind/runtime.ex:88,108,148,151,206` — `[:ezagent, :invoke, :stop/:error]`, `[:ezagent, :authz, :granted/:denied]`, `[:ezagent, :workspace, :denied]`
- `apps/ezagent_core/lib/ezagent/kind/snapshot.ex:202,213,251` — `[:ezagent, :persistence, :restored/:written/:failed]`
- `apps/ezagent_core/lib/ezagent/dlq.ex:45` — `[:ezagent, :dlq, :write]`
- `apps/ezagent_core/lib/ezagent/cc_events.ex:51` — `[:ezagent, :cc_bridge, :event]`
- `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:353` — `[:ezagent, :chat, :receive, :dropped]` (NOT in `@events` of Audit — so this telemetry event has no audit row today)

**Pattern C — Direct table writes**:
- `Ezagent.DLQ.put/2` → `dlq` table (sync)
- `EzagentCore.Repo.insert_all("invocations", ...)` from Writer only

Consumer side:
- `Audit` listens to 8 telemetry events → `invocations` SQLite + `esr:audit:stream` PubSub
- `AdminAuthzAuditLive` listens to 2 telemetry events directly (in addition to Audit's general listen) per-LV-pid
- `ObservabilityLive` reads `invocations` table on tab open (no live stream — refreshes on tab switch)
- `Phoenix.LiveDashboard` (dev only) — `apps/ezagent_web/lib/ezagent_web/router.ex:192`

### 2.3 Delivery channels

| Sink | Topic / location |
|---|---|
| BEAM stderr / `phx.log` | All `Logger.*` calls (default backend) |
| `EzagentCore.Repo` `invocations` table | `Audit.handle_event/4` → `Writer.handle_cast/2` async batched |
| `EzagentCore.Repo` `dlq` table | `DLQ.put/2` sync |
| `EzagentCore.Repo` `kind_snapshots` table | `Ezagent.Kind.Snapshot` (storage; not log per se but observability-adjacent) |
| `esr:audit:stream` PubSub | `Audit.handle_event/4` → `AdminLive` (discarded) / `ObservabilityLive` (TODO — not wired live yet) |
| `cc_events:stream` PubSub | `CCEvents.report/1` → `AdminLive:183` (ring buffer of 20) |
| Direct per-pid telemetry handler | `AdminAuthzAuditLive.on_authz_event/4` (in emitter's process) |

### 2.4 Cap gating

**None of the audit/log path is cap-gated.**

- `Logger` — no caps (impossible; it's Erlang infra)
- `:telemetry.execute` — no caps (anyone in the VM can emit)
- `Ezagent.Audit.attach/0` runs once at boot; no per-event check
- `Audit.Writer` accepts any cast (no auth)
- `Ezagent.DLQ.put/2` — no cap check
- `ObservabilityLive` reads ALL audit rows regardless of viewer's workspace; only the `:logs` admin route is admin-gated (`router.ex` `:admin_only` pipeline) — NOT cap-checked at the query level
- `AdminAuthzAuditLive` has `if Map.get(socket.assigns, :is_admin?)` guard (`admin_authz_audit_live.ex:46`)

The audit row DOES carry `workspace_uri` (`audit.ex:107`, PR-6 of Phase 9), so per-workspace filtering is POSSIBLE — just not enforced today.

### 2.5 Tests

CI gates that enforce audit invariants:
- `apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.ex:176-200` — Invariant #6: `audit.ex` may not write SQLite directly (grep `EzagentCore.Repo.(insert|update|delete)|exqlite`).
- Same task #1: `PubSub.broadcast` allowlisted to `audit.ex` + `invocation.ex` + `behavior/chat.ex`.

Neither gate enforces "every `Logger.*` is paired with appropriate telemetry" or "every silent-drop has a log line" (P27 is policy, not gate).

---

## Section 3 — Comparison

| Aspect | Notifications | Logs / Audit |
|---|---|---|
| Producer API | `Ezagent.Notifications.notify/3` (one site) | `Logger.*` (118 sites) + `:telemetry.execute/3` (13 sites) + `DLQ.put/2` |
| Subscription mechanism | `Ezagent.Notifications.subscribe/2` (cap-gated) | `Phoenix.PubSub.subscribe(audit_stream_topic)` (no cap) + `:telemetry.attach` (no cap) + direct SQL queries |
| Delivery mechanism | `Phoenix.PubSub.broadcast` only (in-flight, lost if no subscriber) | PubSub (in-flight) + SQLite (durable) + BEAM logger backends |
| Persistence | **None** — `Phoenix.PubSub` doesn't buffer | `invocations` table (~indefinite) + `dlq` table + `phx.log` |
| Cap-gating | Yes (per-user `:notify`/`:subscribe`) | None — admin route gate only |
| Audience | Single User entity (per-URI inbox) | Operators / admin LV / SREs |
| Schema | Typed map `%{type, body, source, ?dedup_key}` | Loose: telemetry meta map + free-form `Logger` text + structured DB row |
| URI scope | Only `entity://user/...` | Any URI string in `caller`/`target` columns |
| Plugin extensibility | Plugin calls `Ezagent.Notifications.notify` directly (no Behavior dispatch path) | Plugin emits `Logger.*` freely + can `:telemetry.execute` arbitrary event names (nothing whitelists them) |
| Failure semantics | Lost silently if no subscriber (PubSub property) | `Logger` always flushed; SQLite write retries on next batch (`writer.ex:85`); DLQ for invocation-level drops |
| Invariant test | None covering "all sites go through helper" | Gate #6 ("audit.ex has no Repo write") + Gate #1 ("PubSub.broadcast allowlist") |
| Telemetry presence | None — bypasses the spine | Yes — telemetry IS the spine for audit |

The **single biggest structural difference**: audit is built on telemetry as a single fan-out spine (P19's third rule: "Each `dispatch/1` emits `:start`, `:stop`, `:exception` telemetry"). Notifications bypasses telemetry entirely — its broadcast is invisible to `Audit`, to `LiveDashboard`, to any future trace exporter.

---

## Section 4 — Should they be one system?

### Arguments for unification

1. **Both are "an event happened → fan out to subscribers"** — a single primitive could serve both with subscriber filtering.
2. **Both share a transport (`Phoenix.PubSub`)** — and audit already shows the pattern (PubSub + persistence + cap layer).
3. **OpenTelemetry's model** treats Logs / Events / Metrics / Traces as one telemetry pipeline with different semantic conventions per signal — converging now matches where the industry is going.
4. **Allen's P7 ("converge multi-modal inputs to a flat URI list")** is the meta-principle: if both reduce to `event_emitted(uri, payload, ctx)`, they're constructors over one shape.

### Arguments against unification

1. **Different audiences with different SLA needs.**
   - User inbox needs ordered delivery, dedup, durability across reconnects (eventually), per-user `read` state — a chat-app shape.
   - Operator logs need bulk read, indexed grep, workspace scoping, append-only retention — a SQL/SIEM shape.
   Forcing one schema serves neither well.
2. **Cap model is fundamentally different.**
   - Notification: viewer is the SUBJECT (only `user_uri` themselves + delegated `:subscribe` cap-holders see it).
   - Audit: viewer is an OPERATOR (admin/SRE; sees across users — workspace scope is the boundary, not per-user).
   A "unified system" must implement BOTH cap models simultaneously, which is a more complex thing than two purpose-built systems.
3. **Blast radius asymmetry.**
   - Notification system down → users miss in-app pings (annoying, recoverable via reload).
   - Log/audit system down → operators blind during the very incident they need to debug (catastrophic).
   Coupling the two means a notification volume spike (e.g. a chat broadcast storm) impacts operator observability.
4. **P8 ("less invented, more assembled").** A unified "Events" abstraction is one new concept developers must learn. Today, notification = "use the helper"; audit = "emit telemetry"; both reuse OTP/Elixir idioms. Inventing `Ezagent.Events` to subsume both ADDS concepts.
5. **Industry split is real.** OpenTelemetry unified logs+traces+metrics but kept "notifications" entirely outside its scope — notifications belong to product/UX, telemetry belongs to operations. Apple/Android push, Slack/Discord, Sentry/Datadog all treat them as separate layers.

### Recommended model

**Keep two systems. Tighten BOTH around telemetry as the SHARED spine.** Specifically:

1. **Notifications system stays its own primitive** (`Ezagent.Notifications`) for the User-inbox use case. Closes the open invariant by adding a CI gate + emitting telemetry on every `notify/3` call.
2. **Logs system stays as-is** (Logger + telemetry + Audit + ObservabilityLive). Already mature.
3. **Add the missing edge: every `Notifications.notify/3` emits a telemetry event** (`[:ezagent, :notification, :emitted]`) so the audit pipeline sees it for free. This gives operators the "what did the user see?" cross-reference WITHOUT coupling the storage / cap models.

This makes telemetry the unified observability spine (which Allen's architecture already commits to via P19) while keeping the two product surfaces appropriately separated.

---

## Section 5 — Findings

### Finding 1 — Notifications primitive isn't a chokepoint (P3 violation)

- **Severity: HIGH**
- **What:** `Ezagent.Notifications.notify/3` is documented as "the unified entry" but is only called from ONE site (`chat.ex:269`). The legacy raw `Phoenix.PubSub.broadcast` to the **same topic** still fires from `chat.ex:261` ("transition window"). Any new producer can copy the legacy pattern and skip the helper — no CI gate exists.
- **Where:** `apps/ezagent_core/lib/ezagent/notifications.ex:1`, `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:261-277`
- **Why it matters:** P3 says SoT means "other surfaces are caches/projections, never independent records." Today the topic has TWO independent producers writing two different envelope shapes (`{:message_received, msg}` and `{:notification, uri, payload}`), and subscribers must pattern-match both — exactly the "silent divergence" failure mode P3 prevents.
- **Recommendation:** (1) Delete the legacy broadcast `chat.ex:261-265` after migrating any remaining subscribers (V2 deprecation noted in `chat.ex:258`). (2) Add an invariant test: grep `apps/*/lib` for `Phoenix.PubSub.broadcast.*esr:user:` outside `notifications.ex` — must be empty. (3) Same allowlist style as Audit's check_invariants #1.

### Finding 2 — Subscribers can bypass the cap gate

- **Severity: MEDIUM**
- **What:** `Ezagent.Notifications.subscribe/2` is cap-gated, but the underlying `Phoenix.PubSub.subscribe(EzagentCore.PubSub, "esr:user:<uri>:events")` is uncheckable. Any BEAM process can subscribe to any user's inbox without holding `:subscribe` cap.
- **Where:** `apps/ezagent_core/lib/ezagent/notifications.ex:112-118`
- **Why it matters:** The cap check is a code-discipline gate, not a structural one. A plugin that subscribes directly works fine in tests + dev but silently leaks per-user notifications. Future external transports (browser tab, mobile push) will hit this when they get plumbed through Phoenix.Channels.
- **Recommendation:** Either (a) document the "use the helper" rule explicitly in the moduledoc + add the CI gate from Finding 1, OR (b) introduce a per-subscriber identity check via a `Phoenix.PubSub` dispatcher wrapper (more invasive). (a) is the let-it-crash-shaped fix.

### Finding 3 — Notifications doesn't emit telemetry

- **Severity: MEDIUM**
- **What:** Every `notify/3` is a `Phoenix.PubSub.broadcast` — no `:telemetry.execute`. The audit log, LiveDashboard, future tracing exporters, and StressMetrics cannot see notifications at all. Compare to `cc_events.ex:51` which DOES emit telemetry after broadcasting.
- **Where:** `apps/ezagent_core/lib/ezagent/notifications.ex:94-99`
- **Why it matters:** Operators debugging "user reports they didn't see X notification" have to scrape `Logger` strings — the notification isn't queryable in `invocations` or `cc_events:stream`. This is the same class of bug P27 forbids for silent-drops, just at the observability layer instead of the action layer.
- **Recommendation:** Emit `[:ezagent, :notification, :emitted]` right after the broadcast with metadata `{user_uri, type, source}` (NOT body — could be PII / large). Add to `Audit.@events` so it persists. ~10 LOC change.

### Finding 4 — `[:ezagent, :chat, :receive, :dropped]` telemetry has no audit row

- **Severity: MEDIUM**
- **What:** `chat.ex:353` emits this telemetry when the Agent's bridge isn't bound — the highest-signal "why didn't the agent reply?" event. But `Ezagent.Audit.@events` doesn't include it (`audit.ex:33-50`), so it never persists. Operator sees the `Logger.warning` from `chat.ex:346` in `phx.log` (good) but not in `/admin/logs` (bad).
- **Where:** `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:353-357` vs `apps/ezagent_core/lib/ezagent/audit.ex:33-50`
- **Why it matters:** P22 ("zero-match routes emit telemetry + DLQ-unroutable; silent drop is forbidden") is partially honored (Logger fires) but partially violated (no durable record beyond stdout). Operators tailing `/admin/logs` think the system is healthy when bridge drops are happening.
- **Recommendation:** Add `[:ezagent, :chat, :receive, :dropped]` to `Audit.@events` + a `build_row/3` clause. ~15 LOC.

### Finding 5 — `EzagentWeb.Telemetry.metrics/0` defines metrics but no reporter is attached

- **Severity: LOW**
- **What:** `apps/ezagent_web/lib/ezagent_web/telemetry.ex:22-83` defines 16 `Telemetry.Metrics` (Phoenix, Repo, VM) but the supervisor only starts `:telemetry_poller` and the `ConsoleReporter` is commented out (line 15). Nothing exports these metrics.
- **Where:** `apps/ezagent_web/lib/ezagent_web/telemetry.ex:9-20`
- **Why it matters:** Phoenix LiveDashboard (dev) reads them, so the dev story works — but `MIX_ENV=prod` has no metrics surface at all. Anyone wiring Prometheus/Grafana later assumes "metrics are emitted, just attach a reporter" — actually true, but the metric DEFINITIONS in `metrics/0` aren't the metric EMITTERS; they're consumed by reporters that subscribe to telemetry events. The dead code is fine; the operational gap is "no production metrics export configured."
- **Recommendation:** Either delete the unused `metrics/0` (it's lying — pretending we export them) or wire a real reporter (`PrometheusEx` / `TelemetryMetricsPrometheus`) in prod config.

### Finding 6 — Notification spec missing from `docs/superpowers/specs/`

- **Severity: LOW**
- **What:** Notifications was added 2026-05-23 ("PR-C") but no spec file exists alongside `2026-05-23-presence.md`, `2026-05-23-capability-registry.md`, `2026-05-23-read-receipts.md`. The design lives only in the module docstrings.
- **Where:** `apps/ezagent_core/lib/ezagent/notifications.ex:1-62` (moduledoc); no corresponding `docs/superpowers/specs/2026-05-23-notifications.md`
- **Why it matters:** Future plugin authors need to know "notify is the entry" — currently discoverable only by grepping for `Notifications.notify`. Allen's question itself proves the discoverability gap.
- **Recommendation:** Write a 1-page spec or extend `2026-05-23-presence.md` (same Behavior pattern; could be one "cap-only Behaviors" SPEC covering both).

### Finding 7 — No audit-row workspace check in ObservabilityLive read query

- **Severity: LOW**
- **What:** `observability_live.ex:42-50` runs `SELECT ... FROM invocations ORDER BY id DESC LIMIT 50` — no `WHERE workspace_uri = ?`. Cross-workspace audit data leaks to any admin LV viewer.
- **Where:** `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/observability_live.ex:42-50`
- **Why it matters:** Phase 9 PR-6 went through specifically to add `workspace_uri` to audit rows (P17 + P21 enforcement). The READ side never landed. Defensible interpretation: only admins see this page (system-wide visibility is intentional for SREs). But the column exists and the moduledoc doesn't say "intentionally cross-workspace" so it reads as missing-filter.
- **Recommendation:** Decide explicitly — either filter by `socket.assigns.current_workspace_uri` OR document "cross-workspace by design (system admin view)" in the moduledoc. Either is fine; the ambiguity is the bug.

---

## Section 6 — If unified (rejected option), migration sketch

For completeness — IF Allen overrides the recommendation in §4 and wants unification:

1. **Define `Ezagent.Event`** — single primitive `emit(scope_uri, %{type, body, source, level, dedup_key?, persist?}, ctx)`. `:level` is `:notification | :info | :warning | :error | :audit`; `:persist?` boolean.
2. **Subscriber model** — `subscribe(scope_uri, filter)` where filter is a pattern over `{type, level, source}`. PubSub topic per-scope (`esr:event:<uri>`); subscriber-side filter.
3. **Persistence routing** — `persist?: true` → batched insert into a new `events` table (replaces `invocations` + `dlq`); else PubSub-only. Migrate `Ezagent.Audit` to emit via `Ezagent.Event` and become a subscriber rather than a handler.
4. **Cap layer** — `emit` cap is per-scope-Kind (User → `:notify` cap stays; Session/Workspace → new `:emit_event` cap; `system://` → admin-only). `subscribe` cap is the same per-scope.
5. **Migration order** — write `Ezagent.Event` alongside existing systems; migrate one producer at a time; switch consumers to subscribe to the unified topic with filters; delete old modules in a single sweep PR. ~3-4 PRs over a phase boundary; high blast radius if rolled back mid-flight (Allen's P2 "no parallel paths" recommends one-shot deletion at the end).

Cost estimate: ~500-800 LOC net change across 4 PRs. Benefit: one fewer concept. Risk: as §4 lists — cap model coupling + blast-radius coupling + audience mismatch. **Stick with the recommendation in §4.**

---

## Pointer index for follow-up

- `apps/ezagent_core/lib/ezagent/notifications.ex` — the unified entry
- `apps/ezagent_core/lib/ezagent/behavior/notifications.ex` — cap subject
- `apps/ezagent_core/lib/ezagent_core/application.ex:166-190` — registration
- `apps/ezagent_core/lib/ezagent/audit.ex` — telemetry handler
- `apps/ezagent_core/lib/ezagent/audit/writer.ex` — async batch writer
- `apps/ezagent_core/lib/ezagent/cc_events.ex` — CC-side error report path
- `apps/ezagent_core/lib/ezagent/dlq.ex` — dead-letter table
- `apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.ex:70-114` — PubSub broadcast allowlist
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/observability_live.ex` — `/admin/logs` LV
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_authz_audit_live.ex` — per-pid telemetry stream LV
- `docs/superpowers/specs/2026-05-23-presence.md` — sibling cap-only Behavior (notifications uses identical pattern)
