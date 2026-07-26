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
  # Final remaining entrant: `Ezagent.ActionSet.Workspace` (1498) — the
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
  # - arch-cap-bump: PR #1168 — world `conversation_actions.ex` grew past 1000 with
  #   the concierge chat + publish-as-template + session-open + hello-orchestrator
  #   ensure surfaces. 0→1. Splitting it into a sibling ops module is a tracked
  #   follow-up (the file is cohesive world-console dispatch handlers).
  # - arch-cap-bump: #161 A1 — `behavior/session.ex` was 998 on main (ONE line
  #   under the gate); A1.3 wiring the member-cap `reconcile_after_load/2` seed
  #   into `activate/2` tipped it to 1018. NOT cleanly extractable (it is inline
  #   Lifecycle-callback wiring), so ratchet 1→2. (membership.ex — the OTHER A1
  #   grower, 912→1121 — was instead trimmed back under 1000 by extracting the
  #   at-join member-cap cluster into the sibling `Session.MemberCap`, so it does
  #   NOT count here.) session.ex burn-down (split the activate reconcile block)
  #   is a tracked follow-up in docs/futures/todo.md.
  # - arch-cap-bump: #161 C (admission gate) — `behavior/session/membership.ex`
  #   was 966 on main (A1 had trimmed it under 1000 by extracting the at-join
  #   member-cap cluster into `Session.MemberCap`). C.1/C.2/C.3 added the ~260-line
  #   owner-approval admission cluster (`admission_pending?`, the
  #   `caller_controls_member?`/`{:spawned_by}` exemption chain, `record_pending_admission`,
  #   `notify_pending_managers`, and the public `approve_/deny_/withdraw_admission`
  #   handlers) → 1262. Unlike the MemberCap leaf, the cluster is MUTUALLY RECURSIVE
  #   with the join flow it guards (`do_join` calls `admission_pending?`/
  #   `record_pending_admission`; `approve_admission` calls back `do_join`), so its
  #   natural home is next to `do_join` — a `Session.Admission` split would be a
  #   bidirectional-coupling extraction, not a clean leaf. Ratchet 2→3; the split
  #   is a tracked burn-down follow-up in docs/futures/todo.md (`same_entity?` is
  #   cluster-local; only session.ex's 3 admission handlers + the registration list
  #   would repoint).
  # - arch-cap-bump: 3→4 CapBAC transient-identity-read fix — `kind/runtime.ex`
  #   was 991 on main; the step-5.5 chokepoint gained a bounded `try/rescue` that
  #   converts a TRANSIENT caller identity-read failure (raised
  #   `Ezagent.Kind.IdentityReadError`) into the distinct, caller-retryable
  #   `{:error, :identity_read_unavailable}` instead of crashing the TARGET Kind
  #   or silently denying → 1011. Like the #161 admission cluster, this is inline
  #   chokepoint control flow (mutually bound to the authz telemetry + return
  #   shape), NOT a cleanly-extractable leaf. Burn-down (split authz_check out of
  #   runtime.ex) is a tracked follow-up in docs/futures/todo.md.
  # arch-cap-bump: 4→5 #1451 G5 error mechanism — `ezagent_plugin_world/world_live.ex`
  #   crossed 1000 (→1019) with the `notification.send`/`error_fix_request` handler
  #   (Layer-2 "notify founder" button) + its founder-resolution helpers. Inline
  #   LiveView event handler, mutually bound to socket assigns / dispatch flow, not
  #   a cleanly-extractable leaf; G5 renderer owns the burn-down follow-up.
  # arch-cap-bump: cap-signing re-architecture — the born-signed + strict-verify +
  #   `sync_live` changes touch already-oversized modules without cleanly
  #   extracting them, and latest main measured modules above 1000 the manifest had
  #   not yet recorded. Record the live baseline rather than attributing unrelated
  #   module growth to this feature; the exact count is gate-measured.
  # arch-cap-bump: rebasing Plan C's audited atomic launch boundary onto the
  #   cap-signing/G5 main baseline leaves seven pre-existing oversized modules.
  # arch-cap-bump: +1 #1455/#1513 — pty/server.ex cmd_env secret-redaction
  #   security fix. The +36-line redaction chokepoint (format_status/2 GenServer
  #   callback + redact_cmd_env/1 + scrub_state/1) scrubs vendor API keys
  #   (ANTHROPIC_AUTH_TOKEN, EZAGENT_AGENT_TOKEN, …) from OTP crash reports so
  #   they never reach logs. It pushed ezagent_domain_pty/server.ex from exactly
  #   1000 → 1036 LOC, crossing the >1000 threshold. Intentional, security-
  #   justified growth (not bloat); burn-down = extract the redaction helpers
  #   into a sibling module. 7→8 (on the #1445 seven-module baseline: the
  #   redaction adds server.ex as the eighth oversized module).
  # arch-cap-bump: +1 actor-extraction C0 (spec 2026-07-23 §2.2) — the public
  #   actor read surface (read/3, read_classified/2, read_durable/3 +
  #   read_durable_many/3, resolve_action_subject/2, alive?/1, self?/1,
  #   list_instances/0) MUST live on `Ezagent.Kind` per §2.2, and kind.ex sat at
  #   exactly 995 LOC (zero headroom), so the additive surface pushed it 995 →
  #   ~1203, crossing >1000 as the ninth oversized module. This is ACCEPTED
  #   documented debt, NOT an automatic disappearance: the LOC counter scans
  #   `apps/*/lib/**/*.ex` globally, so C5 relocating kind.ex into `ezagent_actor`
  #   (still under `apps/*/lib`) does NOT drop the count, and C7's small
  #   `get_slice` delegate removal does not get kind.ex back under 1000. The real
  #   burn-down is a module split (extract the §2.2 read surface into a sibling
  #   `Ezagent.Kind.Read` once callers have migrated), tracked for a later chunk.
  #   8→9.
  # arch-cap-bump: +1 V5 pid-closure A1a/A1b — the acquisition-primitive
  #   census (report-only Track-A scanner section: `acquisition_sites/0`,
  #   the ban-set table, the site detector, the ledger markdown renderer +
  #   their doc prose) grew actor_boundary_scanner.ex 838 → ~1150 LOC,
  #   crossing >1000 as the tenth oversized module. Intentional, gate-
  #   justified growth (the census is the V5 anti-drift instrument); the
  #   burn-down is extracting the V5 census section into a sibling
  #   `Ezagent.AcquisitionScanner` module once A1b-rest templating lands.
  #   9→10.
  oversized_modules_gt_1000: 10,
  # arch-cap-bump: +1 #160 — cc_agent Template Class adds the `credential_status/2`
  #   enum adapter (the CredentialAdapter optional callback that maps the cc probe's
  #   File.exists?/expiresAt result into the normalized status enum for the
  #   credential-status view). One new public def; cap-gated read (owner/ws-admin
  #   only via read_credential_status/2). 50→51.
  # arch-cap-bump: +1 #1201 A② — cc_agent adds the `host_login_dir/0`
  #   CredentialAdapter optional callback (installer host-login inheritance for
  #   socialware-materialized agents). One-line delegation to the SHARED
  #   `Ezagent.Credential.HomeRuntime.host_login_dir/2` derivation (env override
  #   else `~/.claude`), consumed only via
  #   `CredentialAdapter.host_login_source_dir/1`. 51→52.
  # arch-cap-bump: +2 cc DeepSeek backend — cc_agent.ex adds two SHARED public
  #   defs the deepseek provider shim (`CcDeepseekAgent`) reuses so a distinct
  #   flavor stores its own launch flavor while the spawn + validation logic stays
  #   single-sourced (NOT forked into the shim): `instantiate_for_flavor/4`
  #   (flavor-parameterized instantiate body) + `validate_after_class/1` (the
  #   class-agnostic validation checks). 52→54.
  def_count_cc_agent: 54,
  def_count_orchestrator_tools: 35,
  # arch-cap-bump: PR #783 split steps 5-8 into `ensure_orchestrator_and_finalize/6`
  #   so the step-4.5 orchestrator pre-store can fail-fast ahead of the readiness
  #   gate (a readability seam-split — smaller functions). 29→30.
  # ratchet-down: #154 extracted the orchestrator owner-notifier cluster → Ezagent.Orchestrator.OwnerNotifier (1071→936 LOC, 35→29 defs) 30→29
  # arch-cap-bump: +5 chain C — `record_unfilled_role_slots/2` +
  #   `unfilled_agent_role_slots/1` (durable read model the UI renders) +
  #   `reason_tag/1` (stable atom for the UI to switch on — THREE clause heads,
  #   each counted) + the updated `run_install_loudly/1` with the partial-success
  #   arm. These give the post-create socialware-install transaction a structured
  #   summary and a user-facing durable record, separate from the install
  #   imperative. Chain C was authored against base bf5e717b (28 heads → 33); on
  #   rebase onto #1294's create-decouple (which added one net head to this module,
  #   28→29 absorbing the prior 29-cap headroom), the stack measures 29→34. 29→34.
  def_count_session_creator: 34,
  # arch-cap-bump: #154 genesis collapse — the admin-entity trust root added
  #   `admin_genesis_cap/0` + `admin_genesis_granter/0` (Stage 1) and predicate-A's
  #   `granted_by_entity?/2` clauses + `admin_invariant?/2` clauses + `same_uri?/2`
  #   (Stages 1+3). These are the small, focused recognizer/minter/predicate
  #   functions for the genesis trust root; co-located in capability.ex so minter +
  #   recognizer never drift. 22→28.
  # arch-cap-bump: #154 genesis collapse — admin trust-root minter/recognizer/predicate-A fns (see block above) 22→28
  def_count_capability: 28,
  # Phase-4 CBAC signing fail-loud invariant. The bounded verification ingress
  # chain must never rescue missing signing material or crypto failures into a
  # normal `false` signature denial.
  cap_verify_rescue_to_false: 0,
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
  # RATCHET-DOWN (2026-07 batch-1 AST conversion) 27→21: converted from the
  #   per-line `SpawnRegistry.spawn(` grep to an AST remote-call matcher
  #   (alias-resolving + parens-only). grep over-counted 5 NON-CALL mentions the
  #   AST correctly drops — all moduledoc/comment lines that happen to contain
  #   `spawn(`: spawn_registry.ex:21, entity/agent.ex:23 + :29 (both moduledoc),
  #   im application.ex:211 (a commented-out `# …SpawnRegistry.spawn(…)`),
  #   cc_agent.ex:24 (moduledoc). The AST hit-set is a strict subset of the grep
  #   hit-set (no real call dropped), so this only tightens the ratchet.
  spawn_registry_call_sites: 21,
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
  # RATCHET-DOWN (2026-07 batch-1 AST conversion) 24→20: same AST conversion. The
  #   3 files grep counted with only a moduledoc/comment `spawn(` mention (no real
  #   call) — spawn_registry.ex, im application.ex, cc_agent.ex — drop out. Tighter.
  spawn_registry_modules: 20,
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
  # RATCHET-DOWN (2026-07 batch-1 AST conversion) 16→14: same AST conversion. Of
  #   the 3 doc-only modules dropped, 2 were sanctioned (no effect here) and 1 —
  #   cc_agent.ex, an off-chokepoint plugin file with only a moduledoc `spawn(`
  #   mention — leaves the off-chokepoint set (−1 vs grep-current 15). Tighter.
  spawn_registry_off_chokepoint_modules: 14,
  # RATCHET-DOWN (2026-07 batch-1 AST conversion) 6→5: converted the
  #   `.create_session(` grep to an AST remote-call matcher (parens-only, so a
  #   `&Ezagent.Workspace.create_session/3` function CAPTURE — which grep never
  #   matched either — is not a call site). The cap sat 1 above grep-current (5);
  #   AST measures the true call-site count (5) so the loose ratchet is tightened.
  # PR-5 (market surface): market_actions.ex reuses the owner-gated
  # `ConversationActions.create_session/6` facade for install — one new call site
  # in one new module (a sanctioned facade reuse, not a raw spawn / bypass).
  create_session_call_sites: 6,
  create_session_modules: 6,
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
  # `:curl_agent`-axis companion `Ezagent.ActionSet.CurlAgentLegacyConfig` (whose
  # reset/configure bodies mirrored `Ezagent.ActionSet.CurlAgent`) is DELETED with
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
  # arch-cap-bump: +8 retire-customer SPEC §5.3/§5.4 — the external surface
  #   ingress (ExternalFeedController/Socket) now takes the SAME anon-user
  #   lifecycle as the chat surface (mint/reuse anon → join → cookie → token),
  #   so its helpers (resolve_caller/resolve_anonymous/reuse_or_mint/mint_fresh/
  #   join_anon/render_spa/read_valid_cookie/put_anon_cookie/show + Socket.connect)
  #   are byte-identical to ChatFeedController/ChatFeedSocket. SPEC §5.4 chose two
  #   PARALLEL surfaces and §9 names touching ChatFeed* a non-goal, so extracting a
  #   shared EzagentWeb.Socialware.AnonIngress is a deferred follow-up (touches
  # - 2026-06-28 socialware P2: AnonAdmission + AnonIngress collapsed the
  #   duplicated anon lifecycle in chat/external feed controllers. 48→42.
  # - arch-cap-bump: PR #1168 (hello orchestrator + website work) — +1 duplicate
  #   group from the world console conversation/publish surface. 42→43.
  # - arch-cap-bump: hello B'-direct substrate migration (#1208) — +1 duplicate
  #   group: plugin `migrate.ex` `agent_recipe/1` mirrors the domain-PRIVATE
  #   `DefinitionAgents.agent_recipe/1` (2-step ETS→durable recipe lookup). The
  #   plugin cannot call a private domain helper under the plugin-only boundary,
  #   so the fork is forced; a future domain-side public helper would collapse
  #   it back. 43→44.
  # - seed-loader dedup ratchet (0709): the kanban↔hello thin-loader
  #   isomorphism is now extracted into the shared
  #   `Ezagent.Socialware.ShippedManifest` loader (both Demo modules are thin
  #   delegating shells), so the duplication is gone by construction. The
  #   earlier "+2 kanban makes 46" attribution never actually measured: the
  #   loader bodies aggregate to 118 normalized chars, under the scanner's
  #   120-char floor — measured count was 42 both before and after the
  #   extraction, so the cap ratchets to the real value. 46→42. NOTE: when
  #   dealscout (#1264) lands, its Demo.Crawler copy switches to
  #   ShippedManifest in S2 — re-measure then.
  # ratchet 43→42 #1476 — the #1472 cap-bump duplicate DISSOLVED. It was the
  #   read-side ctx builder duplicated across `ezagent_plugin_kanban/world_actions.ex`
  #   (`read_ctx/1`) and `ezagent_plugin_world/conversation_actions.ex`
  #   (`session_view_ctx/1`), both bodies calling
  #   `caller_caps: Ezagent.World.PresenterCaps.load(socket)`. #1476 removed the
  #   plugin→UI-host coupling by having world INJECT the presenter caps into a
  #   `:presenter_caps` socket assign; kanban's `read_ctx/1` now reads
  #   `caller_caps: presenter_caps(socket)` while world's `session_view_ctx/1`
  #   still calls `PresenterCaps.load(socket)` — so the two bodies DIVERGE and the
  #   duplicate group is gone. Back to main's pre-extraction value.
  # arch-cap-bump: +3 V5 pid-closure B1 (use side) — the producer enumerator
  #   (`ezagent_core/lib/ezagent/producer_enumerator.ex`) is deliberately
  #   SELF-CONTAINED (NOT an extension of `Ezagent.ActorBoundaryScanner` —
  #   the obtain-side track owns that file, so the B1 task could not share
  #   it): its AST helpers (`collect_aliases/1`, `local_fun_names/1`,
  #   `fn_name/1`, `resolve_ast`+`resolve`, `literal_attributes/1`, …) are
  #   documented own-copies of the scanner's, producing 3 cross-file
  #   duplicate-body groups. Burn-down = fold the enumerator into the
  #   scanner (or extract a shared `Ezagent.AstIdioms` helper) once the
  #   parallel-track shared-file constraint lifts. 42→45.
  cross_file_duplicate_fn_groups: 45,
  # FF-4 (cleanup-1): distinct non-agent_bridge/non-test lib files still
  # referencing a `/cc_socket` deprecation-shim module
  # (EzagentPluginCc.{BridgeRegistry,Socket,Channel,TokenStore}). Cleanup-3
  # (2026-06-08) migrated the three liveview callers to
  # Ezagent.AgentBridge.Registry, deleted all four shim modules, and removed
  # the `/cc_socket` endpoint mount — ratcheting this to 0. This cap MUST
  # stay at 0: the shim layer is gone and no lib file may reintroduce it.
  cc_bridge_shim_callers: 0,
  # domain-only-Kinds gate: plugin-app files declaring a CONCRETE Kind
  # (`@behaviour Ezagent.Kind` exactly, NOT `Ezagent.Kind.Template`) minus the
  # sanctioned allowlist in ezagent.arch.scan (`@plugin_defined_kind_allowlist`).
  # Kinds are a domain concern; plugins compose via Template/Behavior/View. This
  # is TARGET-ZERO: the allowlist (currently just hello_builder, pending its
  # socialware promotion; echo/np already retired) is a ratchet that must reach
  # empty, and any NEW plugin Kind must fail this gate.
  plugin_defined_kinds: 0,
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
  # arch-cap-bump: +37 #160 credential-status view — cc_agent + codex_agent Template
  #   Classes add their `credential_status/2` enum adapter (cc: File.exists?/expiresAt →
  #   enum; codex: File.read/present-absent → enum) + the read-only, cap-gated probe
  #   docs (owner/ws-admin only via read_credential_status/2). Measured combined LOC
  #   1684→1721 (+37); genuine per-flavor probe logic in the plugin-isolation seam,
  #   not extractable duplication.
  # arch-cap-bump: +24 #1201 A② installer host-login inheritance — cc_agent +
  #   codex_agent Template Classes add the `host_login_dir/0` CredentialAdapter
  #   optional callback. Both are ONE-LINE delegations (env var + default dirname)
  #   to the SHARED `Ezagent.Credential.HomeRuntime.host_login_dir/2` body — the
  #   derivation logic itself is NOT duplicated per flavor; the +24 is the two
  #   @impl defs + their doc comments. Measured 1721→1745.
  # arch-cap-bump: +21 #1294 B (cc PTY premature start) — cc_agent Template Class
  #   adds the `config_dir_materialized?/2` guard clause in `ensure_subprocess_alive`
  #   + its private helper (delegating to the SHARED
  #   `HomeRuntime.config_dir_launchable?/2`) so the cold-restart self-heal hook
  #   declines to launch the PTY against an un-materialized config home (chain B /
  #   #1096). codex_agent unchanged; the +21 is the guard + forensic doc comments,
  #   not extractable duplication. Measured 1745→1766.
  # arch-cap-bump: +20 cc DeepSeek backend — cc_agent.ex adds the two SHARED public
  #   defs the deepseek provider shim reuses (`instantiate_for_flavor/4` +
  #   `validate_after_class/1`, see def_count_cc_agent bump) so the deepseek env +
  #   flavor wiring is single-sourced, not forked. codex_agent unchanged. The
  #   provider logic itself lives in the sibling `Ezagent.PluginCc.Provider` +
  #   thin `CcDeepseekAgent`/`CcHeadlessDeepseekAgent` shims (separate files, not
  #   counted here). Measured 1766→1786.
  # arch-cap-bump: custom-backend templates now forward the Plan C launch receipt
  #   option through their shared CC instantiate boundary.
  cc_codex_template_class_combined_loc: 1787,
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
  # Allen). `Ezagent.ActionSet.CurlAgentLegacyReceive` (−7 `{:set,
  # :conversation/:last_error/:last_tokens}` sites) and
  # `Ezagent.ActionSet.CurlAgentLegacyConfig` (−7 `{:set}` sites across
  # handle_configure + handle_reset_conversation) are gone — a measured −14 (the
  # prior baseline comment mis-stated LegacyConfig as −8; the scanned regex
  # counts 7). The PR-2 applied-turn marker remains.
  # arch-cap-bump: cc-headless SDK sync_result state slice persists conversation/error/token fields (+5)
  # arch-cap-bump: #956 hello Surface.handle_set_shell persists the generated site shell — {:set, :shell} + {:set, :shell_css} (within the surface slice, cross-slice stays 0); net +1
  # arch-cap-bump: kanban-as-role — the kanban plugin's single board-write chokepoint Shared.commit/1 ({:set, :tree}); all 24 actions converge through it (cross-slice stays 0); net +1
  # arch-cap-bump: py-agent (Task 1.2) — Behavior.PyAgent's new subprocess-backed
  #   state: the last_input/result/error triple is consolidated into ONE set_last/3
  #   helper line (3 sites, not 12), plus {:set, :timeout_ms} (configure) and
  #   {:set, :python_phase} (handle_signal). 3 irreducible new sites (cross-slice
  #   stays 0); net +3.
  set_effect_sites: 131,
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
  # kanban-as-role K5 (2026-06-25) — resource-only-files gate. `resource://` stays
  # pure FS (`uri-design.md`); it must NEVER be a live spawnable Kind / GenServer.
  # Forbids the abandoned Plan-B (#964) pattern: a plugin `resource_kinds/0`
  # callback OR any `*ResourceKindRegistry.register(...)` call. The SANCTIONED FS
  # resolver shape (`resource_types/0`) is NOT flagged. Hard zero, no allowlist —
  # Plan-B never landed on main; this locks it out.
  resource_kind_as_genserver: 0,
  # World host-scope config (2026-06-29) — deployment HTTP host literals belong
  # in config/runtime config, not production lib code. Forbids the old
  # `host: "world."` router regression and app/world deploy host strings copied
  # into libraries. Email addresses/domains are not counted.
  hardcoded_deploy_domain_hosts: 0,
  # Socialware deploy-seed gate (2026-07-07, deploy-seed SPEC §5). Two shapes.
  #
  # socialware_priv_manifest_files — TARGET-ZERO. The plugin/domain-priv
  #   `priv/socialware/<name>/manifest.yaml` authoring lane is DEPRECATED (design
  #   §2); the canonical home is the deployment directory, seeded from
  #   `ezagent_web/priv/socialware_seed/<name>/` via `Ezagent.Home.SocialwareSeed`.
  #   Gate-first: starts RED at 1 (autoservice still in domain_session priv);
  #   goes to 0 once autoservice migrates to the deploy-seed source.
  socialware_priv_manifest_files: 0,
  # socialware_self_publish_unsanctioned — 0 (hard). Non-framework
  #   `publish_or_upgrade(` self-publish-at-boot call sites (the `Demo.publish`
  #   shape). Only the framework import lane (`manifest_yaml.ex`) is sanctioned.
  #   Burn-down complete: the hello demo's `Demo.Hello.publish/0` primitive is
  #   DELETED — hello (production AND tests) now publishes only through the
  #   deploy-seed lane (`SocialwareSeed.seed!` → `ManifestSeed.scan_dir!` →
  #   `ManifestYaml.import`). No self-publisher remains; any new one trips this.
  socialware_self_publish_unsanctioned: 0,
  # concatenated_namespace_modules — 0 (hard). Namespace-dot convention gate
  #   (2026-07-08, GLOSSARY Decision #161 follow-up). A single-segment
  #   `defmodule Ezagent.XyzAbc` where `Ezagent.Xyz` is a namespace with dotted
  #   children in the SAME app (parent+child glued — should be `Xyz.Abc`), minus
  #   the `@concatenated_namespace_allowlist` of sanctioned single-concept
  #   compounds. The two real offenders (`AgentRecipeResolver`,
  #   `AgentRecipeAttributes`) were renamed to `Ezagent.Agent.Recipe*` (joining
  #   the existing dotted `Ezagent.Agent.Recipe*` cluster); any NEW glued module
  #   that is not sanctioned trips this.
  concatenated_namespace_modules: 0,
  # no_hardcoded_seed_principal (2026-07-24, Allen) — socialware & seed
  # provisioning must create a user/workspace (or grant ownership) with an
  # EXISTING env-provided user identity, NEVER a principal baked into source. The
  # AST gate flags a `Users.create` / `Workspace.create` / `create_user` /
  # `create_workspace` / `founder_join` / `grant_owner` call whose args carry a
  # hardcoded principal (a literal `entity://`/`user://`/email, an `admin_uri()`
  # accessor, or an inline `Ezagent.URI.user(:system, :admin)` construction); the
  # env/runtime-resolved good pattern (`%{created_by: founder_uri}` /
  # `Ezagent.URI.user(workspace, slug)` — VAR args) is NOT flagged.
  #
  # GRANDFATHERED at 1 (gate-first, mirrors socialware_priv_manifest_files): the
  # sole current hit is `EzagentPluginHello.CredentialBridge.ensure_workspace/1`
  # (`Workspace.create(home, %{created_by: User.admin_uri()})`), the DeepSeek
  # deploy-key credential bridge that #1557 DELETES ("remove deploy-key injection
  # / delete CredentialBridge"). It is left ledgered — not `# arch-allow:`ed — so
  # a NEW hardcoded-principal create trips the gate (count 2 > cap 1), and the
  # cap ratchets 1→0 when #1557 lands. The genesis system-workspace bootstrap
  # (im application.ex, `Workspace.create("system", %{created_by: admin})`) is
  # the load-bearing boot invariant and is `# arch-allow:`ed at its call site
  # (excluded from this count), matching the genesis-admin exception.
  # migrate under #1557
  no_hardcoded_seed_principal: 1,
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
  # arch-cap-bump: RF-3 adds the Lifecycle `detached/2` developer hook (the
  #   per-behavior runtime-detach teardown seam). The @callback IS documented
  #   (lifecycle.ex) but the `use Ezagent.Lifecycle` macro emits an overridable
  #   `def detached(_state, _ctx), do: :ok` default INSIDE the quote — exactly
  #   like its siblings `activated/2`/`deactivate/2`/`create/1`, which are also
  #   counted-undocumented quote defaults. +1 symmetric with them. 393→394.
  # +1 #1217: list_sessions/2 catch-all clause in conversation_session_state.ex
  # (rescue wrapper as public API surface). 394→395.
  # - arch-cap-bump: +3 #1239/#1243 — new `Ezagent.ActionSet.Agent.Complete`
  #   cap-only Lifecycle module for the :complete cap subject. Adds standard
  #   boilerplate (create/1, data_owner/1, data_owner/2 — all @doc false now)
  #   plus Lifecycle macro-generated structural fns. 395→398.
  # - arch-cap-bump: +1 CapBAC transient-identity-read fix (main) — the new
  #   `Ezagent.Kind.IdentityReadError` `defexception` module generates a public
  #   `exception/1` (macro-emitted, no @doc target; its `message/1` IS `@impl`).
  #   Same shape as the existing `Capability.Unauthorized` / `BehaviorSet` error
  #   exceptions already in the baseline. 398→399.
  # - arch-cap-bump: +3 #1312 (feat/hello-0709) — new hello publisher
  #   visible-access-control surface (`EzagentPluginHello.HelloPublisherDispatchTest`
  #   + HelloPublisher/sharer/publisher role code) adds 3 undoc'd public API forms.
  #   399→402. Reconciled additively on rebase onto main (base 398 + main's +1
  #   + branch's +3 = 402; verified against `mix ezagent.arch.scan` on the
  #   merged tree).
  # - arch-cap-bump: +2 socialware composition-cap lane v5 — two new internal
  #   public API forms: `Ezagent.Socialware.SessionInstaller.install/4` (the new
  #   `@moduledoc false` owner-gated install chokepoint) and
  #   `EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents.materialize_definition_agents/5`
  #   (the composition-authorized arity; the `/4` arity is already a baseline
  #   undoc entry). Both are internal materialization seams, consistent with the
  #   sibling undocumented `session_creator`/`materializer` internals already in
  #   the baseline. 402→404 (headroom that fit on the pre-rebase base was consumed
  #   by #1361 landing first; reconciled additively on rebase onto main).
  undocumented_public_defs: 404,
  # dynamic_public_def_heads — `def unquote(name)(...)` heads whose function name
  #   is only known at macro-expansion, so they cannot become a documented
  #   {name, arity} entry. ENFORCED at 0 (the tree has none): adding any new
  #   dynamic public head fails the gate unless this baseline is deliberately
  #   raised with a `# arch-cap-bump:` rationale (codex 2026-06-14).
  dynamic_public_def_heads: 0
}
