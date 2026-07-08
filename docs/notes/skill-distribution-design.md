# Skill Distribution to Deployed Agents — Design Options

> Design research, 2026-07-08. Branch `docs/skill-distribution-research`.
> Companion: [`skill-distribution-design.zh_cn.md`](skill-distribution-design.zh_cn.md).
> Status: **research / recommendation** — no implementation in this branch.
> Rev 2 (post codex adversarial review): authority model made explicit and phased
> (§5.3); socialware precedent aligned to the current single-source deploy-seed
> lane (§2.5, P2); ConfigObject rationale corrected to the directory-tree argument
> (§5.4); point-fix confirmed as ezagent-deploy `1d5aeca` (§1); implementation
> constraints appended (§7).

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

**The point-fix (confirmed): ezagent-deploy commit `1d5aeca`** copies
`ezagent-session-orchestrator` into `apps/ezagent_plugin_cc/priv/.claude/skills/`
at image build — the `priv_dir` walk then hits `<priv>/.claude/skills/<ref>/SKILL.md`
at its very first candidate. Same family as Dockerfile.prod lines 66-69, which
already `npm install` the feishu WS sidecar **into `priv/`** so the release
bundles it. It hard-codes a **single** skill; Phase 1 (§6) retires exactly this
mechanism.

The repo-root `.claude/skills/` holds **25 skill dirs** (+ a `SUPERPOWERS_VERSION.md`
marker file). Any future recipe that references a *second* skill breaks identically.
The fix must generalize skill **content distribution**, not patch one ref.

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
declaration. Today's seeded recipes (`roles/0` across plugins: cc, codex,
hello ×3, kanban) reference exactly **one** skill in total —
`OrchestratorRecipe` sets `skills: ["ezagent-session-orchestrator"]`
(`orchestrator_recipe.ex:110`); the hello/kanban recipes carry none.

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
  precedent, not an async one. See §5.5.)

**Lesson for skills:** ship the artifact + its manifest in `priv/` (release-native
default); make the expensive/shared part machine-global, not per-agent.

### 2.5 Reference model B — socialware deploy-seed lane (single source, seeded once)

This is the closest analogue to "distribute post-build content to a deployed node
without rebuilding the release" — and the **current** model is simpler than a
dual-origin overlay: one runtime source, seeded once from the release.

