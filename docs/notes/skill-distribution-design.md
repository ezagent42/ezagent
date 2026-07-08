# Skill Distribution to Deployed Agents — Design Options

> Design research, 2026-07-08. Branch `docs/skill-distribution-research`.
> Companion: [`skill-distribution-design.zh_cn.md`](skill-distribution-design.zh_cn.md).
> Status: **research / recommendation** — no implementation in this branch.

Allen's direction: *"这个理论上应该由 recipe 去管理"* — how an agent gets its skills
must be governed by the **recipe** layer, not ad-hoc file copying. This doc maps
the current state, weighs three distribution options, and recommends one with a
phased migration.

---

## 1. The incident (why this is a distribution-design gap, not a packaging bug)

`mix release` packages **only each app's `priv/`** (Dockerfile.prod line 71). The
repo-root `.claude/skills/` tree is **not** inside any app's `priv/`, so it is
dropped from `_build/prod/rel/ezagent`. The prod runtime image is
`COPY --from=builder /app/_build/prod/rel/ezagent ./` (Dockerfile.prod line 107)
— just the release. The source `.claude/` that `COPY . .` brought into the
*builder* never reaches the *runtime*.

At spawn, an orchestrator agent needs the `ezagent-session-orchestrator` skill dir.
`OrchestratorBootstrap.resolve_skill_source/1`
(`apps/ezagent_plugin_cc/lib/ezagent/template/orchestrator_bootstrap.ex:266`)
resolves a skill ref by **walking up the directory tree from the cc plugin's
`priv_dir`** looking for `.claude/skills/<ref>/SKILL.md`. In every release image
the walk finds nothing → `{:skill_source_not_found, []}` → `role_degraded` →
**session create is dead on every deploy channel.**

A point-fix reportedly stages that one skill into a `priv/` before `mix release`
(the exact analogue of Dockerfile.prod lines 66-69, which already `npm install`
the feishu WS sidecar **into `priv/`** so the release bundles it). *(NOTE: I could
not locate the committed point-fix in `esr-ng-deploy/docker/Dockerfile.prod` nor a
prod `role_skill_sources` / `orchestrator_skill_source` app-env; its exact shape is
**to confirm**. Whatever form it took, it hard-codes a single skill.)*

The repo-root `.claude/skills/` holds **25 skill dirs** (+ a `SUPERPOWERS_VERSION.md`
marker file). Any future recipe that
references a *second* skill breaks identically. The fix must generalize skill
**content distribution**, not patch one ref.

---

## 2. Current-state map — every "agent needs an artifact at runtime" pathway

### 2.1 The recipe layer — declaration is ALREADY solved (and landed on `main`)

