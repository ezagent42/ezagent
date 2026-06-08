%{
  # arch-cap-bump: PR #641 file-flavor create cascade adds the per-agent config_dir + #17-cascade instantiate block to Behavior.Workspace (1630 LOC). The block is interwoven with register_and_invoke_template's :set-effect handler (not an isolable leaf like #657's listing/resolver split), so extraction is deferred; PR-3F/G then removes orchestrator tools from >1500.
  oversized_modules_gt_1500: 3,
  oversized_modules_gt_1000: 14,
  def_count_admin_live: 69,
  def_count_cc_agent: 103,
  def_count_orchestrator_tools: 61,
  def_count_session_creator: 67,
  def_count_capability: 22,
  spawn_registry_call_sites: 38,
  spawn_registry_modules: 32,
  spawn_registry_off_chokepoint_modules: 25,
  create_session_call_sites: 6,
  create_session_modules: 5,
  duplicated_resolve_template_class: 1,
  cc_codex_template_class_combined_loc: 3231,
  # P0.5 (resource-unification): the cc_agent.ex:1460 *doc comment* (not a call)
  # now carries `# arch-allow:`, so the real outside-core Home.path() call count
  # is 8. Tightened 9→8 to keep the ratchet honest and to reconcile with the
  # uri_query.scan `home_path_in_runtime_code` baseline (one source of truth for
  # which raw Home.path calls exist — see scan_home_path_reconcile_test.exs).
  raw_home_path_outside_core: 8,
  path_expand_home: 2,
  spawn_fresh_audit_references: 5,
  spawn_fresh_unsanctioned: 0,
  all_slices_occurrences: 3,
  all_slices_unsanctioned: 0,
  set_effect_sites: 118,
  cross_slice_set_violations: 0,
  missing_cap_check_mutating_actions: 0,
  kind_runtime_ordering_violations: 0,
  kind_runtime_reentry_violations: 0,
  cold_restart_respawn_round_trip_drift: 0
}
