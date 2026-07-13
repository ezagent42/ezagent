# The bridge join times out — and nobody is told

**Status:** OPEN. Separate bug, separate PR. **Very likely one independent root cause of this
week's "@orchestrator never replies".**

**Owner:** `ezagent_domain_agent` (`TransportReadiness`) — **not** `ezagent_domain_pty`.

---

## Symptom

An agent's process starts CORRECTLY, but its esr-bridge never JOINs (parked at a login prompt,
parked at an unknown dialog, bad credentials…). From then on the agent:

- stays `:not_ready` forever
- has every message to it dead-lettered
- **surfaces no error to anyone**

It just hangs there. The operator does not know. The creator does not know. Nothing in the UI says so.

## This is not the launcher's problem (Allen, 2026-07-13)

> "This is by rights not the agent launcher's problem (pty/py and friends) — once the process has
> started correctly the launcher's job is done. The problem is that a bridge that cannot join has
> no exit mechanism. The correct design is: the bridge times out after trying for a while, the
> bridge raises the error, and the creator checks and handles it."

**He is right, and it corrects a layering error of mine.**

I had wanted the PTY breaker to catch this zombie — pinning `healthy_after_ms` to the bridge's 30 s
join timeout, on the reasoning that a shorter window would call a child healthy before the bridge
had a chance to JOIN.

That **smuggled bridge semantics into the PTY layer.** A process launcher answers exactly one
question: *did the process come up?* Whether the agent then becomes usable is the bridge's business.
One number trying to answer two questions belonging to two layers answers neither well.

(Fixed: `RespawnPolicy.@default_healthy_after_ms` is now justified by process stability alone and no
longer references the transport-join timeout. The value is still 30 s — but for the right reason,
and now free to move independently of any bridge timeout.)

## But half of the mechanism Allen describes is missing from the code

He says: bridge times out → **the bridge raises the error** → the creator handles it.

**The first two steps exist. The third does not.**

| Step | Reality |
|---|---|
| bridge attempts to join | ✅ `TransportReadiness.require_transport_join/2` (30 s default) |
| timeout fires | ✅ `TransportReadinessListener`'s `{:transport_join_timeout, …}` → `timeout_generation/2` |
| **error is raised** | ❌ **zero telemetry, zero Logger, zero notification in `transport_readiness.ex`** |
| creator finds out | ❌ **no way to** |

On timeout it does exactly two things (`fail_current_generation_locked/3` →
`ReadyTransition.mark_failed_locked/1`):

1. drains `PendingDelivery` into the DLQ
2. `ReadyGate.mark_failed/1` — flips the ReadyGate to `:failed`

**And that is all.** No telemetry, no log line, no notification. And **no UI or notification path
consumes the ReadyGate `:failed` state** — it is an internal flag.

This is precisely the symptom `Ezagent.Agent.CredentialPrecondition`'s own moduledoc records:

> "`esr-bridge` never joins, `require_transport_join/1` never resolves, and the agent's ReadyGate
> sits at `:not_ready` forever — the "@orchestrator never replies" symptom, **with no error
> anywhere**."

## Why it matters

**This is unrelated to #1294's `--continue` root cause** — but it is the same class of hole wearing
a different coat:

| | #1294 (fixed) | This bug |
|---|---|---|
| Symptom | child dies in 37 ms, respawns forever | child is perfectly alive, never connects |
| Who notices | the logs (933 spawns / 2 h) | **nobody** |
| Owner | PTY launcher | bridge |

`--continue` at least made NOISE. This one is **completely silent** — which makes it worse.

And: **not one of the six cc agents on canary has credentials.** Missing credentials → claude boots
but the bridge cannot connect → exactly this silent failure's trigger condition. So this week's
"the agent actually replies" goal may well be blocked partly on *this*.

## Suggested fix

After `timeout_generation/2` decides the join failed, alongside `mark_failed` it should:

1. **`Logger.error`** — at minimum, make it greppable
2. **telemetry** — `[:ezagent, :agent, :transport_join_timeout]` with `agent_uri` + the timeout
3. **notify the creator** — reuse the existing `Ezagent.Agent.CredentialNotifier` chain (it already
   does "auth failure → resolve owner → notify"); a bridge-join timeout should ride the same path
4. **make it visible** — the agent list / detail view should show `:failed` rather than leaving it
   parked in an invisible `:not_ready`

(3) is the highest-value one: `CredentialNotifier` **already** subscribes to `pty:auth_failed` and
resolves an agent's owner. A bridge-join timeout belongs on the same road — **the creator is the
person who can fix it**, which is also Allen's answer to "who may recover a dead agent".

## Scope

- **Not this PR.** Different app, different root cause, independently testable, independently
  evidenced.
- Needs its own canary proof: make an agent's bridge deliberately fail to join, and confirm a signal
  actually surfaces after the timeout.

---

**Related:**
- `docs/notes/2026-07-13-cc-pty-respawn-crashloop-rootcause.md` — #1294's root cause (it was
  `--continue`, not authentication)
- `docs/notes/2026-07-13-pty-restart-operator-lever-open-decision.md` — the operator recovery lever
