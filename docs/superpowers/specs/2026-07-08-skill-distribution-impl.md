# Skill Distribution P1–P3 — Implementation SPEC

> Date: 2026-07-08 · Companion: [`2026-07-08-skill-distribution-impl.zh_cn.md`](2026-07-08-skill-distribution-impl.zh_cn.md).
> **Source of truth:** [`docs/notes/skill-distribution-design.md`](../../notes/skill-distribution-design.md)
> (merged PR #1251, codex-reviewed twice, final verdict **SOUND-WITH-NOTES**).
> This SPEC **implements that doc's decisions** — it does not re-open them. Where
> this SPEC and the design doc disagree, the design doc wins, with the single
> documented exception in §2 (the design doc's `roles/0` plugin enumeration
> predates a `main` move; the derivation *output* is re-verified here).
> Naming lands on GLOSSARY **Decision #161** (declaration/content layer words:
> `Registry` = runtime index, `Seed` = install channel, `Materializer`/atomic-swap
> = declaration→artifact). The seed reconcile mirrors **#1242**'s three/four-state
> `seed_object_upsert` contract.

---

## 0. Codex handoff preamble

**Branch to work on:** `feat/skill-distribution-p123` (off `origin/main`). This is
**not** the branch this SPEC lands on (`docs/skill-distribution-impl-spec`); the
SPEC merges first, then codex cuts the implementation branch from fresh `main`.

**Self-drive discipline (per our codex-handoff convention):**

- **Codex owns the branch.** One branch, **three bounded sub-steps** (P1 → P2 → P3)
  committed **sequentially**. Each sub-step's own acceptance gates (§ per phase)
  must be **green before the next sub-step starts** — no starting P2 with P1 red.
- **No `main` merge, no PR-to-main by codex.** The coordinator (Allen/Claude)
  merges. Codex pushes the branch and reports each sub-step's gate results.
- **Red gate = fix forward inside the sub-step.** Never skip, never `--exclude`,
  never comment-out an assertion to go green. If a gate reveals the design is
  wrong, stop and report — do not silently deviate from this SPEC.
