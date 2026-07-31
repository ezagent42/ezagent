# Unified operator warning/event seam (`Ezagent.OperatorEvents`)

2026-07-31 · observability

## The gap

`ezagent` had no single, principled place for code to say *"an operator
should see this."* Operator-relevant conditions surfaced through three
unrelated paths — and one large silent hole:

| Path | Scope | Shape |
|---|---|---|
| `Ezagent.Audit` | invocation telemetry (`[:ezagent, :invoke, …]`, `authz`, …) | telemetry **sink** → `esr:audit:stream` + durable row |
| `Ezagent.CCEvents` | CC-agent-failure HTTP hook | **ingestion adapter** → `cc_events:stream` |
| *(everything else)* | — | **silent** |

The silence was concrete. A `DeliveryOutbox` row going `:dead` — a
capability delivery **permanently abandoned** after retry exhaustion,
i.e. a capability that never reached its target — fired zero telemetry
and zero alert (`delivery_outbox.ex` `handle_failure_result({:dead,
target_uri})` just forgot the ETS hint and returned `:ok`). An operator
had no way to learn that a grant silently never landed.

## The seam

`Ezagent.OperatorEvents.emit/1` is **the one write API** for
operator-facing warnings/events. That is the "one place they go" — the
consolidation is at the *API* level, not a fourth pipe bolted on.

```elixir
OperatorEvents.emit(%{severity: :warning, source: :cap_delivery_outbox,
                      message: "…", meta: %{target_uri: uri}})
# convenience: OperatorEvents.warn/error/info(source, message, meta \\ %{})
```

`emit/1` validates (`severity ∈ [:info, :warning, :error]`, non-empty
`source`/`message`; fail-closed on malformed input) and does two
non-blocking, best-effort ops:

1. `Phoenix.PubSub.broadcast(EzagentCore.PubSub, topic(), {:operator_event, event})`
   — the **live** operator surface.
2. `:telemetry.execute([:ezagent, :operator, :event], %{count: 1}, event)`
   — the **sink hook** (durable history, metrics).

Callers never choose a topic; the topic is an implementation detail of
the seam. `emit/1` never raises for a valid event, so an emitter (e.g.
the outbox `:dead` path) can call it without guarding its own bookkeeping.

### How the existing modules relate (consolidation, not a peer)

- **`Audit` is a sink**, not a peer stream. It already persists a
  sibling telemetry event (`[:ezagent, :cc_bridge, :event]`); the
  follow-up attaches `[:ezagent, :operator, :event]` the same way, so
  operator events gain a queryable durable history without a second
  bespoke pipeline.
- **`CCEvents` is an ingestion adapter** — one *source* feeding the
  canonical seam. Its `report/1` collapses to an `emit/1` call
  (follow-up).
- The **live** delivery target is one operator-gated topic; the durable
  history is the `Audit` sink. One write API, two endpoints.

## Operator-gating (task #187)

`OperatorEvents.topic()` is a GLOBAL, all-tenant operator-observability
stream — same trust class as `Audit.stream_topic/0` and
`CCEvents.topic/0`, which #187 hardened after they were found
over-delivering to every logged-in non-operator.

The new stream reuses that exact fix in `EzagentPluginWorld.WorldLive`,
gating on `Ezagent.Identity.AdminAuthority.admin?/1` (the same predicate
`:require_admin`, `OperatorReads`, and the audit/cc streams use — no new
check invented) at **both** exits, fail-closed on unknown/missing caller:

- **subscribe-time (mount):** a non-operator LV is never subscribed to
  `OperatorEvents.topic()`;
- **delivery-time (`handle_info`):** even a socket that somehow holds the
  message drops it unless the caller is an operator *live* (covers a
  pre-gate subscription or a mid-session demotion).

## First emitter: DeliveryOutbox `:dead`

`handle_failure_result({:dead, target_uri})` runs `maybe_forget_target/1`
(the ETS-hint bookkeeping) **first and unconditionally**, then emits
`OperatorEvents.warn(:cap_delivery_outbox, "capability delivery
permanently failed (dead) after retry exhaustion", %{target_uri:
target_uri})` as best-effort observability layered after it — so an
observability call can never skip or corrupt outbox state, and (because
`emit/1` is failure-isolated) can never escape into the `Kind.Server` /
outbox caller either. The live warning stays lean by design: the full
`reason`/`last_error` already persists on the `:dead` DB row for deep
inspection.

## Scope of this PR vs. deferred follow-up

**In this PR (the seam + first emitter):**

- `Ezagent.OperatorEvents` — `emit/1` + `warn`/`error`/`info`, one
  canonical topic, telemetry sink hook.
- `DeliveryOutbox` `:dead` wired as the first emitter.
- `WorldLive` operator-gated subscribe + `handle_info`.
- `check_invariants` #1 allowlist entry for the new fan-out file.
- Tests: the seam unit test; the `:dead` end-to-end emit; the WorldLive
  operator gate (non-operator/caller-less drop, operator receives).

**Deferred (enumerated, deliberately not in this PR to avoid
over-scoping):**

1. **Audit as the durable sink.** Attach `[:ezagent, :operator, :event]`
   in `Ezagent.Audit` and add a `build_row/3` clause. It MUST mirror the
   crash-proof `:cc_bridge` clause exactly — inline `workspace://system`
   and use `inspect(meta)`, **never** `Jason.encode!(meta)` (arbitrary
   `meta` from any caller can carry non-encodable terms; a raise inside a
   telemetry handler detaches it node-wide and silently kills the audit
   log — the failure mode `audit.ex` already documents). This step MUST
   also suppress the generic `esr:audit:stream` re-broadcast for
   `[:ezagent, :operator, :event]` (write the durable row only, skip the
   PubSub fan-out) — operator events already have their own live stream,
   so without the skip every operator event would reach WorldLive twice
   (once as `operator_event`, once as `audit_event`).
2. **Migrate `CCEvents.report/1`** to `OperatorEvents.emit(%{severity:
   level, source: :cc_bridge, message: text, meta: %{bridge_id:
   bridge_id, type: type}})` (~2 lines), keeping the HTTP hook as the
   adapter. (Note: `source` is a single atom/string — the `bridge_id`
   travels in `meta`, since `fetch_source/1` accepts only a non-nil atom
   or non-empty binary.)
3. **Route Audit's operator-relevant events** (`invoke:error`,
   `authz:denied`, `session:receive:dropped`) through `emit/1` so a
   permission denial / dropped chat surfaces on the *live* warning
   stream, not only in the after-the-fact audit table.
