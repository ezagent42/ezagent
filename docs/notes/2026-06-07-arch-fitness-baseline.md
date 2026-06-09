# Architecture Fitness Baseline — 2026-06-07

This report captures the Phase-2 architecture fitness-function baseline from
`mix ezagent.arch.scan` on `origin/main` for `docs/futures/todo.md` #25.

Phase 2 reveals and freezes architecture debt. It does not refactor production
modules. Every counter is capped in
`apps/ezagent_core/test/architecture/arch_baseline_manifest.exs`; the ExUnit
suite asserts `count <= cap`. Phase 3+ PRs reduce a count and lower the cap to
match. Raising a cap requires a same-line `# arch-cap-bump: <reason>`.

## Baseline Counters

| Fitness function | Count | Cap | Target |
|---|---:|---:|---:|
| `oversized_modules_gt_1500` | 5 | 5 | 0 |
| `oversized_modules_gt_1000` | 17 | 17 | watch |
| `def_count_admin_live` | 186 | 186 | reduce |
| `def_count_cc_agent` | 103 | 103 | reduce |
| `def_count_orchestrator_tools` | 83 | 83 | reduce |
| `def_count_session_creator` | 78 | 78 | reduce |
| `def_count_capability` | 65 | 65 | reduce |
| `spawn_registry_call_sites` | 38 | 38 | classify + ratchet |
| `spawn_registry_modules` | 32 | 32 | classify + ratchet |
| `spawn_registry_off_chokepoint_modules` | 25 | 25 | ratchet |
| `create_session_call_sites` | 6 | 6 | hold |
| `create_session_modules` | 5 | 5 | hold |
| `duplicated_resolve_template_class` | 3 | 3 | 1 |
| `cc_codex_template_class_combined_loc` | 3231 | 3231 | reduce |
| `raw_home_path_outside_core` | 12 | 12 | 0 |
| `path_expand_home` | 2 | 2 | 0 |
| `spawn_fresh_audit_references` | 5 | 5 | classify |
| `spawn_fresh_unsanctioned` | 0 | 0 | 0 |
| `all_slices_occurrences` | 3 | 3 | classify |
| `all_slices_unsanctioned` | 0 | 0 | 0 |
| `set_effect_sites` | 118 | 118 | freeze |
| `cross_slice_set_violations` | 0 | 0 | 0 |
| `missing_cap_check_mutating_actions` | 0 | 0 | 0 |
| `kind_runtime_ordering_violations` | 0 | 0 | 0 |
| `kind_runtime_reentry_violations` | 0 | 0 | 0 |
| `cold_restart_respawn_round_trip_drift` | 0 | 0 | 0 |

## Worklist Highlights

- Oversized files: 5 files exceed 1500 LOC; 17 files exceed 1000 LOC.
- Template-class duplication: `cc_agent.ex` + `codex_agent.ex` total 3231 LOC.
- Spawn writer surface: 38 `SpawnRegistry.spawn*` call sites across 32 files;
  25 are outside the sanctioned chokepoint/boot allowlist.
- Resource seam bypasses: 12 `Home.path(` call sites outside core and 2
  `Path.expand("~")` call sites.
- PR-0 invariant-protecting counters are already target-zero:
  `spawn_fresh_unsanctioned`, `all_slices_unsanctioned`,
  `cross_slice_set_violations`, `missing_cap_check_mutating_actions`,
  `kind_runtime_ordering_violations`, `kind_runtime_reentry_violations`, and
  `cold_restart_respawn_round_trip_drift`.

## Gates

- `mix ezagent.arch.scan`
- `mix test apps/ezagent_core/test/architecture/`
- `mix ezagent.check_invariants`
- `mix ezagent.check_invariants.lifecycle`
