# Should agent ROLES be runtime DATA instead of code recipes?

> Research + recommendation. NOT implementation. Driven by the lead's concern
> that roles will proliferate (kanban, np, kb, salesperson-fixture, card-creator,
> …) and that defining each in code + a release is a code-change-per-role tax.
> All code cited from `esr-ng` `origin/main` (read-only); doc authored on branch
> `docs/roles-as-data-research`.

---

## TL;DR — the recommendation

**HYBRID, on the existing `template://<ws>/role/<name>` Template seam — not a new
table, not ConfigStore.**

1. **Keep code recipes for trusted built-ins** (orchestrator, kanban-manager, np).
   They are part of a plugin's contract, ship with the engine, and pay no
   per-tenant cost. Nothing about proliferation of *built-ins* is fixed by moving
   them to data — a built-in role is already "free" once its plugin exists.
2. **Add a runtime-data path for TENANT-AUTHORED roles**, loaded from a persisted
   forkable `template://<ws>/role/<name>` object that the `RoleRegistry` lookup
   resolves — this is the follow-up the role-foundation design *already names*
   (§"Code-seeded built-in, registered via `roles/0`" in `orchestrator_role.ex`;
   role-foundation-design Part 2). The `RoleRegistry.lookup/1` indirection IS the
   re-point seam.
3. **Gate the data path by what the role field actually contains, not by the role
   as a monolith.** The three payload fields have three *different* containment
   regimes (see §4). Caps and behaviors/skills/plugins are already structurally
   contained at instantiation. The `script` field is the only genuinely-new
   executable content and is the one field that forces governance (review→publish
   or operator-only authorship).
4. **The synthesis verdict (§5):** roles-as-data, ConfigStore, and Template
   config DO converge — but on a shared *governance flow*
   (draft → review → publish → re-point an immutable object), **not** on one
   literal table. Collapsing role/config/template into a single store is
   over-reach; unifying their publish-and-pointer *pattern* is the right north
   star.

> ⚠️ **Caveat on "the just-spec'd CR-governance".** The task references a
> just-spec'd CR-governance (propose→review→publish) to map roles-as-data
> against. **No such spec exists in `esr-ng`, `esr`, or `cc-openclaw`** (grepped
> `change request | draft.*review.*publish | propose.*publish | cr-govern` across
> all three — zero hits). This doc therefore reasons from the **closest existing
> governance precedent that IS in the tree**: the config-evolve flow
> (`Turn` → approval gate → `apply_config_delta`, immutable object + pointer,
> manage-cap gated) plus the #154 cap model. If a CR-governance spec exists
> elsewhere, the §5 verdict should be re-checked against its exact shape — but my
> strong read is that it is the *same* flow this doc derives, and the lead should
> confirm that rather than let me assume it.

---

## 1. Current mechanism (cited)

