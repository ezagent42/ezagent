# V1 Acceptance Stress-Test Plan

**Status:** PLAN — not executed. A follow-up implementation task runs it.
**Author:** Claude (Opus 4.7) for Allen — Feishu request 2026-05-22.
**Branch:** `docs/v1-stress-test-plan`
**Scope:** V1 acceptance stress testing. NOT a permanent load-testing framework.

---

## 1. The three questions

Allen, for V1 acceptance, wants measured answers to:

1. **Agents-per-session** — how many agents can all be members of ONE session
   and exchange messages before latency/throughput degrades.
2. **Max sessions** — how many concurrent sessions the system holds.
3. **Max users** — how many concurrent users the system holds.

This document plans *how to measure* those three limits. It does not pick the
numbers — the **acceptance bar (§8) is a proposal for Allen to ratify**.

---

## 2. Runtime cost model (code-grounded)

Every claim below cites a real module. Do not invent costs — these are the
numbers the test must confirm or refute.

### 2.1 Per-entity cost (user / agent / session)

Every user, agent, and session is **one `Ezagent.Kind.Server` GenServer**
(`apps/ezagent_core/lib/ezagent/kind/server.ex`). Spawning one is always
`Ezagent.Kind.spawn/2` → `DynamicSupervisor.start_child`
(`apps/ezagent_core/lib/ezagent/kind.ex:93`). One live entity costs:

| Resource | Per entity | Source |
|---|---|---|
| BEAM process | 1 GenServer | `Kind.Server` |
| KindRegistry entry | 1 ETS row (`Registry`, `keys: :unique`) | `kind_registry.ex` — `put_new/2` |
| ReadyGate entry | 1 ETS row | `Kind.Server.init/1` → `ReadyGate.put` |
| Process state | per-Behavior slice maps keyed by `behavior.state_slice()` | `Kind.Server` state shape |
| Snapshot row | 0 or 1 in `kind_snapshots` (see §2.4) | `Kind.Snapshot` |

Idle entity memory is small (a GenServer with a few small maps ≈ low single-digit
KB). The scaling question is **how many** before the BEAM process table, ETS, or
total RSS becomes the limit — and whether spawn *throughput* (DynamicSupervisor
serialises `start_child`) becomes a ramp bottleneck.

Persistence policy per Kind (decides snapshot write cost):
- **Session** — `{:snapshot, :on_change}` (`entity/session.ex:80`)
- **User** — `{:snapshot, :on_change}` (`entity/user.ex:137`)
- **Agent** — `:on_terminate` (`entity/agent.ex:69`)
- **Echo agent** — `:ephemeral` (`ezagent_plugin_echo/.../entity/echo.ex:21`) — see §3.2

### 2.2 The dispatch fan-out — `chat.send` into a session of N members

This is the heart of question 1. One `chat.send` (`Ezagent.Behavior.Chat.invoke(:send, ...)`,
`apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex:92`) does, in order:

1. **`MessageStore.write/2`** (`message_store.ex:67`) — a `Repo.transaction`
   containing **2 SQLite inserts**: `messages` (upsert) + `message_routings`
   (insert). Synchronous. Write failure = send failure (no silent degrade).
2. **1 PubSub broadcast** to `esr:session:<uri>:events` — the LV chat stream.
3. **`Resolver.resolve/4`** (`routing/resolver.ex:96`) — pure function; expands
   the `$session_members` magic token to the member list minus the sender.
4. **For each of the N−1 recipients** → `dispatch_receive/3` →
   `Ezagent.Invocation.dispatch/1` with `mode: :cast`. Each one:
   - `ReadyGate.status` lookup + `KindRegistry.lookup` (2 ETS reads),
   - `GenServer.cast` to the recipient,
   - inside the recipient: `Kind.Runtime.handle_dispatch/4` runs steps 5–10:
     BehaviorRegistry lookup, **authz check** (`Capability.matches?` scan over
     ctx.caps), **workspace isolation check**, args validation, `Behavior.invoke`,
     slice put, **`[:ezagent, :invoke, :stop]` telemetry**.
5. **`maybe_notify_external/3`** — one extra ETS lookup; no-op unless a plugin
   registered `:notify_external` on the Session Kind.

