# Actor-Framework Umbrella Extraction — physical isolation of Kind state management — SPEC

- **Date**: 2026-07-23
- **Status**: FINAL v3 — codex re-review (round 2, clean `origin/main`) CLOSED five round-1 findings (Capability opacity, SchemeRegistry, SagaPort, `read_durable`, chunk independence — those sections stand as written). This revision, per the owner's decision, fully fixes the two mechanical remainders (EventLogPort workspace derivation, §3.4; KindRegistry supervision child, §3.2/§5-C5) and records the two deep remainders as **implementation-time open questions** (§2.3 runtime_view read surface; §5-C4 fail-closed persistence) — both touch #195-active cap-spine code and are best resolved against settled code + real tests, not respun in a spec. Boundary sound; 2 deep items flagged for implementation time.
- **Read off**: `origin/main` @ `d9c9a90e7` (v1 census taken at `62f606b8f`; every cited anchor re-verified at `d9c9a90e7` — 7 commits apart, no cited line moved; v3 additions verified at `53da02743`)
- **Decision owner**: Allen (lead direction: PHYSICAL isolation — extract the actor framework into a new umbrella app with a strict public interface, so other layers CANNOT reach into actor internals; remaining leakages surface as errors and are fixed one by one)

---

## 0. The X — cross-layer leakage into actor internals

The Kind actor framework (long-lived per-URI GenServers hosting per-Behavior
"slices", snapshot persistence, ready-gating, pending-delivery buffering,
process incarnation/generation) lives in `apps/ezagent_core` next to
everything else in core, and its internals are plain public Elixir modules.
Result: authz, LiveView, session-read, and domain code reach INTO the actor's
state-management instead of going through the dispatch/read plane. Each such
reach-in hard-codes an assumption about HOW the actor stores state (live
slice vs snapshot row vs process dictionary vs registry pid), so every
framework evolution (two-container Lifecycle, cap-authority compartment,
incarnation fencing — all recent) had to hunt down scattered callers.

Seed leakages (the known worklist — §4.4 enumerates the rest):

