# Decouple Session Creation from Orchestrator Spawn — Design

> Status: design (brainstorm-approved 2026-06-23). Supersedes the
> orchestrator-coupling decision in
> `docs/superpowers/specs/2026-05-31-orchestrator-startup-atomicity-and-slice-unwrap.md`
> (see §9). Fixes the PR #902 session-creation bug.

## 1. Summary

Today, creating a session and bringing up its cc orchestrator agent are welded
into one all-or-nothing operation. When the orchestrator cannot become ready,
the whole session creation is dragged down — it exceeds the dispatch budget,
gets rolled back, and the rollback **deletes the session's respawnable
snapshot**, leaving no usable session.

This design splits the two concerns:

- **Creating the session** (a chat space with its owner + members and a
  respawnable snapshot) must always succeed quickly and durably.
- **Bringing up the orchestrator** becomes a best-effort step that runs
  asynchronously inside the Session Kind's own lifecycle (`on_ready/2` hook),
  can fail / time out / be retried later, and **never harms the session**.

## 2. The bug (root cause, verified on `main` 2026-06-23)

Causal chain (each link verified against code; reproduced ×5 via in-node erpc by
the `world-deploy-e2e-pg` E2E pass — see PR #902
`docs/together/2026-06-23/e2e-blocker-analysis.md`):

1. The orchestrator is itself a cc agent. On the current E2E host it hangs at
   claude's project-scoped MCP-trust onboarding dialog (`esr-bridge`) because the
   PTY auto-prompt scanner did not dismiss it → the orchestrator never reaches
   `:ready`. *(This onboarding/credential gap is a SEPARATE, agent-side fix
   owned by other developers — out of scope here. This design makes session
   creation robust regardless of why the orchestrator fails.)*
2. `EzagentDomainInstanceMessage.SessionCreator.create_session/3` runs the
   orchestrator ensure+join **synchronously** inside `finalize_fresh_session`
   → `ensure_orchestrated_session(.., new_session?: true)` — a deliberate
   atomicity choice from the 2026-05-31 SPEC.
3. The synchronous ensure waits for the orchestrator to become ready; with a
   hung orchestrator this blocks well past the framework's default dispatch
   budget (`Ezagent.Invocation`, `inv.ctx[:deadline_ms] || 5_000` → 5s; the
   `workspace.create_session` `:call` times out for the caller).
4. On any step-4..8 failure the create-NEW path calls `rollback_session/3`,
   which **terminates the Session Kind AND deletes its `kind_snapshots` row**.
5. A subsequent `:session :send` lazy-spawns from snapshot; with the snapshot
   deleted, `Ezagent.Invocation` returns `{:error, :no_such_actor}`.
6. The error is invisible: the world composer dispatches `send` with
   `mode: :cast` + `reply: :ignore` (`conversation_actions.ex` `send_message`),
   so the failure only lands in a hidden `data-last-dispatch` attribute — the
   composer clears, the transcript shows "No turns", zero error.

It is **not** a capability problem: admin holds the wildcard cap
(`{:any, :any, :any, :any, :any}`, `confirmed: true`); a session that DOES have
a snapshot accepts the same send (`{:ok, %{stored: true}}`). The defect is the
create→orchestrator coupling + the snapshot-deleting rollback.

## 3. Goals / non-goals

**Goals**
- `create_session` returns a fully usable session quickly, independent of
  orchestrator outcome.
- Orchestrator failure NEVER rolls back / deletes / terminates the session.
- A session whose orchestrator is not (yet) ready is a first-class state the
  whole stack understands.
- Orchestrator bring-up is retried on each session activation (fresh spawn +
  cold-restart respawn), and on demand via the existing "Restart orchestrator"
  operator action.
- Dispatch errors that today are swallowed by `:cast`/`reply: :ignore` are
  surfaced.

**Non-goals (YAGNI for v1)**
- No automatic failure-retry loop within a single activation (manual retry +
  next-activation re-attempt only — brainstorm Q2).
- No replay of messages sent while the orchestrator was down (the orchestrator
  handles turns from when it comes up forward — brainstorm Q3.3).
- The cc onboarding / MCP-trust auto-dismiss fix (agent-side, other devs).

## 4. Design overview

### 4.1 The synchronous part of create stays small

`create_session/3` (via `finalize_fresh_session`) synchronously does only cheap,
local work for an orchestrator-bearing template:

