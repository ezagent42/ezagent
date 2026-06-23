# Handoff (DRAFT — pending Allen confirm): Agent-contract CRUD in `world`

> **Date:** 2026-06-24 · **From:** Claude (re-scope of #84) · **To:** an independent developer (human + cc/codex)
> **Tracking:** task #84 (re-scoped) — "Agent Console: agent-contract CRUD slice" · **Suggested branch:** `agent-console-crud`
> **Base:** `origin/main` @ `09416cf5`
> **Status:** DRAFT — re-scoped per lead (Allen) to *Agent-contract CRUD only*. NOT confirmed. **Update (U) has a load-bearing open question that must be resolved with Allen before the dev builds U** (§9 Q1).

---

## 0. Mission

**Scope target (read once, pinned everywhere below):** "agent definition" here means the **runtime agent INSTANCE** (`entity:agent`) that #905 provisions and shows on its detail page — **not** the cold `AgentTemplate` (`template://agent/<name>`) sandbox-pointer Kind, which is a deferred sibling (§2 row 3a, §6).

This is a **re-do**. The prior #84 attempt ([#904](https://github.com/ezagent42/ezagent/pull/904)) shipped a **demo** instead of the real feature — root cause: a Definition of Done not pinned to *demonstrable acceptance points* (a screenshot of a populated form passed it). This handoff narrows #84 to **just Agent-contract CRUD** — create / view / modify / delete an **agent definition** from the `world` UI — and writes a DoD that **only passes against observed backend state after a mutation** (§5). A screenshot of a form is the demo; a screenshot of state *after* the mutation is the feature.

The agent-contract UI MVP already partly exists: [#905](https://github.com/ezagent42/ezagent/pull/905) (merged, `63e493c4`) shipped the **create form + read-only detail + list** adapted to the agent contract. **Build on #905 — do not duplicate it.** This task adds the missing **Update** and **Delete** verbs and hardens Create/Read to the demonstrable bar (§5, §6).

---

## 1. Required reading (before writing code)

1. Skill **`ezagent-developer`** — invariants that gate your PRs (`.claude/skills/ezagent-developer/`). *(The harness `Skill` tool may not register project-vendored skills; read the SKILL.md directly.)*
2. Skill **`ezagent-session-orchestrator`** — only if Update touches the live agent process (it does — `Manage`/`ConfigEvolve` dispatch into the running Kind).
3. The **`dev-together`** skill + `.claude/skills/dev-together/references/handoff-standard.md` — the workflow + demonstrable-DoD rule this handoff follows.
4. `docs/guide/world-coordination.md` — **REQUIRED** (this touches `world`: additive `*.tsx` + `*_data.ex` + `world_live.ex` clause + the in-flight registry row).
5. The agent-definition contract: `apps/ezagent_core/lib/ezagent/agent_manifest.ex` (the `AgentManifest` author/executor field model) + its specs `docs/superpowers/specs/2026-06-21-agent-definition-contract-design.md`, `…-agent-contract-spec1-manifest-compile-fallback.md`, `…-agent-contract-spec3-versioned-artifact.md`.
6. The #905 handoff this builds on: `docs/together/2026-06-23/handoffs/socialware-creator-agent-config.md`, and the original broad #84 handoff (siblings now deferred): `docs/superpowers/handoffs/2026-06-22-agent-console-in-world-handoff.md`.
7. The config-evolve spec (the candidate Update primitive — read before touching U): `docs/superpowers/specs/2026-06-11-agent-owned-config-evolve-design.md`.

---

## 2. Locked decisions (settled — do not re-litigate)

| # | Decision | Value |
|---|----------|-------|
| 1 | Scope | Agent-contract **CRUD only** (create / view / modify / delete one **agent definition**). Orchestrator console + routing/team UI are deferred siblings (§6). |
| 2 | Surface | The **existing** `world` identities/agents surface (#905). Additive — no new top-level route family, no nav redesign. |
| 3 | Contract | CRUD operates against the agent the runtime already produces (the `create_agent/3` body + `AgentManifest` author/executor model). Do **not** invent a parallel agent model or parallel storage. |
| 3a | **CRUD target = the RUNTIME agent INSTANCE, not the AgentTemplate** | This slice manages the spawned **`entity:agent`** instance #905's detail page shows (live Phase/Bridge/caps). It does **NOT** author/edit the cold **`Ezagent.Entity.AgentTemplate`** (`template://agent/<name>` — the spawnable-sandbox-pointer Kind, `apps/ezagent_domain_agent/lib/ezagent/entity/agent_template.ex`). Template authoring is a **deferred sibling** (§6). `AgentManifest` is the declarative agent-*body* contract (#80/#881); `AgentTemplate` is the orthogonal cold template Kind. Editing an AgentTemplate does **not** retro-modify already-spawned instances — which is exactly why "Modify" in this UI targets the live instance, not the template. |
| 4 | Dispatch | Every mutation goes through the **existing cap-checked domain primitives** named in §3 — never a synthesized cap, never a direct GenServer poke. |
| 5 | Authority | The **creator manage-cap** `cap(:agent, Manage, :any, instance)` (minted at create — `creator_grant.ex:20`, `agent_create.ex:578-581`) is the single authority for Delete **and** the candidate Update path. No new cap is invented in this slice. |
| 6 | Anti-demo gate | The DoD passes **only on observed post-mutation backend state** (§5). A populated form / a row that renders is NOT done. |

---

## 3. Architecture primer (for a dev new to the code)

**Where the world agent UI lives.** The `world` plugin renders a React/TSX island, not server HEEx components:
- UI components: `apps/ezagent_plugin_world/assets/src/components/Identities.tsx`
  - `AgentNewForm` (create), `AgentDetail` (read), `AgentApiKeys`, `AgentExtensions`, `IdentityCard` (list rows), `ContractCoverage` (read-only "pending backend" list).
- State builders (server → island payload): `apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex` — `component_state/5` builds `agents_table`, `agent_new_form`, `agent_detail`, `agent_api_keys`, `agent_extensions`; `list_entities/2` builds the list rows.
- Routes: `apps/ezagent_plugin_world/lib/ezagent/world/routes.ex` — `/identities/agents`, `/identities/agents/new`, `/identities/agents/:uri`, `…/caps`, `…/api-keys`, `…/extensions`, `…/terminal`.
- Dispatch (island event → domain): `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex` — `handle_event("world:dispatch", %{"action" => "agents.create", …})` → `dispatch_agent_create/2` (line 366) → `Ezagent.Workspace.create_agent/3` then `Ezagent.Workspace.grant_initial_caps/3`. The `error:` surfacing pattern (`push_agent_create_error/2`, no-silent-drop) is the template every new mutation must follow.

**The domain primitives the mutations call (all CapBAC-gated):**
- **Create** — `Ezagent.Workspace.create_agent/3` (`apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:760`) → `Behavior.Workspace.:create_agent` action (`apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create.ex:21`). Accepts ONLY `{flavor, name, cwd, with_pty}` (`coerce_create_args/1`, lines 64-88); validates flavor ∈ `cc echo curl np codex` (line 117), name regex (line 135), cwd-required-for-cc/codex (line 142). On success it **grants the creator the manage-cap** (`grant_agent_creator_manage_cap/3`, line 578). The `AgentManifest` author fields (`soul`, `skills`, `tools`, `lifecycle`, executor extras) are **NOT accepted** by create today — that is the documented gap #905 surfaced as the read-only "Contract coverage / Pending backend approval" list.
- **Delete** — `Ezagent.Behavior.Manage.:delete` (`apps/ezagent_core/lib/ezagent/behavior/manage.ex:44`), registered on EVERY Kind. Gated by `cap(:any, Manage, :any)` (the creator manage-cap satisfies it). Dispatched **into** the agent's own process; it replies, then schedules a detached `Ezagent.Lifecycle.destroy/2` Task (self-destroy guard ⇒ external caller pattern, `schedule_delete/1` line 114). **Implication for the DoD:** a UI row disappearing is NOT proof the Kind died — the destroy is async + detached.
- **Update — TWO candidate primitives, and which is correct is OPEN (§9 Q1):**
  - (a) `Ezagent.Behavior.Manage.:reconfigure` (`manage.ex:53`) — the "live re-materialize from new template_data" verb. **Returns `{:error, :reconfigure_unsupported}` today** (`handle_reconfigure/2`, line 103): no Kind declares a per-Class `reconfigure/4` hook until the Template-Class registry lands (PR-5e). **Not demonstrable now.**
  - (b) `Ezagent.Behavior.ConfigEvolve.apply_config_delta` / `repoint_config` (`apps/ezagent_domain_identity/lib/ezagent/behavior/config_evolve.ex:92,107`) — **real, gated by the agent's manage-cap** (`required_caps/0` line 144 → `cap(:agent, Manage, :any)`). The Agent Kind declares `Behavior.ConfigEvolve` in its `base_behaviors` (`apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex:108`). **BUT** it mutates a *layered config cascade* (`layer`/`workspace_uri`/`subject_uri`/`key`/`patch`, durable in `ConfigStore`, default key `advisor.behavior` user layer) — designed for the **socialware Turn-settled config evolution**, not for editing the create-form's flat author fields (`name`/`cwd`). It enforces `assert_subject_self` (an agent may only evolve ITSELF). It can demonstrably change *a config-layer value*, but whether "modify an agent definition" in this UI means "patch the user config layer" is a product call for Allen.

**The contract field model** (`AgentManifest`, `agent_manifest.ex:27`): `name`, `soul`, `skills`, `tools`, `caps`, `lifecycle`, `executor`. Forbidden author fields (rejected on load): `flavor`, `derived_config`, `compiled_config` (line 36) — derived/compiled config is read-only and generated by `flavor.compile` (the detail page already states this).

---

## 4. Design & phased plan (review status: DRAFT, NOT codex-reviewed)

Approach: extend the existing #905 surface with the U and D verbs, wiring each through the §3 domain primitive, following the #905 `dispatch_agent_create` + `push_*_error` no-silent-drop pattern. Each phase is one PR-sized unit on the task branch.

- **Phase 0 — confirm the Update primitive (DISCUSS-FIRST, §9 Q1).** Do not write U code until Allen picks (a) `Manage.:reconfigure` (blocked → defer U), (b) `ConfigEvolve.apply_config_delta` on the user config layer, or (c) extend `create_agent`/add a focused agent-definition update action (touches domain ⇒ discuss-first, possibly defer to a sibling). This is the decision #904 lacked.
- **Phase 1 — Read/List hardening (build-now).** Verify `agent_detail` + `agents_table` reflect *live* status (the #905 re-dispatch note flagged `Phase/Flavor/Bridge: unknown` not parsing live status — confirm it's fixed; if not, fix it here). Add a "Delete" affordance entry point on the detail page (button only; wired in Phase 3).
- **Phase 2 — Create hardening (build-now).** Confirm the real create loop + failure surfacing (`cwd_required`, bad caps, grant failure, authz) per #905; add an explicit regression test that a created agent **appears in `agents_table`** (the C acceptance point in §5).
- **Phase 3 — Delete (build-now, after Phase 1 button).** New `world:dispatch` clause `agents.delete` → `dispatch_agent_delete/2` → `Ezagent.Invocation.dispatch` of `Manage.:delete` on the agent URI with `ctx.caps = current_caps` (the creator manage-cap). Confirm-dialog before destroy. On success, navigate to `/identities/agents` and re-list. Surface `error:` on cap denial (no silent drop).
- **Phase 4 — Update (build only after Q1 confirmed).** Wire the confirmed primitive from Phase 0. If (b): an "Edit config" form on the detail page that submits a `{layer, key, patch}` delta → `ConfigEvolve.apply_config_delta` under the operator's manage-cap; the changed value must **persist across reload** (the U acceptance point, §5). If (a): mark Update **deferred** with the target (PR-5e) and ship C/R/D only.

---

## 5. Definition of Done — DEMONSTRABLE, pinned to backend state (NOT "tests pass", NOT a demo)

> **Anti-demo guardrail (read first).** #904 was satisfied by a rendered/populated form. **This DoD is NOT met by any UI that merely renders.** Every checkbox below requires evidence of **backend state changed by the operator's action** — and the evidence artifact is an **agent-browser screenshot** of the *post-mutation* state (plus, where the mutation is async, a backend lookup confirming it). If the only proof you have is "the form looked right" or "the button is wired to a handler," it is **NOT done**.

For each verb, the **exact UI action**, the **observable result**, and the **evidence artifact**:

- [ ] **CREATE.** At `/identities/agents/new`, fill flavor=`echo`, a fresh name, (cwd if required), submit. **Result:** redirect to the new agent's detail page **AND** the new agent appears as a row in the `agents_table` list at `/identities/agents` on reload (not just "form submitted / redirected"). **Evidence:** agent-browser screenshot of `/identities/agents` showing the new agent's row, with its URI visible. *Also* a second create with flavor=`cc` + a missing required cwd showing the **explicit `cwd_required` error** rendered in the form (no silent drop).
- [ ] **READ / VIEW.** Open the created agent's detail page. **Result:** labeled contract fields (Phase / Flavor / project_cwd / config_dir / Template / Bridge) show **live** values (not literal `unknown`/`—` for a live agent) **AND** the Granted caps list shows the minted creator manage-cap. **Evidence:** agent-browser screenshot of the detail page with live values + the manage-cap chip visible.
- [ ] **UPDATE** *(only if §9 Q1 resolves to a demonstrable primitive — else this row is replaced by a "deferred to <target>" note, see §6).** Edit the confirmed editable field/config from the detail page; submit. **Result:** the changed value is read back from the backend and **persists across a full page reload** (re-fetch from `ConfigStore`/the slice, not an in-form echo). **Evidence:** two agent-browser screenshots — the new value shown *after reload* — plus a backend read (CLI / `iex` lookup of the config pointer) confirming the durable value matches.
- [ ] **DELETE.** From the detail page, click Delete, confirm. **Result:** the agent is **gone from `agents_table` on reload** **AND** the **Kind process is actually terminated** (`Manage.:delete` schedules a *detached, async* `Lifecycle.destroy` — a vanished row alone is NOT proof). **Evidence:** agent-browser screenshot of `/identities/agents` **without** the deleted agent + a backend confirmation that the Kind is gone (`KindRegistry.lookup/1` returns not-found, or `mix ezagent` shows it absent). **Also** a delete attempt by a caller **without** the manage-cap showing the **cap-denial error** (no silent success).
- [ ] All gates green: `arch.scan`, `doc.scan`, `uri_query.scan`, `check_invariants`, `format`, `test`, `:ezagent_plugin_check`.
- [ ] The work's own **invariant/regression test(s):** a test that **fails if a mutation is stubbed** — e.g. create-then-list asserts the URI is in `list_entities`; delete-then-lookup asserts `KindRegistry.lookup` is not-found; (if U built) apply-delta-then-reread asserts the durable pointer advanced. These tests are the structural anti-demo gate: a demo/stub fails them.

---

## 6. Discuss-first vs Deferred (both explicit)

**Discuss-first (do NOT build before lead-confirm):**
- **The Update primitive (§9 Q1)** — load-bearing; `Manage.:reconfigure` (unsupported today), `ConfigEvolve.apply_config_delta` (real but layered-config-shaped), or a new focused update action (touches domain). Resolve before writing any U code.
- Any change to `AgentManifest` schema, `create_agent/3`'s accepted fields (to enable soul/skills/tools/executor — the #905 "Pending backend approval" set), CapBAC grant sites, or `Behavior.Manage`/`ConfigEvolve` semantics. All touch domain/core.
- Adding a new world top-level route family or nav change (this slice is additive only).

**Deferred siblings (flagged + targeted — explicitly OUT of this handoff):**
- **Orchestrator console** (session members / roles / live team management) → deferred sibling of #84; see `docs/superpowers/handoffs/2026-06-22-agent-console-in-world-handoff.md` §2 LIVE-CapBAC + §3.
- **Routing UI** (rule-sets / `{from:X}→Y` chains / legends / prompt-templates) and **session migration** (`migrate_session`) → deferred siblings (same #84 handoff §2 LIVE-WORKFLOW).
- **Author-field create** (soul/skills/tools/lifecycle/executor extras, fork-from-parent) → gated on the `create_agent` extension (Allen's call; #905 §5 E1–E4) — keep as the read-only Contract-coverage list until approved.
- **AgentTemplate authoring** (create/edit/delete the cold `template://agent/<name>` Kind — `agent_template.ex`; `AgentTemplate.fork`/caller-threaded `create/3`) → a deferred sibling on the COLD/template side (see the original #84 handoff §2 COLD). Distinct surface from this runtime-instance CRUD; editing a template does not modify spawned instances. Not in this slice.
- **Update via `Manage.:reconfigure`** → if Q1 picks (a), Update defers to **PR-5e** (Template-Class registry + per-Class `reconfigure/4` hook). Flag it; do not stub it.

**Never deferred here:** the Q1 load-bearing decision; C/R/D wiring that is solvable now; the gates; the per-mutation cap requirement (each mutation MUST be authorized by the real cap, never a synthesized one); the demonstrable-DoD evidence.

**Cap / authority per mutation (no-unowned-caps):**
- Create → caller's `current_caps` (workspace create authority); on success the creator manage-cap is minted (`creator_grant.ex:20`).
- Read → list/detail are read surfaces (granted-caps slice visibility).
- Update → the agent's **manage-cap** (`cap(:agent, Manage, :any)`) authorizes `apply_config_delta`/`repoint_config` (`config_evolve.ex:144`); `assert_subject_self` binds the subject to the agent.
- Delete → the agent's **manage-cap** (`cap(:any, Manage, :any)` per `manage.ex:65`). Fail-closed on absence; surface the denial.

---

## 7. Conflict-avoidance (owned surfaces)

This task **owns** the world identities/agents CRUD surface:
- `apps/ezagent_plugin_world/assets/src/components/Identities.tsx` (the agent components only).
- `apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex` (additive state builders).
- `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex` (additive `world:dispatch` clauses + `dispatch_agent_*` helpers).
- `apps/ezagent_plugin_world/lib/ezagent/world/routes.ex` (only if a new agent sub-route is needed).
- Tests under `apps/ezagent_plugin_world/test/ezagent/world/`.

Do **not** edit hello-page rendering, session routing UI, or the conversation/chat surface. **Follow `docs/guide/world-coordination.md`:** add a row to its in-flight registry; coordinate the shared additive files + the `world_live.ex` route/dispatch clause with the active world-dev; keep the components shadcn/`@json-render`-shaped (a down-payment on world→hello).

---

## 8. Merge model

PRs merge into the task branch **`agent-console-crud`** (never `main`). Keep the branch **rebased on `main`**. When the §5 DoD is met (every CRUD evidence artifact + gates + the anti-stub regression tests), **the lead (Allen) merges `agent-console-crud` → `main`** via `close`. The lead is the only path to `main`. Codex adversarial-review the design (Phase 0) and each PR before merge.

---

## 9. Gates, file/LOC estimate, open questions for Allen

**Gates:** `arch.scan`, `doc.scan`, `uri_query.scan`, `check_invariants`, `format`, `test`, `:ezagent_plugin_check` + the anti-stub regression tests (§5). Load skills `ezagent-developer` (+ `ezagent-session-orchestrator` for U/D).

**File / LOC estimate (additive):** `Identities.tsx` +~120 LOC (edit-config form + delete button + confirm dialog); `world_live.ex` +~80 LOC (`agents.delete`, `agents.update` clauses + `dispatch_*` + `push_*_error`); `identity_data.ex` +~40 LOC (edit-form state, live-status hardening); tests +~150 LOC. No new files expected unless a sub-route is added.

**Open questions for Allen (resolve in discussion — do not guess):**
1. **(LOAD-BEARING) What is "Modify an agent" in this UI?** Three real options with different blast radius: **(a)** `Manage.:reconfigure` — semantically right but `reconfigure_unsupported` until PR-5e ⇒ U defers; **(b)** `ConfigEvolve.apply_config_delta` — works today, gated by the manage-cap, but mutates a **layered config cascade** (e.g. `advisor.behavior` user layer), not the flat create-form fields — is "edit the user config layer" the intended Modify? **(c)** extend `create_agent`/add a focused agent-definition update action (touches domain, possibly a sibling task). **Pick one before U is built.**
2. **Delete lifecycle gate.** `Manage.:delete` tears the Kind down via detached `Lifecycle.destroy`. Is a plain manage-cap-holder confirm-dialog sufficient, or does Allen want an additional gate (e.g. block delete while the agent is bound to a live session)? I did **not** find an existing destroy-gate beyond the manage-cap — confirm none is required.
3. **Create author fields.** Keep soul/skills/tools/lifecycle/executor as the read-only "Contract coverage / Pending backend approval" list (status quo from #905), or does this re-scope authorize the `create_agent` extension (E1–E4) so the create form accepts them? Default assumption: **keep read-only** (extension is a separate Allen-gated decision).
4. **Live-status parsing.** The #905 re-dispatch note flagged the detail page showing `Phase/Flavor/Bridge: unknown` (not parsing live status). Is that already fixed on `main` (so R is just verification), or is fixing it in-scope for Phase 1 here?

---

### Appendix A — exactly what #905 already provides vs. the delta this task adds

**#905 (merged, `63e493c4`) ALREADY PROVIDES — do NOT rebuild:**
- **Create (C):** `AgentNewForm` (`Identities.tsx:325`) with flavor / name / cwd / requested-caps / with-PTY; client validation; URI preview; real submit → `agents.create` → `dispatch_agent_create` → `Workspace.create_agent/3` + `grant_initial_caps/3`; explicit error surfacing (`push_agent_create_error`, no silent drop); flavor-differentiated required-cwd.
- **Read/List (R):** `AgentDetail` (`Identities.tsx:283`) labeled fields (Phase/Flavor/project_cwd/config_dir/Template/Bridge) + Granted caps chips + the "derived/compiled config is read-only" note; `agents_table` list via `identity_data.ex` `list_entities/2`; `IdentityCard` rows; `AgentApiKeys` + `AgentExtensions` sub-tabs; routes `/identities/agents`, `/agents/new`, `/agents/:uri`, `…/caps|api-keys|extensions`.
- **Contract framing:** `ContractCoverage` read-only list marking soul/skills/tools/lifecycle/executor-extras/fork as "Pending backend approval"/"Deferred" (the honest gap, no parallel storage).

**THE DELTA THIS TASK ADDS:**
- **Update (U):** *new* — currently NO update affordance exists; the contract Update primitive must be confirmed (§9 Q1) then wired (edit-config form + `agents.update` dispatch clause + durable-persist DoD).
- **Delete (D):** *new* — currently NO delete affordance exists; wire `Manage.:delete` (delete button + confirm dialog + `agents.delete` dispatch clause + async-destroy-confirmed DoD).
- **Demonstrable hardening of C/R:** the anti-stub regression tests (create→appears-in-list; delete→lookup-not-found) and live-status verification — the structural gate #904 lacked.

*All claims above were verified against the files cited (read 2026-06-24). Where a thing was not found (no destroy-gate beyond the manage-cap; `reconfigure` hooks not yet present), the handoff says so rather than inventing.*
