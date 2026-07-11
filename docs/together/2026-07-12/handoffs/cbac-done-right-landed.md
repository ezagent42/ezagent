# Handoff — cbac-done-right (Phase-3 cap self-store) LANDED on main

**To:** all devs (esp. anyone with in-flight cap-granting work) · **From:** coordinator (Claude) · **Date:** 2026-07-12
**Repo:** `/Users/h2oslabs/Workspace/esr-ng` (ezagent42/ezagent) · **Merge:** `fa72d36ba` on `origin/main`

## TL;DR
The CapBAC grant paradigm changed. A grant is **no longer** a single issuer→grantee dispatch that writes the grantee's `:caps` slice. It is now **ISSUE → STORE → VERIFY**, with an **I12 paradigm-lock** invariant that FAILS CI on the old pattern. If your branch grants caps the old way, **it will fail the I12 gate on rebase** — see "Migration" below.

**Source of truth:** `.claude/skills/ezagent-developer/references/capbac.md` §4.5 (the design spec/plan were NOT merged — capbac.md, the invariant gates, and `docs/e2e/2026-07-11/phase3-cbac-done-right/` are now authoritative). GLOSSARY Decision #162 + ARCHITECTURE §7.7 summarize.

## WHAT changed

A grant is three separable steps; authority moves **issuer → artifact**, storage moves only through the **grantee itself**:

1. **ISSUE — `Ezagent.Cap.issue/3`** (`apps/ezagent_core/lib/ezagent/cap.ex`). The grantor's step. Loads the *issuer's* held authority, runs the full grant-authorization algorithm (`CapabilityRegistry.authorize_grant/3` — same checks as before), and on success stamps `granted_by = <issuer>` on a provenance-only **artifact**. **It transfers NO authority to the grantee.** The four tags (`{:held_by}`/`{:admin}`/`{:rule}`/`{:genesis}`) are unchanged. `Ezagent.Identity.Grant` is still the sole grant/revoke constructor (it now routes grant through `Cap.issue`).
2. **STORE — the grantee absorbs the artifact into its OWN slice.** Two grantee-driven lanes:
   - **`create/1` self-store** — a keyed entity reads its own pre-issued artifacts at Identity `create/1`/`activate/2` (from `RecipeCapBinding`) via `Cap.verified_set/1`.
   - **`:vm_internal` absorb** — `Ezagent.Identity.absorb_cap/2` dispatches one `:absorb_cap` cast with `caller: :vm_internal`; `handle_absorb_cap/2` accepts ONLY a `:vm_internal` caller. Same-BEAM, same-node, no cross-node transport.
3. **VERIFY — `Ezagent.Cap.verify/1`** at ≤5 reviewed load/store boundaries. Fail-closed; Phase-3 checks provenance *format* (entity-scheme `granted_by`) as a stand-in for Phase-4 signatures.

`granted_by` is now **always the issuer** (validated `%URI{scheme: "entity"}`). Pre-issued recipe caps live in `Ezagent.Identity.RecipeCapBinding` (`issue_and_upsert/4`) — persistence never dispatches a cap write to the grantee.

## The gates you'll hit (all in `apps/ezagent_core/test/invariants/`)
- `cap_self_store_paradigm_lock_test.exs` — **I12**. Forbids issuer→grantee grant dispatch. The ~16 legacy grant sites are pinned **shrink-only**; the 3 cold-agent cutovers (recipe/orchestrator/workspace) are zero-tolerance.
- `cap_issue_chokepoint_test.exs` — **I7**. Ratchets every `%Capability{granted_by:}` constructor + every `{:set, :caps, …}` slice writer down toward `Cap.issue`/`store_verified_cap`.
- `cap_absorb_reachability_test.exs`, `cap_provenance_chokepoint_test.exs`, `cap_verify_load_boundaries_test.exs`, `cap_issued_bypass_trust_keys_test.exs` (N1) — pin absorb reachability, single provenance home, verify boundaries, and the `cap_issued` runtime-bypass trust keys.

## Migration — for in-flight cap-granting work

**Who is affected:** any branch that grants caps via the **OLD issuer→grantee dispatch** pattern — i.e. a blocking, ready-gated grant (`grant_cap_via_router(..., mode: :call)` / `await_ready` before the grant) or an `Identity.Grant` call that *drives the grantee* to store the cap. On rebase onto main, the I12 and I7 ratchets will FAIL because your new grant sites widen a shrink-only ledger.

Concretely, this likely hits:
- **jjkysy's socialware composition work** (`m2-orchestrator-socialware`, socialware-manifest / role-slot) — any path that grants an agent/member its caps.
- **dealscout / kanban** cap-granting (and any new socialware that provisions agent caps at materialization).

**How to adapt (the mechanical recipe):**
1. **Split issue from store.** Instead of one grant dispatch, call `Ezagent.Cap.issue(<tag>, target, cap)` (grantor side) to produce the artifact, then let the **grantee** store it.
2. **Cold agent (not yet keyed / materialized before it exists):** issue every proposed cap and commit them to `RecipeCapBinding` via `issue_and_upsert/4`. The agent self-stores them from its `create/1`/`activate/2` lifecycle. Do NOT dispatch a grant to the agent. (Pattern: `session_creator/definition_agents.ex` + `mix ezagent.agent.grant_recipe_caps`.)
3. **Live grantee:** issue the artifact, then hand it to the grantee via `Ezagent.Identity.absorb_cap/2` (the `:vm_internal` cast). (Pattern: `entity/session/orchestrator/caps.ex` `do_grant_orchestrator_scoped_caps` and `workspace.ex` `issue_and_absorb_initial_caps` — both `issue_*` then `absorb_*`, with NO `Identity.Grant`, NO `mode: :call`, NO `await_ready`.)
4. **Do NOT add new legacy grant sites.** The ~16 remaining `grant_cap`/`grant_cap_via_router` sites are pinned shrink-only — the ratchet count can only go DOWN. If you genuinely need a new one, that's a review surface, not a widen.

**If you're only rebasing (not adding grants):** the ratchets are exact-match maps; a rebase that touches no grant/store/verify site is unaffected. If the gate flags a file you didn't mean to change, you re-introduced a legacy driver — check your diff.

## Read before you migrate
- `.claude/skills/ezagent-developer/references/capbac.md` §4.5 (full model + decision tree) — **start here**.
- The 6 invariant gates above (they document the exact allowed shapes).
- `docs/e2e/2026-07-11/phase3-cbac-done-right/` (e2e evidence of the three flows).

Questions → coordinator. Happy to pair on a specific branch's migration.
