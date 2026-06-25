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
  # arch-cap-bump: PR #723 (cc-runtime 2.1.170 MCP-trust/bypass dialog
  #   auto-prompt scanner) pushed ezagent_domain_pty/server.ex over 1000
  #   (now 1027). Both kind.ex (1013) + server.ex (1027) are >1000; cap 1→2.
  #   Pre-existing on main (CI does not run arch.scan); surfaced by the
  #   2026-06-15 orchestrator-readiness work. Burn-down (extract the dialog
  #   scanner from server.ex into a sibling module) tracked in docs/futures/todo.md.
  #   2026-06-22 (dev-together close): #83 world-beautify briefly regrew
  #   world_live.ex to 1036 (cap bumped 3→4), then it was re-trimmed back under
  #   1000 by extracting the pure route table into `Ezagent.World.Routes` (786
  #   lines now; mirror of pg's CallerDisplay split). Cap restored to 3 — the
  #   remaining >1000 are pty/server.ex (1027) + kind.ex (1025) + im
  #   application.ex (1010), all standing burn-down targets in docs/futures/todo.md.
  #   2026-06-23 (arch-debt burn-down, Allen) RATCHET-DOWN 3 → 0: all three
  #   trimmed under 1000 by cohesive extractions — pty/server.ex (1027→892,
  #   `Ezagent.Domain.Pty.AutoPrompts` data catalog), im application.ex
  #   (1025→867, `SessionBehaviorRegistration.register/0`), kind.ex (1025→882,
  #   behavior-set accessors → `Ezagent.Kind.BehaviorSet`, slice accessors →
  #   `Ezagent.Kind.SliceAccess`). All pure refactors w/ thin delegates; public
  #   API + call sites unchanged. Cap is now a hard zero — no module may regrow >1000.
  oversized_modules_gt_1000: 0,
  def_count_cc_agent: 50,
  def_count_orchestrator_tools: 35,
  # arch-cap-bump: PR #783 split steps 5-8 into `ensure_orchestrator_and_finalize/6`
  #   so the step-4.5 orchestrator pre-store can fail-fast ahead of the readiness
  #   gate (a readability seam-split — smaller functions). 29→30.
  # ratchet-down: #154 extracted the orchestrator owner-notifier cluster → Ezagent.Orchestrator.OwnerNotifier (1071→936 LOC, 35→29 defs) 30→29
  def_count_session_creator: 29,
  # arch-cap-bump: #154 genesis collapse — the admin-entity trust root added
  #   `admin_genesis_cap/0` + `admin_genesis_granter/0` (Stage 1) and predicate-A's
  #   `granted_by_entity?/2` clauses + `admin_invariant?/2` clauses + `same_uri?/2`
  #   (Stages 1+3). These are the small, focused recognizer/minter/predicate
  #   functions for the genesis trust root; co-located in capability.ex so minter +
  #   recognizer never drift. 22→28.
  # arch-cap-bump: #154 genesis collapse — admin trust-root minter/recognizer/predicate-A fns (see block above) 22→28
  def_count_capability: 28,
  # arch-cap-bump: +3 protocol_api P0 (#82/#896) — the inbound HTTP API spawns the
  #   target agent / conversation session through the SANCTIONED SpawnRegistry
  #   chokepoint: conversation_registry.ex `resolve` (2 sites: ensure session live
  #   on durable + ephemeral paths) + openai_chat_plug.ex `join_agent` (1 site).
  #   All on-chokepoint, so off_chokepoint is unchanged. 37→40.
  # arch-cap-bump: +2 #907 — cc-headless + codex-remote flavor spawn paths route
  #   through the SANCTIONED SpawnRegistry chokepoint (one site each). 40→42.
  # RATCHET-DOWN (cc-headless PR #931, codex review): the cc-headless template
  #   REPLACED its prior `SpawnRegistry.spawn_detailed/1` call with
  #   `Ezagent.Kind.spawn/2`, and the SDK sidecar owns its Python worker via
  #   `DynamicSupervisor.start_child/2` (the sidecar allowlist, NOT this count).
  #   Net call sites 42 → 41 — cap lowered to actual (the earlier +1 bump comment
  #   was directionally wrong; corrected here so the gate stays tight).
  # arch-cap-bump: +2 #95 — Ezagent.LocalRuntime (the new owner-gated plugin
  #   chokepoint) calls SpawnRegistry.spawn + spawn_detailed (one site each). This
  #   is a TEMPORARY rise: as plugins migrate off direct SpawnRegistry onto
  #   LocalRuntime (PR-2+), those plugin sites disappear and this cap RATCHETS DOWN
  #   well below 41. 41→43.
  # RATCHET-DOWN #95 PR-2 (cc migration): the cc plugin's 6 direct SpawnRegistry
  #   call sites moved onto LocalRuntime, so the scanned count dropped 43→36. Cap
  #   lowered to actual to keep the gate tight (the LocalRuntime delegation sites
  #   in core remain; only the cc plugin-side direct calls were removed). 43→36.
  # arch-cap-bump: #95 PR-3 (codex/echo/feishu/advisor migration): the 11 direct
  #   SpawnRegistry call sites in these 4 plugins moved onto LocalRuntime, so the
  #   scanned count dropped 36→30. Cap lowered to actual. 36→30.
  # RATCHET-DOWN #99 C (LocalRuntime收口 hello/protocol_api/world): conversation_registry
  #   (2 sites) + openai_chat_plug (1 site) moved off direct SpawnRegistry onto the
  #   owner-gated `Ezagent.LocalRuntime.ensure_started`, so the scanned count dropped
  #   30→27. Cap lowered to actual. 30→27.
  spawn_registry_call_sites: 27,
  # Transport #53 Decision C (codex C-rC-P1): the orchestrator MCP transport
  # (`mcp_server.ex`) references the Session Kind it routes to through the
  # SANCTIONED SpawnRegistry chokepoint on a bridge reconnect, to rehydrate the
  # session (whose `session` spawn fn restarts the per-orchestrator
  # SessionManager) after a BEAM restart. +1 module (sanctioned, so
  # off_chokepoint is unchanged).
  # arch-cap-bump: Decision C cold-restart self-heal (cc transport → SpawnRegistry chokepoint)
  # +2 protocol_api P0 (conversation_registry + openai_chat_plug spawn)
  # arch-cap-bump: +2 #907 — cc-headless + codex-remote flavor modules spawn through
  #   the SpawnRegistry chokepoint. 35→37.
  # RATCHET-DOWN (cc-headless PR #931, codex review): modules 37 → 36 — the
  #   cc-headless template module no longer calls SpawnRegistry (uses Kind.spawn);
  #   the SDK sidecar uses DynamicSupervisor (sidecar allowlist), not this count.
  #   Cap lowered to actual; the earlier +1 bump comment was directionally wrong.
  # arch-cap-bump: +1 #95 — new module Ezagent.LocalRuntime (the owner-gated plugin
  #   chokepoint) calls SpawnRegistry. SANCTIONED (added to the chokepoint allowlist),
  #   so off_chokepoint is unchanged. Temporary: ratchets back down as plugins
  #   migrate onto LocalRuntime (PR-2+). 36→37.
  # RATCHET-DOWN #95 PR-2 (cc migration): 5 cc modules dropped their direct
  #   SpawnRegistry references (cc_orchestrator_seed, mcp_server, cc_agent/spawn,
  #   seed_cc_agent, seed_cc_sandbox), so the scanned module count fell 37→32. Cap
  #   lowered to actual. 37→32.
  # arch-cap-bump: #95 PR-3 (codex/echo/feishu/advisor migration): 6 plugin modules
  #   dropped their direct SpawnRegistry references (codex_agent, codex_remote_agent,
  #   echo_agent, echo application, feishu binding_policy, feishu sender_resolver),
  #   so the scanned module count fell 32→26. Cap lowered to actual. 32→26.
  # RATCHET-DOWN #99 C: conversation_registry + openai_chat_plug dropped their direct
  #   SpawnRegistry references (onto LocalRuntime), so the scanned module count fell
  #   26→24. Cap lowered to actual. 26→24.
  spawn_registry_modules: 24,
  # arch-cap-bump: +1 protocol_api P0 (#82/#896) — openai_chat_plug.ex activates the
  #   pre-provisioned target agent directly through SpawnRegistry (rehydrate, not
  #   create), the same off-chokepoint rehydration shape as the cc transport's
  #   cold-restart self-heal. The inbound HTTP adapter owns its own activation
  #   point; creation still flows through the template chokepoint. 25→26.
  # arch-cap-bump: +1 #907 — a cc-headless/codex-remote flavor module activates its
  #   pre-provisioned agent off-chokepoint (rehydrate, not create); creation still
  #   flows through the template chokepoint. 26→27.
  # RATCHET-DOWN #95 PR-2 (cc migration): cc's off-chokepoint SpawnRegistry modules
  #   moved onto LocalRuntime, so the scanned off-chokepoint count fell 27→22. Cap
  #   lowered to actual. 27→22.
  # arch-cap-bump: #95 PR-3 (codex/echo/feishu/advisor migration): these plugins'
  #   off-chokepoint SpawnRegistry modules moved onto LocalRuntime, so the scanned
  #   off-chokepoint count fell 22→16. Cap lowered to actual. 22→16.
  # #99 C: conversation_registry + openai_chat_plug were SANCTIONED (on-chokepoint),
  #   so removing their direct SpawnRegistry calls leaves off_chokepoint UNCHANGED.
  #   The architectural win shows in call_sites/modules above + the sanctioned
  #   allowlist shrinking (conv_reg/openai removed; local_runtime.ex stays). Stays 16.
  spawn_registry_off_chokepoint_modules: 16,
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
  # arch-cap-bump: +3 #907 — cc-headless + codex-remote template classes add thin
  #   CredentialAdapter delegations (auth_failure_signals/secret_relpaths/credential_*
  #   → base cc/codex agent), intentionally duplicating the delegating bodies across
  #   flavor files. 29→32.
  # arch-cap-bump: cc-headless SDK behavior mirrors curl sync-result helper shape pending shared helper extraction (+8)
  cross_file_duplicate_fn_groups: 40,
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
  # arch-cap-bump: +2 #907 — cc_headless_agent + codex_remote_agent flavor template
  #   classes (thin CredentialAdapter delegations). 1682→1684.
  # arch-cap-bump: cc-headless SDK sidecar spawn/respawn replaces the stub runtime (+2 net)
  cc_codex_template_class_combined_loc: 1684,
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
  #
  # World PR-2 (plugin-resource SPEC §4.4) migrated `Ezagent.World.LayoutManager`
  # OFF raw `Home.path("world/layouts")` ONTO the `resource://<ws>/world-layouts`
  # seam (`Ezagent.Resource.FsResolver.resolve/2`). The runtime LayoutManager now
  # has NO `Home.path` call; the one-shot `mix ezagent.world.migrate_layouts`
  # operator task's `Home.path` reads live in `ezagent_core` (excluded from this
  # outside-core metric by construction, like the `Mix.Tasks.Ezagent.Home.*`
  # tasks) and are exact-anchored in `HomePathExceptions`. RATCHET-DOWN 2 → 1:
  # the codex app-server SUN_LEN socket (`codex_agent.ex`) is the sole remaining
  # genuinely un-migratable outside-core caller. (Lowering a cap needs no
  # arch-cap-bump annotation; only raising does.)
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
  # System-principal elimination (agent-internal, 2026-06-19) RATCHET-DOWN 3 → 2:
  # the deleted `system://agent-internal` Catalog entry contained the sanctioned
  # `ctx[:all_slices][:api_keys]` ApiKeys-flip comment; its `:all_slices` mention
  # is gone with the entry, so the occurrence count drops and the cap follows.
  all_slices_occurrences: 2,
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
  # arch-cap-bump: cc-headless SDK sync_result state slice persists conversation/error/token fields (+5)
  # arch-cap-bump: #956 hello Surface.handle_set_shell persists the generated site shell — {:set, :shell} + {:set, :shell_css} (within the surface slice, cross-slice stays 0); net +1
  set_effect_sites: 127,
  cross_slice_set_violations: 0,
  missing_cap_check_mutating_actions: 0,
  kind_runtime_ordering_violations: 0,
  kind_runtime_reentry_violations: 0,
  no_flavor_refs_in_core: 0,
  cold_restart_respawn_round_trip_drift: 0,
  # Subtask B (2026-06-25) — raw `Port.open({:spawn_executable, …})` is forbidden;
  # the sanctioned OS-process spawn exit is `Ezagent.Runtime.OsProcess` (erlexec
  # group-kill subtree reaping). All 4 sidecars (cc SdkSidecar, codex AppServer +
  # BridgeSidecar, feishu WsClient) are migrated → hard zero, no allowlist.
  raw_port_spawn_executable: 0,
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
  # arch-cap-bump: #55 doc-coverage burn-down 441→392
  # arch-cap-bump: RF-4 adds optional roles/0 plugin callback; its only def is the
  #   use-macro default (no @doc target until the first @impl impl lands in RF-9)
  undocumented_public_defs: 393,
  # dynamic_public_def_heads — `def unquote(name)(...)` heads whose function name
  #   is only known at macro-expansion, so they cannot become a documented
  #   {name, arity} entry. ENFORCED at 0 (the tree has none): adding any new
  #   dynamic public head fails the gate unless this baseline is deliberately
  #   raised with a `# arch-cap-bump:` rationale (codex 2026-06-14).
  dynamic_public_def_heads: 0
}