1. spawn the Session Kind (`Ezagent.Kind.spawn(Session, ..)`) — the Session
   Kind's own init writes its respawnable snapshot atomically with the
   `ever_created` marker (`Ezagent.Kind.Server` `persist_initial_snapshot`),
2. bind the session to its workspace (`WorkspaceRegistry.bind/2`),
3. materialize the OTU (orchestrator + session template URIs) onto the session
   working copy — see §4.4 for the **timing change** required,
4. join the **owner** (and any non-orchestrator template members),

then returns `{:ok, session_uri, %{orchestrator_status: :pending, ...}}`
immediately. It does **not** run `ensure_orchestrated_session` and does **not**
join the orchestrator synchronously.

### 4.2 Orchestrator bring-up moves into the Session Kind's `on_ready/2`

The Session Kind (a session-lifecycle Behavior — see §5) implements the
optional `on_ready/2` callback. `Ezagent.Kind.Server` invokes `on_ready` hooks
**after** `ReadyGate` flips to `:ready` (`run_on_ready_hooks/3`, task #49), and
isolates any raise/exit inside them (the Kind stays `:ready`). This is strictly
better than `post_init/2` for our use: `post_init`/`handle_continue` keep the
Kind `:not_ready` for the whole post-init phase (codex round-2 HIGH-1), so doing
the work there would re-block the session; `on_ready` runs while the session is
already usable.

`on_ready/2`:

- reads its slice; if the session has an OTU **and** no live orchestrator
  (`Ezagent.Orchestrator.Health` ≠ `:alive`), it **fire-and-forgets** a
  supervised, timeout-bounded task (see §4.3) and returns immediately. It MUST
  NOT await orchestrator readiness — `on_ready` runs in the Kind's process, so
  blocking it would stall the session's mailbox even though `ReadyGate` says
  ready.
- if the session has no OTU (plain template) or the orchestrator is already
  `:alive`, it is a no-op.

Because `on_ready` fires on every activation (fresh spawn AND respawn from
snapshot on cold restart), orchestrator bring-up is automatically re-attempted
after a node restart — idempotently (the bring-up path treats an already-present
orchestrator as success; see §4.5).

### 4.3 The async bring-up task = the existing `repair_orchestrator`

Orchestrator bring-up is unified onto ONE path: the existing
`EzagentDomainInstanceMessage.repair_orchestrator/1,2`
(`SessionCreator.do_repair_orchestrator`), which is what the operator
"Restart orchestrator" button already calls. It re-materializes the OTU
(idempotent) and runs the §5-atomic ensure gate (spawn orchestrator + grant caps
+ register MCP + join orchestrator) with **`new_session?: false`** semantics:
on failure it compensates **only the orchestrator-side residue** and **leaves the
Session Kind + its snapshot + its members alive** (the existing codex cycle-2
MAJOR #3 behavior). This is exactly the safe semantics this design needs — it is
NOT the snapshot-deleting `rollback_session/3` reserved for the create-NEW path.

The `on_ready` hook runs `repair_orchestrator` inside a fire-and-forget task
under a `Task.Supervisor` (added to the `EzagentDomainInstanceMessage`
application supervision tree). The task is **timeout-bounded**: the orchestrator
ensure's "await orchestrator ready" step is what hangs for >60s, so the task
imposes a deadline (default ~30s, configurable) on `repair_orchestrator`. On
timeout the orchestrator-side residue is compensated (same residue-only path)
and the session's `orchestrator_status` is set to `:failed`. `Ezagent.Kind.spawn`
itself only awaits ~500ms (`:spawn_await_ready_ms`), so the deadline must be
threaded into the ensure-gate's readiness await — preferred over an external
`Task.shutdown`, so the ensure self-compensates cleanly rather than being killed
mid-flight.

> Implementation note: thread an explicit deadline/budget through
> `ensure_orchestrated_session` → the orchestrator readiness await
> (`ReadyGate.await`) so a hung orchestrator surfaces a bounded
> `{:error, :timeout}` the bring-up path can compensate, instead of relying on
> killing the task from outside.

### 4.4 OTU-at-spawn timing (so `on_ready` sees it on the first create)

`on_ready` fires during the Session Kind's spawn (step 1 above), but the OTU is
materialized in `finalize_fresh_session` AFTER spawn returns. To let the first
`on_ready` see the OTU, the orchestrator/session template URIs must be present in
the Session Kind's slice **from birth**: pass `orchestrator_template_uri` (+
`session_template_uri`) into `Kind.spawn`'s params so the session-lifecycle
Behavior's `init_slice/1` records them. The session is then "born knowing" it
should have an orchestrator, and `on_ready` (fresh + respawn) reads it uniformly.
The subsequent `materialize_orchestrator_working_copy` call remains (idempotent)
to keep the working-copy projection consistent.

### 4.5 `orchestrator_status` states

`%{orchestrator_status: status, orchestrator_uri: uri | nil, orchestrator_error: term | nil}`

- `:pending` — bring-up not yet complete (returned by `create_session`; set
  while the async task is in flight). **New value produced by this design.**
- `:ready` — orchestrator agent is alive + joined (was `:created` /
  `:already_present`).
- `:failed` — bring-up failed or timed out; session is alive and usable; the
  operator (or the next activation) may retry. (A plain no-orchestrator template
  keeps its existing `:failed` + nil-URI "this session has no orchestrator role"
  meaning — unchanged; the UI distinguishes "no orchestrator role" from
  "orchestrator bring-up failed" via `orchestrator_uri`/OTU presence.)

The status is persisted on the session working copy so a respawn and the UI both
read it.

## 5. Components

| Module (file) | Change |
|---|---|
| `EzagentDomainInstanceMessage.SessionCreator` (`session_creator.ex`) | `finalize_fresh_session`: stop calling `ensure_orchestrated_session` synchronously for new sessions; do owner-join synchronously; return `:pending`. Keep `repair_orchestrator` as the single bring-up path. Thread a deadline into the ensure readiness await. |
| Session-lifecycle Behavior on the Session Kind (`apps/ezagent_domain_session/lib/ezagent/behavior/...` / `Ezagent.Entity.Session`) | Add `on_ready/2`: if OTU present & orchestrator not `:alive`, fire-and-forget the bring-up task. Add `orchestrator_template_uri`/`session_template_uri` to `init_slice/1` (OTU-at-spawn). |
| `EzagentDomainInstanceMessage.Application` (`application.ex`) | Add a `Task.Supervisor` child to host the fire-and-forget bring-up tasks. |
| `ensure_orchestrated_session` / orchestrator readiness await | Accept an explicit deadline; on timeout return `{:error, :timeout}` + residue-only compensation. |
| `Ezagent.Orchestrator.Health` | Reused unchanged as the `:alive/:crashed/:not_spawned` classifier for the `on_ready` guard + the UI badge. |
| `conversation_actions.ex` (`ezagent_plugin_world`) | `send_message`: surface dispatch errors (no longer silently swallow `:no_such_actor` etc. into `data-last-dispatch` only); show a non-blocking orchestrator-status badge sourced from `Orchestrator.Health` + `orchestrator_status`; "Restart orchestrator" already calls `repair_orchestrator` — reused. |

## 6. Data flow / sequence

```
create_session(orchestrator template)
  └─[sync] Kind.spawn(Session, orchestrator_template_uri:…)   # snapshot written in init
            └─ Session Kind init → :ready → run_on_ready_hooks
                 └─ on_ready/2: OTU present & orchestrator not alive
                      └─[fire-and-forget] Task.Supervisor task (deadline ~30s)
                            └─ repair_orchestrator(session_uri)
                                 ├─ ok  → orchestrator joined + caps + MCP; status=:ready
                                 └─ err/timeout → residue-only compensate; status=:failed
  └─[sync] bind workspace + materialize OTU + join owner
  └─[sync] return {:ok, session_uri, %{orchestrator_status: :pending}}   # fast
```

The user can send into the session from the moment `create_session` returns;
messages persist regardless of orchestrator status. When the orchestrator
becomes `:ready` it handles turns from that point forward.

## 7. Error handling

- Async bring-up failure/timeout: residue-only compensation (terminate the
  half-spawned orchestrator + its partial caps/membership); **never**
  `rollback_session/3`, never delete the snapshot, never touch the Session Kind.
  Set `orchestrator_status: :failed` with `orchestrator_error`.
- `on_ready` raise/exit: isolated by `Kind.Server` (Kind stays `:ready`).
- Plain (no-orchestrator) template: synchronous create joins owner + materializes
  team, returns `:ready` with nil orchestrator URI — unchanged from today.
- The synchronous create's own residue (bind/materialize/owner-join failure)
  still rolls back the half-built session via `rollback_session/3` — this arm is
  unchanged; only the orchestrator arm is decoupled.

## 8. UI

Non-blocking orchestrator-status badge in the world session view, sourced from
`Ezagent.Orchestrator.Health` (`:alive/:crashed/:not_spawned`) + the stored
`orchestrator_status`:

- `:pending` → "orchestrator starting…"
- `:failed`/`:crashed`/`:not_spawned` (with OTU) → "orchestrator unavailable —
  Restart" (button calls existing `repair_orchestrator`)
- `:ready`/`:alive` → hidden

Composer send is **never disabled** by orchestrator status (brainstorm Q3-A).
`send_message` surfaces dispatch errors to the user instead of swallowing them.

## 9. Supersedes the 2026-05-31 orchestrator-startup-atomicity SPEC

`docs/superpowers/specs/2026-05-31-orchestrator-startup-atomicity-and-slice-unwrap.md`
made orchestrator ensure **atomic** with create: any step-4..8 failure rolled the
whole session back, to guarantee "no half-created session is ever observed." That
guarantee's cost is the bug here — a hung/failed orchestrator destroys an
otherwise-fine session.

This design **keeps session-level atomicity** (Session Kind + snapshot +
workspace bind + owner join are still all-or-nothing) but changes the orchestrator
from *atomic, rollback-on-failure* to *best-effort, eventually-consistent,
manually-retryable*. The hazard the old SPEC guarded against ("a session stuck
half-created with no recovery") is now handled by recovery (`on_ready`
re-attempt on each activation + operator "Restart") rather than by rollback —
and "session exists, orchestrator not ready" becomes a designed, observable
state instead of an illegal one. The 2026-05-31 SPEC's slice-unwrap / Lifecycle
work is unaffected; only its create→orchestrator atomicity decision is reversed.

## 10. Testing (each gate fails when the architectural goal is unmet)

1. **No-rollback invariant (the test that would have caught this bug):** create
   a session from a template whose orchestrator ensure FAILS → assert the
   session is alive, its `kind_snapshots` row exists, `orchestrator_status ==
   :failed`, and `rollback_session` was NOT invoked.
2. **Create stays within budget under a hung orchestrator:** stub the
   orchestrator readiness await to hang → `create_session` returns `:pending`
   within the dispatch budget (well under the bring-up deadline).
3. **Session usable while orchestrator not ready:** send to a `:pending`/`:failed`
   session → `{:ok, stored}` and the message persists (no `:no_such_actor`).
4. **Manual retry:** `repair_orchestrator` on a `:failed` session brings it to
   `:ready` + joined.
5. **Re-attempt on activation:** respawn a `:failed`/`:not_spawned`
   orchestrator-bearing session (cold-restart path) → `on_ready` re-kicks
   bring-up; with a now-healthy orchestrator it reaches `:ready`.
6. **Positive path:** orchestrator succeeds → `:ready` + joined + caps + MCP.
7. **Idempotency:** `on_ready` with an already-`:alive` orchestrator is a no-op.
8. **Error surfacing:** a `send_message` dispatch error is surfaced (not only in
   `data-last-dispatch`).

All gates run on PostgreSQL (the suite is PG-only); `mix precommit` must be
green (the `EXIT=` line is authoritative).

## 11. Scope / PR split

- **PR-1 (core decouple):** `SessionCreator` synchronous-create change +
  Session-Kind `on_ready` bring-up + `Task.Supervisor` + OTU-at-spawn + deadline
  threading + status `:pending`. Tests 1–7.
- **PR-2 (UI surfacing):** world `conversation_actions` error surfacing + the
  non-blocking orchestrator badge. Test 8 + agent-browser visual E2E.

PR-1 is the load-bearing fix and can land independently (it removes the bug even
before the UI badge); PR-2 improves observability on top.

## 12. Open questions

None outstanding — Q1 (eager-async), Q2 (manual retry, no auto-loop), Q3
(session immediately usable; timeout-bounded; surface send errors; no backlog
replay), Q4 (lifecycle `on_ready` hook) were all resolved in the 2026-06-23
brainstorm. A second codex adversarial review of this spec runs before
implementation.