`Ezagent.Agent.Recipe` (`apps/ezagent_core/lib/ezagent/agent/recipe.ex`) — the
flavor-agnostic sandbox-content recipe (task #54; `Ezagent.Role` → `Recipe`
rename #127). Its moduledoc is the thesis Allen is invoking:

> **The CONTENTS of the sandbox are the RECIPE; HOW the sandbox is loaded is the
> FLAVOR.**

The struct already carries a first-class **`skills: [skill_ref :: String.t()]`**
field (alongside `plugins`, `prompt`, `script`, `behaviors`, `requested_caps`,
`contributions`, `session_template`, `config`). A recipe is stored **as data** —
a `ConfigObject` under `subject = recipe:<name>`, `key = "recipe"` — resolved
read-through by `Ezagent.Agent.RecipeRegistry`
(`apps/ezagent_domain_agent/lib/ezagent/agent/recipe_registry.ex`):

- `lookup/2`: ETS cache → caller-workspace `ConfigStore` → **system-workspace
  fallback** → rehydrate via `Recipe.new/1`. This is the "workspace-scoped +
  forkable" property: a tenant sees the system built-in until it forks its own.
- `seed_role_if_absent/2`: seeds a built-in recipe into the system workspace via
  the **three-state seed contract** (below), override-safe.

**So the recipe already declares WHICH skills an agent needs.** The gap is not
declaration. `OrchestratorRecipe.recipe/0` sets `skills: [@skill_ref]` today.

### 2.2 The gap — skill ref → skill **content** resolution

`Recipe` declares a skill by **name**. `OrchestratorBootstrap.install_role_sandbox/2`
consumes `sandbox_content.skills` and, per ref, calls `resolve_skill_source/1` to
turn the name into an **on-disk source dir**, then `File.cp_r` it into
`<config_dir>/skills/<ref>`. Resolution today (`:266`):

1. Config override — `:ezagent_plugin_cc, :role_skill_sources` (a `ref => abs_path`
   map) or the orchestrator's dedicated `:orchestrator_skill_source`. Manual,
   per-ref, unset in prod.
2. Else **walk up from the cc plugin `priv_dir`** for `.claude/skills/<ref>/SKILL.md`.

There is **no skill catalog / registry / store**. The pr6 design note flagged
this exactly: *"A generic name→source skill registry is OUT of PR-6 scope"*
(`docs/notes/pr6-desired-skills-caps.md:135`). **This is the missing layer.**

`desired_skills` on `AgentTemplate` content is a *second, domain-tier* declaration
of skill names — but it is **plumbed and never consumed** (no flavor's
`instantiate/3` reads the `"desired_skills"` data key). It shares the same missing
backend: a name that nothing can resolve to bytes on a deployed node.

### 2.3 config_dir materialization — where skill bytes land in an agent

`Ezagent.Credential.HomeRuntime`
(`apps/ezagent_core/lib/ezagent/credential/home_runtime.ex`) owns per-agent
config_dir materialization: `stage_and_swap/7` does `cp_r(reference_dir, staging)`
→ overlay creds → write `CLAUDE.md` → `chmod` → write `.ezagent-config-complete`
marker → `Materializer.atomic_replace(staging, target)`. Idempotent via the marker.
Today the orchestrator skill copy is a **separate** post-spawn step in
`OrchestratorBootstrap`, *outside* this atomic swap.

### 2.4 Reference model A — np/uv provisioning (recipe → artifact at spawn)

`apps/ezagent_plugin_np` provisions an np agent's Python env:

- **Declaration lives with the artifact, bundled in `priv/`**: the dependency set
  is a PEP-723 header *inside* `priv/python/np_compute_server.py` (numpy/sympy);
  the release bundles the script via `priv/`. Elixir only points at the file.
- **Shared, content-addressed provisioning**: `uv run --script` provisions into
  uv's machine-global cache (`~/.cache/uv`), not per-agent. First agent pays the
  ~9.6s cold cost; every later np agent on the box hits the sub-100ms warm cache.
- **Per-agent = the live process only**; the script source is shared read-only
  from `priv/`.
- **Synchronous by deliberate design.** Domain.Python's `init/1` blocks on a real
  `python.ping` before flipping ready — the SPEC explicitly rejected async
  `{:continue, :spawn}` to avoid a **false-readiness** window. (Correction to the
  research brief's "prefer fire-and-forget/async": np is a *sync-for-correctness*
  precedent, not an async one. See §5.4.)

**Lesson for skills:** bundle the artifact + its manifest in `priv/` (release-native
default); make the expensive/shared part machine-global, not per-agent.

### 2.5 Reference model B — socialware `$EZAGENT_HOME` seed + three-state contract

This is the closest analogue to "distribute post-build content to a deployed node
without rebuilding the release."

- **`Ezagent.Socialware.ManifestSeed.scan_all!/1`**
  (`apps/ezagent_domain_session/lib/ezagent/socialware/manifest_seed.ex`) runs
  once at boot (fired from the last-booting app) and scans **two** origins,
  deterministically:
  1. the **deploy dir** `$EZAGENT_HOME/<profile>/socialware/<name>/manifest.yaml`
     (resolved via `Ezagent.System.FsResolver` — a closed compile-time allowlist:
     `credentials|logs|plugins|inbox|socialware`); then
  2. every started app's bundled `priv/socialware/`.
- **`$EZAGENT_HOME` is the escape hatch**: a runtime-populated, bind-mounted
  directory (`EZAGENT_HOME=/data`) that is **NOT** part of the release image
  (`docker/entrypoint.prod.sh`: *"release has no `mix ezagent.home.init`"* — the
  entrypoint `mkdir -p`s the skeleton because a clean home starts blank). This is
  precisely the property skills need: content addable/updatable post-build.
- **Three-state (really four-state) seed contract** —
  `Ezagent.Socialware.ConfigStore.seed_object_upsert/1`
  (`apps/ezagent_domain_identity/lib/ezagent/socialware/config_store.ex`),
  content-hash keyed via `ContentHash.of/1` (key-sorted, stringified, SHA-256):
  1. **absent** → seed-once (race-safe) → `:seeded`
  2. **same** (hash match) → `:exists` no-op
  3. **outdated + seed-family** (`source_turn_id` starts with the caller's
     `seed_family_prefix`) → upgrade: append new object + repoint → `:seeded`
  4. **outdated + non-seed-family** (a user/CR override) → `:exists`, **override
     preserved**.

**Lesson for skills:** bundle a default in `priv/` **and** overlay from
`$EZAGENT_HOME`; reconcile with the same content-hash three/four-state contract so
upgrades are addressable and tenant customizations survive re-seed.

### 2.6 Enumerated "agent needs an artifact at runtime" pathways

| Pathway | Declared where | Resolved / distributed how | Release-safe? |
|---|---|---|---|
| Orchestrator skill | `Recipe.skills` (code recipe) | walk-up from cc `priv_dir` | **NO** (the incident) |
| `desired_skills` (domain) | `AgentTemplate` content | *never consumed* | N/A (dead) |
| Recipe `plugins` | `Recipe.plugins` | fail-closed (unimplemented) | N/A |
| Recipe `script` (py-role) | `Recipe.script` (inline data) | written into config_dir | YES (data, in recipe) |
| np Python deps | PEP-723 in `priv/` script | uv machine-global cache | YES (`priv/` + cache) |
| Socialware manifest | `priv/socialware` + `$HOME` | ManifestSeed two-origin scan | YES (bundled + overlay) |
| Recipe itself | `ConfigObject` (data) | RecipeRegistry read-through + seed | YES (data + seed) |
| Per-agent creds/CLAUDE.md | template config_dir ref | HomeRuntime stage_and_swap | YES |

**The one red row is skills.** Everything else is either data-in-recipe,
bundled-in-`priv`, or a `$EZAGENT_HOME` overlay with a seed contract. Skills are
the only runtime artifact with **no distribution backend** — they rely on a
dev-tree filesystem layout that the release erases.

---

## 3. The gap, stated precisely

A skill is a **multi-file directory tree** (`SKILL.md` + scripts/references),
referenced by **name** in a recipe. We need, on a deployed node with only the
release image + `$EZAGENT_HOME`:

- **name → source-dir resolution** that does not depend on the dev repo tree; and
- a **distribution channel** for the bytes: release-native for defaults, plus a
  post-deploy overlay so an operator (or a recipe fork) can add/upgrade a skill
  **without rebuilding the release**; and
- **materialization** of the referenced (not all) skills into each agent's
  config_dir, **recipe-driven**, versioned, tenant-safe.

Framed in the recipe language: the recipe is the **declaration authority**
(`skills: [ref]`); we are missing the recipe layer's **content backend** for skills
— the exact parallel to how `RecipeRegistry` reads recipe *data* through
`ConfigStore`.

---

## 4. Options

Three axes matter throughout: **addressable** (the resolver can find any referenced
skill) ≠ **bundled** (ships in the release) ≠ **materialized** (copied into a given
agent — always recipe-driven, only referenced skills). Keep them distinct.

### Option (a) — pure `$EZAGENT_HOME` skill store, seeded like socialware

Skills live only under `$EZAGENT_HOME/<profile>/skills/<ref>/`, scanned at boot
into a `SkillRegistry` (index = `ref → {source_dir, content_hash}`), materialized
into config_dir at spawn.

- **Declaration:** `Recipe.skills` (unchanged).
- **Versioning:** three/four-state content-hash contract over the directory
  closure; tenant skill overrides survive via `seed_family_prefix`.
- **Cold-start:** none intrinsic (copy is KB text); but a **fresh release image has
  an empty home → no skills → the incident recurs on first boot** until an operator
  populates the deploy dir.
- **Multi-tenancy:** natural — `$EZAGENT_HOME` is already workspace/profile-scoped.
- **Walk-up:** dies.
- **Verdict:** correct backend, **wrong default** — reintroduces the production
  incident for any un-provisioned deployment. Rejected as sole mechanism.

### Option (b) — build-time bundling of the referenced closure into `priv/`

Stage the runtime skill subset into an app's `priv/` before `mix release`
(generalizing Dockerfile.prod's feishu-node_modules step); resolver reads
`:code.priv_dir`.

- **Declaration:** `Recipe.skills` (unchanged).
- **Versioning:** whatever the release version is — **a skill change requires a
  release rebuild**; a recipe cannot add a skill post-deploy.
- **Cold-start:** none.
- **Multi-tenancy:** shared read-only from `priv/`; no per-tenant skill authoring.
- **Walk-up:** dies (replaced by `priv/` lookup).
- **Verdict:** release-native and self-sufficient, but **rigid** — the recipe layer
  cannot govern skills it did not ship. Good as the *default half* only.

### Option (c) — hybrid: bundled `priv/` defaults + `$EZAGENT_HOME` overlay ✅

A `SkillRegistry` resolves a ref through **two layers, overlay-wins**:

1. `$EZAGENT_HOME/<profile>/skills/<ref>/` (post-deploy, operator/recipe-authored);
2. bundled `priv/.../skills/<ref>/` (release-native default).

Index built at boot by a two-origin scan (mirroring `ManifestSeed`), reconciled by
the content-hash three/four-state contract; materialization folded into
HomeRuntime's atomic swap.

- **Declaration:** `Recipe.skills` — the recipe is the sole declaration authority;
  `SkillRegistry` is its content backend, exactly as `RecipeRegistry` is a
  read-through over `ConfigStore`.
- **Versioning:** three/four-state, override-safe, **and** a fresh image is
  self-sufficient from the bundled layer.
- **Cold-start:** none (KB text copy, synchronous — §5.4).
- **Multi-tenancy:** bundled = shared read-only; overlay = per-profile/tenant
  authored; per-agent copy for isolation (shared read-only store is a later
  optimization).
- **Walk-up:** demoted to dev-mode-only, then removed.
- **Verdict:** inherits the exact pattern socialware already uses to solve this
  same problem. **Recommended.**

---

## 5. Recommendation — Option (c)

### 5.1 Thesis (the discriminator, not the pattern-match)

A skill-distribution design must satisfy **two** constraints that pull apart:

1. **A fresh release image must be self-sufficient** — an orchestrator must spawn
   on first boot with an empty `$EZAGENT_HOME`. This is the exact constraint the
   incident violated. → forces a **bundled default** (rules out pure-(a)).
2. **The recipe layer must be able to add/upgrade a skill post-deploy without a
   release rebuild** — that is what "由 recipe 去管理" means operationally. → forces
   a **`$EZAGENT_HOME` overlay** (rules out pure-(b)).

Only the **hybrid** satisfies both. This is not a novel invention: it is the
identical shape socialware already runs — `priv/socialware` (bundled) **and**
`$EZAGENT_HOME/.../socialware` (overlay), reconciled by one seed contract. We are
inheriting the pattern that already solved this class of problem, applied to
directory-shaped artifacts instead of single-doc manifests.

### 5.2 Shape — recipe-managed, not a parallel subsystem

```
Recipe.skills: [ref]          ← declaration authority (LANDED)
        │  (materialization reads through)
        ▼
SkillRegistry.resolve(ws, ref) → {source_dir, content_hash}
        │  overlay-wins:  $EZAGENT_HOME/<profile>/skills/<ref>   (post-deploy)
        │                 else bundled priv/.../skills/<ref>      (release default)
        ▼
HomeRuntime.stage_and_swap  ← cp_r referenced skills into config_dir/skills/<ref>,
                              inside the SAME atomic swap + idempotency marker
```

`SkillRegistry` is deliberately the **mirror of `RecipeRegistry`**: same
system-workspace + tenant-fallback scoping, same boot-seed lane, same
content-hash reconcile. The recipe governs *what*; the registry is the recipe
layer's content backend for *the bytes*. It is not bolted on beside the recipe —
it is the skill half of the same read-through-over-a-store design.

### 5.3 The three/four-state contract adapts (it is not byte-identical to socialware)

`seed_object_upsert/1` hashes a single `ConfigObject` **body**. A skill is a
**directory**, so:

- The **index/manifest** is a `ConfigObject` (`subject = skill:<ref>`,
  `key = "skill"`, body = `{ref, content_hash, source_layer}`) — this buys the full
  four-state contract (absent / same / **outdated-upgradable** / **override-
  preserved**) verbatim.
- The **hash covers the directory closure** (sorted file-relpath → file-hash → roll
  up), not a JSON body. The object stores a **pointer + hash**, never the skill
  bytes (skills stay on disk in `priv/` / `$EZAGENT_HOME`).
- Carry `seed_family_prefix` (e.g. `"skill-seed"`) so a **tenant-customized skill
  survives a re-seed** — the same override-safety recipes get.

### 5.4 Cold-start & sync/async — push back on the brief

The research brief said "prefer fire-and-forget/async (remember the np 5s
lesson)." **For skills this does not transfer, and we should say so:**

- A skill is KB-scale **text** (`SKILL.md` + a few scripts). `cp_r` is sub-ms — there
  is no 9.6s np-uv equivalent to hide.
- np's own precedent is **synchronous by design** to avoid a false-readiness
  window; async would be *regressing* on that lesson, not applying it.
- Therefore: **materialize synchronously, folded into HomeRuntime's
  `stage_and_swap`** — one atomic swap, one `.ezagent-config-complete` marker, no
  partially-populated config_dir ever observable. This unification is what lets the
  walk-up copy in `OrchestratorBootstrap` die cleanly.
- Guard only the pathological case: if a referenced skill's closure is unexpectedly
  large, cap it and degrade **best-effort** (like np's `activate/2` leaves a
  DEGRADED-but-alive agent) rather than blocking spawn.

### 5.5 What dies

- `OrchestratorBootstrap.search_skill_source/1` **walk-up from `priv_dir`** →
  removed in prod; kept only as a **dev-mode fallback** (dev tree has repo-root
  `.claude/skills/`), gated like the `manifest_boot_scan` `:dev/:prod`-only switch,
  then deleted once `SkillRegistry` is authoritative.
- The manual `:role_skill_sources` / `:orchestrator_skill_source` app-env overrides
  → superseded by the registry (kept as a test seam only).
- The separate post-spawn skill `cp_r` in `OrchestratorBootstrap` → folded into
  `HomeRuntime.stage_and_swap`.

---

## 6. Phased migration

### Phase 1 — release self-sufficiency (retires the incident + point-fix)

**Goal:** every recipe-referenced skill is **addressable in every release image**
via a **generic** resolver; the hard-coded point-fix and the orchestrator-only
special-casing are gone.

1. Stage the **runtime skill subset** into an app `priv/` before `mix release`
   (the Dockerfile.prod feishu-node_modules pattern, made first-class — a build
   step or a checked-in `priv/skills/` symlink target). **Runtime subset, not all
   ~25:** the deployed-agent skills are `ezagent-session-orchestrator` (+
   `ezagent-socialware` if socialware-authoring agents load it). The other ~23 are
   **Claude-Code dev-harness skills** (brainstorming, TDD, writing-plans,
   systematic-debugging, …) that must **not** ship into a prod agent image. (A
   `runtime: true` marker in `SKILL.md` frontmatter, or an explicit bundle
   allowlist, draws the line — see OQ-1.)
2. Replace `resolve_skill_source/1`'s walk-up with a **generic** `priv/`-rooted
   lookup (any ref, no orchestrator hard-code); the orchestrator ref stops being
   special.
3. **Retire the point-fix** — once the runtime subset ships in `priv/` natively,
   whatever ad-hoc priv-copy the deploy Dockerfile carries is deleted. *(Confirm its
   exact current form first — §1 NOTE.)*
4. Invariant test: a `MIX_ENV=prod`-shaped resolution (no dev tree, no config
   override) resolves the orchestrator skill and **fails if the walk-up is the only
   path** — the test that would have caught the incident.

**Exit** — reading "all 20+ skills addressable" through the §4 axis distinction
(*addressable* ≠ *bundled* ≠ *materialized*):

- **Addressable:** the resolver is **generic** — no skill is special-cased, so
  *any* recipe-referenced ref resolves by the same path (this is the sense in which
  "all skills are addressable"; it is a property of the resolver, not of shipping 25
  dirs).
- **Bytes present in a prod image:** the **runtime subset** (~2) is bundled in
  `priv/`. Dev-harness skills stay resolvable in the **dev tree** today and gain a
  prod resolution path via the Phase-2 `$EZAGENT_HOME` overlay; they only need prod
  bytes **if a recipe references them**, at which point they join the bundle or the
  overlay. No recipe references them today, so none are missing.
- Session-create green on every deploy channel without a per-skill hack; the
  point-fix and orchestrator special-casing are gone.

### Phase 2 — `$EZAGENT_HOME` overlay + `SkillRegistry` seed lane

**Goal:** add/upgrade a skill post-deploy without a release rebuild.

1. Add a `skills` entry to `FsResolver`'s allowlist + a `Ezagent.Home` component
   (mirroring how `socialware` was added) → `$EZAGENT_HOME/<profile>/skills/`.
2. Boot-time two-origin scan (deploy dir first, then bundled `priv/`), building the
   `SkillRegistry` index; reconcile via the directory-closure content-hash
   three/four-state contract (§5.3), override-safe.
3. `resolve` becomes overlay-wins: `$EZAGENT_HOME` skill shadows the bundled default.
4. Entrypoint seeds the `skills/` skeleton dir (like the socialware skeleton).

**Exit:** an operator drops `$EZAGENT_HOME/<profile>/skills/<ref>/` and the next
boot registers/upgrades it; a bundled default is shadowable; tenant customizations
survive re-seed.

### Phase 3 — full recipe-driven materialization; walk-up removed

1. Materialization reads `Recipe.skills` through `SkillRegistry` and is **folded
   into `HomeRuntime.stage_and_swap`** (atomic, idempotent) — the separate
   `OrchestratorBootstrap` copy is deleted.
2. Wire the dead `desired_skills` domain declaration to the same backend (or retire
   it in favour of recipe `skills` — OQ-2).
3. **Remove the walk-up** (dev-fallback only until here, then gone).
4. Optional: shared read-only skill store (symlink instead of per-agent `cp_r`) for
   many-agent density; per-tenant authored skills in the workspace-scoped overlay.

---

## 7. Open questions

- **OQ-1 (runtime-vs-dev taxonomy):** how is a skill marked
  "ships-into-deployed-agents"? Frontmatter `runtime: true` vs an explicit bundle
  allowlist. The `skill-gates` worktree and the deploy repo's skill audit
  (`IMPLEMENTATION_ROADMAP.md` §5) may already have a partial cut — reconcile before
  Phase 1 fixes the subset.
- **OQ-2 (`desired_skills` vs `Recipe.skills`):** two skill-name declarations exist
  (domain `AgentTemplate.desired_skills`, recipe `Recipe.skills`); `desired_skills`
  is currently dead code. Collapse to one — recipe-owned — or keep both with a
  defined precedence?
- **OQ-3 (per-agent copy vs shared read-only):** start with per-agent `cp_r`
  (isolation, matches HomeRuntime); when does agent density justify a shared
  read-only store + symlink?
- **OQ-4 (skill closure hashing):** confirm the directory-closure hash algorithm
  (sorted relpath → content-hash → roll-up) and whether executable bits / symlinks
  inside a skill must be preserved through the seed.
- **OQ-5 (point-fix shape):** confirm the committed point-fix in `esr-ng-deploy`
  (§1 NOTE) so Phase 1 retires the real thing.
