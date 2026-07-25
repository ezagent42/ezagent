# EzAgentActor — call/authz interface convergence — DESIGN SPEC

- **Date**: 2026-07-24
- **Status**: DRAFT v3 — codex R1 = NEEDS-WORK (direction GOOD) → v2 folded all six R1
  findings; codex R2 confirmed 4/6 CLOSED (reframe, verifier-dominance-as-diagnostic,
  ephemeral-authority provenance, V2 AuthzPort/#195 + V4/V6 deps, the 4 named pid
  surfaces) and found two remaining pid-USE-side holes, both closed in this revision:
  (R2-1) the v2 "verb-totality" claim was FALSE — `Kind.Server`'s catch-all
  `handle_info` forwards ANY message shape to Behavior `handle_signal/2` under the open
  authority compartment with the full mutating effect pipeline (`{:pty_phase,…}`
  durably mutates with no `:ezagent_*` verb), so the use-side gate is now the
  **all-shapes receiver ban** (ANY `send`/`call`/`cast` to a Kind-provenance pid,
  any message, outside the framework), with the verb matchers demoted to backstop and
  the handler-`self()` claim restated honestly (§1.4); (R2-2) the pid-INPUT census
  completed — `Kind.runtime_view/1` (pid form) and `Kind.monitored_by?/2` (+ its
  `members.ex:45` consumer) added and closed, and the no-pid gate extended to
  parameter types + `is_pid` guards. Earlier v2 content: (1) §1.5 guarantee =
  "enumerated, reviewed-code drift guarantee" — "unconcealable in reviewed code",
  aligned with the cap-signing spec's enforceability limit; (2) pid-returning surfaces
  closed via the no-pid gate (owner decision); (3) verifier-dominance telemetry =
  DIAGNOSTIC; (4) no public `:vm_internal`; ephemeral authority provenance-enforced
  via a fixed policy adapter; (5) fresh authority resolution behind the AuthzPort
  seam; (6) V1–V6 dependencies repaired (V2→port contract + #195 seam; V4 ownership
  split across C5; V5 pid closure both sides; V6→C7).
- **Kind of document**: a CONVERGENCE plan. NOT a rewrite, NOT an implementation plan.
- **Read off**: `origin/main` @ `e7a153a92` (v1 read at `36547a052`; every cited anchor
  re-verified at `e7a153a92` — the C3 landing between the two moved no cited line)
- **Decision owner**: Allen (framing set 2026-07-24)
- **Builds on**: `docs/superpowers/specs/2026-07-23-actor-framework-umbrella-extraction.md`
  (the C0–C7 extraction — public surface + reach-in removal; C0/C1/C2/C3 already landed:
  #1546, #1549, #1548, #1550, #1562, #1561) and
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
C0–C7, which defines the public surface (`extraction spec §2.2/§2.3`) and burns down
the reach-in ledger this spec inherits as its starting census (255 sites at C0-freeze;
208 remaining at the current read-off after C1–C3).

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
  frozen counts (`actor_internals_boundary_test.exs:46-49` — `@forward_frozen 208` post-C3,
  `@reverse_frozen 123` at this SHA).

**How to AST-harden it for THIS spec's rules** (the convergence adds new banned shapes;
same scanner, new matchers):

- The **all-shapes receiver ban** (§1.4): receiver-provenance taint — any
  `send/2` / `Kernel.send` / `Process.send/3` / `GenServer.call` / `GenServer.cast`
  whose RECEIVER traces to a Kind-pid source REDs regardless of message shape
  (`Kind.Server`'s catch-all `handle_signal` fan-out accepts arbitrary shapes, so a
  verb-only matcher is not total). The existing protocol-verb + `:sys` matchers
  remain as the backstop for receivers taint cannot see, with the verb-list sync
  self-test keeping that backstop's discriminator honest.
- Add the **no-pid gate** over the framework's sanctioned surface (§1.4): a
  `pid()`-reaching return OR parameter type (or `when is_pid` guard) on any public
  Kind-actor function — directly or through known aliases like
  `DynamicSupervisor.on_start_child()` — is RED, backed by a runtime deep-walk
  assertion in the framework's own suite. (Enumeration-shape bans — supervisor
  introspection of framework supervisors, `Process.whereis` on framework names,
  direct `Registry.*` with the registry atom — remain in the optional D1 package,
  §1.4: with no sanctioned door yielding a pid and every use RED, they matter only
  against code willing to fish.)
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

### 1.4 Layer C — runtime pid discipline: no pid leaves the framework (obtain-side) + pid-USE closure (use-side)

**Scope decision (owner, 2026-07-24, final): the guarantee target is "unconcealable
in reviewed code"** — not "structurally unconcealable against unreviewed in-BEAM
code" (that is Path B). Within that target, the owner decided layer C carries BOTH
structural halves (the obtain-side elimination is cheap and wanted):