- **Single source.** `Ezagent.Socialware.ManifestSeed.scan_all!/1`
  (`apps/ezagent_domain_session/lib/ezagent/socialware/manifest_seed.ex`) runs once
  at boot (fired from the last-booting app) and sweeps **exactly one** directory:
  `system://socialware` = `$EZAGENT_HOME/<profile>/socialware/*/manifest.yaml`,
  resolved through `Ezagent.System.FsResolver` (never raw `Ezagent.Home`). Its
  moduledoc is explicit: *"the deployment directory is the sole manifest source"* —
  the former app-`priv/socialware/` scan lane was **retired** by the deploy-seed
  migration (autoservice #1231, hello #1233), is **forbidden** by the
  `socialware_priv_manifest_files` arch gate (#1246), and its dead boot-scan branch
  was removed in #1227.
- **Bundled defaults are a SEED SOURCE, not a runtime origin.** Shipped flagships
  live in `ezagent_web/priv/socialware_seed/<name>/` and are copied **one-time,
  idempotently** into the deploy dir by `Ezagent.Home.SocialwareSeed`
  (`apps/ezagent_core/lib/ezagent/home/socialware_seed.ex`; run at `home.init` +
  a boot fallback). A pre-existing package dir is **not overwritten** — operator
  edits are respected.
- **`$EZAGENT_HOME` is the escape hatch**: a runtime-populated, bind-mounted
  directory (`EZAGENT_HOME=/data`) that is **NOT** part of the release image
  (`docker/entrypoint.prod.sh`: *"release has no `mix ezagent.home.init`"* — the
  entrypoint `mkdir -p`s the skeleton because a clean home starts blank). Content
  is addable/updatable post-build — exactly the property skills need.
- **Three-state (really four-state) seed contract** at the *data* layer —
  `Ezagent.Socialware.ConfigStore.seed_object_upsert/1`
  (`apps/ezagent_domain_identity/lib/ezagent/socialware/config_store.ex`),
  content-hash keyed via `ContentHash.of/1` (key-sorted, stringified, SHA-256):
  1. **absent** → seed-once (race-safe) → `:seeded`
  2. **same** (hash match) → `:exists` no-op
  3. **outdated + seed-family** (`source_turn_id` starts with the caller's
     `seed_family_prefix`) → upgrade: append new object + repoint → `:seeded`
  4. **outdated + non-seed-family** (a user/CR override) → `:exists`, **override
     preserved**.

**Lesson for skills:** ship defaults in a `priv/` *seed source*, copy them once
into the single `$EZAGENT_HOME` runtime dir, scan **one** directory at boot, and
reconcile upgrades vs operator edits with the content-hash seed-family contract.
One runtime origin keeps the resolver trivial.

### 2.6 Enumerated "agent needs an artifact at runtime" pathways

| Pathway | Declared where | Resolved / distributed how | Release-safe? |
|---|---|---|---|
| Orchestrator skill | `Recipe.skills` (code recipe) | walk-up from cc `priv_dir` | **only via point-fix `1d5aeca`** (the incident) |
| `desired_skills` (domain) | `AgentTemplate` content | *never consumed* | N/A (dead) |
| Recipe `plugins` | `Recipe.plugins` | fail-closed (unimplemented) | N/A |
| Recipe `script` (py-role) | `Recipe.script` (inline data) | written into config_dir | YES (data, in recipe) |
| np Python deps | PEP-723 in `priv/` script | uv machine-global cache | YES (`priv/` + cache) |
| Socialware manifest+pkg | deploy dir (`$EZAGENT_HOME`) | `priv/socialware_seed` → one-time `Home.SocialwareSeed` copy → single-dir `ManifestSeed` scan | YES (seed-once + single source) |
| Recipe itself | `ConfigObject` (data) | RecipeRegistry read-through + seed | YES (data + seed) |
| Per-agent creds/CLAUDE.md | template config_dir ref | HomeRuntime stage_and_swap | YES |

**The one red row is skills.** Everything else is either data-in-recipe,
bundled-in-`priv`, or the `$EZAGENT_HOME` deploy-seed lane with a seed contract.
Skills are the only runtime artifact with **no distribution backend** — they rely
on a dev-tree filesystem layout that the release erases (patched today by one
hard-coded image-build copy).

---

## 3. The gap, stated precisely

A skill is a **multi-file directory tree** (`SKILL.md` + scripts/references),
referenced by **name** in a recipe. We need, on a deployed node with only the
release image + `$EZAGENT_HOME`:

- **name → source-dir resolution** that does not depend on the dev repo tree; and
- a **distribution channel** for the bytes: release-native for defaults, plus a
  post-deploy path so an operator can add/upgrade a skill **without rebuilding the
  release**; and
- **materialization** of the referenced (not all) skills into each agent's
  config_dir, **recipe-driven**, versioned, with an **explicit publish-authority
  model** (§5.3 — who may put bytes into the store a recipe can reference).

Framed in the recipe language: the recipe is the **declaration authority**
(`skills: [ref]`); we are missing the recipe layer's **content backend** for skills
— the exact parallel to how `RecipeRegistry` reads recipe *data* through
`ConfigStore`.

---

## 4. Options

Three axes matter throughout: **addressable** (the resolver can find any referenced
skill) ≠ **bundled** (ships in the release) ≠ **materialized** (copied into a given
agent — always recipe-driven, only referenced skills). Keep them distinct.

### Option (a) — pure `$EZAGENT_HOME` skill store, no bundled seed

Skills live only under `$EZAGENT_HOME/<profile>/skills/<ref>/`, populated entirely
by the operator, scanned at boot into a `SkillRegistry` (index =
`ref → {source_dir, content_hash}`), materialized into config_dir at spawn.

- **Declaration:** `Recipe.skills` (unchanged).
- **Versioning:** three/four-state content-hash contract over the directory
  closure.
- **Cold-start:** none intrinsic (copy is KB text); but a **fresh release image has
  an empty home → no skills → the incident recurs on first boot** until an operator
  populates the deploy dir.
- **Tenancy/authority:** the store is **node-global** — `<profile>` is a
  deployment axis, not a workspace, and `System.FsResolver` is by contract
  **no per-caller authority** (its R-3). "Tenant-safe" would be an overclaim
  (§5.3).
- **Walk-up:** dies.
- **Verdict:** correct escape hatch, **wrong default** — reintroduces the
  production incident for any un-provisioned deployment. Rejected as sole
  mechanism.

### Option (b) — build-time bundling of the referenced closure into `priv/`

Stage the runtime skill subset into an app's `priv/` before `mix release`
(generalizing point-fix `1d5aeca` / the feishu-node_modules step); the resolver
reads `:code.priv_dir` directly, forever.

- **Declaration:** `Recipe.skills` (unchanged).
- **Versioning:** whatever the release version is — **a skill change requires a
  release rebuild**; a recipe cannot add a skill post-deploy.
- **Cold-start:** none.
- **Tenancy/authority:** shared read-only from `priv/`; implicitly system-vetted
  (whatever CI built); no post-deploy or per-tenant authoring at all.
- **Walk-up:** dies (replaced by `priv/` lookup).
- **Verdict:** release-native and self-sufficient, but **rigid** — the recipe layer
  cannot govern skills it did not ship. Good as the *seed-source half* only.

### Option (c) — bundled seed source + single `$EZAGENT_HOME` store (the socialware lane) ✅

Follow the current socialware deploy-seed model exactly, applied to skills:

1. runtime skills ship in a **`priv/skills_seed/<ref>/`** seed source
   (release-native);
2. `Ezagent.Home.SkillSeed` copies them **one-time, idempotently** into
   **`$EZAGENT_HOME/<profile>/skills/<ref>/`** at `home.init` + a boot fallback;
3. a boot scan of that **single** directory builds the `SkillRegistry` index
   (`ref → {source_dir, content_hash}`), reconciled by the content-hash
   three/four-state contract;
4. materialization reads `Recipe.skills` through the registry, folded into
   HomeRuntime's atomic swap.

- **Declaration:** `Recipe.skills` — the recipe is the sole declaration authority;
  `SkillRegistry` is its content backend, exactly as `RecipeRegistry` is a
  read-through over `ConfigStore`.
- **Versioning:** three/four-state at the index layer, seed-family discriminated
  at the bytes layer (release upgrade vs operator edit — §5.4); **and** a fresh
  image is self-sufficient (the boot seed populates the empty home from `priv/`).
- **Cold-start:** none (KB text copy, synchronous — §5.5).
- **Tenancy/authority:** **explicit and phased** — system-vetted store only at
  first; workspace-scoped custom skills are a later phase on the
  `resource://` + CR-governance track (§5.3).
- **Walk-up:** demoted to dev-mode-only, then removed.
- **Resolver simplicity:** after the seed copy there is **one runtime origin** —
  no overlay-precedence logic at resolve time.
- **Verdict:** inherits the exact lane socialware already runs to solve this same
  problem. **Recommended.**

---

## 5. Recommendation — Option (c)

### 5.1 Thesis (the discriminator, not the pattern-match)

A skill-distribution design must satisfy **two** constraints that pull apart:

1. **A fresh release image must be self-sufficient** — an orchestrator must spawn
   on first boot with an empty `$EZAGENT_HOME`. This is the exact constraint the
   incident violated. → forces a **release-shipped seed source** (rules out
   pure-(a)).
2. **The platform must be able to add/upgrade a skill post-deploy without a
   release rebuild** — that is what "由 recipe 去管理" means operationally: the
   recipe names a skill, and satisfying that reference must not require shipping a
   new image. → forces a **runtime store under `$EZAGENT_HOME`** (rules out
   pure-(b)).

The seed-once-then-single-source lane satisfies both — and it is not a novel
invention: it is the **current** socialware shape verbatim
(`priv/socialware_seed` → `Home.SocialwareSeed` one-time copy → single-dir
`ManifestSeed` scan). We are inheriting the lane that already solved this class
of problem, applied to skill directory trees instead of manifest packages.

### 5.2 Shape — recipe-managed, not a parallel subsystem

```
Recipe.skills: [ref]            ← declaration authority (LANDED on main)
        │  (materialization reads through)
        ▼
SkillRegistry.resolve(ref) → {source_dir, content_hash}
        │  single runtime origin: $EZAGENT_HOME/<profile>/skills/<ref>
        │  (populated once from priv/skills_seed/<ref> by Home.SkillSeed
        │   at home.init/boot; operator may add/upgrade dirs post-deploy)
        ▼
HomeRuntime.stage_and_swap  ← cp_r referenced skills into config_dir/skills/<ref>,
                              inside the SAME atomic swap + idempotency marker
```

`SkillRegistry` is deliberately the **mirror of `RecipeRegistry`**: same boot-seed
lane, same content-hash reconcile, same fail-loud unknown-ref semantics. The
recipe governs *what*; the registry is the recipe layer's content backend for
*the bytes*. It is not bolted on beside the recipe — it is the skill half of the
same read-through-over-a-store design.

### 5.3 Authority model — who may publish into the store (explicit, phased)

The store dir resolves via `Ezagent.System.FsResolver`, and that seam is **by
contract authority-free**: system artifacts "have no natural `<ws>` and no
per-caller authority axis" (R-3,
`apps/ezagent_core/lib/ezagent/system/fs_resolver.ex`). `<profile>` is a
deployment axis, not a tenant boundary. So a `$EZAGENT_HOME/<profile>/skills/`
store is **node-global**, and a recipe in any workspace can name any ref in it.
Calling that "tenant-safe" would be wrong. The authority model is therefore
explicit, in two stages:

**P1–P3 (this design): the skill store is SYSTEM-workspace-vetted only.**

- Contents are **platform artifacts**: shipped via `priv/skills_seed` (CI-built,
  code-reviewed) or published by the **admin/deploy pipeline** into the deploy
  dir. This matches what these skills *are* today —
  `ezagent-session-orchestrator` is platform infrastructure, not tenant content.
- **Interim invariant:** recipes may only reference **system-store refs**;
  resolution of an unknown/unauthorized ref fails **loudly**
  (`{:skill_source_not_found, ref}` → `role_degraded` + telemetry, never a
  silent skip). There is **no runtime-writable publish surface** — the store is
  written only by the `home.init`/boot seed and by operators with node access.

**Later phase (explicitly out of scope here): workspace-scoped custom skills.**

- Storage moves to the **tenant-authorized seam**: `resource://<ws>/skills/<ref>`
  via `Ezagent.Resource.FsResolver.resolve/2`, whose per-type authority check
  requires the caller's authenticated `<ws>` to equal the URI's `<ws>`.
- Publishing rides the **CR-governance path** (the
  `Ezagent.ConfigGovernance.Socialware` `open_cr → stage → publish` pattern), so
  a tenant-authored skill is staged, reviewed, and published with an audit trail
  — and an authoring-boundary trust guard can reject code-injection content
  fail-closed (a skill dir carries scripts; it is exactly the `script`-field
  trust problem `RecipeRegistry.validate_data_role_recipe/1` already fail-closes
  for data-roles).
- Resolution order then becomes: workspace store → system store fallback —
  mirroring `RecipeRegistry.lookup/2`'s caller-ws → system-ws order.

### 5.4 Versioning — the seed contract adapts (index vs bytes)

`seed_object_upsert/1` hashes a single `ConfigObject` **body** — that carries
over directly for the **index**. The **bytes** need one more discriminator:

- The **index entry** is a `ConfigObject` (`subject = skill:<ref>`,
  `key = "skill"`, body = `{ref, content_hash, shipped_hash}`) — this buys the
  four-state contract (absent / same / outdated-upgradable / override-preserved)
  verbatim, with `seed_family_prefix` (e.g. `"skill-seed"`).
- **Why the index does not carry the skill bytes:** a skill is a **directory
  tree** — multiple files, scripts, executable bits, potentially symlinks — which
  a `ConfigObject`'s JSON-map body does not represent. (This is a *shape*
  argument, **not** a "no blobs in Postgres" red-line argument: the taxonomy
  red-line targets binary blobs, and skill content is KB-scale text that would be
  perfectly at home in a ConfigObject. A ConfigObject-backed variant — body =
  `%{relpath => content}` — was weighed for *single-file* skills and set aside:
  splitting the store by skill shape buys nothing in P1–P3, where every store
  write is already system-vetted. It becomes attractive in the workspace-custom
  later phase, where riding ConfigObject gets CR governance, override-safety,
  and audit for free; revisit there.)