**Amplification — the telemetry tail.** Every successful dispatch emits
`[:ezagent, :invoke, :stop]`. `Ezagent.Audit.attach/0` (`audit.ex`) handles it
and does **two things per event**: (a) `Phoenix.PubSub.broadcast` to
`esr:audit:stream`, (b) `GenServer.cast` to `Ezagent.Audit.Writer`. The Writer
**batches** (`audit/writer.ex` — flush every 100ms or at 500 rows,
`insert_all`), so audit DB cost is amortised — but the **PubSub broadcast is
per-event, not batched**.

**Fan-out shape for one `chat.send` into N members (User/Agent recipients,
no auto-reply):**

```
1  chat.send dispatch        (the Session)
+  1 MessageStore txn        = 2 SQLite writes (messages + message_routings)
+  1 session-events PubSub broadcast
+  (N-1) chat.receive dispatches      → (N-1) Behaviour.invoke
+  (N-1) per-recipient PubSub broadcasts (User → user-events; Agent → bridge send)
+  N    [:ezagent,:invoke,:stop] telemetry events   (1 send + N-1 receive)
+  N    audit-stream PubSub broadcasts
+  N    Audit.Writer casts   (batched → ~N/500 SQLite insert_all flushes)
```

So **one logical message → ~2 SQLite writes + ~(2N+1) PubSub broadcasts +
N dispatches + N audit casts**. PubSub fan-out and dispatch count both grow
**linearly in N** per message. The SQLite write count per message is
*constant* (2) — until you add auto-reply (§2.6).

### 2.3 The DB is single-writer (likely bottleneck)

`EzagentCore.Repo` uses `Ecto.Adapters.SQLite3` (`repo.ex`). SQLite serialises
all writers. Pool config:
- **dev** (`config/dev.exs:25`): `pool_size: 5`.
- **prod** (`config/runtime.exs:29`): `pool_size` from `POOL_SIZE` env, default 5.
- **test** (`config/test.exs:8`): `pool_size: 20`, `queue_target: 1000`,
  `queue_interval: 5000` — raised in Phase 9 because integration tests hit the
  Repo from test sandbox + Audit.Writer + cap-loading + per-tenant writes.

A larger Ecto pool does **not** buy write parallelism on SQLite — only one
write transaction commits at a time. Every `chat.send` does a 2-insert
transaction; the Audit.Writer adds a periodic `insert_all`; every `:on_change`
snapshot adds another write. Under sustained traffic these contend for the
single writer. **Confirm whether the DB is in WAL mode** — there is no
`after_connect`/PRAGMA wiring in config or the Repo module (grep found none),
so the journal mode is whatever `ecto_sqlite3` defaults to. WAL vs rollback
journal materially changes the write-contention ceiling; the test must record
the actual `PRAGMA journal_mode` and `PRAGMA busy_timeout` at run start.

### 2.4 Snapshot write cost (`{:snapshot, :on_change}`, PR #199 context)

Session and User Kinds are `{:snapshot, :on_change}`. `Kind.Server` calls
`Ezagent.Kind.Snapshot.maybe_save/4` after **every dispatch**
(`server.ex:117/123/137/145`). `maybe_save` for `:on_change`
(`kind/snapshot.ex:150`) compares `old_state == new_state` (BEAM value
equality) and writes **only if the slice changed**:

- **`chat.send`** returns `{:ok, slice, %{stored: true}}` — the Chat slice
  (`members` / `monitors` / `last_seen`) is **unchanged**. So a plain message
  send does **NOT** trigger a Session snapshot write. Good — message traffic
  alone doesn't amplify snapshot writes.
- **`chat.join` / `chat.leave` / member `:DOWN`** **do** mutate the slice
  (`chat.ex:280-296`, `:305`, `:334`) → a **synchronous** `save_now/3`
  (`kind/snapshot.ex:177`): `term_to_binary` the slice + `KindSnapshot.upsert`
  (a SQLite write).

**Implication for the test:** session *churn* (members joining/leaving, agents
crashing) is the snapshot-write amplifier, NOT message volume. The
agents-per-session scenario must measure both — the join storm at session
construction AND steady-state messaging.

