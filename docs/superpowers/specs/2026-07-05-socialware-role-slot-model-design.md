# Socialware role-slot model — declare roles, never instances

**Date:** 2026-07-05
**Status:** DESIGN rev2 (brainstormed with Allen 2026-07-05; codex adversarial review rev1 → NOT-SOUND-as-written, all findings folded in below; pending re-review + user review)
**Motivating thread:** the #161 C over-fire fix's codex NO-SHIP — a socialware definition can name an agent by direct URI, so a system-mediated mount would spend that agent's owner's credential. Allen chose to close it *structurally* (no instance URIs in a definition at all) rather than add a per-declaration author-ownership gate.

---

## 1. Problems (three, tangled)

1. **Credential-theft template-declaration vector (SECURITY — the trigger).** A `%Definition{}`'s `members: [map()]` (`definition.ex:13`) accepts a raw map carrying a direct agent-instance `uri` (`template_team.ex:110`). Nothing checks the author owns it. Co-tenant B publishes/installs a definition naming A's credentialed agent by URI → the session system-mediated-mounts it (`RouteProvisioner`/`Materializer`, admin-caller) → A's agent runs B's messages → spends A's OAuth credential. #161 C closes the *direct* `session.join` pull but exempts *declared* members (assumed vetted at authoring — a gate that does not exist; conformance checks role-name resolution, not member-URI ownership). **A second, equal declaration surface exists: the legacy `SessionTemplate` content** also carries `members`/`uri`/`source_template_uri` (`entity/session_template.ex:41`, consumed at `:136`) and can OVERRIDE config members (`definition_editor.ex:308`) — same provisioning path (codex BLOCKER). **And routing receivers** can be explicit instance URIs (`conformance.ex:266` accepts URI-parseable receivers; `resolver.ex:412` expands them), a second way to name an instance in a definition (codex HIGH).

2. **Role is baked into the agent globally (ARCHITECTURE).** Role is written onto the agent in several durable places: the materialized URI `entity://ws/agent/<role>-<session-disc>` (`session_agent_materialize.ex:116/239`), `AgentRoleAttributes.put/2` (`recipe_materializer.ex:201`) via `record_launch_attributes/3` (`:114`), read back by `AgentRoleResolver` (`agent_role_resolver.ex:51`) and `UriQueryResolvers` (`uri_query_resolvers.ex:220`), and consumed agent-level by kanban (`shared.ex:94`) and world (`kanban_data.ex:68`). So an agent has ONE global role — it cannot be `advisor` in session A and `reviewer` in B. Role is a property of the (entity × session) relationship, not of the agent (codex HIGH — blast radius larger than a URI change).

3. **`members` vs `agents` duality (CLARITY).** A definition declares agents through TWO parallel fields: `agents: [%{recipe, role_name, flavor}]` (`definition.ex:11/27` — recipe-by-name, conformance-validated via `RecipeRegistry`, the clean form) AND `members: [map()]` (`definition.ex:13` — loose maps with a direct `uri` or `source_template_uri`). Both read by conformance/routing; `members` required non-empty (`definition_editor.ex:265`).

## 2. Principle (Allen)

> A socialware app declares *what kind* of participant it needs (a **role**, filled by a **recipe** for agents, or an open **role slot** for humans) — never *which instance*. Like software declaring "I need a CPU with these capabilities," never "run on this physical CPU." **Humans too** — a role slot, never a named person. And **`role_name` lives on the (entity × session) membership edge**, session-managed, reassignable, uniform for humans and agents; the agent is role-agnostic and can be a member of *multiple* sessions with a *different* role in each.

## 3. Recipe / flavor / template — the build unit (settled)

From `recipe_materializer.ex:5`: **"a recipe owns sandbox content; flavor owns how that content is loaded."**

- **recipe** (RecipeRegistry `recipe:<name>` ConfigObject) = **flavor-free, role-free** build content (sandbox content + caps). A NAME, pure data, no URI.
- **flavor** (`"cc"|"codex"|"curl"|"py"`) = the loader, supplied by the *declaration* at materialize time.
- **AgentTemplate** = a recipe rendered under a concrete flavor (recipe × flavor). It is itself a URI and a pre-baked bundle.

**Decision (Q1): a socialware definition points at RecipeRegistry ONLY — a recipe NAME + a flavor. Never an AgentTemplate URI, never a bare flavorless recipe.** The agent build unit is the pair `(recipe, flavor)`; materialization composes them via `RecipeMaterializer.template_content(recipe, %{flavor, agent_uri})`. This is exactly today's `agent_spec` shape, minus the URI escape hatches. `source_template_uri` declarations convert to RecipeRegistry recipe entries (§7).

## 4. Target model

### 4.1 Declaration — `Definition.roles` (one field, zero instance URIs)

