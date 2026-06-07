# Architecture Deepening — Phase 2: Architecture Fitness Functions

**Status**: Codex-executable handoff. Authored 2026-06-07.
**Repo**: `esr-ng`, branch off `origin/main`.
**Task**: `docs/futures/todo.md` #25 — architecture deepening, Phase 2.
**Companion (Chinese)**: [2026-06-07-architecture-deepening-phase2-fitness-functions.zh_cn.md](2026-06-07-architecture-deepening-phase2-fitness-functions.zh_cn.md).
**Predecessor**: Phase-1 proposal `docs/notes/2026-06-07-architecture-deepening-v1.md` (merged PR #610).

---

## 0. The reframe (read this first)

Codex's Phase-1 proposal framed Phase-2 as a sequence of behavior-preserving
**refactor PRs** (PR-A AdminLive split, PR-C SessionCreator, …). Allen reframed it:

> **Phase 2 is NOT the refactors. Phase 2 is a suite of executable
> "architecture fitness functions" — tests + grep/scans that REVEAL and
> QUANTIFY architectural debt** (redundancy, ad-hoc patterns, anti-patterns).
> The fixes move to **Phase 3+**, where each refactor PR drives a specific
> fitness-function count to its target. "Count hits target = PR done" —
> objective acceptance, not subjective "is it cleaner".

This applies two of Allen's standing rules to *architecture itself*:

- `feedback_systematic_fix_over_local_entropy` — don't point-patch a systemic
  problem; locate **all** instances via a scan, then fix in one mechanical pass.
  The scan *is* the fitness function.
- `feedback_completion_requires_invariant_test` — never claim a phase "done" on
  merge + tests-pass alone; define a test that **fails when the architectural
  goal is unmet**. That test is the gate. Here, "no more than N violations" is
  the gate, and Phase 3+ ratchets N down to target.

There is strong precedent in this repo: `mix ezagent.check_invariants` (a
grep-based Mix task, 16 checks) and the `test/invariants/` ExUnit suites
(e.g. `uri_canonicalization_invariant_test.exs`) already encode exactly this
shape — grep with an allowlist + a `# <gate>-allow: <reason>` suppression
idiom. **Phase 2 generalizes that pattern from "hard invariants" to
"architecture debt counters".**

### The PR-0 guardrails are a SUBSET of Phase 2

A prior review of Phase-1 (ACCEPT-WITH-CHANGES) produced a "PR-0" guardrail set —
the invariant-**PROTECTING** fitness functions (effect-discipline, single-writer +
create-chokepoint, cold-restart round-trip, Kind.Runtime ordering, both gates
green). Those are the **target=0, must-never-regress** subset. Phase 2 is broader:
it ALSO ships the debt-**REVEALING** counters (oversized files, raw-Home.path,
duplicated resolution, …) whose targets Phase 3+ ratchets down from a captured
baseline rather than holding at 0.

---

## 1. The deliverable shape (the key design decision)

### 1.1 Where the fitness functions live

```
apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex     # the scanner Mix task
apps/ezagent_core/test/architecture/                     # ExUnit "architecture tests"
  ├── arch_baseline_manifest.exs                         # the known-violations worklist (data)
  ├── oversized_modules_test.exs
  ├── raw_home_path_test.exs
  ├── spawn_chokepoint_test.exs
  ├── duplicated_resolution_test.exs
  ├── effect_discipline_test.exs        # PR-0 (target 0)
  ├── single_writer_test.exs            # PR-0 (target 0)
  └── runtime_ordering_test.exs         # PR-0 (target 0)
docs/notes/2026-06-07-arch-fitness-baseline.md           # human-readable baseline report
```

`mix ezagent.arch.scan` is a **source-tree grep task** (no runtime BEAM),
modeled on `ezagent.check_invariants`. It is a Category-A dev-loop tool, NOT a
dispatched op (same carve-out as `check_invariants` — see
`docs/notes/2026-05-24-cli-gui-parity-audit.md`). It prints each fitness
function, its current count, its baseline cap, and PASS/FAIL.

### 1.2 How they REPORT — the baseline manifest

The single most important design element. Each fitness function has a
**baseline cap N** stored in `arch_baseline_manifest.exs` (a plain data map):

```elixir
%{
  oversized_modules_gt_1500: 5,     # files > 1500 LOC
  oversized_modules_gt_1000: 17,    # files > 1000 LOC
  raw_home_path_outside_core: 11,   # Home.path() call sites bypassing the UriQuery seam
  duplicated_resolve_template_class: 3,
  # PR-0 invariant-protecting (must stay 0):
  cross_slice_set_violations: 0,
  spawn_fresh_outside_allowlist: 0,
  ...
}
```

### 1.3 The ratchet rule (PASSING-AT-BASELINE)

Each architecture test asserts **"no MORE than N violations"**, where N is the
manifest cap:

```elixir
test "oversized modules (>1500 LOC) do not increase beyond baseline" do
  count = ArchScan.count(:oversized_modules_gt_1500)
  assert count <= Manifest.cap(:oversized_modules_gt_1500),
    "Regression: #{count} files > 1500 LOC, baseline cap is #{Manifest.cap(...)}. " <>
    "A new oversized module was introduced. Split it or justify a cap bump."
end
```

Consequences of this design:

1. **Phase 2 lands GREEN-AT-BASELINE.** The suite passes the moment it merges,
   because every cap equals the measured baseline. Phase 2 reveals + freezes the
   debt; it doesn't fix it.
2. **It is a one-way ratchet.** A new violation pushes the count above the cap →
   test fails → the debt cannot silently grow. Existing invariant-protecting gates
   (caps already at 0) catch *re-introductions*; the debt counters catch
   *additions*.
3. **Phase 3+ acceptance is objective.** A refactor PR lowers a count, then
   lowers the cap to match. "PR-A done" = `oversized_modules_gt_1500` cap drops
   5→4 and the suite is green. No subjective "is it cleaner" review.
4. **A cap can only be *raised* with an explicit `# arch-cap-bump: <reason>`
   in the manifest** — making any debt increase a reviewable, intentional act.

The suppression idiom carries over from `uri_canonicalization_invariant_test.exs`:
any line ending `# arch-allow: <reason>` is exempt from a counter (for genuine
structural exceptions, e.g. the `Home` module defining `path/1` itself).

---

## 2. The fitness functions — with REAL baselines (measured 2026-06-07 on `origin/main`)

All counts below were produced by the exact commands shown, run on `origin/main`.
Exclusions: `/test/` paths, `_build/`, `deps/`. "Core" = `apps/ezagent_core`.

### Category A — Redundancy (duplicated logic / parallel implementations)

#### A1. Multiple writers to the session-spawn path

- **Smell & why**: Invariant — single-writer + create-chokepoint. Only the
  sanctioned chokepoint should reach `SpawnRegistry.spawn_detailed/1`. Scattered
  writers are the scenario-34 / #533 creation-unification bug class.
- **Mechanism (scan)**:
  ```bash
  grep -rEn 'SpawnRegistry\.spawn(_detailed)?\(' apps --include='*.ex' \
    | grep -v '/test/' | sed 's#:[0-9]*:.*##' | sort | uniq -c | sort -rn
  ```
  ExUnit: assert the set of modules calling `SpawnRegistry.spawn*` is a subset of
  an allowlist (the chokepoint + sanctioned domain writers).
- **BASELINE**: **38 call sites across 32 modules.** The chokepoint is
  `Ezagent.Kind` (`kind.ex:294 def spawn/2`); the legitimate domain writers are
  `entity/agent.ex` (3), `entity/session.ex` (2), `session_creator.ex` (2). The
  remaining ~25 modules (incl. 4 plugin templates, 2 demo seed tasks, several
  `*/application.ex`) are the worklist.
- **Target**: ratchet the off-chokepoint module count toward the sanctioned
  allowlist. (Many are seed/demo tasks — classify each as allow vs. fix in PR.)

#### A2. `create_session/3` callers

- **Smell & why**: `SessionCreator.create_session/3` is the lower-level single
  writer. Callers should be few + sanctioned (admin LV, workspace behavior, home
  LV, app boot). Growth here means a new session-creation path.
- **Mechanism**: `grep -rEn '\.create_session\(' apps --include='*.ex' | grep -v '/test/'`
- **BASELINE**: **6 call sites across 5 modules** (`admin_live.ex` x2,
  `application.ex`, `workspace.ex`, `workspace.create_session` mix task,
  `home_live.ex`). All currently legitimate.
- **Target**: hold at 5 modules (regression guard, not a reduction target).

#### A3. Duplicated `resolve_template_class/1`

- **Smell & why**: Copy-pasted resolution logic — the same template-class
  resolution implemented 3 times. One canonical resolver should exist.
- **Mechanism**: `grep -rEn 'defp? resolve_template_class' apps --include='*.ex' | grep -v '/test/'`
- **BASELINE**: **3 definitions** — `entity/agent.ex:1271`,
  `entity/agent_template.ex:381`, `plugin_liveview/agent_extensions_live.ex:126`.
- **Target**: **1** (consolidate to one domain seam; the other two delegate).

#### A4. Parallel cc/codex flavor-runtime (duplicated Template Class)

- **Smell & why**: `cc_agent.ex` (2222 LOC) and `codex_agent.ex` (1009 LOC)
  implement the SAME seam shape (config-home materialization, credential grants,
  spawn-plan, rollback, respawn) twice. This is the Phase-1 §3.3 finding and the
  largest duplication surface.
- **Mechanism (proxy)**: count call sites of the shared callback names in both
  modules; track combined LOC of the two Template Classes.
  ```bash
  wc -l apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex \
        apps/ezagent_plugin_codex/lib/ezagent/template/codex_agent.ex
  ```
- **BASELINE**: combined **3231 LOC**; both implement `template_data_extra`,
  `validate`, `config_dir`-handling, `pty_params`, `instantiate`,
  `form_to_args` independently. (This converges with A-line: extracting shared
  `Ezagent.Agent.ConfigHome` / `SpawnPlan` reduces BOTH the duplication AND the
  oversized-module count.)
- **Target**: combined LOC drops as shared seams (`ConfigHome`, `SpawnPlan`,
  `TemplateData`) are extracted; tracked as a LOC threshold, not a hard count.

### Category B — Ad-hoc (bypassing seams / chokepoints)

#### B1. Raw filesystem path construction bypassing the UriQuery / Resource seam

- **Smell & why**: `Ezagent.Home.path(...)` + raw `Path.join` on home-derived
  paths is ad-hoc resource addressing. The Resource-unification line wants a
  single URI/seam for addressable resources (uploads, credentials, config-home,
  sockets, logs). Each raw call site is a place a future Resource Kind/URI can't
  see. **This counter converges with the Resource-unification work** — note it.
- **Mechanism (scan)**:
  ```bash
  grep -rn 'Home\.path(' apps --include='*.ex' | grep -v '/test/' \
    | grep -v 'apps/ezagent_core'
  grep -rn 'Path.expand("~' apps --include='*.ex' | grep -v '/test/'
  ```
- **BASELINE**:
  - `Home.path(` total **22** call sites; **12 outside core** (the ones that
    should route through a seam): `agent_bridge/token_store.ex`,
    `identity/application.ex`, `codex_agent.ex:892`, `admin_live.ex` (701, 731 —
    uploads), `cc_agent.ex:1460` (comment), `feishu/client.ex` (164, 176),
    `feishu/ws_client.ex:165`, `feishu/application.ex:176`,
    `ezagent_web/uploads_controller.ex:108`, `python/server.ex:708`.
  - `Path.expand("~` **2** sites (`cc` seed task comment + `mcp_config_writer.ex`
    `@default_dir`).
- **Target**: raw-Home.path-outside-core → **0** (all route through the resolved
  seam). The uploads sites (admin_live + uploads_controller) are the first
  Phase-3 reduction (uploads-via-UriQuery).

#### B2. `spawn_fresh` outside its sanctioned allowlist

- **Smell & why**: Invariant — managed-member/team materialization must route
  through `spawn_from_template_content`, never `spawn_fresh` (the scenario-34
  bug: `spawn_fresh` makes a bare Kind with no CLI/PTY). `spawn_fresh` is a
  low-level primitive; only `Entity.Agent` (definition) + the reconciler path may
  use it.
- **Mechanism**:
  ```bash
  grep -rEn 'spawn_fresh(_member)?\(' apps --include='*.ex' | grep -v '/test/' \
    | grep -vE ':[0-9]+:\s*#'
  ```
- **BASELINE**: **5 real references**; the actual *invocations* are
  `entity/agent.ex:182` (the reconciler-allowed self-call) and
  `tools.ex:564` (`spawn_fresh_member`, an internal `defp` defined at
  `tools.ex:293`). Of 41 `spawn_from_template_content` sites, the
  template-content path dominates — good. The two `spawn_fresh` call sites are
  the audit surface.
- **Target**: **0 unsanctioned**; both current calls go on the explicit
  allowlist with a justification, OR `tools.ex` `spawn_fresh_member` is proven to
  route through the template-content path. PR-0 invariant — must never grow.

#### B3. Direct cross-slice state access / `:all_slices` escape hatch

- **Smell & why**: Invariant #18 — sibling-slice reads are opt-in via
  `reads_sibling_slices/0`; `:all_slices` is banned.
- **Mechanism**: `grep -rn ':all_slices' apps --include='*.ex' | grep -v '/test/'`
- **BASELINE**: **3 occurrences, 0 violations** — two are in comments
  (`behavior.ex:454`, `kind/runtime.ex:182` describing the ban), one is a
  documented OWN-slice read (`system_principal/catalog.ex:271`,
  `ctx[:all_slices][:api_keys]` reading its own slice). `reads_sibling_slices/0`
  is declared in **2** modules.
- **Target**: **0** unsanctioned `:all_slices`. Already at 0 — pure regression
  guard.

### Category C — Anti-pattern (oversized modules / god-functions / missing gates)

#### C1. Oversized modules (LOC threshold)

- **Smell & why**: Ousterhout deep-module / god-module anti-pattern. Threshold
  set at **1500 LOC** (hard) and **1000 LOC** (watch). Each oversized file hides
  multiple interfaces behind one module — the Phase-1 §3 finding.
- **Mechanism (scan)**:
  ```bash
  find apps -path '*lib*' -name '*.ex' | xargs wc -l \
    | awk '$1>1500 && $2!="total"' | sort -rn
  ```
- **BASELINE**:
  - **> 1500 LOC: 5 files** —
    | LOC | File |
    |---:|---|
    | 3217 | `ezagent_plugin_liveview/.../admin_live.ex` |
    | 2222 | `ezagent_plugin_cc/.../template/cc_agent.ex` |
    | 1983 | `ezagent_domain_instance_message/.../session_creator.ex` |
    | 1886 | `ezagent_domain_instance_message/.../orchestrator/tools.ex` |
    | 1798 | `ezagent_domain_instance_message/.../behavior/chat.ex` |
  - **> 1000 LOC: 17 files** — the 5 above plus:
    | LOC | File |
    |---:|---|
    | 1459 | `ezagent_core/.../kind/runtime.ex` |
    | 1422 | `ezagent_core/.../behavior.ex` |
    | 1395 | `ezagent_domain_workspace/.../behavior/workspace.ex` *(not in Phase-1 inventory)* |
    | 1363 | `ezagent_domain_instance_message/.../entity/agent.ex` |
    | 1351 | `ezagent_domain_instance_message/.../entity/session.ex` |
    | 1117 | `ezagent_domain_instance_message/.../application.ex` *(not in Phase-1 inventory)* |
    | 1076 | `ezagent_core/.../kind.ex` |
    | 1071 | `ezagent_domain_instance_message/.../orchestrator/mcp_server.ex` |
    | 1023 | `ezagent_core/.../capability.ex` |
    | 1010 | `ezagent_domain_external_mirror/.../behavior/external_mirror_worker.ex` *(not in Phase-1 inventory)* |
    | 1009 | `ezagent_plugin_codex/.../template/codex_agent.ex` |
    | 1004 | `ezagent_domain_external_mirror/.../behavior/external_mirror.ex` *(not in Phase-1 inventory)* |
- **Target**: `gt_1500` cap 5 → ratchet to 0 over Phase 3+. `gt_1000` cap 17 →
  watch (no new entrants). NOTE: Phase-1's inventory missed 4 files (workspace.ex,
  application.ex, external_mirror{,_worker}.ex) — Phase 2 captures the FULL set.

