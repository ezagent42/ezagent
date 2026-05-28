# SPEC — Ezagent state model migration to EventStore + Commanded (CQRS / event-sourcing)

**Status:** r1 — DRAFT for codex adversarial-review (round 1). 2026-05-28.

**Tier:** Cross-cutting architectural migration. Touches `apps/ezagent_core/` (Kind / Behavior / Invocation / Persistence / Snapshot / Audit), all `apps/ezagent_domain_*/` (User, Session, Agent, Workspace, ExternalMirror Worker entity Kinds), the LiveView reading layer (`apps/ezagent_plugin_liveview/`), the CLI (`apps/ezagent_cli/`), the web dispatch surface (`apps/ezagent_web/`), and every plugin authoring example. Introduces three new umbrella apps (`ezagent_event_store`, `ezagent_commanded_app`, `ezagent_projections`) and a runtime hybrid period where some Kinds are Aggregates and others remain GenServers.

**Trigger:** Allen 2026-05-28 06:31 — pause SPEC #440 (entity-destroy lifecycle) after 4 codex REJECT rounds. The destroy cascade's 3 critical findings (no transactional cross-Kind atomicity; partial-failure inconsistency window; saga-like recovery requires structural primitives the current Kind=GenServer model does not provide) all dissolve under event-sourced semantics with Process Managers. Allen flagged the deeper hypothesis: **every multi-Kind workflow we have built (boot reconciler, spawn registry races, cap grant-time check, workspace cap-vis 5-round iteration) hits the same wall**. The destroy-lifecycle blockage is the most visible instance of a class.

**Companion:** `2026-05-28-eventstore-commanded-migration.zh_cn.md` (per `feedback_bilingual_docs_convention`).

**Predecessor memories (load-bearing):**
- `feedback_let_it_crash_no_workarounds` — no shim / dual-path. If we adopt CQRS/ES, the snapshot table becomes a cache for Aggregate replay, NOT a parallel source of truth. The migration is committed (per-Kind hard flip), not toggled.
- `feedback_completion_requires_invariant_test` — Phase gates are invariant tests that FAIL when the architectural goal is unmet. For each migrated Kind, the gate is "this Kind's state reconstructs deterministically from its event stream alone" (no slice/snapshot fallback). For Sagas: "this multi-Kind workflow runs through a Process Manager (not direct cross-Kind GenServer.call)".
- `feedback_north_star_plugin_isolation` — plugin authors write Commands + Events + an Aggregate `execute/2` + `apply/2`. They do NOT touch `Commanded.Application`, the event store config, projection wiring, or the saga registry. The boundary tightens.
- `feedback_destructive_migration_anti_pattern` — see §6 / §8. The migration adds a new event store DB; it does NOT destroy existing snapshot data. The unwind path in §12 explicitly forks back to slice/snapshot for any Phase whose migration aborts.
- `feedback_register_lookup_key_parity` — Aggregate identity must canonicalize the same way as the existing Kind URI (`Ezagent.URI.parse!/1`). The `:identify` clause on the router uses the canonical URI string; divergent canonicalization between dispatch sites would silently mis-route a command to a fresh Aggregate ID. §4.6 enforces.
- `feedback_uuid_is_canonical_identifier` — Aggregate UUIDs MUST be the canonical URI string of the existing Kind URI. We do NOT mint a new UUID column. The URI IS the identifier.
- `feedback_subagent_must_load_project_skills` — every Phase impl subagent dispatch MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`.
- `feedback_codex_review_every_pr` — codex review of THIS SPEC + every Phase impl PR carries the verbatim "no mix" clause.
- `feedback_phase_planning_reads_main_docs` — Phase numbering in §6 conforms to `IMPLEMENTATION_ROADMAP.md` §1.1 (current latest is Phase 6 / partial). This migration would be Phase 10 (post-Phase-9 PR-CC follow-ups complete, post-Phase-6 closeout).
- `feedback_explain_problem_not_code_structure` — §1 leads with the problem class (multi-Kind workflows lack atomicity primitives), §2 leads with the decision (CQRS/ES), code shape lives in §4-§5.

**Parent / historical context:**
- `IMPLEMENTATION_ROADMAP.md` §1.1 — Phase 0-6 are complete or in-flight. This SPEC would become Phase 10 (skipping reserved-but-unstarted Phase 7-9 follow-up work).
- `ARCHITECTURE.md` Decision Log #84 — chose path B (`@behaviour Ezagent.Kind` + shared `Kind.Server` GenServer) over path A (`use Ezagent.Kind` macro). This SPEC supersedes both with path C (`Commanded.Aggregate`).
- `ARCHITECTURE.md` Decision Log #59 + #60 — sync `on_change` snapshot writes + async batch writer for `periodic`. The event-sourced model REPLACES this with synchronous event append + optional aggregate snapshot every N events.
- `apps/ezagent_core/lib/ezagent/kind/server.ex` — the shared Kind GenServer that hosts every Kind today. Becomes deprecated post-Phase-10-D for each migrated Kind.
- `apps/ezagent_core/lib/ezagent/invocation.ex` (steps 1-4, 11-12) + `apps/ezagent_core/lib/ezagent/kind/runtime.ex` (steps 5-10) — the 12-step dispatch flow. Steps 5-10 collapse into `Commanded.Application.dispatch/2` after migration; steps 5.5 (CapBAC) + 5.6 (workspace isolation) move to a pre-dispatch authz pipeline (§4.5).
- `apps/ezagent_core/lib/ezagent/kind/snapshot.ex` — the per-Kind snapshot table. Becomes the Commanded aggregate snapshot store for migrated Kinds; remains in service for any not-yet-migrated Kind during the hybrid window.
- `apps/ezagent_core/lib/ezagent/audit.ex` + `Ezagent.Audit.Writer` — the SQLite `invocations` audit table. Becomes redundant for migrated Kinds (the event stream IS the audit log); REMAINS for un-migrated Kinds and for cross-cutting telemetry that isn't a domain event (e.g. `[:ezagent, :authz, :denied]` deny-side audit).
- `docs/superpowers/specs/2026-05-27-uri-canonicalization.md` — the canonical `%URI{}` chokepoint. Aggregate ID derivation in §4.6 routes through `Ezagent.URI.parse!/1` and emits `URI.to_string/1` for the router `:identify` clause.
- `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` — the dispatch-time authz invariant (step 5.5 chokepoint). §4.5 of this SPEC explains how the authz check moves out of `Kind.Runtime.handle_dispatch/4` into a pre-dispatch pipeline that wraps `Commanded.Application.dispatch/2`, preserving the chokepoint.

**Reference libraries:**
- [commanded](https://github.com/commanded/commanded) — CQRS/ES framework for Elixir. v1.4.10 latest. ([hexdocs](https://hexdocs.pm/commanded))
- [eventstore](https://github.com/commanded/eventstore) — PostgreSQL-backed event store for Elixir. v1.4.8 latest.
- [commanded_eventstore_adapter](https://hex.pm/packages/commanded_eventstore_adapter) — adapter wiring `commanded` to `eventstore`.
- [commanded_ecto_projections](https://hex.pm/packages/commanded_ecto_projections) — Ecto-backed read-model projector helpers.
- [Conduit reference app](https://github.com/slashdotdash/conduit) — Phoenix + Commanded Medium clone.
- [Gift-card demo](https://github.com/slashdotdash/gift-card-demo) — Phoenix LiveView + Commanded reference.

---

## 1. Problem statement — why migrate

### 1.1 The destroy-lifecycle 4-round codex failure as proof

SPEC #440 (entity destroy lifecycle) hit 4 consecutive codex REJECT rounds without converging. Each round addressed a different facet of the same structural shortfall:

- **r1 REJECT — atomicity:** the 7-step destroy cascade (revoke caps → unbind external mirrors → terminate child agents → drop session memberships → unlink lineage → terminate Kind processes → write deletion-audit row) cannot be atomic under the current Kind=GenServer model. Each step is a separate `Invocation.dispatch/1` against a different Kind; if step 4 raises (target Kind crashes mid-leave), steps 1-3 already committed and there is no transactional roll-back primitive. Mitigation proposed: "destroy_lock" GenServer per parent URI to serialize concurrent destroys. Codex flagged: lock acquisition does not give atomicity, only serialization; the partial-failure window persists.
- **r2 REJECT — fence/saga:** proposed a "destroy fence" mechanism — a sweeper that re-runs steps until idempotent. Codex flagged: the sweeper requires re-entrant idempotency on every step's invoke handler, retrofitting that onto 11 existing behaviors is a different SPEC; and the sweeper's progress is itself a workflow that needs its own state machine.
- **r3 REJECT — destroy-as-state-flag:** proposed a `:destroyed_at` slice column on each Kind so dispatch could deny invocations on a tombstoned Kind. Codex flagged: tombstone is a soft delete; the requirement was hard delete + cap unwind + audit; tombstone leaks the dead URI forever and does not address cascade.
- **r4 REJECT — destroy_log table:** proposed a side-table that records cascade progress + a reconciler that resumes interrupted destroys on boot. Codex flagged: this IS event-sourcing, badly. The `destroy_log` table is a hand-rolled append-only event stream; the reconciler is a hand-rolled Process Manager; we are reimplementing Commanded primitives one ad-hoc table at a time.

**Codex r4 verdict text (quoted from the review):** *"The destroy_log approach is event-sourcing without the framework. Every problem you're trying to solve — multi-aggregate atomic operations, mid-failure resumption, audit trail invariant — is what Commanded was designed for. This SPEC keeps re-inventing Commanded internals piecemeal. Step back: do you need to keep the GenServer+slice model, or is the architectural ceiling here?"*

That codex verdict is the proximate cause of THIS SPEC. The atomic-destroy problem is intractable in the current model. The CQRS/ES model has structural primitives — Aggregates carry their own state from events, Process Managers orchestrate multi-aggregate workflows with built-in compensation, EventStore append is the audit log, snapshots are a cache not a source of truth — that resolve all 4 codex blocker classes without re-invention.

### 1.2 The bigger class — every multi-Kind workflow hits this

Destroy is the most acute case, but the same pattern recurs:

- **`BootReconciler`** (Phase 3 PR-EM-9, external-mirror-domain SPEC §3.1) — on Application boot, scan the `external_mirror_bindings` projection table and re-spawn Workers for each persisted binding. The reconciler is a hand-rolled scan-and-spawn loop that races against Session boot (Worker `post_init/2` may run before its target Session reaches `:ready`, requiring a buffer + retry layer in `PendingDelivery`). Under CQRS/ES, "Worker for binding X exists when binding X exists in the read model" is a saga that subscribes to `BindingCreated` events and emits `SpawnWorker` commands. No boot scan; no race; the saga state machine encodes the ordering.
- **`SpawnRegistry` race classes** (Phase 2-3 incident retros) — concurrent `Kind.spawn/2` calls for the same URI race on `DynamicSupervisor.start_child`, with `{:error, {:already_started, pid}}` handled idempotently by callers BUT the second caller's `init_slice/1` args silently lost (the first call wins). Under CQRS/ES, "first command at this aggregate ID creates it" is a primitive — the aggregate doesn't exist until the create command lands; subsequent create commands fail with `{:error, :already_created}` deterministically; the aggregate state is built from the events of the FIRST creation regardless of which process emitted them.
- **Capability grant-time check ambiguity** (PR-CC-2 / caps-cleanup-v1 SPEC) — `Behavior.Identity.grant_cap` must verify the granter held the underlying ownership cap AT GRANT TIME, but caps are a slice that mutates on every grant — the check is a read-after-write against the granter's own slice. The current model resolves this with synchronous `GenServer.call` ordering (`Kind.Server.handle_call` serializes per-instance). Under CQRS/ES, the granter's caps at grant time are derivable from the granter Aggregate's event-replayed state at the instant the grant command was applied; the command's `execute/2` reads the aggregate state and emits the `CapGranted` event atomically (the aggregate-level serialization gives the same property; it's also durable in the event stream, so the audit query "what caps did the granter hold when they granted X" becomes a stream filter, not a forensic snapshot read).
- **Workspace cap-vis 5-round iteration** (`2026-05-27-workspace-cap-based-visibility.md`) — 5 codex rounds REJECT mostly over policy-helper placement + admin-bypass corner cases. The cap-vis SPEC itself was straightforward (`list_workspaces_for(caller, caps)`); the rounds went into "where does the helper live"; "does the helper match cross-workspace runtime semantics"; "does the helper handle the wildcard cap path"; "does the system-membership predicate live on Identity or Capability". Under CQRS/ES, "workspace visibility for caller" is a read-model query against a `workspace_visibility_per_caller` projection — the projection encodes the policy in one place at projection-time; the query at LV-read-time is `SELECT workspace_uri FROM ... WHERE caller_uri = ?`. Policy iteration happens in the projector, not at every read site, and the read site cannot drift from the policy.

The thread: **every multi-Kind workflow exposes a missing primitive in the current model — atomic cross-Kind operations, deterministic saga resumption, queryable historical state, single-place policy projection.** CQRS/ES provides each of these as a framework feature. The current model rebuilds each one ad-hoc per SPEC, and each ad-hoc rebuild costs 3-5 codex rounds.

### 1.3 Diagnosis — current architecture has CRUD but no event log

The current ezagent state model is structurally:

```
External request (LV / CLI / Feishu / MCP / HTTP)
  → Adapter constructs %Invocation{}
  → Invocation.dispatch/1
    → Idempotency check (step 1)
    → ReadyGate gate (step 4)
    → Kind.Runtime.handle_dispatch (steps 5-10):
      - BehaviorRegistry lookup
      - CapBAC step 5.5
      - Workspace isolation step 5.6
      - Behavior.invoke/4 — returns {:ok, new_slice} | {:ok, new_slice, result}
      - Kind.Server merges new_slice into state.state[slice_key]
      - Persistence write (if :on_change and changed)
      - Telemetry emit
    → reply/2 routes result to caller