> **A caller neither OBTAINS nor USES a Kind pid without a reviewed RED shape.**

**Assessment of today, as asked:** yes — `Ezagent.KindRegistry` is a publicly-named
stdlib Registry that any code can `lookup`. The wrapper
(`apps/ezagent_core/lib/ezagent/kind_registry.ex:59-75`) exposes `lookup/1` and
`list_all/0` to the whole umbrella; the backing `{Registry, keys: :unique, name:
Ezagent.KindRegistry}` child is supervised in core
(`apps/ezagent_core/lib/ezagent_core/application.ex:33`). C3 (#1561, landed) has
migrated the ~20 business-tier lookup consumers onto `alive?/self?/read/list_instances`
(ledger 244→208), and C5 moves the module inside `ezagent_actor`.

**Obtain-side: the pid never leaves the framework.** The pid-bearing sanctioned
surfaces (census completed at codex R1 — the v1 draft named only two of them):

- `Kind.spawn/3` returns `DynamicSupervisor.on_start_child()` — `{:ok, pid}` and the
  idempotent `{:error, {:already_started, pid}}` (`kind.ex:379-383`). Becomes
  `:ok | {:ok, :started | :already_started} | {:error, term()}` (or `{:ok, uri}`):
  spawn still calls `DynamicSupervisor.start_child/2` INTERNALLY — nothing about the
  supervision mechanics changes — it just stops leaking the pid; it already awaits
  ready internally, so no caller needs the pid to sequence on. Idempotency callers
  matching `{:error, {:already_started, pid}}` migrate to the `:already_started` atom.
- `Ezagent.LocalRuntime.ensure_started/2` + `ensure_started_detailed/2`
  (`local_runtime.ex:62`, `:72-73`) — same change (the started/already-started
  distinction survives; the pid does not).
- `Kind.list_instances/0` meta drops the `:pid` field (`kind.ex:845-851`); operator
  tooling that genuinely needs process identity moves inside `ezagent_actor` as mix
  tasks / an operator-gated op.
- `Kind.resolve_action_subject/2` — the pid overload (`kind.ex:809`) goes `@doc false`
  internal; the public form takes a URI.
- **Pid-INPUT ops (census completed at codex R2 — the no-pid gate covers parameters,
  not just returns):**
  - `Kind.runtime_view/1` accepts a pid receiver (`kind.ex:857-859` —
    `runtime_view(pid) when is_pid(pid)` → `GenServer.call(pid,
    :ezagent_runtime_view)`). Already scheduled to retire ENTIRELY to actor-internal
    by the extraction (§2.3 — its consumers migrate to `resolve_action_subject/2` /
    `read/3` at C3-tail/C7); until that retirement completes, its pid form is a
    census entry under the no-pid gate, closed by the retirement itself.
  - `Kind.monitored_by?/2` takes TWO pids (`kind.ex:877-884` —
    `Process.info(pid, :monitored_by)`), with a live domain consumer: session
    members' rejoin pre-check (`apps/ezagent_domain_session/lib/ezagent/behavior/
    session/members.ex:45`, `self_monitors?/1` — note the pid it passes is
    re-materialized from session-tracked state, exactly the laundering pattern the
    static taint cannot follow). Close: replace with a URI-keyed public form (or
    internalize into the framework's membership machinery) and migrate the
    members.ex consumer; the pid form goes `@doc false` internal.

**The NEW no-pid arch gate — makes obtain-side enforceable, not conventional, in
BOTH directions.** A gate over the framework's SANCTIONED surface (the §1.3 public
table, a derived module/function list) asserting **no public Kind-actor function
returns OR accepts a pid**: (i) every public-surface function carries a `@spec`, and
the gate REDs any return OR parameter type that reaches `pid()` — directly or
through known aliases (`DynamicSupervisor.on_start_child()`, `GenServer.on_start()`)
— plus any `when is_pid(...)` guard on a public-surface head (catching pid-typed
params whose specs lie, the `runtime_view/1` / `monitored_by?/2` shape); (ii) a
runtime type assertion (an `ActorCase` helper that deep-walks sanctioned-API return
values in the framework's own suite and REDs on any `is_pid` leaf — catching returns
whose specs lie or are missing); (iii) the standard gate-has-teeth self-test (a
fixture offender is caught). Same family and CI path as the boundary scanner. With
this gate, a future convenience op that hands a pid across the boundary — either
direction — is a RED shape in the diff that introduces it, which is the entire point.

**Use-side: the COMPLETE `Kind.Server` mailbox-authority model — and why a
verb-shape ban alone is NOT total (codex R2, verified).** The v2 draft argued "a
Kind actor's entire useful protocol is the `:ezagent_*` verb set, so any useful
message is a RED verb shape." **That claim is FALSE.** The server's mailbox
authority has TWO tiers:

1. **Matched protocol clauses** — every `handle_call`/`handle_cast` head matches an
   `:ezagent_*` message (`server.ex:636-779`; there is NO catch-all call/cast
   clause, so a non-protocol `call`/`cast` is a no-clause crash — a kill-the-Kind
   DoS, not a mutation), and the named `handle_info` clauses likewise.
2. **The catch-all `handle_info`** (`server.ex:993-1005`): ANY unmatched mailbox
   message — ANY shape, no verb required — is forwarded to EVERY Behavior in the
   instance's materialized set via `forward_to_behavior`, **inside the open
   authority compartment** (`Cap.Authority.with_current`, `server.ex:1001`), where
   `Lifecycle.__run_signal__/4` hands it to `handle_signal/2` (`lifecycle.ex:541`)
   and runs the FULL mutating effect pipeline (State → Saga → Dispatches → Notifies
   → Events → Terminations — `apply_signal_effects`, same buckets as the action
   path), then persists the mutation (`persist_handle_info_mutation`,
   `server.ex:1030`). Live example: `send(kind_pid, {:pty_phase, uri, :dead, meta})`
   durably mutates the Sandbox slice (`behavior/sandbox.ex:517` —
   `{:set, :pty_phase, phase}` is snapshot-persisted state) — **no `:ezagent_*` atom
   anywhere**, invisible to every verb matcher.

**Consequence — the use-side gate is receiver-based, not shape-based:** V5 bans
**ALL `send/2` / `Kernel.send` / `Process.send/3` / `GenServer.call` /
`GenServer.cast` to a Kind pid, ANY message shape, outside the framework.**
Mechanics: **receiver-provenance taint** — a pid-typed value whose origin traces to
a framework source (a sanctioned-API pid return during the migration window, a
`KindRegistry`/enumeration escape, a relayed handler-`self()`) taints as a
Kind-receiver, and any send/call/cast whose RECEIVER is Kind-tainted REDs regardless
of the message. The existing verb-shape + `:sys` bans (`scanner.ex:119-163`) REMAIN
as the backstop for receivers taint cannot see. This ban is feasible precisely
because the legitimate arbitrary-shape ingress does not need the pid: `{:pty_phase,…}`
reaches the Kind via a **PubSub subscription the Kind itself takes out**
(`sandbox.ex:509-515` — "the subscription delivering the message is the transient";
the sidecar broadcasts to a topic and never holds the Kind pid), and monitor `:DOWN`
/ `send_after` ticks are runtime-generated — so business
code has no legitimate raw-send to a Kind pid at all, and a sidecar needing a new
signal channel uses PubSub or a sanctioned `EzAgentActor.signal(uri, msg)` wrapper
(URI-addressed, framework-delivered), never a pid. A cheap runtime diagnostic
completes it: telemetry on catch-all messages that NO in-set behavior claims
(all-`:ignore` fan-out) — unexpected-signal shapes become observable, V6-class
observability, not enforcement. The verb-list sync self-test survives with a
narrower, honest job: keeping the taint DISCRIMINATOR in sync for the
protocol-shape backstop, no longer carrying a (false) totality claim.

**The irreducible residual — handler-`self()`, restated honestly (R2).** A Behavior
handler executes INSIDE the target's own actor process and holds its own pid by
construction; no design closes this — the handler IS the actor. The v2 claim
"smuggled pids are caught at the eventual useful USE site" was only true under a
verb-total protocol, which `handle_signal` breaks; it is restored ONLY by the
all-shapes receiver ban above, and only to this extent: a smuggled pid whose flow
the receiver-taint can follow (bindings, returns, params — the same fixpoint
machinery as message taint) REDs at its send site whatever the message; a pid
**laundered through data** (stashed in a slice/ETS/message and re-materialized where
static provenance is gone) is NOT catchable statically and lands in §1.5's
deliberate-evasion residual — named, not claimed closed.

**Known costs (obtain-side migration, V5):** callers pattern-matching pids out of the
four ops (mechanical — nearly all use the pid as a truthy "it started" witness);
pid-grabbing tests (`Ezagent.ActorCase` grows sanctioned helpers — extraction §6.6);
operator/debug tooling relocation. **OPTIONAL / DEFERRED — D1 (Path B tier):**
enumeration-shape bans (supervisor introspection of `Ezagent.KindSupervisor` +
per-Kind supervisors, `Process.whereis` on framework names, direct `Registry.*` with
the registry atom) — obtain-side side-channels that matter only against code willing
to fish; documented, not scoped into the V-phases. Even with everything above,
honestly: Registry cannot be unnamed (fact 1.1-3), atoms are global, `Process.list/0`
exists, and handler-`self()` remains — layer C narrows structurally; it never seals.
Sealing is Path B's cryptographic boundary, not a BEAM-structural property.

### 1.5 The honest conclusion (the mechanism = the three layers TOGETHER; the guarantee = a reviewed-code drift guarantee)

**What this design gives is an ENUMERATED, REVIEWED-CODE DRIFT GUARANTEE — not
cryptographic unforgeability.** The v1 draft of this spec over-claimed ("bypass
requires editing `ezagent_actor` or a RED shape"); codex R1 falsified that claim
concretely: `Kind.spawn/3` and `LocalRuntime.ensure_started[/_detailed]` handed a pid
to any caller through the SANCTIONED surface, handler code always holds `self()`
(§1.4), and dynamic `apply/3` is statically undecidable (§1.2). The owner's final
scope: the guarantee target is **"unconcealable in reviewed code"** — and layer C
closes BOTH structural halves toward it (§1.4): no sanctioned actor API returns or
accepts a pid (obtain-side, enforced by the no-pid-return gate), and every useful
message to a Kind pid is a RED shape (use-side, the protocol-verb ban). The claim,
stated at exactly the strength the layers deliver:

> After convergence, a violation of "everything goes through `EzAgentActor`" that is
> written in ORDINARY, reviewed code — the accidental reach-in, the copy-pasted
> shortcut, the review-missed convenience path; i.e. the entire drift class that
> actually occurs (extraction §4.4 census: 255 real sites at C0-freeze, all of this class) —
> is caught mechanically: as a compile error (layer B, upward), or a RED CI shape at
> the point of OBTAINING a pid (layer C's no-pid gate — no sanctioned door yields or
> accepts one) or at the point of USING one (the all-shapes receiver ban — ANY
> `send`/`call`/`cast` to a Kind-provenance pid is RED whatever the message, because
> `Kind.Server`'s catch-all `handle_signal` fan-out accepts arbitrary shapes, §1.4;
> the protocol-verb bans remain as the backstop for receivers taint cannot see).
> What remains is **deliberately-constructed evasion** (runtime-assembled `apply/3`
> with runtime-assembled receivers and messages, a pid laundered through data so its
> provenance is statically invisible, forged telemetry), which no static or
> structural mechanism in one unsandboxed BEAM can catch — that is Path B's
> cryptographic boundary, explicitly out of scope here.

This is EXACTLY the enforceability posture the cap-signing spec already commits to for
the write plane, and this spec aligns with it rather than out-promising it: "**Under
Path A, even the STATIC gates are review aids** — they catch accidental and
review-missed violations (threats ① and ②), not a determined actor running unreviewed
code in-BEAM" (`2026-07-16-cap-signing-per-kind-authority-design.md:156`, §10
preamble), and its "**Honest enforceability limit (v5 / Path A)**" paragraph (`:179`)
is the model for this section.

No single layer delivers even this. Layer A alone is a heuristic with a known evasion
tail; layer B alone cannot make modules private downward (language fact); layer C
alone cannot make pids secret in one BEAM (platform fact) and never covers the
handler's own pid. Together they close each other's ACCIDENTAL-use gaps: **A** catches
what occurs and what is casually added; **B** makes the boundary physical, the
internal set derivable, and upward leakage a compile error; **C** closes both pid
seams — no sanctioned door yields or accepts a pid (the no-pid gate), and possession
of one buys nothing expressible in ordinary code, because ANY message to a
Kind-provenance receiver is a RED shape (the all-shapes receiver ban — not merely
protocol verbs, §1.4). The signing analogy therefore lands one notch weaker than Allen's
ideal, and honestly so: admin-signing makes forgery impossible without the key; this
mechanism makes drift **unconcealable in reviewed code** — every bypass expressible
in ordinary Elixir is either impossible to write against the public surface or RED in
the diff that introduces it. For the actual X — a dev-time EVOLVABILITY problem where
the enemy is the casual bypass that rots into legacy (read-plane spec §0), under a
threat model that already scopes out in-VM malice — that is the correct target
strength, and anything stronger is Path B work (D1 documents the first step of that
road without scoping it in).

One runtime addition rounds out the picture — with its role stated precisely: the
**verifier-dominance telemetry check** from the cap-signing gate plan (§10 property 1
— "no handler-run event without a matching authz event"). It is a **diagnostic**, not
enforcement and not bypass-detection: both events are emitted by the framework's own
pipeline, so a bypass that never enters the pipeline emits neither and is invisible
to it, and in-VM code could emit forged events. What it IS good for: a
uniquely-correlated ordering assertion (`(instance, action, dispatch-id)`-keyed)
that observably proves the wiring — every pipeline-executed handler was preceded by
its own step-5.5 decision — and catches ACCIDENTAL drift inside the pipeline (a new
dispatch route that skips the verifier, a reordering regression). It lands in §4-V6
as observability, priced accordingly.

---

## 2. The bypass census — every current way around the chokepoint, each with a close-plan + its gate

The extraction spec’s ledger IS the base census: **208 frozen forward reach-in sites**
(`actor_internals_boundary_test.exs:46` holds the post-C3 frozen 208; C1 took 261→255, C2 255→244, C3 244→208), broken down
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

| Bypass class | Census (extraction §4.4, @`62f606b8f`, ledger-frozen 208 @`e7a153a92`) | Close plan | Gate |
|---|---|---|---|
| `Kind.get_slice`/`SliceAccess` reach-ins | 53 lib files / 16 apps | C6 per-domain batches → `read/3`; C7 deletes the public symbol | forward scanner root+call bans, SITE-multiset ratchet |
| `SnapshotStore` direct reads | 18 non-framework lib files | C2 (done: 8 callers, ledger 255→244) + C6 tail → `read_durable*` | same |
| `KindRegistry.lookup/list_all` | ~20 production sites | C3 → `alive?/self?/read/list_instances` (+ explicit `await_incarnation/2` if the need survives) | same + §1.4 enumeration-shape bans |
| direct `GenServer.call(pid, :ezagent_*)` | spine seed: `cap.ex:116-118` (`action_context/3` → `resolve_action_subject/2`) | C3 | Kind-message-verb taint (interprocedural) |
| direct `Repo`/Ecto on read planes | read-plane spec census (message plane closed by PR-1..5) | V3 extends the module-keyed raw-store ban to remaining stores | `message_read_chokepoint_boundary_test` model |
| process-generation ambient read | `cap/authorize.ex:86-97` (`autonomous_current?`) | C4 (spine PR, five transition tests, three hard preconditions — extraction §5-C4) | fixed-allowlist rule (post-C4 = exactly 2 fence consumers) |

### 2.4 NEW bypasses this spec names (found in this investigation; not in either parent spec)

1. **The sanctioned surface hands out AND accepts pids** — six ops (returns census
   completed at codex R1; inputs census completed at codex R2): `Kind.spawn/3`
   returns `{:ok, pid}` / idempotent `{:error, {:already_started, pid}}`
   (`kind.ex:379-383`); `LocalRuntime.ensure_started/2` + `ensure_started_detailed/2`
   return pid forms (`local_runtime.ex:62`, `:72-73`); `list_instances/0` meta
   carries `%{pid: pid}` (`kind.ex:845-851`); `resolve_action_subject/2` accepts a
   pid receiver (`kind.ex:809`); `runtime_view/1` accepts a pid receiver
   (`kind.ex:857-859` — retires entirely to actor-internal per extraction §2.3);
   `monitored_by?/2` takes two pids (`kind.ex:877-884`; live domain consumer
   `session/members.ex:45`). Close (V5, owner-decided — cheap and wanted): the pid
   never crosses the boundary in either direction — URI-keyed returns
   (`:ok | {:ok, :started | :already_started} | {:error, _}`; spawn still calls
   `DynamicSupervisor.start_child/2` internally and already awaits ready, so no
   caller needs the pid to sequence on), pid-free `list_instances` meta, URI-only
   `resolve_action_subject`, `runtime_view` retirement, URI-keyed
   `monitored_by?` replacement (+ members.ex migration); operator tooling that
   genuinely needs process identity becomes an `ezagent_actor`-internal mix task /
   operator-gated op. Gate: the **no-pid gate** (§1.4) — a pid in any sanctioned
   actor-API return or parameter is a RED shape, enforced, not conventional.
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
4. **`resolve_action_subject/2` pid overload** (`kind.ex:809`) — folded into item 1's
   V5 closure (URI-only public form; the pid overload goes `@doc false` internal).

---

## 3. The caps-resolution contract — identity in, caps resolved fresh at the chokepoint

**The hard rule (Allen's sketch, corrected as specified):** the fourth parameter of
`EzAgentActor.call/4` is the caller's **IDENTITY** — an authenticated principal
`%URI{}`, and ONLY that — **NEVER a caps list, and NO public `:vm_internal` option.**
Framework/trusted-internal dispatches do not enter through the public primitive at
all: they use framework-tier internal constructors (the enumerated facades — identity
persistence's `EntityCaps.dispatch_mutation`-class paths), so `:vm_internal` never
appears in a business-tier call signature and cannot be reached for by convenience.
Caps are resolved FRESH at the chokepoint, at decision time, from the durable/live cap
store — **through the extracted authorization port** (post-C5 the chokepoint lives in
`ezagent_actor`, which cannot and must not call the identity domain directly; the
AuthzPort / `authority_loader` DI seam, extraction §3.4, already carries exactly this
inversion, with the core adapter resolving via `EntityCaps.load/1`). A caller-passed
cap list is the stale/forged-cap vector, and this repo has already paid for it twice:

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

**The convergence (V2) — ONE adapter-owned authorization op:**

1. `EzAgentActor.call/4` has **no caps parameter and no ephemeral parameter**. The
   chokepoint performs a SINGLE authorization operation behind the authz port: load
   the caller's authority snapshot ONCE (port → core adapter → `EntityCaps.load/1`),
   and within that one op run #195's principal-fence, the current-holder gate, and the
   per-candidate target-verify together (`Cap.Authorize.authorize/3` already composes
   exactly these three — `cap/authorize.ex:46-63`; V2 changes where the CANDIDATES
   come from, not the decision logic).
2. `ctx.caps` becomes an **internal envelope field** written only inside
   `ezagent_actor`. The three enumerated exceptions are all chokepoint-side or
   provenance-enforced — never a caller-supplied value crossing the public API:
   (a) **admin materialization** — minted inside `dispatch/1` after the origin check
   (`invocation.ex:181-209`), target-signed, verified like any cap;
   (b) **JIT ephemeral authority — provenance-enforced through a FIXED policy
   adapter, not a caller wrapper.** The current shape is not good enough to keep:
   `PresenterCaps.load_with_ephemeral/2` (`presenter_caps.ex:26-73`) accepts an
   `%EphemeralCaps{}` that ANY caller can construct around ANY `%Capability{}` — the
   tag proves intent, not provenance, so it reintroduces exactly the
   store-removed-inline-cap class V2 eliminates (a stale artifact wrapped in the tag
   rides in). V2 shape: a small FIXED registry of ephemeral-policy adapters (module
   allowlist — today's sole member: the kanban published-read adapter), each of which
   MINTS its authority inside the chokepoint's call path (via `Cap.issue/3`-class
   issuance at decision time) keyed by the request; the chokepoint unions ONLY
   adapter-minted-this-decision authority, and no public parameter can carry a
   capability value at all. The `%EphemeralCaps{}` public wrapper is deleted;
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
   contract applies verbatim); one port-mediated authority load per dispatch (the same
   cost class the C2 batch path already accepted; per-URI actors make per-dispatch
   load O(1) in candidates, and batch planes hoist it exactly as
   `read_credential_statuses/3` does).

**Gate:** scanner rule — a `:caps` key written into a Cmd/Invocation ctx outside
`ezagent_actor` is RED, and any `%Capability{}`-typed value crossing the public
`EzAgentActor` surface is RED; the ephemeral-policy adapter registry is a fixed module
allowlist (a new adapter = a reviewed registry diff, never a new call-site wrapper).
Census-seeded, shrink-only (the census is small: post-C1, `PresenterCaps.context/1`
consumers + CLI dispatch + the kanban published-read adapter).

---

## 4. Sequencing + phasing — each phase = a closable bypass + its enforcing gate

**Hard precondition: the extraction C0–C7.** This spec's phases consume the extraction's
public surface (C0, landed), its consumer migrations (C1–C3, C6), the spine deletion
(C4), the physical move (C5), and the flip (C7). Status at `e7a153a92`: C0 (#1546) +
gate hardening (#1549), C1 (#1548), C2 (#1550 + #1562), **C3 (#1561, ledger 244→208)**
are MERGED; C4–C7 pending. Phase V1 below can begin before C5 (it touches the dispatch
front door, not the file layout); V2 needs the port contract; V4 straddles the move
and states which side owns what; V6 closes only after C7.

| Phase | Closable bypass (§2 ref) | What lands | Enforcing gate | Depends on | Cost |
|---|---|---|---|---|---|
| **V1 — name the primitive; close the envelope front door** | §2.4-2, §2.4-3 | `EzAgentActor.call/4` as the business-tier entry (a thin, semantics-preserving façade over `Cmd.authenticated_external` + `Router.dispatch`; NO public `:vm_internal` — framework facades use internal constructors, §3); ingress-adapter set enumerated; `with_admin_operator` callers enumerated; optional Boundary-style compile tracer (§1.3) | envelope-construction shape ban, census-seeded shrink-only; adapter fixed allowlist | C0 only | M |
| **V2 — caps-resolution convergence** | §3 | ONE adapter-owned authorization op behind the authz port (snapshot loaded once; principal-fence + holder gate + target-verify together); no caps/ephemeral params; ephemeral-policy adapter registry replaces the public `%EphemeralCaps{}` wrapper; TOCTOU + differential tests | `:caps`-write + `%Capability{}`-across-public-surface shape bans; TOCTOU test (store-removed inline cap DENIED); fixed ephemeral-adapter allowlist | V1; **the AuthzPort/authority-loader port contract** — land with C5's port-introduction pre-flight (ports are introduced while files still live in core, extraction §5-C5) or introduce that port first; **coordinate w/ #195 owner** (authz seam) | M–L |
| **V3 — read-plane convergence** | §2.1 | every principal-facing read behind a chokepoint conforming to the identity-in/fresh-caps contract; `Kind.read*` plumbing restricted to {chokepoints, framework tier, in-dispatch handlers}; remaining raw stores under the read-plane §3.3 ban | read-plumbing-callers module allowlist (shrink-only) + raw-store ban extension; enumerator run = worklist | C0–C3 (surface + migrations); benefits from C6 | **L (breadth)** |
| **V4 — cap-exemption structural split + ratchet** | §2.2 | two declaration classes at the ActionSet/Behavior macro layer; `@non_cap_actions` families absorbed one PR at a time; verifier map count → 0. **Ownership across C5, stated:** the declaration-class MECHANICS live in the macro layer (`behavior.ex` — a §3.2 MOVER file), so they land in / move with `ezagent_actor`; the non-cap PREDICATES + the verifier's exemption enumeration are spine POLICY (`Cap.Verifier` stays in core). NOT independent of C5: the macro half either lands before C5 and moves with `behavior.ex`, or after C5 in the actor app — never split mid-move | shrink-only count on the verifier map; class-split structural assertions; cap-signing §10-property-2 flag bans | **C5 (macro-layer ownership)**; predicates/ratchet halves may proceed family-by-family before it; **coordinate w/ #195** | **L** |
| **V5 — pid closure, both sides** | §1.4, §2.4-1, §2.4-4 | **Obtain/input-side**: `Kind.spawn/3` + `LocalRuntime.ensure_started[/_detailed]` stop returning pids (URI-keyed returns; `DynamicSupervisor.start_child/2` stays internal); `list_instances/0` meta drops `:pid`; `resolve_action_subject/2` URI-only; `runtime_view/1` retires to actor-internal (extraction §2.3); `monitored_by?/2` → URI-keyed replacement + `members.ex:45` consumer migration; caller migration (mechanical — pids used as truthy witnesses); the NEW **no-pid gate** (return + parameter types + `is_pid` guards; runtime deep-walk; has-teeth self-test). **Use-side (receiver-based, per the R2 mailbox-authority model)**: the **all-shapes receiver ban** — receiver-provenance taint REDs ANY `send`/`call`/`cast` to a Kind-provenance pid regardless of message shape (the catch-all `handle_signal` fan-out accepts arbitrary shapes — `{:pty_phase,…}` mutates durably with no verb); protocol-verb + `:sys` matchers retained as the backstop, verb-list sync self-test kept for the backstop's discriminator; sanctioned signal ingress documented (PubSub subscription / `EzAgentActor.signal(uri, msg)` — never a pid); optional unexpected-signal telemetry diagnostic. Handler-`self()` + laundered-pid residuals documented in the gate's own doc | no-pid gate green at zero-allowlist; all-shapes receiver ban + backstop shapes at zero-allowlist; verb-sync test green | C3 (landed) for the consumer baseline; C5 (scanner + verb census move with the framework; return-type changes may land either side of the move, never split across it) | M |
| **V6 — runtime dominance diagnostic + closure** | §1.5 | verifier-dominance telemetry check (uniquely-correlated ordering assertion — DIAGNOSTIC observability for accidental in-pipeline drift, not enforcement, §1.5); convergence acceptance run | the diagnostic assertion + all prior gates at zero-allowlist | V1–V5 **and C7** (acceptance cannot claim one-door while `get_slice`/`get_raw_slice` are still on the public surface — they leave it at C7) | S–M |

**The biggest-cost items, flagged as required:** (1) **V3 read-plane convergence** — a
breadth census across every principal-facing reader, even with the message plane
already done; (2) **V4 cap-exemption ratchet** — a macro-layer refactor straddling the
C5 move and adjacent to live #195 spine work, which is why its interim
(enumerate-and-lock) is already in force and the split can proceed family-by-family
without a flag-day; (3) **V2** — an authz-seam change requiring #195-owner
coordination and the port contract. (V5 shrank from the v1 draft's XL to M when the
owner scoped the guarantee to reviewed-code-unconcealable: the pid-return elimination
is retained — it is cheap, mechanical, and gate-enforced — while the expensive
remainder of full physical encapsulation, the enumeration-ban package, moved to the
optional D1 deferral.)

**Rollback discipline** (inherited from the extraction): every phase's gate allowlist
travels in the same commit as its migration; reverting a phase = reverting its PR.

---

## 5. Acceptance

1. **One door, write plane:** `EzAgentActor.call/4` is the only business-tier dispatch
   entry — envelope-construction census at `[]`; ingress adapters enumerated and fixed.
2. **Identity-in, caps-fresh, no public `:vm_internal`:** the public call surface
   takes an authenticated principal URI only — no caps parameter, no ephemeral
   parameter, no `:vm_internal` option; fresh resolution runs behind the authz port;
   `:caps`-write census at `[]` outside the chokepoint; ephemeral authority only via
   the fixed policy-adapter registry (no public `%Capability{}` carrier exists); the
   TOCTOU test proves a store-removed inline cap no longer authorizes a dispatch.
3. **One discipline, read plane:** `Kind.read*` plumbing callable only from
   {chokepoints, framework tier, in-dispatch handlers} — allowlist at `[]`; every read
   chokepoint takes identity, resolves fresh.
4. **Exemptions governed:** verifier `@non_cap_actions` map deleted (members absorbed
   into the structural non-cap class, each with a named predicate); cap-gated-AND-exempt
   unrepresentable.
5. **Pid closed on both sides:** no sanctioned `ezagent_actor` API accepts or returns
   a pid — the no-pid gate (return + parameter types + `is_pid` guards, runtime
   deep-walk, has-teeth self-test) is green at zero-allowlist, including the R2
   input census (`runtime_view/1` retired; `monitored_by?/2` URI-keyed with the
   `members.ex:45` consumer migrated); the **all-shapes receiver ban** is green at
   zero-allowlist (ANY message to a Kind-provenance receiver REDs — verified by a
   fixture that sends a NON-verb mutating signal shape, the `{:pty_phase,…}` class,
   and is caught), with the protocol-verb + `:sys` backstop and its verb-sync test
   green; the handler-`self()` and laundered-pid residuals are documented in the
   gate's own doc (named residuals, not claimed closed).
6. **Runtime dominance observed (diagnostic):** the uniquely-correlated telemetry
   assertion holds across the full suite — every pipeline-executed handler paired
   with its own step-5.5 decision (observability for accidental in-pipeline drift;
   not claimed as bypass detection).
7. **Zero regression:** full umbrella green on every phase against the pre-phase
   baseline (the standing rule); the extraction's acceptance (its §7, including C7's
   removal of `get_slice`/`get_raw_slice` from the public surface) green before V6
   closes.

---

## Appendix A — evidence index (all `origin/main` @ `e7a153a92`)

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
- Pid-returning surfaces closed at V5 (§1.4 obtain-side): `Kind.spawn/3` returns
  `DynamicSupervisor.on_start_child()` `kind.ex:379-383` (idempotent
  `{:already_started, pid}` callers noted in its own doc, `kind.ex:365-369`);
  `LocalRuntime.ensure_started/2` `apps/ezagent_core/lib/ezagent/local_runtime.ex:62`,
  `ensure_started_detailed/2` `local_runtime.ex:72-73`; plus the two `kind.ex` leaks
  above
- Pid-INPUT surfaces (R2 census, §1.4): `Kind.runtime_view/1` pid form
  `kind.ex:857-859` (retires per extraction §2.3); `Kind.monitored_by?/2`
  `kind.ex:877-884` (`Process.info(pid, :monitored_by)`); domain consumer
  `apps/ezagent_domain_session/lib/ezagent/behavior/session/members.ex:45`
  (`self_monitors?/1` inside the rejoin pre-check `monitor_ref_for_current_pid?/3`,
  `members.ex:34-46`)
- Mailbox-authority model (§1.4 use-side — why verb-shape bans are not total):
  catch-all `handle_info` forwards ANY unmatched shape to every in-set Behavior
  `kind/server.ex:993-1005` (fan-out under the OPEN authority compartment —
  `Cap.Authority.with_current` at `server.ex:1001`; mutation persisted via
  `persist_handle_info_mutation`, `server.ex:1030`); `Lifecycle.__run_signal__/4` →
  `module.handle_signal(message, ctx)` `lifecycle.ex:534-541` (call at `:541`) →
  FULL effect pipeline `apply_signal_effects` (same buckets as the action path,
  comment `lifecycle.ex:545-560`); live no-verb durable mutation:
  `behavior/sandbox.ex:517` (`handle_signal({:pty_phase, …})` →
  `{:set, :pty_phase, phase}`, snapshot-persisted); legit ingress is
  subscription-based, never pid-based: `sandbox.ex:509-515` ("the subscription
  delivering the message is the transient"); no catch-all `handle_call`/`handle_cast`
  exists (`server.ex:636-779` — all heads match `:ezagent_*`)
- Boundary gate SSOT: `apps/ezagent_core/lib/ezagent/actor_boundary_scanner.ex`
  (banned roots `:88-108`; kind-message verbs `:125-163`; taint fixpoint `:407-463`;
  reflective `:sys` `:316-378`); ledger frozen counts
  `apps/ezagent_core/test/invariants/actor_internals_boundary_test.exs:46-49`
  (`@forward_frozen 208` post-C3, `@reverse_frozen 123`); tracked evasion tail
  `docs/futures/todo.md` (2026-07-24 hardening section)
- Honest-enforceability alignment (§1.5): cap-signing spec
  `2026-07-16-cap-signing-per-kind-authority-design.md:156` (§10 preamble — "Under
  Path A, even the STATIC gates are review aids") and `:179` ("Honest enforceability
  limit (v5 / Path A)")
- C1 fresh-caps fix: `apps/ezagent_plugin_world/lib/ezagent/world/presenter_caps.ex:1-80`
  (fresh `EntityCaps.load`); the caller-constructible `%EphemeralCaps{}` wrapper +
  `load_with_ephemeral/2` this spec RETIRES at V2 (§3 exception b):
  `presenter_caps.ex:26-73`
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