### 2.5 PubSub fan-out

Two consumers per session:
- The **session-events** topic (`esr:session:<uri>:events`) — LV chat streams.
- The **audit-stream** topic (`esr:audit:stream`) — every LV `/admin` view,
  plus one broadcast per dispatch (§2.2).

With M LV subscribers on a topic, each broadcast is M message-sends. The
audit-stream broadcast is the concern: it fires **once per dispatch** —
under heavy traffic the audit-stream topic is a global hot path even if only
one admin LV is connected.

### 2.6 Loop amplification — the combinatorial risk

If agents auto-reply, message volume can explode. The Echo agent
(`ezagent_plugin_echo/.../behavior/echo.ex`) on `:receive` dispatches a fresh
`chat.send` back to the session. The moduledoc notes one guard: `Resolver`
excludes the message *sender* from fan-out, so an echo reply does not loop
back to the *same* echo agent. **But that guard is not enough** for N echo
agents in one session:

- Agent A's reply is `chat.send` from A → fans out to B, C, … (everyone but A).
- Agent B receives it, replies → fans out to A, C, … — and so on.
- One human message into a session of N auto-replying agents triggers a
  cascade that grows roughly geometrically until something drops it.

There is **no global turn counter or message-budget cap** in Chat/Resolver
(confirmed — Resolver only does sender-exclusion + dedup-by-URI). So a naive
"N echo agents all chatting" test would measure a runaway, not capacity.

**The plan therefore mandates bounded traffic (§7).**

---

## 3. Methodology

### 3.1 Drive load WITHOUT real LLM calls

V1 acceptance must measure **ezagent's orchestration cost**, not OpenAI/Claude
latency. Use stub agents:

- **Echo plugin** (`apps/ezagent_plugin_echo`) — already a reference stub. Its
  `:receive` dispatches a `chat.send` back. Use it for the *auto-reply* path,
  but ONLY with the turn cap of §7, because it amplifies.