Collapse `agents` + `members` into ONE role-slot list. No field can hold a participant instance URI.

```
roles: [role_slot]
role_slot ::
  %{role_name, fill: :agent, recipe: String.t(), flavor: String.t()}   # recipe NAME + flavor, no URI
  | %{role_name, fill: :human}                                         # open slot, filled at runtime
```

- `role_name` unique per definition (the session-model slot id + the `{:role, name}` routing receiver).
- `members` is **retired** (both the `Definition.members` field AND the legacy `SessionTemplate` `members`/`uri`/`source_template_uri` content and its override path). `Definition.new/1`, conformance, and `definition_editor` move the required-non-empty check to `roles`.
- **Routing receivers** in a definition are restricted to `{:role, name}` — an explicit agent/user instance-URI receiver is rejected at conformance (and by the arch gate, §8).

### 4.2 Materialization — operator decides per agent slot

When an **operator** materializes a definition into a session, for each **agent slot** they choose:

- **Fresh** — build a new agent from `(recipe, flavor)` (§4.3), materialized under **system-mediated (admin) authority** (safe: a brand-new agent the operator owns), OR
- **Reuse** — bind one of the operator's **own existing** agents of that recipe. **The reuse bind MUST enter through an operator-caller `session.join`** (`ctx.caller = operator`), NOT through the admin-mediated declaration helpers (`DefinitionAgents` admin ctx `definition_agents.ex:200`, `RouteProvisioner.system_mediated_ctx` `route_provisioner.ex:49`). This is load-bearing (codex HIGH): only an operator-caller join makes the #161 C admission gate fire — binding an agent the operator does NOT manage then PENDS (owner approval). If reuse rode the admin helpers it would be EXEMPT and reopen the vector.

Either choice yields a **(agent × session) membership edge** carrying `role_name` (via the existing `Members.put_member_facets` facet). **Human slots** are not filled at materialize; they are open slots a human is assigned to at runtime (§4.5).

### 4.3 Agent identity — role-agnostic, fresh uuid

A materialized agent's identity is `entity://<ws>/agent/<uuid>` — no role segment, no session segment. `planned_agent_uri(role, …)` is removed. Recipe/session provenance moves to a **stored attribute** (mirrors flavor-as-stored-attribute, #931), queried where needed — never encoded in the URI, never a global role.

### 4.4 `role_name` — the (entity × session) edge, only

`role_name` lives ONLY on the membership edge (`Members` meta facet; per-session uniqueness already enforced by `role_name_conflict/3`). Routing `{:role, name}` resolves against the session's current edges. NO agent config, URI, or `AgentRoleAttributes` stores role. This requires migrating every agent-level-role consumer (§2 item 2) to read role from the edge — done one-shot via the gate method (§8).

### 4.5 Human role slots

Declared `%{role_name, fill: :human}`; filled at runtime: when a human joins (invite / anon admission / operator assignment) an operator assigns a `role_name` from the open human slots → sets the `role_name` facet on that human's edge. Symmetric with agents; same edge, same facet. Home for the "specify role" UI Allen flagged missing (§6).

## 5. Security invariant (the point) — scoped precisely

**No `%Definition{}` (or its persisted JSON, or the legacy `SessionTemplate` content it resolves through) may contain a PARTICIPANT / mount-target instance URI** — i.e. no `entity://…/agent/…` or `entity://…/user/…` in a role slot, a member declaration, or a routing receiver. The only participant declaration is a role slot: `role_name` + (for agents) a `recipe` NAME + `flavor`.

- **Structural closure:** there is no field to write A's agent URI into → the template-declaration credential vector is impossible (supersedes the deferred author-ownership gate).
- **Reuse is admission-gated** (§4.2): operator-caller join → foreign agent PENDS.
- **Scope note (codex LOW):** the invariant targets PARTICIPANT/mount-target URIs. `Definition.owner_policy.fixed` stores an *owner* user URI (`definition.ex:66`) — that is authorship metadata, not a participant/route target, and is explicitly OUT of the invariant. The gate matches participant-declaration + receiver positions, not owner metadata.

## 6. Operator materialize UI