```

State mutation is **CRUD-shaped**: each `Behavior.invoke/4` is a function `(slice, args) -> new_slice`. There is no formal command/event split. The audit log (`invocations` table) is a side-channel recording of `(caller, target, action, result)` tuples written by a telemetry handler — it is NOT the source of truth (the slice/snapshot is). Cross-Kind workflows are sequences of `Invocation.dispatch/1` calls strung together imperatively in caller code (e.g. `EzagentDomainChat.create_session/3` orchestrates 5 dispatches across 4 Kinds with try/rescue cleanup at each step).

The shape this leaves us with:
- **No formal command** — `Behavior.invoke/4`'s `args` argument is just a map; there is no Command struct, no router, no central catalog of what commands exist.
- **No formal event** — `Behavior.invoke/4`'s return is a new slice + optional result; the slice mutation is not named, not durable, not subscribable.
- **No saga primitive** — multi-Kind orchestration is imperative caller code with manual try/rescue cleanup; partial-failure compensation is ad-hoc per call site.
- **No replay** — restart restores the latest snapshot only; the history between snapshots is lost (audit table is a side-channel, not replayable into Kind state).
- **No subscription** — LV reads slice directly via `Kind.get_slice/2` (sync `GenServer.call`); to react to a slice change, LV must poll OR rely on `Phoenix.PubSub` broadcasts from Behavior code (e.g. `Behavior.Chat` broadcasts `:message_appended`). Each broadcast is opt-in per Behavior; there is no automatic event stream.

### 1.4 Hypothesis — CQRS/ES provides the missing primitives structurally

Commanded + EventStore provides:
- **Command** as a struct, dispatched through a router with `:identify` clauses that route by aggregate UUID. Catalog is the router config.
- **Event** as a struct, emitted by `Aggregate.execute/2`, persisted to the event stream BEFORE `Aggregate.apply/2` mutates the in-memory state. Audit is the event stream.
- **Aggregate** as a process, restored from event replay (+ optional snapshot every N events). State IS derived from events.
- **Process Manager (Saga)** as a stateful event subscriber that emits commands in response to events. Multi-aggregate workflows are explicit + resumable + compensable.
- **Projection** as an event-subscribing read-model updater (Ecto-backed via `commanded_ecto_projections`). LV reads the projection table; the projector updates it from events. Read-model decoupling is built-in.
- **Consistency mode** — `dispatch(cmd, consistency: :strong)` blocks until strong-consistent projectors have caught up; `:eventual` returns immediately. The read-after-write problem is a flag at dispatch time, not a hand-rolled wait loop.

Every one of §1.2's pain points dissolves to a framework primitive. The migration cost is real (Phase plan in §6), but the recurring cost of NOT migrating is 3-5 codex rounds per SPEC that touches a multi-Kind workflow — and we have one or more such SPECs every week.

---

## 2. Decision — adopt Commanded + EventStore as primary state model

### 2.1 What we adopt

| Component | Lib | Role |
|---|---|---|
| `Commanded.Application` | `commanded` | Per-deployment dispatch + aggregate hosting boundary |
| `Commanded.Commands.Router` | `commanded` | Command → Aggregate routing via `:identify` |
| `Commanded.Aggregates.Aggregate` | `commanded` | The behaviour replacing `Ezagent.Kind`'s GenServer pattern |
| `Commanded.ProcessManagers.ProcessManager` | `commanded` | Multi-aggregate workflows (the new home for destroy cascade etc.) |
| `Commanded.Event.Handler` | `commanded` | Non-projection event subscribers (e.g. mirror events to external systems, dispatch follow-up commands without state — the `:eventually consistent` variant of a process manager when state machine is overkill) |
| `Commanded.Projections.Ecto` | `commanded_ecto_projections` | Read-model projectors that Ecto.Multi-update tables on events |
| `EventStore` | `eventstore` | Postgres-backed event persistence |
| `Commanded.EventStore.Adapters.EventStore` | `commanded_eventstore_adapter` | Adapter wiring `commanded` to `eventstore` |
| `Commanded.EventStore.Adapters.InMemory` | bundled | Test / dev-loop event store |

### 2.2 What we do NOT adopt yet

- **EventStoreDB** (the standalone Erlang/Scala event store via `commanded_extreme_adapter`) — operationally heavier than Postgres + `eventstore` lib, and we have no clustering need at current scale. Postgres ops is widespread; EventStoreDB is niche. (Discussion in §7.4 + §10 OQ-1.)
- **Snapshot store on EventStoreDB** — we use Commanded's built-in snapshot-every-N-events stored in the same Postgres `eventstore` schema. The existing `kind_snapshots` SQLite table is retired per Kind on migration.
- **Multi-app Commanded topology** (one `Commanded.Application` per bounded context with cross-app event bridges) — overkill for our 5-Kind model; we run ONE `Ezagent.CommandedApp` with all aggregates + all process managers + all projectors. Splitting is a Phase N+1 question if scale demands it.

### 2.3 What stays unchanged (the external API surface)

- Phoenix.Channel `handle_in/3` callbacks. Today they construct `%Invocation{}` and call `Invocation.dispatch/1`; post-migration they construct `%Cmd{}` and call `Ezagent.CommandedApp.dispatch/2`. The channel topic, message shape, response shape are unchanged from the JS client's perspective.
- LiveView `mount/3` + `handle_event/3`. Same change: dispatch a Command instead of an Invocation. Reads come from projection queries instead of `Kind.get_slice/2` (§5).
- CLI `mix ezagent.*` tasks. Same dispatch change. Reads from projection tables.
- HTTP plug controllers (e.g. `EzagentWeb.SessionController.create`). Same.
- The `URI`-based addressing model. Aggregate UUIDs ARE the canonical URI strings; no new addressing scheme.
- Capability semantics. The cap struct + matcher are unchanged. The check moves from `Kind.Runtime` step 5.5 to a pre-dispatch pipeline (§4.5).
- The Behavior contract surface visible to plugin authors stays *substantively* the same — they declare a Kind (now an Aggregate), state (now event-derived), actions (now commands), invoke logic (now `execute/2` returning events + `apply/2` returning new state). The interface(s) differ syntactically but the mental model is preserved (§4.2 maps each callback).

### 2.4 What MUST change (the internals)

- `Ezagent.Kind.Server` is retired per-Kind on migration. The shared GenServer is replaced by `Commanded.Aggregates.Aggregate` processes managed by Commanded's `AggregateRegistry`.
- `Ezagent.Kind.Snapshot` is retired per-Kind on migration. Commanded's snapshot store (Postgres-backed, configured via `snapshot_every:`) replaces it.
- `Ezagent.Audit.Writer` (the `invocations` SQLite table) is retired for domain events; the event stream IS the audit log. Non-domain telemetry (denied authz, persistence-failure, cross-cutting boot/teardown) stays in the SQLite audit table (§4.7).
- `Ezagent.Invocation.dispatch/1` is retired as the public dispatch entry. Replaced by `Ezagent.CommandedApp.dispatch/2`. The 12-step flow becomes a 5-step pre-dispatch pipeline + Commanded's aggregate hosting (§4.5).
- `Ezagent.KindRegistry` is retired per-Kind on migration. Aggregate lookup is handled by Commanded internally; cross-Kind references go through events + sagas, not registry lookups.
- `Ezagent.SpawnRegistry` is retired per-Kind on migration. "Spawn" becomes "first command at aggregate ID creates it" — the aggregate doesn't exist until the create command applies; subsequent create commands fail deterministically.
- `Ezagent.PendingDelivery` is retired post-Phase-10-A (the not-yet-ready buffer pattern). Aggregates don't have a `:not_ready` state in the same sense — they're either created (history non-empty) or not (history empty); a dispatch against a non-created aggregate either creates it (per the `execute/2` clause for empty state) or fails with the aggregate's "not created" error.
- `Ezagent.Persistence.scope_by_workspace/2` and `workspace_uri_for/1` stay — they apply to PROJECTION tables now, not slice writes. The workspace isolation invariant is enforced in projectors + read queries.

### 2.5 Decision boundary — what this SPEC does and does not commit to

This SPEC commits to:
- Adopting Commanded + EventStore as the future state model.
- The 4-phase migration plan in §6 (Phase 10-A through 10-D), with explicit unwind at each phase boundary.
- The mapping table in §4.4 from current Kinds to Aggregates + the cross-Kind workflow inventory in §4.4.2 that defines which Process Managers exist post-migration.
- The dev-loop story (in-memory adapter for fast tests; Postgres for dev + prod). See §7.3.
- The audit decomposition in §4.7 — domain events go to event store, telemetry-only events stay in SQLite.

This SPEC explicitly does NOT commit to:
- The exact event schema for each Aggregate (per-Aggregate impl SPECs in Phase 10-B through 10-D).
- The exact projection table shape for each read-model (impl-time decisions per phase).
- Whether process managers run in-process with the Commanded Application or in a sibling supervisor (§10 OQ-5).
- Snapshot-every-N tuning per Aggregate (default = 50, override per-Aggregate where benchmarks justify it).
- The exact CLI / LV form changes for any command (per existing CLI ↔ LV isomorphism invariant in `IMPLEMENTATION_ROADMAP.md` §1.4; preserved post-migration but the specific binding details land in impl PRs).

---

## 3. Phoenix + Commanded hybrid integration — the critical research question

This is the section Allen specifically flagged for depth. The integration is **not novel** (production references in §3.6) but the patterns are subtle. The whole point of CQRS is the asymmetry between write-path (commands dispatched to aggregates, events persisted) and read-path (projections queried). LiveView and Phoenix.Channel sit on BOTH paths. This section enumerates each interaction.

### 3.1 The "Phoenix at the edges, Commanded at the core" pattern

The canonical pattern across Conduit, gift-card-demo, segment-challenge, and Honeydew is:

```
                       ┌─────────────────────────────┐
                       │  EXTERNAL TRANSPORT          │
                       │  (HTTP / WS / LV / CLI / MCP)│
                       └──────────────┬──────────────┘
                                      │
                                      ▼  (constructs %Cmd{})
                       ┌─────────────────────────────┐
                       │  PRE-DISPATCH PIPELINE       │
                       │  - authn (already happens)   │
                       │  - authz (CapBAC step 5.5)   │
                       │  - workspace isolation 5.6   │
                       │  - idempotency check         │
                       │  - URI canonicalization      │
                       └──────────────┬──────────────┘
                                      │
                                      ▼  Ezagent.CommandedApp.dispatch(cmd, opts)
                       ┌─────────────────────────────┐
                       │  COMMANDED.APPLICATION       │
                       │  Router → :identify by id    │
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
                                      ▼  events appended to event store
                       ┌─────────────────────────────┐
                       │  EVENT STORE (Postgres)      │
                       └──────────────┬──────────────┘
                                      │
                ┌─────────────────────┼─────────────────────┐
                │                     │                     │
                ▼                     ▼                     ▼
        ┌──────────────┐    ┌──────────────┐      ┌──────────────┐
        │ PROJECTOR    │    │ PROCESS MGR  │      │ HANDLER      │
        │ Ecto.Multi   │    │ saga state + │      │ side effects │
        │ updates      │    │ emits cmds   │      │ (notifs, fan │
        │ read tables  │    │              │      │  out, etc.)  │
        └──────┬───────┘    └──────┬───────┘      └──────────────┘
               │                   │
               ▼                   ▼
       ┌─────────────┐     ┌─────────────┐
       │  LV / API   │     │  AGGREGATE  │
       │  reads from │     │  (follow-up │
       │  read table │     │   command)  │
       └─────────────┘     └─────────────┘
