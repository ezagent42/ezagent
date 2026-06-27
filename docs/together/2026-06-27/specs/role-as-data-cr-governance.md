# SPEC — Roles as DATA in config + CR governance over role-config (UNIFIED)

> **Design doc, NOT implementation.** Skills loaded: `ezagent-developer`,
> `ezagent-socialware`. All code citations verified against `origin/main`
> (`3f68b502`). Worktree off `origin/main`; branch `docs/role-as-data-cr-spec`.
>
> **This SPEC SUPERSEDES** the hybrid / Template-seam conclusion of
> `docs/together/2026-06-27/notes/roles-as-runtime-data.md` (the
> "roles-as-data research"). That note recommended storing roles on the
> `template://<ws>/role/<name>` Template seam and keeping built-ins as code
> recipes. **The lead's refinement OVERRIDES both points** (§0). The research's
> *security analysis* (the #154 cap chain, the three-field containment regimes,
> `script` as the one new executable vector) is retained verbatim and is the
> spine of §6 — only its *store* and *built-in* conclusions are overridden.
>
> It **builds ON** `docs/together/2026-06-26/specs/cr-config-governance.md` (the
> minimal CR-over-ConfigStore SPEC, rev 3) and **generalizes** it: that SPEC's
> §4.1 explicitly says *"v1 rejects a non-agent `subject_uri` … workspace-subject
> CRs are a follow-up."* **Role-config governance IS that follow-up.**

---

## 0. The lead's refinement (the contract — supersedes the research)

1. **Roles are DATA (config), with a UNIFORM form for BOTH built-in/plugin roles
   AND user-runtime-created roles.** A built-in role is **not** a special
   code-recipe; it is the **same data shape** as a user-authored role.
2. **Behaviors (and other code/functionality) are a SEPARATE concern, living in
   PLUGINS (installed code).** A role (data) only **references** behaviors by
   module name; the plugin **installs** the behavior code. Built-in/plugin roles
   therefore *do* ship code that must be installed (the behaviors, in the
   plugin) — **but the role's core config and a user's runtime-authored role are
   FORM-IDENTICAL config objects.** Only the *seeding origin* differs.