#### C2. God-functions (def-count proxy per oversized module)

- **Smell & why**: A module with very many `def/defp` is doing too much; tracks
  the same anti-pattern at function granularity, and gives Phase 3+ a per-module
  reduction signal independent of pure LOC.
- **Mechanism**: `grep -cE '^\s*(def|defp) ' <file>` per oversized module.
- **BASELINE**: `admin_live.ex` **186**, `cc_agent.ex` **103**,
  `tools.ex` **83**, `session_creator.ex` **78**, `capability.ex` **65**.
- **Target**: per-module def-count drops as each is split; tracked per file in
  the manifest, ratcheted alongside C1.

#### C3. Cross-slice `{:set}` / effect-discipline (PR-0)

- **Smell & why**: Invariant #18 effect-discipline — no Behavior handler/helper
  does a cross-slice `{:set, :other_slice, ...}` or a side-effecting write
  outside the `(state, args, ctx) -> {data, [effect]}` grammar. A handler may
  only `{:set, <own_slice>, ...}`.
- **Mechanism**: enumerate `{:set, :<slice>, ...}` effects and assert each
  module only sets its own declared `state_slice` (ExUnit walking the AST /
  grep + per-module slice map). Raw scan:
  ```bash
  grep -rEn '\{:set,\s*:[a-z_]+,' apps --include='*.ex' | grep -v '/test/'
  ```
