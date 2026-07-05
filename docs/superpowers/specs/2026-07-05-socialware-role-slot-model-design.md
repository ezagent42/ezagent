# Socialware role-slot model — declare roles, never instances

**Date:** 2026-07-05
**Status:** DESIGN rev3 (brainstormed with Allen 2026-07-05; codex rev1 NOT-SOUND → rev2 folded findings → codex rev2 NOT-SOUND/converging → rev3 resolves the two design questions + demotes precision findings to implementation constraints; pending final coherence codex + user review)
**Motivating thread:** the #161 C over-fire fix's codex NO-SHIP — a socialware definition can name an agent by direct URI, so a system-mediated mount would spend that agent's owner's credential. Allen chose to close it *structurally* (a definition cannot name a participant instance) rather than add a per-declaration author-ownership gate.

---

## 1. Problems (three, tangled)

1. **Credential-theft template-declaration vector (SECURITY — the trigger).** A `%Definition{}`'s `members: [map()]` (`definition.ex:13`) accepts a raw map with a direct agent-instance `uri` (`template_team.ex:110`); nothing checks the author owns it. Co-tenant B publishes/installs a definition naming A's credentialed agent by URI → the session system-mediated-mounts it (`RouteProvisioner`/`Materializer`, admin-caller) → A's agent runs B's messages → spends A's OAuth credential. #161 C closes the *direct* `session.join` pull but exempts *declared* members. **Two more surfaces feed the same vector:** the lower-level `SessionTemplate` content that a Definition renders into ALSO carries `members`/`uri`/`source_template_uri` (`entity/session_template.ex:42-47`, joined at `:138-140`, with a legacy-override path `definition_editor.ex:308`) (codex rev1 BLOCKER); and definition **routing receivers** may be explicit instance URIs (`conformance.ex:266` accepts URI-parseable receivers, `resolver.ex:412` expands them) (codex rev1 HIGH).

2. **Role is baked into the agent globally (ARCHITECTURE).** Role is written durably ONTO the agent in many places: the materialized URI `entity://ws/agent/<role>-<disc>` (`session_agent_materialize.ex:116/239`), `AgentRoleAttributes.put/2` via `RecipeMaterializer.record_launch_attributes/3` (`recipe_materializer.ex:114/201`), the `:role` in the agent's sandbox slice (`sandbox.ex:51/222`), `Recipe.Compose` emitting `role: role.name` (`recipe/compose.ex:65`), `Workspace.AgentCreate.RoleStep` durable markers (`agent_create/role_step.ex:119/139`) — read back by `AgentRoleResolver` (`agent_role_resolver.ex:51`), `UriQueryResolvers` (`uri_query_resolvers.ex:220`), kanban (`shared.ex:94`), world (`kanban_data.ex:68`). So an agent has ONE global role → it cannot be `advisor` in A and `reviewer` in B. Role belongs to the (entity × session) relationship, not the agent (codex rev1/rev2 HIGH — larger blast radius than a URI change).

3. **`members` vs `agents` duality (CLARITY).** Two parallel agent-declaration fields: `agents: [%{recipe, role_name, flavor}]` (`definition.ex:11/27` — recipe-by-NAME, conformance-validated via `RecipeRegistry`, the clean form) AND `members: [map()]` (loose maps with a direct `uri`/`source_template_uri`). Both read by conformance/routing; `members` required non-empty (`definition_editor.ex:265`).

## 2. Principle (Allen)

> A socialware app declares *what kind* of participant it needs (a **role**, filled by a **recipe** for agents, or an open slot for humans) — never *which instance*. Like software declaring "I need a CPU with these capabilities," never "run on this physical CPU." **Humans too** — a role slot, never a named person. And **`role_name` lives on the (entity × session) membership edge**, session-managed, reassignable, uniform for humans and agents; the agent is role-agnostic and can be a member of *multiple* sessions with a *different* role in each.

## 3. Build unit — recipe NAME + flavor (RecipeRegistry), zero URI

From `recipe_materializer.ex:5`: **"a recipe owns sandbox content; flavor owns how that content is loaded."**