```

Phoenix.Channel and LiveView sit at the top (write-side, constructing commands) and the bottom (read-side, querying projections). Commanded owns the middle. Plugin authors write commands, events, aggregates, projectors, and process managers — they never touch the event store directly.

### 3.2 LiveView write-path — handle_event/3 → dispatch

The reference pattern from `gift-card-demo/lib/gift_card_demo/gift_cards.ex`:

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

LiveView's `handle_event/3` calls `GiftCards.issue_gift_card(amount)`. The function constructs a Command struct and dispatches. No direct EventStore access; no manual event emission; the aggregate's `execute/2` decides what events fire.

**For ezagent**, the equivalent context module is per-Domain (one per `apps/ezagent_domain_*`) — `Ezagent.Domain.Chat.create_session(...)`, `Ezagent.Domain.Identity.grant_cap(...)`, etc. Each context function:
1. Builds a `%Cmd{}` struct with the canonical aggregate URI as `:id`.
2. Calls `Ezagent.CommandedApp.dispatch(cmd, opts)` with opts derived from the caller's intent (`consistency: :strong` for read-after-write paths; `:eventual` otherwise — see §3.3).
3. Returns `:ok` / `{:error, reason}`.

The pre-dispatch pipeline (§4.5) wraps `Ezagent.CommandedApp.dispatch/2` so authz, workspace isolation, idempotency, and URI canonicalization happen ONCE at the boundary, not in every domain context function.

### 3.3 Read-after-write consistency — THE critical question

When LiveView `handle_event` dispatches a command and then re-renders, will the re-render see the new state?

**Three modes Commanded supports:**

**(a) `consistency: :eventual` (default).** Dispatch returns `:ok` as soon as the event is persisted. Projectors run asynchronously. LiveView's re-render fires immediately on dispatch return — but the projection table may not yet reflect the change. The next push from PubSub or projector `after_update/3` triggers a follow-up render with the new state. UX: a momentary stale read; users see the change within a typical 1-10ms projector latency.

**(b) `consistency: :strong`.** Dispatch blocks until ALL projectors flagged `consistency: :strong` have committed. LiveView's re-render after dispatch sees the new state synchronously. Cost: dispatch latency = event-append (5-50ms) + slowest strong projector commit (typically another 5-20ms). For dispatches that fan out to multiple strong projectors, the bound is max of them. ([hexdocs Commands.md](https://hexdocs.pm/commanded/Commanded.Commands.Router.html))

**(c) `consistency: [ProjectorA, ProjectorB]`.** Block until specific named projectors catch up. The middle ground: synchronous wait for only the projectors that feed THIS LiveView, async for everything else.

**ezagent's choice — per dispatch site, default `:eventual`, opt-in `:strong`:**

The default for `Ezagent.CommandedApp.dispatch/2` is `consistency: :eventual` because the majority of dispatches (chat send, audit-only writes, fanout-style mutations) do not require read-after-write at the dispatch site. The dispatch site opts into `:strong` (or named-projector-list) when:

- The same LiveView render reads back the projection it just updated (e.g. create_session → wizard redirects to /sessions/X and renders the session detail — the detail projection must be present).
- A CLI command prints the resulting state to stdout (deterministic CLI return).
- A controller responds 201 with the created resource's projection state.

The opt-in mechanism is explicit at the dispatch site: `Ezagent.CommandedApp.dispatch(cmd, consistency: :strong)`. Defaulting to `:eventual` keeps the hot path fast; the LV/PubSub pattern (3.4) makes the eventual case nearly invisible to users.

**Process-manager-emitted commands always use `:eventual`** — the saga is itself an event subscriber, so by the time it dispatches a follow-up command, the originating event has already persisted; blocking on strong consistency between saga-internal steps would deadlock with the saga's own event subscription.

### 3.4 LiveView read-path — subscribe to projections, not events

The reference pattern from gift-card-demo:

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

And in the projector:

```elixir
project %GiftCardIssued{...} = event, fn multi -> ... end

def after_update(_event, _metadata, %{gift_card_summary: summary}) do
  Registry.dispatch(Registry.GiftCardSummary, :gift_card_summary, fn entries ->
    for {pid, _} <- entries, do: send(pid, {:gift_card_summary, summary})
  end)
