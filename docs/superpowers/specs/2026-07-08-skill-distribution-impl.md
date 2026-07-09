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
> Rev 2 (post codex adversarial review of this SPEC, NEEDS-CHANGES → fixed):
> HIGH-1 — P2 seed/upgrade is now **atomic** (staging-sibling + rename, boot
> recovery deletes `*.staging-*`; §4.1.6 + crash-recovery gate); MED-2 — P2 gains a
> **fresh-home boot-order gate** so the switchover is proven inside P2, not
> deferred to P3 (§4.2); impl-constraints: IC-1 mode normalized to the exec bit +
> empty-dir note; IC-4 names `mix ezagent.skills.regen_seed`.
> Rev 3 (codex round-2 verify): §4.1.6 upgrade pinned to the exact three-step
> rename sequence (`<ref>→.old-<nonce>` → staging→`<ref>` → delete `.old`) with a
> **no-concurrent-reader boot-window invariant** closing the between-renames
> window structurally, an extended recovery rule (restore `.old` when `<ref>`
> missing; drop `.old` when both present), and a **crash-point table** codex tests
> row-by-row; §4.2 gates named concretely (`skill_seed_crash_recovery_test.exs`,
> `skill_seed_boot_order_test.exs` with pinned observer, no retry/sleep); §4.3
> exit claim reworded to match.
> Rev 3.1 (codex round-3, SOUND-WITH-NOTES — accepted): pre-ready `resolve/1`
> made explicitly fail-loud (raise, no dir fallback; sole-reader = implementation
> requirement) + two double-crash rows added to the crash-point table
> (recovery rules are re-entrant); gates extended accordingly.

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
   not a hand-list — codex regenerates it via the dedicated
   **`mix ezagent.skills.regen_seed`** task (IC-4), which runs the derivation over
   `roles/0` and copies each derived ref's dev-tree closure.
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
6. **Atomic directory materialization — crash-safe seed/upgrade (codex review
   HIGH-1).** The §4.1.5 matrix covers only **complete** dirs; a crash mid-copy or
   mid-upgrade must never leave `$EZAGENT_HOME/<profile>/skills/<ref>/`
   half-populated — since P2 re-points the registry at that single origin, a
   partial dir would be hashed and **misclassified as operator-edited** (preserved
   forever) or simply broken. Interruption is handled structurally, with the
   **same fresh-staging idiom as `HomeRuntime.stage_and_swap`**
   (`home_runtime.ex:279` / `Materializer.atomic_replace`):
   - **Write to a temp sibling, rename into place.** Every seed and every upgrade
     copies into `<deploy_dir>/<ref>.staging-<nonce>` (same filesystem → same-device
     rename). **Fresh seed** (no existing `<ref>`): one atomic
     `rename(<ref>.staging-<nonce> → <ref>)`. **Upgrade — the exact three-step
     sequence, named intermediates, in this order:**
     1. `rename(<ref> → <ref>.old-<nonce>)` — atomic; the old closure stays
        **complete at a path** throughout;
     2. `rename(<ref>.staging-<nonce> → <ref>)` — atomic; the new closure
        appears complete;
     3. `delete <ref>.old-<nonce>`.
   - **No-concurrent-reader invariant (closes the between-renames window
     structurally, not probabilistically).** Between upgrade steps 1 and 2 the
     path `<ref>` is briefly **absent**. This is harmless **by construction**,
     and the SPEC pins why: seed/upgrade materialization runs **only during
     boot, strictly before the registry's first scan** — the registry scan is
     the **sole reader** of the deploy dir, and the supervisor wires `SkillSeed`
     (boot recovery + seed/upgrade) **before** the registry scan/ready, so the
     window is single-threaded and no reader exists to observe the absent path.
     There are no mid-flight runtime upgrades in P2 (the store is written only
     by the boot seed and operators, §4.1.7); an operator drop takes effect on
     the **next boot**, inside the same single-threaded window.
   - **Pre-ready admission (fail-loud, let-it-crash).** A `SkillRegistry.resolve/1`
     call arriving **before the registry's boot scan has completed** is a
     supervisor-wiring bug, not a recoverable runtime condition: it **raises**
     (registry-not-ready, message naming the required wiring order) — it never
     blocks, never returns a partial answer, and **never falls back to reading
     the skills dir directly**. This makes the sole-reader rule an
     **implementation requirement, not just an argument**: no component other
     than the registry's boot scan may read `$EZAGENT_HOME/<profile>/skills` —
     every consumer goes through `resolve/1`, and `resolve/1` refuses to answer
     until the scan is done.
   - **Boot recovery rule — repairs EVERY crash residue, runs before seeding:**
     1. **always** delete every `*.staging-*` dir;
     2. if `<ref>` **missing** and `<ref>.old-<nonce>` present →
        `rename(<ref>.old-<nonce> → <ref>)` — restore the old complete closure
        (the interrupted upgrade simply **re-applies** during this same boot's
        seed run);
     3. if **both** `<ref>` and `<ref>.old-*` present → delete `<ref>.old-*`
        (rename-in had completed; this finishes the interrupted step 3).
   - **Crash-point table** — every crash point lands in a state the recovery
     provably repairs; codex writes a test case per row:

     | crash point | residue on disk | recovery → post-boot state |
     |---|---|---|
     | mid-copy into staging | partial `.staging-*` (+ old complete `<ref>` if upgrade) | staging deleted; old dir (or absence) intact; seed/upgrade re-runs this boot |
     | staging complete, before upgrade step 1 | complete `.staging-*` + old complete `<ref>` | staging deleted (cheap re-copy); upgrade re-runs this boot |
     | between upgrade steps 1 and 2 | `<ref>` **missing**; `.old-<nonce>` + `.staging-*` present | staging deleted; `.old` renamed back to `<ref>`; upgrade re-runs this boot |
     | between upgrade steps 2 and 3 | new complete `<ref>` + `.old-<nonce>` present | `.old` deleted; new closure stands |
     | mid-fresh-seed rename | `<ref>` either absent or complete (rename is atomic) | leftover staging deleted if any; seed re-runs if absent |
     | **double-crash: mid-delete of `.staging-*` during recovery** | partially-deleted `.staging-*` still present; main state (`<ref>` / `.old`) untouched by the delete | recovery **re-entrant**: next boot's rule 1 deletes it again (`rm_rf` is idempotent); main-state rules 2/3 then apply unchanged |
     | **double-crash: after `.old → <ref>` restore, before the re-seed applies** | old complete `<ref>` back in place; no `.old-*`, no `.staging-*` | indistinguishable from a normal pre-upgrade state; this (or the next) boot's seed run re-detects untouched+release-differs → **upgrade re-applies**; nothing lost |

     The recovery rules are **re-entrant**: any crash *during recovery itself*
     leaves a residue that the same rules repair on the next boot — no
     recovery-of-the-recovery mechanism is needed.

   - **Registry hygiene.** The `SkillRegistry` scan **skips `*.staging-*` and
     `*.old-*` names** defensively (an intermediate dir is never indexed).
