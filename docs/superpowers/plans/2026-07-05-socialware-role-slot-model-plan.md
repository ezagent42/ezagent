# Socialware role-slot model — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a socialware `%Definition{}` declare participants by ROLE only (recipe name + flavor, or an open human slot) — never by instance URI — so the credential-theft template-declaration vector is structurally impossible; and move `role_name` to the (entity × session) membership edge so an agent is role-agnostic and can hold different roles in different sessions.

**Architecture:** Gate-driven migration. Two fail-closed arch gates start RED and enumerate the exhaustive worklist; each task drives part of the red to green. **P1** (this plan, detailed) = the declaration + security core: `Definition.roles`, retire both `members` layers, receivers role-only, `source_template_uri`→recipe, owner=installer, operator-caller reuse, **Gate A** green. **P2/P3** outlined at the end. P1 alone closes the credential vector and is independently shippable.

**Tech Stack:** Elixir umbrella (`apps/ezagent_domain_session`, `apps/ezagent_domain_agent`, `apps/ezagent_core`), ExUnit, `EzagentCore.DataCase`, socialware `%Definition{}` (ConfigObject-persisted), `RecipeRegistry`/`RecipeMaterializer`, the #161 C admission gate (`Membership.do_join/5`).

**Spec:** `docs/superpowers/specs/2026-07-05-socialware-role-slot-model-design.md` (rev3, codex SOUND).

## Global Constraints

- **Elixir edits via the Edit tool only — NEVER `cat >>`** (appends after module end → SyntaxError). [[feedback_no_cat_append_elixir]]
- **Run tests with `mix`** (not `python`); precommit gate + `mix ezagent.check_invariants` + `mix ezagent.uri_query.scan` must pass before any push. [[feedback_use_uv_not_python]] [[feedback_run_check_invariants_gate]]
- **Load `Skill: ezagent-developer` + `elixir-phoenix-helper`** before touching apps code. [[feedback_subagent_must_load_project_skills]]
- **Pre-prod, no back-compat for `members`**: this repo has no published prod definitions carrying direct-URI members (verified on `origin/main`); do NOT add a compatibility shim — delete the old surfaces (let-it-crash). [[feedback_let_it_crash_no_workarounds]]
- **Every distinct behavior gets a test; zero new failures proven against a clean base.** [[feedback_zero_new_failures_baseline_proof]]
- **The credential invariant is the gate:** completion = Gate A green (no participant instance URI in a socialware declaration) + the §14.5(A)-style acceptance stays green. [[feedback_completion_requires_invariant_test]]

---

## File structure (P1)

- `apps/ezagent_core/test/architecture/socialware_declaration_uri_gate_test.exs` — **Gate A** (NEW): no participant instance URI in a `%Definition{}` / its rendered `SessionTemplate` content. Self-contained AST + decoded-JSON scan, teeth test. Model on `member_cap_grant_seam_test.exs`.
- `apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex` — add `roles`, retire `members`; `Definition.new/1` validates `roles`; drop `owner_policy: :fixed` (keep default `:installer`).
- `apps/ezagent_domain_session/lib/ezagent/socialware/conformance.ex` — validate `roles` (recipe resolves, role_name unique, flavor known); receivers `{:role,name}`-only; drop `members` reads.
- `apps/ezagent_domain_session/lib/ezagent/socialware/definition_editor.ex` — compose `roles`; drop the `members` legacy-override (`:308`); `member_declarations_for_template/2` returns role slots.
- `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/template_team.ex` — delete the direct-`uri` `ensure_member_present` clause (`:109`); provision from role slots (recipe) only.
- `apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex` — the socialware-render `members` field becomes role-slot-derived; drop `uri`/`source_template_uri` on that path.
- `apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex` + `.../session_creator.ex` — owner = installer (already default `:installer`); reject/remove `:fixed`.
- `apps/ezagent_plugin_kb/test/e2e/socialware_p10_codex_gate_test.exs` — migrate the bot fixture (`members:[%{uri}]`) → `roles:[%{role_name:"bot", recipe, flavor}]`.
- Tests co-located in `apps/ezagent_domain_session/test/ezagent/socialware/` (mirror `definition_test.exs` / `conformance_test.exs`).

---

## Task 1: Gate A — the RED worklist anchor

**Files:**
- Create: `apps/ezagent_core/test/architecture/socialware_declaration_uri_gate_test.exs`