- The **content hash covers the directory closure**: sorted `relpath → file-hash`
  pairs rolled up — so renames and deletions change the hash; the per-file hash
  input includes the executable bit and, for symlinks, the link target (IC-1).
- **Upgrade vs operator edit at the bytes layer:** `Home.SocialwareSeed`'s
  blanket never-overwrite is the conservative default, but skills want the
  seed-family upgrade: keep the **shipped hash** in the index; at boot-seed time,
  if the on-disk dir still hashes to the last shipped hash and the new
  `priv/skills_seed` differs → **upgrade** (replace dir, bump index); if the
  on-disk dir diverges from the last shipped hash → **operator edit, preserved**
  (`:exists`) — the four-state contract applied to bytes.

### 5.5 Cold-start & sync/async — push back on the brief

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

### 5.6 What dies

- `OrchestratorBootstrap.search_skill_source/1` **walk-up from `priv_dir`** →
  removed in prod; kept only as a **dev-mode fallback** (dev tree has repo-root
  `.claude/skills/`), gated like the `manifest_boot_scan` `:dev/:prod`-only switch,
  then deleted once `SkillRegistry` is authoritative.
- The manual `:role_skill_sources` / `:orchestrator_skill_source` app-env overrides
  → superseded by the registry (kept as a test seam only).
