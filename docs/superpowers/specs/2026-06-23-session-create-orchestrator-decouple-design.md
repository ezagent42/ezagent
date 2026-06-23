# Decouple Session Creation from Orchestrator Spawn — Design (rev3)

> Status: design (brainstorm-approved 2026-06-23; **rev3** addresses the proper
> `/codex:adversarial-review` of rev2 — 1 BLOCKER + 2 HIGH, all verified against
> code; rev2 had addressed the first review's 2 BLOCKER + 4 HIGH + 3 MED).
> Supersedes the orchestrator-coupling decision in
> `docs/superpowers/specs/2026-05-31-orchestrator-startup-atomicity-and-slice-unwrap.md`
> (§9). Fixes the PR #902 session-creation bug.

## 0a. What changed in rev3 (read first)

The adversarial-review confirmed the decouple direction but flagged three
load-bearing gaps; rev3 closes them:

- **Status write ordering (BLOCKER):** `:pending` is now written in the Session
  Kind's **birth slice** (`init_slice`, persisted in the initial snapshot) —
  NOT late, after bind. And every terminal status write (`:ready`/`:failed`) is
  **monotonic via a per-attempt id (CAS)**: a stale/late write can never
  overwrite a newer terminal status. Together this removes the hazard where a
  fast worker's `:ready` could be clobbered by a late `:pending` (e.g. test-mode
  / already-present orchestrator).
- **Residue ledger completeness (HIGH):** the ledger now enumerates **every**
  side effect the ensure performs after spawn (see §4.3), each compensated
  idempotently, each with a failure-injection test.
- **Mandatory global concurrency cap (HIGH):** the bring-up supervisor MUST be a
  single global-capped queue/pool (fixed max in-flight across ALL sessions) plus
  atomic per-session dedup. Per-session dedup alone does not bound the
  cold-restart boot storm; the global cap is no longer an optional alternative.

## 0. What changed in rev2 (read first)

The brainstorm direction (decouple; orchestrator bring-up is best-effort,
re-attempted on activation) is unchanged. rev2 fixes correctness gaps the review
found:

- **Fresh-create no longer relies on `on_ready` firing during spawn** (it would
  race the post-spawn workspace bind → the guard would see an unbound session).
  Instead `create_session` **explicitly kicks** the bring-up task *after* the
  synchronous session is fully built (spawned + bound + OTU + owner-joined).
  `on_ready`/`activated/2` is used **only for respawn / cold-restart**
  re-attempts, where the workspace bind is already durable. Both paths converge
  on one bounded bring-up worker. *(This is a refinement of "pure on_ready",
  flagged for Allen — it still gives "re-attempt on each activation".)*
- **`orchestrator_status` is made durable** (new working-copy fields) — today it
  exists only in the create return value.
- **Bring-up is genuinely residue-only** via a compensation ledger (today the
  `new_session?: false` failure branch leaves the session alive but does NOT
  revoke partial orchestrator/cap/MCP/member residue).
- **Deadline is threaded at the real 90s gate** (`await_orchestrator_ready/3`,
  `@orchestrator_readiness_timeout_ms`), not at a SessionCreator wrapper.
- **Boot-storm bounded**: a dedicated bring-up supervisor with in-flight dedup,
  so N orchestrator-bearing sessions respawning on cold start don't fan out N
  concurrent 90s ensures.
- **Member/team boundary made explicit**: synchronous create joins the **owner
  only** (owner authority); template-team + orchestrator join stay in the async
  bring-up (preserving existing member lineage / grantor semantics).
- **Supersession migrates executable tests**, not just prose (§10).

## 1. Summary

Creating a session and bringing up its cc orchestrator agent are welded into one
all-or-nothing operation. When the orchestrator cannot become ready, session
creation is dragged down — it exceeds the dispatch budget, gets rolled back, and
the rollback **deletes the session's respawnable snapshot**, leaving no usable
session.

This design splits the concerns:

- **Creating the session** (a chat space with its owner + a respawnable
  snapshot) always succeeds quickly and durably.
- **Bringing up the orchestrator** is a best-effort, bounded, async step that can
  fail / time out / be retried, and **never harms the session**.

