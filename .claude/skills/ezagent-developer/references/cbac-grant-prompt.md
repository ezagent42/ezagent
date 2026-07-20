# cbac-done-right — 授权前必读 prompt (read before ANY capability-granting work)

> Paste this to yourself (or the agent) before writing/modifying code that GRANTS a
> capability in ezagent. Landed `fa72d36ba`. Ignoring it → you fail the I12/I7 CI
> gates on rebase. Full model: `.claude/skills/ezagent-developer/references/capbac.md` §4.5.

## The one rule
A grant is **ISSUE → STORE → VERIFY** — never a single issuer→grantee dispatch that
writes the grantee's `:caps` slice. Authority moves **issuer → artifact**; storage
happens **only through the grantee itself**.

## Decision tree — "I need to grant a cap"
1. **Never** use the old pattern: no `grant_cap_via_router(..., mode: :call)`, no
   `await_ready`-then-grant, no `Identity.Grant` path that *drives the grantee* to
   store. These trip **I12** (paradigm-lock).
2. **ISSUE (grantor side, always):** `Ezagent.Cap.issue(<tag>, target, cap)`
   (`apps/ezagent_core/lib/ezagent/cap.ex`). Runs the full grant-authorization algorithm
   against the *issuer's* held authority, stamps `granted_by = <issuer>` on a
   provenance-only artifact. Transfers NO authority. Tags unchanged:
   `{:held_by}` / `{:admin}` / `{:rule,name,owner}` / `{:genesis}`.
3. **STORE — is the grantee COLD or LIVE?**
   - **COLD** (not yet keyed / materialized before it exists): issue every proposed cap
     and commit to `RecipeCapBinding` via `issue_and_upsert/4`. The agent self-stores
     from its `create/1`/`activate/2` lifecycle. Do NOT dispatch a grant.
     → Pattern: `session_creator/definition_agents.ex` + `mix ezagent.agent.grant_recipe_caps`.
   - **LIVE**: hand the issued artifact to the grantee via `Ezagent.Identity.absorb_cap/2`
     (one `:vm_internal` cast; `handle_absorb_cap/2` accepts ONLY `caller: :vm_internal`;
     same-BEAM/same-node).
     → Pattern: `entity/session/orchestrator/caps.ex do_grant_orchestrator_scoped_caps`,
       `workspace.ex issue_and_absorb_initial_caps` — `issue_*` then `absorb_*`, with
       NO `Identity.Grant`, NO `mode: :call`, NO `await_ready`.
4. **VERIFY (Path A, PR #1457, 2026-07-18):** caps are **born-signed** and **strictly
   crypto-verified** — `Ezagent.Cap.verify/1` is **retired**. Storage admits only born-signed
   receiver-bound artifacts (`Cap.storable_for?`/`verified_set`); dispatch verifies the ed25519
   signature via `Ezagent.Cap.Verifier` → `Authority.verify_current` (fail-closed:
   `:invalid_cap_signature`/`:missing_cap`). No permissive/provenance-format stand-in remains.
   See `capbac.md` §4.6. (Path B = deferred isolated signer for in-VM-malicious defense.)
5. `granted_by` is **always the issuer**, validated `%URI{scheme: "entity"}`. If the
   owner can't resolve, **fail closed** — never fall back to admin as `granted_by`.
6. Don't add a NEW `grant_cap` / `grant_cap_via_router` site — the ~16 legacy sites are
   pinned **shrink-only** (count can only go DOWN). A genuine new need is a review
   surface, not a widen.

## Self-check before you finish
- [ ] No `{:set, :caps, …}` write to a grantee as a grant (only self-store lanes above).
- [ ] `Cap.issue/3` is the ONLY place `%Capability{granted_by:}` is stamped on my path.
- [ ] A `Cap.verify/1` boundary covers where my cap is loaded/stored.
- [ ] `mix test apps/ezagent_core/test/invariants/` green — I7 (issue chokepoint),
      I12 (paradigm-lock), N1 (bypass trust keys), absorb-reachability,
      provenance-chokepoint, verify-load-boundaries.

## Read for depth
`.claude/skills/ezagent-developer/references/capbac.md` §4.5 (start here · full decision
tree) · GLOSSARY #162 · ARCHITECTURE §7.7 · `docs/e2e/2026-07-11/phase3-cbac-done-right/`
· the 6 invariant gates in `apps/ezagent_core/test/invariants/`.