- The separate post-spawn skill `cp_r` in `OrchestratorBootstrap` → folded into
  `HomeRuntime.stage_and_swap`.
- **ezagent-deploy commit `1d5aeca`** (the image-build copy of one skill into cc
  `priv/.claude/skills/`) → retired in Phase 1.

---

## 6. Phased migration

### Phase 1 — release self-sufficiency (retires the incident + point-fix `1d5aeca`)

**Goal:** every recipe-referenced skill is **addressable in every release image**
via a **generic** resolver; the hard-coded point-fix and the orchestrator-only
special-casing are gone.

1. Create the **`priv/skills_seed/<ref>/`** seed source and stage the **runtime
   skill subset** into it in-repo (checked in, not an image-build copy). The
   subset is **derived, not hand-counted** (IC-3): enumerate `Recipe.skills`
   across every `roles/0` seed — today that yields exactly
   `["ezagent-session-orchestrator"]` (cc + codex both seed `OrchestratorRecipe`;
   the hello/kanban recipes carry no skills) — plus `ezagent-socialware` if/when
   a socialware-authoring recipe references it. The other ~23 repo-root skills
   are **Claude-Code dev-harness skills** (brainstorming, TDD, writing-plans, …)
   that must **not** ship into a prod agent image; they stay resolvable in the
   dev tree and join the seed only if a recipe ever references them.