**Interfaces:**
- Produces: an arch test `no participant instance URI in a socialware declaration` that scans `%Definition{}` construction sites + persisted JSON string values in role/member/receiver positions for `entity://…/agent|user/…`. Starts RED (today's `members`/`uri`/URI-receiver sites) — the exhaustive worklist for Tasks 2-7.

- [ ] **Step 1: Write the gate + teeth test** (model on `member_cap_grant_seam_test.exs` — self-contained `Path.wildcard` + AST/string scan). Scan `apps/*/lib` socialware definition/render modules + a synthetic decoded-JSON fixture. The main assertion allowlists NOTHING (target state); the teeth test plants a `%{role_name, uri: "entity://ws/agent/x"}` member + an `entity://…/agent/…` receiver string and asserts the scanner flags both.
- [ ] **Step 2: Run it — expect RED on the real tree** (`members`/`uri` in `definition.ex`/`template_team.ex`, URI receivers in `conformance.ex`). Capture the offender list — this is the Task 2-7 worklist. Run: `mix test apps/ezagent_core/test/architecture/socialware_declaration_uri_gate_test.exs`. Expected: teeth test PASS, main test FAIL listing the current URI sites.

  > **Scope (codex plan-review LOW):** Gate A is a STATIC scan of repo-authored definitions, rendered maps, source literals, and decoded-JSON fixtures. It does NOT scan already-persisted DB `ConfigObject` rows — those are out of scope (pre-prod: the design mandates wipe/reseed, no back-compat). State this in the test moduledoc. The teeth test MUST exercise the same recursive decoded-map scanner the main assertion uses.
- [ ] **Step 3: Commit** (`test(socialware): Gate A — no participant instance URI in a definition (starts red = worklist)`).

## Task 2: `Definition.roles` schema + retire `members`

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex` (`defstruct :12`, `@type :56`, `new/1 :77`, `body/1 :136`)
- Test: `apps/ezagent_domain_session/test/ezagent/socialware/definition_test.exs`

**Interfaces:**
- Produces: `%Definition{roles: [role_slot]}` where `role_slot :: %{role_name: String.t(), fill: :agent, recipe: String.t(), flavor: String.t()} | %{role_name: String.t(), fill: :human}`. `agents`/`members` fields REMOVED. `Definition.new/1` returns `{:error, {:socialware_definition_declares_instance_uri, …}}` if any role slot / receiver carries an `entity://…/agent|user/…`.

- [ ] **Step 1: Write failing tests** — `Definition.new(%{roles: [%{role_name: "bot", fill: :agent, recipe: "echo", flavor: "curl"}], …})` → `{:ok, %Definition{roles: [...]}}`; a slot with `%{role_name, uri: "entity://ws/agent/x"}` (no such field) or a receiver `"entity://ws/agent/x"` → `{:error, {:socialware_definition_declares_instance_uri, _}}`; a `%{role_name, fill: :human}` slot → ok.
- [ ] **Step 2: Run → fail** (`roles` unknown key). `mix test apps/ezagent_domain_session/test/ezagent/socialware/definition_test.exs`.
- [ ] **Step 3: Implement** — replace `agents:`/`members:` in `defstruct`/`@type` with `roles: []`; `new/1` parses+validates `roles` (each slot: non-empty `role_name`; `fill: :agent` requires non-empty `recipe` + known `flavor`; `fill: :human` requires only `role_name`; reject any string value matching `~r{^entity://[^/]+/(agent|user)/}`); `body/1` serializes `roles`.
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Commit** (`feat(socialware): Definition.roles replaces agents+members — recipe/human slots, no instance URI`).

## Task 3: Conformance validates `roles`; receivers role-only

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/socialware/conformance.ex` (`check_agent_recipes` `:148`, `check_role_name_uniqueness`, `declared_role_names` `:288`, `check_routing_receivers` `:266`)
- Test: `apps/ezagent_domain_session/test/ezagent/socialware/conformance_test.exs`

**Interfaces:**
- Consumes: `Definition.roles` (Task 2).
- Produces: `Conformance.check/2` passes only when every agent slot's `recipe` resolves via `RecipeRegistry.lookup/2`, role_names are unique across `roles`, every routing receiver is `{:role, name}` referencing a declared role_name, and NO receiver is an instance URI.

- [ ] **Step 1: Write failing tests** — a def with an agent slot whose recipe is unregistered → `{:error, {:unknown_agent_recipe, _}}`; two slots with the same `role_name` → `{:error, {:duplicate_role_name, _}}`; a routing rule with a receiver `"entity://ws/agent/x"` → `{:error, {:socialware_receiver_not_a_role, _}}`; a rule with receiver `{:role, "bot"}` where `bot` is a declared slot → `:ok`.
- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement** — repoint `check_agent_recipes`/`check_role_name_uniqueness`/`declared_role_names` to read `roles` (agent slots for recipe checks; all slots for role names); rewrite `check_routing_receivers` to require each receiver decode to `{:role, name}` with `name ∈ declared_role_names`, rejecting URI/`{:uri,_}` receivers.
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Commit** (`feat(socialware): conformance validates roles + role-only routing receivers`).

## Task 4: `DefinitionEditor` composes roles; drop the members override

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/socialware/definition_editor.ex` (`member_declarations_for_template/2` `:76`, compose `:298-325`, `:265` incomplete-check, `:308` legacy override)
- Test: `apps/ezagent_domain_session/test/ezagent/socialware/definition_editor_authored_pin_test.exs` (extend)

**Interfaces:**
- Produces: `DefinitionEditor.role_slots_for_template/2 :: {:ok, [role_slot]}` (replaces `member_declarations_for_template/2`); the compose acc merges `roles` (not `agents`+`members`); the "incomplete" check fires on empty `roles`.

- [ ] **Step 1: Write failing test** — `role_slots_for_template(content, ws)` returns the installed defs' merged `roles`; a def with empty `roles` → `{:error, {:incomplete_socialware_definition, :roles}}`; assert NO code path reads a `members` `uri`.
- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement** — rename/rewrite `member_declarations_for_template` → `role_slots_for_template` returning `config.roles`; delete the `legacy_members`/`:308` override and the `acc.members ++ …` merge; move the empty-check to `roles`.
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Commit** (`refactor(socialware): definition_editor composes roles, drops members override`).

## Task 5: Materialize from role slots (fresh) + retire the direct-uri clause

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex` — **THE real socialware recipe-agent materializer** (`materialize_definition_agents/4` `:65-96`, called from `TemplateTeam.materialize_template_team/4` `:29`). Uses role-derived URIs + `RecipeMaterializer.create_agent_from_recipe/1` today; repoint to consume `roles` (agent slots) with **uuid** URIs. (codex plan-review HIGH — the plan MUST update this, not only template_team.)
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/template_team.ex` (`provision_declared_member` `:48`, `ensure_member_present` `:76`/`:109` direct-uri clause, `materialize_template_team` `:29`)
- Modify: `apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex` — the persisted-content **key list at `:764`** (NOT the `:42-47` moduledoc, codex plan-review MED); drop `uri`/`source_template_uri` on the socialware-render path.
- Test: `apps/ezagent_domain_session/test/integration/session_template_materialize_test.exs` (extend)

**Interfaces:**
- Consumes: role slots (Task 4).
- Produces: `DefinitionAgents.materialize_definition_agents/4` + `TemplateTeam.provision_role_slot/4` — for an `:agent` slot, materialize a FRESH agent via `RecipeMaterializer.create_agent_from_recipe/1` (recipe+flavor) with a **uuid** `agent_uri` (NOT role-derived), returning `{:ok, agent_uri, %{role_name: slot.role_name}}`. The direct-`uri` `ensure_member_present` clause (`:109`) is DELETED.

- [ ] **Step 1: Write failing test** — a session created from a def with an agent role slot provisions a FRESH uuid agent bound to the slot's `role_name`; assert the provisioned agent URI is NOT role-derived (no `<role>-` segment) and no member declaration carried a `uri`.
- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement** — update `DefinitionAgents.materialize_definition_agents/4` to iterate `roles` agent slots (uuid URIs, `create_agent_from_recipe`); add `TemplateTeam.provision_role_slot/4`; delete `ensure_member_present`'s direct-`uri` clause; repoint `RouteProvisioner`/`Materializer` to role slots; drop `uri`/`source_template_uri` on the socialware-render key list (`session_template.ex:764`).
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Commit** (`feat(socialware): materialize agents from role slots (fresh recipe), retire direct-uri members`).

## Task 6: `source_template_uri` → recipe; owner = installer

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex` — drop `:fixed` from `owner_policy/1` (`:70`) AND rewrite `validate_anon_owner/2` (`:396`, which today REQUIRES `:fixed` for `web_anon_access: true` — codex plan-review HIGH) to require **installer/operator ownership** semantics instead of a baked owner URI.
- Modify: `apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex` — the **built-in socialware seed declares a fixed admin owner (`:290`)** (codex plan-review HIGH); change it to installer/owner-at-materialize (admin-as-installer for the boot seed).
- Modify: `apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex` (`owner_uri_for_template` `:103`)
- Modify: `orchestrator/tools.ex` (`source_agent_template_uri` real uses `:137`/`:167`/`:207` — NOT the `:115` doc, codex plan-review MED) + `orchestrator/tools/member_template.ex` (real consumers `:102`/`:253`/`:633` — NOT the `:622` comment).
- Test: `apps/ezagent_domain_session/test/ezagent/socialware/definition_test.exs` + `installation_test.exs`

**Interfaces:**
- Produces: `owner_policy` accepts only `%{type: :installer}` (default kept); `Definition.new/1` rejects `%{type: :fixed, owner_uri: …}` → `{:error, {:socialware_definition_declares_owner_uri, _}}`; `validate_anon_owner` passes when the installer is a non-anon principal (no baked owner URI). `Installation.owner_uri_for_template/3` returns the INSTALLER's uri. `source_agent_template_uri` consumers repoint to recipe.

- [ ] **Step 1: Write failing tests** — `Definition.new(%{owner_policy: %{type: :fixed, owner_uri: "entity://ws/user/x"}, …})` → `{:error, {:socialware_definition_declares_owner_uri, _}}`; a `web_anon_access: true` def with NO fixed owner but a non-anon installer → `:ok` (installer owns); `Installation.owner_uri_for_template/3` returns the INSTALLER's uri; the built-in socialware seed publishes without a fixed owner URI.
- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement** — remove the `:fixed` branch; rewrite `validate_anon_owner` to require a non-anon installer (not a baked URI); update the `definition_registry` boot seed to installer-owned (admin-as-installer); `owner_uri_for_template` derives from the installer/caller; repoint the two `source_agent_template_uri` consumers to recipe.
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Commit** (`feat(socialware): owner=installer (drop owner_policy.fixed URI); source_template→recipe`).

## Task 7: Operator-caller reuse path (bind an existing owned agent)

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/participants.ex` (the caller-preserving join, `:9-16`/`:66-81`)
- Test: `apps/ezagent_domain_session/test/integration/` (new: `socialware_reuse_bind_test.exs`)

**Interfaces:**
- Produces: a reuse-bind entrypoint that joins an operator-owned existing agent to a session slot via an **operator-caller** `session.join` (`ctx.caller = operator`), setting `role_name` on the edge — routed through `Membership.do_join/5` so the #161 C admission gate fires. NEVER the admin materialization helpers.

- [ ] **Step 1: Write failing tests** — an operator reuse-binds their OWN recipe-agent to a slot → mounts, edge carries `role_name`; an operator reuse-binds an agent they do NOT `manages?` → PENDS (`:pending_members`, no member-cap) — proving the operator-caller join hits the #161 C gate. (Non-system workspace, per `admission_gate_test` moduledoc.)
- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement** — the reuse entrypoint dispatches `session.join` with `caller: operator` + facets `%{role_name}` through the participant path; assert it does NOT call `DefinitionAgents`/`system_mediated_ctx`.
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Commit** (`feat(socialware): operator-caller reuse-bind — foreign agent pends via #161 C`).

## Task 8: Migrate the P10 E2E fixture + Gate A → green

**Files:**
- Modify: `apps/ezagent_plugin_kb/test/e2e/socialware_p10_codex_gate_test.exs` (`author_socialware_template` `:337` members; `:77` assertion)
- Modify: `apps/ezagent_core/test/architecture/socialware_declaration_uri_gate_test.exs` (Task 1 — now expected GREEN)

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Seed a concrete non-passive test recipe** (codex plan-review BLOCKER — there is NO `ezagent_plugin_echo` in this checkout, `curl` is a FLAVOR not a recipe, and the `kb` recipe is `passive: true` so it CANNOT be a joined bot member: `session.ex:720` rejects passive actors). In the E2E `setup`, register a minimal **non-passive** recipe via `RecipeRegistry.seed_role_if_absent(%{name: "p10-bot", requested_caps: […], passive: false, config: %{…}})` under a real flavor whose template class exists (`AgentFlavorRegistry` — use `"curl"`). Verify `RecipeRegistry.lookup(ws, "p10-bot")` resolves + the flavor's template class is registered.
- [ ] **Step 1b: Migrate the fixture** — the bot member `%{"role_name" => "bot", "uri" => …}` → an agent role slot `%{role_name: "bot", fill: :agent, recipe: "p10-bot", flavor: "curl"}`; the bot becomes a FRESH recipe-materialized agent assigned `bot` on its edge (drop the pre-spawned `bot_uri` + its `spawn_agent`); update the `:77` assertion + `role_member_uri`-based checks. Also drop the fixed-owner data the P10 form authors (`:369`) — the session owner is the installer/admin_ctx (codex plan-review HIGH).
- [ ] **Step 2: Run the P10 E2E → pass.** `mix test apps/ezagent_plugin_kb/test/e2e/socialware_p10_codex_gate_test.exs`.
- [ ] **Step 3: Run Gate A → now GREEN** (all URI sites retired). `mix test apps/ezagent_core/test/architecture/socialware_declaration_uri_gate_test.exs`. Expected: PASS (teeth still trips on the planted fixture).
- [ ] **Step 4: Full gate** — `mix ezagent.check_invariants` + `mix ezagent.uri_query.scan` + `mix test apps/ezagent_core/test/architecture apps/ezagent_core/test/invariants` + the 6 flavor plugins + `apps/ezagent_domain_session/test`. All green. [[feedback_run_check_invariants_gate]]
- [ ] **Step 5: Commit** (`test(socialware): P10 E2E via role slots; Gate A green — vector structurally closed`).

## Task 9: P1 acceptance — the vector is structurally closed

**Files:**
- Create: `apps/ezagent_domain_session/test/ezagent/socialware/role_slot_acceptance_test.exs`

- [ ] **Step 1: Write the acceptance test** — (a) authoring/publishing a definition whose `roles`/receivers name a foreign agent instance URI is rejected at `Definition.new/1` (the field does not exist / the URI-shape check fires) — proving structural closure at the schema layer, not a runtime gate; (b) a legit def with an agent recipe slot + a human slot passes conformance; (c) reuse-bind of a foreign agent PENDS (#161 C).
- [ ] **Step 2: Run → pass.**
- [ ] **Step 3: Commit** (`test(socialware): P1 acceptance — no instance URI representable, reuse-bind gated`).
- [ ] **Step 4: `/codex:adversarial-review`** the P1 branch (static). Address findings; re-gate.

---

## P2 (outline) — role de-bake, one-shot (`Gate B`)

Add **Gate B** (`apps/ezagent_core/test/architecture/agent_session_role_gate_test.exs`): no read/write of a global agent SESSION role (`AgentRoleAttributes` role field, `planned_agent_uri` role segment, sandbox-slice `:role`, `Recipe.Compose` `role:`, `RoleStep` markers, `AgentRoleResolver`/`UriQueryResolvers` agent→role) — **carveout:** recording which *recipe* an agent came from (provenance) is allowed. Starts RED = the worklist. Then task-by-task: (1) `planned_agent_uri` → uuid (`session_agent_materialize.ex`); (2) stop writing role in `recipe_materializer`/`sandbox`/`recipe/compose`/`role_step`; (3) repoint `AgentRoleResolver`, `UriQueryResolvers`, kanban `shared.ex`, world `kanban_data.ex`, `AgentCreate` role threading to the session edge (or a session-scoped resolver); (4) recipe/session provenance → stored attribute. **Acceptance:** one agent joined to two sessions holds distinct `role_name`s; `{:role,advisor}`@A and `{:role,reviewer}`@B resolve to the same agent; agent URI has no role segment; Gate B green.

## P3 (outline) — human role slots + operator materialize UI

`fill: :human` runtime assignment (an operator assigns a joined human an `entity://…/user/…` `role_name` on the edge; user-URI only; NEVER persisted back to `%Definition{}`). Operator materialize wizard (World console): per agent slot choose flavor (default from slot) + Fresh/Reuse (Reuse lists the operator's `manages?`-owned recipe-matching agents); per human slot an "assign role" control gated to the operator. **Acceptance:** operator materializes an app choosing fresh/reuse + flavor per slot; assigns a human to a role; reuse of a foreign agent PENDS.

---

## Self-review

- **Spec coverage:** §4.1 roles→T2/T3; §4.2 materialize+reuse→T5/T7; §4.3 uuid→P2; §4.4 edge role→P2; §5 invariant→T1/T2/T6/T9; §7 migration→T2-T6/T8; §8 Gate A→T1/T8, Gate B→P2; §9 P1/P2/P3→plan structure. Covered.
- **Placeholder scan:** the recipe name for the P10 bot fixture (T8) is "an echo/curl recipe" — the implementer picks the concrete registered recipe (`RecipeRegistry` has the seeded set); not a placeholder in the plan sense (the step names the source of truth).
- **Type consistency:** `role_slot` shape identical across T2/T3/T4/T5; `role_slots_for_template/2` (T4) consumed by T5; `provision_role_slot/4` (T5) is the fresh path, reuse entrypoint (T7) is separate. Consistent.
