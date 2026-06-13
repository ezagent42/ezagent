%{
  oversized_modules_gt_1500: 0,
  # #25 Phase-3 burn-down (ratchets DOWN toward 0):
  #   PR-3N: 9 → 8 (extracted ExternalMirror.Codec, external_mirror.ex 1004 → 936)
  #   PR-3O: 8 → 7 (extracted ExternalMirrorWorker.SendKey, worker 1010 → 963)
  #   PR-3P: 7 → 6 (extracted AgentModuleResolver, application.ex 1117 → 985)
  #   PR-3Q: 6 → 5 (extracted Admin.EventFormat + Admin.OrchestratorRestart,
  #          admin_live.ex 1170 → 974)
  #   PR-3R: 5 → 4 (extracted Chat.Membership + Chat.Legends + Chat.ConfigActions,
  #          chat.ex 1445 → 988)
  #   PR-3S: 4 → 3 (extracted Orchestrator.Tools.MemberTemplate, tools.ex 1498 → 938)
  #   PR-3T: 3 → 2 (extracted CcAgent.Spawn, cc_agent.ex 1340 → 917)
  #   PR-3U: 2 → 1 (extracted Workspace.Listing, workspace.ex facade 1055 → 938)
  # Final remaining entrant: `Ezagent.Behavior.Workspace` (1498) — the
  # #685 CapBAC membership Behavior, the last burn-down target (PR-3V).
  #   PR-3V: 1 → 0 (extracted Behavior.Workspace.AgentCreate, behavior/workspace.ex 1498 → 786) — CAMPAIGN COMPLETE
  #   PR-6 (im/session/agent decomposition §3.5): 0 → 1 — the
  #   `nil_capture_behavior_set/1` accessor (the soft sibling of
  #   `requires_explicit_behavior_set?/1` enabling the curl-flavor fold without
  #   an agent backfill) pushed ezagent/kind.ex 999 → 1013. Its natural home is
  #   alongside the behavior-set accessors it mirrors. Burn-down target.
  # arch-cap-bump: PR-6 nil_capture_behavior_set/1 → kind.ex 999→1013
  oversized_modules_gt_1000: 1,
  def_count_admin_live: 46,
  def_count_cc_agent: 50,
  def_count_orchestrator_tools: 35,
  def_count_session_creator: 29,
  def_count_capability: 22,
  spawn_registry_call_sites: 37,
  # Transport #53 Decision C (codex C-rC-P1): the orchestrator MCP transport
  # (`mcp_server.ex`) references the Session Kind it routes to through the
  # SANCTIONED SpawnRegistry chokepoint on a bridge reconnect, to rehydrate the
  # session (whose `session` spawn fn restarts the per-orchestrator
  # SessionManager) after a BEAM restart. +1 module (sanctioned, so
  # off_chokepoint is unchanged).
  spawn_registry_modules: 33, # arch-cap-bump: Decision C cold-restart self-heal (cc transport → SpawnRegistry chokepoint)
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
  # PR-2 config-evolve transiently bumped this to 30 when it ported
  # CascadeRepoint's put_user_layer/put_resolution into Behavior.ConfigEvolve
  # while cascade_repoint.ex still held the originals. PR-4 deleted
  # cascade_repoint.ex (the functions now live ONLY on ConfigEvolve), so the
  # transient duplicate is gone — ratcheted back to 29.
  # chat→session (2026-06-12) +1 = 30: `Ezagent.Session.SliceMigration` is a new
  # one-shot snapshot migration that DELIBERATELY mirrors the sanctioned
  # `Ezagent.Kind.KindBaseBackfill` migration shape (it shares the byte-identical
  # `session_rows/0` row-selector — `KindSnapshot.list_all |> filter kind_type ==
  # "session"`). Two standalone one-shot migrations naturally share that 1-line
  # row selector; this is a structural mirror of the approved pattern, not a
  # copy-paste fork of business logic.
  # arch-cap-bump: chat→session SliceMigration mirrors KindBaseBackfill session_rows/0
  # PR-6+7 (curl-as-flavor, forward-only) RATCHET-DOWN 31 → 30: the legacy
  # `:curl_agent`-axis companion `Ezagent.Behavior.CurlAgentLegacyConfig` (whose
  # reset/configure bodies mirrored `Ezagent.Behavior.CurlAgent`) is DELETED with
  # the standalone curl Kind. No rollback window (Allen) — the unified Entity.Agent
  # is the sole curl path, so the duplicate group is gone.
  # PR-6+7 RATCHET-DOWN 31 → 29: (a) the legacy `CurlAgentLegacyConfig` mirror is
  # DELETED (−1); (b) the new `mix ezagent.curl.migrate` task adds NO fork — its
  # Repo-only boot is the shared `Ezagent.Migration.RepoOnly.run/1` (extracted from
  # `ezagent.session.migrate_slice`, eliminating that copy too) and its `run/1` is
  # the `use Mix.Task` callback, now correctly exempted via `@dup_callback_owners`
  # (which also retires a pre-existing Mix-task `run/1` fork the gap had been
  # counting, −1 more). The chat→session `SliceMigration` mirror remains.
  # arch-cap: PR-6+7 curl fold + Mix.Task run/1 callback exemption
  cross_file_duplicate_fn_groups: 29,
  # FF-4 (cleanup-1): distinct non-agent_bridge/non-test lib files still
  # referencing a `/cc_socket` deprecation-shim module
  # (EzagentPluginCc.{BridgeRegistry,Socket,Channel,TokenStore}). Cleanup-3
  # (2026-06-08) migrated the three liveview callers to
  # Ezagent.AgentBridge.Registry, deleted all four shim modules, and removed
  # the `/cc_socket` endpoint mount — ratcheting this to 0. This cap MUST
  # stay at 0: the shim layer is gone and no lib file may reintroduce it.
  cc_bridge_shim_callers: 0,
  # #719 §5.B(c) re-provisions the source agent credential across its own respawn
  # (durable-credential bug fix). cc_agent.ex 917→930 (+13 net: the
  # `maybe_reprovision_source_from_respawn_data/2` chokepoint + the
  # `credential_source` producer in `template_data_extra/1`). codex 752 unchanged.
  # Genuine product logic, codex-reviewed (HIGH+MEDIUM addressed); not extractable
  # shared duplication. 1669 → 1682.
  # arch-cap-bump: #719 §5.B(c) source-respawn credential reprovision (+13 cc_agent)
  cc_codex_template_class_combined_loc: 1682,
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
  # PR-2 config-evolve adds the `{:set, :applied, …}` applied-turn idempotency
  # marker effect in Behavior.ConfigEvolve.handle_apply_config_delta (the agent's
  # own :config_evolve slice).
  # PR-6+7 (curl-as-flavor, forward-only) RATCHET-DOWN 135 → 121: both legacy
  # curl shims are DELETED with the standalone curl Kind (no rollback window —
  # Allen). `Ezagent.Behavior.CurlAgentLegacyReceive` (−7 `{:set,
  # :conversation/:last_error/:last_tokens}` sites) and
  # `Ezagent.Behavior.CurlAgentLegacyConfig` (−7 `{:set}` sites across
  # handle_configure + handle_reset_conversation) are gone — a measured −14 (the
  # prior baseline comment mis-stated LegacyConfig as −8; the scanned regex
  # counts 7). The PR-2 applied-turn marker remains.
  # arch-cap-bump: PR-2 applied-turn marker; curl legacy shims deleted (−14)
  set_effect_sites: 121,
  cross_slice_set_violations: 0,
  missing_cap_check_mutating_actions: 0,
  kind_runtime_ordering_violations: 0,
  kind_runtime_reentry_violations: 0,
  cold_restart_respawn_round_trip_drift: 0,
  # Documentation-coverage gate (2026-06-13, Allen) — RATCHET-DOWN counters.
  # Backed by `Mix.Tasks.Ezagent.Doc.Scan`; enforced by
  # test/architecture/doc_coverage_test.exs. Calibrated GREEN at the CURRENT
  # main count (no day-one red build); the comment-improvement campaign lowers
  # these. See docs/notes/doc-coverage-audit.md §"How to ratchet DOWN".
  #
  # undocumented_public_modules — defmodules under apps/*/lib (sans test files +
  #   the scanner) with NO @moduledoc (a `@moduledoc false` COUNTS as
  #   documented). Ratcheted to 0 (2026-06-14): the 6 former offenders (Repo /
  #   Endpoint / Router / 3 socialware Ecto schemas) now carry @moduledoc.
  undocumented_public_modules: 0,
  # undocumented_public_defs — distinct {name, arity} public API forms
  #   (def + defmacro + defdelegate + defguard; NOT their defp/defmacrop/
  #   defguardp siblings) with NO @doc (a `@doc false` COUNTS as documented),
  #   EXCLUDING @impl callbacks + the {child_spec,1}/{start_link,0|1}
  #   boilerplate allowlist. defdelegate/defmacro/defguard are in the
  #   denominator because public API here is not limited to raw `def` — a
  #   facade's delegates + the Kind/Behavior DSL macros are public surface too
  #   (codex 2026-06-14; def-only undercounted by 52). Also counts STATICALLY-
  #   named public defs emitted from quote blocks (macro-generated public API,
  #   e.g. __using__-injected defaults; +22 over def+macro+delegate+guard) and
  #   ignores @impl false (only @impl true / @impl Behaviour exempt). Pending
  #   @doc is preserved only across def-adjacent metadata (@spec/@dialyzer/
  #   @deprecated); doc-consuming attrs (@callback/@type/@typedoc/…) clear it, so
  #   a callback's @doc can't leak onto a later def (codex 2026-06-14; +4 real
  #   false-negatives caught). Same-name defs across compile-time branches/quotes
  #   merge conservatively — documented only if EVERY branch is (+1 caught).
  undocumented_public_defs: 511,
  # dynamic_public_def_heads — `def unquote(name)(...)` heads whose function name
  #   is only known at macro-expansion, so they cannot become a documented
  #   {name, arity} entry. ENFORCED at 0 (the tree has none): adding any new
  #   dynamic public head fails the gate unless this baseline is deliberately
  #   raised with a `# arch-cap-bump:` rationale (codex 2026-06-14).
  dynamic_public_def_heads: 0
}