2. Replace `resolve_skill_source/1`'s walk-up with a **generic** seed-source
   lookup (any ref, no orchestrator hard-code); the orchestrator ref stops being
   special.
3. **Retire ezagent-deploy `1d5aeca`** — the image-build copy is deleted; the
   seed source ships in the repo/release natively.
4. Invariant test: a `MIX_ENV=prod`-shaped resolution (no dev tree, no config
   override) resolves **every ref enumerated from seeded recipes** and **fails if
   the walk-up is the only path** — the test that would have caught the incident,
   derived from the same `Recipe.skills` enumeration as step 1.

**Exit** — reading "all 20+ skills addressable" through the §4 axis distinction
(*addressable* ≠ *bundled* ≠ *materialized*):

- **Addressable:** the resolver is **generic** — no skill is special-cased, so
  *any* recipe-referenced ref resolves by the same path (a property of the
  resolver, not of shipping 25 dirs).
- **Bytes present in a prod image:** the **derived runtime subset** is in the
  seed source. Dev-harness skills stay dev-tree-resolvable; they only need prod
  bytes **if a recipe references them**, at which point the step-1 derivation
  pulls them into the seed (and the step-4 invariant test starts covering them).
- Session-create green on every deploy channel with `1d5aeca` deleted.

### Phase 2 — `$EZAGENT_HOME` skill store + `SkillRegistry` (the socialware lane)

**Goal:** add/upgrade a skill post-deploy without a release rebuild — via the
seed-once-then-single-source lane, not a dual-origin overlay.

1. Add a `skills` entry to `System.FsResolver`'s closed `<type>` catalog + an
   `Ezagent.Home` component (mirroring how `socialware` was added) →
   `$EZAGENT_HOME/<profile>/skills/`.