## 2. The bug (root cause, verified on `main` 2026-06-23)

Causal chain (each link code-verified; reproduced ×5 via in-node erpc by the
`world-deploy-e2e-pg` E2E pass — PR #902
`docs/together/2026-06-23/e2e-blocker-analysis.md`):

1. The orchestrator is a cc agent. On the current E2E host it hangs at claude's
   project-scoped MCP-trust onboarding dialog (`esr-bridge`) → never reaches
   `:ready`. *(Agent-side onboarding fix is OUT OF SCOPE — owned by other devs.
   This design makes create robust regardless of why bring-up fails.)*
2. `SessionCreator.create_session/3` runs orchestrator ensure+join
   **synchronously** in `finalize_fresh_session` →
   `ensure_orchestrated_session(.., new_session?: true)`.
3. That ensure waits for orchestrator readiness with a **90s** budget
   (`Ezagent.Entity.Session.Orchestrator` `@orchestrator_readiness_timeout_ms
   90_000`, `await_orchestrator_ready/3`). The **outer** `workspace.create_session`
   `:call` only has the framework dispatch budget (`Ezagent.Invocation`,
   `inv.ctx[:deadline_ms] || 5_000`), so the caller times out at 5s while the
   server keeps grinding toward 90s.
4. On step-4..8 failure the create-NEW path calls `rollback_session/3`, which
   **terminates the Session Kind AND deletes its `kind_snapshots` row**.
5. A later `:session :send` lazy-spawns from snapshot; with the snapshot gone,
   `Ezagent.Invocation` returns `{:error, :no_such_actor}`.
6. The error is invisible: the world composer dispatches `send` with
   `mode: :cast` + `reply: :ignore` (`conversation_actions.ex` `send_message`) —
   it lands only in a hidden `data-last-dispatch` attribute.

Not a capability problem (admin holds the wildcard cap; a snapshot-bearing
session accepts the same send). The defect is the create→orchestrator coupling +
the snapshot-deleting rollback.

## 3. Goals / non-goals

**Goals**
- `create_session` returns a usable session quickly, independent of orchestrator
  outcome.
- Orchestrator failure NEVER rolls back / deletes / terminates the session.
- "Session exists, orchestrator not ready" is a first-class, durable, observable
  state.
- Bring-up is retried on each activation (fresh + cold-restart) and on demand
  via the existing "Restart orchestrator" action — **bounded** to avoid a boot
  storm.
- Bring-up failure is genuinely residue-only (no leaked orchestrator/cap/MCP).
- Swallowed dispatch errors are surfaced.

**Non-goals (YAGNI v1)**
- No automatic failure-retry loop within a single activation (manual + next
  activation only).
- No replay of messages sent while the orchestrator was down.
- The cc onboarding / MCP-trust auto-dismiss (agent-side, other devs).

## 4. Design

### 4.1 Synchronous create stays small (owner-only)

`create_session/3` → `finalize_fresh_session`, for an orchestrator-bearing
template, synchronously does only cheap local work:

1. spawn the Session Kind (`Ezagent.Kind.spawn(Session, %{.., orchestrator_template_uri:, session_template_uri:})`)
   — the Kind's init writes its respawnable snapshot atomically with the
   `ever_created` marker (`Kind.Server` initial-snapshot path); the OTU **and**
   `orchestrator_status: :pending` are in the **birth slice** (§4.4, §4.5), so
   `:pending` is durable from t=0 (before `activated/2` or any worker can run) —
   create does NOT write `:pending` late,
2. bind the session to its workspace (`WorkspaceRegistry.bind/2`),
3. join the **owner only** (owner authority) so the session is immediately
   usable,

then returns `{:ok, session_uri, %{orchestrator_status: :pending, ...}}`. It does
**not** run `ensure_orchestrated_session` and does **not** join the orchestrator
or the template team synchronously.

After the synchronous session is complete (still under the per-URI
`:create_session` `:global` lock create already holds), it **kicks the bounded
bring-up worker** (§4.3) for this session and returns. Kicking here — *after*
bind — is deterministic and avoids the race where an `on_ready`-launched task
could start before the workspace bind committed.