end
```

**The flow:**
1. LV `mount/3` subscribes to a per-projection Registry topic.
2. LV initial render reads the projection table directly (sync DB query).
3. Projector's `after_update/3` callback (a `commanded_ecto_projections` hook) fans out the updated row to all subscribers.
4. LV `handle_info` re-fetches + re-renders.

**For ezagent**, we replace `Registry` with `Phoenix.PubSub` (already used elsewhere in the codebase; uniform topic naming). Per-Aggregate-class projector defines a topic like `"ezagent:projections:user:#{user_uri}"` and broadcasts on `after_update/3`. LV subscribes during mount.

The pattern is symmetric across all 5 Kinds — User, Session, Agent, Workspace, Worker — each gets a projector + a PubSub topic; LV subscribes per the URIs it's rendering.

**The cold-load problem.** When LV mounts and the projection has not yet caught up to the LATEST events (a race window because the LV mount runs in parallel with the projector subscription), the initial render shows stale state. Two solutions:

- **`Commanded.Subscriptions.wait_for/3`** — the LV mount blocks on a specific aggregate UUID + version until the projector catches up. Slightly more synchronous than the standard pattern but eliminates the stale-mount window when the LV is mounted RIGHT AFTER a dispatch (e.g. wizard redirect-then-mount).
- **Dispatch-then-mount-with-aggregate-version** — the dispatching code passes the `:aggregate_version` from the dispatch result through the redirect URL or session; the LV mount waits for THAT specific version before rendering. This is the gift-card-demo pattern, scaled up.

For ezagent, the standard LV pattern uses `consistency: :strong` on the dispatch that precedes the redirect; the destination LV mounts AFTER the dispatch returns, so the projection is guaranteed to be caught up at mount time. The wait_for/3 helper exists as a fallback for cross-tab races (user opens detail page in tab 2 while tab 1 is dispatching).

### 3.5 Phoenix.Channel write-path (CLI, agent_bridge, feishu)

Phoenix.Channel `handle_in/3` is structurally identical to LV `handle_event/3` — it constructs a command and dispatches. The only difference is the reply mechanism:

- **LV** — re-render is triggered automatically by `assign/2`; the user sees the result in HTML.
- **Channel** — `handle_in/3` returns `{:reply, {:ok, payload}, socket}` and the JS client (cli, agent_bridge) receives the reply. The dispatch result (typically `:ok` or `{:ok, %ExecutionResult{}}`) is serialized into the channel payload.

For commands whose dispatch site needs to return data to the caller (e.g. CLI `mix ezagent.user.token --mint` prints the minted token):
- The dispatch uses `consistency: :strong` (so the token is in the read model).
- The dispatch site queries the read model immediately after dispatch returns.
- The dispatch result + read-model row are returned together to the channel.

There is no `Behavior.invoke/4`-style return-value-in-the-event-itself pattern in Commanded — events are facts about the past, not return values. If the caller needs a return value, the return is derived from the read model AFTER dispatch.

### 3.6 Production references

| Project | Stack | Notes | URL |
|---|---|---|---|
| **Conduit** | Phoenix + Commanded | RealWorld example app (Medium clone); mature; demonstrates router, aggregates, projectors, process managers, Phoenix views | https://github.com/slashdotdash/conduit |
| **Gift-card-demo** | Phoenix LiveView + Commanded | Smaller, LV-focused; shows projection-via-Registry pattern + `after_update/3` hook | https://github.com/slashdotdash/gift-card-demo |
| **Segment Challenge** | Phoenix + Commanded | Production app for Strava competitions; larger-scale aggregate inventory | https://github.com/slashdotdash/segment-challenge |
| **Honeydew** | Phoenix LiveView + Commanded + Postgres ("CELP stack") | Starter template; demonstrates standard wiring | https://github.com/quarterpi/honeydew |
| **Casavo (medium post)** | Production company | Uses Commanded + LiveView for monitoring/debug tools sitting on top of event store; demonstrates "LiveView as event-store observer" pattern (we will use the same for `/admin/events` page) | https://medium.com/casavo/supercharging-our-event-sourcing-capabilities-with-phoenix-liveview-c4a9d1d4ab99 |
| **ElixirMerge guide** | Walkthrough | EventStoreDB + Phoenix + LiveView CQRS/ES guide | https://elixirmerge.com/p/comprehensive-guide-to-implementing-es-cqrs-with-eventstoredb-phoenix-and-liveview |
| **Cantido blog post** | Phoenix LV event-sourced | LV subscribes to `$all` event stream + push_event to JS hook for high-frequency render | https://dev.to/cantido/phoenix-liveview-but-event-sourced |
| **Christian Alexander blog post** | Phoenix API + Commanded | Read-after-write strong-consistency pattern walkthrough | https://christianalexander.com/2022/05/09/elixir-commanded/ |

**Verdict on maturity:** the integration is established; reference apps exist; community has Q&A on ElixirForum dating back to 2018. Not pioneering. The "Phoenix at the edges, Commanded at the core" pattern is the de-facto standard. ezagent is well within the precedented use-cases.

### 3.7 Failure modes — what can go wrong

| Failure | Cause | Recovery | SPEC §reference |
|---|---|---|---|
| **Aggregate process crashes mid-replay** | A corrupted event in the stream OR a bug in `apply/2` raises during state reconstruction | Commanded's `AggregateRegistry` restarts the aggregate; replay resumes from the last snapshot. If the bug is in `apply/2`, the crash loops until the code is fixed. Pin: snapshot every N events bounds the replay scope so a code fix immediately recovers (replay starts from the snapshot, not from event 0). | §4.4 + §6 Phase 10-A |
| **EventStore Postgres outage** | DB down | `dispatch/2` returns `{:error, _}`. Caller treats this as transient failure (retry policy). Aggregates in-memory state survives; on Postgres recovery, dispatch resumes. Sagas pause (their subscription stops receiving events); on recovery they resume from the last processed event. | §7.4 + §8 |
| **Saga partial failure** | Process Manager's `handle/2` returns a command that the target aggregate rejects | Saga's `error/3` callback decides: retry-with-backoff, compensate (dispatch reverse command), skip-and-continue, or stop. The compensation logic is explicit code in the saga; no framework auto-rollback. | §3.8 destroy cascade specifically |
| **New event type added to existing aggregate** | Code adds a new event variant the aggregate now emits | `apply/2` MUST have a clause for the new event. The aggregate's `behaviors/0`-equivalent list (the aggregate module itself) is the source of truth; the new event is also added to the projector's `project` clauses. | §10 OQ-3 + §11 q#6 — event schema evolution |
| **Old event type removed** | Code stops emitting a type that's in historical streams | `apply/2` MUST still have a clause for the historical event (replay needs it). The clause can be a no-op if the field is no longer relevant; the event itself is not deleted from history. | §10 OQ-3 |
| **Field added to existing event** | Need to add `caller_metadata` to `MessagesPosted` events | `Commanded.Event.Upcaster` impl runs at event-read time, transforming old events into the new shape before they reach `apply/2`. Historical events stay byte-identical on disk; in-memory shape is upgraded. | §10 OQ-3 |
| **Projection drift from aggregate** | Projector has a bug, write the wrong column | Rebuild from event stream: stop projector → truncate projection table → restart projector with `start_from: :origin`. Cost: O(events) replay; bounded by `snapshot_every` for aggregate snapshots but not for projections (projection replay reads the full stream). For our scale, projection replay is minutes not hours. | §7.4 + §8 |
| **Hot aggregate with 10K+ events** | A heavily-used Session aggregates 10K MessagesPosted over its lifetime | Snapshot every 50 events bounds replay to ≤50 events on cold start; warm aggregates stay in memory. Worst-case replay = ~50 events × `apply/2` latency (μs each) ≈ 1ms. | §7.2 |
| **Two writers race on same aggregate** | Concurrent LV + CLI both dispatch a command for the same aggregate UUID | Commanded serializes per aggregate (one process per UUID); the second command queues behind the first. Optimistic concurrency error only if explicit `expected_version` is set (which we don't for ezagent — we accept implicit serialization). | §4.5 |
| **Event store schema breaking change** | Commanded major version upgrade introduces event store table changes | Upgrade migration runs against Postgres; events are NOT rewritten (the event payload is JSON, schema-flexible); only the surrounding metadata columns change. Read [commanded changelog](https://hexdocs.pm/commanded/changelog.html) before each upgrade. | §7.4 |

### 3.8 Saga compensation pattern for the destroy cascade (the original trigger)

The destroy cascade from SPEC #440, expressed as a Process Manager:

```elixir
defmodule Ezagent.Saga.DestroyAgentSaga do
  use Commanded.ProcessManagers.ProcessManager,
    application: Ezagent.CommandedApp,
    name: "DestroyAgentSaga"

  defstruct [:agent_uri, :workspace_uri, :step, :caps_revoked, :children_destroyed]

  # Starts on AgentDestroyRequested event (emitted by Agent aggregate
  # when it accepts a Destroy command).
  def interested?(%AgentDestroyRequested{agent_uri: uri}), do: {:start, uri}

  # Continues for each follow-up event the saga emits commands for.
  def interested?(%AgentCapsRevoked{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentChildrenDestroyed{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentMembershipsDropped{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentLineageUnlinked{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentTerminated{agent_uri: uri}), do: {:stop, uri}

  # Step 1: Revoke all caps held by this agent.
  def handle(%__MODULE__{step: nil}, %AgentDestroyRequested{} = ev) do
    %RevokeAllCapsHeldBy{agent_uri: ev.agent_uri}
  end

  # Step 2: After caps revoked, destroy child agents (lineage cascade).
  def handle(%__MODULE__{step: :caps_revoked} = pm, %AgentCapsRevoked{}) do
    case Ezagent.Projection.AgentLineage.children_of(pm.agent_uri) do
      [] -> %SkipChildrenDestruction{agent_uri: pm.agent_uri}
      children -> %DestroyChildAgents{agent_uri: pm.agent_uri, children: children}
    end
  end

  # Step 3: Drop session memberships.
  def handle(%__MODULE__{step: :children_destroyed} = pm, %AgentChildrenDestroyed{}) do
    %DropAllSessionMembershipsFor{agent_uri: pm.agent_uri}
  end

  # Step 4: Unlink lineage.
  def handle(%__MODULE__{step: :memberships_dropped} = pm, %AgentMembershipsDropped{}) do
    %UnlinkLineage{agent_uri: pm.agent_uri}
  end

  # Step 5: Terminate the aggregate (final).
  def handle(%__MODULE__{step: :lineage_unlinked} = pm, %AgentLineageUnlinked{}) do
    %TerminateAgent{agent_uri: pm.agent_uri}
  end

  # State machine — track step progression.
  def apply(%__MODULE__{} = pm, %AgentDestroyRequested{} = ev),
    do: %{pm | agent_uri: ev.agent_uri, workspace_uri: ev.workspace_uri, step: :requested}

  def apply(pm, %AgentCapsRevoked{}), do: %{pm | step: :caps_revoked, caps_revoked: true}
  def apply(pm, %AgentChildrenDestroyed{}), do: %{pm | step: :children_destroyed, children_destroyed: true}
  def apply(pm, %AgentMembershipsDropped{}), do: %{pm | step: :memberships_dropped}
  def apply(pm, %AgentLineageUnlinked{}), do: %{pm | step: :lineage_unlinked}

  # Error / compensation.
  def error({:error, :agent_not_found}, _cmd, _ctx) do
    # If the agent aggregate doesn't exist by the time we reach step 5,
    # the cascade already destroyed it via another path — idempotent.
    {:skip, :discard_pending}
  end

  def error({:error, _failure}, _cmd, %{context: %{retries: n}}) when n >= 3 do
    # Three failures on the same step — stop and require operator intervention.
    # Saga state persists; operator can inspect + resume.
    {:stop, :too_many_failures}
  end

  def error({:error, _failure}, _cmd, %{context: ctx}) do
    {:retry, 1_000, Map.update(ctx, :retries, 1, &(&1 + 1))}
  end
end
```

**What this resolves vs the SPEC #440 destroy_log table approach:**

| SPEC #440 r4 (destroy_log table) | This SPEC (DestroyAgentSaga) |
|---|---|
| Hand-rolled append-only side-table | Event stream (already append-only by definition) |
| Hand-rolled reconciler that resumes on boot | Saga subscription resumes from last-processed event automatically |
| Hand-rolled "is this step idempotent" discipline per behavior | Each step is a command to a specific aggregate; aggregate handles its own idempotency (`{:error, :already_destroyed}` on repeated destroy) |
| Hand-rolled partial-failure compensation | `error/3` callback + `{:retry, ...}` / `{:stop, ...}` framework primitives |
| Hand-rolled audit row for "destroy cascade progressed to step N" | Each step emits a domain event; the saga state IS the cascade audit |

The destroy cascade becomes ~100 lines of saga code + per-aggregate command/event variants. The framework owns the "atomic" property (atomic w.r.t. each step boundary, with explicit compensation between steps).

### 3.9 Open questions specific to Phoenix integration

These bubble up to §11 codex review:

- Does our LV codebase use enough `assign_new/3` and per-tab session state that we can safely make the read-path projection-driven? (Yes — current LVs already wrap `Kind.get_slice/2` in `assign/2`; the substitution is mechanical.)
- Do we have any code paths that READ FROM the slice DURING a Behavior.invoke/4 of a DIFFERENT Kind (cross-Kind read inside dispatch)? (Yes — `Behavior.Identity.check_grant_authorized` reads the owner URI's slice. Post-migration, this must read from a projection or query the target aggregate via a fresh dispatch — see §11 q#5.)
- Are there places where the audit table's `invocations` rows are queried by SQL with predicates (workspace_uri, time range)? (Yes — `/admin/audit` LV. Post-migration, audit queries against domain events become event-stream filter operations OR queries against an `audit_events` projection table. §4.7 + §11 q#8.)

---

## 4. Mapping current ezagent architecture → CQRS

### 4.1 Concept-by-concept mapping

| Current | New | Migration notes |
|---|---|---|
| `Ezagent.Kind` behaviour module | `Commanded.Aggregates.Aggregate` behaviour-implementing module | Kind module's `type_name/0` / `behaviors/0` / `persistence/0` callbacks → aggregate's `execute/2` / `apply/2` callbacks. `behaviors/0` (the list of Behaviors a Kind composes) is encoded by aggregate's per-event `apply/2` clauses — one clause per event emitted by any of the former behaviors. |
| `Ezagent.Behavior.X` modules with `actions/0` + `invoke/4` | Per-Behavior namespace of Command modules + Event modules + a per-Aggregate `execute/2` clause | E.g. `Behavior.Chat.actions == [:send, :join, :leave]` becomes `Behavior.Chat.Commands.SendMessage`, `JoinSession`, `LeaveSession` + matching `MessagesPosted`, `MemberJoined`, `MemberLeft` events. The dispatch routes the command to the Session aggregate, which has `execute/2` clauses for each command. |
| Per-Kind slice state (`state.state[behavior.state_slice()]`) | Aggregate state struct | The Kind GenServer's `state.state` map of slices becomes the Aggregate's `defstruct` fields. No more "slice key" — every field is just a struct field on the aggregate. |
| `Ezagent.Kind.Snapshot.save_now/3` (sync `:on_change`) | Commanded snapshot-every-N (Postgres-backed) | Default `snapshot_every: 50` events. Per-Aggregate override where benchmarks justify it. Replaces both `:on_change` and `:periodic` strategies. `:ephemeral` becomes "no snapshot config" (replay-from-events always). `:on_terminate` becomes irrelevant (aggregates have no terminate hook in Commanded). |
| `Ezagent.Persistence` per-workspace scoping (`scope_by_workspace/2`) | Same module + same scoping, applied to projection tables | Workspace isolation invariant moves from slice writes to projection writes + read queries. The function survives unchanged; it just operates on `projections.*` tables now. |
| `Ezagent.Invocation.dispatch/1` | `Ezagent.CommandedApp.dispatch/2` (wrapped by pre-dispatch pipeline) | The 12-step flow collapses (steps 5-10 become Commanded internals); steps 1-4 + 5.5-5.6 + 11-12 stay (now in pre-dispatch pipeline + `after_dispatch` projection-trigger). |
| `Ezagent.KindRegistry` (URI → pid) | Commanded's internal aggregate registry | Direct lookups (e.g. for `Kind.get_slice/2`) are replaced by projection reads. No external callers of `KindRegistry.lookup/1` survive post-migration. |
| `Ezagent.SpawnRegistry` + `Kind.spawn/2` | Implicit (first command at aggregate ID creates it) | The "spawn" verb disappears; aggregates are created by their first creation command (`%RegisterUser{}`, `%CreateSession{}`, etc.). `{:error, {:already_started, pid}}` race becomes `{:error, :already_created}` returned deterministically by the aggregate's `execute/2`. |
| Cross-Kind cascade in imperative caller code (e.g. `EzagentDomainChat.create_session/3`'s 5-dispatch orchestration) | Process Manager (Saga) subscribing to the originating event | E.g. `SessionCreated` event triggers `GrantOwnerCapsSaga` which dispatches `GrantCap` commands; saga's error/3 handles compensation. |
| `Ezagent.Audit.Writer` writing to `invocations` SQLite table | Event stream IS the audit log (for domain events) + audit-events projection for queryable subset | Cross-cutting telemetry (denied authz, persistence failure, cc_bridge events) stays in SQLite audit; domain events move to event stream + queryable projection. See §4.7. |
| `kind_snapshots` SQLite table | Commanded snapshot store (in `eventstore` Postgres schema) | For migrated Kinds: existing snapshots are NOT migrated (per `feedback_destructive_migration_anti_pattern`); first command on a migrated Aggregate creates fresh event-sourced state. Snapshot data for un-migrated Kinds remains untouched during the hybrid window. |
| `Ezagent.ReadyGate` (status: `:ready` / `:not_ready` / `:unknown`) | Implicit (aggregate exists ⇔ command can be dispatched) | The `:not_ready` post-init buffering pattern becomes "first creation command must precede any other command"; subsequent commands fail until the aggregate is created. Buffering (the old `Ezagent.PendingDelivery`) is retired for migrated Kinds. |
| `Ezagent.PendingDelivery` (cast buffer for not-yet-ready Kinds) | Retired for migrated Kinds | Cast commands to non-existent aggregates fail at dispatch (`{:error, :aggregate_not_found}` or whatever Commanded returns for a uncreated-aggregate cast — see §11 q#8). |
| `Ezagent.Behavior.X.post_init/2` + `handle_continue/3` (deferred work after Kind register) | Process Manager subscribed to `AggregateCreated`-style event | The split-init pattern from `external-mirror-domain` SPEC §6.1 becomes: aggregate's creation command emits `WorkerCreated`; a `WorkerBootstrapSaga` subscribes to this event and dispatches the follow-up commands (subscribe-to-publisher etc.). |
| `Ezagent.Kind.Server.handle_call({:ezagent_get_slice, slice_key}, ...)` | Projection table query | Cross-process slice read becomes `Ezagent.Projection.X.get(uri)`. The query routes through the read-model module; no aggregate process is touched on read. |
| `Ezagent.CapabilityRegistry` + `Ezagent.BehaviorRegistry` | Stay unchanged | Cap subjects are still registered at compile/boot time; the registry is consulted in the pre-dispatch pipeline. No event-sourcing concern. |
| `@behaviour Ezagent.Behavior` + cap_subjects/0 + data_owner/1 | Stay (with semantic shift) — cap_subjects represents what commands gate via CapBAC; data_owner represents which aggregate owns the underlying data | The CapBAC chokepoint at pre-dispatch is unchanged; the cap_subject IS the command's behavior + action axis. data_owner now points to an aggregate URI rather than a Kind's owning principal. |

### 4.2 The 5 entity Kinds — migration target per Kind

#### 4.2.1 `Ezagent.Entity.User` → `Ezagent.Aggregate.User`

**Current state shape (slice):**
```elixir
%{
  identity: %{caps: MapSet.t(Capability.t())},
  user_credentials: %{...counter state...},
  user_tokens: %{...counter state...}
}
```

**New aggregate state:**
```elixir
defmodule Ezagent.Aggregate.User do
  defstruct [
    :uri,            # canonical URI string — also the aggregate ID
    :workspace_uri,
    :registered_at,
    :password_hash,  # mirrors users.password_hash column
    caps: MapSet.new(),
    tokens: %{},     # token_id → %{minted_at, expires_at, scope, ...}
    destroyed?: false
  ]
  ...
end
```

**Commands:**
- `%RegisterUser{uri, workspace_uri, password_hash, initial_caps}` → emits `%UserRegistered{}`
- `%GrantCapToUser{uri, cap, granted_by}` → emits `%CapGrantedToUser{}` (or `{:error, :grant_not_owner}` if granter lacks data-owner cap)
- `%RevokeCapFromUser{uri, cap, revoked_by}` → emits `%CapRevokedFromUser{}`
- `%MintTokenForUser{uri, token_id, scope, expires_at}` → emits `%TokenMintedForUser{}`
- `%RevokeTokenForUser{uri, token_id}` → emits `%TokenRevokedForUser{}`
- `%RotatePasswordForUser{uri, new_password_hash}` → emits `%PasswordRotatedForUser{}`
- `%DestroyUser{uri}` → emits `%UserDestroyRequested{}` (which triggers `DestroyUserSaga` for cascade)

**Events** — one per command above; payload is the command minus the routing UUID.

**Projections:**
- `user_caps_projection` — Ecto table `projections.user_caps(uri, cap_json, granted_by, granted_at)`. Read by `Behavior.Identity` queries and `/admin/users` LV. `consistency: :strong` for cap-grant dispatches that need read-after-write at the LV.
- `user_profile_projection` — Ecto table `projections.user_profile(uri, workspace_uri, registered_at, destroyed?)`. Read by the user listing LV.
- `user_tokens_projection` — Ecto table `projections.user_tokens(uri, token_id, scope, minted_at, expires_at, revoked_at)`. Read by `entity_tokens` queries (replaces the existing `entity_tokens` SQLite table).

**Persistence:** snapshot every 50 events. User aggregate event volume is low (one event per cap grant + one per token mint); 50 events is ~weeks of activity per active user.

#### 4.2.2 `Ezagent.Entity.Agent` → `Ezagent.Aggregate.Agent`

**Current state (slice):** complex — flavor-specific state + lineage parent_uri + api_keys + workspace_uri + per-template fork state.

**New aggregate state:**
```elixir
defmodule Ezagent.Aggregate.Agent do
  defstruct [
    :uri,
    :workspace_uri,
    :flavor,           # :cc | :codex | :curl | :np | :echo | ...
    :parent_template_uri,
    :lineage_parent_uri,
    :config_dir,
    :api_keys,         # encrypted map; api_keys behavior's slice
    caps: MapSet.new(),
    flavor_state: %{},  # per-flavor sub-state, opaque to non-flavor code
    sessions: MapSet.new(),  # session URIs this agent is a member of
    destroyed?: false
  ]
end
```

**Commands** — split into flavor-agnostic core + per-flavor extensions:

Core:
- `%CreateAgent{uri, workspace_uri, flavor, parent_template_uri, lineage_parent_uri, initial_caps, config_dir}` → emits `%AgentCreated{}`
- `%GrantCapToAgent{uri, cap, granted_by}` → emits `%CapGrantedToAgent{}`
- `%RevokeCapFromAgent{uri, cap, revoked_by}` → emits `%CapRevokedFromAgent{}`
- `%PutApiKeyForAgent{uri, key_name, encrypted_key}` → emits `%ApiKeyPutForAgent{}`
- `%JoinSessionAsAgent{uri, session_uri}` → emits `%AgentJoinedSession{}`
- `%LeaveSessionAsAgent{uri, session_uri}` → emits `%AgentLeftSession{}`
- `%DestroyAgent{uri}` → emits `%AgentDestroyRequested{}` (triggers `DestroyAgentSaga`)

Per-flavor (cc, codex, ...):
- Each flavor exposes a `%FlavorSpecific{...}` command variant; the aggregate's `execute/2` dispatches to the flavor's logic + emits a flavor-specific event. The flavor's `apply/2` clause mutates `flavor_state` opaquely.

**Projections:**
- `agent_profile_projection` — Ecto table for the listing LV.
- `agent_caps_projection` — for cap queries.
- `agent_lineage_projection` — replaces `Ezagent.AgentLineage` registry (parent/child relationships).

#### 4.2.3 `Ezagent.Entity.Session` → `Ezagent.Aggregate.Session`

**Current state:** highest complexity in the codebase — Chat slice + Publisher slice + ExternalMirror slice; members; rules; routing.

**New aggregate state:**
```elixir
defmodule Ezagent.Aggregate.Session do
  defstruct [
    :uri,
    :workspace_uri,
    :template_uri,
    :owner_uri,
    members: MapSet.new(),         # member URIs (users + agents)
    messages_count: 0,             # for backpressure metrics; full history in event stream
    publisher_subscribers: %{},    # subscriber pid → cursor
    external_mirror_bindings: [],  # workers bound to this session
    template_working_copy: nil,
    destroyed?: false
  ]
end
```

**Commands** — many; the largest aggregate by command count.

Core lifecycle:
- `%CreateSession{uri, template_uri, owner_uri, workspace_uri}` → emits `%SessionCreated{}`
- `%DestroySession{uri}` → emits `%SessionDestroyRequested{}` (triggers `DestroySessionSaga`)

Membership (`Behavior.Chat` actions):
- `%JoinSession{uri, joiner_uri}` → emits `%MemberJoinedSession{}`
- `%LeaveSession{uri, leaver_uri}` → emits `%MemberLeftSession{}`
- `%TransferSessionOwnership{uri, new_owner_uri}` → emits `%SessionOwnershipTransferred{}`

Messaging:
- `%PostMessageToSession{uri, message}` → emits `%MessagePosted{}` (also triggers fanout-via-projection)

Publisher (`Behavior.Publisher.SessionImpl`):
- `%SubscribeToSessionPublisher{uri, subscriber_pid, cursor}` → emits `%PublisherSubscriberAdded{}`
- `%UnsubscribeFromSessionPublisher{uri, subscriber_pid}` → emits `%PublisherSubscriberRemoved{}`
- (Note: PIDs in events is a smell — see §11 q#5. Maybe subscribers are tracked outside the aggregate.)

External mirror (`Behavior.ExternalMirror`):
- `%BindExternalMirror{uri, binding_descriptor}` → emits `%ExternalMirrorBound{}`
- `%UnbindExternalMirror{uri, binding_id}` → emits `%ExternalMirrorUnbound{}`

**Projections** — many:
- `session_profile_projection` — basic session state for LV listing.
- `session_messages_projection` — replaces the current `messages` SQLite table. Each `MessagePosted` event → insert row.
- `session_members_projection` — `(session_uri, member_uri, joined_at, left_at)` for membership queries.
- `external_mirror_bindings_projection` — replaces the current `external_mirror_bindings` SQLite table.

#### 4.2.4 `Ezagent.Workspace` → `Ezagent.Aggregate.Workspace`

**Current state:** tiny — workspace metadata + ownership.

**New aggregate state:**
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

**Commands:**
- `%CreateWorkspace{uri, name, created_by}` → emits `%WorkspaceCreated{}`
- `%AddMemberToWorkspace{uri, member_uri}` → emits `%MemberAddedToWorkspace{}`
- `%RemoveMemberFromWorkspace{uri, member_uri}` → emits `%MemberRemovedFromWorkspace{}`
- `%DestroyWorkspace{uri}` → emits `%WorkspaceDestroyRequested{}` (triggers `DestroyWorkspaceSaga` — cascades destroy on all sessions/agents/users in workspace; expensive)

**Projections:**
- `workspaces_projection` — for the picker LV. Replaces current `workspaces` SQLite table.
- `workspace_members_projection` — for the cap-vis SPEC's `list_workspaces_for/2`. Cap-based visibility becomes a JOIN against this + the cap projection.

#### 4.2.5 `Ezagent.ExternalMirror.Worker` → `Ezagent.Aggregate.ExternalMirrorWorker`

**Current state:** binding-specific worker state.

**New aggregate state:**
```elixir
defmodule Ezagent.Aggregate.ExternalMirrorWorker do
  defstruct [
    :uri,
    :session_uri,
    :workspace_uri,
    :binding_descriptor,
    :cursor,                # publisher cursor
    :adapter_state,         # per-adapter internal state
    destroyed?: false
  ]
end
```

**Commands:**
- `%SpawnWorker{uri, session_uri, binding_descriptor}` → emits `%WorkerSpawned{}` (triggers `BootstrapWorkerSaga`)
- `%AdvanceWorkerCursor{uri, new_cursor}` → emits `%WorkerCursorAdvanced{}`
- `%TerminateWorker{uri}` → emits `%WorkerTerminated{}`

**Projection:**
- `external_mirror_workers_projection` — live worker status + last-cursor.

### 4.3 The 11 Behavior modules — disposition

| Behavior | Disposition | Notes |
|---|---|---|
| `Behavior.Identity` | Decomposed into per-aggregate cap-handling commands | Cap grant/revoke commands land on the relevant aggregate (User/Agent); the Behavior module becomes a namespace for the commands + the cap_subjects/0 callback for CapBAC registration. data_owner/1 callback stays (drives saga compensation paths). |
| `Behavior.Chat` | Session aggregate commands + projector | All actions become Session commands; the Behavior module becomes a namespace + cap_subjects + the message projection's update logic. |
| `Behavior.Publisher` + `Behavior.Publisher.SessionImpl` | Session aggregate commands; subscriber tracking moved to projection-side | See §11 q#5 — PID-in-event smell; subscriber tracking is a runtime concern, not an event-sourced one. |
| `Behavior.ExternalMirror` | Session aggregate commands + Worker aggregate commands | Bindings are persisted as Session events; worker spawn is a saga (BootstrapWorkerSaga subscribes to BindingCreated, dispatches SpawnWorker). |
| `Behavior.IdentityAdmin` | Workspace aggregate commands + admin-shortcut helper module | The admin-cap-bypass logic lives in the pre-dispatch authz pipeline; the commands themselves land on the Workspace aggregate. |
| `Behavior.UserCredentials` | User aggregate commands | Password rotation is a User command. The `users.password_hash` column becomes a projection. |
| `Behavior.UserTokens` | User aggregate commands | Token mint/revoke is a User command. The `entity_tokens` table becomes a projection. |
| `Behavior.WorkspaceUserAdmin` | Workspace aggregate commands | User creation as a workspace admin → `AddUserToWorkspace` command on Workspace + `RegisterUser` command on User. The two-command sequence is bundled in a saga (`CreateUserInWorkspaceSaga`). |
| `Behavior.Presence` | Stays slice-based (NOT migrated) | Presence is real-time runtime state, not durable history. Kept as-is on a non-Aggregate `Ezagent.Presence` GenServer (or moved to `Phoenix.Presence` natively). §11 q#7. |
| `Behavior.Sandbox` | Stays runtime-only | Test-fixture-only Behavior; not part of production state model. |
| `Behavior.Routing` | Routes are workspace-scoped rules, stored as Workspace aggregate state | Workspace command `AddRoutingRule` / `RemoveRoutingRule` + matching events. |
| `Behavior.Notifications` | Event handler subscribing to relevant events + emitting notifications | See §11 q#5 — notification emission is a side-effect handler, not state-mutating. `Commanded.Event.Handler` impl. |
| `Behavior.Lifecycle` | Subsumed by aggregate creation/destruction commands | Lifecycle as a Behavior disappears post-migration; each Kind's create/destroy commands replace it. |

### 4.4 Cross-Kind workflows — the saga inventory

Post-migration sagas that replace ad-hoc cross-Kind orchestration:

| Saga | Triggered by | Cascade |
|---|---|---|
| `DestroyAgentSaga` | `AgentDestroyRequested` | RevokeAllCapsHeldBy → DestroyChildAgents → DropAllSessionMembershipsFor → UnlinkLineage → TerminateAgent |
| `DestroyUserSaga` | `UserDestroyRequested` | RevokeAllCapsHeldBy → DestroyChildAgents (where user is parent) → DropAllSessionMembershipsFor → TerminateUser |
| `DestroySessionSaga` | `SessionDestroyRequested` | EvictAllMembers → UnbindAllExternalMirrors → DestroyAllChildAgents → TerminateSession |
| `DestroyWorkspaceSaga` | `WorkspaceDestroyRequested` | DestroyAllSessions → DestroyAllAgents → DestroyAllUsers → TerminateWorkspace (expensive — requires explicit confirm + admin caps; reuses each child's destroy saga) |
| `CreateSessionSaga` | `SessionCreated` | GrantOwnerOrchestratorAdminCap (the bug 2 path from URI canonicalization SPEC) → InvokeTemplateClassInitHooks → AnnounceSessionReady |
| `CreateUserInWorkspaceSaga` | `WorkspaceAdminRequestedUserCreate` | RegisterUser → GrantDefaultCaps → AddUserToWorkspaceMembers → MintInitialToken (optional) |
| `BootstrapWorkerSaga` | `BindingCreated` | SpawnWorker → SubscribeToSessionPublisher → AnnounceWorkerReady |
| `RevokeCapCascadeSaga` | `WorkspaceMembershipRevoked` | RevokeAllWorkspaceScopedCapsFor (the principal whose membership was revoked loses all caps scoped to that workspace) |
| `CapGrantOwnershipVerifySaga` | `CapGrantRequested` | VerifyGranterHasDataOwnerCap (via reading granter's cap projection at command-time) → either dispatch the actual grant or reject with `:grant_not_owner` |

Each saga is ~50-150 lines + the per-step command/event variants. Total saga LOC across the inventory ≈ 1500-2000 LOC. Replaces the current ~3000 LOC of ad-hoc cross-Kind orchestration in domain modules.

### 4.5 The pre-dispatch pipeline — where step 5.5 + 5.6 + idempotency move to

Current dispatch routes steps 5.5 (CapBAC) + 5.6 (workspace isolation) through `Kind.Runtime.handle_dispatch/4`, inside the Kind GenServer's `handle_call`. Post-migration, these checks happen BEFORE `Commanded.Application.dispatch/2` — in a pre-dispatch pipeline module.

```elixir
defmodule Ezagent.CommandedApp.Dispatch do
  alias Ezagent.CommandedApp

  @spec dispatch(cmd :: struct(), opts :: keyword()) ::
    :ok | {:error, term()}
  def dispatch(cmd, opts \\ []) do
    with :ok <- Ezagent.URI.canonicalize_cmd(cmd),         # step 1 — canonicalize URIs in cmd
         :ok <- check_idempotency(cmd, opts),              # step 1.5 — idempotency key check
         :ok <- check_capbac(cmd, opts),                   # step 5.5 — CapBAC chokepoint
         :ok <- check_workspace_isolation(cmd, opts),      # step 5.6 — cross-workspace deny
         :ok <- CommandedApp.dispatch(cmd, opts) do        # step 6+ — Commanded internals
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
    target_workspace = cmd.workspace_uri  # every cmd carries workspace_uri
    if caller_workspace == target_workspace or admin?(opts),
      do: :ok,
      else: {:error, :cross_workspace_denied}
  end

  ...
end
```

Every external entry (LV, Channel, CLI, MCP) calls `Ezagent.CommandedApp.Dispatch.dispatch(cmd, opts)`. The pre-dispatch pipeline is the new chokepoint — equivalent to step 5.5 + 5.6 today.

The `Ezagent.CommandedApp.dispatch/2` (the bare Commanded application) is private to this module; nothing outside the pipeline calls it directly. Invariant test: grep for `Ezagent.CommandedApp.dispatch` outside `Ezagent.CommandedApp.Dispatch` is empty (mirror of current `single_dispatch_entry_test.exs`).

### 4.6 Aggregate ID derivation — URI canonicalization parity

Per `feedback_register_lookup_key_parity` + `feedback_uuid_is_canonical_identifier`:

- Every command MUST carry a canonical URI string in a field named `:uri` (or the relevant variant, e.g. `:agent_uri`, `:session_uri`).
- The router's `identify` clause uses this field:
  ```elixir
  identify(Ezagent.Aggregate.User, by: :uri, prefix: "")
  ```
- The canonical form is `Ezagent.URI.parse!(...) |> URI.to_string()` — same as the URI-canonicalization SPEC.
- The pre-dispatch pipeline canonicalizes the URI fields before dispatch.
- Cross-aggregate references (e.g. a Session command that references an Agent URI) carry both URIs as canonical strings.

The aggregate ID is opaque to the aggregate (it's the routing key, not state); the URI inside the aggregate state is the same canonical string. Single source of truth; no divergence between routing and state.

### 4.7 The audit log — what's a domain event vs telemetry

Two distinct concepts collapse into one `invocations` table today; they DIVERGE post-migration:

**Domain events (in event stream):**
- `UserRegistered`, `CapGrantedToUser`, `MessagePosted`, `SessionCreated`, `MemberJoinedSession`, `WorkerSpawned`, ... — every state-mutating event.
- Persisted in event store with full payload; queryable via projection (`audit_events_projection`).
- The event stream is the audit log; no separate audit writer.

**Telemetry-only events (stay in SQLite `audit` table):**
- `[:ezagent, :authz, :denied]` — the dispatch was rejected; nothing was state-mutated; not a domain event.
- `[:ezagent, :persistence, :failed]` — infra-level failure; not part of aggregate history.
- `[:ezagent, :cc_bridge, :event]` — bridge sidechannel; not state-mutating.
- `[:ezagent, :chat, :receive, :dropped]` — runtime drop; not state-mutating.
- `[:ezagent, :notification, :emit]` — side-effect emission record; not state-mutating in the source aggregate.

**Audit query patterns:**
- "What did user X do between time A and B" → query event stream for events with `metadata.caller == "X"` AND `created_at BETWEEN A AND B`. Either via Postgres event store SQL OR via `audit_events_projection` (a denormalized read model for fast querying).
- "Why was this dispatch denied" → query the SQLite `audit` table for the `[:ezagent, :authz, :denied]` row (this is NOT in the event stream because nothing happened in the domain).
- "What's the current cap set for user X" → query `user_caps_projection`.
- "What's the cap-grant history for user X" → query event stream for `CapGrantedToUser` / `CapRevokedFromUser` events filtered by `metadata.target == "X"`.

This split keeps domain events pure (only state-mutating facts; no telemetry noise in the stream) while preserving telemetry for ops + debugging.

---

## 5. Read Model strategy

### 5.1 One projection per logical read view

Each LiveView page / API endpoint has a corresponding projection table:

| Projection | Source events | Read by |
|---|---|---|
| `user_profile` | UserRegistered, PasswordRotatedForUser, UserDestroyRequested | `/admin/users`, login flow |
| `user_caps` | CapGrantedToUser, CapRevokedFromUser | `/admin/caps`, dispatch authz |
| `user_tokens` | TokenMintedForUser, TokenRevokedForUser | `entity_tokens` reads, bearer auth |
| `agent_profile` | AgentCreated, AgentDestroyRequested | `/admin/agents`, agent picker |
| `agent_caps` | CapGrantedToAgent, CapRevokedFromAgent | `/admin/caps`, dispatch authz |
| `agent_lineage` | AgentCreated (with parent_uri), AgentDestroyRequested | lineage queries |
| `agent_api_keys` | ApiKeyPutForAgent | runtime credential fetch (NOTE: encrypted in projection too; same encryption as current `agent_api_keys` table) |
| `session_profile` | SessionCreated, SessionDestroyRequested, SessionOwnershipTransferred | `/sessions`, session picker |
| `session_messages` | MessagePosted | `/sessions/X`, chat history (replaces `messages` SQLite table) |
| `session_members` | MemberJoinedSession, MemberLeftSession | membership queries, `/sessions/X` |
| `external_mirror_bindings` | ExternalMirrorBound, ExternalMirrorUnbound | bindings reconciler, `/admin/mirrors` |
| `external_mirror_workers` | WorkerSpawned, WorkerCursorAdvanced, WorkerTerminated | worker status |
| `workspaces` | WorkspaceCreated, WorkspaceDestroyRequested | workspace picker, `Workspace.list_*` |
| `workspace_members` | MemberAddedToWorkspace, MemberRemovedFromWorkspace | `list_workspaces_for/2` cap-vis query |
| `audit_events` | (all domain events filtered through audit projector) | `/admin/audit` queryable history |

Each projection is a module:

```elixir
defmodule Ezagent.Projection.UserCaps do
  use Commanded.Projections.Ecto,
    application: Ezagent.CommandedApp,
    name: "UserCapsProjection",
    consistency: :eventual  # opt to :strong for read-after-write LVs

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

### 5.2 Workspace scoping on projections

Every projection row that's workspace-scoped carries a `workspace_uri` column (same convention as current SQLite tables). `Ezagent.Persistence.scope_by_workspace/2` works against projections unchanged; the existing workspace-isolation invariant test is repointed at projection tables.

### 5.3 Cold-load handling

When LV mounts, it reads the projection (sync DB query). If the LV was just redirected-to from a dispatch site, the dispatch used `consistency: :strong` so the projection is caught up.

For cross-tab races (tab 1 dispatches, tab 2 mounts a stale LV before the projector catches up):
- The LV mount uses `Commanded.Subscriptions.wait_for/3` with the latest known aggregate version for that URI. If known, wait. If not known, accept eventual.
- The LV subscribes to the PubSub topic for the projection; the projector's `after_update/3` fires the subscriber; the LV re-renders.

The cold-load defense is the SAME as gift-card-demo: subscribe + re-fetch on update + initial render is best-effort. Worst case: ≤10ms stale window.

### 5.4 Strong vs eventual per projector

Default: `consistency: :eventual` for all projectors. Opt to `:strong` only for projectors that gate a dispatch site's immediate redirect (e.g. `user_profile` for `/admin/users/create` → redirect to `/admin/users/X` flow needs the new user in the profile projection).

Tradeoff: each `:strong` projector adds latency to every dispatch that flags `:strong` consistency. Default `:eventual` keeps the hot path fast.

---

## 6. Migration plan — phased

The migration runs as **Phase 10** in the IMPLEMENTATION_ROADMAP. Four sub-phases (10-A through 10-D), each gated by a /goal + per-phase invariant test.

### 6.1 Phase 10-A — dependencies + skeleton + Worker first (smallest Kind)

**Goal:** prove the integration. One Kind migrated; everything else unchanged. If 10-A fails, the whole migration aborts (we revert the deps + skeleton + Worker code; nothing else has changed).

**Deliverables:**
1. Add deps to root mix: `commanded ~> 1.4`, `eventstore ~> 1.4`, `commanded_eventstore_adapter ~> 1.4`, `commanded_ecto_projections ~> 1.3`, `postgrex ~> 0.19`.
2. Create new umbrella app `apps/ezagent_event_store` — config for `eventstore` lib (Postgres backend; dev uses local Postgres on port 5432, test uses in-memory adapter via Commanded's built-in test adapter).
3. Create new umbrella app `apps/ezagent_commanded_app` — `Ezagent.CommandedApp` module + the router + the pre-dispatch pipeline (§4.5).
4. Create new umbrella app `apps/ezagent_projections` — projection tables (Ecto repo against the existing SQLite for projection storage; events live in Postgres; the asymmetry is intentional — see §7.3).
5. Migrate `Ezagent.ExternalMirror.Worker` to `Ezagent.Aggregate.ExternalMirrorWorker`.
   - Worker is the smallest Kind (117 LOC), the most isolated (its own domain app), and its in-process subscribers are bounded.
   - Existing `Ezagent.Entity.ExternalMirrorWorker` Kind module is REPLACED — not deprecated. Same URI shape; same callers (the BindingCreated saga that boot-spawns Workers is also added in this phase).
6. `BootstrapWorkerSaga` is implemented (replaces the boot reconciler scan).
7. `external_mirror_workers_projection` is implemented.
8. Phoenix.Channel + LV that talk to Workers route through `Ezagent.CommandedApp.Dispatch`.

**Phase 10-A invariant test (the gate, per `feedback_completion_requires_invariant_test`):**
- `Worker aggregate state reconstructs deterministically from event stream alone` — test spins up an aggregate, dispatches N commands, stops the aggregate, restarts, asserts state equality.
- `BootstrapWorkerSaga resumes after BindingCreated event without rerunning the binding` — test plays a BindingCreated event, kills the saga process, replays, asserts no duplicate SpawnWorker dispatch.
- `Cross-Kind invocation from Worker → Session uses an event subscription, not direct GenServer.call` — grep test on the Worker code; no `Kind.get_slice/2` or `KindRegistry.lookup/1` for cross-Kind reads.

**Phase 10-A unwind (if failure):**
- Revert all deps in mix.exs.
- Delete the three new umbrella apps.
- Restore `Ezagent.Entity.ExternalMirrorWorker` from git.
- No data migration; the worker state was always derived from `external_mirror_bindings` rows (which never moved).

### 6.2 Phase 10-B — User + Session

**Pre-condition:** Phase 10-A merged + 1 week of soak in dev/staging.

**Goal:** the two most-used Kinds migrated. User: medium (240 LOC); Session: large (2272 LOC); both critical to every user-facing flow.

**Deliverables:**
- `Ezagent.Aggregate.User` + commands/events/projections (§4.2.1).
- `Ezagent.Aggregate.Session` + commands/events/projections (§4.2.3).
- Sagas: `CreateSessionSaga`, `DestroySessionSaga`, `DestroyUserSaga`, `CapGrantOwnershipVerifySaga`.
- All User + Session callsites migrated to the new Command-based API. Existing `EzagentDomainChat.create_session/3` becomes `EzagentDomainChat.create_session_command/3` returning `{:ok, cmd}` + a dispatch site OR is rewritten to dispatch directly.

**Phase 10-B invariant tests:**
- User caps reconstruct from event stream.
- Session messages reconstruct from event stream.
- `CreateSessionSaga` completes deterministically (no missing GrantOwnerOrchestratorAdminCap step).
- `DestroyUserSaga` compensates correctly on simulated step failure (the destroy_lifecycle 4-round failure resolved).

**Phase 10-B unwind:**
- More complex. User + Session aggregates have written events to the production event store. Unwind requires:
  1. Stop dispatch (new commands go to the GenServer-Kind code).
  2. Replay event stream → write back to slice/snapshot tables via a one-time `mix ezagent.unwind.user_session` task.
  3. Verify slice/snapshot state matches projection.
  4. Restore the GenServer Kind modules from git.
- Documented + reversible; the cost is the manual replay step.

### 6.3 Phase 10-C — Agent + Workspace

**Pre-condition:** Phase 10-B merged + 2 weeks soak.

**Goal:** the remaining Kinds. Agent: large (798 LOC) + per-flavor variants; Workspace: small but cross-cutting.

**Deliverables:**
- `Ezagent.Aggregate.Agent` + commands/events/projections (§4.2.2).
- `Ezagent.Aggregate.Workspace` + commands/events/projections (§4.2.4).
- Sagas: `DestroyAgentSaga` (the trigger SPEC #440), `DestroyWorkspaceSaga`, `CreateUserInWorkspaceSaga`, `BootstrapWorkerSaga` (refactored — was Phase 10-A but enriched here with Workspace context).
- All per-flavor agent code migrated. Flavor Behaviors (cc, codex, curl, np, echo) gain a Command + Event vocabulary.

**Phase 10-C invariant tests:**
- Agent lineage queries match aggregate state (no projection drift).
- `DestroyAgentSaga` completes the full 7-step cascade or compensates cleanly.
- `DestroyWorkspaceSaga` cascades through all child sessions/agents/users.

### 6.4 Phase 10-D — deprecate + cleanup

**Pre-condition:** Phases 10-A through 10-C merged + 1 month soak.

**Goal:** delete the old code.

**Deliverables:**
- Delete `Ezagent.Kind.Server`, `Ezagent.Kind.Snapshot`, `Ezagent.KindRegistry`, `Ezagent.SpawnRegistry`, `Ezagent.PendingDelivery`, `Ezagent.ReadyGate`.
- Delete `Ezagent.Invocation` (and all its callers).
- Delete the `kind_snapshots` SQLite table (after a final data dump for ops record).
- Delete `Ezagent.Audit.Writer` for domain-event paths; KEEP for telemetry paths.
- Delete `Ezagent.Behavior` (and all Behavior modules) — replaced by Command modules + per-Aggregate execute clauses.
- Update `IMPLEMENTATION_ROADMAP.md` §1.1 to mark Phase 10 complete + the new architectural baseline.
- Update `CLAUDE.md` skill `ezagent-developer` to point at the new dispatch / aggregate patterns.

**Phase 10-D invariant tests:**
- grep for `Ezagent.Kind.Server`, `Ezagent.Invocation`, `KindRegistry.lookup`, etc. across `apps/` is empty.
- All LVs read from projections; no `Kind.get_slice/2` calls anywhere.

### 6.5 Estimated phase durations

| Phase | Estimated calendar time (1 developer + codex review) |
|---|---|
| 10-A | 2-3 weeks |
| 10-B | 4-5 weeks |
| 10-C | 4-5 weeks |
| 10-D | 1-2 weeks |
| **Total** | **~3 months** |

These are rough — they assume no major blockers and the patterns established in 10-A generalize. Allen's input needed on whether this aligns with current priorities (see §10 OQ-2).

---

## 7. Performance + ops cost analysis

### 7.1 Hot-path dispatch latency

| Operation | Current latency | New latency | Notes |
|---|---|---|---|
| Dispatch `:cast` to existing Kind | ~1ms (`GenServer.cast` + slice update + `:on_change` SQLite write) | ~5-50ms (event append to Postgres) | Postgres event append dominates; same order as SQLite `:on_change` today but slower per-op due to fsync semantics |
| Dispatch `:call` to existing Kind | ~5ms (`GenServer.call` + slice + write + reply) | ~10-60ms (event append + aggregate apply + reply) | Similar shape |
| Dispatch `:call` w/ `consistency: :strong` | n/a — current model is implicitly strong via GenServer serialization | ~15-80ms (event append + strong projector commit + reply) | The new "strong" mode is similar to current effective behavior |
| Cold aggregate replay (after restart) | n/a — Kind GenServer starts from latest snapshot | ~5-50ms (load snapshot + replay events since snapshot) | `snapshot_every: 50` bounds replay to ≤50 events |
| LV mount + initial read | ~1ms (Kind.get_slice sync call) | ~1-5ms (Postgres SELECT) | Roughly equivalent; SQLite local-disk is faster than Postgres networked but the gap is ~ms |
| LV update (projection-driven) | n/a (currently push-via-PubSub from Behavior) | ~10-20ms (projector commit + PubSub broadcast + LV re-render) | Similar to current — current also has the broadcast hop |

**Conclusion:** event-store-driven dispatch is **5-10x slower than current per-dispatch in the worst case** (50ms vs 5ms), but still well within human-perception bounds (<100ms). For batch workflows (CLI), this is acceptable; for real-time UI, it's seamless.

### 7.2 Aggregate snapshot frequency tuning

`snapshot_every: 50` events is the recommended default. Per-Aggregate override:

- **Session** — high event volume (1 event per message). `snapshot_every: 100` to amortize snapshot cost. Worst-case cold replay = 100 events × 50μs each = 5ms.
- **User** — low event volume. `snapshot_every: 20` is fine; replay cost is negligible.
- **Workspace** — very low volume. `snapshot_every: 10`.
- **Agent** — medium volume; `snapshot_every: 50` default.
- **Worker** — medium volume (per-cursor-advance event); `snapshot_every: 100`.

These are starting values; tune based on production telemetry post-launch.

### 7.3 Dev burden — Postgres in dev loop

The current dev loop uses SQLite (zero-config). Postgres requires:
- Running `postgres` locally (Docker: `docker run -p 5432:5432 postgres:16`, or homebrew: `brew install postgresql@16 && brew services start postgresql@16`).
- `mix event_store.create` + `mix event_store.init` at first-time setup.
- An additional repo for the event store schema (separate from the existing SQLite projections repo).

**Mitigations:**
- **Test mode uses in-memory adapter** — `Commanded.EventStore.Adapters.InMemory` runs in-process; no Postgres required for `mix test`. The test environment is unchanged from the dev's perspective.
- **`docker-compose.dev.yml`** ships a Postgres + adminer container; `mix ezagent.dev.up` brings it up. Onboarding cost: one Docker command at clone time.
- **Snapshot store also in Postgres** (Commanded's built-in `snapshotting` config) — no separate snapshot infra in dev.
- **Migration path documented in CONTRIBUTING.md** — first-PR-after-Phase-10-A devs read the new setup instructions; existing devs need to pull the docker-compose change.

**Trade-off acknowledged:** the zero-config dev experience is lost. Allen's input needed (§10 OQ-2).

### 7.4 Ops burden — Postgres backup, replication, PITR

Postgres ops is widespread; tooling is mature:
- **Backup**: `pg_dump` for full; WAL archiving for PITR.
- **Replication**: streaming replication; standby for failover.
- **PITR**: WAL-based; standard `recovery.conf`.

For ezagent's scale (single-tenant deployment per Allen's current ops model), a single Postgres node + nightly `pg_dump` + WAL archive is sufficient. Cloud-managed (RDS, Cloud SQL, Supabase) all work. No new ops skill required beyond "we now run Postgres in addition to SQLite for projections + telemetry".

**SQLite stays for:**
- Projections (the projection schema lives in SQLite for compatibility with all existing read paths).
- Telemetry audit (the `audit` table for non-domain events).
- Application config / templates / fixtures.

**Postgres handles only:**
- Event store (`eventstore` lib schema).
- Aggregate snapshots (Commanded's snapshot store, sharing the `eventstore` schema).

**Why split:** SQLite is unbeatable for low-latency local reads; Postgres's event-store schema is the only place a Postgres-only library is required. Splitting lets us keep SQLite for everything that doesn't NEED Postgres while paying the Postgres cost only for what does. Asymmetric, but pragmatic.

### 7.5 Disk footprint

Event store grows monotonically (events are append-only, never deleted). Estimate:
- Per event: ~200-1000 bytes JSON payload + ~100 bytes metadata.
- ezagent activity rate: very rough estimate ~1000-10,000 events/day in steady state.
- Daily disk growth: ~1MB-10MB/day; ~1GB/year worst case.

Event archival policy: snapshots make REPLAY fast regardless of stream length, so events don't need to be deleted for performance. They can be archived (move to cold storage) for cost; not required for years. §11 q#8 addresses query patterns over archived events.

---

## 8. Migration risks + rollback plan

### 8.1 Per-phase rollback

Each phase has explicit unwind documented in §6. Summary:

| Phase | Rollback complexity | Data risk |
|---|---|---|
| 10-A (Worker only) | Trivial — revert code; no data migration | None — Worker state always derived from `external_mirror_bindings`, which never moved |
| 10-B (User + Session) | Medium — manual event-replay → slice/snapshot via a `mix` task | Low — events exist in event store, can be replayed back to slice |
| 10-C (Agent + Workspace) | Medium — same as 10-B | Low — same |
| 10-D (cleanup) | Hard — old code is deleted; rollback means restoring from git + re-running 10-B/10-C unwind | Medium — but only triggered if every prior phase failed |

### 8.2 Hybrid-period heterogeneity risk

During Phases 10-A through 10-C, some Kinds are Aggregates and others are GenServers. How they interact:

- **Aggregate → GenServer Kind cross-Kind call:** A saga emits a Command that targets a GenServer Kind. The Command's "dispatch" routes through the OLD `Ezagent.Invocation.dispatch/1` path for that Kind. Bridge: in the pre-dispatch pipeline, if the command's target URI maps to a non-yet-migrated Kind, route through `Invocation.dispatch/1`. The bridge module is `Ezagent.MigrationBridge.dispatch_to_legacy/2`.
- **GenServer Kind → Aggregate cross-Kind call:** A `Behavior.invoke/4` calls into a migrated Kind. Bridge: the call constructs a Command and dispatches via the new pipeline. Equally explicit in the bridge module.

The bridge module is the SHIM that allows hybrid operation. It's intentionally narrow — exactly the two directions above. The bridge is deleted in Phase 10-D.

§11 q#5 enumerates this concern for codex review.

### 8.3 Event schema breakage during impl

If a Phase 10-B impl PR adds an event type and Phase 10-B v2 needs to rename a field, every historical event still has the old shape on disk. `Commanded.Event.Upcaster` handles this:

```elixir
defimpl Commanded.Event.Upcaster, for: MessagePosted do
  def upcast(%MessagePosted{content: c} = ev, _meta) when not is_nil(c) do
    %MessagePosted{ev | body: c, content: nil}
  end
  def upcast(%MessagePosted{} = ev, _meta), do: ev
end
```

The pattern is well-supported by Commanded ([hexdocs](https://hexdocs.pm/commanded/Commanded.Event.Upcaster.html)). Each event schema change adds an upcaster impl; the historical event is read-only.

### 8.4 Production data loss risk

Per `feedback_destructive_migration_anti_pattern`:
- **No DROP / TRUNCATE on existing SQLite tables during migration.** New code reads from event-derived projections; old code reads from slice tables (during hybrid window). Both coexist.
- **Final cleanup (Phase 10-D) drops `kind_snapshots` only AFTER 1 month of clean operation post-10-C.**
- **Event store is append-only by construction** — events cannot be deleted accidentally without explicit operator action.

The risk is bounded: in the worst case (every phase fails), data is recoverable from the never-truncated SQLite tables. Phase 10-D is the only point of no return, and it gates on a 1-month soak.

---

## 9. Backwards compat / external API

### 9.1 What surface stays the same

- Phoenix.Channel topic names + message shapes — unchanged.
- HTTP endpoint paths + JSON shapes — unchanged.
- LiveView URLs + Assigns — unchanged from the user's perspective.
- CLI command names + flag shapes — unchanged.
- MCP tool schemas — unchanged.
- The `URI` addressing scheme — unchanged.
- Capability struct shape — unchanged.

### 9.2 What surface changes

- Plugin authors: instead of `@behaviour Ezagent.Kind` + `Ezagent.Behavior` modules, they write `@behaviour Commanded.Aggregates.Aggregate` + Command modules + Event modules + a per-Aggregate execute clause. The `ezagent-developer` skill is rewritten Phase 10-D.
- Domain context modules: `EzagentDomainChat.create_session/3` either becomes a thin wrapper that constructs `%CreateSession{}` and dispatches, OR is deleted and replaced by direct dispatch from the LV / channel. Decision per impl PR.
- Audit consumers: queries against the SQLite `invocations` table for domain events fail post-10-D — those queries must move to `audit_events_projection` OR to event-stream filters via `EventStore.read_stream_forward/4`. Migrated piecewise during 10-B / 10-C.

### 9.3 Plugin compatibility

Plugins outside the umbrella (if any future plugins existed at a separate git remote) would need to migrate their Kind definitions to Aggregates. Per `feedback_north_star_plugin_isolation`, the migration cost is bounded — plugins write commands + events + an aggregate; they do NOT touch the event store, the router, or the saga infrastructure (those live in `ezagent_commanded_app`).

The 3-tier rule from existing SPECs holds:
- **Tier 1 — core:** `apps/ezagent_core/`, `apps/ezagent_commanded_app/`, `apps/ezagent_event_store/`, `apps/ezagent_projections/`. Owns Commanded wiring.
- **Tier 2 — domain:** `apps/ezagent_domain_*/`. Owns aggregates + commands + events + projectors + sagas for their domain Kinds.
- **Tier 3 — plugin:** `apps/ezagent_plugin_*/`. Owns flavor-specific aggregate extensions (per-flavor commands + events + per-flavor execute clauses on the Agent aggregate).

Plugins cannot reach across to other plugins' aggregates; they go through events + sagas.

---

## 10. Open questions for Allen

### OQ-1. DB choice — Postgres for event store, SQLite for projections — accept?

Decision: yes (recommended). Alternatives:
- (a) **Migrate everything to Postgres** — drop SQLite entirely. Cleaner; one DB to manage. Cost: existing SQLite-based code (audit, fixtures, templates) must move; bigger disruption.
- (b) **Keep SQLite for everything except event store** — current recommendation (§7.4). Asymmetric but pragmatic.
- (c) **Find a SQLite event-store adapter** — no maintained one exists; would require building + maintaining a custom `Commanded.EventStore.Adapter` impl. High risk; not recommended.

### OQ-2. Migration calendar — 3 months acceptable, or do we phase it differently?

Allen's input needed. The phased plan is conservative (one Kind class per phase + 1-2 week soak). Acceleration options:
- (a) Phase 10-B and 10-C in parallel (riskier; two teams; we don't have two teams).
- (b) Run 10-A then jump directly to 10-D-equivalent for all Kinds (big bang; rejected per `feedback_destructive_migration_anti_pattern`).
- (c) Pause non-migration feature work during Phase 10-A through 10-C (Allen's call).

### OQ-3. Dev experience — Postgres in dev loop, acceptable burden?

Mitigations in §7.3. Allen's call on whether the docker-compose hop is acceptable for daily dev.

### OQ-4. Multi-tenant — does event sourcing change tenant-isolation concerns?

The current per-workspace isolation invariant (Phase 9 / SPEC v3 §7) ports forward: each domain event carries `workspace_uri`; projections enforce isolation in queries. The event stream itself is NOT workspace-partitioned by default — all events for all workspaces live in the same stream. This may be a concern for ops (a workspace cannot be "deleted from the event log" without a full dump-filter-restore cycle).

Alternative: one event stream per workspace. Commanded supports per-stream subscriptions naturally; multi-stream aggregates require care. §11 q#6.

### OQ-5. Mid-migration interop — bridge module placement

Phase 10-A through 10-C has the bridge module `Ezagent.MigrationBridge`. Should it live in `apps/ezagent_core/` (Tier 1) or `apps/ezagent_commanded_app/` (also Tier 1)? Probably the latter — the bridge is migration-specific scaffolding, not a permanent feature. Allen agrees?

### OQ-6. Sagas — should they be supervised inside `Ezagent.CommandedApp` or in a sibling supervisor?

Commanded supports both. In-app is simpler (single supervisor tree); sibling is more isolated. Default recommendation: in-app for Phase 10-A; reconsider if saga count grows past ~20.

### OQ-7. Presence — keep slice-based or move to `Phoenix.Presence`?

Per §4.3, Presence is not migrated to event sourcing (it's transient runtime state). Two options:
- (a) Keep as a `Ezagent.Presence` GenServer + slice (current).
- (b) Migrate to `Phoenix.Presence` natively (better-tested; CRDT-backed; clustering-ready).

Independent decision from this SPEC; flag here.

### OQ-8. Audit retention — when do we archive old events?

EventStore grows monotonically (§7.5). At ~1GB/year, archival is not pressing for years. When do we want a policy?

---

## 11. Codex adv-review questions

Pre-loaded attack vectors for codex round 1:

1. **Phoenix + Commanded integration maturity — is there a production reference at comparable scale, or are we pioneering?** §3.6 enumerates Conduit, Gift-card-demo, Segment Challenge, Honeydew, Casavo. None is at "thousands of aggregate types"-scale. Verdict: the pattern is established; ezagent's scale is well within precedent.

2. **Read-after-write consistency for LV — when user dispatches a command and LV re-renders, will it see the updated state? Is `:strong` mode the right answer or does it block command return until projection catches up?** §3.3 explains the three modes; the recommendation is default `:eventual` with opt-in `:strong` per dispatch site. The blocking is exactly what we want for the "wizard → redirect → detail page" pattern. Codex: validate that our specific LV → dispatch → re-render flows all have an opt-in path documented.

3. **Saga partial-failure: destroy cascade has 7 steps; if step 4 fails, how does the Saga compensate? Are there published compensation patterns?** §3.8 shows the destroy saga with `error/3` callback. Compensation in Commanded sagas is explicit (no auto-rollback); the saga code MUST encode compensation. Codex: validate the destroy saga's compensation logic is complete (does step 4 failure require undoing steps 1-3 or just retrying step 4? — depends on idempotency of each).

4. **Postgres vs SQLite — ezagent uses SQLite; can we feasibly support both, or must we migrate fully?** §7.4 + OQ-1: the recommendation is split (Postgres for event store + snapshots; SQLite for projections + audit + everything else). Asymmetric but works. Codex: validate that the asymmetry doesn't create cross-DB query problems (it shouldn't — projections + event store don't share queries; they share only the projection update operation, which is an Ecto.Multi within the projection's own SQLite repo).

5. **Heterogeneous migration — Phase 10-A through 10-C has some Kinds as Aggregates and some as GenServers. How do cross-Kind workflows work in this mixed mode?** §8.2 + the `Ezagent.MigrationBridge` module. Codex: validate that the bridge module handles both directions (Aggregate → GenServer + GenServer → Aggregate) AND that the bridge deletion in Phase 10-D doesn't strand any callers.

6. **Event schema evolution — adding new fields to existing event types, handling old events on replay.** §8.3 + Commanded's `Event.Upcaster` pattern. Codex: validate the Upcaster impl path for each anticipated schema change in Phase 10-B/10-C (we have at least 5 known evolutions queued from the destroy SPEC).

7. **Performance: worst-case event-stream replay time for an aggregate with N events. Hot Aggregates may have 10K+ events.** §7.2 + snapshot_every: 50-100. Codex: validate that 50 events × 50μs = 2.5ms cold-start is acceptable for our LV mount budget (it is).

8. **Audit query: today's `invocations` table is queryable via SQL. With EventStore, ad-hoc audit queries require event-stream scan or projection. Define audit query patterns.** §4.7. Codex: validate that the `audit_events_projection` schema can satisfy the existing `/admin/audit` LV's filter predicates (workspace_uri, caller, time range, action type). If a query exists today that the projection can't satisfy, document it as a Phase 10-B impl-blocker.

---

## 12. Rollback plan — overall abort path

If, after Phase 10-A merges + 10-B / 10-C in progress, Allen decides the migration is not working:

1. **Stop new dispatch.** Set a feature flag in the pre-dispatch pipeline that routes all commands through the legacy `Ezagent.Invocation.dispatch/1` path. New dispatches stop emitting events; Aggregates stop receiving commands.
2. **Replay events back to slice/snapshot.** For each migrated Aggregate, a `mix ezagent.aggregate.unwind --uri <uri>` task reads the event stream + writes equivalent slice state into `kind_snapshots`. The replay is deterministic (Aggregate's `apply/2` IS the projection from event to state).
3. **Verify parity.** A `mix ezagent.aggregate.verify` task asserts that for every migrated URI, the slice-snapshot state equals the event-replayed Aggregate state. If parity fails, the unwind aborts at this point (data is preserved in the event store + the SQLite snapshot — operator inspects).
4. **Restore GenServer Kind code.** From git: revert the per-Phase code that replaced `Ezagent.Entity.X` with `Ezagent.Aggregate.X`. The legacy `Kind.Server` boots from the (now-replayed) snapshot.
5. **Keep the event store data.** Even on abort, the events are preserved. A future re-attempt at migration starts from the same event store.

The unwind is documented + automated per Aggregate. Cost: an operator-driven session (estimated 1-2 hours for the full unwind across all 5 Aggregate classes given the projections are already shaped for the inverse direction).

---

## Appendix A — Event-store schema (Postgres)

Standard `eventstore` library schema; documented at https://hexdocs.pm/eventstore/EventStore.html. Tables:

- `event_store.events` — append-only event log.
- `event_store.streams` — per-stream metadata (one stream per Aggregate UUID = canonical URI string).
- `event_store.subscriptions` — projector + saga subscription state (replayed events position).
- `event_store.snapshots` — aggregate snapshots (Commanded-managed).

No custom schema required for Phase 10-A; per-projection tables live in the SQLite projections repo (§4 + §5).

## Appendix B — Sample command + event + aggregate execute clause

```elixir
# Command
defmodule Ezagent.Aggregate.User.Commands.GrantCapToUser do
  @derive Jason.Encoder
  defstruct [:user_uri, :workspace_uri, :cap, :granted_by, :idempotency_key]
end

# Event
defmodule Ezagent.Aggregate.User.Events.CapGrantedToUser do
  @derive Jason.Encoder
  defstruct [:user_uri, :workspace_uri, :cap, :granted_by, :granted_at]
end

# Aggregate execute clause
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

  # apply — state mutation
  def apply(%__MODULE__{} = state, %CapGrantedToUser{} = ev),
    do: %{state | caps: MapSet.put(state.caps, ev.cap)}

  # ... other commands/events/apply clauses ...
end

# Router clause
defmodule Ezagent.CommandedApp.Router do
  use Commanded.Commands.Router

  identify(Ezagent.Aggregate.User, by: :user_uri)
  dispatch([
    Ezagent.Aggregate.User.Commands.GrantCapToUser,
    Ezagent.Aggregate.User.Commands.RevokeCapFromUser,
    ...
  ], to: Ezagent.Aggregate.User)
end

# Dispatch site (e.g. in EzagentDomainIdentity.Users)
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

## Appendix C — Reference URLs

- Commanded: https://github.com/commanded/commanded · https://hexdocs.pm/commanded
- EventStore (lib): https://github.com/commanded/eventstore · https://hexdocs.pm/eventstore
- commanded_eventstore_adapter: https://hex.pm/packages/commanded_eventstore_adapter
- commanded_ecto_projections: https://hex.pm/packages/commanded_ecto_projections · https://hexdocs.pm/commanded_ecto_projections
- Awesome-Elixir-CQRS (project list): https://github.com/slashdotdash/awesome-elixir-cqrs
- Conduit reference app: https://github.com/slashdotdash/conduit
- Gift-card-demo: https://github.com/slashdotdash/gift-card-demo
- Segment Challenge: https://github.com/slashdotdash/segment-challenge
- Honeydew CELP starter: https://github.com/quarterpi/honeydew
- Casavo Phoenix LiveView + ES tools: https://medium.com/casavo/supercharging-our-event-sourcing-capabilities-with-phoenix-liveview-c4a9d1d4ab99
- "Phoenix LiveView but event-sourced" (cantido): https://dev.to/cantido/phoenix-liveview-but-event-sourced-7pe
- Christian Alexander Phoenix API + Commanded: https://christianalexander.com/2022/05/09/elixir-commanded/
- ElixirMerge ES/CQRS guide: https://elixirmerge.com/p/comprehensive-guide-to-implementing-es-cqrs-with-eventstoredb-phoenix-and-liveview
- Commanded process managers / sagas: https://hexdocs.pm/commanded/process-managers.html
- Commanded read-model projections: https://hexdocs.pm/commanded/Read%20Model%20Projections.md
- Commanded event upcasting: https://hexdocs.pm/commanded/Commanded.Event.Upcaster.html
- Saga pattern in Elixir (Peter Ullrich): https://peterullrich.com/saga-pattern-in-elixir