- **A passive "sink" agent** — for measuring pure fan-out *without*
  amplification, the test needs an agent whose `:receive` is a no-op (counts
  the message, never replies). The echo behavior amplifies; a sink does not.
  **Implementation task action:** add a tiny `sink` behavior/Kind in a
  test-support module (or a flag on the echo behavior to disable the reply).
  Prefer a flag on echo (`reply: false` in the agent's init args) so no new
  plugin is needed. **This is the one piece of test code the implementation
  task must write** — the rest is a driver script.
- Real `cc.agent` / `curl_agent` are explicitly OUT of scope — they pull in
  PtyServer / HTTP latency and obscure the orchestration cost.

### 3.2 Spawn N entities programmatically

All spawns go through `Ezagent.Kind.spawn/2` (the sole entry, invariant).
The driver (a mix task, §6) loops:

- **Users:** `Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: ..., initial_caps: ...})`.
  For large counts, skip the DB-row provisioning of `mix ezagent.user.create`
  and spawn the Kind directly with `default_caps()` — the test measures
  *Kind* capacity, not the identity-provisioning path.
- **Agents:** spawn the echo Kind directly (`:ephemeral` — no snapshot noise),
  or via the echo `cc.agent`-style Template Class.
- **Sessions:** spawn `Ezagent.Entity.Session`, then **`WorkspaceRegistry.bind/2`**
  immediately (invariant 4 — `MessageStore.write` raises on an unbound session
  via `Persistence.workspace_uri_for!/1`).
- Each agent/user **joins** the session via `chat.join` (a `:call`).

URIs are canonical 3-segment per-tenant form (SPEC v3 §5.15):
`entity://agent/<workspace>/echo_<n>`, `session://default/<workspace>/stress_<n>`.

### 3.3 Trigger chat traffic

The driver dispatches `chat.send` invocations into target sessions at a
controlled rate (a token-bucket pacer), with a **fixed total message budget**
per scenario run (§7). Each message is a plain `%Ezagent.Message{}` with a
small text body.

> **Updated 2026-05-22** — mention-gated routing
> (`docs/superpowers/specs/2026-05-22-mention-gated-routing.md`). The
> `system_default` rule is now `{:always} → [$session_users,
> $mentions]`, NOT `[$session_members]`. A **mention-less** message
> no longer fans out to agent members — it only reaches User members
> (per-user notification). To exercise the full agent fan-out for the
> agents-per-session scenario, the message MUST either `@mention` all
> agent members, or the scenario must add an explicit broadcast rule
> resolving to `$session_members`. Mention-less is the realistic
> default only for *human-to-human* traffic; agent fan-out is now
> mention-driven.

### 3.4 Test environment

- Run against a **dedicated `:prod`-or-`:bench` build** with a real on-disk
  SQLite DB (not the test Sandbox — the Sandbox serialises per test and would
  mask real pool contention). Pin `POOL_SIZE` explicitly and record it.
- Single BEAM node (V1 is single-node). Record host: cores, RAM, disk type
  (SSD vs spinning materially changes SQLite write latency).
- Record `PRAGMA journal_mode` + `busy_timeout` at start (§2.3).
- **[HUMAN-ASSIST]** Allen / an operator must designate the test machine — see §9.

---

## 4. Scenarios

Each scenario: spawn → warm-up → ramp → steady-state hold → tear-down.
Every ramp step holds long enough for metrics to stabilise (suggest ≥60s hold
per step). Every run uses a **fixed message budget** (§7).

### Scenario A — Agents per session (question 1)

One session, ramp the member count, hold steady traffic at each step.

- **Ramp:** 2 → 5 → 10 → 25 → 50 → 100 agents (all members of one session).
- **Traffic:** a fixed driver injects M messages total across the hold window
  at a fixed rate; recipients are **sink agents** (no auto-reply) for the
  capacity number, then a **separate bounded auto-reply run** (echo agents +
  turn cap, §7) to measure the reply-fan-out cost.
- **Primary metric:** dispatch latency p50/p99 and messages/sec as N grows;
  the per-message fan-out is N−1 dispatches (§2.2).
- **Stop condition for the ramp:** first step where p99 dispatch latency
  exceeds the §8 bar, or the BEAM/DB shows distress (§5).

### Scenario B — Max sessions (question 2)

Many sessions, modest members each, light traffic.

- **Ramp:** 10 → 50 → 100 → 250 → 500 → 1000 → 2000 sessions, each with a
  small fixed membership (e.g. 1 user + 2 sink agents).
- **Traffic:** a low fixed per-session rate (e.g. 1 msg/session/10s) so the
  scenario measures *holding* many sessions, not message throughput.
- **Primary metric:** total BEAM process count, total RSS, KindRegistry ETS
  size, session spawn throughput (DynamicSupervisor serialisation), and
  snapshot-write rate from the join storm at construction (§2.4).
- **Stop condition:** RSS approaching the host limit, spawn throughput
  collapsing, or `kind_snapshots` write queue backing up.

### Scenario C — Max users (question 3)

Many user Kinds, few sessions.

- **Ramp:** 100 → 500 → 1000 → 5000 → 10000 user Kinds.
- **Traffic:** users are mostly idle (a realistic user is not constantly
  sending); a small active subset (e.g. 5%) sends at a light rate.
- **Primary metric:** process count, RSS, KindRegistry ETS size, User
  `:on_change` snapshot behaviour (a User snapshot writes only when the User
  slice changes — idle users cost no writes; confirm).
- **Stop condition:** as Scenario B.

### Scenario D — Combined (realistic mix)

A blended run approximating a plausible V1 deployment, to catch interaction
effects the isolated scenarios miss (DB contention is shared across all three).

- **Shape (proposed, Allen to adjust):** e.g. 200 users, 50 sessions
  averaging 5 members each, 10% of sessions "busy" with bounded auto-reply
  echo agents, the rest light traffic.
- **Primary metric:** end-to-end p99 dispatch latency and SQLite write queue
  depth under the mixed load — this is the number closest to "is V1 good
  enough".

---

## 5. What to measure

Per scenario, per ramp step, sampled over the steady-state hold:

| Metric | How | Why |
|---|---|---|
| **Dispatch latency p50/p99** | `[:ezagent, :invoke, :stop]` telemetry carries `duration_us` (`kind/runtime.ex:88`). Attach a histogram handler. | The core orchestration-cost number. |
| **Messages/sec throughput** | Count `chat.send` dispatches per second (driver-side counter + telemetry cross-check). | Question 1's headline. |
| **BEAM process count** | `:erlang.system_info(:process_count)` sampled. | Question 2 & 3 ceiling. |
| **Total memory (RSS + per-type)** | `:erlang.memory/0` (`:total`, `:processes`, `:ets`, `:binary`) + OS RSS. | Question 2 & 3 ceiling. |
| **ETS size** | `:ets.info(table, :size)` + `:memory` for the `Registry` (KindRegistry), ReadyGate, SchemeRegistry, RoutingRegistry tables. | KindRegistry contention/size hypothesis. |
| **SQLite write latency** | Wrap/observe `MessageStore.write` + `Audit.Writer` flush + `Snapshot.save_now`; emit timing telemetry. The repo has `[:ezagent, :persistence, :written]` (`kind/snapshot.ex:202`) — extend with a duration measurement. | DB-contention hypothesis (§2.3). |
| **DB queue depth** | Ecto `:telemetry` `[:ezagent_core, :repo, :query]` events expose `queue_time`. Attach a handler; alarm when `queue_time` rises toward `queue_target`. | Pool exhaustion / writer serialisation. |
| **Snapshot write rate** | Count `[:ezagent, :persistence, :written]` events; correlate with join/leave/DOWN events. | §2.4 churn-amplification check. |
| **Scheduler utilisation** | `:scheduler.utilization/1` (sample over the hold). | Is the BEAM CPU-bound or IO-bound (waiting on SQLite)? |
| **Mailbox depth** | Sample `Process.info(pid, :message_queue_len)` for the Audit.Writer, Snapshot.Writer, and the hottest Session/Agent. | Backpressure detection (writers cast unconditionally — §2.2, `audit/writer.ex` moduledoc). |

Sampling: a lightweight collector process polls `system_info`/`memory`/`ets`
every 1–5s and writes a CSV/JSONL per run. Telemetry histograms aggregate
latency. Do **not** keep the audit-stream PubSub subscription open during a run
unless measuring it — it is itself load.

---

## 6. Tooling

Keep it realistic for this repo — no new framework.

- **Driver: a Mix task.** `mix ezagent.stress` under
  `apps/ezagent_core/lib/mix/tasks/` (alongside the existing
  `ezagent.bootstrap`, `ezagent.snapshot.*` tasks). Args: `--scenario a|b|c|d`,
  `--ramp`, `--message-budget`, `--rate`, `--turn-cap`, `--out <path>`. It
  spawns entities via `Ezagent.Kind.spawn/2`, binds workspaces, joins members,
  paces `chat.send` dispatches, and shuts down cleanly.
- **Metrics: telemetry + a sampler.** Attach handlers to the events that
  already exist (`[:ezagent, :invoke, :stop]`, `[:ezagent, :persistence, :written]`,
  Ecto's `[:ezagent_core, :repo, :query]`). Add a `StressMetrics` collector
  module that owns the histograms + the periodic `system_info` sampler and
  flushes a results file. `ezagent_web/telemetry.ex` already exists as a
  pattern to copy.
- **Observation:** `:observer` for an interactive look during a run;
  `:recon` (`:recon.proc_count/2`, `:recon.bin_leak/1`) for process/binary
  forensics if a leak is suspected. These are diagnostic, not the data source —
  the CSV/JSONL from the sampler is the record.
- **The only test code to write:** the `mix ezagent.stress` task, the
  `StressMetrics` collector, and the echo `reply: false` flag (§3.1). No
  permanent harness, no CI wiring — V1 acceptance is a one-off measurement.

---

## 7. Loop-amplification safety (mandatory)

A capacity test must measure *capacity*, not a runaway (§2.6). The driver
MUST bound traffic by **both** mechanisms:

1. **Fixed message budget.** Each run injects exactly M driver-originated
   `chat.send` messages, then stops injecting. M is a run parameter.
2. **Turn cap on auto-reply.** For any scenario using echo (auto-reply)
   agents, the message carries a **hop counter** in its body (e.g.
   `body.meta.hop`), and the echo `:receive` reply path is gated:
   **do not reply if `hop >= turn_cap`**. `turn_cap` is a run parameter
   (suggest 3–5). This caps the cascade depth deterministically.
   - **Implementation task action:** add the hop-counter check to the echo
     behavior's reply path (alongside the `reply: false` flag of §3.1). This
     is a test-support concern — gate it behind the flag/arg so production
     echo behaviour is unchanged.
3. **Driver watchdog.** The driver tracks observed `chat.send` count vs the
   expected ceiling (`M × fan-out × turn_cap`); if observed exceeds the
   ceiling by a margin, it aborts the run and flags "amplification not bounded"
   — a finding in itself.

For the *pure capacity* numbers (questions 1–3), prefer **sink agents**
(no reply) so fan-out is exactly N−1 per message and the budget is exact.
Use echo + turn cap only for the explicit "what does auto-reply cost"
sub-measurement.

---

## 8. Bottleneck hypotheses (ranked)

Ranked predictions of what breaks first. Each: why, how the test confirms it,
candidate mitigation.

### H1 — SQLite single-writer contention (MOST LIKELY)

**Why:** `EzagentCore.Repo` is SQLite; one writer at a time (§2.3). Every
`chat.send` is a 2-insert transaction; Audit.Writer adds periodic `insert_all`;
every `:on_change` snapshot (join/leave/DOWN) adds a write. A bigger Ecto pool
does not add write parallelism. Under Scenario A at high message rate, or
Scenario D's mixed load, the single writer is the throughput ceiling.

**Confirm:** messages/sec plateaus while CPU is NOT saturated; Ecto
`[:ezagent_core, :repo, :query]` `queue_time` climbs toward `queue_target`;
`MessageStore.write` p99 latency rises; Audit.Writer mailbox grows.

**Mitigation candidates:** confirm + enable **WAL journal mode** (biggest
single lever — record current mode first); raise `busy_timeout`; batch
`message_routings` inserts; consider whether the per-`chat.send` `messages`
upsert + routing insert can be a single statement; longer-term a non-SQLite
writer for the message store. For acceptance, WAL + a documented msgs/sec
ceiling is likely sufficient.

### H2 — PubSub audit-stream fan-out as a global hot path

**Why:** every dispatch emits `[:ezagent, :invoke, :stop]`; `Ezagent.Audit`
broadcasts that to `esr:audit:stream` **per event, un-batched** (§2.2, §2.5).
At N×msgs/sec dispatches this is a single high-frequency PubSub topic; every
`/admin` LV subscriber multiplies it.

**Confirm:** scheduler utilisation rises with dispatch count even when DB is
idle; the PubSub/`Phoenix.PubSub` processes show high reductions; disabling the
audit attach (test-only) measurably lifts throughput.

**Mitigation candidates:** batch the audit-stream broadcast (the Writer
already batches the DB path — mirror it for the broadcast); or make the
audit-stream broadcast sampled/coalesced; or have LV `/admin` pull on an
interval instead of subscribing to a per-dispatch firehose.

### H3 — Per-message dispatch overhead × fan-out (linear-in-N)

**Why:** one `chat.send` into N members = N−1 `chat.receive` dispatches, each
running the full `Kind.Runtime` path: BehaviorRegistry lookup, authz cap scan
(`Enum.any?` over ctx.caps), workspace isolation check, args validation,
telemetry (§2.2). Cost grows linearly in N — for Scenario A this is the
intrinsic agents-per-session cost even with a perfect DB.

**Confirm:** p99 dispatch latency for a single `chat.send` grows
proportionally with member count N; flamegraph/`:recon` shows time in
`handle_dispatch` not in Repo.

**Mitigation candidates:** likely *acceptable* for V1 — document the
linear cost and the practical N ceiling. If a specific sub-step dominates
(e.g. the cap scan), micro-optimise that. Do not prematurely batch dispatch.

### H4 — KindRegistry / ETS contention at high entity counts

**Why:** every entity is a `Registry` (ETS) row; every dispatch does
`ReadyGate` + `KindRegistry` lookups (§2.1, §2.2). At 10k+ entities (Scenario C)
the tables are large; under high concurrent dispatch the partitioned ETS could
show read contention.

**Confirm:** `:ets.info` memory grows as expected (size is fine); but if
dispatch latency rises with *total entity count* independent of per-session
fan-out, suspect registry contention.

**Mitigation candidates:** stdlib `Registry` is already partitioned —
likely fine; if not, increase partitions. Most likely H4 is a non-issue and
the test confirms ETS scales linearly and cheaply.

### H5 — DynamicSupervisor spawn serialisation during ramp

**Why:** `Ezagent.Kind.spawn/2` → `DynamicSupervisor.start_child` is
serialised through the supervisor. Spawning 10k entities is 10k serialised
calls — a *ramp-time* cost, not a steady-state one.

**Confirm:** time the spawn loop; if entities/sec spawned plateaus, the
supervisor is the limit.

**Mitigation candidates:** acceptable for a test (ramp slowly); for
production, multiple per-Kind supervisors already exist (the `supervisor/0`
callback) — spread Kinds across them. Document, don't block V1 on it.

**Predicted order of failure:** H1 (DB writes) → H2 (audit PubSub) →
H3 (linear fan-out) → H5 (spawn ramp) → H4 (ETS, probably never).

---

## 9. Success criteria / acceptance bar — **PROPOSAL, Allen to ratify**

These numbers are **proposals**. Allen ratifies the actual bar. They are
sized for a single-node V1 on commodity hardware.

| Dimension | Proposed "V1 good enough" | "Needs work" |
|---|---|---|
| **Agents per session** | ≥ 25 agents, all members, p99 `chat.send` end-to-end fan-out < 250 ms at a steady 5 msg/s into that session | p99 > 1 s at ≤ 25 agents |
| **Max sessions** | ≥ 500 concurrent sessions held, RSS < ~2 GB, spawn + idle stable | system unstable below 200 sessions |
| **Max users** | ≥ 5000 user Kinds held, RSS < ~2 GB, idle | unstable below 1000 users |
| **Combined (D)** | the realistic mix sustains p99 dispatch < 250 ms with SQLite `queue_time` well under `queue_target` | sustained queue backup or p99 > 1 s |
| **Throughput** | ≥ 200 `chat.send`/s sustained system-wide without DB queue backup | < 50 /s |

**Each number is a proposal — Allen sets the V1 bar.** The deliverable of the
*execution* task is a results table populated with measured numbers plus a
clear "meets / does not meet" against whatever bar Allen ratifies, and a
prioritised mitigation list keyed to §8.

---

## 10. Steps requiring a human / Allen — [HUMAN-ASSIST]

Per memory `feedback_flag_user_assist_steps`, every step needing a person:

1. **[HUMAN-ASSIST] Designate the test machine.** The run must NOT be on a
   shared dev box or CI runner — it saturates the BEAM, the DB, and disk IO.
   Allen / an operator picks a dedicated host and records its specs (§3.4).
2. **[HUMAN-ASSIST] Authorise the test build + DB.** The run uses a `:prod`/
   `:bench` build with a real on-disk SQLite DB, separate from any real data.
   Someone with deploy access provisions it.
3. **[HUMAN-ASSIST] Sustained / long runs.** Scenario D and the high steps of
   B/C can run for tens of minutes to hours. If those run on shared infra or
   overnight, Allen should green-light the window.
4. **[ALLEN] Ratify the acceptance bar (§9).** The proposed numbers are
   placeholders — V1 pass/fail is Allen's call.
5. **[ALLEN] Approve the auto-reply turn cap value (§7).** Suggested 3–5;
   Allen confirms what "a realistic agent conversation depth" is for V1.

---

## 11. Out of scope

- Multi-node / distributed BEAM (V1 is single-node).
- Real LLM-backed agents (`cc.agent`, `curl_agent`) — measured cost would be
  dominated by external latency, not orchestration.
- A permanent load-testing framework or CI perf gate — this is one-off V1
  acceptance measurement.
- Network-transport stress (Feishu sidecar, Phoenix Channels WS) — orthogonal
  to the three questions; separate effort if needed.