- **BASELINE**: **118** `{:set, :slice, ...}` effect sites total. The fitness
  function asserts **0 cross-slice** among them (each set targets the emitting
  module's own slice). Phase 2 captures the per-module slice allowlist; the
  count of *cross-slice* violations is the gated number.
- **Target**: cross-slice violations **0** (PR-0; must never grow).

#### C4. Missing cap-check on mutating actions (PR-0)

- **Smell & why**: CapBAC chokepoint — every mutating action routes through
  `Kind.Runtime` authz (`authz_check → workspace_isolation_check → invoke`,
  never reordered). A mutating Behavior action without `required_caps` is a hole.
- **Mechanism**: ExUnit over the Behavior registry — every action declared with
  a mutating effect must declare `required_caps`. (There is already
  `behavior_required_caps_action_invariant_test.exs` — extend/alias it into the
  arch suite rather than duplicate.)
- **BASELINE**: existing invariant test passes → **0 known violations**.
- **Target**: **0** (PR-0; protected by the existing gate, surfaced in the arch
  manifest for completeness).

#### C5. Kind.Runtime ordering (PR-0)

- **Smell & why**: `handle_dispatch/4` must run
  `authz_check → workspace_isolation_check → invoke`, never reordered / skipped /
  re-entrant (invariant #17 — no re-entry to dispatch from
  `target_ownership_check/2` or `event_to_payload/1`).
- **Mechanism**: ExUnit asserting the call order in `kind/runtime.ex` (AST /
  ordered-grep of the three stage calls) + the existing re-entrancy invariant.
- **BASELINE**: ordering intact → **0 violations**.
- **Target**: **0** (PR-0).

#### C6. Cold-restart respawn round-trip (PR-0)

- **Smell & why**: spawn → snapshot → cold-restart → cascade must re-resolve +
  re-cap identically (#110/#113/#114 class). This is a *behavioral* fitness
  function, not a grep — it belongs as an ExUnit round-trip under `MIX_ENV=test`.
- **Mechanism**: ExUnit (test env only) that spawns a templated session, snapshots,
  simulates cold restart, and asserts resolved caps + member set are identical.
  Reuse existing cold-restart test fixtures if present.
- **BASELINE**: assumed green (existing `mix ezagent.check_invariants.lifecycle`
  covers the lifecycle class). Phase 2 adds the explicit round-trip assertion.
- **Target**: **0** drift (PR-0).

---

## 3. Phase 2 → Phase 3+ map

Each Phase-3+ refactor PR is now defined by **which fitness-function count it
reduces**, and "done" = the count + its manifest cap both drop to target and the
suite stays green. Codex's original PR-A/B/… become:

| Phase-3+ PR (from Phase-1 §6) | Fitness function it drives | Count change |
|---|---|---|
| **PR-A** AdminLive split (§3.1) | `oversized_gt_1500` (admin_live 3217) + C2 def-count (186) | gt_1500 cap 5→4 |
| PR-B AdminLive compose/invite/routing | C2 admin_live def-count | def-count drop |
| Uploads via UriQuery seam | B1 raw-Home.path-outside-core (admin_live 701/731 + uploads_controller 108) | 12→9 |
| PR-C SessionCreator listing/resolver | (prep) — no count yet | — |
| PR-D/E SessionCreator team/rollback | `oversized_gt_1500` (session_creator 1983) | gt_1500 cap →3 |
| PR-F/G Orchestrator Mcp/Tools split | `oversized_gt_1000` (mcp_server 1071) + `oversized_gt_1500` (tools 1886) | caps drop |
| **PR-H** cc/codex ConfigHome + SpawnPlan | A4 combined-LOC + `oversized_gt_1500` (cc_agent 2222) + B1 (codex_agent 892) | gt_1500 cap →; A4 LOC drop |
| Consolidate `resolve_template_class` | A3 duplicated-resolution | 3→1 |
| PR-I Behavior.Chat helpers | `oversized_gt_1500` (chat 1798) | gt_1500 cap drop |
| PR-K/L Capability / Behavior split | `oversized_gt_1000` (capability 1023, behavior 1422) + C2 capability def-count (65) | caps drop |

### Recommended first Phase-3 PR + ordering

1. **First: PR-A — AdminLive session-context + rehydrate-flash extraction.**
   Biggest single file (3217), lowest invariant risk (UI, no CapBAC core), purely
   mechanical. Drives `oversized_gt_1500` 5→4. This was the Phase-1 review's
   recommendation and the safest objective win.
2. **Capability-split BEFORE the cc/codex shared-runtime PR (PR-H).** The
   cc/codex ConfigHome/SpawnPlan extraction (PR-H) is security-sensitive (config-
   home copying, secret relpaths, grant minting). Splitting `Capability`
   (`Normalize` / `Match` / `Scope`, capability.ex 1023 LOC) first gives PR-H a
   clean, audited capability seam to build the credential-grant path on, instead
   of extracting shared credential logic against a still-monolithic Capability.

---

## 4. Codex execution instructions (autonomous)

**Scope**: build the Phase-2 suite + manifest + scanner. Do NOT do any Phase-3
refactor in this work. Land green-at-baseline.

1. Create `mix ezagent.arch.scan` modeled on
   `apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.ex` (source-tree
   grep, no BEAM, Category-A dev-loop tool — keep it as `mix ezagent.arch.*`, do
   NOT migrate to dispatched `mix ezagent`). One function per fitness function in
   §2, each returning `{name, count}`.
2. Create `apps/ezagent_core/test/architecture/arch_baseline_manifest.exs` with
   the caps set to the **measured baselines in §2** (these are authoritative as
   of 2026-06-07 on `origin/main`; re-measure with the §2 commands and use the
   fresh numbers if `main` has moved).
3. Create one ExUnit test per fitness function asserting `count <= cap`, modeled
   on `apps/ezagent_core/test/invariants/uri_canonicalization_invariant_test.exs`
   (allowlist + `# arch-allow: <reason>` suppression idiom). PR-0 functions
   (B2, B3, C3, C4, C5, C6) assert `== 0`.
4. Write `docs/notes/2026-06-07-arch-fitness-baseline.md` — the human-readable
   debt inventory (the §2 tables) cross-linked from this handoff.
5. Add an ARCHITECTURE.md Decision Log entry (Appendix B, next sequential
   number): "Architecture fitness functions — Phase 2 debt counters, ratcheted by
   Phase 3+; new violations fail CI; cap raises require `# arch-cap-bump:`."

**Acceptance (objective)**:
- [ ] `mix ezagent.arch.scan` runs and prints every fitness function + count + cap + PASS.
- [ ] `mix test apps/ezagent_core/test/architecture/` is GREEN at baseline.
- [ ] `mix ezagent.check_invariants` GREEN (unchanged).
- [ ] `mix ezagent.check_invariants.lifecycle` GREEN (unchanged).
- [ ] Baseline manifest caps == measured §2 numbers; baseline note committed.
- [ ] No production `.ex` under `apps/*/lib` modified (suite + manifest + docs only).

**Constraints**:
- Static-only Codex review (`feedback_codex_companion_no_mix`): the companion has
  no `mix deps`; review reads source statically, does not run `mix`.
- Test only under `MIX_ENV=test`; never touch dev/prod migrations or Docker.
- Bilingual docs (`feedback_bilingual_docs_convention`): keep this `.md` and the
  `.zh_cn.md` companion in sync.

---

## 5. Summary — what Phase 2 reveals + quantifies

| Fitness function | Category | Baseline | Target |
|---|---|---:|---|
| Files > 1500 LOC | anti-pattern | **5** | 0 (ratchet) |
| Files > 1000 LOC | anti-pattern | **17** | watch |
| admin_live def-count | anti-pattern | **186** | reduce |
| cc_agent def-count | anti-pattern | **103** | reduce |
| `SpawnRegistry.spawn*` off-chokepoint modules | redundancy | **~25 of 32** | allowlist |
| `create_session/3` caller modules | redundancy | **5** | hold |
| duplicated `resolve_template_class/1` | redundancy | **3** | 1 |
| cc+codex Template Class combined LOC | redundancy | **3231** | reduce |
| raw `Home.path()` outside core | ad-hoc | **12** | 0 |
| `Path.expand("~`  | ad-hoc | **2** | 0 |
| `spawn_fresh` unsanctioned calls | ad-hoc (PR-0) | **2** sites (audit) | 0 |
| `:all_slices` unsanctioned | ad-hoc (PR-0) | **0** | 0 |
| cross-slice `{:set}` (of 118 `:set` sites) | anti-pattern (PR-0) | **0** | 0 |
| missing cap-check on mutating action | anti-pattern (PR-0) | **0** | 0 |
| Kind.Runtime ordering / re-entrancy | anti-pattern (PR-0) | **0** | 0 |
| cold-restart respawn drift | behavioral (PR-0) | **0** | 0 |

PR-0 set (target 0, must-never-regress): effect-discipline, single-writer +
create-chokepoint, cold-restart round-trip, Kind.Runtime ordering, both gates
green. Debt-revealing counters (ratcheted down by Phase 3+): oversized modules,
def-counts, raw-Home.path, duplicated resolution, cc/codex combined LOC.
