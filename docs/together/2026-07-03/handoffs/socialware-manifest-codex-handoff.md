# Codex Handoff — Socialware Manifest track

**To:** codex (development). **From:** lead (Allen + Claude). **Date:** 2026-07-03.

## Mode: AUTONOMOUS — build the WHOLE track in one pass, no mid-flight questions
This is a **pre-set goal**: develop **all six PRs end to end** to the acceptance gate **without asking the lead/Allen anything mid-flight**. If you hit an ambiguity or a blocker, **make the most reasonable default consistent with the spec + settled designs, keep going, and record the decision + any open question in the final return doc and the relevant PR comment.** Do not stall waiting for a human. The only communication back is at the END (the return doc + PR comments).

## Target branch model
Develop on **`integration/socialware-manifest`** (already created off `main`). Commit + push each PR increment and self-merge it **onto that branch** — do NOT merge to `main`, do NOT open PRs against `main`. Keep the branch rebased on `main`. When the acceptance gate is green, **return the branch** with the return doc; the lead runs full gates + merges to `main` (this is the ONLY acceptance checkpoint).

## Read first (both on this branch)
- **Plan:** `docs/together/2026-07-03/plans/socialware-manifest-plan.md` — the 6 PRs, DoDs, **and the "Codex adversarial review — corrections that OVERRIDE" section (C-1..C-7): those corrections are authoritative.**
- **Spec:** `docs/superpowers/specs/2026-07-03-socialware-manifest-design.md` — the model + field set + decisions.
- **Skills to load:** `ezagent-socialware`, `ezagent-developer`, `ezagent-session-orchestrator` (as relevant).

## Goal (one line)
Make a socialware authorable as a **pure-config manifest (zero code; all code in a plugin it `uses`)** that goes **create → publish → discover → install → use**, with a **non-cc-flavor** agent materializing — the full chain, not per-layer stubs.

## Acceptance gate (the track's DoD — non-negotiable)
An **E2E test** that authors a real socialware as pure config, publishes it (`ConfigGovernance.Socialware`), discovers it (`DefinitionRegistry.list`), installs it via the new-session page, and uses it — **with ≥1 non-cc agent materializing (config+readiness+role+grants+join) and its views rendering** — and **fails if any link breaks**. Plus `mix ezagent.socialware.check` extended to assert manifest validity+installability. Plus all standard gates green (`arch.scan`/`doc.scan`/`uri_query.scan`/`check_invariants`/`format`/`test`/`:ezagent_plugin_check`). **Backend-only "done" is rejected.**

## Waves (sequencing per correction C-3 — the plan's "PR1-4 independent" claim is WRONG)
- **Wave A (parallel):** PR-1 (name-ref resolver **+ add `uses` field to the `Definition` struct** — C-5) · PR-2 (`DefinitionRegistry.list` **+ write ownership ACL with a named authority boundary** — C-4).
- **Wave B (designs are SETTLED below — implement directly, NO discuss-first gate):**
  - **PR-4 (flavor)** — implement per "SETTLED — PR-4" below.
  - **PR-3 (publish)** — implement per "SETTLED — PR-3" below.
- **Wave C:** PR-5 (new-session page — needs PR-1,2,**4**) · PR-6 (dogfood autoservice/hello as pure-config manifest + the acceptance-gate E2E — needs PR-1..4).

## Rules
- **Every PR carries a behavioral proof** (not just `socialware.check` statics — C-6). A regression/E2E test that fails on the pre-change code.
- **Fail-closed** everywhere: a manifest referencing an un-installed plugin/view must NOT produce a half-built socialware; write/publish must reject cross-workspace/forged subjects.
- **PR-3 and PR-4 designs get a codex adversarial review before implementation** (they touch CapBAC/core + the materialization pipeline).
- Keep `main` green discipline: rebase on `main`, run the affected suites (`MIX_TEST_PARTITION=<unique>` when running in a worktree).
- **No mid-flight check-ins.** Self-merge each wave onto the branch and continue to the next. Every design ambiguity → pick the spec-consistent default, note it in the return doc + PR comment, keep moving. All PR-3/PR-4 designs are already settled below — implement them directly.

## SETTLED DESIGNS (Allen 2026-07-03 — authoritative; implement directly)

