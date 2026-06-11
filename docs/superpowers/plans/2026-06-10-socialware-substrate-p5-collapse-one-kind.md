# Socialware Substrate P5 — Collapse to One Session Kind Implementation Plan

> **STATUS: v1 DRAFT (parallel planning) — HIGHEST RISK, may stay DEFERRED.** Spec §6 P5 itself says: *"Highest risk — do last, may stay deferred if E2E risk is high; the substrate value is delivered by P1–P4 even without P5."* P5 *implementation* depends on P1 (instance-set runtime enforcement — MERGED) AND on P2.5c + P3 + P4 being settled (it merges the two Kinds those phases shaped). This plan is codex-reviewed now (Allen's "all P codex" ask) + finalized/rebased against the as-built P1–P4 before any implementation — and may be a CONSCIOUS no-op (stay deferred) if the E2E risk outweighs the value.

> **For agentic workers:** REQUIRED SUB-SKILL once finalized: superpowers:writing-plans → subagent-driven-development. Subagents touching `apps/**/*.ex` MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`.

**Goal:** Merge `Ezagent.Entity.Session` (chat) and `Ezagent.Entity.SocialwareSession` into ONE parameterized session Kind. Chat, page (socialware), and advisor become **Templates** that select a behavior subset over the single Kind. After P5: "a session" is one Kind; "what kind of session" is a Template (a behavior-set + config), not a separate Kind module.

**Why it is SAFE only because of P1 (the load-bearing dependency):** the single Kind registers the UNION of behaviors (Chat + Surface + Turn + ConfigUpdate + Publisher trunk + SocialwarePublisherRead + the view contracts + …). That superset is harmless **only because P1's per-instance behavior-set runtime enforcement denies out-of-set actions per instance** — a chat-template instance has the Chat behaviors in its set and the socialware behaviors OUT, so a `surface.put_version` dispatch to a chat instance is denied by the P1 `instance_set_gate`, exactly as if `Surface` were not on the Kind at all. Without P1, a superset Kind would expose every behavior on every instance (an authz + correctness disaster). With P1 (merged + its denial test), the collapse is behavior-preserving by construction.

**Architecture:**
- A single `Ezagent.Entity.Session` Kind (or a new neutral name) whose `behaviors/0` is the UNION; `type_name :session` (already shared).
- Templates define the per-instance behavior set (P1's `Kind.BehaviorSet` `init_set/2` — the set stored in the instance's `:kind_base` slice at first spawn): `chat` template = the chat behaviors; `socialware`/`page` template = chat + Surface + Turn + ConfigUpdate + Publisher + SocialwarePublisherRead; `advisor` template = the advisor subset. Spawning chooses the template → the instance's behavior set.
- Migration: existing `Session` + `SocialwareSession` snapshots map to the unified Kind with the appropriate behavior set materialized from their `:kind_base` (P1 already persisted the set; the cold-load path reloads it). The Kind module reference in `kind_snapshots` (`kind_type`) for existing rows must resolve to the unified Kind — a snapshot `kind_type` migration/alias.

---

## Sub-PRs (each MUST keep ALL scenarios green — this is a behavior-preserving collapse)

### P5-1 — Union behavior set on the single Kind + Templates select the subset
Make the unified Kind's `behaviors/0` the union; define the per-template behavior sets (reusing P1 `BehaviorSet.init_set/2`). New chat sessions spawn via the chat template; new socialware via the socialware template. Gate: P1's denial test holds on the unified Kind (a chat instance denies `surface.*`; a socialware instance denies nothing socialware); a fresh chat + a fresh socialware session each behave EXACTLY as the separate Kinds did.

### P5-2 — Snapshot/kind_type migration for existing sessions
Map existing `Session` + `SocialwareSession` `kind_snapshots` rows to the unified Kind (`kind_type` alias/migration) with the correct materialized behavior set from their persisted `:kind_base`. Gate: a cold-restart of a pre-P5 chat session AND a pre-P5 socialware session each rehydrate on the unified Kind with byte-identical behavior + state (the cold-restart respawn round-trip invariant); the P1 denial set is preserved per instance.

### P5-3 — Remove the dead `SocialwareSession`/`Session` module split
Once both route through the unified Kind, retire the duplicate Kind module(s) (or alias). Gate: arch fitness (no orphaned Kind); the duplicate-fn / FF arch checks pass.

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
