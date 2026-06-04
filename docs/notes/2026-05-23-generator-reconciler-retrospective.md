# Generator → Reconciler retrospective — *what we learned: wrong abstraction*

> **Date**: 2026-05-23. Author: Claude, per Allen Feishu 2026-05-23.
> **Companion docs**:
> - SPEC: `docs/superpowers/specs/2026-05-23-generator-reconciler.md`
> - PR-A (#259, commit `350e9c3`) — Session.spawn_from_template/2 reconciler
> - PR-C (#260, commit `526c401`) — update_agent_template / add / remove reconciler
> - Superseded design: `docs/superpowers/specs/2026-05-22-phase-7-completion.md`
>   §"Spawn phase" + §1.6/§1.6a (cleanup_partial saga)
> - Audit that triggered it all:
>   `docs/notes/phase-7-implementation-audit-2026-05-22.md`

This is the post-mortem of **how the Phase-7-completion Generator
shipped with a saga-cleanup model, took 10 rounds of codex adversarial
hardening that never converged to 0 HIGH findings, and was ultimately
dissolved by a reconciler refactor that deleted ~800 LOC.** Honest tone
— *the codex iteration was valuable; the lesson is the abstraction
choice, not the engineering*. Numbered lessons at the bottom for
future devs.

---

## §1 The pattern — atomic-saga semantics, enumerated cleanup

Phase-7-completion PR-4 (the Generator —
`Session.spawn_from_template/2`) and PR-5 (the Orchestrator's tools —
`Ezagent.Orchestrator.Tools.update_agent_template` /
`add_agent_slot` / `remove_agent_slot`) shipped with this shape:

```elixir
defp do_spawn(template_uri, owner_uri, opts, ctx) do
  with {:ok, x1} <- step1(...) |> guard(:step1, ctx),
       {:ok, x2} <- step2(x1, ...) |> guard(:step2, ctx),
       {:ok, x3} <- step3(x2, ...) |> guard(:step3, ctx),
       ... (8 steps total) ...
       {:ok, xN} <- stepN(...) |> guard(:stepN, ctx) do
    {:ok, session_uri}
  end
end

defp guard({:error, reason}, step, ctx) do
  cleanup_partial(ctx)  # enumerate the N stores we touched, tear each down
  {:error, {step, reason}}
end
defp guard(ok, _step, _ctx), do: ok
```

`cleanup_partial/1` had to **know about every side-effect store the
Generator had touched so far** and reverse each:

- live `KindRegistry` pids — `Ezagent.SpawnRegistry.terminate`
- `WorkspaceRegistry` bindings — `WorkspaceRegistry.unbind`
- `AgentLineage` rows — `AgentLineage.forget`
- committed `routing_rules` rows — `RuleStore.delete_by_id` (with
  a thread-through `routing_rule_ids` accumulator)
- (for `update_agent_template`) the Session-Kind `template_working_copy`
  slot tuple
- (for `add_agent_slot`) the spawned worker Agent + its sidecar

The intent: **make the multi-step Generator operation look atomic** —
any failure rolls back all earlier side effects, leaving the system in
the pre-call state.

---

## §2 The trajectory — 10 rounds of hardening, HIGH count stuck at 1-2

After the Phase-7-completion 6-PR effort (#231..#237) landed, codex
adversarial-review was run repeatedly against the saga model. Each
round dropped severity in places, but **the HIGH count never reached
0**:

| Round | PR | Severity | What the round fixed |
|---|---|---|---|
| 1 | #239 | 1 CRITICAL + 3 HIGH | Generator / orchestrator tool initial hardening — first audit found CapBAC + the saga both leaked |
| 2 | #241 | ~2 HIGH | round-2 fixes — cap delegation TOCTOU + persistence race |
| 3 | #243 | ~2 HIGH | round-3 — orchestrator adoption + AgentLineage classification edges |
| 4 | #244 | 1 HIGH | round-4 — routing operations made transactional (per-step `Repo.transaction`) |
| 5 | #245 | 1 HIGH | round-5 — `update_agent_template` recovery fail-safe wrapper |
| 6 | #246 | 2 HIGH | round-6 — last `update_agent_template` failure-path gaps |
| 7 | #247 | 2 HIGH | round-7 — only record lineage/binding for freshly-created workers (`fresh?` gating introduced) |
| 8 | #248 | 2 HIGH | round-8 — no sidecar / no Generator adoption for non-fresh workers |
| 9 | #249 | 1 HIGH | round-9 — Loader `fresh?`-gating + Generator multi-slot cleanup |
| 10 | #250 | 2 HIGH | round-10 — close two Generator failure-exit orphan leaks; spawner-cleans-its-own-partial-spawn |

**The pattern**: every round fixed *N* stores' cleanup paths, and codex
came back with *N* adjacent missed-store / TOCTOU / partial-recovery
edges:

- Round 7 introduced `fresh?` gating because `Agent.spawn/4` maps
  `{:already_started, _}` → `{:ok, pid}` and **unconditionally binds
  workspace + records lineage** — when the existing pid is a foreign
  lineage, this re-parents it. Cleanup added: only bind / record for
  freshly-spawned.
- Round 8 found the symmetric bug on the orchestrator side — non-fresh
  workers were still getting sidecars launched. Cleanup added: gate
  sidecar launch on `fresh?` too.
- Round 9 found the Loader had the same shape — workspace template
  load_one was binding non-fresh members. Cleanup added: Loader
  `fresh?`-gating.
- Round 10 found two more orphan-leak exits in Generator's multi-slot
  paths.

The findings were **adjacent**, not redundant. Each round was a real
bug. But the convergence rate stayed flat — there was always one more
store, one more TOCTOU window, one more failure path.

---

## §3 The diagnosis — why enumeration is combinatorially fragile

A multi-step Generator operation that touches `N` independent stores
(`KindRegistry`, `WorkspaceRegistry`, `AgentLineage`, `routing_rules`,
the working-copy slot tuple, the spawned worker PtyServer sidecar, the
Identity caps table, …) **cannot be made transactional by enumerating
the stores in a `cleanup_partial`**. The reasons compound:

1. **N grows.** Each new Kind type / registry / persistence side-channel
   adds a store the cleanup must learn to roll back. The enumeration is
   unbounded — every audit pass finds "one more store."

2. **N×K failure paths.** With `N` stores and `K` steps in the saga,
   there are `N×K` (step-X-fails-after-stores-1..X-1-touched) failure
   paths. Each needs the correct prefix of cleanup. Codex finds the
   ones with un-covered prefixes.

3. **TOCTOU between gate-check and side-effect.** When the gate ("is
   this URI already owned?") and the side-effect ("spawn / bind /
   record") are not in the same atomic transaction, a foreign process
   can claim the URI in between. The saga can't compensate for state
   it didn't cause.

4. **Asymmetric primitives.** `Agent.spawn/4` returning
   `{:ok, pid}` whether it spawned fresh or adopted an existing pid is
   convenient for callers but **catastrophic for a saga's cleanup**
   — the saga commits a "I spawned X" tombstone, then `cleanup_partial`
   terminates a process it didn't create.

5. **Cleanup itself can fail.** Tearing down a partially-committed
   `routing_rules` row inside a `cleanup_partial` is another DB call
   that can race or fail — and the saga has nowhere to compensate
   that compensation.

6. **Residue from one failed run blocks the next.** If `cleanup_partial`
   misses a store on call N, call N+1 sees the residue and either
   adopts it (wrong: re-parenting foreign work) or fails (wrong: legit
   re-run can't make progress).

The fundamental problem: **a saga's correctness is an N-store
exhaustivity proof.** Every audit finds the next N+1. The number of
failure paths is combinatorial in the number of side-effecting steps,
and each new Kind that the system gains adds one more.

---

## §4 The right abstraction — converge-to-spec

Allen 2026-05-22:

> *"Generator 现在'原子多步 + 失败回滚'的模型是错的抽象 — 正确的是
> 声明式 SessionTemplate + reconciler(`spawn_from_template/2` 变成
> `docker-compose up`-style 收敛到 spec 的命令;残留状态是预期的;
> 再跑一次从失败点继续)."*

**The reframe**:

- A `SessionTemplate` is a **declarative desired-state spec** — the
  set of agent slots, routing rules, orchestrator, caps, working copy
  the session SHOULD have.
- The Generator's job is **`converge(spec, current_state)`** —
  docker-compose `up` semantics:
  - already-converged components are **detected and skipped**;
  - missing components are **spawned forward**;
  - mis-configured routing rules are **corrected forward**;
  - partial residue from a previous failed run is the **expected
    intermediate state**, not corruption;
  - re-running the Generator with the same
    `(SessionTemplate URI, owner URI)` pair **continues from the
    partial state** to the same desired end state.
- Each per-Kind operation is **already independently atomic** at the
  primitive level: `SpawnRegistry.spawn` is one
  `DynamicSupervisor.start_child`; `RuleStore.add` is one SQL insert
  in one `Repo.transaction`; `WorkspaceRegistry.bind` is one ETS
  upsert. The reconciler composes these primitives behind per-step
  idempotency probes — *spawn-if-missing*, *bind-if-unbound*,
  *insert-if-not-present-with-same-shape*.
- The Generator is therefore a **SCRIPT, not a transaction**. Saga
  rollback is the wrong primitive — the right primitive is
  **idempotent forward progress**.

The precedent was already in the codebase:
`Ezagent.Workspace.Loader.load_one/1` + `invoke_template/2` already
work this way for workspace templates — load all members, re-spawn
missing, `{:already_started, _}` → no-op,
`fresh?`-gated bind, errors logged not raised, re-run continues. The
Loader is the Generator's older sibling. **The Generator should have
been the same shape from the start.**

---

## §5 The fix — PR-A and PR-C

### PR-A (#259, commit `350e9c3`) — Session.spawn_from_template/2 as reconciler

- `do_spawn/4` (the 8-step `with` chain wrapped in `guard/2`) →
  `reconcile/2` — a sequence of per-step idempotency-probed calls.
- `cleanup_partial/1` → **deleted** (~400 LOC across `session.ex` paths
  for `spawn_from_template` and its `add_agent_slot` invocation).
- Four new per-Kind idempotency helpers:
  - `Agent.spawn_fresh/4` — reports `:fresh | :already_started`
    WITHOUT side-effects on already_started (lets the reconciler
    decide whether to bind / record lineage).
  - `WorkspaceRegistry.bind_if_fresh/2` — bind only when the binding
    is absent or matches.
  - `AgentLineage.record_if_fresh/3` — record only on `:fresh`.
  - `RuleStore.upsert_by_logical_key/5` — insert-if-missing using a
    normalized matcher + scope tuple as logical key.
- Working-copy merge: `populate_working_copy/5` became a MERGE (not a
  replace), and the merge re-validates every slot at merge time
  (ownership re-check covers in-pass and prior-pass).
- The orchestrator adoption gate splits ABSENT-evidence from
  POSITIVE-foreign-evidence (per the SPEC's rev-4 fix to round-7's
  classification) — absent retries with bounded delay; positive
  returns `:foreign` cleanly.

### PR-C (#260, commit `526c401`) — orchestrator tools as reconciler

- `update_agent_template`, `add_agent_slot`, `remove_agent_slot` —
  rewritten to call the new reconciler instead of their own per-tool
  saga.
- ~6 saga compensation helpers in
  `apps/ezagent_domain_instance_message/lib/ezagent/orchestrator/tools.ex`
  **deleted** (rollback_template_slot, restore_prior_working_copy,
  cleanup_routing_changes, the per-tool `guard` wrappers, …).
- Cap idempotency probe uses **logical equality** (ignores
  `granted_at`) — `grant_cap_if_absent` is the reconciler's cap helper.
- Routing rule idempotency requires `enabled == true` AND normalized
  matcher equality (rev-2 fix from SPEC §2 step 4).

Combined LOC delta: **~800 LOC removed** across `session.ex` +
`orchestrator/tools.ex`; net additions are the four
per-Kind idempotency primitives (~80 LOC). The codebase is
**measurably smaller** after the refactor.

---

## §6 What this validates — design principles

The reconciler dissolution is a **case study for two of the
`ezagent-developer` SKILL's design principles** (using the SKILL's
authoritative numbering P1-P26):

### P2 "let-it-crash; no workarounds, no defaults, no whitelists"

The saga model was, structurally, a **workaround** — it tried to
absorb the N-store enumeration problem inside the Generator with
defaults ("if X failed at step 7, default to tearing down stores
1..6"). Each codex round added more defaults: `fresh?` gating
defaults, "if non-fresh skip sidecar" defaults, "if Loader sees
existing member skip bind" defaults. Each default was correct in
isolation. The accumulation was the antipattern.

The reconciler is the **structural fix** — it deletes the entire
saga surface area (the `guard`/`cleanup_partial` machinery) and
replaces it with idempotent per-step primitives. There's nothing to
default against — re-run converges or returns a typed partial state.

### P3 "single source of truth for any datum"

The saga had `cleanup_partial` enumerating stores as **a separate
record** of "what the Generator just did" (a thread-through
accumulator). That accumulator was a second source of truth alongside
the actual store state — divergence between them was the bug class
codex kept finding.

The reconciler **dissolves the accumulator**: the SessionTemplate is
THE source of truth for what should exist; the live state is THE
source of truth for what does exist; the reconciler is the function
`converge(spec, current)`. There is no separate "what I just did"
record to drift.

### Plugin/Kind contract — `Workspace.Loader` is the precedent

`Ezagent.Workspace.Loader` had been this pattern since workspace
templates were introduced. **It is the precedent reconciler in the
codebase** — already `:already_started`-safe, already `fresh?`-gated,
already idempotent on re-run. The Generator should have been modelled
on the Loader from the start. The SKILL's
**§"How-to: add a Template Class"** now references the Loader as the
canonical reconciler pattern; new Template Classes that spawn
multi-Kind state SHOULD follow this shape.

---

## §7 What's KEPT from the hardening rounds

The 10 codex rounds were **not wasted**. The reconciler keeps several
load-bearing things that were introduced during hardening:

- **CapBAC + workspace-isolation fixes from rounds 1-3** — these are
  *real security* (cross-workspace cap leakage, identity-grant
  authority preflight, TOCTOU on cap delegation). They're orthogonal
  to the saga/atomicity question — the reconciler relies on them.
- **`fresh?` gating from round 7+** — the reconciler is *built on* the
  `Agent.spawn_fresh/4` primitive that round 7 motivated. The bug
  ("non-fresh adoption mis-binds workspace + lineage") is real; the
  fix ("only bind / record on `:fresh`") is correct; the reconciler
  uses it everywhere.
- **Round 8's "no sidecar for non-fresh workers"** — same shape, same
  primitive, kept verbatim.
- **Round 10's "spawner cleans its own partial spawn"** — the
  Generator's per-step still cleans up the *immediate* failure of its
  own spawn (an `Agent.spawn_fresh` that returned `{:error, _}` before
  side-effects). This is local, bounded, NOT a multi-step saga. The
  reconciler keeps this.
- **Round 4's `Repo.transaction` around routing operations** — the
  per-step atomic primitive **within** the reconciler. Routing
  operations are still wrapped in a single SQL transaction; the
  reconciler relies on that primitive for routing idempotency.

In other words: the rounds got the **per-primitive correctness** right.
The reconciler keeps those primitives. What it deletes is the
**multi-primitive enumeration** on top of them.

---

## §8 Anti-pattern to remember

**The anti-pattern in three words**: *"we'll just add one more cleanup
step."*

When a multi-step operation fails and you're tempted to add another
entry to a `cleanup_partial` enumeration, **stop and ask**:

> *"Why is cleanup necessary at all? What is the converge-to-spec
> model for this operation?"*

If the operation has a declarative spec (SessionTemplate, Workspace
template, deployment manifest, anything that says "the system should
have X") and idempotent primitives (`spawn-if-missing`, `bind-if-unbound`,
`insert-if-not-present-with-same-key`), then the operation is a
reconciler, not a saga. Write it as a reconciler. Delete the cleanup
enumeration.

If the operation does NOT have a spec to converge to (a one-shot
"deduct from account A, credit to account B" with no
declarative end-state), then a saga *might* be the right primitive
— but use a saga *library* (e.g. `Sage`, `Commanded`) that has
already solved the N-store enumeration formally, don't roll a
hand-written `cleanup_partial`.

---

## §9 Numbered LESSONS for future devs

### LESSON 1 — *A saga over N stores is a proof obligation that grows with N.*

If you're writing `cleanup_partial` and listing the stores you
touched, you are signing up to **maintain that list as the system
grows**. Every new Kind / registry / persistence side-channel adds
one more entry. The audit cost is permanent. **Before writing the
saga, check whether the operation has a declarative spec — if yes,
write a reconciler instead.**

### LESSON 2 — *Idempotency primitives at the Kind level dissolve multi-step sagas at the Generator level.*

`Agent.spawn_fresh/4` (reports `:fresh | :already_started` without
side-effects), `WorkspaceRegistry.bind_if_fresh/2`,
`AgentLineage.record_if_fresh/3`,
`RuleStore.upsert_by_logical_key/5` — these per-Kind idempotency
helpers are what made the reconciler shape possible. When you add a
new Kind that will be touched by multi-step Generators, **ship the
idempotency primitive alongside the Kind**, not as an afterthought
when the Generator needs it.

### LESSON 3 — *Convenience primitives that hide `:already_started` are a saga's enemy.*

`Agent.spawn/4` returning `{:ok, pid}` regardless of fresh-vs-existing
was *convenient* for callers but **the root cause of round-7..10's
non-fresh-adoption bugs**. The reconciler needs to know
`fresh | already_started` to make the right downstream decision (bind?
record lineage? launch sidecar?). When you write a "spawn" primitive,
prefer the version that surfaces the distinction; callers that don't
care can pattern-match `_ -> :ok`.

### LESSON 4 — *Look for the precedent reconciler in your codebase before designing a new saga.*

`Ezagent.Workspace.Loader` was already a reconciler when the Generator
was designed as a saga. Nobody noticed the asymmetry until 10 codex
rounds later. **When designing a new multi-Kind orchestration, grep
for other things in the codebase that orchestrate multi-Kind state.
If they're reconcilers and you're about to write a saga, the
asymmetry is probably a bug in your design.**

### LESSON 5 — *Adversarial-review convergence rate is a signal about abstraction, not engineering.*

If 10 rounds of code review keep finding 1-2 HIGH per round and the
severity isn't dropping, **the abstraction is wrong**. Stop the
review loop and ask the architectural question. Codex was correct on
every individual round; the engineering was fine; the *design* was
the bug. (The same signal applies to human review — flat HIGH count
across many rounds means you're not converging.)

---

## §10 Where this doc fits

| Doc | Purpose |
|---|---|
| `docs/superpowers/specs/2026-05-23-generator-reconciler.md` | The SPEC for the refactor (rev 4 — 3 codex reviews) |
| `docs/superpowers/specs/2026-05-22-phase-7-completion.md` | The Phase-7-completion SPEC (rev 5) — atomic-saga sections now annotated SUPERSEDED |
| `docs/notes/phase-7-implementation-audit-2026-05-22.md` | The audit that triggered the 6-PR + 10-round work (now has a 2026-05-23 RESOLUTION header) |
| `docs/notes/phase-7-handoff.md` | The Phase-7 release framing (now reflects reconciler-validated state) |
| **THIS DOC** | The post-mortem — *why* the saga didn't work, *what* the reconciler is, *what* future devs should remember |

PR sequence for the refactor: PR-A (#259) + PR-C (#260) + PR-D (this
doc + supersede annotations + SKILL pointers).

— 2026-05-23, by Claude (Opus 4.7) per Allen Feishu 2026-05-23.
