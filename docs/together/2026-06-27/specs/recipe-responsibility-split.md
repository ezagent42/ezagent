# SPEC — Split the `role` homonym: agent **recipe** (A) vs session **responsibility** (B)

> **Design doc, NOT implementation.** A **clarity refactor**, not a new
> subsystem. Skills loaded: `ezagent-developer`, `ezagent-socialware`. All code
> citations verified against `origin/main` (`37b71aae`). Worktree off
> `origin/main`; branch `docs/recipe-responsibility-split`. Codex
> adversarial-review record in §6.
>
> **Scope = the vocabulary split + decoupling the binding, nothing more.** The
> B2 multi-holder / approval / quorum / arbiter machine analysed in
> `docs/together/2026-06-27/notes/role-for-users-domain-role.md` is **DEFERRED**
> and explicitly out of scope here. This SPEC does not design it, cite it only as
> the deferred sibling.
>
> **Lead's framing:** `role` is two homonyms — **A = agent recipe**
> (`Ezagent.Role`: prompt/skills/plugins/behaviors/caps/script = the agent's
> sandbox contents; `RoleRegistry`, relocating core→domain.agent as
> `Ezagent.Agent.RoleRegistry` on `feat/role-as-data`) and **B = responsibility**
> (session membership `role_name` + routing `{:role, name}`, a per-session,
> cross-principal label). This SPEC makes the split explicit in code+docs and
> proves the two axes are independent.

---

## 0. TL;DR (the verdict, and a correction to the task's premise)

1. **The two axes are ALREADY separate fields in the data model.** Concept A
   lives in the agent's `:sandbox` slice `:role` (mirrored to ETS
   `AgentRoleAttributes`, sourced from the `:role` param at agent-create and the
   AgentTemplate content `:role`). Concept B lives in **session membership `meta`
   `:role_name`**, set from the *join facets* (member declaration / orchestrator
   tool param), never read back from the recipe.

2. **The task's hypothesis — "session `role_name` is FORCED to equal the recipe
   name" — does NOT hold in the code.** There is **no structural forcing** and
   **no back-compat default that derives `role_name` from the recipe**
   (verified: the fallback grep returns ∅; the only `role_name`-absent path
   falls back to the *template URI path segment*, not the recipe — `template_team.ex`
   `spawned_member_instance_name`). Proof the axes are independent is already in
   the tree: the G4 e2e spawns a member with `role_name: "worker"` over a
   `cc-orchestrator`-flavored source template
   (`agent_contract_g4.ex:269` + `:354`).

3. **So the conflation is NOT a binding to sever — it is two softer things:**
   - **(C1) Vocabulary.** The bare word `role` names BOTH axes across the
     codebase (`Ezagent.Role`, `RoleRegistry`, `AgentRoleAttributes`,
     `AgentRoleResolver`, sandbox `:role`, AgentTemplate `:role`, `EZAGENT_ROLE`
     env) **and** (`:role_name`, `{:role, name}`, `role_name_conflict`,
     `resolve_role`). A reader cannot tell which `role` a symbol means. One local
     variable literally crosses the streams: `role_step.ex:176`
     `role_name = Map.get(params, :role)` — a variable named like B holding an A
     value.
   - **(C2) Seed coincidence.** The orchestrator is the one built-in where the
     **recipe name** (`"orchestrator"`) and the **session `role_name`**
     (`"orchestrator"`) are hand-bound to the *same literal* across three files
     (§1.3). This single coincidence is what makes the two axes *look* like one.

4. **Crucially, nothing in production confers authority from `role_name`.**
   Orchestrator authority is the `{:within_session, S}` delegated CapBAC cap
   (`session.ex:754`, `:851`; `membership.ex:387`); orchestrator tools/skills come
   from the **recipe** (mcp.json + skill copy + `EZAGENT_ROLE`, threaded by
   `source_template_uri`, not by name-match). The only `role_name == …` reads in
   prod are recipe-side (`AgentRoleResolver`, which reads the sandbox `:role`, i.e.
   A) and a migration *lookup* (`migration.ex:80`). So decoupling the label
   breaks no authority path. **The decouple is genuinely lean.**

5. **Therefore the deliverable is: (a) a lock-in invariant TEST proving
   recipe-name ≠ session-role_name is supported, (b) a scoped vocabulary rename
   that makes "role" mean only B, reconciled with the in-flight
   `Ezagent.Agent.RoleRegistry` move, (c) doc disambiguation.** No data-model
   surgery. The task's "make `role_name` settable independently of the recipe" is
   **already true**; this SPEC *locks it* and *names it*.

---

## 1. Where the two axes live, and where they are conflated (§-task-1)

### 1.1 A — agent **recipe** (build-time, agent-only)