### SETTLED — PR-4: ONE unified agent-materialization pipeline
- Do NOT keep a second cc-pinned path. **Extract the flavor-aware core of the world create-agent path** (`agent_create.ex:336` + `role_step.ex:159` — flavor template-data + config validation + cap minting + role markers + config_dir + readiness) into a shared function `create_agent_from_recipe(recipe, flavor, …)`.
- **Socialware materialization (`materialize_definition_agents`, and the sibling `SessionAgentMaterialize.materialize_by_role`) call that shared core** per declared agent, then add the socialware/session-specific wrapper: per-session URI + assign `role_name` + `session.join` + grant the recipe's `requested_caps`.
- Add optional `flavor` (default `cc`) to the `Definition.agents` `agent_spec`. `Recipe` still forbids a flavor field — flavor is the socialware's axis. Delete the `DefaultAgentSeed.template_content` shortcut for socialware.
- **DoD:** a Definition declaring a **non-cc** agent (e.g. codex or py) materializes correctly (config + readiness + role + grants + join) proven by test; default (no flavor) stays cc; world-create path behavior unchanged. This is the load-bearing PR — its E2E is part of the acceptance gate.

### SETTLED — PR-3: publish via `ConfigGovernance.{Agent, Socialware}` + owner/visibility model
**Structure (the generic engine already exists):** `Ezagent.Socialware.ConfigChangeStore` is the subject-agnostic CR lifecycle engine (open→stage→published→rejected→rolled_back, NO auth) over `ConfigStore` (data+pointers). Keep both. Rename the current `Ezagent.ActionSet.ConfigGovernance` behavior to the **`.Agent`** fork (agent cap + self-binding + sandbox effect — unchanged). Add a **`.Socialware`** fork = a parallel thin dispatch behavior driving the SAME `ConfigChangeStore`, differing only in: cap + subject + post-publish effect.

**Owner + cap:**
- A socialware is **owned by its creating user** (grantable to teammates, like an agent). One cap: **`cap(:socialware, :manage, instance: "socialware:<name>", workspace: <ws>)`** — grants edit + version-publish (pointer flip) + rollback. Follows #1042's "no separate publisher cap".
- Subject = the `socialware:<name>` ConfigStore subject (NOT self/agent). The `.Socialware` fork asserts the CR subject is a socialware the caller holds `:manage` on.

**Visibility (a SCOPE, not a boolean):** extend `visibility_policy` with a scope: **`private`** (default; own workspace only) and **`public`** (global market; anon-visible). (`shared`-to-specific-workspaces is a designed-in **extension point — do NOT build it now**.)
- Setting `private` = self-serve under the owner's `:manage` cap.
- Setting **`public`** = crosses a governance boundary → **admin/moderation gate** (an admin cap or approval — NOT self-serve for arbitrary tenants). For this build, public listing is **admin-gated** (core-team curates); self-serve-public + a review queue is a later addition.

**Discovery + cross-workspace install:**
- `DefinitionRegistry.list(caller_ws)` returns: caller's own-ws definitions **+ public** definitions. (So B sees A's only if A's is `public`.)
- **Install a public socialware from another ws** = **cross-ws READ-ONLY lookup** of the (public) Definition + **materialize a LOCAL copy in the installer's workspace** (agents spawn in the installer's ws, caps minted there per the recipe's `requested_caps`). npm-style: no write access to the owner; install never mutates the source.
- **DoD:** owner publishes (private→public via admin gate) → appears in another ws's `list` → that ws installs → local materialization works; a non-owner cannot edit/publish; a non-public socialware is invisible cross-ws (tests, red-on-pre-change→green).

## Return (the ONLY communication back — no mid-flight messages)
When the acceptance gate is green on `integration/socialware-manifest`, write a **return handoff** at `docs/together/2026-07-03/returns/socialware-manifest-return.md` on the branch, covering:
- **What landed** — each of the 6 PRs (commit shas on the branch), gates run per PR + the final full-suite result.
- **The acceptance-gate E2E transcript** — the real create→publish→discover→install→use run with the non-cc agent.
- **Decisions/defaults you made** — every ambiguity you resolved yourself (with your reasoning), so the lead can ratify or revise at acceptance.
- **Open questions / risks / anything you couldn't fully close** — deferred here (and mirrored in the relevant PR comment), NOT asked mid-flight.
- **Anything that needs Allen** (e.g. the admin/moderation gate for public listing, if it needs a policy call) — listed here as a post-acceptance decision, with your interim default.
Then the lead runs full gates + merges the branch to `main`. That merge is the single acceptance checkpoint.