| # | Leak | Where | What it reaches into |
|---|---|---|---|
| (a) | authz reads process generation | `apps/ezagent_core/lib/ezagent/cap/authorize.ex:86-97` (`autonomous_current?/1`) | `Cap.Authority.current_process_generation/1` reads `Process.get({Ezagent.Cap.Authority, :current})` (`cap/authority.ex:75-83`) — the authorization decision depends on AMBIENT actor-process state (being inside a Kind's authority compartment), an invisible coupling between the authz plane and the actor runtime |
| (b) | LiveView trusts a mount-time cap snapshot | `apps/ezagent_plugin_world/lib/ezagent/world/presenter_caps.ex:19,27` merges `assigns.current_caps` (assigned once at mount, `apps/ezagent_web/lib/ezagent_web/live_auth.ex:234`) into every later authorization context | a caller-held COPY of actor state (the principal's cap set) survives grants/revokes for the socket lifetime; ~13 world/web action modules consume it via `PresenterCaps.context/1` |
| (c) | cold session reads rebuild snapshots directly | `apps/ezagent_domain_socialware/lib/ezagent/socialware/session_reads.ex:473-487` (`surface_slice/1`) | `Kind.get_slice` miss → `Ezagent.Kind.StateRebuilder.rebuild/1` + `Kind.normalize_slice_view/1` — a domain module re-implements the framework's rehydration path because no public cold-safe read exists. Same pattern: `apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex:494` (`StateRebuilder.snapshot_exists?/1`) |
| (d) | `get_slice`/`mount` callers bypass the dispatch plane | `Kind.get_slice/2` is live-only — "needs a live session process (it does NOT lazy-spawn)" (`session_reads.ex:465-472`); 53 lib files across 16 apps call it, and every caller that cares about cold state hand-rolls its own fallback (snapshot read, SpawnRegistry poke, or silent `%{}`) | the liveness/rehydration decision — which belongs to the dispatch plane (`Invocation.dispatch/1` DOES lazy-spawn, `invocation.ex:422-468`) — is re-made ad hoc at every read site |

Beyond the seeds, the census (§4.4) shows the same class everywhere:
`Ezagent.SnapshotStore` read directly from **18 non-framework lib files** including
`ezagent_web` LiveViews (`home_live.ex`, `session_controller.ex`) and the
identity domain's cap loader (`entity_caps.ex`); `Ezagent.KindRegistry`
pid-resolution from **~20 production sites** outside core (workspace
provisioning, agent transport readiness, socialware GC, retirement sweeper,
identity fence checks).

**The fix is a boundary, not another round of patches.** Enforce actor
encapsulation at an app boundary with a strict public interface; every
remaining reach-in becomes a gate error with a named owner.

---

## 1. What IS the actor framework — module inventory

The framework = the modules that implement "a URI is a serialized,
snapshot-backed, capability-compartmented actor". All in
`apps/ezagent_core/lib/ezagent/` today:

**Actor host + dispatch mechanics**
- `kind/server.ex` (1164 LOC) — the single shared GenServer for every Kind instance; the ONLY `def init/1` (invariant #2, `server.ex:8-10`); owns the state shape `%{kind, uri, state (slices), authority, ...}` (`server.ex:12-24`)
- `kind/runtime.ex` (739) + `kind/runtime/{context,effects,receipt}.ex` — Appendix-A dispatch steps inside the actor
- `invocation.ex` (722) — the dispatch chokepoint: ReadyGate/incarnation/lazy-spawn/PendingDelivery linearization (`invocation.ex:298-479`)
- `router.ex` — Cmd-level dispatch on top of Invocation (+ `cmd.ex`, the pure command struct it dispatches)
- `../ezagent_core/kind_supervisor.ex` — `Ezagent.KindSupervisor`, the default DynamicSupervisor every Kind without its own `supervisor/0` callback runs under (`kind.ex:691` fallback; surfaced by the §3.4 scan)
- `kind/deferred_dispatch.ex`, `kind/cascade_hook.ex` — post-commit dispatch ordering
- `kind/spawner.ex`, `kind/ready_transition.ex`, `kind/termination.ex`, `kind/mount_detach.ex`, `kind/launch_context_init.ex`, `kind/launch_context_relay.ex`

**State + persistence**
- `kind/snapshot.ex` (843) — load_or_init / commit / save_now / strip_transients
- `snapshot_store.ex` (339) + `snapshot/writer.ex` — the `kind_snapshots` row store
- `ecto/kind_snapshot.ex` — the schema (the actor's durable-state table)
- `kind/state_rebuilder.ex` (322) — snapshot→state rehydration (already documented "framework-internal — plugin authors NEVER call this", `state_rebuilder.ex:71-75`; the SPEC §11 grep gate it references was never built — (c) above is exactly the drift it predicted)
- `kind/slice_access.ex` (286) — cross-process slice reads + T3 normalization
- `lifecycle.ex` (836) — the two-container durable/transients contract + create/activate/destroy
- `kind/behavior_set.ex`, `kind/kind_base_backfill.ex`, `kind/introspection.ex`

**Liveness + delivery**
- `kind_registry.ex` (79) — URI→pid
- `ready_gate.ex` (163) — :unknown/:not_ready/:ready/:failed + await + external-gate hook
- `pending_delivery.ex` (217) — not-ready buffering + the per-URI lock that linearizes cast delivery with registration (load-bearing, §6.1)
- `idempotency.ex` (77) + `idempotency/sweeper.ex` — the TTL sweep GenServer, named in the mover inventory EXPLICITLY (it is a supervised core child today, `application.ex:37`; it moves and re-supervises under the actor app, §3.2)
- `spawn_registry.ex` — scheme→spawn-fn registry + `ensure_live/1` (rehydrate-or-refuse, `spawn_registry.ex:137-153`)
- `local_runtime.ex` — the existing owner-gated liveness facade (`kind_alive?/ensure_started/ensure_live`)

**Contracts consumed by Kind/Behavior authors** (public, move with the framework)
- `kind.ex` (995) — the Kind behaviour + `use Ezagent.Kind` + spawn/terminate/mount/detach facade
- `behavior.ex` / the `action_set` CONTRACT modules (`behavior/{effects,kind_base,legacy_callbacks,introspection}.ex`), `behavior_registry.ex`, `universal_behaviors.ex`, `interface_validator.ex` — the five core-AUTHORED policy ActionSets in the same directory (`behavior/{routing,terminable,manage,notifications,sandbox}.ex`) are policy, not contract, and do NOT move (§3.4 scan findings)
- `slice_change.ex` + `slice_change/cursors.ex` — the change-notification plane

**NOT the framework** (stays in `ezagent_core`, §3.3): the cap/authority
spine (`cap/*.ex`, `capability.ex`, `capability_registry*`, `ecto/kind_cap_authority.ex`),
`Ezagent.URI`*, `message*`/`message_store`, workspace/dispatch-origin gates,
audit/event_log/dlq/presence, `EzagentCore.Repo`.

\* `Ezagent.URI` is needed by the framework pervasively and by everything
else too; it moves DOWN into the new app (module name frozen), so the new
app depends on nothing above it. `Ezagent.URI` is NOT standalone, though —
`uri.ex:177,190,248,988` call `Ezagent.URI.SchemeRegistry` (the runtime ETS
scheme allowlist, `uri/scheme_registry.ex`) and the moved
`spawn_registry.ex:71` co-registers schemes into it. The registry moves
WITH `uri.ex` — module, ETS table ownership, AND the 6-scheme boot seed,
atomically (§3.2); moving `uri.ex` without it would leave an uncaptured
upward edge. If review prefers, a `ezagent_kernel` bottom app for URI+
SchemeRegistry alone is the alternative; not proposed (no second consumer
of the split).

---

## 2. The Kind public interface

Everything outside the new app may touch actors ONLY through this surface.

### 2.1 Write/action plane (exists, unchanged)
- `Ezagent.Invocation.dispatch/1` — THE action chokepoint. Already lazy-spawns from snapshot (`invocation.ex:422-468`), already serializes per-URI. Semantics unchanged.
- `Ezagent.Router.dispatch/1` (Cmd) — unchanged.
- `Ezagent.Kind.spawn/2,3`, `terminate/1`, `terminate!/1`, `mount/3`, `detach/2` — lifecycle operations (already the sole sanctioned entries; `SingleSpawnEntryTest`).
- `Ezagent.Lifecycle.destroy/2`, `with_entity_transition/2`.

### 2.2 Read plane (NEW — this is the heart of the spec)

```elixir
@spec Ezagent.Kind.read(URI.t(), slice_key :: atom(), opts :: keyword()) ::
        {:ok, term()} | {:error, :not_created | term()}
```

**The authoritative read.** Contract:
1. Live process → normalized live slice (exactly today's `get_slice/2` view).
2. Cold but durably created → **lazy-spawn via the framework's own
   rehydration path** (`SpawnRegistry.ensure_live/1`, which refuses
   never-created URIs — `spawn_registry.ex:137-153`), await ReadyGate, then
   read live. One truth path: the actor's own load path (snapshot decode +
   behavior-set backfill + authority open) — NOT a parallel snapshot-decode
   that can drift from live semantics.
3. Never durably created → `{:error, :not_created}`.
4. **Self-safe**: when the caller IS the target's own process (the
   `EntityCaps` case, `entity_caps.ex:52-60`), a `GenServer.call` to self
   would deadlock; the framework detects self and serves the durable
   projection (correct for `{:snapshot, :on_change}` Kinds — in-memory ==
   durable after every commit; for other policies it returns the persisted
   view, same as today's `load_persisted` escape).
5. `opts[:spawn].. :ensure (default) | :never` — `:never` returns
   `{:error, :not_live}` instead of spawning; for probe-style callers that
   only care about LIVE state. Callers that need DURABLE state without a
   spawn use `read_durable/3`; the list plane (§6.3) uses
   `read_durable_many/3` (below).

```elixir
@spec Ezagent.Kind.read_classified(URI.t(), slice_key :: atom()) ::
        {:ok, term()} | :absent | {:transient, term()}
```

**The authz-grade read.** Generalizes `SliceAccess.read_identity_caps/1`
(`slice_access.ex:200-276`): 3-way classification with bounded retry and the
durable-existence disambiguation of `:not_found`. Preserves the
fail-LOUD-not-deny contract (`kind.ex:212-250`) as a PUBLIC primitive so the
cap layer stops needing private slice/snapshot access. Does not spawn.

```elixir
@spec Ezagent.Kind.read_durable(URI.t(), slice_key :: atom(), opts :: keyword()) ::
        {:ok, term(), meta :: %{version: integer(), updated_at: DateTime.t()}}
        | {:error, :not_created}
```

**The durable projection (single URI).** Renamed from the v1 draft's
`read_cold/3` because the semantics are now DURABLE, not
cold-preferring-live: v1's live-first single read and single-query batch
read could DISAGREE over the same URIs — two calls in one render pass,
observably divergent for `:ephemeral` Kinds (System, Workspace) and
`:periodic`/on-terminate snapshot policies — an incompatibility, not a
caveat. Contract:
1. NEVER consults the live process. The answer is the snapshot row
   (snapshot decode + `normalize_slice_view/1`) — deterministic: the same
   store state yields the same answer regardless of liveness, and
   `read_durable/3` agrees with `read_durable_many/3` by construction
   (same rows, same decode). The sanctioned form of what
   `session_reads.surface_slice/1` (seed (c)) and the 18 SnapshotStore
   reach-ins hand-roll today.
2. `{:ok, value, meta}` carries the row's `version` + `updated_at`
   (`ecto/kind_snapshot.ex:29,41`) so staleness is reasoned about
   EXPLICITLY at the call site, never guessed.
3. Never durably created → `{:error, :not_created}` — including a LIVE
   Kind whose persistence policy has produced no durable row yet. That is
   the stated contract of a durable read, not a surprise; transients are
   absent by definition (§6.4).
4. Callers that want live-preferred single reads COMPOSE explicitly:
   `read(uri, key, spawn: :never)` then fall back to `read_durable/3`.
   The race window between the two calls exists at the CALL SITE, visible
   in review — never hidden inside the API.

Distinct from `read(uri, key, spawn: :never)`, which REFUSES cold reads
(`{:error, :not_live}`): `read_durable/3` ANSWERS them from the durable row.
Probe-vs-render rule: liveness probes use `spawn: :never`; render/list
paths that accept durable state use `read_durable/3`.

```elixir
@spec Ezagent.Kind.read_durable_many([URI.t()], slice_key :: atom(), opts :: keyword()) ::
        %{optional(URI.t()) => {:ok, term(), meta :: map()} | {:error, :not_created}}
```

**The batch durable projection (list plane).** ONE store query over the
snapshot rows — a single consistent durable view; never per-URI spawns,
never per-URI GenServer calls, and never a live overlay (an overlay would
reintroduce v1's single/batch divergence and cost N calls — the one-query
guarantee is the point). Per-URI results carry the same `meta` as the
single form. This pulls the "batch snapshot projection through one
sanctioned internal gateway" (previously deferred to the read-plane
`InternalReads` pattern, spec 2026-07-19 §3.4) INTO the public §2.2 surface:
rendering N rows costs one query, never N spawns (§6.3). List callers MUST
accept durable semantics — recorded per caller at C2/C6 migration review
(§5); a caller that cannot accept them belongs on `read/3`, not on the
list plane.

```elixir
@spec Ezagent.Kind.resolve_action_subject(URI.t() | pid(), action :: atom()) ::
        {:ok, {kind_module :: module(), behavior_module :: module()}} | {:error, term()}
```

**The action-subject resolution op (purpose-specific — replaces the raw
runtime-view reach-through).** Resolves which `{kind_module,
behavior_module}` handles `action` on the live target, running the
behavior-set resolution INSIDE the actor and returning ONLY the two module
atoms — never the slice map. This is exactly what `Cap.action_context/3`
needs (`cap.ex:116-122`: today it pulls the COMPLETE `%{kind, uri, state}`
view via `GenServer.call(pid, :ezagent_runtime_view)` and runs
`Kind.BehaviorSet.resolve_action` outside the actor) and what
`composition_caps.ex:508-513` hand-rolls (registry lookup + raw view +
direct `BehaviorSet.resolve_action` + membership check). Does not spawn;
`{:error, :not_live}` when cold.

```elixir
@spec Ezagent.Kind.alive?(URI.t()) :: boolean()      # today LocalRuntime.kind_alive?/1
@spec Ezagent.Kind.self?(URI.t()) :: boolean()       # am I the target's own process
@spec Ezagent.Kind.list_instances() :: [{uri, meta}]  # operator plane; sole KindRegistry.list_all wrapper
```

`Ezagent.LocalRuntime` stays public as the owner-gated ensure facade
(`ensure_started/ensure_live` — plugin runtime entry, arch.scan §95 chokepoint).

### 2.3 Authoring plane (public, for Kind/Behavior authors)
`@behaviour Ezagent.Kind` + `use Ezagent.Kind`, `use Ezagent.Lifecycle`,
`Ezagent.ActionSet` contract, `BehaviorRegistry.register/*` (boot wiring),
`SpawnRegistry.register/2` (scheme→spawn-fn), `ReadyGate.register_external_gate/1`
(the one sanctioned external-readiness hook, `ready_gate.ex:62`),
`SliceChange` subscribe surface.

`Ezagent.Kind.runtime_view/1` is NOT on the public surface (the v1 draft
put it here; review round 1 correctly called that a sanctioned raw-state
escape). Stripping the private authority is not enough: the handler returns
the COMPLETE slice map — `Map.take(state, [:kind, :uri, :state])`,
`server.ex:584-587` — so publishing it makes arbitrary state reach-in
gate-LEGAL, defeating the boundary. It becomes actor-INTERNAL. Its five
production consumers on `origin/main` all migrate onto purpose-specific
ops: `cap.ex:116-122` (`action_context/3`) →
`resolve_action_subject/2`; session `orchestrator/tools.ex:320-330` and cc
`cc_orchestrator_seed.ex:203-214` (template-slice content reads) →
`read/3`; session `socialware/composition_caps.ex:508-513` (conformance
check) → `resolve_action_subject/2` + `read/3`; ui `auto_derive.ex:95`
(introspection listing) → `read/3` + `list_instances/0`. All four
non-spine consumers enter the §4.4 census ledger. The composition_caps and
auto_derive target ops are PROVISIONAL — the open question below governs
their final shape. If a genuine multi-slice-view need survives migration
review, the replacement op returns a BOUNDED DTO (named, explicit fields)
— never an arbitrary slice map.

**Open question (implementation-time) — the runtime_view replacement
surface is NOT settled by this spec.** Owner decision: the exact
read/introspection ops that retire the raw view are designed at
implementation time, against settled #195 cap-spine code and real tests —
not respun here. Codex review round 2 established three constraints that
design must satisfy (recorded so the C0/C3 implementer designs against
them, not around them):

1. **A SECOND cap-side raw-slice escape exists, and the §3.4 port
   PRESERVES it.** The SELF-target resolution branch reads
   `{kind_module, slice_state}` from `Cap.RuntimeView.current()`
   (`cap.ex:161-172`, `self_target_subject/2`), and the actor runtime
   installs the FULL slice state for the duration of every dispatch
   (`runtime.ex:125-134`, `Cap.RuntimeView.with_current(kind_module,
   state, …)` at `:132`). `AuthorityPort.with_runtime_view` (§3.4) ports
   that call as-is — the full slice map still crosses the boundary into
   the spine, port-shaped. Retiring `runtime_view/1` closes the PUBLIC
   escape but not this one; what actually crosses `with_runtime_view`
   (full state as today, or the narrower view the resolve-need actually
   requires) is decided at implementation time WITH the spine owner.
2. **Composition conformance needs instance MEMBERSHIP, not just action
   resolution.** `composition_caps.ex:507-528` (`assert_target_conformance`
   + `runtime_instance_member?`) checks that the behavior is a member of
   the instance's EFFECTIVE behavior set (`BehaviorSet.effective_set/2`)
   in ADDITION to resolving the action. `resolve_action_subject/2`
   returning `{kind_module, behavior_module}` cannot reproduce that check,
   and the actor-internal `instance_set_gate` (`runtime.ex:170`, defp at
   `:333`) applies on the DISPATCH path separately — it does not serve
   this read-side conformance probe. Whether the answer is a membership
   flag on `resolve_action_subject`, a distinct membership op, or folding
   the probe into dispatch is an implementation-time choice.
3. **AutoDerive needs dynamic slice KEYS + a bounded slice DTO.**
   `auto_derive.ex:75-119` enumerates the slice keys of the full state
   (`Map.keys`) and renders the full slice map in its detail view —
   `read/3` (requires a KNOWN key) and `list_instances/0` (`{uri, meta}`)
   provide neither. If AutoDerive's need survives migration review, the
   bounded introspection DTO (named, explicit fields — never the
   arbitrary slice map) is designed then, and it lands in C0's
   public-surface chunk WHEN actually built (§5), not speculatively now.

Until these are resolved, the §4.4 raw-runtime-view ledger entries stay
allowlisted; C3 migrates each consumer only once its replacement op exists.

### 2.4 What becomes PRIVATE (gate-banned outside the new app)

| Internal | Today's public symbol(s) | Public replacement |
|---|---|---|
| pid resolution | `Ezagent.KindRegistry.lookup/list_all` | `alive?/1`, `self?/1`, `read/3`, `list_instances/0` |
| readiness mechanics | `Ezagent.ReadyGate.status/await/put/mark_*` | `read/3` + `dispatch/1` await internally; `register_external_gate/1` stays public |
| delivery buffer | `Ezagent.PendingDelivery.*` | none — framework-only |
| snapshot store | `Ezagent.SnapshotStore.*`, `Ezagent.Ecto.KindSnapshot.*`, `Ezagent.Snapshot.Writer` | `read/3` (authoritative), `read_classified/2`, `read_durable/3` + `read_durable_many/3` (durable projection / list plane) |
| rehydration | `Ezagent.Kind.StateRebuilder.*` | `read/3` (spawning), `read_durable/3` (non-spawning); ops bulk-replay stays as a mix task inside the app |
| raw runtime view | `Ezagent.Kind.runtime_view/1` + the `:ezagent_runtime_view` call shape (`server.ex:584-587`) | `resolve_action_subject/2` (action-subject resolution), `read/3` (slice reads) — the raw view goes actor-internal (§2.3) |
| snapshot mechanics | `Ezagent.Kind.Snapshot.*` (commit/save_now/load_or_init/strip_transients) | none — framework-only |
| live slice call | `Ezagent.Kind.get_slice/2`, `get_raw_slice/2`, `SliceAccess.*` | `read/3` (`spawn: :never` reproduces live-only reads); `get_slice` DEPRECATED during migration, deleted from the public surface at the end (§5 C7) |
| actor host | `Ezagent.Kind.Server` (module + any `GenServer.call/cast(pid, {:ezagent_*, ...}` / `:ezagent_*` atom outside the app), `Kind.Runtime*`, `Kind.BehaviorSet`, `Kind.Spawner/ReadyTransition/MountDetach/Termination/DeferredDispatch/LaunchContext*` | dispatch/read/lifecycle surface |
| process generation | `Cap.Authority.current_process_generation/1` (spine-internal; 3 legitimate consumers, named in §4.2 — §5 C4 deletes ONLY the `Cap.Authorize` authz-decision one; the two generation-FENCE consumers survive) | none — becomes `@doc false` spine-private, callable only from the §4.2 fixed consumer list |
| idempotency table | `Ezagent.Idempotency.*` | framework-only (dispatch ctx flag unchanged) |

`Ezagent.Kind.normalize_slice_view/1` stays public: it is a pure shape
adapter consumers of `read/3` results still need for persisted blobs they
legitimately hold (e.g. MCP `decode_state` path, `slice_access.ex:135-151`).

---

## 3. The new umbrella app

### 3.1 Name + position

**`apps/ezagent_actor`** (name states intent: the actor/state-management
substrate; avoids colliding with the `Ezagent.Kind` module namespace).
**Module names FROZEN on the move** — repo precedent: "PR-9a — `entity/agent.ex`
relocated VERBATIM to the new `ezagent_domain_agent` app (module name FROZEN)"
(`arch.scan.ex:131-133`). No rename churn across the 53-file `get_slice`
caller set; public/private is a module LIST (§2.4), not a namespace pattern.

Dependency direction (today `ezagent_core` is the umbrella bottom — it has
zero `in_umbrella` deps; every other app declares `{:ezagent_core, in_umbrella: true}`):

```
BEFORE:  domain/plugin/web apps ──► ezagent_core (framework + spine + everything)
AFTER:   domain/plugin/web apps ──► ezagent_core (spine, policy, stores)
                              └───► ezagent_actor (actor framework)   ◄── ezagent_core
         ezagent_actor ──► (ecto_sql, phoenix_pubsub, telemetry ONLY — nothing in-umbrella)
```

`ezagent_actor/mix.exs` declares NO in_umbrella deps. That is the
compile-time teeth: **the framework physically cannot reference core/domain
modules** — `mix compile` inside `apps/ezagent_actor` against only its
declared deps is the standalone-compile acceptance check (§7.2), and the
umbrella xref/undeclared-dep discipline (the known masked-by-build-order
trap) is covered by that standalone compile, not by full-umbrella build order.

Honesty about what the app boundary does NOT give: Elixir cannot make public
modules unreachable downward — domain apps that (transitively) depend on
`ezagent_actor` can still name `Ezagent.SnapshotStore` and it will resolve at
runtime. Downward privacy is enforced by the gate (§4), exactly like the
read-plane precedent (`message_read_chokepoint_boundary_test`). The physical
split contributes: (i) upward-reference impossibility for the framework,
(ii) an unambiguous module inventory (the app's `lib/` IS the internal set —
the gate's banned list is derived from it, not hand-curated), (iii) a place
where framework tests/ops tasks live without being mistaken for public API.

### 3.2 What moves

Everything in §1's first four groups, verbatim (`git mv`), keeping module
names: `kind.ex`, `kind/**` (EXCEPT `kind/template.ex` AND `kind/template/**`
— Template is domain policy, not actor mechanics, and the SUBTREE is
load-bearing outside the framework: `kind/template/pre_start.ex` is a NAMED
GenServer (`name: __MODULE__`, `pre_start.ex:10-20`) supervised by CORE
(`application.ex:30`) whose implementation the workspace domain registers
at boot (`ezagent_domain_workspace/application.ex:73`) — v1's literal
`EXCEPT kind/template.ex` would have dragged it (and
`kind/template/attribute_hook.ex`) across WITHOUT its supervision, and
workspace boot would `:noproc`; the whole `kind/template` subtree STAYS,
with `TemplateRegistry`/`Workspace`/`Sandbox.ConfigDir`/`AgentManifest`
upward refs and core supervision unchanged; `kind/identity_read_error.ex`
moves), `lifecycle.ex`, `invocation.ex`, `router.ex` + `cmd.ex`,
`kind_registry.ex`, `ready_gate.ex`, `pending_delivery.ex`, `idempotency.ex`
+ `idempotency/sweeper.ex`, `snapshot_store.ex`, `snapshot/writer.ex`,
`ecto/kind_snapshot.ex`, `spawn_registry.ex`, `local_runtime.ex`,
`slice_change*`, `behavior.ex` + the `behavior/` CONTRACT modules
(`effects,kind_base,legacy_callbacks,introspection` — the five policy
ActionSets stay, §3.4 scan findings), `behavior_registry.ex`,
`universal_behaviors.ex`, `interface_validator.ex`, `uri.ex` (+
`ecto/uri_type.ex`) together with `uri/scheme_registry.ex` (atomic move —
below), and `lib/ezagent_core/kind_supervisor.ex`, plus their tests and the
framework mix tasks (`ezagent.snapshots.*`-class tooling). The framework's
supervision children move with it: `ezagent_actor` gets its own Application
owning the ETS tables today created by `EzagentCore.EtsOwner` (ready_gate /
pending_delivery / idempotency / spawn_registry / scheme_registry /
slice-change cursors / behavior_registry), plus the stdlib `Registry` child
backing `Ezagent.KindRegistry` — `{Registry, keys: :unique, name:
Ezagent.KindRegistry}`, today a CORE child (`ezagent_core/application.ex:33`);
`kind_registry.ex` is a thin WRAPPER over that separately-supervised
process, so moving the wrapper module without also moving this child would
`:noproc` on the first `put_new`/`lookup` at actor startup — plus
`Snapshot.Writer`, `Idempotency.Sweeper`, and `KindSupervisor`.

**`URI.SchemeRegistry` moves ATOMICALLY — module + ETS ownership + boot
seed.** v1 moved `uri.ex` but did not move the registry — an uncaptured
upward edge: the moved `uri.ex:177,190,248,988` and `spawn_registry.ex:71`
call it, while its ETS table and seed stayed in core. The three pieces
travel as ONE commit inside C5: (i) `uri/scheme_registry.ex` moves; (ii)
its ETS table entry (`{Ezagent.URI.SchemeRegistry, :set}`,
`ets_owner.ex:75`) leaves `EzagentCore.EtsOwner` for the actor app's ETS
owner; (iii) the 6-scheme boot seed (`seed_uri_schemes/0`,
`application.ex:231-239`, invoked at `application.ex:120-123` — the
existing comment already demands it run "BEFORE any code path that calls
`Ezagent.URI.new!/1`") moves into `ezagent_actor`'s `Application.start/2`.
Ordering then becomes STRUCTURAL, not comment-enforced: `ezagent_core`
depends on `ezagent_actor`, so OTP starts the actor app — and the seed —
before any core boot code can call `URI.new!/1` (e.g. the
`system://routing/default` sentinel spawn, `application.ex:150`). The seed
list (`~w(entity workspace session template resource system)`) is string
data, not policy modules; plugins keep extending schemes via
`SpawnRegistry.register/2` co-registration exactly as today.

The `kind_snapshots` migration stays in core's priv (migrations are a
deploy-repo/Repo concern); the SCHEMA module moves.

### 3.3 What stays in `ezagent_core` — the cap/authority spine does NOT move

**Decision: the cap/authz/generation/DeliveryOutbox spine stays in
`ezagent_core`.** Justification:

1. **It is #195-ACTIVE.** Unified-revocation merged days ago
   (`7e3ee6560`, `b96b1cd9a`); the regenesis/backfill/lockout follow-ups are
   in flight. Moving `cap/*` mid-workstream collides with an active branch
   family for zero boundary gain — the spine is not "actor internals"; its
   truth is durable rows (`kind_cap_authorities`, `cap_deliveries`), not
   process state.
2. **Its dependency direction is UPWARD-facing anyway.** The spine reaches
   into domain policy via the dependency-inverted `authority_loader` config
   (`authorize.ex:118-122` → `Ezagent.Identity.read_held_caps/1` in the
   identity DOMAIN) and `Capability.workspace_of/1` consults
   `WorkspaceRegistry` (`capability.ex`). Pulling the spine below core would
   drag identity/workspace knowledge down with it — the opposite of a clean cut.
3. **The framework's need of the spine is narrow and portable** (§3.4): open
   a compartment at init, run closures inside it, retire/regenerate, verify
   artifacts, mark outbox rows. A small behaviour covers it.

### 3.4 The ports — how the framework calls the spine without depending on it

The port table below is EMPIRICAL, not hand-derived: every §3.2 file was
ripgrep-scanned for aliased and fully-qualified references to staying-in-core
modules, and every hit was read to separate real calls from doc references
(census at `62f606b8f`; the C5 pre-flight re-runs the same scan as the
completeness gate). The scan found real cross-boundary calls the first
hand-derived draft (4 ports, from reading `server.ex`/`invocation.ex`/
`runtime.ex` only) missed — rows marked *(scan)* below. Result: **9 ports**
+ 2 config injections.

| Framework call site | Spine/policy call | Port — OWNER (core module the adapter wraps) |
|---|---|---|
| `server.ex:143-155` (init) | `Cap.Authority.open/3` + run snapshot load under `with_current` | **AuthorityPort** `open(uri, kind_type, freshness)` → opaque token — owner `Ezagent.Cap.Authority` (adapter also fronts `Ezagent.Cap`/`Cap.Verifier`/`Cap.RuntimeView` for the artifact/view rows below) |
| `server.ex:349-354,410-413,577-581,693-699,715-719,757-761,933-937` | `Cap.Authority.with_current(authority, fun)` | AuthorityPort `with_authority(token, fun)` |
| `server.ex:705-713` (`:ezagent_revoke_all_to`) | `Cap.Authority.regenesis/3` | AuthorityPort `regenesis(uri, kind_type, ctx)` |
| `server.ex:663` (destroy) | `Cap.Authority.retire/1` | AuthorityPort `retire(uri)` |
| `server.ex:571-582,688-699` | `Cap.validate_for_current_target/2`, `Cap.Verifier.valid_artifact?/2` | AuthorityPort `validate_artifact/verify_artifact` — takes `artifact :: term()`; the ADAPTER validates the representation (the moved `server.ex:689` handler no longer struct-matches — opacity rule below) |
| `server.ex:593-604` (`:ezagent_recredential_generation`) | reads `authority.generation` | AuthorityPort `generation(token)` — the authority struct becomes OPAQUE to the framework (today it is already `@opaque`, framework-private by doc: `cap/authority.ex:2-12`) |
| `kind/snapshot.ex:667` (load: verify persisted caps) *(scan)* | `Cap.verified_set/2` | AuthorityPort `verified_set(caps, receiver_uri)` |
| `runtime.ex:132` (install in-process view for SELF-target issuance during a dispatch) *(scan)* | `Cap.RuntimeView.with_current/3` | AuthorityPort `with_runtime_view(kind_module, state, fun)` — same compartment scope as `with_authority`; what crosses here (full state as today vs a narrower view) is governed by the §2.3 open question, constraint 1 |
| `runtime.ex` step 5.5 (`runtime.ex:174`) | `Cap.Verifier.authorize/…`, `Ezagent.Kind.holds_cap?/3` | **AuthzPort** `authorize_dispatch(inv, needed, ctx)` — owner `Ezagent.Cap.Verifier` + the relocated holds-cap spine module; the `holds_cap?/default_holds_cap?` block (`kind.ex:143-340`) MOVES OUT of `Ezagent.Kind` into a core spine module (it is cap policy layered on `read_classified/2`) |
| `runtime.ex:282` (`{:cap, :grant}` action path) *(scan)* | `Cap.Grant.authorize_and_issue_current/…` | AuthzPort `authorize_and_issue_grant(...)` — owner `Ezagent.Cap.Grant`; takes `cap :: term()`, ADAPTER validates (the `runtime.ex:270` args match no longer struct-matches — opacity rule below) |
| `behavior/introspection.ex:61` (data-owner resolution) *(scan)* | `CapabilityRegistry.data_owner_of/2` | AuthzPort `data_owner_of(behavior, instance)` — owner `Ezagent.CapabilityRegistry` |
| `runtime.ex:406,448,473`, `runtime/receipt.ex:67,99,113,121`, `runtime/effects.ex:480` (receipt emission + cross-workspace checks) *(scan)* | `Capability.workspace_of/1` (consults `WorkspaceRegistry` — §3.3.2, so NOT pure), `Capability.cross_workspace?/2`, `Capability.identity_key/1` | **CapabilityPort** (NEW) `workspace_of/1`, `cross_workspace?/2`, `identity_key/1` — owner `Ezagent.Capability`. The cap crosses the boundary as OPAQUE data — the framework never pattern-matches or constructs the struct (opacity rule below); only these semantics/policy functions are ported (Capability's dual role — §4.2) |
| `server.ex:821-856`, `invocation.ex:160-165,349,394,447` | `Cap.DeliveryOutbox.{replay?,eligible?,enqueue_and_attempt,mark_applied,record_handler_failure}` | **OutboxPort** — owner `Ezagent.Cap.DeliveryOutbox` |
| `ready_transition.ex:56,218` (ready-transition outbox drain) *(scan)* | `Cap.DeliveryOutbox.pending_target?/1`, `drain_target/1` | OutboxPort `pending_target?/drain_target` — SEVEN functions total, not the five first drafted |
| `invocation.ex:151-158,181-242` | `DispatchOrigin.validate/2`, `WorkspaceOwnerGate.assert_local_owner_for_uri/2`, admin-cap materialization (`Cap.issue_for_action`, `Cap.Verifier.non_cap_actions`) | **DispatchPolicyPort** `before_delivery(inv)` → `{:ok, inv} \| {:error, _}` — ONE hook folding origin/owner-gate/admin-materialization — owner `Ezagent.DispatchOrigin` + `Ezagent.WorkspaceOwnerGate` + `Ezagent.Cap` (one core adapter) |
| `runtime.ex:166` (re-dispatch origin check inside the actor) *(scan)* | `DispatchOrigin.validate/2` | DispatchPolicyPort `validate_origin(origin, ctx)` |
| `spawn_registry.ex:190`, `local_runtime.ex:50` (owner gate on the SPAWN/LIVENESS path — per-URI, not per-invocation, so `before_delivery` cannot cover it) *(scan)* | `WorkspaceOwnerGate.assert_local_owner_for_uri/2` | DispatchPolicyPort `assert_local_owner(uri, tag)` |
| `runtime/effects.ex:432` (`:emit` effects) *(scan)* | `Ezagent.EventLog.append/4` | **EventLogPort** (NEW) `append(uri, event, payload, ctx)` — owner `Ezagent.EventLog`. The actor side passes only `{uri, event, payload}` + trace/caller ctx and NEVER supplies `workspace_uri`; the core ADAPTER derives the workspace scope from the event's target via the core persistence/workspace policy before calling `append/4` (adapter contract below) |
| `invocation.ex:587,619` (buffer-full / stale-incarnation), `ready_transition.ex:194` (drain failure) *(scan)* | `Ezagent.DLQ.put/2` | **DeadLetterPort** (NEW) `put(reason, inv)` — owner `Ezagent.DLQ` |
| `runtime/effects.ex:244` (`:saga` effect), `router.ex:117-141` (`dispatch_saga`) *(scan)* | `Ezagent.SagaRunner.execute/2` | **SagaPort** (NEW) `execute(saga :: term(), ctx)` — owner `Ezagent.SagaRunner`. The actor side never names the `Saga` type; the ADAPTER owns the `Code.ensure_loaded?` probe AND the `is_struct/2` representation check (Saga rule below); the port's `:not_configured` default replaces the soft-coupling |
| `kind/snapshot.ex:540`, `snapshot_store.ex:313` (workspace derivation for snapshot rows), `ecto/kind_snapshot.ex:75,127` *(scan)* | `Persistence.workspace_uri_for/1`, `Persistence.scope_by_workspace/2`, `Persistence.TransientRetry.with_retry/1` | **PersistencePort** (NEW) `workspace_uri_for/1`, `scope_by_workspace/2`, `with_transient_retry/1` — owner `Ezagent.Persistence` |
| `snapshot.ex`/`snapshot_store.ex`/`writer` | `EzagentCore.Repo` | **repo injection** (config, not a behaviour): `Application.fetch_env!(:ezagent_actor, :repo)` (Oban-style); core config sets it to `EzagentCore.Repo` |
| `runtime/effects.ex:363`, `invocation.ex:711`, `slice_change.ex:167,292,298` *(scan)* | `Phoenix.PubSub` under the literal server name `EzagentCore.PubSub` | **pubsub injection** (config, not a behaviour): `Application.fetch_env!(:ezagent_actor, :pubsub)`; core config sets it to `EzagentCore.PubSub` — `phoenix_pubsub` itself is already a declared dep of the new app |

**Capability is OPAQUE inside the framework — no struct pattern-matching
(decision: option (a); the kernel-app relocation is REJECTED).** "Crosses
as plain data" is only true if actor code never expands
`%Ezagent.Capability{}` — a struct pattern requires the DEFINING module at
COMPILE time, so a single match re-creates the upward compile edge, and a
behaviour (CapabilityPort) cannot remove it. The moved set has exactly two
such matches on `origin/main` — after the already-specified
`holds_cap?/default_holds_cap?` relocation takes `kind.ex:257-333`'s
matches out of the moved set with it: `runtime.ex:270` (the `{:cap,
:grant}` action path matches `cap: %Ezagent.Capability{}` inside the args
map) and `server.ex:689` (the `:ezagent_verify_cap_artifact` handler
matches its artifact argument). Both demote to plain bindings (`cap`,
`artifact`); representation validation moves to the core ADAPTERS that
already receive the value — the AuthzPort `authorize_and_issue_grant`
adapter and the AuthorityPort `validate_artifact`/`verify_artifact` adapter
each reject a non-`Capability` input as `{:error, :invalid_artifact}` (the
same adapter-validates rule as SagaPort, below). Typespec references become
`term()`/port-local types (non-port findings, below). The alternative —
relocating the `Ezagent.Capability` DATA TYPE into a lower kernel app both
core and `ezagent_actor` depend on — is rejected because it cannot be a
clean data move: `workspace_of/1` consults `WorkspaceRegistry` (§3.3.2), so
the kernel app would either drag workspace knowledge down or force a
type/functions split of one #195-active module, for a gain the two demoted
patterns already deliver. The §4.2 reverse gate ENFORCES opacity: a
`%Ezagent.Capability{}` pattern (or any staying-module struct pattern)
inside `apps/ezagent_actor/lib` is RED.

**SagaPort: the framework never names the Saga type — the ADAPTER validates
the representation.** v1's port leaked the core-owned
`Ezagent.SagaRunner.Saga` type upward: `Router.dispatch_saga/2` inspects
`is_struct(saga, Ezagent.SagaRunner.Saga)` before dispatch
(`router.ex:117-141`, check at `:131`) — and Router MOVES. Respec: the port
contract is `execute(saga :: term(), ctx :: map())`; moved Router/effects
code passes the saga value through UNINSPECTED; the core-side SagaAdapter
owns BOTH halves of today's soft-coupling — the
`Code.ensure_loaded?`/`function_exported?` probe AND the `is_struct/2`
representation check — returning `{:error, :saga_runner_not_loaded}` for
either failure (byte-for-byte today's observable contract,
`router.ex:121-141`). The port's `:not_configured` default stays. The atom
`Ezagent.SagaRunner.Saga` appearing anywhere in `ezagent_actor` lib code is
RED under the §4.2 reverse gate.

**EventLogPort: ONE 4-arg contract; Router's two map-form audit sites are
respec'd onto it.** v1 declared only `append(uri, event, payload, ctx)`
(the `effects.ex:432` shape) while Router emits audit MAPS — dispatch-start
at `router.ex:84-92` and completion at `router.ex:232-259` (append call at
`:248`) — via `safe_call(Ezagent.EventLog, :append, [%{...}])`. Verified on
`origin/main`: `Ezagent.EventLog` defines ONLY `append/4`
(`event_log.ex:131`); `append/1` does not exist, so `function_exported?` is
false and `safe_call` silently skips (`router.ex:287-299`) — BOTH Router
audit sites are dead no-ops today. Rather than adding a map-form callback
to canonize a shape the sink never implemented, both sites respec onto the
port's single 4-arg contract — `append(cmd.target,
:router_dispatch_start | :router_dispatch_ok | :router_dispatch_error,
payload_map, ctx)` — which keeps the port at one callback AND turns the
dead audit real. Best-effort semantics are preserved: an EventLog failure
never fails dispatch (Router keeps its rescue wrapper; `effects.ex:396-455`
already swallows).

**Adapter contract — workspace scope is DERIVED in core, never passed by the
actor.** `EventLog.append/4` REQUIRES `ctx.workspace_uri` — it raises
`ArgumentError` without it (`event_log.ex:131`, raise at `:135-138`;
`invocations.workspace_uri` is `NOT NULL`) — while `Cmd.ctx` neither
requires nor defaults a `:workspace_uri` key (`cmd.ex:53-61`: the ctx type
has no such key at all). So respec'ing the Router audit sites onto the port
with a passed-through Cmd ctx would swap one dead no-op for another: every
audit append would raise and be swallowed by the best-effort wrapper.
Closed, not canonized: the EventLogPort ADAPTER (in core) derives the
workspace scope from the event's TARGET via the core persistence/workspace
policy — `Persistence.workspace_uri_for/1` (`persistence.ex:93-110`), the
same policy the PersistencePort already fronts for snapshot rows — and
injects it into the `append/4` ctx itself. The actor side of the port
passes only `{uri, event, payload}` (+ trace/caller ctx) and never names
`workspace_uri`; a target whose workspace cannot be derived is an
adapter-side `{:error, _}` under the same best-effort rule (logged, never
raised into dispatch).

Wiring: `config :ezagent_actor, authority: Ezagent.Cap.AuthorityAdapter,
authz: …, capability: …, outbox: …, dispatch_policy: …, event_log: …,
dead_letter: …, saga: …, persistence: …, repo: EzagentCore.Repo,
pubsub: EzagentCore.PubSub` — adapters live in core. Precedents already
in-tree for exactly this inversion: `authority_loader` config
(`authorize.ex:118-122`), `ReadyGate.register_external_gate`
(`ready_gate.ex:62`), `SpawnRegistry.register/2` (scheme→fn). Ports are
`@behaviour`s in `ezagent_actor` with `:test` no-op/strict fakes so the
framework's own suite runs spine-free.

Also moving OUT of moved files into core (they are policy, not mechanics):
`Invocation.materialize_admin_action_cap` + `globally_non_cap_actions?`
(→ the DispatchPolicyPort adapter), `Kind.holds_cap?/default_holds_cap?`
(→ core spine module; dispatch reaches it via AuthzPort).

**Scan findings that are NOT ports** (upward references the scan surfaced
that resolve by moving, staying, or inverting — recorded so the C5
pre-flight does not re-litigate them):

- `kind/behavior_set.ex:328-349` (legacy slice-alias map + behavior
  dependency map) and `kind/kind_base_backfill.ex:100-116` (backfill sets)
  hard-code concrete domain/plugin ActionSet modules (`ActionSet.Session/
  Turn/Surface/ConfigEvolve/Identity/Sandbox/ApiKeys/CcHeadlessAgent/
  CurlAgent/ExternalMirror/SupervisorApproval/Publisher.SessionImpl`).
  These are module-ATOM references — the standalone compile (§7.2) will NOT
  flag them — so they are named here: both tables invert to registration
  data (BehaviorRegistry/config) at C5 pre-flight, the same idiom §6.8
  prescribes for `UniversalBehaviors`.
- The five core-authored POLICY ActionSets do NOT move (contract/policy
  split, §1/§3.2): `ActionSet.Routing` (CRUDs `Ezagent.Routing.RuleStore`,
  `behavior/routing.ex:162-191`), `ActionSet.Terminable`
  (`AgentLineage.lookup` + `Notifications.notify`,
  `behavior/terminable.ex:194-198`), `ActionSet.Manage`,
  `ActionSet.Notifications`, `ActionSet.Sandbox` (§4.4 census). They stay
  in core as ordinary boot-registered Behaviors — core becomes "just
  another Behavior author" — which is what keeps the port count at 9
  (no NotifyPort / RuleStorePort needed).
- `ActionSet.LegacyCallbacks` quotes `Ezagent.Capability.cap/3` into USING
  modules; the generated call executes in the (upward) using module, so it
  is not a framework RUNTIME dependency — but the module ATOM sits in
  `ezagent_actor` source, and the strengthened §4.2 reverse gate REDs
  atoms, not just calls. It is the reverse gate's single FIXED allowlist
  entry (reason recorded in the gate: quoted code, executes upward); the
  entry dies when LegacyCallbacks retires or the quote is parameterized
  at C5.
- `kind/template.ex` is excluded from the move (§3.2) — its
  `TemplateRegistry`/`Workspace`/`Sandbox.ConfigDir`/`AgentManifest` refs
  are Template-registry policy, exactly the class the policy→core rule exists
  for.
- Typespec-only references to staying types (`Ezagent.Capability.t/0`,
  `Ezagent.DispatchOrigin.t/0` in `cmd.ex`/`invocation.ex` specs) are types,
  not calls; they become port-local types or `term()` at C5.

**Circular-dependency blocker, stated plainly**: a FULLY self-contained
actor app (no ports) is impossible without also moving `Capability`,
`Cap.Authority`+`KindCapAuthority`, `DeliveryOutbox`, `WorkspaceOwnerGate`,
`DispatchOrigin`, `EventLog`, `DLQ`, `SagaRunner`, `Persistence` — i.e. most
of core, including #195-active surface and domain-facing policy. The port
set above IS the pragmatic boundary: **9 small behaviours (AuthorityPort,
AuthzPort, CapabilityPort, OutboxPort, DispatchPolicyPort, EventLogPort,
DeadLetterPort, SagaPort, PersistencePort) + 2 config injections (repo,
pubsub)**. Two invariants keep the count honest: the framework side of
every port trades ONLY in primitives, plain maps, module atoms, and opaque
tokens — never a staying module's STRUCT (Capability, Saga: the adapter
validates representations, per the blocks above); and where destructuring
of a staying type is needed, it happens in the ADAPTER, which returns
primitives. If the C5 pre-flight re-scan finds a 10th upward reference in
the moved set, the rule is: policy → extract to core adapter; mechanics →
move with the framework. (C5 in §5 re-runs the same ripgrep scan that built
this table, as the completeness gate before the move.)

---

## 4. The enumerator gate

### 4.1 Mechanism

New arch test **`apps/ezagent_core/test/architecture/actor_internals_boundary_test.exs`**
(lives in core so it is ALREADY on the PR-CI path — `@arch_invariant_test_paths`
in root `mix.exs:131-137` includes `apps/ezagent_core/test/architecture`;
`mix gate.arch` runs in the PR `gate` job AND inside `ci.local`/full-suite.
This dodges the known full-suite-only trap where a violation passes PR CI
and reds main).

Model: `message_read_chokepoint_boundary_test.exs` — **AST-based** (alias-
and line-split-resistant, incl. `alias … as:` and brace-form), with a
**module-keyed allowlist** (NOT the line-anchored `arch.scan` style, whose
anchors drift on every unrelated insertion — see the shift-comment graveyard
at `arch.scan.ex:118-157`), plus the gate-has-teeth self-tests (the door
exists; a fixture offender is caught).

### 4.2 The rule

Scan `apps/*/lib/**/*.ex` EXCLUDING `apps/ezagent_actor/lib` (pre-move:
excluding the §1 framework file set).

**Scope: the banned set is ACTOR INTERNALS ONLY** — derived from the moved
app's `lib/` minus the §2.2/§2.3 public surface. Spine and policy modules
are NOT banned roots: `Ezagent.Cap.*`, `Ezagent.Capability`,
`Ezagent.CapabilityRegistry`, the §3.4 port behaviours, and their core
adapters never appear in the list. Consequence: a correct §3.4 port call
can never trip the gate — ports are called FROM inside the framework
(excluded from the scan by construction), and the core adapters implement
port behaviours by calling SPINE modules, which are not banned. Capability's
dual role (spine type that also crosses the boundary as data) is therefore
safe by scoping, not by allowlisting — and the framework side never expands
the struct at all (§3.4 opacity rule; the reverse gate enforces it).

RED on any reference to:

- banned module roots (actor internals): `Ezagent.KindRegistry`, `Ezagent.ReadyGate` (except
  `register_external_gate`), `Ezagent.PendingDelivery`, `Ezagent.Idempotency`,
  `Ezagent.SnapshotStore`, `Ezagent.Snapshot.Writer`, `Ezagent.Ecto.KindSnapshot`,
  `Ezagent.Kind.StateRebuilder`, `Ezagent.Kind.Snapshot`, `Ezagent.Kind.SliceAccess`,
  `Ezagent.Kind.Server`, `Ezagent.Kind.Runtime*`, `Ezagent.Kind.BehaviorSet`,
  `Ezagent.Kind.{Spawner,ReadyTransition,MountDetach,Termination,DeferredDispatch,CascadeHook,LaunchContextInit,LaunchContextRelay}`
- banned call shapes: `GenServer.call/cast` whose message AST contains an
  `:ezagent_*` atom; `:sys.get_state/replace_state`; `Kind.get_slice`/
  `get_raw_slice` (ratchet-only — allowlisted en masse at first, §5 C7 flips it to banned)
- **process-generation containment (separate rule, FIXED allowlist — not
  part of the ratchet)**: any reference to
  `Ezagent.Cap.Authority.current_process_generation/1` outside its 3
  legitimate consumers is RED. The 3, RE-CENSUSED at `d9c9a90e7`
  (`git grep current_process_generation` over all `apps/*/lib` — the list
  is unchanged from the v1 `62f606b8f` census; the only other lib hits are
  the defining module itself, `cap/authority.ex:74-75`):
  1. `Ezagent.Cap.current_target_generation/1` (`cap.ex:132`) — the G-6/MF5
     stale-signer fence: SELF-target issuance requires the process-local
     sealed-signer generation to equal the durable active generation.
  2. `Ezagent.Cap.Authorize.autonomous_current?/1` (`cap/authorize.ex:87`)
     — seed (a); this entry is DELETED at C4.
  3. `Ezagent.Entity.Token.credential_generation_allowed/3`
     (`entity/token.ex:233`) — `:create_freshness`: a just-minted credential
     is honored only when issued by the currently-live generation.
  After C4 the list is exactly {1, 3} — both are generation-FENCE
  comparisons (process vs durable), not authorization decisions; C4 removes
  only the authz-decision use. §2.4's "becomes `@doc false` spine-private"
  means callable only from this list, not zero callers.

One known banned-SHAPE offender inside the spine seeds the ratchet
allowlist (it is migration debt, not a permanent exemption):
`Ezagent.Cap.action_context/3` reaches the actor host via
`GenServer.call(pid, :ezagent_runtime_view)` (`cap.ex:116-118`); it
migrates onto `Kind.resolve_action_subject/2` (§2.2) — NOT onto a public
raw view; `runtime_view` stays actor-internal (§2.3).

**Reverse direction** (the new app reaching UP): the standalone compile
(§7.2) proves call-level isolation but cannot see module-ATOM references
(the `behavior_set.ex` legacy tables, §3.4 scan findings) — and a struct
pattern that compiles fine in the umbrella build still re-creates the
compile edge. A companion AST scan inside `apps/ezagent_actor/lib` REDs,
for any `Ezagent.*`/`EzagentCore.*` module outside {the app's own modules}
∪ {the 9 port behaviours} ∪ {declared deps}, ALL THREE shapes: (i) CALLS;
(ii) bare module ATOMS in any position — data tables, quoted code, remote
types in specs; (iii) STRUCT PATTERNS and constructions
(`%Ezagent.Capability{…}`, `%Ezagent.SagaRunner.Saga{…}`, any staying
module) — one scan, three matchers, not three gates. Fixed allowlist
(reasoned entries, not part of the ratchet): exactly one — the
`ActionSet.LegacyCallbacks` quoted-injection (§3.4 non-port findings). Port
calls cannot trip it — the port behaviours ARE the app's own modules;
concrete adapters are named only in core config, never in `ezagent_actor`
lib code.

Allowlist: `@allowlisted_modules` — module names with a one-line reason each.
**Seeded with the FULL current census (§4.4) — the migration debt ledger —
and ratchets to `[]`.** A second test asserts the allowlist only SHRINKS
(compare against a committed count), the same ratchet discipline as the
oversized-module burn-down.

### 4.3 Empty-allowlist = the worklist enumerator

`ACTOR_BOUNDARY_ALLOWLIST=empty mix test <the gate file>` runs the same scan
with `@allowlisted_modules = []` and prints every offender as
`app | module | internal touched | file:line`. That output IS the complete
leakage worklist (Pillar-B completeness: the red build is the census, not a
hand-maintained list). Run it once at C0 to freeze the ledger in the plan
doc; re-run any time to measure drift/progress. CI runs the ratchet form;
the empty form is the enumerator.

### 4.4 Census seed (verified on `62f606b8f`, spot-re-verified at `d9c9a90e7`; the C0 empty-allowlist run is authoritative)

Production `lib/` reach-ins by category:

- **StateRebuilder**: `session_reads.ex:479` (c); `identity_data.ex:494` (world);
  `boot_reconciler.ex` (external_mirror — doc-refs + planned delegation).
- **SnapshotStore** (18 non-framework lib files): identity `entity_caps.ex`,
  `behavior/{workspace_shared,user_default}_credential_source.ex`; agent
  `agent_flavor_resolver.ex`, `behavior/agent/delivery.ex`, `recipe_resolver.ex`,
  `credential_status.ex`, `host_login_adopt.ex`; agent_bridge `agent_bridge.ex`;
  web `home_live.ex`, `session_controller.ex`; session `uri_query_resolvers.ex`;
  plugins curl_agent(2), hello(1); core-internal non-framework:
  `behavior/sandbox.ex`, `credential/{grant_row,resolver}.ex`.
- **KindRegistry** (~20 sites): agent `template_spawn/cascade.ex:311`,
  `transport_readiness.ex:376,438`, `retirement_sweeper.ex:103`,
  `domain/agent.ex:83`; socialware `anon_user/gc.ex:297,322`; workspace
  `workspace.ex:42`, `agent_create.ex:245`, `listing.ex:22` (list_all),
  `responsibility_assignments.ex:94`, `provisioning.ex:141`; identity
  `entity_caps.ex:52,215`, `users.ex:258` (self-detection), `entity.ex:90`,
  `target_authority.ex:55`, `operator_reads.ex:55` (list_all),
  `offboarding/reaper.ex:40`.
- **get_slice/SliceAccess** (53 files / 16 apps — the long tail): session(19),
  core-non-framework(6), agent(6), hello(5), identity(4) … each becomes a
  `read/3` or `read_classified/2` call or moves behind an existing chokepoint.
- **Process-generation**: `cap/authorize.ex:86-97` (a) — the OTHER two
  consumers (`cap.ex:132`, `entity/token.ex:233`) are on the §4.2 fixed
  allowlist, not in this ledger.
- **`:ezagent_*` GenServer shape in the spine**: `cap.ex:116-118`
  (`action_context/3`'s `:ezagent_runtime_view` call → migrates to
  `Kind.resolve_action_subject/2`, §2.2).
- **Raw runtime view** (`Kind.runtime_view/1` consumers outside the spine —
  §2.3): session `orchestrator/tools.ex:321` and cc
  `cc_orchestrator_seed.ex:204` (template-content reads → `read/3`);
  session `socialware/composition_caps.ex:509` (conformance check — ALSO
  calls the banned root `Kind.BehaviorSet.resolve_action` directly →
  `resolve_action_subject/2`); ui `auto_derive.ex:95` (introspection →
  `read/3` + `list_instances/0`).
- **Mount-snapshot caps**: `presenter_caps.ex` + 13 consumer modules (b).

Test-code reach-ins are NOT gated (framework tests move with the app;
other apps' tests get `Ezagent.ActorCase` test-support helpers as needed —
tracked in C5, not blocking the lib gate).

### 4.5 `check_invariants` wiring

Add invariant **#13 actor-boundary** to `mix ezagent.check_invariants`
(`apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.ex`) delegating to
the same scanner module (single source of truth; the mix task gives ci.local
parity, the ExUnit test gives PR-gate parity).

---

## 5. Migration plan — chunks, each independently reviewable + CI-green

**C0 — gate first, move nothing.** Land `actor_internals_boundary_test` with
the allowlist seeded from the empty-allowlist run (§4.3). Land the FULL §2.2
read surface as thin wrappers in core — all eight entry points, so no later
chunk introduces public API another chunk already consumes (v1 left
`read_cold*` out of C0 while C2 needed it on day one — a false
chunk-independence): `Kind.read/3` (compose `SpawnRegistry.ensure_live` +
`ReadyGate.await` + existing slice call), `Kind.read_classified/2`
(generalize `SliceAccess.read_identity_caps`), `read_durable/3` +
`read_durable_many/3` (the sanctioned snapshot-row projections, single +
one-query batch), `resolve_action_subject/2` (new actor-side handler
returning only the subject modules), `alive?/self?/list_instances`. Zero
behavior change; the ledger exists; every later chunk shrinks it. *(Gate
before move: violations enumerate at zero risk. Surface before consumers:
C1–C6 only CALL public API that C0 landed.)*

**C1 — PresenterCaps → fresh (early; user-visible correctness).** Drop the
mount-snapshot merge: `PresenterCaps.load/1` = `EntityCaps.load(presenter)`,
full stop. The "bootstrap-only artifacts for ephemeral mount authority"
carve-out gets an explicit narrow path (anon/ephemeral principals whose caps
are minted at mount and never revocable mid-socket) or dies if the C1
investigation shows no live consumer. Then fix `EntityCaps` itself onto
`read_classified/2` + `self?/1`, removing identity's
KindRegistry/SnapshotStore/ReadyGate/SpawnRegistry reach-ins
(`entity_caps.ex:27-37`). Allowlist −5 modules. *(Interacts with #195
holder-loading — coordinate: same seam (`authority_loader`), no signature change.)*

**C2 — cold reads → authoritative read.** `session_reads.surface_slice/1` →
`Kind.read(session_uri, :surface)` (deletes the StateRebuilder fallback,
seed (c)); world `identity_data.ex:494` → `read/3`/`alive?`; web
`home_live.ex`/`session_controller.ex` SnapshotStore reads → `read/3`;
session `uri_query_resolvers.ex`; agent credential/recipe/flavor snapshot
reads → `read/3` (each is a "durable view of a possibly-cold Kind" read).
Hard case flagged: reads on the LIST plane (many URIs) go through
`read_durable_many/3` — the §2.2 batch durable projection (one store query;
the public form of the read-plane `InternalReads` pattern, spec 2026-07-19
§3.4) — and single reads that must not spawn use `read_durable/3`. Both are
DURABLE-semantics APIs (§2.2): each migrated list caller's review RECORDS
that durable staleness is acceptable for that surface, or the caller
belongs on `read/3`, not on the list plane. Do NOT spawn 500 actors to
render a list (§6.3).

**C3 — KindRegistry/ReadyGate consumers → public liveness surface.**
Mechanical per-site: `lookup`-for-aliveness → `alive?/1`; `lookup`-for-self →
`self?/1`; `lookup`-then-`GenServer.call(pid, …)` → dispatch or a §2.2 read;
`list_all` → `list_instances/0` (OperatorReads keeps its authz on top).
The four non-spine `runtime_view` consumers (§4.4 raw-runtime-view
category) migrate in this chunk too: registry-lookup + raw-view +
`resolve_action` (composition_caps) → `resolve_action_subject/2`;
template-content and introspection reads (tools / cc_seed / auto_derive) →
`read/3` — replacement ops per the §2.3 open question (composition's
instance-membership check and AutoDerive's bounded DTO are settled at
implementation time; each consumer migrates only once its op exists,
staying allowlisted until then).
Workspace provisioning + agent transport-readiness are the fiddly ones
(they wait on incarnation transitions — if a genuine "await incarnation
change" need survives review, it becomes an explicit public
`await_incarnation/2` rather than a private-registry poke).

**C4 — boot-ordering removes `autonomous_current?` (seed (a)).** Delete the
process-generation branch from `Cap.Authorize` (`authorize.ex:82-97`) —
`principal_current?` collapses to `holder_caps(holder) != []` — and mark
`Authority.current_process_generation/1` spine-private (callable only from
the §4.2 fixed consumer list). **This is a spine change: sequence WITH the
#195 owner; it lands as its own PR with a fail-closed test (a gen-bumped
live process must be inert).**

**C4 preconditions (all three HARD — the deletion PR does not open until
all are green; precondition 2 is ALREADY green on `origin/main`).
Precondition 1 proves steady-state auth; 2 is the satisfied holder-store
contract; 3 proves BOOT ordering, which steady-state proofs cannot:**

1. **Self-license enumerator gate — at rest AND across a bump.** A gate
   that ENUMERATES every principal that today can pass `principal_current?`
   only via the process-generation branch (internal/ephemeral/autonomous
   principals — the F-6 narrow case) and proves TWO states per principal,
   not one: (i) a durable self-license exists AT REST (issued+stored at
   create/activate — the member-cap backfill precedent shows the shape);
   and (ii) AFTER a generation bump executed inside the gate harness, the
   principal re-holds a valid CURRENT-generation self-license once its boot
   completes — asserted by bumping and re-checking, never by observing that
   a license existed before the bump (a pre-bump license is exactly what a
   bump invalidates; proving it existed is the wrong theorem). Same
   Pillar-B discipline as §4.3: the gate run empty-allowlist PRINTS the
   worklist; C4 lands only when that run is EMPTY. A green enumerator is
   the proof the branch is dead code; deleting without it is a lockout
   (the read-plane member-cap lockout precedent).
2. **#195 G-3 holder-store contract — SATISFIED on `origin/main`.** G-3
   has LANDED (`8f7bb435f` "feat(cap): gate EntityCaps with creation-only
   self-license (G-3, MF1/v4-H2b)"): `Ezagent.EntityCaps.load/1` — the
   load source behind `Ezagent.Cap.Authorize`'s `authority_loader` seam
   (`authorize.ex:118-122`) — already applies the principal-generation
   self-license gate before any caller can use the returned set as
   authority (its own moduledoc states the contract; a gen-bumped
   principal loads EMPTY). So `principal_current?` collapsing to
   `holder_caps(holder) != []` reads the self-license through the same
   fail-closed store as every other holder cap. This is a precondition C4
   VERIFIES at PR-open (the gate sits in the load path it collapses onto)
   — not one it waits on, and never one it re-implements on a parallel
   path. C4 remains its own spine PR, coordinated with the #195 owner (§6.2).
3. **Boot-ordering: the self-license is durable BEFORE readiness.** The
   post-boot cap machinery sits on the WRONG side of the ready line — and
   none of it renews a self-license at all. Verified on `origin/main`: the
   host marks the Kind ready inside `handle_continue(:announce_ready, …)`
   (`server.ex:323` → `ReadyTransition.mark_ready`,
   `ready_transition.ex:98`) before deferred mailbox work runs, while the
   only post-boot self-cap machinery — config-evolve's deferred reconcile
   — issues and asynchronously absorbs the `:reconcile_cascade` +
   `Sandbox.update_config` OPERATIONAL caps
   (`issue_self_caps_and_reconcile`, `config_evolve.ex:238-264`;
   `activate/2` is just `send(self(), @ce_reconcile_signal)`,
   `config_evolve.ex:196-199`, handled post-ready at `:212`; absorbs are
   fire-and-forget casts, `config_evolve.ex:263-264` →
   `Identity.absorb_cap`, `identity.ex:147-182` — its own doc: "dispatches
   a VM-internal fire-and-forget cast without waiting for readiness"). It
   does NOT renew a `:self_license` — no code path does: self-license
   minting is CREATION-ONLY (`maybe_mint_self_license`,
   `behavior/identity.ex:176-198`, gated on `create_freshness: :created`,
   via `Authority.issue_self_license_current`,
   `cap/authority.ex:289-295`). After a gen bump the old license is
   already invalid, nothing re-mints it, and the operational-cap absorbs
   are still queued — so once `autonomous_current?` is deleted, a first
   dispatch admitted at ready is denied (no current-generation
   self-license exists to authorize it), and a crash between ready and
   absorb leaves the principal durably locked out. Requirement
   (design-level; mechanism is the implementer's): for any principal
   whose currency depends on a self-license, a generation-crossing boot
   must issue AND durably persist the current-generation self-license
   BEFORE `ReadyGate` reports ready — a NEW pre-ready boot step executed
   in the actor's own turn (target == self: no cross-actor delivery is
   needed, so "synchronous before ready" is cheap; creation-time minting
   already runs in-turn via `issue_self_license_current` and is the shape
   precedent), never a post-ready queued cast, and never a reordering of
   config-evolve's operational-cap reconcile. Precondition 1(ii) is the
   enumerator-side proof that this holds for every affected principal.

**C4 transition tests (land WITH the deletion PR, not after):**
- (t1) **live bump → inert**: bump the durable generation under a live
  principal; its next self-authorized dispatch is denied (today's
  fail-closed behavior, preserved by the deletion).
- (t2) **cold restart → independent renew**: kill the process post-bump,
  cold-start it, and assert it reaches ready holding a valid
  current-generation self-license — no dependence on pre-bump state.
- (t3) **renewal durable before readiness**: an ordering assertion (not
  sleep-based) that at the moment ready becomes observable, the durable
  self-license row is already committed.
- (t4) **first-dispatch race**: fire a dispatch concurrently at the
  earliest observable ready; it must authorize via the renewed license —
  never denied by a still-queued renewal (there is no
  `autonomous_current?` left to mask the window).

**Open question (implementation-time) — the pre-ready persist needs a
DEDICATED fail-closed seam.** Precondition 3 demands the self-license be
durably persisted before ready, FAIL-CLOSED — but the existing pre-ready
persistence path cannot carry that demand: `commit_post_init/2`
(`kind/server.ex:477-508`) is BEST-EFFORT BY DESIGN (Issue #342) — it
wraps `Snapshot.commit` in `try/rescue` + `catch :exit`, logs a warning,
keeps the mutation in-memory, returns `:ok`, and the boot proceeds to
ready. Riding it would let a persistence failure yield a ready principal
whose currency exists only in memory — exactly the durable lockout
precondition 3 exists to prevent, and it would make t3 unfalsifiable
under injected failure. Owner decision: the mechanism is designed at
implementation time against settled #195 code, not here. The requirement
that design must satisfy: the self-license persist gets a DEDICATED
fail-closed persistence step on the pre-ready path — an injected
persistence failure MUST prevent `ReadyGate` from ever reporting ready
(a failed, observable boot; never silent in-memory currency) — distinct
from, and not a behavioral change to, best-effort `commit_post_init/2`.
The deletion PR's test set therefore includes a fifth assertion:
- (t5) **persistence failure blocks readiness**: with a failure injected
  into the self-license persist step, the Kind never becomes ready and
  the failure is observable — asserted alongside t1–t4.

Consumer-scope correction (from the §4.2 empirical list): C4 deletes ONLY
`Cap.Authorize.autonomous_current?/1`. The other two
`current_process_generation` consumers — `Cap.current_target_generation/1`
(G-6/MF5 stale-signer fence) and `Entity.Token.credential_generation_allowed/3`
(`:create_freshness`) — are generation-FENCE reads, remain legitimate, and
are OUT of C4 scope.

**C5 — the physical move.** Pre-flight: re-run the §3.4 ripgrep scan over
the §3.2 set as the port-completeness gate; introduce the 9 ports + repo/
pubsub injection (§3.4) WHILE FILES STILL LIVE IN CORE (each port its own
reviewable PR; core adapters registered via config; framework tests run
against fakes); demote the two `%Ezagent.Capability{}` struct patterns to
plain bindings with adapter-side validation (§3.4 opacity rule —
`runtime.ex:270`, `server.ex:689`); apply the §3.4 non-port findings
(behavior_set/backfill table inversion, policy-ActionSet stay-behind,
LegacyCallbacks fixed-allowlist entry). Then the mechanical chunk: create
`apps/ezagent_actor`, `git mv` the §3.2 set verbatim (the EXCEPT set is
`kind/template.ex` + `kind/template/**` — PreStart's core supervision and
the workspace boot registration are untouched; `idempotency/sweeper.ex`
moves and re-supervises under the actor app; the stdlib `Registry` child
backing `Ezagent.KindRegistry` leaves core's child list,
`ezagent_core/application.ex:33`, for the actor Application's — §3.2),
move `uri/scheme_registry.ex`
+ its ETS ownership + the 6-scheme seed as ONE commit within the chunk
(§3.2 — registry, table, and seed are never split across a boot), add
`{:ezagent_actor, in_umbrella: true}` to core (+ explicit deps in apps that
call the public API), move framework tests, add
`apps/ezagent_actor/test/architecture` to `@arch_invariant_test_paths`.
Green = full umbrella + standalone `mix compile` of the new app + a cold
umbrella boot (scheme seeding now owned by `ezagent_actor` must precede
core's first `URI.new!/1` — app dep order makes it structural, the boot
run makes it observed).

**C6 — long-tail `get_slice` migration.** Ratchet the remaining ~45 files
in per-domain batches (session's 19 files is its own PR) onto `read/3`
(most are 1-line changes; the ones with hand-rolled cold fallbacks DELETE
the fallback).

**C7 — flip + empty.** `get_slice`/`get_raw_slice` leave the public surface
(delegate bodies fold into `read/3`'s internals); gate allowlist reaches
`[]`; the ratchet test flips to `assert @allowlisted_modules == []`.

Chunk-independence: C1–C4 and C6 only require C0 — which now carries the
ENTIRE §2.2 surface, closing the v1 gap where C2 consumed `read_cold*` APIs
C0 never landed. C5 requires only the port PRs. Nothing blocks on the #195
tail except C4 (explicitly coordinated) and the port-introduction PR for
AuthorityPort (signature-freeze check with the spine owner before landing).

---

## 6. Risks + do-carefully set

**6.1 Per-URI mailbox serialization is load-bearing — UNTOUCHED.** All
ordering machinery (single `Kind.Server` mailbox serializing
dispatch/mount/detach; `PendingDelivery.with_lock` linearizing cast delivery
with registration + ready-transitions, `invocation.ex:366-415`;
drain-then-mark FIFO, `server.ex:511-558`) moves VERBATIM. `read/3` routes
through the same mailbox (`:ezagent_get_slice` call) after ensure_live, so
reads serialize behind in-flight writes exactly as `get_slice` does today.
The gate bans OTHER code from touching these mechanisms; it does not alter them.

**6.2 #195 spine coordination.** The spine does not move (§3.3). Collision
surface = (i) AuthorityPort introduction (wraps the CURRENT `open/with_current/
regenesis/retire/verify` signatures — freeze-check with the spine owner, land
in a quiet window; afterwards #195 evolves BEHIND the adapter), (ii) C4
(explicitly a spine PR, sequenced with the #195 owner). Everything else is
disjoint from `cap/*`.

**6.3 Lazy-spawn amplification.** An authoritative read of a cold Kind costs
a spawn (authority open + snapshot load + post-init). Fine for single-URI
reads (same cost dispatch already pays on the cold path); WRONG for list
planes. Mitigations are part of the §2.2 contract: `spawn: :never` (refuse
cold), `read_durable/3` (deterministic durable view — never spawns, never
consults the live process), and list planes go through `read_durable_many/3`
— one store query, never N spawns, and single/batch durable reads can never
disagree (both are pure projections of the same rows, §2.2). C2/C6 reviews
must check each migrated caller's cardinality AND its recorded acceptance
of durable semantics.

**6.4 Self-read semantics.** `read/3` from inside the target's own callback
serves the durable projection (§2.2.4). For `{:snapshot, :on_change}` Kinds
(20 of ~33) this equals live state post-commit. For `:ephemeral`/`:periodic`
Kinds the durable view can LAG live state — same today for
`EntityCaps.load_persisted`; documented, and `read_classified` reports
`{:ok, _}` only for live reads. A Behavior reading ITS OWN slice keeps using
the callback's `slice`/`ctx.slice_state` argument (the documented contract,
`server.ex:1018-1031`) — the framework may raise on same-process `read/3` of
one's own slice in dev to catch lazy misuse.

**6.5 Backward compat during migration.** Names frozen; `get_slice` keeps
exact semantics until C7; every allowlisted call keeps compiling. No
flag-days: each chunk deletes its own allowlist entries. Rollback of any
chunk = revert that PR (the gate allowlist travels in the same commit).

**6.6 Test infra.** Other apps' tests seed state via framework internals
(e.g. `LifecycleCase`, snapshot writes). Lib-only gating keeps this legal
initially; C5 ships `Ezagent.ActorCase` (public test-support: spawn/seed/
assert-transients) so a later test-gating ratchet is possible, not required.

**6.7 Where a clean physical cut is impossible.** Stated in §3.4: without
ports the extraction drags most of core down. The ports ARE the boundary
design, not a compromise of it — they make the framework's upward needs
EXPLICIT and enumerable (9 behaviours + 2 config injections, §3.4 — an
EMPIRICAL census, not a hand-derived one), which is precisely what "strict
public interface" means for the reverse direction. Residual risk: an
overlooked upward ref discovered at C5 pre-flight; rule of decision recorded
(§3.4 last para) so it never blocks the chunk.

**6.8 BehaviorRegistry/ActionSet placement.** The CONTRACT set moves; the
five core-authored POLICY ActionSets stay (§1/§3.2 split — the §3.4 scan
already found their real upward refs: RuleStore CRUD, AgentLineage/notify,
sandbox domain reads). `behavior.ex`'s doc-refs to domain modules and
`UniversalBehaviors`' concrete list are re-checked at C5 pre-flight for
REAL upward refs (docs are fine; code refs get the policy/mechanics rule).
If `UniversalBehaviors` names core-side behaviors, it inverts to a
config-registered list — the same inversion the §3.4 scan findings already
mandate for `behavior_set.ex`'s legacy tables and
`kind_base_backfill.ex`'s backfill sets.

---

## 7. Acceptance

1. **Boundary clean**: `actor_internals_boundary_test` green with
   `@allowlisted_modules == []` — no lib code outside `apps/ezagent_actor`
   references any §4.2 banned symbol/shape. (The empty-allowlist enumerator
   run and the CI run are the same scan — no drift possible.)
2. **Physical proof**: `cd apps/ezagent_actor && mix compile
   --warnings-as-errors` succeeds against only `ecto_sql/phoenix_pubsub/
   telemetry` + stdlib — the framework references nothing above it — AND
   the §4.2 reverse-direction scan is green (no upward CALLS, module
   ATOMS, or STRUCT PATTERNS — the latter two the compile alone cannot
   see).
3. **Seeds closed with tests**: (a) `Cap.Authorize` has no
   process-generation branch + the five C4 transition tests green
   (t1 bump-inert, t2 cold-restart renew, t3 renewal-durable-before-ready,
   t4 first-dispatch race, t5 persistence-failure-blocks-ready — t5's
   seam per the §5 C4 open question); (b) a grant/revoke after
   LV mount changes the next action's authz outcome (no socket-lifetime cap
   snapshot); (c) `session_reads.ex` contains no `StateRebuilder` reference
   and the cold-surface E2E (BEAM restart → committed page renders) passes
   via `read/3`; (d) a cold-but-durable Kind serves `read/3` without any
   caller-side spawn/fallback code.
4. **Full umbrella green** (`mix ci.local` locally, `gate` + full-suite in
   CI); zero new failures vs the pre-chunk baseline on every chunk.
5. **No ordering regression**: existing FIFO/linearization tests
   (ready-transition, pending-delivery, incarnation fencing) pass unmodified.
6. **Boot-order proof**: a cold full-umbrella boot is green with URI scheme
   seeding owned by `ezagent_actor` (§3.2) — no core boot path reaches
   `URI.new!/1` before the registry is seeded (structurally guaranteed by
   app dependency order; observed by the boot run).

---

## Appendix A — evidence index

- Framework state shape + only-init invariant: `apps/ezagent_core/lib/ezagent/kind/server.ex:8-24`
- Authority compartment is framework-private by design (doc, pre-existing): `apps/ezagent_core/lib/ezagent/cap/authority.ex:2-12` (`@opaque` struct, `Inspect` derive excluding key)
- Process-generation ambient read: `cap/authority.ex:75-83`; its 3 consumers (§4.2 fixed list): `cap.ex:132` (G-6/MF5 fence), `cap/authorize.ex:86-97` (seed (a), deleted at C4), `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex:233` (`:create_freshness`)
- Dispatch chokepoint lazy-spawn: `apps/ezagent_core/lib/ezagent/invocation.ex:422-479`; linearization lock: `invocation.ex:366-415`
- Rehydrate-or-refuse primitive: `apps/ezagent_core/lib/ezagent/spawn_registry.ex:137-153`
- Live-only `get_slice` + cold-fallback workaround: `apps/ezagent_domain_socialware/lib/ezagent/socialware/session_reads.ex:465-487`
- Fail-loud classified identity read: `apps/ezagent_core/lib/ezagent/kind/slice_access.ex:200-276`; security-decision caller: `kind.ex:253-321`
- Self-call deadlock avoidance precedent: `apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex:52-60`
- Mount-snapshot cap merge: `apps/ezagent_plugin_world/lib/ezagent/world/presenter_caps.ex:14-28`; assign origin `apps/ezagent_web/lib/ezagent_web/live_auth.ex:234`
- Gate model (AST, module allowlist, has-teeth self-test): `apps/ezagent_core/test/architecture/message_read_chokepoint_boundary_test.exs`
- Line-anchored allowlist drift (what NOT to copy): `apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex:118-157`
- PR-CI arch-test path list: root `mix.exs:131-137` (`@arch_invariant_test_paths`)
- Module-name-frozen app-move precedent: `arch.scan.ex:131-133` (PR-9a note)
- Port-scan adds (§3.4, verified at `62f606b8f`, re-verified at `d9c9a90e7`): `EventLog.append` — `kind/runtime/effects.ex:432`; `DLQ.put` — `invocation.ex:587,619`, `kind/ready_transition.ex:194`; `SagaRunner.execute` — `kind/runtime/effects.ex:244`, `router.ex:117-141`; `Persistence.workspace_uri_for` — `kind/snapshot.ex:540`, `snapshot_store.ex:313` (+ `ecto/kind_snapshot.ex:75,127`); `Capability.workspace_of/cross_workspace?/identity_key` — `kind/runtime.ex:406,448,473`, `kind/runtime/receipt.ex:67,99,113,121`, `kind/runtime/effects.ex:480`; outbox drain — `kind/ready_transition.ex:56,218`; owner gate on spawn/liveness — `spawn_registry.ex:190`, `local_runtime.ex:50`; `Cap.verified_set` — `kind/snapshot.ex:667`; `Cap.RuntimeView.with_current` — `kind/runtime.ex:132`; `Cap.Grant.authorize_and_issue_current` — `kind/runtime.ex:282`; `CapabilityRegistry.data_owner_of` — `behavior/introspection.ex:61`
- Capability struct pattern-matches in the moved set (demote to plain bindings, §3.4 opacity rule): `kind/runtime.ex:270`, `kind/server.ex:689`; `kind.ex:257,259,261,298,333` leave the moved set via the `holds_cap?` relocation
- Saga type inspection before dispatch (moves into the core SagaAdapter): `router.ex:117-141` — `is_struct(saga, Ezagent.SagaRunner.Saga)` at `router.ex:131`
- Router map-form audit sites (respec'd onto the 4-arg EventLogPort; DEAD on `origin/main` — `Ezagent.EventLog` defines only `append/4`, `event_log.ex:131`, so `safe_call`'s `function_exported?` check silently skips, `router.ex:287-299`): start `router.ex:84-92`; completion `router.ex:232-259` (append at `router.ex:248`)
- SchemeRegistry topology (§3.2 atomic move): module `apps/ezagent_core/lib/ezagent/uri/scheme_registry.ex`; ETS entry `apps/ezagent_core/lib/ezagent_core/ets_owner.ex:75`; 6-scheme seed `apps/ezagent_core/lib/ezagent_core/application.ex:231-239`, invoked at `application.ex:120-123` before core `URI.new!/1` callers (routing sentinel spawn `application.ex:150`); framework callers `uri.ex:177,190,248,988`, `spawn_registry.ex:71`
- Template.PreStart supervision (why `kind/template/**` stays, §3.2): named GenServer `apps/ezagent_core/lib/ezagent/kind/template/pre_start.ex:10-20`; core child `application.ex:30`; workspace boot registration `apps/ezagent_domain_workspace/lib/ezagent_domain_workspace/application.ex:73`
- Raw runtime view returns the complete slice map: `kind/server.ex:584-587` (`Map.take(state, [:kind, :uri, :state])`); public facade `kind.ex:650-656`; non-spine consumers (§2.3/§4.4): `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex:320-330`, `apps/ezagent_domain_session/lib/ezagent/socialware/composition_caps.ex:508-513`, `apps/ezagent_domain_ui/lib/ezagent_domain_ui/auto_derive.ex:95`, `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/cc_orchestrator_seed.ex:203-214`
- C4 boot-ordering sequence (all `origin/main`): ready marked in `kind/server.ex:323` (`handle_continue(:announce_ready, …)`) → `Ezagent.ReadyGate.mark_ready` at `kind/ready_transition.ex:98`; config-evolve's post-ready OPERATIONAL-cap issuance (`:reconcile_cascade`/`Sandbox.update_config` — NOT self-license renewal) deferred from `activate/2` `apps/ezagent_domain_identity/lib/ezagent/behavior/config_evolve.ex:196-199`, handled post-ready at `config_evolve.ex:212`, issue+absorb in `issue_self_caps_and_reconcile` `config_evolve.ex:238-264` (absorbs at `:263-264`); fire-and-forget absorb envelope `apps/ezagent_domain_identity/lib/ezagent/identity.ex:147-182`
- Self-license minting is CREATION-ONLY (C4 precondition-3 evidence): `maybe_mint_self_license` `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:176-198` (gated on `create_freshness: :created`) → `Ezagent.Cap.Authority.issue_self_license_current` `apps/ezagent_core/lib/ezagent/cap/authority.ex:289-295`; G-3 landed on `origin/main`: commit `8f7bb435f` ("feat(cap): gate EntityCaps with creation-only self-license (G-3, MF1/v4-H2b)"), gate contract stated in `apps/ezagent_domain_identity/lib/ezagent/identity.ex` moduledoc
- Best-effort pre-ready persist (why C4's t5 needs a dedicated fail-closed seam, §5 C4 open question): `commit_post_init/2` `apps/ezagent_core/lib/ezagent/kind/server.ex:477-508` (Issue #342 comment; `rescue` + `catch :exit`, mutation kept in-memory, proceeds to ready)
- EventLogPort workspace derivation (§3.4 adapter contract): `EventLog.append/4` raises without `ctx.workspace_uri` `apps/ezagent_core/lib/ezagent/event_log.ex:131,135-138`; `Cmd.ctx` has no `:workspace_uri` key `apps/ezagent_core/lib/ezagent/cmd.ex:53-61`; derivation policy `Persistence.workspace_uri_for/1` `apps/ezagent_core/lib/ezagent/persistence.ex:93-110`
- KindRegistry backing child (§3.2/§5-C5 move set): stdlib `{Registry, keys: :unique, name: Ezagent.KindRegistry}` core child `apps/ezagent_core/lib/ezagent_core/application.ex:33`; wrapper doc `apps/ezagent_core/lib/ezagent/kind_registry.ex:1-10`
- §2.3 open-question anchors (runtime_view replacement constraints): cap-side SELF-target raw-slice read `apps/ezagent_core/lib/ezagent/cap.ex:161-172` (`self_target_subject/2` ← `Cap.RuntimeView.current`); full-state install `kind/runtime.ex:125-134` (`with_current` at `:132`); composition conformance + instance membership `apps/ezagent_domain_session/lib/ezagent/socialware/composition_caps.ex:507-528`; dispatch-path instance gate (separate) `kind/runtime.ex:170` (defp at `:333`); AutoDerive dynamic keys + full-slice detail `apps/ezagent_domain_ui/lib/ezagent_domain_ui/auto_derive.ex:75-119`
- Snapshot-row staleness metadata fields (§2.2 `read_durable*` meta): `apps/ezagent_core/lib/ezagent/ecto/kind_snapshot.ex:29` (`version`), `:41` (`updated_at`)
- Legacy domain-ActionSet tables inside moving files (module-atom refs, invert at C5): `kind/behavior_set.ex:328-349`, `kind/kind_base_backfill.ex:100-116`
- DI precedents: `cap/authorize.ex:118-122` (authority_loader), `ready_gate.ex:62` (external gate), `spawn_registry.ex:68` (scheme spawn fns)
- Umbrella bottom: `apps/ezagent_core/mix.exs` (no in_umbrella deps); all other apps declare `{:ezagent_core, in_umbrella: true}`