| Symbol | File:line (`origin/main`) | What it is |
|---|---|---|
| `Ezagent.Role` struct | `apps/ezagent_core/lib/ezagent/role.ex` | the recipe (skills/plugins/prompt/script/behaviors/requested_caps/session_template) |
| `Ezagent.RoleRegistry` | `apps/ezagent_core/lib/ezagent/role_registry.ex` | `name → %Role{}` ETS map (relocating → `Ezagent.Agent.RoleRegistry` on `feat/role-as-data`) |
| sandbox slice `:role` | agent `:sandbox` slice (durable SoT) | the recipe NAME stamped on an agent |
| `Ezagent.AgentRoleAttributes` | `apps/ezagent_domain_agent/lib/ezagent/agent_role_attributes.ex` | ETS fast-path `uri → role name` for the `:role` UriQuery |
| `Ezagent.AgentRoleResolver` | `apps/ezagent_domain_agent/lib/ezagent/agent_role_resolver.ex` | list-by-role + per-URI durable fallback, both over the sandbox `:role` |
| AgentTemplate content `:role` | `cc_orchestrator_seed.ex:430` | recipe name carried on the template content |
| `:role` param → CapMint | `role_step.ex:176`, `:124` | the recipe whose `requested_caps` get minted |
| `EZAGENT_ROLE` / `EZAGENT_AGENT_ROLE` env | `cc_orchestrator_seed.ex:483`,`:520` | recipe identity exposed to the running agent |

Every one of these is **build-time, agent-only**: it describes how the sandbox is
manufactured. A human principal has none of it. (Full A/B analysis: the research
note §1–§2.)

### 1.2 B — session **responsibility** (runtime, cross-principal)

| Symbol | File:line | What it is |
|---|---|---|
| membership `meta.:role_name` | `members.ex:36-86`, set in `membership.ex:35` | the per-session label a member carries (user OR agent) |
| `Members.role_name_conflict/3` | `members.ex:64-76` | enforces `role_name` **unique per session** (B1 single-holder) |
| `Members.role_name_to_uri/2` | `members.ex:82-86` | resolves a `role_name` to its ONE holder URI |
| routing `{:role, name}` receiver | `apps/ezagent_core/lib/ezagent/routing/receiver.ex:11-42` | a routing rule addressed by responsibility name |
| `expand_receiver({:role,…})` | `apps/ezagent_core/lib/ezagent/routing/resolver.ex:189,210` (single-resolve) | resolves `{:role,name}` → one URI via the injected `role_resolver` |
| `RouteProvisioner.resolve_role/4` | `apps/ezagent_domain_session/lib/ezagent/behavior/session/route_provisioner.ex:9-40` | the `role_resolver` wired at `session.ex:498-499`; resolves an existing member or lazily provisions a *declared* one |

Every one is **runtime, cross-principal**: who is responsible for what in *this*
session. It never reads the recipe; the member→recipe link is the separate
`source_template_uri` facet.

### 1.3 The conflation points (exact `file:line`)

**These are the bindings to disambiguate. None is a structural forcing — (1)–(3)
are the same literal hand-threaded across both axes; (4) is a misnamed variable.**

1. **`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/orchestrator_role.ex:48`**
   — `@role_name "orchestrator"` is the **recipe NAME** (registered in
   `RoleRegistry` via `roles/0`). Note the field is *named* `@role_name` though it
   is concept **A**.
