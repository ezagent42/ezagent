# Plan — Socialware Manifest (create→publish→discover→install→use)

**Target branch:** `integration/socialware-manifest` (off `main`). All PRs merge here; lead accepts + merges to `main` at the end.
**Spec:** `docs/superpowers/specs/2026-07-03-socialware-manifest-design.md` (#1152). **Owner:** codex (dev), lead (accept/gate/merge).
**North star:** everything around ezagent = plugin/socialware uploaded at runtime; core small; code/data separated. This plan builds the *create→publish→discover→install→use* chain so a socialware can be authored as **pure config** (no code) via ezagent itself.

## Model (locked, see spec §1)
- **app = socialware** = config-only `Definition` (VSCode extension-pack); **plugin = code** (VSCode extension). Addressed `socialware:<name>` (opaque subject; `config://` dead).
- **SessionTemplate** = the new-session preset (installs+members+name). **session** = instance.

## Acceptance gate (whole track DoD — a closed, user-layer, non-regressible invariant)
**One real socialware, authored as a PURE-CONFIG manifest (zero code; all code in a plugin it `uses`), goes create→publish→discover→install→use — with at least one agent on a NON-cc flavor materializing successfully + its views rendering — proven by (a) an E2E test that fails if any link breaks, and (b) `mix ezagent.socialware.check` conformance extended to assert the manifest is valid+installable.** Plus all standard gates green (`arch.scan`/`doc.scan`/`uri_query.scan`/`check_invariants`/`format`/`test`/`:ezagent_plugin_check`). Backend-only "done" is rejected — the new-session page must actually create a working session.

## PRs (each merges to `integration/socialware-manifest`; independent unless noted)

### PR-1 — name-ref resolver layer (spec O-1 = a)
- **Goal:** a manifest authored with **names/IDs** (strings) resolves into the existing `Definition` struct (whose `views/shape/bases` are `module()`) at load/install. T2 struct unchanged.
- **Do:** a resolver `manifest(names) → Definition(modules)` — resolve `views`/`shape`/`bases` names via the ActionSet/view registry, `agents[].recipe` via `RecipeRegistry` (already name-based), `uses:[plugin]` validated present (fail-closed). Round-trip: a code-authored Definition and a name-authored manifest converge on the same resolved struct.
- **Files:** `apps/ezagent_domain_session/lib/ezagent/socialware/` (new resolver module) + `definition.ex` (accept manifest map).
- **DoD:** resolver unit tests (name→module, missing plugin→fail-closed, code+manifest converge); gates green.

### PR-2 — discovery (`DefinitionRegistry.list`) + write ownership ACL (W0-deferred/W1)
- **Goal:** list installable socialwares (catalog/checkbox data source) + close the write_definition ownership hole.
- **Do:** `DefinitionRegistry.list(workspace)` → `[{name,title,description,public?}]` (this-ws + system + published filter). `write_definition/2`: reject caller-supplied workspace that isn't the caller's; no silent default-to-system (jjkysy W0#2 / #1148).
- **Files:** `socialware/definition_registry.ex`.
- **DoD:** list returns only entitled+published defs (test); write ACL rejects cross-ws/forged workspace (test, red-on-main→green); gates green.

### PR-3 — `ConfigGovernance.{Agent, Socialware}` fork (task #158)
- **Goal:** publish a whole socialware Definition via the CR pattern.
- **Do:** extract shared CR machinery (open/stage/preview/publish-pointer-flip/rollback) into subject-agnostic `ConfigGovernance`; move current agent path to `ConfigGovernance.Agent`; add `ConfigGovernance.Socialware` (stage draft Definition → flip visibility/version pointer → discoverable+installable). Preserve all existing agent-CR behavior/tests.
- **Files:** `apps/ezagent_domain_identity/lib/ezagent/.../config_governance*.ex` (+ new `.Socialware`).
- **DoD:** existing agent-CR tests all green (no behavior change); new `.Socialware` publish test (draft→publish→appears in `list` as published); gates green. **Note:** this touches CapBAC/core → discuss-first if the shared-parent extraction is non-obvious.

### PR-4 — `agents[].flavor` via `Recipe.Compose` (cc-hardcode fix)
- **Goal:** a socialware-declared agent can be cc/codex/py, not hard-pinned cc.
- **Do:** add optional `flavor` to `Definition.agents` `agent_spec` (default cc). Route `materialize_definition_agents` (and sibling `SessionAgentMaterialize.materialize_by_role`) through `Recipe.Compose.materialize(recipe, %{flavor_behaviors: <flavor>.instance_behaviors})` (the flavor-generic path world-create already uses) instead of the cc-pinned `DefaultAgentSeed.template_content`. **Do NOT** just add a flavor arg to the cc seed — cc uniquely wires the role hooks; Compose makes skills-into-config_dir flavor-generic. Recipe still forbids a flavor field (flavor is the socialware's axis, not the recipe's).
- **Files:** `session_creator/definition_agents.ex`, `agent/session_agent_materialize.ex`, `socialware/definition.ex` (agent_spec + validation).
- **DoD:** a Definition declaring a **non-cc** agent materializes that flavor (test); default (no flavor) still cc; gates green.

### PR-5 — new-session page (官网 UI) [dep: PR-1, PR-2]
- **Goal:** the create surface Allen drew: `session name` + **checkboxes of installable socialwares** (from PR-2 `list`) + invite user/agent → create.
- **Do:** world/新建 UI form → `create_session(name, installs:[checked], members:[invited])` (extend `SessionCreator.create_session` opts to accept an explicit installs list + members, back-compat with template_name). Reuse the existing invite component, moved pre-create.
- **Files:** `apps/ezagent_plugin_world/assets/src/` (form) + `world_live.ex`, `session_creator.ex`.
- **DoD:** LiveViewTest/agent-browser: fill name → check 2 socialwares → invite 1 agent → create → land in session with both installed. **User-layer proof required.**

### PR-6 — dogfood + conformance gate [dep: PR-1..4]
- **Goal:** prove the whole chain on a real app.
- **Do:** re-express **autoservice (or hello)** as a pure-config manifest referencing an `autoservice` plugin's registered pieces (extract any inline code into the plugin). Extend `mix ezagent.socialware.check` to validate the manifest + assert installability. E2E: author→publish(`ConfigGovernance.Socialware`)→discover(`list`)→install(new-session)→use, with a non-cc agent.
- **DoD = the track acceptance gate above.**

## Sequencing / parallelism
- **Parallel now:** PR-1, PR-2, PR-3, PR-4 are independent.
- **Then:** PR-5 (needs 1+2), PR-6 (needs 1-4) last.
- Each PR: codex develops on `integration/socialware-manifest`, self-merges to that branch (no main merge, no GitHub PR needed against main), returns branch; lead runs full gates + merges to main at track end.

## Risks / discuss-first
- **PR-3 (ConfigGovernance extraction)** touches CapBAC/core — the shared-parent split must not weaken the agent-CR cap model. Codex flags the design before coding.
- **PR-4** must go via `Recipe.Compose` (not the cc seed) or the `no_surface_read_dispatch`/activation invariants + broken non-cc agents bite (see spec §4).
- **Name-ref resolution (PR-1)** must be fail-closed on a missing plugin/view — a manifest referencing an un-installed piece must NOT silently produce a half-built socialware.

---

## Codex adversarial review — corrections that OVERRIDE the PRs above (2026-07-03)

Codex reviewed this plan against the code. These corrections are authoritative; where they conflict with the PR sketches above, follow the correction.

**C-1 (CRITICAL, reshapes PR-4) — flavor is NOT a shallow `Recipe.Compose` swap.** `Recipe.Compose` returns behaviors/passive-role/sandbox content and **does not compose caps** (`recipe/compose.ex:19,55`). Non-cc materialization needs flavor-specific **template data + config validation + cap minting + role markers + config_dir + readiness** — which the **world create-agent path already does** via `agent_create.ex:336` + `role_step.ex:159` (flavor branching). **PR-4 must route socialware agent materialization through (or share) that same world-create flavor pipeline**, not the cc-pinned `DefaultAgentSeed.template_content` (`definition_agents.ex:151,246`; `session_agent_materialize.ex:173` repeats the cc path). Treat PR-4 as the **end-to-end materialization pipeline unification**, not a routing patch. This is the single biggest risk — a shallow PR-4 makes the acceptance gate unreachable. PR-4 is **discuss-first** (codex-review the design before coding).

**C-2 (HIGH, reshapes PR-3) — the `ConfigGovernance` parent is NOT cleanly extractable as sketched.** Current `ConfigGovernance` is agent-bound in caps (`config_governance.ex:117` agent Manage), subject (`:270` forces CR subject = self), self-assertion (`:290` asserts self is an agent), and effects (`:344` agent sandbox/config). The reusable machinery is closer to `ConfigChangeStore` — but that **does NO authorization** (`config_change_store.ex:10`). So PR-3 must **define a NEW authority model for socialware publish**: socialware definitions are NOT agents → a concrete **subject owner + cap shape** for open/stage/preview/publish/rollback on a `socialware:<name>` subject (who owns a socialware? the creating user/workspace). Do not reuse the agent Manage cap; do not fall back to system/admin. **PR-3 is discuss-first** — spec the cap model first. `.Agent` = today's behavior unchanged; `.Socialware` = the new subject+cap.

**C-3 (HIGH) — PR independence is false. Corrected sequencing:**
- **Wave A (parallel):** PR-1 (resolver + `uses` field) · PR-2 (`list` + write ACL).
- **Wave B:** PR-4 (flavor pipeline — big, discuss-first) · PR-3 (publish — needs PR-2's `list` for its DoD + its own cap model, discuss-first).
- **Wave C:** PR-5 (new-session page — needs PR-1,2,**4**: installing a socialware that declares agents is meaningless until PR-4 materializes them). PR-6 (dogfood + gate — needs PR-1..4).
- PR-6 is the **first place the real acceptance path runs** — earlier per-PR DoDs must each carry their own end-to-end-ish proof so "green PRs, dead system" can't happen.

**C-4 (HIGH, PR-2) — name the authority boundary.** `write_definition/2` today lets the caller set `workspace_uri`, defaults to the system workspace, and defaults the actor to system admin with no cap check (`definition_registry.ex:80`). PR-2 must state the exact authority: a write is authorized against **the caller's workspace membership/cap**, rejects a caller-supplied workspace ≠ caller's, and never silently writes to system. `list(workspace)` needs precise visibility semantics (this-ws + system + published), not raw enumeration (`definition_registry.ex:21,138`).

**C-5 (MEDIUM, PR-1) — `Definition` has NO `uses` field today** (`definition.ex:11` defstruct; binary behavior input is treated as an existing module atom, `:126`). PR-1 must **add the `uses:[plugin]` field** to the struct + validation + persistence, or the "zero-code, behavior-from-plugin" acceptance goal is unprovable. This makes PR-1 a struct change, not only a resolver.

**C-6 (MEDIUM) — DoDs must prove the goal, not statics.** `mix ezagent.socialware.check` validates a built Definition's static refs (`conformance.ex:35,123`) — necessary, not sufficient. Every PR DoD carries a behavioral proof; PR-4's must verify flavor-specific config + readiness + role + grants + session-join (template spawn fails loud on missing flavor data — `agent_template.ex:286`, `py_agent.ex:65`).

**C-7 (process) — ship the spec with the branch.** Codex couldn't read the design spec (it lives on branch `docs/socialware-manifest-design`, not merged). **Copy the spec onto `integration/socialware-manifest`** so codex/devs read plan + spec together.

**Net:** the plan's shape holds, but **PR-3 and PR-4 are the load-bearing, deeper-than-sketched pieces (both discuss-first + codex-reviewed before coding)**, PR-1 includes a struct change (`uses`), and the wave sequencing above replaces the "PR1-4 independent" claim.