A materialize/install wizard (World operator console): per **agent slot** choose Fresh (spin from recipe) or Reuse (pick from the operator's own `manages?`-owned, recipe-matching agents); per **human slot** an open role assigned when a human joins (an "assign role" control gated to the operator). This is the home for the missing "specify role" surface. (Layout/interaction is a plan concern.)

## 7. Migration & back-compat

Pre-prod: no non-test producer of `members`-with-direct-URI on `origin/main` (confirmed); direct-URI members appear only in test fixtures (the socialware P10 E2E).

- **Definition:** add `roles`; migrate `agents` → `roles` (`fill: :agent`); DELETE `members` (field + the `source_template_uri` member form). Update `Definition.new/1` + conformance + `definition_editor` (move `members == [] → incomplete` to `roles`).
- **Legacy `SessionTemplate` (codex BLOCKER):** retire/hard-fail `members`/`uri`/`source_template_uri` in template content + the `definition_editor.ex:308` legacy-override path; delete the direct-`uri` clause in `TemplateTeam.ensure_member_present` (`template_team.ex:109`). No provisioning path may consume a member URI.
- **`source_template_uri` → recipe (codex MED, Allen: convert all):** every source AgentTemplate becomes a RecipeRegistry recipe entry with **equivalent version/fork semantics** (a real migration rule, not hand-wave); the slot then carries `(recipe, flavor)`. `orchestrator/tools.ex:115` + `member_template.ex:622` (the `source_agent_template_uri` consumers) repoint to recipe. Confirm no flow needs a raw AgentTemplate reference the recipe layer can't express.
- **Role de-bake (codex HIGH):** remove `planned_agent_uri` role segment (uuid); stop writing `AgentRoleAttributes` / `record_launch_attributes` role; repoint `AgentRoleResolver`, `UriQueryResolvers` role lookups, kanban (`shared.ex`), world (`kanban_data.ex`) to read role from the session edge (or a session-scoped resolver). Enumerated + driven to completion by the gate (§8).
- **Fixtures:** migrate the P10 E2E + seed definitions to `roles`(recipe); the bot becomes a fresh recipe-materialized agent assigned `bot` on its edge (no pre-spawned named bot).

## 8. Migration strategy — gate-catches-wrong-usage, fix the reds (Allen's method)

Add TWO fail-closed arch/invariant gates FIRST; their red lists are the exhaustive worklist; fix each site until green; green = migration complete and non-regressible (same discipline as oversized-modules / domain-only-Kinds gates; model on `member_cap_grant_seam_test`).

- **Gate A — no participant instance URI in a definition.** Static/AST + persisted-JSON scan: no `entity://…/agent|user/…` (or `%URI{}`) in a role slot, member declaration, or routing receiver of a `%Definition{}` / `SessionTemplate` content. Teeth: a planted definition with a member/receiver URI trips it.
- **Gate B — no agent-level role.** No read/write of a global agent role attribute (`AgentRoleAttributes` role field, `planned_agent_uri` role segment, `AgentRoleResolver`-style agent→role) outside the (allowlisted, → empty) edge path. Teeth: a planted agent-level role read trips it. Role must be resolved from the (entity × session) edge.

Both gates start RED (they enumerate today's violations); the migration is "drive both to zero." This is the completion criterion.

## 9. Phasing (one spec family; Allen: role de-bake is one-shot)

- **P1 — Declaration + security core.** `Definition.roles` (agent slots, migrate `agents`); retire both `members` layers + the direct-uri clause; receivers `{:role,name}`-only; operator-caller reuse path; `source_template`→recipe; Gate A green. *Acceptance:* no instance URI representable/persistable in a definition (Gate A + teeth + an author/publish-rejects-URI integration test); P10 flow works via `roles`(recipe); reuse of a foreign agent PENDS (#161 C).
- **P2 — Role de-bake (one-shot).** uuid identity; role only on the edge; migrate ALL agent-level-role consumers; Gate B green. *Acceptance:* one materialized agent joined to two sessions holds distinct `role_name`s; routing `{:role,advisor}`@A and `{:role,reviewer}`@B resolve to the same agent; agent URI has no role segment; Gate B green.
- **P3 — Human role slots + operator UI.** `fill: :human`; operator fresh-vs-reuse binding UI; human role-assign UI.

(P1 closes the credential vector structurally and is independently shippable; P2 is Allen's one-shot role migration; P3 is the product completion.)

## 10. Testing / acceptance

- **Security (structural):** Gate A + teeth; an integration test that authoring/publishing a definition naming a foreign agent URI is rejected at the schema/`Definition.new` layer (no field exists), not merely at a runtime gate.
- **Reuse gate:** operator reuse-binds own recipe-agent → mounts; binds an agent they don't manage → PENDS (#161 C). Proves reuse rides the operator-caller join, not an admin helper.
- **Role-on-edge:** the two-sessions-different-role E2E (P2 acceptance); Gate B green.
- **De-bake:** materialized agent URI has no role segment; role read only from the edge.
- **Regression:** the P10 E2E (migrated) + all flavor plugins green.

## 11. Open questions (narrowed)

- **O-1 (source_template version/fork parity).** Confirm every source AgentTemplate's version/fork semantics is expressible as a RecipeRegistry recipe (the §7 conversion rule); if a template carries flavor-specific pre-rendering not reducible to (recipe, flavor), surface it.
- **O-2 (recipe provenance query).** With uuid identity, "which recipe/session did this agent come from" is a stored attribute; confirm the catalog/ops views that need it read the attribute.