3. **Store the role DATA directly in CONFIG (ConfigStore)** — a role is a kind of
   config object. (Overrides the research's "store on the `template://` seam".)
4. **CR governance is the general flow over config objects, and a role is one
   such object → "cr-as-role".** The SAME `draft → review → publish → re-point`
   (rollback = re-point) governs role-config exactly as it governs agent-config.
   cr-governance generalizes from "agent config approval" to **"config-object
   governance,"** role-config being a first-class object type.

---

## 1. The spine — CR generalizes to be config-object-type-parametric

The unification is **not** "stuff a role into an agent's config." It is:
**the minimal-CR core is already object-type-agnostic; today it is *bound* to an
agent subject in exactly three places that have no analog for a role.** Make
those three a *parameter* (`subject_type`), and the same core governs both.

### 1.1 What is genuinely SHARED (the CR core — REUSED unchanged)

From cr-config-governance rev 3, every one of these is type-agnostic and reused
**verbatim** for role-config:

| Core mechanism | Source (verified) |
|---|---|
| Immutable `ConfigObject` (append-only `(id, ws, subject, key, body, created_by, source_turn_id)`) | `socialware/config_object.ex` L16-22 |
| Mutable `ConfigPointer` + `resolve/4` + `put_pointer/1` (returns `previous_config_id`) | `config_store.ex` L40-90,141 |
| Stage = write an **inert** immutable object, point NO layer (`write_object_staged/1`, `cr-stage:` fence) | cr-spec §4.2 |
| Status-gated publish idempotency (`open → published` one-way) | cr-spec §4.3 step 1 |
| Atomic multi-pointer flip in one `Ecto.Multi` | cr-spec §4.3.1 |
| Base-drift guard (`resolve/4` must still resolve to `base_object_id`) | cr-spec §4.4 |
| **Scope guard** `fetch_matching_object/1` `{config_id, workspace_uri, subject_uri, key}` | `config_store.ex` L340-352 |
| Re-point rollback to the durable `published_prev_object_id` | cr-spec §4.5 |
| Plain `render_*` preview diff, no lint/reviewer (rev 3 cut those) | cr-spec §5 |
| `ConfigChangeRequest` / `ConfigChangeItem` envelope + items | cr-spec §3 |

**None of the above changes.** A `ConfigChangeRequest` whose `subject_uri` is a
role URI (not an agent URI) flows through the identical stage→publish→rollback
machinery, because staging/flipping/rolling-back operate purely on
`(ws, subject, key)` tuples and immutable object bodies — they never inspect
*what kind of thing* the subject is.

### 1.2 What is BOUND to "subject = agent" today (the three parameters)

cr-config-governance §4.1 / §4.3-step-5 / §6 couple CR to an agent subject in
three spots with **no analog for a role**. These become the `subject_type`
parameter of the generalized CR:

| Coupling point | Agent (today) | Role (this SPEC) |
|---|---|---|
| **Authoring cap** (§6) | the agent's **manage** cap `cap(:agent, Manage, :any)` | a new **workspace-level role-authoring cap** `cap(:workspace, Workspace, :author_role)` (sibling to the shipped `:add_template`/`:remove_template` caps, `behavior/workspace.ex` L341-342) |
| **Dispatch target + self-binding** (§6) | publish dispatches TO the subject agent; CE-1 rebinds `subject_uri → self_uri` | publish dispatches TO the **Workspace Kind** (it owns the workspace and the role subject); rebinds `subject_uri`/`workspace_uri` to the workspace-scoped role URI it authorizes |
| **Publish side-effect** (§4.3 step 5) | fires `sandbox.write_path`, materializes `CLAUDE.md` into the agent's `config_dir` | fires **`RoleRegistry` cache-invalidate** for `(ws, role_name)` — NO config_dir, NO `CLAUDE.md` (a role is not a running agent) |

> **Why this is a true unification, not a forced fit (pre-empting codex's
> "force a bad fit?"):** the three divergences are *exactly* the three places
> cr-config-governance itself flagged as agent-specific ("CE-1 self-binding
> requires an agent handler"; "`sandbox_write_effects/3` no-ops without a
> `:sandbox` sibling"; "the cap is the agent's manage cap"). They are not
> incidental — they are the *subject-type seam*. The shared core (stage inert
> object / atomic flip / drift+scope guard / status-gated idempotency / re-point
> rollback) is genuinely identical. The SPEC does NOT paper over them — it names
> them as the parameter and shows the rest is shared. This is precisely the
> generalization cr-config-governance §4.1 deferred.

### 1.3 Refactor shape (NOT implementation — for the plan)

`ConfigChangeStore` (the CR/item row owner) stays subject-agnostic — it already
is; it only writes/reads CR rows + delegates to `ConfigStore`. The
subject-type-specific trio (cap, dispatch target, publish hook) lives in the
*behavior* layer: `Ezagent.Behavior.ConfigGovernance` (agent Kind, shipped path)
gains a **sibling** `Ezagent.Behavior.RoleGovernance` (Workspace Kind). Both
delegate stage/publish/rollback bookkeeping to the same `ConfigChangeStore`;
they differ only in `required_caps/0`, the self-binding target, and the
post-publish effect (`sandbox.write_path` vs `role_registry.invalidate`). No
public-API widening beyond the new behavior + one `RoleRegistry` read-through.

---

## 2. The data model — a role as a ConfigObject

### 2.1 Field mapping (recipe → ConfigObject body)

A role's recipe is the map `Ezagent.Role.new/1` already consumes
(`role.ex` L84-108). It maps onto `ConfigObject` (`config_object.ex` L16-22) as:

| ConfigObject column | Role value |
|---|---|
| `workspace_uri` | the role's owning workspace (system-ws for a built-in seed; tenant-ws for a fork — §4) |
| `subject_uri` | **the role's OWN URI** (`entity://role/<ws>/<name>`) — see §2.2 |
| `key` | the fixed literal `"role"` (one role-recipe slice per role subject) |
| `body` | the **whole recipe map** — `%{name, passive, skills, plugins, prompt, script, behaviors, requested_caps, session_template}` |
| `created_by` | the authoring entity (the workspace granter at seed; the caller at runtime author) |
| `source_turn_id` | `cr-stage:<cr_id>:<item_id>` while staged; `cr-publish:<cr_id>` once published; `role-seed:<ws>:<name>` at boot seed |

**`body.behaviors` is stored as module-name STRINGS** (e.g.
`"Elixir.Ezagent.Behavior.Template"`), never as atoms in the JSON map. This is
load-bearing for round-trip + security: `Role.new/1` is **already atom+string-key
symmetric** and **already validates each behavior to a real loaded
`Ezagent.Behavior` module** (`role.ex` L92-101 + research §1.1
`behavior_module?/1`). So:
- the body round-trips through `ConfigObject.body :map` (JSON) losslessly;
- on rehydrate, `Role.new/1` rejects any behavior that is not a *currently-loaded
  compiled module* — **a data-role can only REFERENCE behaviors a plugin has
  already installed** (lead refinement point 2). The role data references; the
  plugin installs.

### 2.2 Scoping — the role is its OWN config subject (resolves the research's objection)

The research (§3.1) objected: *"ConfigStore is per-subject config; a role has no
`subject_uri`; forcing a role into the `(subject_uri, key)` shape mis-models
it."* **That objection only holds if the role is shoved under SOME OTHER
subject's config layer.** It is resolved by making **the role its own config
subject**:

```
subject_uri = entity://role/<workspace>/<name>     # the role IS the subject
key         = "role"                               # fixed
```

This is not a hack — it is the honest model. A role is a first-class addressable
config object; it deserves its own subject URI exactly as an agent has one. The
role is **not** crammed into another subject's `(subject_uri, key)` slot — it owns
its slot. Confirmed against the two scope-bearing reads:
- `resolve/4` takes `(layer, ws, subject, key)` — all four supplied → resolves.
- `fetch_matching_object/1` matches `{config_id, workspace_uri, subject_uri, key}`
  exactly (`config_store.ex` L340-352) — the publish scope guard works unchanged:
  a tampered CR row cannot cross-bind one role's subject/key to another role's
  object.

**Why subject = role-URI and NOT subject = workspace + key = `role/<name>`:**
the discriminator is the **one-open-CR-per-`(workspace, subject)`** partial
unique index (cr-spec §3.1) + concurrent role edits:
- *subject = workspace, key = `role/<name>`* → every role in a workspace shares
  ONE subject → only ONE open role-CR per workspace at a time → two devs editing
  two different roles concurrently collide. **Rejected.**
- *subject = the role's own URI* → each role is its own subject → one open CR
  **per role** → concurrent edits of different roles are independent. **Chosen.**

The role is **workspace-scoped + forkable** (lead's requirement) via the
`workspace_uri` axis + the §3 lookup fallback: a tenant "forks" a built-in by
copying its object body into the tenant workspace under
`entity://role/<tenant-ws>/<name>` and pointing it.

### 2.3 Layer

Role-config uses the **`workspace`** layer of the cascade (`@layers =
~w(workspace user session)`, `config_store.ex` L15). A role is a
workspace-scoped reusable recipe; `user`/`session` layers are not meaningful for
a role and are not used. (One pointer per role subject, on the `workspace` layer.)

---

## 3. `RoleRegistry.lookup/1` resolves from ConfigStore (read-through; ETS = cache)

Today `RoleRegistry.lookup/1` reads ETS only, written solely by `boot/1`
(`role_registry.ex` L82-90, "the only writer today is `boot/1`"). The change:

**`lookup/1` becomes a read-through over ConfigStore; ETS is demoted to an
invalidate-on-publish cache.**

```
lookup(name) within caller workspace ws:
  1. ETS hit for (ws, name) AND not marked stale → return cached %Role{}
  2. else resolve from ConfigStore:
       a. obj = ConfigStore.resolve("workspace", ws, entity://role/<ws>/<name>, "role")
       b. if :none → fall back to (system_ws, name):
            ConfigStore.resolve("workspace", system_ws,
                                entity://role/<system_ws>/<name>, "role")
       c. if still :none → :error
       d. {:ok, role} = Ezagent.Role.new(obj.body)   # existing validation boundary
       e. cache (ws,name)→role in ETS; return {:ok, role}
```

Two consequences, both desirable:

1. **Rollback-by-repoint works for roles FOR FREE.** A `rollback_cr` re-points
   the role's pointer to the prior object (§5.4); the *next* `lookup/1`
   re-resolves to that prior body. No role-specific rollback code — the CR core's
   re-point rollback IS the role rollback. (This is the cleanest argument for the
   ConfigStore store over the Template seam: the registry indirection the
   research already named as "the re-point seam" is now *literally* a ConfigStore
   re-point.)

2. **The cross-workspace fallback (2b) is the ONE new resolution wrinkle.**
   `ConfigStore.resolve/4` does **not** fall back across workspaces (it is a
   single-tuple read). The `(caller-ws → system-ws)` fallback lives in
   `RoleRegistry.lookup/1`, NOT in `ConfigStore`. This is what delivers
   "workspace-scoped + forkable" without seeding every built-in into every
   tenant: a tenant sees the system built-in until it forks its own. **Flagged
   for the lead** (OQ-2) — it is a small, contained read-side addition, but it is
   genuinely new behavior not present in `resolve/4`.

**Cache invalidation:** `publish_cr`/`rollback_cr` for a role-subject emit a
`role_registry.invalidate(ws, name)` effect (the role-subject analog of the
agent's `sandbox.write_path` — §1.2). The "different recipe under same name
raises" guard (`role_registry.ex` L72-77) is **removed for the ConfigStore path**
— immutability is now the append-only ConfigObject + re-point, not an ETS
raise. The boot-collision guard for *two plugins claiming one name* is preserved
as a **seed-time** check (§4.2), not a runtime lookup raise.

---

## 4. Built-in seeding — a plugin ships BEHAVIORS as code, SEEDS its role(s) as data

This is lead refinement point 2 made concrete: **the plugin's CODE is the
behaviors; the plugin's ROLE is seeded as config data that references those
behaviors.** Built-in and user roles are then form-identical config objects —
only the seeding origin differs.

### 4.1 The seed mechanism

The `roles/0` plugin callback (`plugin.ex` L216) is RETAINED, but its boot
consumer changes. Today `boot/1` does
`Enum.each(plugin_module.roles(), &RoleRegistry.register/1)` (ETS insert,
`plugin.ex` L482-484). New boot behavior — **seed into ConfigStore, not ETS**:

```
for each recipe in plugin.roles():
  name = recipe.name
  ws   = system_workspace_uri          # canonical system ws (one place, all built-ins)
  subj = entity://role/<system_ws>/<name>
  if ConfigStore.resolve("workspace", ws, subj, "role") == :none:
      ConfigStore.write_and_point(%{
        layer: "workspace", workspace_uri: ws, subject_uri: subj, key: "role",
        body: recipe (with behaviors as module-name strings),
        created_by: system_workspace_granter,
        source_turn_id: "role-seed:#{ws}:#{name}"
      })
  # else: a published override exists → DO NOTHING (idempotent + override-safe)
```

### 4.2 Idempotency + override-safety (the trap the advisor flagged)

A naive boot-reseed would **clobber a tenant's published edit of a built-in** on
every restart. The guard: **seed the object + point ONLY IF no pointer exists**
for the role's `(ws, subject, "role")`.

- First boot: no pointer → seed writes object + points. Built-in is now config.
- Reboot, unchanged: pointer exists → **no-op**. Idempotent.
- Reboot after a published override of that built-in: pointer exists (aimed at
  the override object) → **no-op**. The override survives the restart.

This is **both idempotent AND override-safe** with one `resolve == :none` check —
no version compare, no upsert. Note the structural reason this works without a
cascade fallback: the cascade layers are only `workspace|user|session` — there is
**no "system/default" layer below `workspace`** to lean on for precedence. So we
do NOT model built-ins as a lower cascade layer; we model them as a seeded
`workspace`-layer object in the **system workspace**, reached by the §3
`lookup` fallback. Seed-once + lookup-fallback is the substitute for a missing
default layer.

**Two-plugins-one-name collision** (the guard `role_registry.ex` L72-77 used to
enforce at ETS write) moves to seed time: if two plugins' `roles/0` declare the
same `name` in the system workspace, the second seed sees an existing pointer
with a *different body* → **fail loud at boot** (`{:role_seed_collision, name}`),
preserving the original invariant ("two plugins must not claim the same role
name") at the seam where it actually applies.

---

## 5. CR-as-role governance — the draft→publish→re-point flow over role-config

The cr-config-governance lifecycle (`open → published`, `+ rejected,
rolled_back`) applies unchanged; only the three §1.2 parameters differ.

### 5.1 Who authors / publishes (caps)

**The cap is the new workspace-level role-authoring cap**
`cap(:workspace, Ezagent.Behavior.Workspace, :author_role)` — a sibling to the
shipped `:add_template` / `:remove_template` workspace caps
(`behavior/workspace.ex` L341-342). Enforced by the **standard dispatch
step-5.5 gate** (not a facade `if`), because role-CR actions are a new
`Ezagent.Behavior.RoleGovernance` Lifecycle behavior on the **Workspace Kind**
whose `required_caps/0` declares `:author_role`. Per cr-config-governance rev 3's
cut: **whoever may author may publish** — no two-person rule, no separate
reviewer cap, for the *scriptless* case. (The script case is the one exception —
§6.3 / OQ-1.)

### 5.2 draft → publish (the flow, role-parameterized)

| Step | Role-config behavior (delta from cr-spec) |
|---|---|
| `open_cr` | open for `subject_uri = entity://role/<ws>/<name>`; one-open-per-subject index now means one open CR **per role** (§2.2). Authoring cap, not manage cap. |
| `stage_item` | write inert `ConfigObject` (the proposed recipe body) with `source_turn_id = cr-stage:…`, point no layer. Body validated via `Role.new/1` at stage time (fail-loud on a malformed recipe — same boundary, §2.1). Layer fixed `"workspace"`, key fixed `"role"`. |
| `preview_cr` | plain diff: `render_role(current_body)` vs `render_role(proposed_body)` — the role analog of `render_soul/1`. No lint, no checks (rev 3). A trivial deterministic render of `name/persona/skills/plugins/behaviors/caps/script-present?`. |
| `publish_cr` | **identical core**: status-gate → drift guard (`resolve/4` == base) → scope guard (`fetch_matching_object/1`) → atomic `put_pointer` flip → record `published_prev_object_id`. **Differs only in step 5:** fire `role_registry.invalidate(ws, name)` (NOT `sandbox.write_path`) — dispatched to the Workspace Kind. |
| `reject_cr` | free; nothing was pointed-to. |

### 5.3 The `script` field — gated through publish (the injection line)

`script` is operator-authored file content written into a py-agent's `config_dir`
(research §4.3) — **the one field whose safety is bounded by the execution
sandbox, NOT CapBAC.** In the data-role world it becomes runtime-authorable
content. The gate:

- A role-CR that stages a body carrying a non-nil `script` is the **only**
  payload that re-opens the CapBAC-uncontained executable surface.
- **behaviors are NOT this vector** — they are install-time plugin code, trusted,
  referenced-not-injected (§2.1, lead point 2). A data-role cannot inject a
  behavior; `Role.new/1` rejects any behavior that is not a loaded module.
- The script's runtime safety remains the **execution sandbox** (np's
  numpy/sympy whitelist, research §4.3) — unchanged. CR governance adds the
  *authoring* gate (review→publish), not a new execution containment.

**Open tension surfaced to the lead, NOT silently decided (OQ-1):** the
research (§4.3 / OQ-4) calls for an **accountable approver** (review→publish) for
script-carrying roles. But cr-config-governance **rev 3 explicitly CUT the
`review` state and the two-person rule** ("whoever may edit may publish"). For
scriptless roles, rev-3's cap-gated publish is sufficient. For a
**script-carrying** role, the minimal CR gives **no approver separation** — the
author publishes their own script. This is the one place the unification does NOT
automatically satisfy the security analysis. See §6.3 + OQ-1.

### 5.4 rollback (re-point — free for roles, §3)

`rollback_cr` re-points the role's pointer to `published_prev_object_id`
(cr-spec §4.5, REUSED) + fires `role_registry.invalidate`. The next `lookup/1`
re-resolves the prior recipe. No role-specific rollback mechanism.

---

## 6. Security — re-confirming the #154 chain holds when a role is runtime-authored config

### 6.1 The chokepoint is SOURCE-AGNOSTIC (the spine of the verdict)

Roles-as-config changes only the **SOURCE** of the recipe map (boot ETS → boot
ConfigStore seed / runtime CR). It does **not** change the instantiation path.
`create_agent` / `RoleStep` resolve a role and instantiate it through the
**identical** pipeline regardless of where the recipe came from
(`role_step.ex` L198-210 → `Role.Compose` → `Role.CapMint` → `grant_initial_caps`):

```
Role.new/1            (validate: flavor-field reject, cap-axis reject,
                       behaviors-must-be-loaded-modules)   role.ex L84-108
  → Role.Compose      (context-free content/behavior union; caps NOT composed)
  → Role.CapMint.mint (inject axes; fail-closed authorize vs flavor policy;
                       drop-never-copy; mint via Capability.normalize!)
  → grant_initial_caps {:held_by, caller}   (re-read CALLER caps; narrow-never-
                       broaden; granter = caller)   role_step.ex L21-31
```

`RoleStep` **never learns where the recipe came from.** Therefore every #154
property the research proved holds **unchanged**:

- **#154-clean granted_by:** every minted cap's `granted_by` is the real
  instantiating `caller` (`{:held_by, caller}`, granter = caller, `role_step.ex`
  L26-30) — never the role or its author. Roles-as-config introduces **no
  unowned-cap risk.**
- **Caller-authority ceiling:** a non-admin who authors a greedy data-role and
  instantiates it gets `{:grant_failed, …}` — they must ALREADY hold the
  requested caps (role_step moduledoc). No escalation via a runtime-authored
  recipe.
- **No scope smuggling:** `Role.new/1` rejects a cap carrying
  `kind/instance/workspace_uri/granted_by/granted_at` (`role.ex`
  `@cap_materialization_axes` L40) — the codebase's own anticipation of an
  operator/data-authored recipe as an injection vector. Holds for the CR-authored
  body identically (same `Role.new/1` boundary).

### 6.2 The create_agent chokepoint holds

The role-CR governs **authoring** the recipe (the config object). Instantiation
is still the SAME `create_agent` chokepoint, behind the SAME `:create_agent`
workspace cap, running the SAME fail-closed CapMint. Authoring a role does NOT
instantiate it; the two gates are orthogonal and both intact.

### 6.3 The script execution-sandbox gate holds — with one caveat

- `script` content is still written into `config_dir` and bounded by the
  **execution sandbox** (the np whitelist) at *run* time — CR does not weaken
  that; it adds an authoring gate on top.
- **Caveat (the one residual):** under rev-3 minimal CR, a script-carrying role
  has **no approver separation** at authoring time (§5.3). The execution sandbox
  still contains *what the script can do*, but "should this script exist as a
  live role at all" has only the single author's cap behind it. **This is the
  one place the security verdict is conditional on the lead's OQ-1 decision.**

### 6.4 Verdict

**For scriptless roles: SECURE — strictly equivalent to today.** The chokepoint
is source-agnostic; #154, the caller-authority ceiling, cap-axis rejection, and
behaviors-must-be-loaded all hold because the instantiation path is byte-identical
and only the recipe's storage location moved. The authoring surface is new but is
gated by a real workspace cap through the structural dispatch gate.

**For script-carrying roles: SECURE AT EXECUTION (sandbox unchanged), but the
AUTHORING gate is weaker than the research recommends** (no approver separation
under rev-3). Resolve via OQ-1 before opening the script field to runtime authors.

---

## 7. Migration — from code-`roles/0` to data-roles-in-config

### 7.1 Path (back-compat throughout)

1. **Add the ConfigStore role subject + read-through `lookup/1`** (§3) with the
   `(caller-ws → system-ws)` fallback. ETS becomes an invalidate-on-publish
   cache.
2. **Change `boot/1`'s `roles/0` consumer** from `RoleRegistry.register/1` (ETS
   insert) to the **seed-once-if-no-pointer** ConfigStore seed (§4). `roles/0`
   itself and every plugin's `*_role_recipe/0` are **unchanged** — they remain
   the *declaration* the seed consumes.
3. **Add `Ezagent.Behavior.RoleGovernance`** (Workspace Kind) + the
   `:author_role` cap (§5) — the runtime authoring path. Agent-config
   `ConfigGovernance` is untouched.
4. **Console authoring surface** (CRUD over role-CRs) — out of this SPEC's scope;
   hosts on the agent-console CRUD work (`docs/together/2026-06-24/`).

No behavior of an *instantiating* caller changes at any step (the chokepoint is
source-agnostic, §6.1) — `create_agent`/`RoleStep` consume `lookup/1` exactly as
today.

### 7.2 Elimination criterion (the completion gate)

> Per MEMORY "completion-claim requires invariant test": the goal is "no code
> path resolves a role from `roles/0` as the runtime authority."

**`roles/0` survives ONLY as the boot SEED SOURCE.** No runtime lookup resolves a
role from `roles/0` or from a `roles/0`-derived ETS entry as *authority* — every
`lookup/1` resolves from ConfigStore (ETS is a cache *of* the ConfigStore
resolution, not an independent code-recipe store).

**Invariant test (fails when the goal is unmet):**
- After boot, **every** built-in (orchestrator, kanban-manager, np, kb, …) is
  resolvable via `ConfigStore.resolve("workspace", system_ws,
  entity://role/<system_ws>/<name>, "role")` (proves the seed wrote config, not
  just ETS).
- With the ETS cache **flushed**, `RoleRegistry.lookup(name)` STILL returns the
  built-in `%Role{}` (proves lookup resolves from ConfigStore, not from a
  surviving `roles/0` ETS write — i.e. no code-recipe authority remains).
- A built-in's recipe edited via a published role-CR is what `lookup/1` returns
  after a simulated reboot (proves seed-once override-safety + ConfigStore is the
  authority).

The code-recipe (`*_role_recipe/0`) remains *as a seed input only* — that is the
acceptable residual (lead refinement point 2: built-ins ship behaviors as code +
seed their role as data). A built-in role and a user role are then byte-identical
ConfigObjects; the elimination is of the runtime *code-recipe-as-authority*, not
of the seed declaration.

---

## 8. Test plan (delta over cr-config-governance §9; that suite is reused for the shared core)

1. **Role is its own subject** — a seeded built-in resolves at
   `(system_ws, entity://role/<system_ws>/<name>, "role")`; `fetch_matching_object/1`
   matches it; a foreign subject/key does not.
2. **lookup read-through** — flush ETS; `lookup(name)` resolves from ConfigStore
   and rehydrates via `Role.new/1` (behaviors as strings → loaded modules).
3. **Cross-ws fallback** — `lookup(name)` in a tenant ws with no own role falls
   back to the system-ws built-in; after a tenant fork, returns the tenant's.
4. **Seed idempotency** — re-running boot does not write a second object / does
   not move the pointer (no-op when pointer exists).
5. **Seed override-safety** — publish a role-CR overriding a built-in, simulate
   reboot; the override survives (seed no-ops).
6. **Seed collision** — two plugins declaring the same role name in the system ws
   fail loud at boot (`{:role_seed_collision, name}`).
7. **CR core reused** — stage writes an inert object (lookup unchanged until
   publish); publish flips the pointer atomically + records
   `published_prev_object_id`; status-gated idempotency; drift guard; scope guard
   (all the cr-spec §9 tests, retargeted to a role subject).
8. **Rollback = re-point** — publish then rollback a role-CR; `lookup/1`
   re-resolves the prior recipe (no role-specific rollback code).
9. **Authoring cap is structural** — a caller without `:author_role` gets
   `:unauthorized` at `open_cr`/`publish_cr` via the dispatch gate (not a facade
   check).
10. **Chokepoint source-agnostic (#154)** — a tenant-authored scriptless role
    instantiated by a **non-admin** grants ⊆ caller-held caps; every minted cap's
    `granted_by` = the instantiating caller (proves no escalation, no unowned
    cap). Byte-for-byte equal to instantiating the same recipe seeded as a
    built-in.
11. **Cap-axis rejection on the CR body** — a staged role body whose
    `requested_caps` carries `workspace_uri`/`granted_by` is rejected at
    `stage_item` via `Role.new/1`.
12. **Behaviors-must-be-loaded on the CR body** — a staged body referencing a
    non-loaded module name is rejected at `stage_item`.
13. **Script gate** — (pending OQ-1) a script-carrying role-CR is governed per
    the lead's chosen script policy; execution-sandbox containment unchanged.
14. **Elimination invariant** — §7.2 (the completion gate).
15. full `mix test` 0 failures + CI green (incl. `check_invariants`).

---

## 9. Where it lives + reuse map

| Concern | Status |
|---|---|
| Immutable object / pointer / atomic write / flip / re-point rollback / drift+scope guard / status-gated idempotency / staged-inert-object fence | **REUSED** (cr-config-governance core, subject-type-agnostic) |
| `ConfigChangeRequest` / `ConfigChangeItem` / `ConfigChangeStore` | **REUSED** (subject-agnostic envelope; role subject is just a non-agent `subject_uri`) |
| Role recipe struct + validation (`Role.new/1`: flavor/cap-axis/behaviors-loaded) | **REUSED** (the rehydrate boundary, `role.ex`) |
| Instantiation chokepoint (`RoleStep` → Compose → CapMint → grant `{:held_by, caller}`) | **REUSED UNCHANGED** (source-agnostic, §6.1) |
| `roles/0` plugin callback + `*_role_recipe/0` | **REUSED as SEED SOURCE only** (no runtime authority, §7.2) |
| `RoleRegistry.lookup/1` read-through from ConfigStore + ETS-as-cache + cross-ws fallback | **CHANGED** (§3) |
| `boot/1` `roles/0` consumer → seed-once-if-no-pointer into ConfigStore | **CHANGED** (§4) |
| `RoleRegistry` raise-on-divergent-recipe (runtime) | **REMOVED** (immutability = append-only object + re-point); collision guard → seed-time (§4.2) |
| `Ezagent.Behavior.RoleGovernance` (Workspace Kind) + `:author_role` cap + `role_registry.invalidate` publish hook | **NEW** (the subject-type-specific trio, §1.2/§5) |
| Role-recipe `render_role/1` preview diff | **NEW** (trivial deterministic render, analog of `render_soul/1`) |
| Two-person rule / review state / reviewer cap / lint | **CUT** (inherited from cr-spec rev 3) — except the open script question (OQ-1) |

---

## 10. Open questions for the lead

- **OQ-1 (blocks the script security verdict)** — **script-carrying roles vs
  rev-3 "no review state".** The research mandates an accountable approver for a
  role's `script` (the one CapBAC-uncontained vector); rev-3 minimal CR cut the
  review state ("whoever may edit may publish"). Three options:
  - (a) a **dedicated higher** cap `cap(:workspace, Workspace, :author_role_script)`
    distinct from `:author_role` — only that cap may publish a script-carrying
    role (cap-level separation, no review pipeline);
  - (b) keep `script` **operator/code-only even as data** — data-roles are
    scriptless; the script field is rejected at `stage_item` for runtime authors
    (research OQ-4's conservative cut; the data path never opens the executable
    surface);
  - (c) reintroduce approver-separation (`published_by != opened_by`) **for the
    script case only**.
  **Recommend (b)** — it gives the tenant long tail (personas/skills/caps) with
  zero new executable-content surface and needs no review-pipeline revival; open
  to (a) if runtime script authoring is a real near-term need. The security
  verdict for script-carrying roles is conditional on this.
- **OQ-2 (confirm scoping)** — the **system-workspace seed + `lookup`
  cross-workspace fallback** (§3, §4). `ConfigStore.resolve/4` has no cross-ws
  fallback today; this SPEC adds it in `RoleRegistry.lookup/1` only. Confirm the
  canonical system-workspace URI to seed built-ins under, and that the
  `(caller-ws → system-ws)` fallback (rather than a new cascade "default" layer)
  is the intended forkability mechanism.
- **OQ-3** — the role subject URI scheme `entity://role/<ws>/<name>` — confirm
  this is the desired addressable form (no `role://` scheme exists today; reusing
  `entity://` with a `role/` segment avoids a new scheme + dispatcher, invariant
  8). The fixed `key = "role"` per role subject is assumed.
- **OQ-4** — `RoleGovernance` on the **Workspace Kind** as the dispatch/
  self-binding target for role-CRs (the role-subject analog of the agent's
  CE-1 self-binding). Confirm the Workspace Kind is where role-authoring caps +
  the publish effect belong (it already owns `:add_template`/`:remove_template`).
- **OQ-5** — built-in name namespacing: should tenant role names be namespaced so
  a tenant can never shadow a system built-in via the §3 fallback, or is "a
  tenant fork of `orchestrator` shadows the built-in **for that tenant only**"
  (the natural fallback behavior) the desired semantics? (Recommend the latter —
  it IS forkability.)
