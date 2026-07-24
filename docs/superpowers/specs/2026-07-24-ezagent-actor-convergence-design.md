# EzAgentActor — call/authz interface convergence — DESIGN SPEC

- **Date**: 2026-07-24
- **Status**: DRAFT v1 — for coordinator + Allen review, then codex adversarial pass
- **Kind of document**: a CONVERGENCE plan. NOT a rewrite, NOT an implementation plan.
- **Read off**: `origin/main` @ `36547a052` (every file:line cited below verified at this SHA)
- **Decision owner**: Allen (framing set 2026-07-24)
- **Builds on**: `docs/superpowers/specs/2026-07-23-actor-framework-umbrella-extraction.md`
  (the C0–C7 extraction — public surface + reach-in removal; C0/C1/C2 already landed:
  #1546, #1549, #1548, #1550, #1562) and
  `docs/superpowers/specs/2026-07-19-read-plane-authz-chokepoint-design.md`
  (read-plane chokepoints + anti-bypass gate — landed as PR-1..5: #1464/#1467/#1471/#1466/#1494).

---

## 0. The corrected framing — what this spec is and is not

Allen's correction (2026-07-24, supersedes any earlier PG-as-truth analysis): the goal is
**NOT persistence inversion**. Live-slice-as-truth is fine; PG is just storage. The goal is
**unifying the call/authz interface layer**. Business modules today insert
identity/permission/persistence handling inconsistently — different implementers,
non-uniform interfaces. The convergence target is **one enforced primitive**:

```
EzAgentActor.call({:uri, ACTOR_URI}, CMD, CMD_ARGS, CALLER_IDENTITY)
```

which resolves the URI, checks caps, and routes to the business module's CMD
implementation. Business modules use it TRANSPARENTLY and never touch persistence or
caps directly.

**The key insight, stated up front: this primitive already essentially exists.**
`Ezagent.Invocation.dispatch/1` (`apps/ezagent_core/lib/ezagent/invocation.ex:148-172`)
and its Cmd-level front `Ezagent.Router.dispatch/1` (`apps/ezagent_core/lib/ezagent/router.ex:79-104`)
already do exactly this pipeline: origin validation → workspace-owner gate → lazy-spawn
URI resolution (`invocation.ex:422-479`) → per-URI mailbox serialization → **step 5.5
capability verification** (`Ezagent.Cap.Verifier.authorize/6` called at
`apps/ezagent_core/lib/ezagent/kind/runtime.ex:174`) → workspace-isolation (step 5.6) →
args validation → route to the Behavior's `handle_<action>/2`. The chokepoint is real,
merged, and load-bearing.

So this spec is a **convergence**: tighten the existing chokepoint into THE single
enforced path, enumerate every current bypass, and give each bypass a close-plan plus
the gate that drives it to zero. It is sequenced AFTER the actor-framework extraction
C0–C7, which defines the public surface (`extraction spec §2.2/§2.3`) and removes the
244-site reach-in ledger this spec inherits as its starting census.

§1 — the enforcement/drift-detection mechanism — is the central design question and is
resolved first, because everything else in the plan is only as strong as it.

---

## 1. THE CENTRAL DESIGN QUESTION — what makes "everything goes through EzAgentActor" ROBUST

### 1.0 The requirement

Allen's bar: the analogy is asymmetric-key signing making admin non-forgeable — forging
requires the private key, so nobody can *casually* use admin authority in code without
being caught. What is the equivalent mechanism for "no business code may reach an actor
except through `EzAgentActor.call`"? A grep gate alone is bypassable; the answer must
say precisely what each layer catches, what evades it, and what the honest combined
guarantee is.

### 1.1 First, the ground truth about the platform (investigated, confirmed)

Four facts about BEAM/OTP/Elixir bound every possible design. Each is stated with the
consequence it forces:

1. **A pid is a bearer capability, and `GenServer.call` has no caller ACL.** OTP has NO
   native "restrict who may call this GenServer": `GenServer.call/3` is monitor + send
   (`:gen.call`), deliverable by any process that holds the pid or the registered name.
   The only callee-side hook is that `handle_call` receives `from = {pid, ref}` — the
   server *could* inspect the caller pid and refuse, but a pid carries no authenticatable
   provenance, and any allowlist/token the server would check is itself in-BEAM data,
   readable and forgeable by in-VM code. Consequence: **runtime enforcement must come
   from pid-encapsulation (deny the caller the pid), not from an OTP feature (none
   exists) and not from a callee-side ACL (unauthenticatable).**
2. **Atoms and module names are global.** Any code in the VM can write the atom
   `Ezagent.KindRegistry` or `:sys`; Elixir has **no cross-app module privacy** — a
   "private" module in `ezagent_actor` still resolves at runtime from any app. The
   extraction spec already states this honestly (§3.1: "Elixir cannot make public modules
   unreachable downward"). Consequence: **layer B (compile/dep boundary) can make the
   framework's own upward isolation physical, but downward privacy is enforced by
   gate + review, never by the language.**
3. **A named process is reachable by name, an unnamed one is enumerable.** stdlib
   `Registry` requires a `:name` atom (there is no anonymous Registry), and even a
   deliberately-hidden pid is recoverable via `Process.list/0` + `Process.info/2`,
   `Supervisor.which_children/1` on the (named) `Ezagent.KindSupervisor`
   (`apps/ezagent_core/lib/ezagent_core/kind_supervisor.ex:24` — `name: __MODULE__`), or
   `:sys.get_state/1`. Consequence: **pid-encapsulation is about removing every
   SANCTIONED way to obtain a pid, and gate-banning the enumeration shapes — it cannot
   make the pid cryptographically unobtainable in one BEAM.**
4. **Runtime bearer tokens buy nothing in-BEAM.** One could stamp every envelope with a
   boot-time secret held by `ezagent_actor` (the closest literal analog of "the private
   key"). But whatever the chokepoint checks is in-VM state, reachable by the same
   introspection the gate already bans — and the repo's settled Path A threat model
   (cap-signing spec `2026-07-16` threat-model section; read-plane spec §0) explicitly
   scopes OUT in-VM malicious code. Today's `DispatchOrigin` stamp is consistent with
   this: `Cmd.new/4` sets `origin: :trusted_internal` for any caller
   (`apps/ezagent_core/lib/ezagent/cmd.ex:106-124`) — it is a review discipline, not a
   forgery barrier. Consequence: **do not build a token scheme; it adds cost and no
   strength within the threat model.**

### 1.2 Layer A — the static AST arch gate (exists; state = strong, evadable, hardening path known)

**What exists on `origin/main`** — this layer is NOT hypothetical; C0 built it and one
hardening round already happened:

- `Ezagent.ActorBoundaryScanner` (`apps/ezagent_core/lib/ezagent/actor_boundary_scanner.ex`,
  876 LOC) — SSOT for both the ExUnit gate
  (`apps/ezagent_core/test/invariants/actor_internals_boundary_test.exs`, PR-CI path) and
  `mix ezagent.check_invariants` #13 (`ezagent.check_invariants.ex:84-90`).
- FORWARD scan: bans the actor-internal module roots (`scanner.ex:88-108` —
  `KindRegistry`, `SnapshotStore`, `Kind.Server`, `Kind.Runtime*`, `StateRebuilder`,
  `SliceAccess`, `PendingDelivery`, …), the `Kind.get_slice/get_raw_slice/runtime_view`
  calls (`:114`), `ReadyGate.*` except `register_external_gate` (`:116`), the
  process-generation read outside its fixed 3-consumer list, `:sys.get_state/replace_state/get_status`
  in literal, reflective (`apply/3`, `:erlang.apply/3`), and variable-receiver forms
  (`scanner.ex:119-123`, `:316-378`), and any `GenServer.call/cast` whose message is a
  Kind-protocol `:ezagent_*` verb — including **interprocedural taint**: a fixpoint over
  bindings, destructures, helper-chains, and positional-parameter relay, with the
  `@kind_message_verbs` protocol allowlist as the precision discriminator
  (`scanner.ex:138-163`, `:407-463`; hardening PR #1549).
- REVERSE scan: the mover set may not reference staying-core modules in ANY of three
  shapes — calls, bare module atoms, struct patterns (extraction spec §4.2).
- Ratchet integrity: SITE-level `{path, target, content_sha}` fingerprints, **multiset**
  enforcement (a byte-identical copy of an allowlisted line still REDs), shrink-only
  frozen counts (`actor_internals_boundary_test.exs:41-44` — `@forward_frozen 244`,
  `@reverse_frozen 123` at this SHA).

**How to AST-harden it for THIS spec's rules** (the convergence adds new banned shapes;
same scanner, new matchers):

- Ban **supervisor/process enumeration of framework processes**:
  `Supervisor.which_children/count_children/DynamicSupervisor.which_children` where the
  argument resolves to `Ezagent.KindSupervisor` (or any Kind-declared supervisor — the
  set is enumerable from `supervisor/0` callbacks), `Process.whereis` of framework-named
  atoms, and `Registry.lookup/select/dispatch` whose first argument is
  `Ezagent.KindRegistry` (the module-root ban already catches the alias/atom; the
  explicit shape closes the "call stdlib Registry directly with the atom" form).
- Ban **envelope forgery shapes** (new in this spec, §2.4/§4-V1): construction of
  `%Ezagent.Cmd{}` / `%Ezagent.Invocation{}` literals and calls to
  `Invocation.dispatch/Router.dispatch` outside {`ezagent_actor`, the enumerated ingress
  adapters} — ratcheted from a census like every other rule.
- Ban **caps-injection shapes** (§3): writing a `:caps` key into a Cmd/Invocation ctx
  outside the chokepoint + the tagged-ephemeral adapters.

**Honest residual evasion surface.** A static scanner is a heuristic. The C0 codex
review constructed evasions with zero current occurrence, and the tracked follow-up list
is explicit (`docs/futures/todo.md` 2026-07-24 section): interprocedural HEAD-pattern
destructuring, deeply-nested/computed extractors, container taint through opaque stdlib
transforms, `Kernel.apply(:sys, …)` qualified form, variable op-names
(`op = :get_state; apply(:sys, op, …)`), `Function.capture`, and in general
`apply(Module.concat(parts), fn_var, args)` with every component runtime-assembled.
`String.to_atom` + `apply/3` is not statically decidable — full stop. Layer A therefore
catches **all reach-ins that actually occur today, all casual/accidental additions, and
every known-common indirection form**, and is backstopped by per-PR adversarial review
for the exotic tail. It is necessary, not sufficient. One more scoping honesty: a blanket
"ban OTP primitives outside `ezagent_actor`" is NOT feasible — 52 lib files across the
umbrella legitimately `use GenServer` (PTY servers, channel adapters, sweepers, sidecars).
The ban is and must stay **targeted at Kind-actor-directed shapes** (banned roots +
Kind-message verbs + framework-pid introspection), which is exactly what the verb-allowlist
taint discriminator exists for.

### 1.3 Layer B — compile-time dependency + module-privacy boundary (what Elixir actually gives)

After C5 the framework is `apps/ezagent_actor` with **no in-umbrella deps**
(extraction §3.1). What this layer genuinely provides:

- **Upward impossibility (real compile-time teeth).** `cd apps/ezagent_actor && mix
  compile --warnings-as-errors` against only `ecto_sql/phoenix_pubsub/telemetry` proves
  the framework references nothing above it (extraction §7.2). This direction is a
  compiler error, not a scan miss.
- **An unambiguous internal set.** The app's `lib/` minus the §2.2/§2.3 public surface
  IS the banned list — derived, not hand-curated (extraction §3.1(ii)). This is what
  keeps layer A's config honest over time.
- **Downward privacy is NOT a language feature** (fact 1.1-2). What can be added
  mechanically: a compile-tracer boundary check (the `Boundary` library pattern, already
  named as an option in the read-plane spec §3.3) makes *static* cross-boundary
  references a **compile error** rather than a test failure — a meaningful ergonomic
  upgrade (fails earlier, in the offender's own compile) with the same metaprogramming
  blind spots as layer A. Recommended as an addition at V1, not a replacement for A.

**Exactly what must be private vs public** (the module LIST is the boundary; names per
extraction §2.2/§2.4, with this spec's deltas marked ★):

| Public (the ONLY sanctioned surface) | Private (gate-banned outside `ezagent_actor`) |
|---|---|
| ★ `EzAgentActor.call/4` (the named primitive; V1 façade over Router/Invocation — §4) | ★ `%Ezagent.Cmd{}` / `%Ezagent.Invocation{}` construction; `Router.dispatch/1` + `Invocation.dispatch/1` as raw entries (business tier) |
| `Kind.read/3`, `read_classified/2`, `read_durable/3`, `read_durable_many/3` (`kind.ex:677-806`) — ★ callable only from read chokepoints + framework tier after V3 (§2.1) | `KindRegistry` (module AND the stdlib-Registry atom), `ReadyGate.*` (except `register_external_gate`), `PendingDelivery`, `Idempotency`, `SnapshotStore`, `Snapshot.Writer`, `Ecto.KindSnapshot`, `StateRebuilder`, `Kind.Snapshot`, `SliceAccess`, `Kind.Server`, `Kind.Runtime*`, `Kind.BehaviorSet`, spawner/termination/mount internals |
| `resolve_action_subject/2` — ★ URI form only; the pid overload (`kind.ex:809`) goes internal | `Kind.get_slice/get_raw_slice` (C7 deletes), `Kind.runtime_view/1` (§2.3 of extraction — actor-internal) |
| `alive?/1`, `self?/1` (`kind.ex:824-836`); `list_instances/0` — ★ with pid REMOVED from meta (§2.4-i) | `Cap.Authority.current_process_generation/1` outside the fixed 2-consumer post-C4 list |
| Lifecycle: `Kind.spawn/terminate/mount/detach`, `Lifecycle.destroy/with_entity_transition` | ★ `Invocation.with_admin_operator/2` (operator adapters only, enumerated) |
| Authoring plane: `use Ezagent.Kind`, `Ezagent.ActionSet` contract, `BehaviorRegistry.register`, `SpawnRegistry.register/2`, `ReadyGate.register_external_gate/1`, `SliceChange` subscribe | everything else in `apps/ezagent_actor/lib` |

### 1.4 Layer C — runtime pid-encapsulation (the strongest backstop)

**Assessment of today, as asked:** yes — `Ezagent.KindRegistry` is a publicly-named
stdlib Registry that any code can `lookup`. The wrapper
(`apps/ezagent_core/lib/ezagent/kind_registry.ex:59-75`) exposes `lookup/1` and
`list_all/0` to the whole umbrella; the backing `{Registry, keys: :unique, name:
Ezagent.KindRegistry}` child is supervised in core
(`apps/ezagent_core/lib/ezagent_core/application.ex:33`); the extraction census found
~20 production lookup sites outside core (extraction §4.4), and C3 is precisely the
migration of those consumers onto `alive?/self?/read/list_instances`.

**What making it private requires** (in dependency order):

1. **C3 complete** — zero business-tier `lookup/list_all` callers (the extraction
   already owns this chunk).
2. **C5 complete** — the module and its Registry child live inside `ezagent_actor`
   (extraction §3.2), so the forward gate's ban on the root stops being a ratchet with
   allowlisted debt and flips to a hard zero.
3. **Close the pid leaks in the PUBLIC surface** (new findings, this spec):
   - `Kind.list_instances/0` returns `{uri, %{pid: pid}}` — **the sanctioned surface
     itself hands out pids today** (`kind.ex:845-851`). The meta must drop the pid
     (operator tooling that genuinely needs process identity moves inside
     `ezagent_actor` as mix tasks / an operator-gated op).
   - `Kind.resolve_action_subject/2` accepts a pid receiver (`kind.ex:809`) — the pid
     overload goes `@doc false` internal; the public form takes a URI.
4. **Gate the enumeration side-channels** (layer A hardening, §1.2): supervisor
   introspection of `Ezagent.KindSupervisor` + per-Kind supervisors, `Process.whereis`
   on framework names, direct `Registry.*` with the registry atom.
5. **The stdlib constraint accepted honestly:** Registry cannot be unnamed (fact 1.1-3),
   and the atom is writable from anywhere. Privacy is therefore "no sanctioned API
   returns or accepts a pid, and every unsanctioned way of obtaining one is a RED
   gate shape," not "the pid is secret."

**What breaks (cost, flagged):** operator/debug tooling that lists processes (moves
behind an operator op or into `ezagent_actor` mix tasks); tests that grab pids to
monitor/kill Kind processes (C5's `Ezagent.ActorCase` grows sanctioned test helpers —
extraction §6.6); agent transport-readiness / workspace-provisioning consumers that
poll the registry across incarnation transitions (C3 already plans an explicit
`await_incarnation/2` public op if the need survives review — extraction §5-C3). This
is the biggest-cost phase of the convergence (§4-V5) and it is deliberately LAST.

**Why this is the strongest layer:** after it, business code cannot *obtain* the object
a dynamic bypass needs. `apply(GenServer, :call, [pid, msg])` evades any static scan —
but only if you have `pid`. "You can't message a pid you can't name" — where "can't
name" means: no public API yields it, and every known way to fish for it
(registry atom, supervisor children, `Process.list`, `:sys`) is a banned shape that is
loud in a diff. The evasion that remains is deliberate multi-step circumvention, which
is exactly what review + the codex adversarial pass exist to catch.

### 1.5 The honest conclusion (the mechanism = the three layers TOGETHER)

**This design gives structural unforgeability, not cryptographic unforgeability.** The
precise claim:

> After convergence, any code path that reaches an actor, a cap decision, or actor
> persistence WITHOUT going through `EzAgentActor` must either (a) edit
> `apps/ezagent_actor` itself — visible as a framework-app diff, owned and reviewed as
> such, with the reverse gate + standalone compile constraining what it can quietly
> import; or (b) contain a statically-banned shape — RED in CI before merge; or
> (c) be a deliberately-constructed metaprogramming evasion of (b) — undetectable
> statically *in principle*, mitigated by review + the per-phase adversarial pass, and
> pointless under the settled Path A threat model, which already scopes out in-VM
> malicious code.

No single layer delivers this. Layer A alone is a heuristic with a known evasion tail;
layer B alone cannot make modules private downward (language fact); layer C alone
cannot make pids secret in one BEAM (platform fact). Together they close each other's
specific gaps: **A** catches what occurs and what is casually added; **B** makes the
boundary physical, the internal set derivable, and upward leakage a compile error;
**C** removes the bearer object so the dynamic evasions of A have nothing to aim at.
The signing analogy lands as: *the "private key" is write-access to
`apps/ezagent_actor` plus the willingness to put a RED-flagged shape in a reviewed
diff* — a forgery is not impossible, it is **unconcealable**. That is the correct and
achievable strength for a dev-time drift problem (read-plane spec §0: this class of
problem is an EVOLVABILITY problem, and the enemy is the casual bypass that rots into
legacy — not a malicious insider).

One runtime addition completes the picture: the **verifier-dominance runtime
invariant** from the cap-signing gate plan (§10 property 1 — "no handler-run event
without a matching authz event," telemetry-asserted). Static reachability says every
door leads through the chokepoint; the runtime invariant observes that in fact every
executed handler was preceded by a step-5.5 decision for the same `(instance, action)`.
It is the cheap runtime completeness check for the whole write plane and lands in
§4-V6.

---

## 2. The bypass census — every current way around the chokepoint, each with a close-plan + its gate

The extraction spec's ledger IS the base census: **244 frozen forward reach-in sites**
(`actor_internals_boundary_test.exs:41`; C1 took 261→255, C2 took 255→244), broken down
in extraction §4.4 (53 `get_slice` files across 16 apps; 18 `SnapshotStore` files; ~20
`KindRegistry` sites; the presenter-caps snapshot family). C3–C7 own driving that
ledger to `[]`. This section enumerates the bypass CLASSES that remain **even at
ledger-zero**, because they are sanctioned-today surfaces, not reach-ins.

### 2.1 Reads don't go through dispatch — the second authz surface (the hard one)

**The tension, stated exactly:** reads deliberately do NOT enter the actor mailbox.
Serializing reads through cold actors is an OTP anti-pattern and the read-plane spec
settled this (§2.1: "Reads must NOT be routed through the actor's mailbox… the fix
moves the cap-check to the read chokepoint, NOT into the actor"). So there are two
authz surfaces: step 5.5 for writes, and the read chokepoints for reads. The
convergence question: how do reads come under the ONE `EzAgentActor` discipline
without re-serializing them?

**The resolution — reads are `EzAgentActor`-OWNED but served from the durable
projection, not the live mailbox.** The pieces already exist in two halves that this
spec joins:

- The extraction's §2.2 read surface (`Kind.read/3`, `read_classified/2`,
  `read_durable/3`, `read_durable_many/3` — landed in C0, `kind.ex:677-806`) is the
  **plumbing** half: one sanctioned way to obtain live-or-durable slice state, batch
  reads as ONE store query, never N spawns. It performs **no cap check** — by design;
  it replaced raw `SnapshotStore`/`StateRebuilder` reach-ins.
- The read-plane chokepoints (`SessionReads` — note its signature already takes
  `caller` identity, `session_reads.ex:150-185`; `OperatorReads`
  (`identity/operator_reads.ex`); workspace/user reads; `InternalReads` for the
  no-principal framework tier) are the **policy** half: per-scope access policy
  (member-cap ∪ open-policy ∪ operator-cap, read-plane §2.2), row-policy ownership,
  live-first `Membership.authorize/3`.

**Convergence contract (the rule this spec adds):**

1. Every **principal-facing** read goes through a read chokepoint; every read
   chokepoint conforms to the `EzAgentActor` calling contract — it takes
   **CALLER_IDENTITY, never caps** (§3), resolves caps/membership FRESH at decision
   time, and touches state ONLY via the §2.2 plumbing surface or its designated
   raw-store owner.
2. The §2.2 plumbing surface itself becomes **restricted the same way `InternalReads`
   is** (read-plane §3.4 two-sided boundary): `Kind.read*/read_durable*` callable only
   from {read chokepoints, framework-internal tier, Behavior handlers inside a
   dispatch}. A LiveView loader or controller calling `Kind.read_durable/3` directly is
   a bypass of the authz half — today it is legal, after V3 it REDs. This is the single
   most important NEW gate in this spec: without it, ledger-zero still permits
   cap-ungated reads through the sanctioned plumbing.
3. Whether the chokepoint modules are literally renamed under an `EzAgentActor.read`
   namespace is a naming decision, not architecture — what converges is the
   **contract + the gate**, and the recommendation is to keep the per-scope modules
   (their §5 layer placements in the read-plane spec are correct and cycle-free) and
   bind them with the gate, not to build a monolithic read God-module.

**Gate that drives it to zero:** extend the boundary scanner with a
`read-plumbing-callers` allowlist (module-keyed, seeded from the census of current
`Kind.read*` callers, shrink-only) + the read-plane spec's existing raw-`Repo`/store
ban (§3.3). Enumerator run = the worklist (same Pillar-B discipline as extraction §4.3).

**Cost flag (honest):** this is a breadth problem — every principal-facing reader in
web/world/session tiers must be classified {chokepoint-backed | framework-internal |
violating}. The read-plane PR-1..5 work did the message plane; V3 generalizes to the
remaining slice-read planes. Second-biggest phase after pid-encapsulation.

### 2.2 Cap exemptions — `@non_cap_actions` / `cap_exempt_actions` — the ratchet-to-governed-zero

**Census on `origin/main`:** the verifier's closed map `@non_cap_actions`
(`apps/ezagent_core/lib/ezagent/cap/verifier.ex:21-42`) carries **15 actions across 6
ActionSets** (Identity: `cascade_notify_managers`; IdentityAdmin: 5 persistence ops;
Agent+User `receive`; SocialwarePublisherRead: `snapshot`/`history`; Session: 4
admission ops + `add_self`). The declaration-side flag `cap_exempt_actions/0` exists at
`apps/ezagent_core/lib/ezagent/behavior.ex:307-356`. The cap-signing spec's gate plan
(§10 property 2 — the exemption item the coordinator's brief references as §7.8)
already settles the DIRECTION: exemptions become a **structural class split** —
cap-gated actions are one declaration class where the verifier ALWAYS applies (no
exempt flag representable), and non-cap actions are a separate class carrying their
**own first-class authorization predicate** (admission → membership/invite predicate;
`receive` → `MemberReceive.authorize/1`; publisher reads → their read predicate;
identity persistence → the trusted-internal facade). The interim form (already live) is
enumerate-and-lock: the closed map, where "a new action cannot escape the verifier by
adopting an exemption class."

**The convergence plan:**

- **Phase-in (V4):** the macro-layer split (two declaration classes at
  `behavior.ex:307-356`) so cap-gated-AND-exempt is unrepresentable by construction;
  each `@non_cap_actions` family converts one PR at a time — the map may only shrink
  (frozen-count ratchet test, identical mechanics to the boundary ledger).
- **The honest end state:** NOT zero exemptions — the non-cap families are load-bearing
  and stay (cap-signing spec §2 already fixed this). The end state is **zero
  UNGOVERNED exemptions**: every non-verifier action is an enumerated member of a
  structural class with a named in-handler predicate over the session-authenticated
  presenter, and the verifier map itself is deleted (replaced by the class dispatch).
  "Ratchet-to-zero" = the INTERIM map's member count goes to zero as classes absorb
  members.
- **Gate:** the existing structural assertions (`keys(required_caps) ∪
  cap_exempt_actions == actions`, `behavior.ex:348`) + a shrink-only count on the
  verifier map + the cap-signing arch-gate items that forbid the bypass FLAGS on
  target-cap-gated actions (`cap_signing_architecture_test.exs`).

### 2.3 Direct ecto / actor-state / `KindRegistry.lookup` / `GenServer.call` — the ledger classes

Owned by the extraction (this spec does not respin them; it inherits their gates):

| Bypass class | Census (extraction §4.4, @`62f606b8f`, ledger-frozen 244 @`36547a052`) | Close plan | Gate |
|---|---|---|---|
| `Kind.get_slice`/`SliceAccess` reach-ins | 53 lib files / 16 apps | C6 per-domain batches → `read/3`; C7 deletes the public symbol | forward scanner root+call bans, SITE-multiset ratchet |
| `SnapshotStore` direct reads | 18 non-framework lib files | C2 (done: 8 callers, ledger 255→244) + C6 tail → `read_durable*` | same |
| `KindRegistry.lookup/list_all` | ~20 production sites | C3 → `alive?/self?/read/list_instances` (+ explicit `await_incarnation/2` if the need survives) | same + §1.4 enumeration-shape bans |
| direct `GenServer.call(pid, :ezagent_*)` | spine seed: `cap.ex:116-118` (`action_context/3` → `resolve_action_subject/2`) | C3 | Kind-message-verb taint (interprocedural) |
| direct `Repo`/Ecto on read planes | read-plane spec census (message plane closed by PR-1..5) | V3 extends the module-keyed raw-store ban to remaining stores | `message_read_chokepoint_boundary_test` model |
| process-generation ambient read | `cap/authorize.ex:86-97` (`autonomous_current?`) | C4 (spine PR, five transition tests, three hard preconditions — extraction §5-C4) | fixed-allowlist rule (post-C4 = exactly 2 fence consumers) |

### 2.4 NEW bypasses this spec names (found in this investigation; not in either parent spec)

1. **`list_instances/0` leaks pids on the sanctioned surface** (`kind.ex:845-851`,
   `meta = %{pid: pid}`). Close: drop the pid from meta at V5; operator tooling that
   needs process identity becomes an `ezagent_actor`-internal mix task. Gate: the
   public-surface spec test asserts the return type carries no pid.
2. **Envelope construction is open** — any module can `Cmd.new/4` (which stamps
   `origin: :trusted_internal`, `cmd.ex:106-124`) or build a raw `%Invocation{}` and
   call `dispatch/1` directly. The chokepoint is unavoidable once you're IN the
   pipeline, but the pipeline's front door has no doorframe: nothing distinguishes an
   enumerated ingress adapter from an arbitrary business module minting a
   trusted-internal envelope. Close (V1): `EzAgentActor.call/4` becomes the only
   business-tier entry; `Cmd.new/authenticated_external/trusted_internal` +
   `Router.dispatch/Invocation.dispatch` become adapter/framework-tier only, with the
   ingress-adapter set enumerated exactly as the cap-signing spec's §1.5 ingress
   inventory did for origin-stamping. Gate: envelope-construction shape ban (§1.2),
   census-seeded, shrink-only.
3. **`with_admin_operator/2` scope** (`invocation.ex:106-118`) — the process-local
   admin-materialization window (`materialize_admin_action_cap`,
   `invocation.ex:181-209`). Sound design (mint INSIDE the chokepoint, target-signed,
   ordinary verification), but its caller set is unenumerated. Close (V1): enumerate
   callers (CLI/World/Session-Config adapters per its own doc) into a fixed allowlist;
   gate RED on new callers.
4. **`resolve_action_subject/2` pid overload** (`kind.ex:809`) — public API accepting a
   raw pid receiver. Close (V5): URI-only public form.

---

## 3. The caps-resolution contract — identity in, caps resolved fresh at the chokepoint

**The hard rule (Allen's sketch, corrected as specified):** the fourth parameter of
`EzAgentActor.call/4` is the caller's **IDENTITY** — an authenticated principal `%URI{}`
(or `:vm_internal` for the enumerated trusted facades) — **NEVER a caps list.** Caps
are resolved FRESH at the chokepoint, at decision time, from the durable/live cap store
(`EntityCaps.load/1`). A caller-passed cap list is the stale/forged-cap vector, and this
repo has already paid for it twice:

- **The mount-snapshot staleness bug** (pre-C1): `PresenterCaps` merged a mount-time
  `assigns.current_caps` snapshot into every later authz context — a demoted admin kept
  admin rights for the socket lifetime (todo.md 2026-07-22; fixed by C1 #1548:
  `PresenterCaps.load/1` is now "exactly `EntityCaps.load(presenter)`, full stop" —
  `presenter_caps.ex:5-22`).
- **The C2 over-auth/TOCTOU vector** (#1550, hardened #1562): a cap **removed from the
  store without a generation bump** still verifies cryptographically (signature valid,
  generation current) — so an inline caller-held copy remains honorable even though the
  store no longer grants it. C2's batch read-plane authorizer therefore loads the
  caller's caps fresh ONCE per decision ("NEVER the caller-supplied inline caps… a cap
  revoked from the store without a generation bump lingers there → over-auth/TOCTOU",
  #1550 commit body), matched in-memory at the chokepoint owner
  (`Ezagent.Identity.caps_match?/2`, #1562). Signing defends forgery/tamper/retarget/
  issuer — it does NOT deliver per-cap revoke-completeness (the known deferred class);
  fresh store resolution at the decision point is what narrows that window.

**What already conforms** (state it so the implementer converges, not rebuilds):
`Ezagent.Cap.Authorize.authorize/3` (`cap/authorize.ex:46-63`) is already
principal-gate-independent — the holder's caps are loaded from the dependency-inverted
`authority_loader` (→ `Identity.read_held_caps/1` → `EntityCaps.load/1`, which is
generation-verified and fail-closed), and **presented candidates can never satisfy the
principal gate** (its moduledoc, rule 1). Each candidate is verified against the
target's CURRENT authority row (`verify_against_current/3`, fresh read). What does NOT
yet conform: the **candidate set itself** is caller-assembled — `Invocation.ctx`
requires `:caps` (`invocation.ex:73-81`), the verifier's candidates are literally
`ctx.caps` (`verifier.ex:123`), and business/web tiers populate it (via
`PresenterCaps.load` since C1 — fresh, but still hand-carried by every adapter).

**The convergence (V2):**

1. `EzAgentActor.call/4` has **no caps parameter**. The chokepoint resolves the
   candidate set itself: `EntityCaps.load(caller_identity)` at step 5.5 (or immediately
   before delivery for `:cast`), unioned with chokepoint-minted artifacts.
2. `ctx.caps` becomes an **internal envelope field** written only inside
   `ezagent_actor`. The three enumerated exceptions, all already chokepoint-side or
   explicitly tagged, are preserved as such:
   (a) **admin materialization** — minted inside `dispatch/1` after the origin check
   (`invocation.ex:181-209`), target-signed, verified like any cap;
   (b) **JIT ephemeral caps** — request-time caps that are never durably granted; the
   C1 carve-out already forces the tagged `PresenterCaps.EphemeralCaps` wrapper
   (`presenter_caps.ex:26-41`) so a bare/stale `%Capability{}` cannot be smuggled; V2
   lifts this to an explicit `EzAgentActor.call` option (`ephemeral:
   %EphemeralCaps{…}`) — tag-only, never a bare list;
   (c) **grant-flow artifacts** — the `{:cap, :grant}` path (`runtime.ex:120-122`),
   already special-cased inside the actor.
3. **Behavioral consequence, stated honestly:** for the dispatch plane, a
   store-removed-but-unexpired cap presented inline TODAY still authorizes (the C2
   vector, write-side). After V2 it cannot — the candidate set comes from the store.
   This is a deliberate authz-tightening, the same one C2 shipped for the read plane;
   it needs the same differential + TOCTOU tests (#1550's pattern: revoked-but-inline
   DENIED; chokepoint-resolved ⟺ presented parity for legit flows) and coordination
   with the #195 owner, since it grazes the revoke-completeness boundary (plan §68's
   deferred class shrinks but does not close — delete-resurrection etc. remain
   separate).
4. **Freshness contract:** point-in-time at decision (read-plane §3.2's window
   contract applies verbatim); one `EntityCaps.load` per dispatch (the same cost class
   the C2 batch path already accepted; per-URI actors make per-dispatch load O(1) in
   candidates, and batch planes hoist it exactly as `read_credential_statuses/3` does).

**Gate:** scanner rule — a `:caps` key written into a Cmd/Invocation ctx outside
{`ezagent_actor`, the EphemeralCaps-tag adapters} is RED; census-seeded, shrink-only
(the census is small: post-C1, `PresenterCaps.context/1` consumers + CLI dispatch).

---

## 4. Sequencing + phasing — each phase = a closable bypass + its enforcing gate

**Hard precondition: the extraction C0–C7.** This spec's phases consume the extraction's
public surface (C0, landed), its consumer migrations (C1–C3, C6), the spine deletion
(C4), the physical move (C5), and the flip (C7). Status at `36547a052`: C0 (#1546) +
gate hardening (#1549), C1 (#1548), C2 (#1550 + #1562) are MERGED; C3–C7 pending.
Phases V1/V2 below can begin before C5 (they touch the dispatch front door, not the
file layout); V5 hard-requires C3+C5.

| Phase | Closable bypass (§2 ref) | What lands | Enforcing gate | Depends on | Cost |
|---|---|---|---|---|---|
| **V1 — name the primitive; close the envelope front door** | §2.4-2, §2.4-3 | `EzAgentActor.call/4` as the business-tier entry (a thin, semantics-preserving façade over `Cmd.authenticated_external/trusted_internal` + `Router.dispatch`); ingress-adapter set enumerated; `with_admin_operator` callers enumerated; optional Boundary-style compile tracer (§1.3) | envelope-construction shape ban, census-seeded shrink-only; adapter fixed allowlist | C0 only | M |
| **V2 — caps-resolution convergence** | §3 | no caps param; chokepoint-side `EntityCaps.load`; `EphemeralCaps` option; TOCTOU + differential tests | `:caps`-write shape ban; TOCTOU test (store-removed inline cap DENIED) | V1; **coordinate w/ #195 owner** (spine seam) | M–L |
| **V3 — read-plane convergence** | §2.1 | every principal-facing read behind a chokepoint conforming to the identity-in/fresh-caps contract; `Kind.read*` plumbing restricted to {chokepoints, framework tier, in-dispatch handlers}; remaining raw stores under the read-plane §3.3 ban | read-plumbing-callers module allowlist (shrink-only) + raw-store ban extension; enumerator run = worklist | C0–C2 (surface + first migrations); benefits from C6 | **L (breadth)** |
| **V4 — cap-exemption structural split + ratchet** | §2.2 | two declaration classes at the Behavior macro layer; `@non_cap_actions` families absorbed one PR at a time; verifier map count → 0 | shrink-only count on the verifier map; class-split structural assertions; cap-signing §10-property-2 flag bans | independent of C5; **macro-layer refactor — coordinate w/ #195** | **L** |
| **V5 — pid-encapsulation** | §1.4, §2.4-1, §2.4-4 | `list_instances` drops pid; `resolve_action_subject` URI-only; enumeration-shape bans live (supervisor introspection, `Process.whereis`, direct `Registry.*` w/ the atom); ops tooling relocated; `ActorCase` pid-free test helpers | §1.2 hardened shapes at zero-allowlist; public-surface type tests (no pid in any return) | **C3 + C5 complete** | **XL (flagged: ops tooling, tests, incarnation-wait consumers)** |
| **V6 — runtime dominance + closure** | §1.5 | verifier-dominance telemetry invariant (no handler-run without matching step-5.5 decision); convergence acceptance run | the runtime invariant itself + all prior gates at zero-allowlist | V1–V5 | S–M |

**The three biggest-cost items, flagged as required:** (1) **V5 pid-encapsulation of
KindRegistry** — not the registry itself (C5 moves it) but the long tail of ops
tooling, pid-grabbing tests, and the transport-readiness/incarnation consumers; (2)
**V3 read-plane convergence** — a breadth census across every principal-facing reader,
even with the message plane already done; (3) **V4 cap-exemption ratchet** — a macro-layer
refactor adjacent to live #195 spine work, which is why its interim (enumerate-and-lock)
is already in force and the split can proceed family-by-family without a flag-day.

**Rollback discipline** (inherited from the extraction): every phase's gate allowlist
travels in the same commit as its migration; reverting a phase = reverting its PR.

---

## 5. Acceptance

1. **One door, write plane:** `EzAgentActor.call/4` is the only business-tier dispatch
   entry — envelope-construction census at `[]`; ingress adapters enumerated and fixed.
2. **Identity-in, caps-fresh:** no public caps parameter anywhere on the call/read
   surface; `:caps`-write census at `[]` outside the chokepoint + tagged adapters; the
   TOCTOU test proves a store-removed inline cap no longer authorizes a dispatch.
3. **One discipline, read plane:** `Kind.read*` plumbing callable only from
   {chokepoints, framework tier, in-dispatch handlers} — allowlist at `[]`; every read
   chokepoint takes identity, resolves fresh.
4. **Exemptions governed:** verifier `@non_cap_actions` map deleted (members absorbed
   into the structural non-cap class, each with a named predicate); cap-gated-AND-exempt
   unrepresentable.
5. **No pid on the surface:** no public `ezagent_actor` API accepts or returns a pid;
   enumeration-shape bans at zero-allowlist.
6. **Runtime dominance observed:** the telemetry invariant holds across the full suite
   — every handler execution paired with a step-5.5 decision.
7. **Zero regression:** full umbrella green on every phase against the pre-phase
   baseline (the standing rule); the extraction's acceptance (its §7) already green
   before V5/V6 close.

---

## Appendix A — evidence index (all `origin/main` @ `36547a052`)

- Dispatch chokepoint pipeline: `apps/ezagent_core/lib/ezagent/invocation.ex:148-172`
  (origin gate → admin materialization → owner gate → outbox/idempotency → lazy-spawn);
  lazy-spawn `invocation.ex:422-479`; ctx type requires `:caps` `invocation.ex:73-81`;
  `with_admin_operator` `invocation.ex:106-118`; admin materialization
  `invocation.ex:181-209`
- Step 5.5 verifier call: `apps/ezagent_core/lib/ezagent/kind/runtime.ex:174` (within
  the `with` chain `runtime.ex:165-183`; instance-set gate `:170`; workspace isolation
  after `:182`)
- Verifier: `apps/ezagent_core/lib/ezagent/cap/verifier.ex:21-42` (`@non_cap_actions`,
  15 actions / 6 ActionSets); candidates = `ctx.caps` `verifier.ex:123`
- Principal gate independent of presented caps: `apps/ezagent_core/lib/ezagent/cap/authorize.ex:1-63`
  (moduledoc rule 1 + `authorize/3`); `autonomous_current?` `cap/authorize.ex:86-97`
  (C4 deletes); loader seam `cap/authorize.ex:118-122`
- Cmd envelope: `apps/ezagent_core/lib/ezagent/cmd.ex:106-124` (`origin:
  :trusted_internal` default, `caps: nil`); Router caps normalization
  `apps/ezagent_core/lib/ezagent/router.ex:150-172`, `:220-226`
- KindRegistry: wrapper `apps/ezagent_core/lib/ezagent/kind_registry.ex:59-75`
  (`lookup/list_all`); backing Registry child `apps/ezagent_core/lib/ezagent_core/application.ex:33`;
  named default supervisor `apps/ezagent_core/lib/ezagent_core/kind_supervisor.ex:24`
- C0 read surface: `apps/ezagent_core/lib/ezagent/kind.ex:677-806` (`read/3` at `:677`,
  `read_durable/3` at `:746`, `read_durable_many/3` at `:766`); pid leak in
  `list_instances/0` `kind.ex:845-851`; pid overload `resolve_action_subject`
  `kind.ex:809`
- Boundary gate SSOT: `apps/ezagent_core/lib/ezagent/actor_boundary_scanner.ex`
  (banned roots `:88-108`; kind-message verbs `:138-163`; taint fixpoint `:407-463`;
  reflective `:sys` `:316-378`); ledger frozen counts
  `apps/ezagent_core/test/invariants/actor_internals_boundary_test.exs:41-44`
  (`@forward_frozen 244`, `@reverse_frozen 123`); tracked evasion tail
  `docs/futures/todo.md` (2026-07-24 hardening section)
- C1 fresh-caps fix: `apps/ezagent_plugin_world/lib/ezagent/world/presenter_caps.ex:1-80`
  (fresh `EntityCaps.load`; tagged `EphemeralCaps` carve-out)
- C2 over-auth/TOCTOU semantics: PR #1550 commit body (`32a3335f3`) + #1562
  (`36547a052`, `Identity.caps_match?/2` at the chokepoint owner)
- EntityCaps loader: `apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex:42-105`
  (live-first verified load; fail-closed; self-case durable projection)
- Read-plane chokepoints: `apps/ezagent_domain_socialware/lib/ezagent/socialware/session_reads.ex:150-185`
  (identity-taking signatures); `apps/ezagent_domain_identity/lib/ezagent/identity/operator_reads.ex`;
  `apps/ezagent_domain_session/lib/ezagent/session/internal_reads.ex`
- Cap-signing exemption direction: spec `2026-07-16-cap-signing-per-kind-authority-design.md`
  §10 property 2 (structural class split preferred / enumerate-and-lock interim) +
  `behavior.ex:307-356` (`cap_exempt_actions` flag + coverage assertion `:348`)
- Extraction spec anchors consumed here: §2.2 (read surface), §2.4 (private table),
  §3.1 (honesty about downward privacy), §4.2-§4.4 (gate + census), §5 (C0–C7),
  §6.3 (list-plane amplification)