### 1.1 `Ezagent.Role` — the recipe struct
`apps/ezagent_core/lib/ezagent/role.ex`. A **flavor-agnostic sandbox-content
recipe** (#54). Fields:

```
name, passive, skills[], plugins[], prompt, script, behaviors[],
requested_caps[], session_template
```

Key properties already built into `Role.new/1` (these matter enormously for the
data question, because `new/1` is the boundary an untrusted persisted recipe
crosses):

- **Atom+string-key symmetric** — explicitly designed to round-trip through
  JSON/snapshot ("A persisted role recipe … round-trips through JSON/snapshot as
  STRING keys"). So the struct is *already* persistence-ready; serialization is
  not the blocker.
- **`@flavor_fields` exclusion (#54)** — a recipe naming `:flavor`/`:kind`/
  `:bridge_adapter`/`:template_class` is rejected `{:flavor_field_in_role, key}`.
  Keeps a role composable across cc/codex/curl.
- **`@cap_materialization_axes` rejection** — a requested cap carrying
  `:kind`/`:instance`/`:workspace_uri`/`:granted_by`/`:granted_at` is rejected
  fail-loud. The moduledoc names this exactly: *"Rejecting them stops an
  operator-authored role from SMUGGLING a concrete/foreign workspace/instance
  into a cap (a CapBAC hole)."* This is the codebase already anticipating an
  operator/data-authored recipe as an injection vector.
- **`behaviors` are validated to be real loaded `Ezagent.Behavior` modules**
  (`behavior_module?/1` → `Code.ensure_loaded? and new_style?`). A typo / a
  non-Behavior (`String`) is rejected at the boundary. **A data-role cannot
  reference a behavior that does not already exist as compiled code.**
- **`requested_caps` must be `%{behavior:, action:}` maps**, key-hygiene
  canonicalized to atoms; value canonicalization + minting deferred to CapMint.

### 1.2 `Ezagent.RoleRegistry` — boot registration + lookup
`apps/ezagent_core/lib/ezagent/role_registry.ex`. An ETS `:set`
(`:ezagent_role_registry`), key = role NAME (string), value = validated
`%Role{}`.

- `register/1` validates through `Role.new/1` (invalid recipe raises).
- **Effectively immutable / append-only at runtime**: identical re-register is
  idempotent; a *different* recipe under an existing name **raises**
  (`"Two plugins must not claim the same role name."`). There is no `update`,
  no `delete`. The only writer today is `boot/1`.
- The moduledoc itself flags the data follow-up:
  *"The forkable, persisted `template://<ws>/role/<name>` Template subtype is a
  documented follow-up."* and *"The `RoleRegistry` lookup IS that re-point seam."*

### 1.3 The `roles/0` callback + boot registration
`apps/ezagent_core/lib/ezagent/plugin.ex`: `@callback roles() :: [map()]`
(optional, defaults `[]`); `boot/1` does
`Enum.each(plugin_module.roles(), &Ezagent.RoleRegistry.register/1)`.
Exemplars: `EzagentPluginCc.Application.roles/0 → OrchestratorRole.recipe/0`;
`EzagentPluginKanban.Application.roles/0 → kanban_manager_recipe/0`;
`EzagentPluginPy.Application.roles/0 → np_role_recipe/0`.

### 1.4 RF-5a consume path — `create_agent(flavor, role)`
`apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create/role_step.ex`.
One **generic** role step (no per-role branch):

1. `resolve/2` — `RoleRegistry.lookup(name)` → recipe; `Role.Compose.materialize`
   unions role behaviors with the flavor's per-instance behaviors and produces
   the **context-free** `sandbox_content` (`skills/plugins/prompt/script`).
2. `mint_and_grant_caps/4` — `Role.CapMint.mint/3` runs `requested_caps` through
   the **flavor's** `:cap_policy` (RF-8 seam; `native`/`py` both = "grant exactly
   the recipe's pairs, nothing else, fail-closed"), then grants via
   `Ezagent.Workspace.grant_initial_caps/3`.
3. Durable markers: `passive` (RF-6, non-principal isolation) + `role` name (RF-7,
   list-by-role read model).

**The two security chokepoints already in this path** (load-bearing for the data
question):
- **CapMint fail-closed authorization** (`role/cap_mint.ex`): inject
  `kind/instance/workspace_uri`, drop malformed cap *values*, then
  `policy.(needed) == true` (strict — a non-true or a *raising* predicate drops
  the cap), then mint via `Capability.normalize!/2` (the sole grant chokepoint,
  mandates `workspace_uri`). A rejected/un-mintable cap is **dropped, never
  copied**.
- **Grant under caller authority** (`grant_initial_caps`, `{:held_by, caller}`):
  the RoleStep moduledoc states it plainly — *"a non-admin creator must ALREADY
  hold the role's `requested_caps` or the create fails-closed at grant … no
  privilege escalation via a role recipe."* The `granter` recorded on every
  minted cap is `caller` (`require_caller/1` → `params.caller`, a real `%URI{}`)
  — **#154-clean: `granted_by` is the real instantiating entity, never the role
  or its author.**

---

## 2. The proliferation pain — what "add a role" costs today

To add one role today (e.g. `salesperson-fixture` or `card-creator`):

| Step | Cost |
|---|---|
| Pick/own a plugin | A role is declared by a plugin's `roles/0`. A new role either rides an existing plugin or needs a plugin. |
| Write a `*_role_recipe/0` | Elixir code: skills, plugins, prompt, behaviors (must be real modules), `requested_caps` pairs, optional script. |
| Wire `roles/0` | Add the recipe to the plugin's `roles/0` list. |
| Cap-policy (if caps) | The flavor needs a `:cap_policy` (native/py have the generic one; a *new* flavor would need one). |
| Tests | `*_role_test.exs` asserting the exact recipe (every existing role has one). |
| **Compile + release + deploy** | The role does not exist until the new BEAM is built and the node restarts. |

**Who can add one: developers only.** There is no runtime authoring surface. A
tenant who wants "a salesperson role with these skills + this persona" cannot
self-serve; it is a PR + a deploy. *This is exactly the proliferation tax the
lead is worried about* — and it is real for the **tenant-authored long tail**
(personas, skill bundles, prompt variants). It is **not** a real tax for
*built-ins* (orchestrator/kanban/np ship with their plugin regardless).

That split — built-ins are cheap-in-code, the tenant tail is expensive-in-code —
is the whole case for a hybrid rather than an all-or-nothing flip.

---

## 3. Runtime-data roles — what it would take

The persistence and validation machinery is **mostly already there**:

- **Serialization**: `Role.new/1` is already atom+string-key symmetric for
  exactly this — a persisted recipe is just the map it already consumes.
- **Validation at the boundary**: `Role.new/1` already does shape + flavor-field
  + cap-axis + behavior-module validation. A data-role gets the *same* boundary
  for free.
- **Registry indirection**: `RoleRegistry.lookup/1` is already the single read
  point; the design names it as the re-point seam.

What is genuinely **missing**:

1. **A persisted store + a load-from-data registry path.** The registry's only
   writer today is `boot/1`. A data path needs (a) a durable object, (b) a
   loader that registers from data, and (c) a mutation story (the registry today
   *raises* on a different recipe under the same name — fine for "two plugins
   collide", wrong for "tenant edits their own role"; the immutable-object +
   re-point pattern resolves this — you never mutate in place, you publish a new
   object and re-point).
2. **A create/edit/validate authoring surface** (CLI/console) — the agent-console
   CRUD work (`docs/together/2026-06-24/`) is the obvious host.

### 3.1 Where does the store live? — two candidates, and the task pre-picks one

The task suggests *"ride the existing `ConfigStore` immutable-object+pointer
model."* That is one option, but the evidence points at a **different, better-fit
vehicle**, so both are presented honestly:

| Candidate | What it is | Fit for roles |
|---|---|---|
| **`template://<ws>/role/<name>` Template subtype** (role-foundation-design's own nominee) | A forkable Template object; `RoleRegistry.lookup` re-points at it | **Best fit.** A role IS a forkable recipe; the design already nominates this; lookup is already the seam. Needs a `role`-type branch in the `template://` spawn resolver + a RoleTemplate Kind — **neither exists yet** (see open questions). |
| **`Ezagent.Socialware.ConfigStore`** (`config_store.ex` + `config_object.ex`) | Immutable `socialware_config_objects` + `ConfigPointer`; layers = `workspace/user/session`; keyed by `(workspace, subject_uri, key)` | **Pattern fits, subsystem does not.** ConfigStore is *per-subject config* (an agent's own soul/config layer, #607/#17). A role is **not** a subject's config — it has no `subject_uri`, it is a workspace-scoped reusable recipe. Forcing a role into the `(subject_uri, key)` shape mis-models it. |

**They share the immutable-object + pointer + fork pattern** (write a new object,
re-point a pointer, rollback = re-point back). They are **different subsystems
with different scoping.** Roles want workspace-scoped fork-from-template; that is
the Template path, not the subject-keyed ConfigStore path.

---

## 4. The security crux — three fields, three regimes (this is the hard part)

A role carries `script` + `skills`/`plugins`/`behaviors` + `requested_caps`. The
task frames this as one injection vector. It is actually **three different
containment regimes**, and seeing the asymmetry is what makes the gating design
fall out cleanly.

### 4.1 `requested_caps` — already structurally contained at instantiation
- `Role.new/1` rejects caps carrying materialization axes (no scope smuggling).
- `CapMint.mint/3` injects axes + authorizes fail-closed against the flavor
  policy + mints via the sole `normalize!` chokepoint; rejected caps are dropped.
- `grant_initial_caps` runs under `{:held_by, caller}` — **narrow-never-broaden.
  A data-role that requests caps its INSTANTIATOR does not hold fails closed at
  grant.** A non-admin who authors and instantiates a greedy role gets nothing
  extra.
- **#154 is preserved**: every minted cap's `granted_by` is the real
  instantiating `caller`, never the role or its author. Roles-as-data introduces
  **no unowned-cap risk**.

⇒ The cap vector is closed **except when an admin/genesis principal instantiates**
(they hold everything, so `{:held_by, caller}` is not a real ceiling for them).
That residual — *an admin blindly instantiating an over-requesting data-role* —
is **precisely** what a review→publish gate exists to catch. State it that way to
the lead: caps need governance only for the admin-instantiation case.

### 4.2 `skills` / `plugins` / `behaviors` — references to pre-existing artifacts
- `behaviors` MUST resolve to real loaded `Ezagent.Behavior` modules
  (`Role.new/1`). A data-role **cannot inject new code** through this field —
  only *reference* code that already shipped.
- `skills`/`plugins` are name refs installed into `config_dir`. The risk is
  "reference a skill/plugin the tenant shouldn't get", which is a *selection*
  problem (does this skill exist + is it permitted in this workspace), not a
  code-injection problem. Containable by an allow-list at publish time; no new
  executable content.

### 4.3 `script` — the ONE genuinely-new executable-content field
This is the field that actually forces governance.
- `script` is **operator-authored file content** written into `config_dir`
  (py-agent RF-5b channel). py-agent spec §0.1/§0.3 is explicit: *"a role's
  safety travels with its **script**"* and the script surface is
  **"operator-authored only … NOT an end-user code surface."**
- Its safety is bounded by the **execution sandbox** (np's numpy/sympy
  whitelist), **not** by CapBAC. CapBAC gates what the *agent* may dispatch;
  it does not constrain what arbitrary python a script runs inside its
  subprocess.

⇒ **A runtime-data role that carries a `script` is a runtime-authored executable.
That is the case CapBAC cannot contain and the case that mandates either
operator-only authorship or a review→publish gate before the data-role goes
live.** A *scriptless* data-role (skills + prompt + behaviors + caps — the
salesperson-persona / card-creator long tail) is far less dangerous: its only
residual risk is the admin-instantiation cap case (§4.1).

### 4.4 The gating design that falls out

| Role payload | Authoring allowed as data? | Gate |
|---|---|---|
| Scriptless, caps ⊆ what tenant authority can grant | **Yes, self-serve** | `{:held_by, caller}` at grant already fail-closes; publish-time skill/plugin allow-list |
| Scriptless, requests caps beyond instantiator (admin-instantiated) | Data, **but reviewed** | review→publish before live (closes the admin-blind-instantiate residual §4.1) |
| **Carries a `script`** | Data **only** behind review→publish, OR keep operator/code-only | review→publish mandatory; script is the uncontained-by-CapBAC vector (§4.3) |
| Trusted built-in (orchestrator/kanban/np) | Stay in code | plugin contract + PR review (today's gate) |

This is the hybrid, made precise: **the gate strength is a function of the
payload, and `script` is the dividing line.**

---

## 5. The synthesis — do roles-as-data + CR-governance + config-as-data converge?

**Partial convergence. Yes on the *flow*; no on the *store*.**

The config-evolve flow (the closest in-tree governance precedent) already is:

```
Turn (propose a delta)  →  approval gate (manage-cap)  →  apply_config_delta
   →  write immutable object + re-point pointer  (rollback = re-point back)
```

A role-as-data, governed, would be:

```
draft role recipe  →  review (publish gate)  →  publish
   →  write immutable role object + re-point RoleRegistry source
   (rollback = re-point to prior object)
```

**These are the same shape**: propose → authorize → write-immutable + re-point.
ConfigStore (`write_and_point/1`, `put_pointer`, rollback-by-re-point) is the
same shape again. So:

- **Right north star:** a **single governance + immutable-publish + pointer
  pattern**, reused across config / role / template, with one authoring/review
  surface. Roles-as-data becomes "CR-governed config" *in the sense that it uses
  the same draft→review→publish→re-point machinery* — that is the real, defensible
  convergence and it directly answers the proliferation pain without re-inventing
  governance per object type.
- **Over-reach:** collapsing roles, subject-config, and templates into one
  literal table/Kind. They have different scoping (`role` = workspace-scoped
  forkable recipe; `config` = `(subject_uri, key)`-keyed layer; `template` =
  forkable spawn source). Unifying their *table* mis-models the domain; unifying
  their *publish-and-pointer flow* is exactly right.

**Verdict:** converge the **governance flow**, not the storage. A role-as-data is
"CR-governed config" by *flow*, stored as a `template://…/role/…` object,
registered from the pointer — **not** stuffed into ConfigStore.

> Re-flag for the lead: this verdict assumes "the just-spec'd CR-governance" IS
> the propose→review→publish flow described above (which is what config-evolve
> already implements). If the actual CR-governance spec differs, re-check.

---

## 6. Recommendation — HYBRID, phased

**Keep code for trusted built-ins; add a data path for tenant-authored roles,
gated by payload, on the `template://…/role/…` seam, using the shared
publish-and-pointer governance flow.**

### Phase 0 — decision + foundations (no new role types yet)
- Lead confirms: (a) hybrid is the target; (b) "CR-governance" == the
  propose→review→publish flow above; (c) Template seam (not ConfigStore) is the
  role store.
- Confirm the `RoleRegistry` mutation story: replace "raise on different recipe"
  with "register-from-data re-points to a new immutable object" for the
  tenant-namespaced names (built-in names stay collision-guarded).

### Phase 1 — scriptless tenant roles, self-serve, no new governance
- Persisted `template://<ws>/role/<name>` object (RoleTemplate Kind +
  `template://` role-type resolver branch — **the unestimated machinery, see
  open questions**).
- Registry loads from the pointer; `Role.new/1` validates as today.
- **No script field allowed in this phase.** Caps gated by the existing
  `{:held_by, caller}` fail-close — no new governance code needed for the
  self-serve case. Authoring surface = agent-console CRUD.
- Invariant test: a tenant-authored scriptless role instantiated by a non-admin
  grants ⊆ caller-held caps (proves no escalation).

### Phase 2 — review→publish governance (closes the admin + script cases)
- A draft → review → publish flow re-using the config-evolve approval-gate shape;
  publish re-points the role object.
- Mandatory for: (a) roles requesting caps beyond the instantiator
  (admin-instantiation residual §4.1); (b) **any role carrying a `script`**
  (§4.3).
- Invariant test: a script-carrying data-role cannot go live without a recorded
  reviewer/approver (the #154-style "accountable approver" stamp, mirroring
  config-evolve's recorded settler).

### Phase 3 (optional) — converge the surface
- One authoring/review console + one publish-and-pointer library shared by
  role / config / template. Only after Phases 1–2 prove the shape; this is the
  "north star, not now" piece.

---

## 7. Open questions for the lead

1. **CR-governance spec** — does one exist outside esr-ng/esr/cc-openclaw? I found
   none. If it does, the §5 verdict must be re-mapped to its exact shape. If not,
   confirm config-evolve's flow is the intended governance model.
2. **Store choice** — Template seam (my recommendation, the design's own nominee)
   vs ConfigStore (the task's suggestion). I argue Template; confirm.
3. **The unestimated machinery** — the data path needs a `template://` role-type
   resolver branch **and a RoleTemplate Kind**, which role-foundation-design says
   *neither exists yet*. I did **not** read that resolver/Kind machinery; it is
   the unestimated cost of the data path. A recommendation is sound without it,
   but Phase 1's estimate is gated on scoping it.
4. **Script-carrying data-roles — allow at all?** Even behind review→publish, a
   runtime-authored script is the one uncontained-by-CapBAC vector. Option: keep
   `script` **code/operator-only forever** (data roles are scriptless), so the
   data path never opens the executable-content surface. This is the most
   conservative cut and may be the right one — it gives the tenant long-tail
   (personas/skills/caps) without ever exposing a runtime code surface.
5. **Tenant authority to grant caps** — Phase 1 leans entirely on
   `{:held_by, caller}`. Is that the intended ceiling for tenant role authoring,
   or is an explicit per-workspace cap allow-list also wanted at publish time?
6. **Built-in/data name collision** — should tenant role names be namespaced
   (e.g. `ws/<name>`) so a tenant can never shadow or collide with a built-in
   (`orchestrator`, `kanban-manager`, `np`)?

---

### Appendix — primary sources (esr-ng origin/main)
- `apps/ezagent_core/lib/ezagent/role.ex` — struct, `@flavor_fields`,
  `@cap_materialization_axes`, atom/string-key symmetry, behavior-module + cap
  validation.
- `apps/ezagent_core/lib/ezagent/role_registry.ex` — boot register, lookup,
  raise-on-divergent (immutability), "Template subtype is a follow-up… lookup IS
  the re-point seam".
- `apps/ezagent_core/lib/ezagent/role/compose.ex` — context-free content/behavior
  compose; caps deliberately NOT composed here.
- `apps/ezagent_core/lib/ezagent/role/cap_mint.ex` — fail-closed authorize +
  mint; drop-never-copy.
- `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create/role_step.ex`
  — RF-5a generic step; `{:held_by, caller}` grant; `granter: caller` (#154);
  file-flavor role deferred (RF-5b).
- `apps/ezagent_plugin_{native,py}/lib/.../cap_policy.ex` — "grant exactly the
  recipe pairs, fail-closed" flavor policy (RF-8 seam).
- `apps/ezagent_plugin_{cc,kanban,py}` `roles/0` + `*_role_recipe/0` — the three
  code-seeded built-ins.
- `apps/ezagent_domain_identity/lib/ezagent/socialware/{config_store,config_object}.ex`
  — immutable-object + pointer + re-point-rollback pattern.
- `docs/together/2026-06-25/specs/role-foundation-design.md` — names the
  `template://<ws>/role/<name>` forkable-Template follow-up + passive isolation.
- `docs/together/2026-06-25/specs/py-agent-flavor-spec.md` §0.1/0.3 — "safety
  travels with the script"; script is operator-authored-only, not an end-user
  code surface.
- `docs/superpowers/specs/2026-06-11-agent-owned-config-evolve-design.md` —
  Turn → approval gate → apply, immutable object + pointer (the governance
  precedent).
- `.claude/skills/ezagent-developer/references/capbac.md` — Decision #154 (every
  `granted_by` a real accountable entity).