2. **`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/cc_orchestrator_seed.ex:430`**
   — AgentTemplate content `role: "orchestrator"` (concept **A**, stamped on the
   spawned agent's sandbox; drives skill-copy + `EZAGENT_ROLE`).
3. **`apps/ezagent_domain_session/lib/ezagent_domain_instance_message/application.ex:562`**
   — the default session template declares its sole member as
   `role_name: "orchestrator"` (concept **B**, the routing label).

   → (1)+(2) are **A**; (3) is **B**. They are bound to the *same string*
   `"orchestrator"` purely by seed convention. There is no code path that derives
   one from the other — swapping (3) to `role_name: "lead"` would leave the recipe
   untouched and only rename the routing label. This coincidence is the visual
   root of the homonym.

4. **`apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create/role_step.ex:176`**
   — `role_name = Map.get(params, :role)`: a local variable named like **B**
   (`role_name`) that holds the **A** recipe name (it is immediately passed to
   `RoleRegistry.lookup/1` for CapMint). This single line is the sharpest
   illustration of the vocabulary collision and is fixed as a token of the rename
   (§3).

**Non-findings (verified, so the SPEC stays honest):**
- No `role_name` default derives from the recipe (fallback grep ∅).
- No production branch confers authority/tools from `role_name == "orchestrator"`
  (authority = `{:within_session,S}` cap; tools/skills = recipe via
  `source_template_uri`). The lone non-team agent join sets no recipe-derived
  `role_name` at all.

---

## 2. The minimal decouple (§-task-2)

Because the axes are already separate fields with no forcing and no
recipe-derived default, the decouple is **assertional + nominal**, not
structural. Three changes, smallest first:

### 2.1 Lock the independence with an invariant test (the centerpiece)

Add a fast regression test (domain_session test suite) that PROVES the two axes
are independent — converting today's incidental separation into a guarded
contract:

- **T1 — recipe ≠ role_name is admissible.** Spawn/join a member from a source
  AgentTemplate whose recipe/flavor is `cc-coder` (or `cc-orchestrator`) with
  join facet `role_name: "reviewer"`; assert the member's `meta.role_name ==
  "reviewer"` AND the agent's sandbox `:role` (via `AgentRoleResolver` /
  `AgentRoleAttributes`) is unchanged by the join. (Generalises the existing G4
  `role_name: "worker"` case into an explicit named invariant.)
- **T2 — a recipe-less principal holds a role_name.** A `entity://…/user/…`
  member joins with `role_name: "reviewer"` and resolves via
  `Members.role_name_to_uri/2` — proving B is cross-principal and recipe-free.
- **T3 — the orchestrator's `role_name` is independent of its recipe name.**
  Re-seed the default template with `role_name: "lead"` (recipe still
  `"orchestrator"`); assert the orchestrator still spawns and bootstraps (skill
  copy + `EZAGENT_ROLE` still `"orchestrator"`) while routing addresses it as
  `{:role, "lead"}`. This is the lock-in for conflation point §1.3(3).

These tests are the **completion gate** for the decouple: they fail if a future
change re-forces `role_name` from the recipe.

### 2.2 The default rule (explicit, back-compat-safe)

**Current behaviour (keep):** `role_name` is set *only* from the join facets;
when absent the member simply has no `role_name` (and its instance name falls
back to the template path segment). **This SPEC does not change that default.**

The task's mention of "default behaviour can still derive role_name from recipe
when unspecified" describes a default **that does not exist today**. Designing it
is therefore *additive*, not back-compat preservation — see OQ-1. Recommendation:
**do not add it.** Forcing `role_name = given || recipe_name` would re-introduce
exactly the coincidence (C2) this SPEC removes, and the system already runs fine
without it.

### 2.3 The decoupled field (already correct — affirm + document)

`meta.:role_name` is the decoupled field. The API to set it already exists and
takes `role_name` as an explicit, recipe-independent argument at every join site:
`Tools.add_managed_member/4` (`tools.ex:131`), `Tools.add_participant/3` →
`Participants.admit_participant` (`participants.ex:28,98`), and the member
declaration `:role_name` consumed by `TemplateTeam.provision_declared_member`
(`template_team.ex:40,54`). **No new field, no new parameter** — the decouple is
realised by (2.1) locking it and (3) naming it so callers stop conflating the
two. The orchestrator-as-declared-member design (task #90, `application.ex:562`)
is already the pattern: the orchestrator is "just a member with a role_name", and
that role_name is free to differ from its recipe.

---

## 3. Vocabulary plan (§-task-3) — make "role" mean only B

The risk codex will press (§6): *renaming that leaves "role" spanning both axes
is not a fix.* So the rule is **decisive, not cosmetic**, but **scoped to the
high-confusion symbols** (no whole-codebase churn):

**Decision: "role" is reserved for B (responsibility). A is renamed to
"recipe".** After this, every bare `role`/`role_name` in code means the session
responsibility; the agent build-spec is always `recipe`.

### 3.1 A-side renames (reconciled with the in-flight `feat/role-as-data` move)

The relocation `Ezagent.RoleRegistry` → `Ezagent.Agent.RoleRegistry` is in
flight. **Fold the A-rename INTO that move** so it lands once, not twice:

| Now | Rename to | Note |
|---|---|---|
| `Ezagent.RoleRegistry` → (in-flight) `Ezagent.Agent.RoleRegistry` | **`Ezagent.Agent.RecipeRegistry`** | piggyback on the relocation already touching every call site |
| `Ezagent.Role` (struct) | **`Ezagent.Agent.Recipe`** | the manufacturing spec |
| `Ezagent.AgentRoleAttributes` | **`Ezagent.AgentRecipeAttributes`** | ETS fast-path |
| `Ezagent.AgentRoleResolver` | **`Ezagent.AgentRecipeResolver`** | list-by-recipe / per-URI recipe |
| sandbox slice key `:role` | **`:recipe`** | the durable SoT field (coordinate with role-as-data SPEC, which is converting this to a `config://…/role/<name>` read — adopt `recipe` naming there too) |
| `role_step.ex` var `role_name = Map.get(params, :role)` | **`recipe_name = Map.get(params, :recipe)`** | the cross-stream variable — the token fix |
| `EZAGENT_ROLE` / `EZAGENT_AGENT_ROLE` env | keep for now (external contract) OR alias `EZAGENT_RECIPE` | flag as follow-up; touches the cc PTY contract |

`orchestrator_role.ex` becomes `orchestrator_recipe.ex` with `@recipe_name
"orchestrator"`; `cc_orchestrator_seed.ex:430` writes `recipe: "orchestrator"`.

### 3.2 B-side — keep, optionally clarify

`role_name`, `{:role, name}`, `role_name_conflict`, `resolve_role`,
`role_resolver` already mean B. **Keep them** (renaming to `responsibility`
everywhere is churn beyond scope). Document that `role_name` ≡ "session
responsibility" in the `members.ex` moduledoc and GLOSSARY so the bare word is
anchored to B. If a sharper word is wanted later, `responsibility_name` is the
candidate (OQ-3) — not in this SPEC.

### 3.3 Docs

- **GLOSSARY.md** — two entries: **Agent Recipe (A)** and **Session
  Responsibility / `role_name` (B)**, each citing the other as "not to be
  confused with".
- **ARCHITECTURE.md Appendix B** — one Decision Log entry recording the homonym
  split + the "role means B, recipe means A" rule.
- The in-flight role-as-data SPEC and the deferred B2 note both get a one-line
  pointer to this SPEC for the vocabulary contract.

### 3.4 Why this reduces confusion (not just renames)

After §3.1 the string `role` no longer appears on the A axis at the
high-confusion symbols; a reader seeing `role_name`/`{:role,_}` knows it is the
session responsibility, and `recipe`/`RecipeRegistry` is unambiguously the build
spec. The `role_step.ex:176` cross-stream variable — today's proof that even the
authors collide the terms — disappears. The rename is bounded to ~7 A-side
symbols (all touched anyway by the in-flight relocation) plus moduledocs; B-side
and the wider codebase are untouched.

---

## 4. Scope boundary (what this SPEC does NOT do)

- **No B2.** No multi-holder `role_name`, no fan-out `{:role,name}`, no
  assignment table, no approval/quorum/arbiter Behavior, no `:assign_role` cap.
  All deferred to `role-for-users-domain-role.md` (cited, not built).
- **No `domain.role` app.** A stays in `domain.agent` (the in-flight move); B
  stays where it is (membership + core routing).
- **No data migration.** The sandbox slice key rename (`:role`→`:recipe`) rides
  the existing role-as-data wipe/rebuild; no separate migration is introduced
  here.
- **No new default.** §2.2 explicitly declines the recipe→role_name default.

---

## 5. Sequencing (each step independently shippable)

1. **Lock-in tests T1–T3** (§2.1) — land FIRST, on current `origin/main`; they
   pass today and become the regression gate.
2. **A-side rename** (§3.1) — fold into the `feat/role-as-data` relocation PR so
   every A call site is touched once. Includes the `role_step.ex:176` token fix.
3. **Doc disambiguation** (§3.3) — GLOSSARY + Decision Log + moduledocs.
4. **(optional, follow-up)** `EZAGENT_ROLE` env alias; `role_name` →
   `responsibility_name` if the lead wants the B-side word sharpened too.

Steps 1 and 3 are independent of the in-flight branch; step 2 is gated on it.

---

## 6. Codex adversarial-review record

> _(to be appended after `/codex:adversarial-review` against the committed
> artifact — questions posed: (a) is the conflation correctly located, i.e. is
> the "no structural forcing" claim right or did the review miss a path that
> reads `role_name` to confer behaviour? (b) is the decouple minimal +
> back-compat-safe, given §2.2 declines the default the task assumed exists? (c)
> does the §3 vocab split actually reduce confusion, or does keeping `role_name`
> for B leave "role" still spanning both axes?)_

---

## 7. Open questions for the lead

- **OQ-1 — the recipe→role_name default.** The task assumed a back-compat default
  deriving `role_name` from the recipe; it does **not** exist. §2.2 recommends
  NOT adding it (it would re-create the coincidence). Confirm — or, if a
  convenience default is wanted, it is a NEW opt-in (`given || derive(recipe)`),
  scoped separately.
- **OQ-2 — rename blast radius / timing.** Fold the A-side rename into the
  in-flight `feat/role-as-data` relocation (one pass, recommended), or land it as
  a separate follow-up PR after the relocation merges?
- **OQ-3 — B-side word.** Keep `role_name` (anchored to B by docs, recommended,
  zero churn) or rename to `responsibility_name` for symmetry (wider churn)?
- **OQ-4 — `EZAGENT_ROLE` env.** Rename/alias to `EZAGENT_RECIPE` now (touches
  the cc PTY contract + bridge) or defer as a follow-up?
