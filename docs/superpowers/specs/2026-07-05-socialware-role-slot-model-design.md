# Socialware role-slot model — declare roles, never instances

**Date:** 2026-07-05
**Status:** DESIGN (brainstormed with Allen 2026-07-05; pending codex adversarial review + user review)
**Motivating thread:** the #161 C over-fire fix's codex NO-SHIP — a socialware definition can name an agent by direct URI (`members[].uri`), so a system-mediated mount would spend that agent's owner's credential. Allen chose to close it *structurally* (no instance URIs in definitions at all) rather than add a per-declaration author-ownership gate.

---

## 1. Problem

Three tangled problems in the socialware declaration + materialization model:

1. **Credential-theft template-declaration vector (SECURITY, the trigger).** A `%Definition{}`'s `members: [map()]` field (`definition.ex:13`) accepts a raw map that may carry a direct agent-instance `uri` (`template_team.ex:110` `member_uri_field(member, :uri)`). Nothing validates that the declared URI is an agent the author owns. So co-tenant B can publish/install a definition declaring A's credentialed agent by URI; the session then system-mediated-mounts it (via `RouteProvisioner`/`Materializer`, both admin-caller) → A's agent runs B's messages → spends A's OAuth credential. The #161 C admission gate closes the *direct-pull* path (`session.join` with `caller=B` pends) but exempts declared members (assumed vetted at authoring — an authoring gate that does not exist; conformance checks role-name resolution, not member-URI ownership).

2. **Role is baked into agent identity (ARCHITECTURE bug).** `SessionAgentMaterialize.planned_agent_uri(role, session_uri, workspace_uri)` builds `entity://<ws>/agent/<role>-<session-disc>` (`session_agent_materialize.ex:116/239`) — the materialized agent's *identity* encodes its role. The same recipe cannot be `advisor` in session A and `reviewer` in session B: role is a property of the (entity × session) relationship, not of the agent.

3. **`members` vs `agents` duality (CLARITY).** A definition declares session agents through TWO parallel fields: `agents: [%{recipe, role_name, flavor}]` (`definition.ex:11`, recipe-by-name, conformance-validated via `RecipeRegistry` — the clean form) AND `members: [map()]` (`definition.ex:13`, loose maps that carry a direct `uri` OR a `source_template_uri`). Both are read by conformance (`declared_role_names/1` reads `members` + `agents`) and routing. `members` is *required* non-empty (`definition_editor.ex:265`). Two mechanisms, overlapping responsibilities.

## 2. The principle (Allen)

> A socialware app declares *what kind* of participant it needs (a **role** filled by a **recipe** for agents, or an open **role slot** for humans) — never *which instance*. Like software declaring "I need a CPU with these capabilities," never "run on this specific physical CPU."

Two corollaries Allen drew out:

- **Humans, too, are declared by role, never by person.** A definition never names a specific user; it declares a human role slot filled at runtime.
- **`role_name` is a property of the (entity × session) membership edge**, managed by the session, reassignable, uniform for humans and agents. The agent itself is role-agnostic and can be a member of *multiple* sessions with a *different* role in each (advisor in A, reviewer in B).

## 3. What already exists (foundation — this is a targeted refactor, not a rebuild)