7. **Authority stays system-vetted (design §5.3).** No runtime-writable publish
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
- **Crash-recovery gate (HIGH-1)** — `test/.../home/skill_seed_crash_recovery_test.exs`:
  **one test case per row of the §4.1.6 crash-point table** — plant that row's
  exact residue in the deploy dir (partial staging; complete staging + old
  `<ref>`; `<ref>` missing + `.old-<nonce>` + staging; new `<ref>` + `.old-<nonce>`;
  leftover staging alone; **plus the two double-crash rows**: partially-deleted
  staging from an interrupted recovery, and restored-old-`<ref>` with no
  intermediates awaiting the re-applied upgrade) → run the boot recovery + seed
  path → assert the
  table's post-boot state: intermediates gone, `SkillRegistry.resolve/1` returns
  the ref's **complete** closure with the correct hash, and **no
  operator-edited misclassification** (the reconcile classifies the recovered
  dir by its true hash, never by a partial one).
- **Fresh-home boot-order gate (MED-2)** —
  `test/.../home/skill_seed_boot_order_test.exs`, test description:
  `"fresh $EZAGENT_HOME: every derived Recipe.skills ref resolves on the FIRST
  registry read after boot (SkillSeed strictly before first scan)"`. Start from
  a **fresh `$EZAGENT_HOME`** (no manual `seed!` call anywhere in the test),
  drive the seed + registry path **in the exact order the application
  supervisor wires it** (`home.init`-absent boot fallback included). The
  "before any consumer reads" claim is pinned to a concrete observer, both
  directions:
  - **order**: assert the registry's scan/ready step (its ETS table population
    or ready event) happens **only after** `SkillSeed` completes — enforced by
    the supervisor child order, asserted by the test observing that order (e.g.
    the registry's ETS table does not exist / is empty until `SkillSeed` has
    returned);
  - **first-read success**: assert `SkillRegistry.resolve/1` succeeds for
    **every derived `Recipe.skills` ref on the first call after boot**, with
    **NO retry, NO `Process.sleep`, NO eventually-consistent polling** anywhere
    in the test — deterministic on the first read, or the gate is red;
  - **pre-ready refusal**: a `resolve/1` attempt made **before** the registry is
    ready **fails cleanly** (raises registry-not-ready per §4.1.6) and **never
    observes a partial dir** — asserted as its own case in this test file.
  This proves P2 is independently deployable — the fresh-home switchover must
  not wait for P3's cold-spawn test.
- **`fs_resolver` / `home` tests**: `skills` type resolves to the deploy dir; skeleton
  mkdir present.