- **recipe** = a **RecipeRegistry** `recipe:<name>` entry — **flavor-free, role-free** sandbox content + caps. A NAME, pure data. Versioned by ConfigStore (immutable object + pointer + previous). RecipeRegistry is a broad, shared library (plugins seed their role recipes via `seed_role_if_absent`; the generic by-role materialization — dev-together/kanban/default-agent — consumes it) — it is KEPT, not deleted.
- **flavor** = `"cc"|"codex"|"curl"|"py"`, the loader.
- **AgentTemplate** = a recipe rendered under a flavor (recipe × flavor); a derived, URI-addressed artifact. **NOT referenced by socialware** — a socialware slot names `(recipe, flavor)` and composes the AgentTemplate content at materialize via `RecipeMaterializer.template_content/2`. (AgentTemplate's only extra over recipe-name+flavor is *fork lineage*, which socialware does not need — a "fork" is a new named recipe. So no AgentTemplate URI, no fork-parity gap.)

**Decision: an agent slot is `%{role_name, recipe: "<name>", flavor}` — a recipe NAME + a flavor, both strings, zero URI.** `flavor` is the AUTHOR's default in the slot; the **operator may override flavor per slot at materialize** (recipe is flavor-free by design, so the same recipe can run under a different flavor). `source_template_uri` member declarations convert to recipe-name slots (§7).

## 4. Target model

### 4.1 Declaration — `Definition.roles` (one field, zero instance URIs)

Collapse `agents` + `members` into ONE role-slot list. No field can hold a participant instance URI.

```
roles: [role_slot]
role_slot ::
  %{role_name, fill: :agent, recipe: String.t(), flavor: String.t()}   # recipe NAME + default flavor
  | %{role_name, fill: :human}                                         # open slot, filled at runtime
```

- `role_name` unique per definition (the session-model slot id + the `{:role, name}` routing receiver).
- `members` is **retired**: the `Definition.members` field AND the legacy `SessionTemplate` `members`/`uri`/`source_template_uri` content + `definition_editor.ex:308` override + the direct-`uri` clause in `TemplateTeam.ensure_member_present` (`template_team.ex:109`). The required-non-empty check moves to `roles`.
- **Routing receivers** in a definition are restricted to `{:role, name}`; an explicit agent/user instance-URI receiver is rejected at conformance (and by Gate A).

### 4.2 Materialization — operator decides per agent slot

When an **operator** materializes a definition into a session, per **agent slot** they choose (defaults from the slot):

- **flavor** — accept the author's default or override.
- **fill** — **Fresh** (build a new agent from `(recipe, flavor)`, §4.3, under system-mediated authority — safe: a brand-new agent the operator owns) OR **Reuse** (bind one of the operator's OWN existing agents of that recipe).
  - **Reuse MUST enter through an operator-caller `session.join`** (`ctx.caller = operator`), via the caller-preserving participant path (`orchestrator/tools/participants.ex` joins with caller/caps, not admin), NOT the admin-mediated declaration helpers (`definition_agents.ex:200`, `route_provisioner.ex:49`). Only an operator-caller join makes the #161 C admission gate fire — binding an agent the operator does not `manages?` then PENDS (owner approval). If reuse rode an admin helper it would be EXEMPT and reopen the vector (codex rev1/rev2 HIGH). The fresh path stays system-mediated (a new own agent — no foreign credential).

Either choice yields a **(agent × session) membership edge** carrying `role_name` (existing `Members.put_member_facets` facet). **Human slots** are not filled at materialize (§4.5).

### 4.3 Agent identity — role-agnostic, fresh uuid

A materialized agent's identity is `entity://<ws>/agent/<uuid>` — no role or session segment. `planned_agent_uri(role, …)` is removed. Recipe/session provenance moves to a stored attribute (mirrors flavor-as-stored-attribute, #931), queried where needed — never in the URI, never a global role.

### 4.4 `role_name` — the (entity × session) edge, only

`role_name` lives ONLY on the membership edge (`Members` meta facet; per-session uniqueness already enforced by `role_name_conflict/3`). Routing `{:role, name}` resolves against the session's current edges. No agent URI/config/`AgentRoleAttributes`/sandbox-slice/RoleStep stores a session role. Migrating every agent-level-role consumer (§1 item 2) to read from the edge is done one-shot via Gate B (§8). **Carveout:** a recipe's own NAME (build-spec identity / provenance) is NOT a session role — Gate B forbids the *agent's session role* on the agent, it does not forbid recording which *recipe* an agent was built from.

### 4.5 Human role slots

Declared `%{role_name, fill: :human}`; filled at runtime: when a human joins (invite / anon admission / operator assignment) an operator assigns a `role_name` from the open human slots → sets the `role_name` facet on that human's edge. **Assignment requires an `entity://…/user/…` URI** (never an agent/template URI — the assign path must not spawn/join an agent) and is a RUNTIME edge write, **never persisted back into the `%Definition{}`** (codex rev2 NEW-HIGH). Home for the "specify role" UI Allen flagged (§6).

## 5. Security invariant (the point) — scoped precisely

**No socialware DECLARATION artifact — a `%Definition{}` (or its persisted JSON), nor the `SessionTemplate` content a Definition RENDERS INTO — may contain a PARTICIPANT instance URI** (`entity://…/agent/…` or `entity://…/user/…`) in a role slot, a member position, or a routing receiver. The only participant declaration is a role slot: `role_name` + (agents) a recipe NAME + flavor.

- **Structural closure:** no field to write A's agent URI into → the template-declaration credential vector is impossible (supersedes the deferred author-ownership gate).
- **Reuse is admission-gated** (§4.2): operator-caller join → foreign agent PENDS.
- **Owner (codex rev1 LOW resolved):** a session has an owner, but the **definition never names it** — `owner = the installer/operator at materialize time**. `owner_policy.fixed`'s baked owner USER URI is dropped; for anon-accessible apps the installing (non-anon) operator is the owner (satisfies "anon MUST be :fixed"). So no owner URI enters a definition.
- **Scope — socialware path only (codex rev2 finding 2/6).** The invariant governs the socialware DECLARATION/render path. It does NOT govern (a) live operator routing added at runtime (World UI / orchestrator `Tools.define_rule_set_rule` — authz-gated, out of this artifact) nor (b) the owner-scoped "**fork my own session → SessionTemplate**" capture flow, which legitimately references the forking user's OWN members (not cross-owner; admission-gated on rejoin). Gate A (§8) matches the socialware-authored/rendered positions, not these.

## 6. Operator materialize UI

A materialize/install wizard (World operator console): per **agent slot** choose flavor (default from slot), then Fresh (spin from recipe) or Reuse (pick from the operator's own `manages?`-owned, recipe-matching agents); per **human slot** an open role assigned when a human joins (an "assign role" control gated to the operator, user-URI only). Home for the missing "specify role" surface. (Layout is a plan concern.)

## 7. Migration & back-compat

Pre-prod: no non-test producer of `members`-with-direct-URI on `origin/main`; direct-URI members appear only in test fixtures (socialware P10 E2E).

- **Definition:** add `roles`; migrate `agents` → `roles` (`fill: :agent`); DELETE `members`. Move `members == [] → incomplete` to `roles`. Update `Definition.new/1` + conformance + `definition_editor`.
- **Legacy `SessionTemplate` (codex BLOCKER):** the socialware→SessionTemplate render emits role slots, not URI members; retire/hard-fail `members`/`uri`/`source_template_uri` on the socialware-render path + the `definition_editor.ex:308` override + the `template_team.ex:109` direct-uri clause. (The owner-scoped session-fork capture flow keeps its own members representation — §5 scope.)
- **`source_template_uri` → recipe:** the source AgentTemplate's content becomes a RecipeRegistry recipe entry (ConfigStore-versioned); the slot carries `(recipe, flavor)`. Repoint `orchestrator/tools.ex:115` + `member_template.ex:622` (`source_agent_template_uri` consumers).
- **Owner:** replace `owner_policy.fixed` baked URI with owner-derived-from-installer at `Installation.owner_uri_for_template` / `SessionCreator` (`session_creator.ex:367/544`).
- **Role de-bake (one-shot):** remove role from `planned_agent_uri` (uuid); stop writing role in `AgentRoleAttributes`/`record_launch_attributes`/sandbox slice/`Recipe.Compose`/`RoleStep`; repoint `AgentRoleResolver`, `UriQueryResolvers`, kanban `shared.ex`, world `kanban_data.ex`, `AgentCreate` role threading to the session edge (or a session-scoped resolver). Enumerated + driven to zero by Gate B.
- **Fixtures:** migrate the P10 E2E + seed definitions to `roles`(recipe); the bot becomes a fresh recipe-materialized agent assigned `bot` on its edge.

## 8. Migration strategy — gate-catches-wrong-usage, fix the reds (Allen's method)

Add TWO fail-closed arch/invariant gates FIRST; their red lists are the exhaustive worklist; fix each until green; green = complete + non-regressible (same discipline as oversized-modules / domain-only-Kinds; model on `member_cap_grant_seam_test`).

- **Gate A — no participant instance URI in a socialware declaration.** Scan `%Definition{}` (incl. the DECODED persisted JSON — `json_safe` stringifies `%URI{}`, so scan string values in role/member/receiver positions, not just `%URI{}` AST) + the socialware→SessionTemplate render output: no `entity://…/agent|user/…` in a role slot, member position, or routing receiver. Teeth: a planted definition/render with a member/receiver instance URI trips it. Excludes owner metadata (none — owner is installer-derived) and the owner-scoped session-fork capture path (§5).
- **Gate B — no agent-level session role.** No read/write of a global agent session-role (the `AgentRoleAttributes` role field, `planned_agent_uri` role segment, sandbox-slice `:role`, `Recipe.Compose` `role:`, `RoleStep` markers, `AgentRoleResolver` agent→role) outside the (allowlisted → empty) edge path. **Carveout:** recording which *recipe* an agent came from (build provenance) is allowed; only the agent's *session role* is forbidden on the agent. Teeth: a planted agent-level session-role read trips it.

Both gates start RED (they enumerate today's violations); the migration is "drive both to zero" = the completion criterion.

## 9. Phasing (one spec family; role de-bake is one-shot)

- **P1 — Declaration + security core.** `Definition.roles` (agent slots, migrate `agents`); retire both `members` layers + direct-uri clause; receivers `{:role,name}`-only; operator-caller reuse path; `source_template`→recipe; owner=installer; Gate A green. *Acceptance:* no participant instance URI representable/persistable in a socialware declaration (Gate A + teeth + an author/publish-rejects-URI integration test); P10 flow works via `roles`(recipe); reuse of a foreign agent PENDS (#161 C).
- **P2 — Role de-bake (one-shot).** uuid identity; role only on the edge; migrate ALL agent-level-role consumers; Gate B green. *Acceptance:* one materialized agent joined to two sessions holds distinct `role_name`s; `{:role,advisor}`@A and `{:role,reviewer}`@B resolve to the same agent; agent URI has no role segment; Gate B green.
- **P3 — Human role slots + operator materialize UI.** `fill: :human` (user-URI runtime assignment, never persisted to the definition); operator fresh/reuse/flavor binding UI; human role-assign UI.

(P1 closes the credential vector structurally + is independently shippable; P2 is the one-shot role migration; P3 is product completion.)

## 10. Testing / acceptance

- **Security (structural):** Gate A + teeth; an integration test that authoring/publishing a definition naming a foreign agent URI is rejected at the schema/`Definition.new` layer (no field exists), not only at a runtime gate.
- **Reuse gate:** operator reuse-binds own recipe-agent → mounts; binds an agent they don't manage → PENDS (#161 C) — proves reuse rides the operator-caller join, not an admin helper.
- **Role-on-edge:** the two-sessions-different-role E2E (P2); Gate B green.
- **De-bake:** materialized agent URI has no role segment; role read only from the edge.
- **Flavor override:** operator overrides the slot's default flavor at materialize → agent built under the chosen flavor.
- **Regression:** the P10 E2E (migrated) + all flavor plugins green.

## 11. Open questions

- **O-1 (recipe provenance query).** With uuid identity, "which recipe/session did this agent come from" is a stored attribute; confirm the catalog/ops views that need it read the attribute (not the URI).
- **O-2 (source AgentTemplate → recipe fidelity).** Confirm every source AgentTemplate's content reduces cleanly to a flavor-free RecipeRegistry recipe + a flavor (no flavor-specific pre-rendering that can't be re-derived); surface any that don't.
