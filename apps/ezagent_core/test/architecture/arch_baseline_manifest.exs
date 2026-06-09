%{
  oversized_modules_gt_1500: 0,
  # #25 Phase-3 burn-down (ratchets DOWN toward 0):
  #   PR-3N: 9 → 8 (extracted ExternalMirror.Codec, external_mirror.ex 1004 → 936)
  #   PR-3O: 8 → 7 (extracted ExternalMirrorWorker.SendKey, worker 1010 → 963)
  # Remaining entrants include `Ezagent.Workspace` (1055, bloated by the
  # #685 CapBAC security fix, SPEC §7) — a later burn-down target.
  oversized_modules_gt_1000: 7,
  def_count_admin_live: 69,
  def_count_cc_agent: 76,
  def_count_orchestrator_tools: 61,
  def_count_session_creator: 67,
  def_count_capability: 22,
  spawn_registry_call_sites: 38,
  spawn_registry_modules: 32,
  spawn_registry_off_chokepoint_modules: 25,
  create_session_call_sites: 6,
  create_session_modules: 5,
  duplicated_resolve_template_class: 1,
  # FF-1 (cleanup-1): groups of ≥2 lib files sharing a byte-identical
  # (whitespace-normalized, ≥120-char) function. Functions are extracted per
  # ENCLOSING module with all clauses of a `{name, arity}` AGGREGATED before the
  # length threshold (codex r2 MEDIUM — module-scoped markers + multi-clause
  # forks), and a callback `{name, arity}` is exempt ONLY when its enclosing
  # module declares the owning behaviour by exact last-segment match (codex r1/r2
  # — not name-only, not substring). Cleanup-1 baseline = 32; Cleanup-2 deduped
  # the audit-confirmed pure forks — `check_agent_uri/1` (5 plugin template
  # files → one shared `Ezagent.Kind.Template.check_agent_uri/1`),
  # `content_field/2` (cc/codex/curl templates → the same core helper),
  # `reject_stale_config_dir_data_key!/1` (cc `CcAgent` + `SpawnPlan` → one
  # definition on `CcAgent`), and the bridge `normalize_attachments` /
  # `normalize_attachment_keys` (cc + codex `BridgeAdapter` → shared
  # `Ezagent.AgentBridge.AttachmentNormalizer`). The cc/codex
  # `handle_client_event/3` + `dispatch_reply` were INTENTIONALLY kept separate
  # (cc carries the Invariant-#9 empty-`session_uris` rejection + three-bucket
  # ACK + telemetry that codex does not). Measured 2026-06-08 = 29.
  # Generalizes `duplicated_resolve_template_class`.
  cross_file_duplicate_fn_groups: 29,
  # FF-4 (cleanup-1): distinct non-agent_bridge/non-test lib files still
  # referencing a `/cc_socket` deprecation-shim module
  # (EzagentPluginCc.{BridgeRegistry,Socket,Channel,TokenStore}). Cleanup-3
  # (2026-06-08) migrated the three liveview callers to
  # Ezagent.AgentBridge.Registry, deleted all four shim modules, and removed
  # the `/cc_socket` endpoint mount — ratcheting this to 0. This cap MUST
  # stay at 0: the shim layer is gone and no lib file may reintroduce it.
  cc_bridge_shim_callers: 0,
  cc_codex_template_class_combined_loc: 2141,
  # P3 (resource-unification, SPEC §10 OI-3): the population-3 outside-core
  # callers (agent_bridge token registry, identity smtp_config, feishu app-cred +
  # inbox + plugin config, python log) migrated behind the `UriQuery` seam
  # (`system://<type>` via `Ezagent.System.FsResolver`), removing their raw
  # `Home.path(`/`profile_dir(` calls. Lowered 8→1: the ONLY remaining
  # outside-core `Home.path(` call is the codex app-server socket
  # (`codex_agent.ex:661`) — the SUN_LEN short-path OS handle that stays on
  # sanctioned raw `Home` (Decision D2), and is an exact-anchor exception in
  # `HomePathExceptions`. Reconciles with the uri_query.scan
  # `home_path_in_runtime_code` baseline (see scan_home_path_reconcile_test.exs).
  raw_home_path_outside_core: 1,
  # Cleanup-1 FF-5 fix: `mcp_config_writer.ex` no longer hardcodes
  # `Path.expand("~/.ezagent")` — its default dir now resolves through the
  # post-Resource-unification `system://` seam (Ezagent.System.FsResolver). The
  # only remaining non-exempt `Path.expand("~")` is the `~/.claude/.credentials`
  # path printed in the `ezagent.demo.seed_cc_sandbox` operator help text.
  # Lowered 2→1.
  path_expand_home: 1,
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