> Member boundary (codex HIGH): template-team materialization currently runs
> only after orchestrator success, granting via `orchestrator_uri`
> (`template_team.ex`). To preserve member lineage / grantor semantics, the
> template team (non-owner members) is materialized inside the async bring-up,
> NOT in synchronous create. Immediate usability needs only the owner, who is
> joined synchronously with owner authority.

### 4.2 `on_ready` / `activated/2` drives re-attempt on respawn

The Session-lifecycle Behavior implements the Lifecycle `activated/2` callback
(the `use Ezagent.Lifecycle` name for `on_ready/2`; `Kind.Server` runs it AFTER
the `ReadyGate` flip, `run_on_ready_hooks/3`, and isolates raises — the Kind
stays `:ready`). On **every** activation it:

- reads its own slice: if the session has an OTU **and** the planned orchestrator
  is not live (`KindRegistry` lookup on the planned orchestrator URI — a
  slice/registry check that does NOT depend on `WorkspaceRegistry`, so it is safe
  even in the brief pre-bind window) **and** no bring-up is already in flight
  (§4.3 dedup) → **kick the bounded bring-up worker** and return immediately;
- else no-op.

On a fresh create, `activated/2` may fire during spawn before bind — this is now
safe because (a) `:pending` is already in the birth slice (no late create write
to clobber a fast worker's terminal status — the rev3 BLOCKER fix), (b) the
guard does not need the bind, and (c) the worker it would kick is de-duplicated
against the explicit kick from `create_session` (§4.3), so at most one bring-up
runs. On cold-restart respawn, the bind is already durable, so `activated/2` is
the sole driver. `activated/2` must NOT await readiness (it runs in the Kind's
process; blocking it stalls the mailbox even though `ReadyGate` says ready).

### 4.3 One bounded, deduplicated bring-up worker (reuses `repair_orchestrator`)

Both entry points (the explicit create kick + the `activated/2` respawn kick)
converge on a single bring-up path under a dedicated bring-up manager added to
`EzagentDomainInstanceMessage.Application`. It MUST enforce a **global
concurrency cap** (a single GenServer queue or a fixed-size worker pool — a
mandatory ceiling on total in-flight bring-ups across ALL sessions) **plus**
atomic per-session in-flight dedup. Per-session dedup alone only prevents
duplicate work for one session; on cold restart N distinct orchestrator-bearing
sessions would still launch N concurrent 90s readiness waits — exactly the
2026-05-31 SPEC boot-storm warning. The global cap is therefore not optional. A
second kick for a session already in flight is a no-op.

The worker runs the existing
`EzagentDomainInstanceMessage.repair_orchestrator/1,2`
(`SessionCreator.do_repair_orchestrator`) — the SAME path the operator "Restart
orchestrator" button calls. It re-materializes the OTU (idempotent) and runs the
ensure gate (spawn orchestrator + caps + MCP + join orchestrator + materialize
team) with **`new_session?: false`** semantics, which already **leaves the
Session Kind + snapshot + members alive** on failure — NOT the snapshot-deleting
`rollback_session/3`.

**Deadline (codex MED):** the real wait is `await_orchestrator_ready/3`
(`@orchestrator_readiness_timeout_ms 90_000` in
`entity/session/orchestrator.ex`). Thread an explicit deadline/opts through
`Session.ensure_orchestrator/3` → `await_orchestrator_ready/3` (new arity) so the
worker bounds it (default ~30s, configurable) and gets a clean
`{:error, :timeout}` to compensate — rather than an external `Task.shutdown` that
kills the ensure mid-flight.

**Residue-only via ledger (codex HIGH):** the `new_session?: false` failure
branch leaves the session alive but does NOT currently revoke the partial
residue of the failed attempt. Today the ensure writes the working-copy
`orchestrator_uri` BEFORE granting caps/MCP and starts a SessionManager BEFORE
member/team materialization (`session_creator.ex` ensure region), so a naive
"compensate spawn/caps/MCP/members" misses real residue. The ledger MUST cover
**every** side effect the ensure performs, in order, each recorded when done and
compensated idempotently on failure/timeout:

1. working-copy `orchestrator_uri` write (clear it),
2. spawned orchestrator process + its ownership/bindings (terminate + unbind),
3. owner manage/restart caps (revoke),
4. orchestrator scoped caps (revoke),
5. MCP context registration (deregister),
6. SessionManager process, if started (stop),
7. member joins + template-team rows/rules (remove the attempt's rows/rules),
8. live-join / readiness rows (remove).

Compensation touches ONLY this attempt's residue — never the Session Kind, its
snapshot, or the owner. Each step gets a failure-injection test (§10.5) so the
"residue-only" claim is proven per step, not asserted.

On settle, the worker writes the terminal `orchestrator_status` (`:ready` /
`:failed` + `orchestrator_error`) durably (§4.5) under the **monotonic/CAS rule**
(§4.5) and in a rescue-safe `after` so a crashed worker never leaves a stale
`:pending`.

### 4.4 OTU-at-spawn (nested working-copy shape) (codex HIGH)

`activated/2` reads the OTU from the slice, so the OTU must be present from birth.
Readers consume the **nested** `template_working_copy` shape
(`entity/session/orchestrator.ex`), and `Session.create/1` builds that copy from
defaults (`behavior/session.ex`). Therefore the birth OTU fields
(`orchestrator_template_uri`, `session_template_uri`) must be merged into the
**nested `template_working_copy`** of the initial slice — not stored as top-level
slice keys (which readers would miss). A test asserts the initial snapshot's
nested shape carries the OTU.

### 4.5 `orchestrator_status` — durable (codex BLOCKER 2)

Add durable working-copy fields `orchestrator_status`, `orchestrator_error`, and
`orchestrator_attempt_id` (in the nested `template_working_copy`, alongside the
OTU fields), so a respawn and the UI both read a persisted value. Today
`orchestrator_status` exists only in the `create_session` return map
(`session_creator.ex` return-meta) and is lost on restart.

**Write rules (rev3 BLOCKER fix):**
- `:pending` is set in the **birth slice** (`init_slice`) at spawn — durable in
  the initial snapshot, before `activated/2` or any worker runs. Create never
  writes `:pending` after the fact.
- Each bring-up attempt carries a fresh monotonically-increasing
  `orchestrator_attempt_id`. A terminal write (`:ready`/`:failed`) succeeds only
  if its attempt id is ≥ the stored one (CAS); a stale/late write is dropped.
  `:pending` is only ever the birth value (or a value an explicit re-attempt sets
  with a NEW attempt id before kicking) — it can never overwrite a terminal
  status from a newer attempt. This makes the status write order-independent.

States:
- `:pending` — bring-up not complete (written by synchronous create; cleared by
  the worker). **New durable value.**
- `:ready` — orchestrator alive + joined.
- `:failed` — bring-up failed/timed out; session alive + usable; retry via next
  activation or "Restart". (A plain no-orchestrator template keeps its existing
  `:failed` + nil-URI "no orchestrator role" meaning; the UI distinguishes the
  two via OTU/`orchestrator_uri` presence.)

## 5. Components

| Module (file) | Change |
|---|---|
| `SessionCreator` (`session_creator.ex`) | `finalize_fresh_session`: drop the synchronous `ensure_orchestrated_session` for new sessions; sync owner-join only; write durable `:pending`; kick the bounded bring-up worker after bind. Keep `repair_orchestrator` as the single bring-up path; thread a deadline into its ensure. |
| Session-lifecycle Behavior (`apps/ezagent_domain_session/lib/ezagent/behavior/session*.ex` / `Ezagent.Entity.Session`) | Add `activated/2` (= `on_ready`) re-attempt guard (slice OTU + non-live orchestrator + not-in-flight → kick worker). Merge birth OTU into the nested `template_working_copy` in `create/1` / `init_slice`. Add durable `orchestrator_status`/`orchestrator_error` fields + a status-write action. |
| `Ezagent.Entity.Session.Orchestrator` (`orchestrator.ex`) | `ensure_orchestrator/3` + `await_orchestrator_ready/3`: accept an explicit deadline (opts/new arity); record a compensation ledger; on failure/timeout compensate only this attempt's residue. |
| `EzagentDomainInstanceMessage.Application` (`application.ex`) | Add the bring-up manager: a **global-concurrency-capped** queue/pool (mandatory ceiling on total in-flight bring-ups) + atomic per-session in-flight dedup. |
| `Ezagent.Orchestrator.Health` | Reused unchanged for the UI badge; the `activated/2` guard uses a `WorkspaceRegistry`-independent liveness check (see §4.2). |
| `conversation_actions.ex` (`ezagent_plugin_world`) | `send_message`: surface dispatch errors (stop swallowing into `data-last-dispatch` only). Non-blocking orchestrator-status badge from `Health` + durable `orchestrator_status`; "Restart" already calls `repair_orchestrator` — reused. |

## 6. Data flow

```
create_session (orchestrator template)            [holds :create_session global lock]
  ├─[sync] Kind.spawn(Session, OTU in birth slice)   # snapshot written in init
  │         └─ Kind init → :ready → activated/2 guard:
  │              orchestrator not live + OTU present → (dedup) kick worker
  ├─[sync] WorkspaceRegistry.bind
  ├─[sync] write orchestrator_status = :pending  (durable)
  ├─[sync] join OWNER (owner authority)
  ├─[sync] kick bounded bring-up worker (dedup vs the activated/2 kick)
  └─[sync] return {:ok, uri, %{orchestrator_status: :pending}}     # fast

bring-up worker (bounded, deadline ~30s):
  repair_orchestrator(uri)  →  ensure (spawn + caps + MCP + join orch + team)
    ├─ ok               → status=:ready
    └─ err/timeout      → compensate THIS attempt's residue (ledger);
                          session + snapshot untouched; status=:failed

cold-restart respawn:
  Kind init → :ready → activated/2 guard → (dedup) kick worker  → same as above
```

User can send from the moment create returns; messages persist regardless of
orchestrator status; the orchestrator handles turns from when it becomes ready.

## 7. Error handling

- Bring-up failure/timeout: ledger-based residue-only compensation; **never**
  `rollback_session/3`; never delete the snapshot; never touch the Session Kind.
  Durable `orchestrator_status: :failed` + `orchestrator_error`.
- `activated/2` raise/exit: isolated by `Kind.Server` (Kind stays `:ready`).
- Worker crash: the rescue-safe status write prevents a stuck `:pending`; the
  next activation's `activated/2` re-attempts.
- Plain (no-orchestrator) template: synchronous create joins owner + team,
  returns `:ready` with nil orchestrator URI — unchanged.
- Synchronous-create residue (bind/owner-join/snapshot failure) still rolls back
  the half-built session via `rollback_session/3` — this arm is unchanged; only
  the orchestrator arm is decoupled.

## 8. UI

Non-blocking orchestrator badge in the world session view from
`Ezagent.Orchestrator.Health` (`:alive/:crashed/:not_spawned`) + durable
`orchestrator_status`:
- `:pending` → "orchestrator starting…"
- `:failed`/`:crashed`/`:not_spawned` (with OTU) → "orchestrator unavailable —
  Restart" (calls existing `repair_orchestrator`)
- `:ready`/`:alive` → hidden

Composer send is never disabled by orchestrator status. `send_message` surfaces
dispatch errors to the user.

## 9. Supersedes the 2026-05-31 orchestrator-startup-atomicity SPEC

That SPEC made orchestrator ensure **atomic** with create (any step-4..8 failure
rolled the whole session back) to guarantee "no half-created session is ever
observed", and explicitly warned of an N×30s boot storm if bring-up were made
per-activation. Its cost is this bug — a hung/failed orchestrator destroys an
otherwise-fine session.

This design **keeps session-level atomicity** (Session Kind + snapshot +
workspace bind + owner join are still all-or-nothing) but changes the
orchestrator from *atomic, rollback-on-failure* to *best-effort,
eventually-consistent, manually-retryable + re-attempted-on-activation*. The
"half-created with no recovery" hazard is handled by recovery (`activated/2`
re-attempt + operator "Restart") instead of rollback; "session exists,
orchestrator not ready" becomes a designed, durable state. The boot-storm warning
is honored by the bounded bring-up supervisor (§4.3). The SPEC's slice-unwrap /
Lifecycle work is unaffected; only its create→orchestrator atomicity decision is
reversed.

## 10. Testing (each gate fails when the architectural goal is unmet)

New / changed tests:
1. **No-rollback invariant (would have caught this bug):** create from a template
   whose orchestrator ensure FAILS → session alive, `kind_snapshots` row exists,
   durable `orchestrator_status == :failed`, `rollback_session` NOT invoked.
2. **Create within budget under a hung orchestrator:** stub the readiness await to
   hang → `create_session` returns `:pending` within the dispatch budget.
3. **Session usable while not ready:** send to `:pending`/`:failed` session →
   `{:ok, stored}`, message persists (no `:no_such_actor`).
4. **Durable status:** `:pending`/`:failed` survives a respawn (read from the
   working copy, not the return value).
5. **Residue-only on failure (per-step failure injection):** inject a failure
   after EACH ledger step (§4.3: working-copy `orchestrator_uri`, orchestrator
   process, owner caps, scoped caps, MCP, SessionManager, member/team rows, live-
   join rows) → assert no leak of that step's residue and that the session +
   snapshot + owner are intact.
6. **Re-attempt on activation:** respawn a `:failed`/`:not_spawned`
   orchestrator-bearing session → `activated/2` re-kicks; with a healthy
   orchestrator it reaches `:ready`.
7. **Dedup + global cap:** the explicit create kick + `activated/2` kick for the
   same session run at most one bring-up (per-session dedup); and respawning M ≫
   cap orchestrator-bearing sessions never exceeds the configured global
   concurrent-bring-up ceiling at any instant.
7b. **Status monotonicity (the rev3 BLOCKER):** with a fast/already-present
   orchestrator, a worker writing terminal `:ready` followed by any later
   `:pending`/stale write leaves the durable status `:ready` (CAS by
   `orchestrator_attempt_id`) — never reverts to "permanently starting".
8. **OTU nested shape:** the initial snapshot's nested `template_working_copy`
   carries the OTU.
9. **Positive path:** orchestrator succeeds → `:ready` + joined + caps + MCP +
   team.
10. **Error surfacing:** a `send_message` dispatch error is surfaced (not only in
   `data-last-dispatch`).

**Supersession migration (codex MED) — executable tests that assert immediate
orchestrator readiness must be migrated, not just the prose:**
- `apps/ezagent_domain_session/test/integration/session_create_orchestrator_unified_test.exs`
- `apps/ezagent_plugin_cc/test/integration/session_create_atomicity_test.exs`
- `scenario_32_mention_orchestrator_dispatch_test.exs` (and an audit grep for any
  other test asserting a live orchestrator / MCP immediately after create)

Migrate each to the new contract: create returns `:pending`; the orchestrator
becomes `:ready` after the (test-driven, not 90s-real) bring-up completes. Where a
test needs a ready orchestrator synchronously, it awaits the bring-up explicitly
(test helper) rather than assuming create blocks on it.

All gates run on PostgreSQL (PG-only suite); `mix precommit` must be green (the
`EXIT=` line is authoritative).

## 11. Scope / PR split

- **PR-1 (core decouple):** SessionCreator sync-create + durable status fields +
  bounded bring-up supervisor + `activated/2` re-attempt + OTU-at-spawn (nested) +
  deadline threading + ledger residue compensation. Tests 1–9 + supersession test
  migration.
- **PR-2 (UI surfacing):** world `conversation_actions` error surfacing + the
  non-blocking orchestrator badge. Test 10 + agent-browser visual E2E.

PR-1 is the load-bearing fix (removes the bug before the UI badge); PR-2 adds
observability.

## 12. Open questions

None outstanding. Brainstorm Q1–Q4 resolved 2026-06-23; rev2 resolves the first
codex review's findings. A second `/codex:adversarial-review` of rev2 runs before
implementation.
