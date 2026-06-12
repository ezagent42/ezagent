# Socialware Substrate P5 — Collapse to One Session Kind Implementation Plan

> **STATUS: v1 DRAFT (parallel planning) — HIGHEST RISK, may stay DEFERRED.** Spec §6 P5 itself says: *"Highest risk — do last, may stay deferred if E2E risk is high; the substrate value is delivered by P1–P4 even without P5."* P5 *implementation* depends on P1 (instance-set runtime enforcement — MERGED) AND on P2.5c + P3 + P4 being settled (it merges the two Kinds those phases shaped). This plan is codex-reviewed now (Allen's "all P codex" ask) + finalized/rebased against the as-built P1–P4 before any implementation — and may be a CONSCIOUS no-op (stay deferred) if the E2E risk outweighs the value.

> **For agentic workers:** REQUIRED SUB-SKILL once finalized: superpowers:writing-plans → subagent-driven-development. Subagents touching `apps/**/*.ex` MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`.

**Goal:** Merge `Ezagent.Entity.Session` (chat) and `Ezagent.Entity.SocialwareSession` into ONE parameterized session Kind. Chat, page (socialware), and advisor become **Templates** that select a behavior subset over the single Kind. After P5: "a session" is one Kind; "what kind of session" is a Template (a behavior-set + config), not a separate Kind module.

**Why it is SAFE only because of P1 (the load-bearing dependency):** the single Kind registers the UNION of behaviors — **as-built on main after config-evolve (#733): `Chat` + `Publisher.SessionImpl` + `ExternalMirror` + `Turn` + `Surface`** (ConfigUpdate is GONE — it moved to the Agent as `ConfigEvolve`; `SocialwarePublisherRead` is registry/read-API, not in `behaviors/0`). That superset is harmless **only because P1's per-instance behavior-set runtime enforcement denies out-of-set actions per instance** — a chat-template instance has the Chat behaviors in its set and the socialware behaviors OUT, so a `surface.put_version` dispatch to a chat instance is denied by the P1 `instance_set_gate`, exactly as if `Surface` were not on the Kind at all. Without P1, a superset Kind would expose every behavior on every instance (an authz + correctness disaster). With P1 (merged + its denial test), the collapse is behavior-preserving by construction.

**Architecture:**
- A single `Ezagent.Entity.Session` Kind (or a new neutral name) whose `behaviors/0` is the UNION; `type_name :session` (already shared).
- Templates define the per-instance behavior set (P1's `Kind.BehaviorSet` `init_set/2` — the set stored in the instance's `:kind_base` slice at first spawn). As-built mapping over the union `{Chat, Publisher.SessionImpl, ExternalMirror, Turn, Surface}` (mandatory core = **Chat + Publisher**, Allen 2026-06-11):
  - `chat` template = `Chat` + `Publisher.SessionImpl` + `ExternalMirror`
  - `socialware`/`page` template = `Chat` + `Publisher.SessionImpl` + `Turn` + `Surface`
  Spawning chooses the template → the instance's behavior set.
- Migration: existing `Session` + `SocialwareSession` snapshots map to the unified Kind with the appropriate behavior set materialized from their `:kind_base` (P1 already persisted the set; the cold-load path reloads it). The Kind module reference in `kind_snapshots` (`kind_type`) for existing rows must resolve to the unified Kind — a snapshot `kind_type` migration/alias.

---

## Sub-PRs (REVISED 2026-06-12 after codex plan-review — each MUST keep ALL scenarios green)

> Codex plan-review confirmed the collapse APPROACH is sound (no slice collisions; out-of-set declared behaviors do NOT run `init_slice`/`activate`/signals; `instance_set_gate` covers all declared entry points) but found 4 issues now folded into the sub-PR order below. **`init_set` threading + the nil-guard (P5-0b) and the publisher-read unification (P5-A) MUST land BEFORE P5-1** (the union), or the union silently breaks the P1 invariant / fails boot.

### P5-0 — Backfill existing `:kind_base` (the load-bearing precondition)
`BehaviorSet.effective_set/2` expands a NIL/missing `:kind_base` to the FULL declared list (`behavior_set.ex:108-125`); pre-P1 snapshots seed `%{behaviors: nil}` (`snapshot.ex:106-119`). Once P5-1 makes the declared list the UNION, any nil-`:kind_base` chat row cold-loads with the entire socialware superset → P1 invariant silently breaks. **Backfill EVERY existing session snapshot's `:kind_base` with its concrete as-built set** (chat-Kind rows → `{Chat, Publisher, ExternalMirror}`; SocialwareSession rows → `{Chat, Publisher, Turn, Surface}`); rows that cannot be classified FAIL LOUD; a **go/no-go gate** asserts ZERO nil/missing `:kind_base` session rows remain. Migration on TEST/sandbox DB only.

### P5-0b — Thread `:behaviors` through EVERY session spawn chokepoint + add the runtime nil-guard (codex H1+H2)
Backfilling existing rows is not enough: every current create/spawn/template path omits `:behaviors`, so a session spawned after the backfill still persists nil (`application.ex:704-708`, `session_creator.ex:355-363`, `generic_session.ex:99-113`). **(a)** make EVERY session spawn/create/template chokepoint pass an explicit behavior set (from the chosen template) to `init_set/2`. **(b)** add a RUNTIME FAIL-LOUD guard: on the unified union Kind, a nil/missing `:kind_base` is INVALID — `effective_set` (or the spawn/load path) RAISES rather than silently expanding to the union. (The guard is the structural backstop to the backfill; together they make a nil set impossible on the union Kind.) Gate: spawning a session without an explicit behavior set fails loud; no path yields nil `:kind_base`.

### P5-A — Unify the two publisher-reads into ONE membership-gated read (codex H3; Allen: option B)
Today `{Session, :snapshot/:history}` → `Publisher.SessionImpl` (CapBAC cap-gated) and `{SocialwareSession, :snapshot/:history}` → `SocialwarePublisherRead` (cap-exempt + in-handler membership) — distinct Kinds, no collision. On ONE Kind the same `{kind, action}` can map to only one behavior → fail-loud collision OR socialware reads lose their owner/member authz. **Resolve BEFORE the collapse: unify into a single membership-gated read** (the `SocialwarePublisherRead` model — cap-exempt + `ChatMembership` owner/member check — applied to ALL session reads). This changes chat reads from cap-gated to **membership-gated** (Allen-approved: "谁在 session 里谁能读"). **Consideration flagged:** any current chat read by a non-member CAP holder (e.g. a workspace admin reading a session they have not joined) loses access under pure membership — confirm via tests whether an admin-read path is needed; if so, admit admin as member or keep an explicit admin override (do NOT re-introduce a parallel cap-gated read). Gate: a member reads; a non-member is denied; chat send/receive/join/leave + socialware reads all green under the single read behavior.

### P5-1 — Union behavior set on the single Kind + Templates select the subset
With P5-0/0b/A landed: make the unified Kind's `behaviors/0` the UNION `{Chat, Publisher.SessionImpl, ExternalMirror, Turn, Surface}`; templates select the per-instance subset via `init_set/2` (chat = `{Chat, Publisher, ExternalMirror}`; socialware = `{Chat, Publisher, Turn, Surface}`). Gate: P1's denial test holds on the unified Kind (a chat instance denies `surface.*`/`turn.*`; a socialware instance denies nothing socialware); a fresh chat + a fresh socialware session each behave EXACTLY as the separate Kinds did.

### P5-2 — Spawn/supervisor cutover + drain in-flight `SocialwareSession` (codex H4 — corrected)
**There is NO `kind_type` migration** — both Kinds already return `kind_type = "session"`; snapshots key by `kind_type`, and the `kind_module` is supplied by the spawning **supervisor**, not stored. So the "migration" is a SPAWN-ROUTING cutover: route ALL session spawns (chat + socialware URIs) through the unified Kind + a single supervisor, so existing `Session` + `SocialwareSession` snapshots (already `kind_type "session"`) rehydrate under the unified Kind with the correct per-instance set from their (P5-0-backfilled) `:kind_base`. **DRAIN in-flight `SocialwareSession` processes** (they run under the old supervisor/module) before the cutover — do not leave a process running a module about to be deleted (codex MED). Gate: a cold-restart of a pre-P5 chat session AND a pre-P5 socialware session each rehydrate on the unified Kind with byte-identical behavior + state (cold-restart respawn round-trip); the P1 denial set is preserved per instance; no window where a session URI resolves to a deleted module.

### P5-3 — Remove the dead `SocialwareSession` module + its supervisor/registration
Once all session URIs route through the unified Kind, retire the duplicate `SocialwareSession` Kind module + its supervisor + its `CapabilityRegistry` registrations (the SocialwarePublisherRead registration is superseded by P5-A). Gate: arch fitness (no orphaned Kind; duplicate-fn check ratchets down); a grep proves no remaining production reference to `SocialwareSession`.

---

## E2E acceptance (spec §7 — the P5 merge gate, the strictest)
**Every existing scenario green on the collapsed Kind:**
- **Chat core** — send/receive/join/leave/owner-first-join/cap grants; cold-restart respawn round-trip; `{:from}`→orchestrator relay.
- **Socialware** — SW-DEV/USE/UPD; surface put_version→approve; settlement commit (P2.5); customer-visibility gating (operator_only never leaks).
- **P1 denial test holds on the collapsed Kind** — a chat-template instance denies out-of-set socialware actions; a socialware-template instance denies nothing it should allow. THIS is the load-bearing gate (the collapse is safe iff P1's per-instance denial holds on the superset Kind).
- **External SPA (P3/P4)** + **Feishu mirror** green on the collapsed Kind.
- Full umbrella regression + arch fitness + lifecycle invariants.

**DEFER criterion (explicit):** if P5-1/P5-2 cannot reach all-scenarios-green with acceptable risk (e.g. the snapshot migration is too risky on live data, or a behavior interaction surfaces only on the merged Kind), P5 STAYS DEFERRED — the substrate value (one composable session base, instance-set enforcement, durable delivery, unified external adapters) is already delivered by P0–P4. P5 is the cherry, not the cake.

---

## Open decisions (settle at finalize, against the as-built P1–P4)
1. **Unified Kind name** — keep `Session` (chat is the older/larger) + fold socialware in, vs a neutral `SessionKind`. Lean: keep `Session`, add the socialware behaviors as registry-only/owned per the P3 slice-ownership rules.
2. **Template ↔ behavior-set wiring** — confirm `Kind.BehaviorSet.init_set/2` (P1) is the exact mechanism Templates use to set the per-instance set at spawn (it should be).
3. **Snapshot kind_type migration** — alias vs rewrite; must be cold-restart-safe + reversible. Highest-risk item; gate on the respawn round-trip.
4. **Go/no-go** — after P1–P4 are as-built, re-assess whether the collapse's E2E risk is acceptable; default to DEFER if not.

---

## Re-alignment notes (2026-06-11 — against as-built P0–P4 + Allen decisions; pending config-evolve A/B/C)

These supersede the body above where they conflict; fold in at finalize once the config-evolve decision lands.

1. **As-built behavior lists (verified on origin/main 20a38d5e):**
   - chat `Session` = `Chat` + `Publisher.SessionImpl` + `ExternalMirror`
   - `SocialwareSession` = `Chat` + `Turn` + `Surface` + `ConfigUpdate` + `Publisher.SessionImpl`
   - So socialware ⊇ chat (shared `Chat` + `Publisher`); socialware = chat + `Turn`/`Surface`/`ConfigUpdate`. The collapse is a **chat-base + socialware-extension** hierarchy, NOT two peer Kinds.

2. **Mandatory core = `Chat` + `Publisher` (Allen 2026-06-11).** Every template's behavior set includes the core; `chat` template = core (+`ExternalMirror`); `socialware` template = core + `Turn` + `Surface` (+ `ConfigUpdate`, see #4). Rationale: `Chat` carries the session's ownership/membership model that `Surface.data_owner`→`Chat.data_owner` and `ConfigUpdate`'s `reads_siblings([:chat])` depend on; a fully chat-optional substrate would first need ownership/membership extracted into a base behavior (YAGNI).

3. **NEW P5-0 — backfill nil `:kind_base` BEFORE the union (load-bearing precondition).** Verified: `BehaviorSet.effective_set/2` expands a **nil** `:kind_base` capture to the FULL declared list (`behavior_set.ex` "Legacy sentinel … → declared"). Pre-P1 / absent-args session snapshots have a nil `:kind_base`. The moment P5-1 makes the declared list the UNION, a legacy chat snapshot would cold-load with the entire socialware superset → the P1 "chat denies `surface.*`" invariant silently breaks on restart. **P5-0 (runs FIRST): backfill every session snapshot's `:kind_base` with its concrete as-built behavior set (chat-Kind rows → chat set; SocialwareSession rows → socialware set); rows that cannot be classified FAIL LOUD; a go/no-go gate confirms zero nil `:kind_base` session rows remain before P5-1 proceeds.** TEST/sandbox DB only.

4. **`ConfigUpdate` in the union is conditional on the config-evolve decision (task #50, A/B/C):** if **C** (decouple), `ConfigUpdate` stays a socialware-template behavior in the union; if **A/B** (move to Agent), `ConfigUpdate` is already deleted from `SocialwareSession` before P5, so it is NOT in the union and the socialware template = core + `Turn` + `Surface` only. Finalize the union list after #50 lands.

## Dependency + parallel-safety
Depends on P1 (merged) + the as-built P2.5c/P3/P4, **and on the config-evolve decision (#50) for the final behavior union (note #4)**. P5-0 (nil `:kind_base` backfill + go/no-go) runs FIRST, then P5-1→P5-2→P5-3. Docs-only to plan; implementation strictly last, after P4 + #50, and only if the go/no-go favors it.