- Standing gates (§3.2) green — note `arch.scan` may need the `skills` type
  acknowledged the same way `socialware` is.

### 4.3 P2 exit

An operator drops/updates `$EZAGENT_HOME/<profile>/skills/<ref>/` and the next boot
registers/upgrades it; a shipped default upgrades itself on a release bump **unless**
operator-edited (in which case the skip is loudly signalled); an unknown ref degrades
loudly. One runtime origin; resolver has no overlay logic. A fresh `$EZAGENT_HOME`
boots to a fully-resolvable registry with no manual step, deterministically on the
first read (MED-2 gate). Crash-safety (HIGH-1): at every instant **outside the
single-threaded boot window**, `<ref>` on disk is either the old complete closure
or the new complete closure — never partial, never absent; **inside** the boot
window the brief absent state during the upgrade rename pair is unobservable
because no reader exists until `SkillSeed` completes, and the boot recovery rule
repairs every crash residue per the §4.1.6 table.

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
  under the dir, build the **sorted set of `{relpath, exec_bit, content_digest}`
  tuples** (relpath = POSIX-normalized path relative to the skill root;
  `exec_bit` = the file mode **deliberately normalized down to a single
  owner-executable boolean** — full permission bits are **excluded on purpose**,
  because macOS vs Linux copy/umask semantics can differ on the other bits and
  would produce spurious "operator-edited" classifications; only the exec bit is
  semantically load-bearing for a skill script; `content_digest` = SHA-256 of file
  bytes), and SHA-256 the canonical serialization of that sorted set. Consequences
  (all required): a **rename** changes a relpath → hash changes; a **deletion**
  removes a tuple → hash changes; a **chmod +x** flips `exec_bit` → hash changes; a
  chmod that touches only non-exec bits does **not** change the hash (intended).
  **Empty directories do not affect the hash** (only files contribute tuples) —
  acceptable and intended: the seed content is git-backed, and git itself does not
  track empty dirs, so no shipped closure can differ by one. **Symlinks** hash
  their **link target path** (as the `content_digest` input) rather than following
  the link. (The later-phase tenant store must *reject* symlinks outright as an
  escape vector — noted for that phase, not implemented here.) This semantics is a
  hard prerequisite for the P2 index contract; implement it as a single
  `Ezagent.SkillRegistry.dir_hash/1` (or a small `Ezagent.Skill.ContentHash`) used
  by both `SkillSeed` (shipped-hash) and the index.
- **IC-2 — upgrade correctness needs P3.** Until the copy moves into `stage_and_swap`
  (P3, fresh staging per materialization), an already-materialized agent never picks
  up a skill upgrade/removal (`copy_skill/3` skips an existing dest). Between P2 and
  P3, a skill upgrade therefore requires config_dir regeneration — **state this in
  the ops runbook** (add the line alongside §4.1.5's runbook line).
- **IC-3 — the runtime subset is derived, not hand-enumerated.** Both the P1
  seed-bundle list and the P1 invariant test are **computed from `Recipe.skills`
  across all `roles/0` seeds** (§2). No hand-maintained list anywhere.
- **IC-4 — named seed-bundle regeneration helper (this SPEC).** The checked-in
  `priv/skills_seed` bundle is regenerated by a dedicated mix task —
  **`mix ezagent.skills.regen_seed`** (dev-only, alongside the existing
  `ezagent.*` tasks in `apps/ezagent_core/lib/mix/tasks/`): it runs the §2
  derivation over every `roles/0` seed, copies each derived ref's dev-tree
  closure (`.claude/skills/<ref>/`) into
  `apps/ezagent_web/priv/skills_seed/<ref>/`, and prints the derived set + hashes.
  Codex implements this task in P1 (it is *how* work-item §3.1.1 is produced, not
  a manual copy) so the bundle can never drift from the derivation rule; the P1
  prod-shape invariant test is the enforcement, this task is the remediation.

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
| **P2** | `skills` in FsResolver/Home + `Home.SkillSeed` (shipped-hash three-way + loud both-sides-changed signal; **atomic staging-then-rename + boot recovery**, HIGH-1) + registry re-pointed at `$EZAGENT_HOME` origin + ConfigObject index (`seed_object_upsert`) | `skill_seed_test` (four-way matrix incl. telemetry/log assertion); **crash-recovery gate**; **fresh-home boot-order gate** (MED-2) |
| **P3** | copy folded into `HomeRuntime.stage_and_swap`; separate copy + walk-up deleted | `skill_cold_spawn_regression_test` (red→green); IC-2 upgrade-picks-up-new-bytes |

Standing gates on **every** sub-step: `mix format`,
`mix compile --warnings-as-errors --force`, `mix ezagent.check_invariants`,
`mix ezagent.arch.scan`, `mix ezagent.doc.scan` (ratchets, code-verified `@doc`).