- **Standing constraints:**
  - Edit Elixir with structured edits, never `cat >>`/`echo >>` append (appended
    Elixir → `SyntaxError`; use the editor's replace, matching indentation).
  - **No `.claude/` edits.** The repo-root `.claude/skills/` tree is dev-harness
    content; P1 *reads* it (dev fallback) and P2/P3 stop depending on it, but this
    work never mutates it.
  - **`uv run`, never `python`/`python3`** for any scripting.
  - `mise` pins OTP/Elixir; run gates through `mix` as the aliases define them.
- **Coordinator-owned, out of codex scope:** retiring the deploy-repo point-fix
  (**ezagent-deploy `1d5aeca`**) happens **after** this branch merges, by the
  coordinator. P1 must keep that point-fix **harmless in the interim** (§3.4).

---

## 1. Goal (one paragraph)

An orchestrator (or any recipe-referenced skill) must resolve and materialize on a
**deployed node** with only the release image + `$EZAGENT_HOME` — no dev repo tree.
Today `OrchestratorBootstrap.resolve_skill_source/1` walks **up from the cc plugin
`priv_dir`** for `.claude/skills/<ref>/SKILL.md`; `mix release` ships only per-app
`priv/`, so in a release image the walk finds nothing → `{:skill_source_not_found}`
→ `role_degraded` → **session-create dead on every channel** (patched today by one
hard-coded skill copy, ezagent-deploy `1d5aeca`). This SPEC replaces that dev-tree
dependency with the **socialware deploy-seed lane applied to skills**: a
release-shipped `priv/skills_seed` seed source → one-time idempotent copy into a
**single** `$EZAGENT_HOME/<profile>/skills/` runtime origin → a `SkillRegistry`
read-through index → materialization folded into `HomeRuntime.stage_and_swap`. The
recipe layer stays the **declaration authority** (`Recipe.skills`); `SkillRegistry`
is its **content backend**, exactly as `RecipeRegistry` is a read-through over
`ConfigStore`.

---

## 2. The P1 derivation rule (IC-3) — verified against `main`

**Rule.** The runtime skill set is **derived, never hand-listed.** It is the union
of `Recipe.skills` across **every plugin's `roles/0` seed** — the same enumeration
`Ezagent.Plugin.RoleSeedHook.seed_roles/2` already drives at
`apps/ezagent_core/lib/ezagent/plugin.ex:482` (`plugin_module.roles()` per booting
plugin). Both the **P1 seed-bundle list** and the **P1 invariant test** are computed
from this one enumeration (IC-3) — a hand-maintained list would rot the moment a
recipe adds a ref, recreating the incident.

**Verified current output (against `origin/main`, 2026-07-08).** Enumerating every
`roles/0` in the umbrella:

| plugin | `roles/0` recipes | declares `skills:`? |
|---|---|---|
| cc | `OrchestratorRecipe.recipe()` | **yes** → `["ezagent-session-orchestrator"]` (`orchestrator_recipe.ex:110`, `@skill_ref` `:41`) |
| codex | `OrchestratorRecipe.recipe()` (same recipe) | yes (same ref) |
| kb | `kb_recipe()` | no (defaults `skills: []`) |
| py | `np_role_recipe()` | no |
| kanban | `kanban_manager_recipe()` | no |
| hello | `hello_front_desk` / `hello_builder` / `hello_concierge` / `hello_llm` (**4**, not the doc's "×3") | no |

→ **Derived output today = `["ezagent-session-orchestrator"]`** (one ref). The
design doc's illustrative count is correct even though its plugin list omitted `kb`
and undercounted hello — because none of those recipes carry a skill. This SPEC
re-verifies rather than copies the count (advisor blocker), and the derivation
**surface** (`roles/0` recipes) is asserted to be **the same set** the P1 invariant
tests, so a seeded-but-unbundled ref can never slip past.

**Anti-rot note.** The `~23` other repo-root `.claude/skills/` dirs are Claude-Code
**dev-harness** skills (brainstorming, TDD, writing-plans, …). They must **not**
ship into a prod agent image. They stay dev-tree-resolvable and join the seed
**only if a recipe ever references them** — at which point this same derivation
pulls them in automatically and the invariant test begins covering them.

---

## 3. P1 — generic resolver + bundled runtime set

**Goal:** every recipe-referenced skill is **addressable in every release image**
via a **generic** resolver reading a release-bundled origin; the walk-up is demoted
to a dev-only fallback; the orchestrator ref stops being special-cased.

### 3.1 Work items

1. **Seed source dir (checked in, release-native).** Create
   `apps/ezagent_web/priv/skills_seed/<ref>/` and stage the **derived runtime set**
   (§2) into it in-repo — today exactly
   `apps/ezagent_web/priv/skills_seed/ezagent-session-orchestrator/` (a copy of the
   repo-root `.claude/skills/ezagent-session-orchestrator/` closure). Pin the
   seed-source **app = `ezagent_web`** (the deploy/assembly top app), mirroring
   `socialware_seed`: `mix release` packages only per-app `priv/`, so the bytes
   must live in *some* app's `priv/`, and `ezagent_web` is the same app socialware
   chose. The dir name `skills_seed` (≠ `skills`) keeps it out of any future
   `skills` runtime scan. The staging is source content the derivation **produces**,
   not a hand-list — codex regenerates it by running the derivation over `roles/0`
   and copying each derived ref's dev-tree closure.
2. **`Ezagent.SkillRegistry`** (`Registry` layer, GLOSSARY #161) — a
   `ref → {source_dir, content_hash}` index. In **P1 it reads the bundled origin
   directly**: enumerate every loaded app's `priv/skills_seed/<ref>/` (generic scan,
   the `SocialwareSeed.source_dirs/0` idiom — no hardcoded app ref), hash each dir's
   closure (§6 IC-1), expose `resolve/1 :: {:ok, {source_dir, hash}} | {:error,
   {:skill_source_not_found, ref}}`. **Placement:** a layer that both the cc plugin
   and `HomeRuntime` (P3) can call without a cross-app cycle — `ezagent_core` is the
   natural home (it already owns `Home`, `HomeRuntime`, `System.FsResolver`).
3. **Rewire `resolve_skill_source/1`** (`orchestrator_bootstrap.ex:266`) to call
   `SkillRegistry.resolve/1` — **generic for any ref**, no orchestrator hard-code.
   The existing config overrides (`:orchestrator_skill_source`, `:role_skill_sources`)
   are retained **only as a test seam** (still consulted first if set). The
   **walk-up (`search_skill_source/1` + `walk_for_skill/2`) is demoted to a
   dev-mode-only fallback**: reachable only when `SkillRegistry.resolve/1` misses
   **and** the env is `:dev` (compile-env gate, the `manifest_boot_scan` `:dev/:prod`
   switch idiom). In `:prod` a miss is a hard `{:skill_source_not_found, ref}` — the
   loud interim-authority invariant (design §5.3).
4. **Keep `1d5aeca` harmless (interim).** After merge but before the coordinator
   retires the deploy point-fix, both sources may coexist in a built image: the
   ezagent-deploy copy at `apps/ezagent_plugin_cc/priv/.claude/skills/…` **and** the
   new `ezagent_web/priv/skills_seed/…`. This must not conflict, and the SPEC states
   **why**: (a) `SkillRegistry` resolves from **its own origin** (`priv/skills_seed`
   scan), so the cc-`priv` copy is simply never consulted by the new path; (b) the
   walk-up that *would* hit the cc-`priv` copy is now `:dev`-gated and unreachable in
   `:prod`; (c) even if the copy is present, it is byte-identical seed content at a
   different location — **idempotent-identical**, no divergence. Codex does **not**
   delete `1d5aeca` (out of scope; coordinator, post-merge).

### 3.2 P1 acceptance gates

- **`test/.../skill_registry_test.exs`** (new): `resolve/1` returns `{:ok, {dir,
  hash}}` for `"ezagent-session-orchestrator"`; returns `{:error,
  {:skill_source_not_found, ref}}` for an unknown ref; the derived set enumerated
  from `roles/0` all resolve.
- **`test/.../skill_distribution_prod_shape_test.exs`** (new, **failing-first**):
  simulate a prod-shaped resolution — **no dev tree, no config override, walk-up
  disabled** — and assert **every ref enumerated from seeded `Recipe.skills`
  resolves via `SkillRegistry`**, and that resolution **fails if the walk-up is the
  only path**. This is the test that would have caught the incident; write it red
  (before the rewire) and drive it green. Its expected-pass set is computed from the
  **same** `roles/0` enumeration as the seed-bundle (§2), asserted identical.
- Existing `orchestrator_bootstrap` tests stay green (overrides still honored as a
  test seam).
- **Standing gates** (all sub-steps): `mix format` clean;
  `mix compile --warnings-as-errors --force` clean; `mix ezagent.check_invariants`
  green; `mix ezagent.arch.scan` green; `mix ezagent.doc.scan` ratchets not regressed
  (every new public fn carries a **code-verified** `@doc` — claims match the code,
  not inferred from names).

### 3.3 P1 exit

Resolver is **generic** (no skill special-cased); the derived runtime subset's bytes
are in the release-bundled seed source; session-create is green on a prod-shaped path
with the walk-up disabled; `1d5aeca` is harmless-and-redundant, ready for the
coordinator to retire.

---

## 4. P2 — seed lane (`$EZAGENT_HOME` store + single runtime origin)

**Goal:** add/upgrade a skill **post-deploy without a release rebuild**, via the
seed-once-then-single-source lane — **not** a dual-origin overlay.

### 4.1 Work items

1. **`skills` in `System.FsResolver` + `Home`.** Add `"skills" => "skills"` to the
   closed `@catalog` (`fs_resolver.ex:65`) and `:skills` to `Home.skeleton_dirs`
   (`home.ex:73`) — mirroring exactly how `socialware` was added → resolves to
   `$EZAGENT_HOME/<profile>/skills/`. The entrypoint/`home.init` `mkdir -p`s the
   `skills/` skeleton (a clean home starts blank).
2. **`Ezagent.Home.SkillSeed`** — a **direct mirror of `Home.SocialwareSeed`**
   (`apps/ezagent_core/lib/ezagent/home/socialware_seed.ex`): enumerate every loaded
   app's `priv/skills_seed/<ref>/`, copy each into `$EZAGENT_HOME/<profile>/skills/`
   idempotently, resolving the dest through the sanctioned `System.FsResolver` seam
   (**not** raw `Home`), so seed-dest == scan-dir. Trigger at **`home.init`** +
   a **boot fallback** (before the store scan), same two-site pattern socialware uses.
   The difference from `SocialwareSeed`'s blanket never-overwrite: **shipped-hash
   three-way reconcile at the bytes layer** (below).
3. **Re-point `SkillRegistry` at the single runtime origin.** After P2, the registry's
   backing origin is **`$EZAGENT_HOME/<profile>/skills/`**, not `priv/skills_seed`
   (which is now only `SkillSeed`'s *source*). This is the **P1→P2 transition** codex
   must implement crisply: P1's registry read `priv/skills_seed` directly; P2 makes
   the seed populate the deploy dir and the registry scans **that one dir**. After the
   seed there is **one runtime origin** — no resolve-time overlay precedence.
4. **The index vs bytes split (design §5.4) — keep distinct:**
   - **Index** = a `ConfigObject` per skill (`subject = skill:<ref>`, `key =
     "skill"`, body `= %{ref, content_hash, shipped_hash}`), reconciled by
     `Ezagent.Socialware.ConfigStore.seed_object_upsert/1` with
     `seed_family_prefix: "skill-seed"` → the **four-state** contract verbatim
     (absent → `:seeded`; same → `:exists`; outdated + seed-family → upgrade; outdated
     + non-seed-family override → `:exists`, preserved).
   - **Bytes** = the on-disk skill directory, reconciled by the **shipped-hash
     three-way discriminator** in `SkillSeed` (below). The index does **not** carry
     the bytes (a skill is a directory tree — scripts, exec bits, symlinks — that a
     ConfigObject JSON body cannot represent; this is a *shape* argument, not a
     no-blobs one — design §5.4).
5. **Shipped-hash three-way reconcile (bytes).** `SkillSeed` keeps the last
   **shipped_hash** (the hash of the `priv/skills_seed` dir it last seeded) in the
   index. At seed time, for each `<ref>`, compare the **on-disk** dir hash, the
   **stored shipped_hash**, and the **new priv** hash:

   | on-disk vs shipped_hash | new priv vs shipped_hash | action |
   |---|---|---|
   | equal (untouched) | equal | **no-op** |
   | equal (untouched) | differs | **upgrade** — replace dir, bump `shipped_hash` + index |
   | **differs (operator-edited)** | equal | preserve (no release change anyway) |
   | **differs (operator-edited)** | **differs** | **preserve operator edit** + **LOUD SIGNAL** ↓ |

   The **both-sides-changed cell** (operator edited **and** release changed) is the
   codex round-2 note: **preserve the operator edit**, but emit a **loud, greppable
   `Logger.warning`** (e.g. `"skill-seed: SKIPPED release upgrade for <ref> —
   operator-edited on disk (on_disk=<hash8> shipped=<hash8> release=<hash8>); operator
   edit preserved, release change NOT applied"`) **plus a telemetry event** (e.g.
   `:telemetry.execute([:ezagent, :skill_seed, :upgrade_skipped], %{count: 1},
   %{ref: ref, on_disk_hash: …, shipped_hash: …, release_hash: …})`) so the skipped
   upgrade is **visible** in logs and metrics. **Runbook line** (add to the ops
   runbook / the SPEC's §7): *"If `skill-seed: SKIPPED release upgrade` fires, a
   released skill upgrade was withheld because the deploy dir copy was operator-edited.
   To take the release version: back up and remove
   `$EZAGENT_HOME/<profile>/skills/<ref>/`, then re-run the boot seed (or `mix
   ezagent.home.init`) — it re-seeds from `priv/skills_seed` and bumps the index."*
6. **Authority stays system-vetted (design §5.3).** No runtime-writable publish
   surface. The store is written only by the `home.init`/boot seed and by operators
   with node access. Unknown/unauthorized refs fail **loudly**
   (`{:skill_source_not_found, ref}` → `role_degraded` + telemetry), never a silent
   skip.

### 4.2 P2 acceptance gates

- **`test/.../home/skill_seed_test.exs`** (new): idempotent seed (second call no-op);
  the four-way bytes matrix — untouched+unchanged (no-op), untouched+release-changed
  (upgrade), operator-edited+unchanged (preserve), **operator-edited+release-changed
  (preserve + assert the `Logger.warning` string is emitted + the telemetry event
  fires** via `:telemetry_test` handler).
- **`skill_registry_test.exs` extended**: after seed, `resolve/1` reads the
  `$EZAGENT_HOME` origin; an operator-dropped `<ref>` dir registers on the next scan;
  index reconcile hits `:seeded` / `:exists` / upgrade correctly.
- **`fs_resolver` / `home` tests**: `skills` type resolves to the deploy dir; skeleton
  mkdir present.
- Standing gates (§3.2) green — note `arch.scan` may need the `skills` type
  acknowledged the same way `socialware` is.

### 4.3 P2 exit

An operator drops/updates `$EZAGENT_HOME/<profile>/skills/<ref>/` and the next boot
registers/upgrades it; a shipped default upgrades itself on a release bump **unless**
operator-edited (in which case the skip is loudly signalled); an unknown ref degrades
loudly. One runtime origin; resolver has no overlay logic.

---

## 5. P3 — materialization fold into `stage_and_swap`

**Goal:** skill copy into an agent's `config_dir` is **folded into
`HomeRuntime.stage_and_swap`** (one atomic swap, one `.ezagent-config-complete`
marker), which makes **upgrade and removal** correct; the separate post-spawn copy
and the walk-up **die**.

### 5.1 Work items

1. **Fold the copy into `stage_and_swap`** (`home_runtime.ex:279`). The referenced
   skills (from `Recipe.skills`, resolved through `SkillRegistry`) are `cp_r`'d into
   `<staging>/skills/<ref>` **inside** the existing staging pipeline (between
   `cp_r(reference_dir, staging)` and the marker write), so the whole config_dir —
   creds, `CLAUDE.md`, **and skills** — lands via one `atomic_replace`. Because
   staging is **fresh per materialization**, a skill upgrade or removal is now
   correct (the stale dir does not survive), fixing **IC-2** — today
   `OrchestratorBootstrap.copy_skill/3` **skips an existing dest** (`:356`) so an
   already-materialized agent never picks up an upgrade.
2. **Delete the separate copy.** `OrchestratorBootstrap`'s `install_skills/2` +
   `copy_skill/3` post-spawn step is removed (materialization now owns it). Keep
   `resolve_role`/recipe-compose that produces `sandbox_content.skills`; the **list**
   of refs still comes from the recipe — only the *copy* moves.
3. **Remove the walk-up.** `search_skill_source/1` + `walk_for_skill/2` +
   `search_orchestrator_skill_source_from/1` are **deleted** (the `:dev`-gate from P1
   was a migration bridge; P3 removes the code). `SkillRegistry` is now the sole
   resolution path. The `:orchestrator_skill_source` / `:role_skill_sources`
   overrides collapse to a documented test seam or are removed.
4. **`desired_skills` (OQ-2).** The dead `AgentTemplate.desired_skills` domain
   declaration is **out of scope to wire** here; note it in §6 out-of-scope and leave
   a one-line TODO — do not collapse or delete it in this branch (it is a separate
   decision).

### 5.2 P3 acceptance gates

- **`test/.../skill_cold_spawn_regression_test.exs`** (new, **failing-first**): a
  **cold agent spawn on a fresh `$EZAGENT_HOME`** (empty home → boot seed → registry
  → materialize) results in `<config_dir>/skills/ezagent-session-orchestrator/SKILL.md`
  present. Write it red against pre-fold code, green after the fold. This is the
  end-to-end incident regression.
- **`home_runtime` tests**: skills present in the atomically-swapped config_dir;
  idempotency marker still single; a **re-materialization after a skill upgrade
  picks up the new bytes** (the IC-2 fix — assert the upgraded content replaces the
  old).
- `orchestrator_bootstrap` tests updated for the removed copy path (no dangling refs
  to `copy_skill`/walk-up).
- Standing gates (§3.2) green; `arch.scan` confirms the walk-up is gone.

### 5.3 P3 exit

Cold spawn on a fresh `$EZAGENT_HOME` gets the skill; skill upgrade/removal inside an
agent is correct via fresh staging; the walk-up no longer exists in the codebase.

---

## 6. Implementation constraints (from design §7 — binding)

- **IC-1 — directory-hash semantics (PICKED, not optional).** The content hash of a
  skill dir is over the **directory closure**, computed as: enumerate all files
  under the dir, build the **sorted set of `{relpath, mode, content_digest}`
  tuples** (relpath = POSIX-normalized path relative to the skill root; `mode` = the
  file's permission bits, so the **executable bit is part of the input**;
  `content_digest` = SHA-256 of file bytes), and SHA-256 the canonical serialization
  of that sorted set. Consequences (all required): a **rename** changes a relpath →
  hash changes; a **deletion** removes a tuple → hash changes; a **chmod +x** changes
  a mode → hash changes. **Symlinks** hash their **link target path** (as the
  `content_digest` input) rather than following the link. (The later-phase tenant
  store must *reject* symlinks outright as an escape vector — noted for that phase,
  not implemented here.) This semantics is a hard prerequisite for the P2 index
  contract; implement it as a single `Ezagent.SkillRegistry.dir_hash/1` (or a small
  `Ezagent.Skill.ContentHash`) used by both `SkillSeed` (shipped-hash) and the index.
- **IC-2 — upgrade correctness needs P3.** Until the copy moves into `stage_and_swap`
  (P3, fresh staging per materialization), an already-materialized agent never picks
  up a skill upgrade/removal (`copy_skill/3` skips an existing dest). Between P2 and
  P3, a skill upgrade therefore requires config_dir regeneration — **state this in
  the ops runbook** (add the line alongside §4.1.5's runbook line).
- **IC-3 — the runtime subset is derived, not hand-enumerated.** Both the P1
  seed-bundle list and the P1 invariant test are **computed from `Recipe.skills`
  across all `roles/0` seeds** (§2). No hand-maintained list anywhere.

### 6.1 Runbook lines to add (ops)

1. *skill-seed skipped upgrade* — see §4.1.5 (both-sides-changed recovery).
2. *pre-P3 upgrade* — *"Before P3 lands, upgrading a skill for an already-spawned
   agent requires regenerating its `config_dir` (delete the config_dir + marker so
   the next spawn re-materializes) — the in-place copy skips an existing dest."*

---

## 7. Explicit out-of-scope (later phase — NOT this handoff)

- **Workspace-custom / tenant-authored skills** (`resource://<ws>/skills/<ref>` via
  `Resource.FsResolver` per-`<ws>` authority; workspace→system resolution fallback).
- **The `resource://<ws>/skills` resource type** registration.
- **Skill CR wrapper** (a `ConfigGovernance.Skill` fork for staged/reviewed/published
  tenant skills; the authoring-boundary trust guard for skill scripts).
- **Any runtime-writable publish surface** — in P1–P3 the store is written only by
  the boot/`home.init` seed and by operators with node access.
- **`desired_skills` wiring** (OQ-2) — dead `AgentTemplate.desired_skills`; leave a
  TODO, do not collapse here.
- **Shared read-only skill store / symlink density** (OQ-3) — start with per-agent
  `cp_r`.

---

## 8. Sub-step summary (codex checklist)

| Sub-step | Lands | Key gate (failing-first where behavior changes) |
|---|---|---|
| **P1** | `priv/skills_seed` (derived set) + `Ezagent.SkillRegistry` reading the bundled origin + `resolve_skill_source` rewired, walk-up `:dev`-gated | `skill_distribution_prod_shape_test` (red→green); `skill_registry_test` |
| **P2** | `skills` in FsResolver/Home + `Home.SkillSeed` (shipped-hash three-way + loud both-sides-changed signal) + registry re-pointed at `$EZAGENT_HOME` origin + ConfigObject index (`seed_object_upsert`) | `skill_seed_test` (four-way matrix incl. telemetry/log assertion) |
| **P3** | copy folded into `HomeRuntime.stage_and_swap`; separate copy + walk-up deleted | `skill_cold_spawn_regression_test` (red→green); IC-2 upgrade-picks-up-new-bytes |

Standing gates on **every** sub-step: `mix format`,
`mix compile --warnings-as-errors --force`, `mix ezagent.check_invariants`,
`mix ezagent.arch.scan`, `mix ezagent.doc.scan` (ratchets, code-verified `@doc`).