- **`role_name` is already a membership-edge facet.** `Members.put_member_facets/2` (`members.ex:38`) merges `:role_name` into a member's `meta` on the session's `:members` roster; `role_name_conflict/3` enforces per-session uniqueness. So "role lives on the (entity × session) edge" is *already true* for the agent path — the gap is that it is ALSO baked into the agent's URI, and humans have no declaration path.
- **`agents: [%{recipe, role_name, flavor}]` is already the clean, no-URI, conformance-validated agent declaration** (`definition.ex:27`, `conformance.ex` `check_agent_recipes` resolves the recipe via `RecipeRegistry`; `check_role_name_uniqueness`). Recipe (config axis A) is already decoupled from role_name (routing axis B) — the recipe/responsibility split (#122/#127/#141).
- **The #161 C admission gate** already pends a cross-owner *bind* of an agent a caller does not manage. Reuse-binding (§5) rides on this.

So the model is ~half-built. The work is: **remove the two escape hatches** (the `members`-URI declaration path; the role-in-identity baking), **add** the human role slot + the operator materialize-time binding, and **consolidate** the two declaration fields into one.

## 4. Target model

### 4.1 Declaration layer — `Definition.roles`

Collapse `agents` + `members` into ONE field of role slots. No instance URI is representable.

```
roles: [role_slot]
role_slot ::
  %{role_name: String.t(), fill: :agent, recipe: String.t(), flavor: String.t()}   # agent slot
  | %{role_name: String.t(), fill: :human}                                         # human slot
```

- `role_name` is unique per definition (the session-model slot identity + the `{:role, name}` routing receiver).
- An **agent slot** carries a `recipe` (a `RecipeRegistry` name — pure data, no URI) + `flavor`. Exactly today's `agent_spec`, re-tagged `fill: :agent`.
- A **human slot** carries only `role_name` (+ optional metadata like a display label / whether it's required). No person reference.
- **`members` is retired.** The direct-`uri` and `source_template_uri` member declaration forms are removed (see §7 migration). `Definition` no longer has a field into which any instance/template URI can be written for a participant.

### 4.2 Materialization layer — operator decides per slot

When an **operator** materializes/installs a socialware definition into a session, for each **agent slot** the operator chooses:

- **Fresh** — materialize a new agent from `recipe` (§4.3), or
- **Reuse** — bind one of the operator's **own existing** agents of that recipe (an agent can be a member of multiple sessions).

Either choice produces a **(agent × session) membership edge** carrying `role_name = slot.role_name` (via the existing `put_member_facets` facet). **Human slots** are not filled at materialization; they are open slots a human is assigned to at runtime (see §4.5).

The decision is the operator's, at materialization time — not baked into the app, not a global policy.

### 4.3 Agent identity — de-bake role (fresh uuid)

`planned_agent_uri(role, …)` is replaced: a materialized agent's identity is **role-independent** — `entity://<ws>/agent/<uuid>` (fresh opaque id; identity-scheme **B** from the brainstorm). The agent carries NO role attribute anywhere. Its role is *only* the `role_name` facet on each session membership edge it holds. This is what lets the same agent hold different roles across sessions.

> Rationale for a fresh uuid over recipe-derived: the brainstorm chose (b) — pure instance identity keeps "role lives on the edge" self-consistent and lets one operator run several agents of the same recipe (even filling two slots in one session) without identity collision. Recipe/session provenance moves to a queryable stored attribute (mirrors the flavor-as-stored-attribute pattern, #931), not the URI.

### 4.4 `role_name`归属 — the (entity × session) edge

`role_name` lives ONLY on the membership edge (`Members` meta facet), session-managed and reassignable, uniform across kinds. Routing (`{:role, name}`) resolves against the session's current membership edges (whichever member holds that role now) — as it does today, but now the *only* home for role. No agent config, no agent URI, no per-kind branch stores role.

### 4.5 Human role slots (the missing UI Allen flagged)

A human slot is declared (`%{role_name, fill: :human}`) but filled at runtime: when a human joins a session (invite / anon admission / operator assignment), an operator assigns them a `role_name` from the definition's open human slots → sets the `role_name` facet on that human's membership edge. Symmetric with the agent path; same edge, same facet. The **operator materialize/assign UI** (§6) is the surface for this.

## 5. Security invariant (the point)

**No `%Definition{}` can contain a participant instance URI (agent or human).** The only participant declaration is a role slot keyed by `role_name` + (for agents) a `recipe` name. Therefore:

- **The template-declaration credential vector is structurally impossible** — there is no field to write A's agent URI into. (Supersedes the deferred author-ownership gate; a definition simply cannot name an instance.)
- **Operator reuse-binding is authz-gated.** When an operator binds an *existing* agent to a slot, that bind is an ordinary member-add subject to the #161 C admission gate: the operator can bind only agents they `manages?`; binding an agent they do not own → PENDS (owner approval). So reuse cannot pull a foreign credentialed agent either.
- **Materialization dispatches remain system-mediated** for the *fresh* path (recipe → new agent the operator owns), unchanged and safe.

Net: both the declaration path (no URI) and the reuse path (admission-gated) are closed. This is the structural closure of the vector #161 C's over-fire fix left deferred.

## 6. Operator materialize UI

A materialize/install wizard (World operator console):

- For each **agent slot**: choose **Fresh** (spin from recipe) or **Reuse** (pick from the operator's own agents of that recipe; list filtered to `manages?`-owned + recipe-matching).
- For each **human slot**: shown as an open role to be assigned; assignment happens when a human joins (an "assign role" control on the member, gated to the operator).
- The wizard is the home for the "specify role" surface Allen noted is missing.

(UI detail — layout/interaction — is an implementation concern for the plan, not fixed here.)

## 7. Migration & back-compat

Pre-prod: no real published definitions carry direct-URI members (confirmed — no non-test producer of `members` with a direct agent URI on `origin/main`; the only direct-URI declarations are test fixtures, e.g. the socialware P10 E2E's `%{"role_name" => "bot", "uri" => …}`). So:

- **`Definition`**: add `roles`; migrate `agents` entries → `roles` with `fill: :agent`; drop `members` (+ the `source_template_uri` member form — reconcile with `roles` if any legit use exists, else remove). Update `Definition.new/1` + `conformance` + `definition_editor` (the `members == [] → incomplete` check moves to `roles`).
- **Materialization**: rewrite `TemplateTeam.provision_declared_member` / `RouteProvisioner` / `DefinitionAgents` to consume `roles` (fresh path) + the operator's reuse bindings; delete the direct-`uri` `ensure_member_present` clause. Replace `planned_agent_uri(role, …)` with the uuid scheme; move recipe/session provenance to a stored attribute.
- **Tests/fixtures**: migrate the P10 E2E + any seed definitions to `roles`(recipe). The bot becomes a fresh recipe-materialized agent assigned the `bot` role on its edge (no pre-spawned named bot).
- **Arch invariant**: a fitness test that no `%Definition{}` field (or its persisted JSON) can hold an `entity://…/agent/…` or `entity://…/user/…` instance URI — the structural guarantee, with a planted-bypass teeth test (model on the #161 C `member_cap_grant_seam_test`).

## 8. Phasing (one spec family; internal order)

Allen chose "一次做完" — one coherent effort, internally ordered so the security core lands first and independently testable:

- **P1 — Declaration + materialization core (SECURITY).** `Definition.roles` (agent slots only, migrate `agents`); retire `members`-URI; de-bake `planned_agent_uri` → uuid; consolidate conformance/editor; migrate fixtures; the no-instance-URI arch invariant. *Acceptance:* a definition cannot declare an instance URI (structural + teeth); the P10 flow works via `roles`(recipe); the same agent can hold two roles across two sessions (edge-role E2E).
- **P2 — Human role slots + operator materialize UI.** `fill: :human` slots; operator fresh-vs-reuse binding UI; human role-assign UI. *Acceptance:* operator materializes an app choosing fresh/reuse per slot; assigns a human to a role; reuse of a foreign agent PENDS (admission gate).

## 9. Testing / acceptance

- **Security (structural):** the §7 arch invariant — no instance URI representable in `%Definition{}` — with a teeth fixture. Plus an integration test: attempt to author/publish a definition naming a foreign agent URI → rejected at the schema/`Definition.new` layer (the field does not exist), not merely at a runtime gate.
- **Role-on-edge:** one materialized agent joined to two sessions holds distinct `role_name`s; routing `{:role, advisor}` in A and `{:role, reviewer}` in B resolve to the same agent.
- **De-bake:** materialized agent URI contains no role segment; role read only from the membership edge.
- **Operator reuse gate:** operator reuse-binds their own recipe-agent → mounts; binding an agent they do not manage → PENDS (#161 C).
- **Regression:** the socialware P10 E2E (migrated to `roles`) stays green; all flavor plugins green.

## 10. Open questions

- **O-1 (source_template_uri form).** `members` also had a `source_template_uri` form (spawn fresh from an AgentTemplate). Is that subsumed by `recipe` (RecipeRegistry name), or is a template-URI reference still needed for some flow? Recommend: subsume into recipe (a template URI is still a URI — against the principle); confirm no flow needs a raw AgentTemplate reference the recipe layer can't express.
- **O-2 (recipe provenance query).** With uuid identity, "which recipe/session did this agent come from" moves to a stored attribute. Confirm the query surfaces that need it (catalog, ops views) read the attribute, not the URI.
- **O-3 (P2 boundary).** Is the human-slot + operator-UI genuinely P2 (after the security core ships), or does any current flow need human slots on day one? Recommend P2.