2. `Ezagent.Home.SkillSeed` (mirror of `Home.SocialwareSeed`): one-time
   idempotent copy `priv/skills_seed/<ref>/` →
   `$EZAGENT_HOME/<profile>/skills/<ref>/` at `home.init` + boot fallback, with
   the §5.4 shipped-hash discriminator (upgrade an untouched shipped dir;
   preserve an operator-edited one).
3. Boot scan of that **single** directory builds the `SkillRegistry` index;
   reconcile index entries via `seed_object_upsert/1`
   (`seed_family_prefix: "skill-seed"`). After the seed, the resolver has **one
   runtime origin**.
4. `resolve_skill_source/1` re-points at the registry; the entrypoint seeds the
   `skills/` skeleton dir. **Authority stays system-vetted** (§5.3): no
   runtime-writable publish surface; unknown refs fail loudly.

**Exit:** an operator drops/updates `$EZAGENT_HOME/<profile>/skills/<ref>/` and
the next boot registers/upgrades it; shipped defaults upgrade themselves on a
release bump unless operator-edited; a recipe referencing an unknown ref degrades
loudly, never silently.

### Phase 3 — full recipe-driven materialization; walk-up removed

1. Materialization reads `Recipe.skills` through `SkillRegistry` and is **folded
   into `HomeRuntime.stage_and_swap`** (atomic, idempotent) — the separate
   `OrchestratorBootstrap` copy is deleted. This is also what makes skill
   **upgrade/removal** inside an agent correct (IC-2).
2. Wire the dead `desired_skills` domain declaration to the same backend (or
   retire it in favour of recipe `skills` — OQ-2).
3. **Remove the walk-up** (dev-fallback only until here, then gone).
4. Optional: shared read-only skill store (symlink instead of per-agent `cp_r`)
   for many-agent density.

### Later phase (explicitly out of scope) — workspace-scoped custom skills

Tenant-authored skills via `resource://<ws>/skills/<ref>` +
`Resource.FsResolver.resolve/2` authority + CR-governance publish (§5.3), with
workspace→system resolution fallback mirroring `RecipeRegistry.lookup/2`.
Requires the authoring-boundary trust guard (skills carry scripts — the
data-role `script` problem, fail-closed) and is where the ConfigObject-backed
single-file variant (§5.4) earns its keep.

---

## 7. Implementation constraints (from adversarial review; non-blocking, binding on impl)

- **IC-1 — directory-hash semantics.** The closure hash must change on file
  rename **and** deletion (hashing the sorted `relpath → hash` *pair set* covers
  both); the per-file hash input must include the executable bit; symlinks hash
  their **target path** (and the later-phase tenant store should reject symlinks
  outright — an escape vector). Specify this before P2; the index contract
  depends on it.
- **IC-2 — upgrade correctness needs P3.** `OrchestratorBootstrap.copy_skill/3`
  **skips an existing dest dir** (`orchestrator_bootstrap.ex:356`), so an
  already-materialized agent never picks up a skill upgrade or removal until
  materialization moves into `stage_and_swap` (fresh staging per
  materialization, P3). Until P3, a skill upgrade requires config_dir
  regeneration; the ops runbook must say so.
- **IC-3 — the runtime subset is derived, not enumerated by hand.** The P1
  bundle list and the P1 invariant test must both be **computed from
  `Recipe.skills` across all `roles/0` seeds** (today:
  `orchestrator_recipe.ex:110` → `ezagent-session-orchestrator`). A
  hand-maintained list would rot the moment a recipe adds a ref — recreating
  this incident with extra steps.

---

## 8. Open questions

- **OQ-1 (runtime-vs-dev taxonomy):** IC-3 derives the *must-bundle* set, but a
  human-readable marker (frontmatter `runtime: true` vs the seed-source dir
  itself being the marker) still helps reviewers; reconcile with the
  `skill-gates` worktree and the deploy repo's skill audit before P1.
- **OQ-2 (`desired_skills` vs `Recipe.skills`):** two skill-name declarations
  exist (domain `AgentTemplate.desired_skills`, recipe `Recipe.skills`);
  `desired_skills` is currently dead code. Collapse to one — recipe-owned — or
  keep both with a defined precedence?
- **OQ-3 (per-agent copy vs shared read-only):** start with per-agent `cp_r`
  (isolation, matches HomeRuntime); when does agent density justify a shared
  read-only store + symlink?
