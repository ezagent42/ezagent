# SPEC — Ezagent state model migration to EventStore + Commanded (CQRS / event-sourcing)

**Status:** r4 — DRAFT for codex adversarial-review (round 4 — FINAL round of 4-budget). 2026-05-28.

## r4 changelog (delta from r3, retained for trail)

Addresses 6 HIGH + 2 MED + 1 corollary HIGH from codex r3 REJECT (final budgeted round per cap-vis/URI-canonical 4-round pattern):

- **HIGH-1 (§4.1.5 still misclassifies):** r3 left `Echo` and `NpAgent` as vague "per-flavor" — actually both `:ephemeral` (`echo.ex:21`, `np_agent.ex:65`); `Sandbox` was "test fixture only" but production `Ezagent.Entity.Agent` lists it at `agent.ex:75` exposing `:read/:write_path/:destroy` actions at `sandbox.ex:86`. **r4 fix:** §4.1.5 table updates Echo + NpAgent to `:ephemeral`. Sandbox row added to behavior list with explicit migration disposition: stays as Agent aggregate behavior (real `:read`/`:write_path`/`:destroy` commands on Agent aggregate). The "test fixture only" line removed.

- **HIGH-2 (§4.1 stale "no migration" mapping contradicts §6.0):** r3 §4.1 row for `kind_snapshots` still said migrated Kinds "do NOT migrate existing snapshots; first command creates fresh event-sourced state" while §6.0 mandates import. **r4 fix:** §4.1 row REWRITTEN to: "For migrated Kinds: existing snapshot data is forward-migrated via §6.0 snapshot-import as Step 0 of each Phase. The `kind_snapshots` table itself is read-only post-import; deletion gated by §6.4 preflight." This removes the contradiction and aligns §4.1 with §6.0.

- **HIGH-3 (§4.8 AST gate cannot trace facades):** r3 AST gate only matched direct `Ezagent.CommandedApp.dispatch/2` in `handle_event/3`. Actual LV writes route through facades: `Ezagent.Workspace.add_template/3` @ `workspace_detail_live.ex:307`, `EzagentDomainChat.create_session/3` @ `admin_live.ex:804`, `chat.join` dispatches @ `admin_live.ex:1019`, session routing CRUD @ `admin_live.ex:1381`, `EzagentPluginFeishu.bind/2` @ `feishu_bindings_live.ex:88`, `ExternalMirror.bind/4` @ `session_external_mirror_live.ex:221`. **r4 fix:** §4.8 dual-gate architecture:
  - **Facade declaration:** every domain-context write facade (e.g. `Ezagent.Workspace.add_template/3`, `EzagentDomainChat.create_session/3`, `EzagentPluginFeishu.bind/2`) declares a `@consistency :strong | :eventual | {:named, [projector]}` module attribute on its function head. The attribute is the API contract; callers see it via docs + `@type`.
  - **AST gate widened:** `Ezagent.Invariants.ConsistencyMatrixTest` walks each facade module, asserts every public `def` that ends in a `Commanded.App.dispatch/2` call has a `@consistency` attribute; then walks each LV `handle_event/3`, for each facade call, looks up the declared `@consistency` and asserts the LV's subsequent `assign/2` re-read is compatible with that attribute (i.e. if the LV re-reads, the facade must be `:strong` or a named-projector list covering the projection). Facade-to-projection coverage map lives in §5.1 (each projection lists the facades that update it).
  - The hand-table in §4.8 is now annotated with the FACADE name + the dispatching LV file:line. The full list of facades + their `@consistency` declarations is in a new Appendix D.

- **HIGH-4 (§6.1 split-brain unsafe for bind→spawn→subscribe):** r3 had two state stores per Session URI; current bind persists row at `external_mirror.ex:394`, spawns worker at `:421`, then worker subscribes back via legacy publisher at `external_mirror_worker.ex:639`. r3's event-store binding race with legacy publisher subscription is unsafe. **r4 fix:** Phase 10-A drops the slice-split protocol. Two options:
  - **Option (a) — DEFAULT for r4: bind→spawn→subscribe modeled as a single `BootstrapWorkerSaga` from the start.** The saga in 10-A subscribes to the legacy Session's `:slice_change` topic via existing PubSub, NOT to the new event stream. The saga's commands target the new Worker aggregate (now `:aggregate`). The Session itself stays fully legacy in 10-A — `:external_mirror` slice writes remain on the Session GenServer; the saga reads those writes via the legacy slice subscription, not via an event stream. The split disappears; Session is wholly legacy in 10-A, Worker is wholly aggregate, the saga bridges via PubSub.
  - **Option (b) — fallback if Worker reverse-callback to Session publisher cannot be retained legacy: migrate the full Session aggregate in 10-A (Chat + Publisher + ExternalMirror + OrchestratorAdmin together).** Big-bang scope; rejected unless (a) proves infeasible at impl PR-A1.

  Option (a) commits r4. The split-brain protocol from r3 §6.1 is REMOVED. SessionRouter is removed; Session stays entirely legacy in 10-A. `Ezagent.Invariants.SessionSplitBrainConsistencyTest` is removed (no longer needed).

- **HIGH-5 (§6.0 UNION missing workspace scope + wrong cursor type):** r3 UNION filters/orders by `m.inserted_at` but omits `m.workspace_uri == ?` (required per `message_store.ex:174`/`:201`). r3 says `older_than(session_uri, msg_id)` — actual cursor type is `DateTime`, not `msg_id`, per `message_store.ex:195`. **r4 fix:** §6.0 UNION rewritten to include `m.workspace_uri = $workspace_str` predicate + `r.session_uri = $session_uri` join key + ordering by `r.inserted_at`. `older_than` cursor corrected to `DateTime` per the existing API. Three parity-preserving SQL templates added (one per query), matching the current `MessageStore.recent_in_session/3`, `older_than/3`, `in_session_since/3` signatures.

- **HIGH-6 (§5.1 + §6.0 User projection parity not carried):** r3 said §5.1 was updated but field-level parity gates in §6.0 verify still referenced generic `kind_snapshots.state_binary` parity. **r4 fix:** §5.1 projection list explicitly enumerates COLUMNS for each User projection (no more "etc"). §6.0 `mix ezagent.aggregate.verify --kind user` definition expanded with explicit per-table parity asserts: it queries every row of `entity_profiles`, asserts a matching `user_profile_projection` row exists with `display_name + email + workspace_uri + registered_at` equal; then queries `entity_tokens`, asserts matching `user_tokens_projection` row with `token_hash + label + last_used_at + workspace_uri` equal. The generic parity step survives FOR `users.caps_json` (handled via `user_caps_projection`); the new explicit asserts are additional.

- **MED-7 (§4.2.3 working-copy nested field names wrong):** r3 had `source_template_uri` — actual field per `chat.ex:257` is `source_agent_template_uri` + `live_worker_uri` + `generation`. **r4 fix:** §4.2.3 working-copy nested shape rewritten to match `default_template_working_copy/0` verbatim — `agent_slots: [{slot_name, source_agent_template_uri, live_worker_uri, generation}]`. Replay parity test reaches per-nested-field, not just "5 fields exist".

- **HIGH-8 (§3.8 step 0 reads stale projections):** r3 `%CaptureDestroyPreSnapshot{}` read caps/sessions/lineage from projections (eventually-consistent). Lineage source is ETS (`agent_lineage.ex:31`); caps are slice state (`identity.ex:89`). Reading projections for compensation baseline is stale-by-design. **r4 fix:** Step 0 captures from AUTHORITATIVE sources directly. The aggregate's `execute/2` for `%CaptureDestroyPreSnapshot{}` reads:
  - Caps from the Agent aggregate's OWN state (the aggregate has `caps: MapSet.new()` in its defstruct; `%DestroyPreSnapshotCaptured{}.caps = aggregate.caps`).
  - Lineage parent from the aggregate's OWN state (`aggregate.lineage_parent_uri`).
  - Session memberships from the aggregate's OWN state (`aggregate.sessions`).

  The aggregate's state IS the authoritative source — it was hydrated from events on aggregate-load; no projection lag concern. The saga's PM state retains the snapshot for fast compensation lookup, but the snapshot's source-of-truth is the event-replayed aggregate state at command-time. No external projection read in step 0.

- **MED-9 (§6.4 cooldown is actually expiry, not cooldown):** r3 said `expires_at = drill_completed_at + 24h` and called that a cooldown; but `execute` permits `now > drill_completed_at` — DROP can run immediately, not after a cooldown. **r4 fix:** §6.4 receipt schema adds explicit `earliest_execute_at = drill_completed_at + cooldown_hours` (default 24h, configurable). `expires_at` becomes a separate field (default `drill_completed_at + 7d`). `cleanup.execute` verifies `earliest_execute_at < now < expires_at`. Receipt is one-time consumed: `cleanup.execute` writes a marker file `priv/cleanup_receipts/<timestamp>.consumed` after a successful DROP; replays of the same receipt see the marker and fail. An `execution_nonce` is generated by `cleanup.execute` and recorded in an `audit_events` row for forensic trail.

---

## r3 (prior) status

## r3 changelog (delta from r2, retained for trail)

Addresses 6 HIGH + 2 MED from codex r2 REJECT (no CRIT in r2 — r1 CRITs closed):

- **HIGH-1 (§4.1.5 inventory still wrong):** r2 misclassified `Ezagent.Workspace` as `{:snapshot, :on_change}` (actually `:ephemeral` at `apps/ezagent_domain_workspace/lib/ezagent/entity/workspace.ex:61`), `Ezagent.Entity.ExternalMirrorWorker` as `:on_terminate` (actually `:ephemeral` at `apps/ezagent_domain_external_mirror/lib/ezagent/entity/external_mirror_worker.ex:71`); omitted `Ezagent.Entity.System` (a real Kind with Routing behavior, `:ephemeral` at `apps/ezagent_core/lib/ezagent/entity/system.ex:32`); omitted `Ezagent.Behavior.IdentityAdmin` (separate behaviour module in same file as `Identity`, at `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:328`). **r3 fix:** §4.1.5 rewritten with statically-verified persistence values from each module. New §4.1.5-table-note clarifies that `:ephemeral` Kinds (`Workspace`, `ExternalMirrorWorker`, `System`) are durable via *external persistence* (Workspace = `workspaces` SQLite table via `Workspace.Store`; Worker = `external_mirror_bindings` reconciliation; System = config-derived bootstrap). Their migration target reads from those external sources at aggregate creation, not from `kind_snapshots`. The §6.0 import task is adjusted per-Kind to read from the correct source.

- **HIGH-2 (§4.8 consistency matrix incomplete and references wrong files):** r2 referenced nonexistent `agents_live.ex` (actual: `agent_new_live.ex`), used TBD rows, and missed many write→read sites. **r3 fix:** §4.8 is rewritten with statically-verified file:line. New sites added: `users_live.ex:202` (set_password), `users_live.ex:230` (promote_to_system), `users_live.ex:250` (revoke from system), `workspace_detail_live.ex:255` (remove member), `routing_live.ex:307` (delete_rule), `agent_api_keys_live.ex:159` (delete_api_key). `agent_new_live.ex:120` corrected for create-agent. The matrix is now declared as the *source of truth*; r3 promotes the invariant to a structural AST scan via `Ezagent.Invariants.ConsistencyMatrixTest` that walks every LV `handle_event/3` clause AST-side and asserts: any dispatch followed by an `assign/2` re-read of the modified projection uses `consistency: :strong`. The hand-table is a doc artifact; the invariant test is the gate.

- **HIGH-3 (§6.1 Phase 10-A still self-contradictory):** r2 left the "Worker first (smallest Kind) — One Kind migrated; everything else unchanged" phrasing while expanding to include Session ExternalMirror behavior. **r3 fix:** Phase 10-A renamed "ExternalMirror slice + Worker — the bind-spawn coupling boundary". The "smallest Kind" framing is dropped. New paragraph explicitly enumerates the split-brain protocol: Session's `Behavior.Chat` + `Behavior.Publisher.SessionImpl` + `Behavior.OrchestratorAdmin` slices stay GenServer-hosted; only the `:external_mirror` slice moves to the new Session aggregate. The Session GenServer is alive AND the Session aggregate has events on its stream — they are TWO state stores for one URI during 10-A. The pre-dispatch pipeline routes commands by which Behavior the command targets: ExternalMirror commands → aggregate; Chat/Publisher/OrchestratorAdmin commands → legacy. A new `Ezagent.SessionRouter` module owns the routing decision (`route_session_command/1 :: :legacy | :aggregate`). The invariant: any test that exercises a Session URI must drive BOTH the GenServer slice + the aggregate state into consistency.

- **HIGH-4 (§6.0 messages archive plan wrong column / wrong join):** r2 said "filter by `created_at`"; actual schema column is `inserted_at` per `apps/ezagent_core/priv/repo/migrations/20260516070500_phase2_messages.exs:23`; per-session history is a `message_routings → messages` join per `apps/ezagent_core/lib/ezagent/message_store.ex:174`. **r3 fix:** §6.0 messages archive paragraph rewritten: the permanent query is an ordered union over (a) the archive `message_routings ⋈ messages` join filtered `inserted_at < <cutover_at>`, and (b) the new `session_messages_projection` filtered `inserted_at >= <cutover_at>`. Parity gates added for `recent_in_session`, `older_than`, `in_session_since` query shapes.

- **HIGH-5 (§4.2.1 User projections still omit fields):** r2 added profile/token fields to aggregate state but the §5.1 projection table rows didn't reflect them. **r3 fix:** §5.1 projection table updated — `user_profile_projection(uri, workspace_uri, display_name, email, registered_at, destroyed?)`; `user_tokens_projection(uri, token_id, token_hash, label, scope, expires_at, last_used_at, minted_at, revoked_at, workspace_uri)`. Field-level parity gates added against `entity_profiles` + `entity_tokens` during the §6.0 import: every row in those tables must produce a matching projection row post-replay.

- **MED-6 (§4.2.3 Session working-copy shape underspecified):** r2 had `template_working_copy: nil` — actual default is a structured map at `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:255` with `agent_slots`, `routing_rules`, `orchestrator_template_uri`, `default_workspace_uri`, `description`. **r3 fix:** §4.2.3 expanded — `template_working_copy` is now a sub-struct with the 5 named fields, default per `default_template_working_copy/0`. Replay test added: a Session with a populated working copy reconstructs all 5 fields.

- **HIGH-7 (§3.8 saga step 0 was commentary, not code):** r2 documented `pre_destroy_caps` / `pre_destroy_sessions` / `pre_destroy_lineage_parent` in saga defstruct comments but the actual `defstruct` line didn't include them. **r3 fix:** §3.8 saga is REWRITTEN with explicit step 0:
  ```elixir
  def handle(%__MODULE__{step: nil}, %AgentDestroyRequested{} = ev) do
    %CaptureDestroyPreSnapshot{agent_uri: ev.agent_uri}  # NEW: step 0 dispatches a snapshot-capture command FIRST
  end
  def handle(%__MODULE__{step: :pre_snapshotted}, %DestroyPreSnapshotCaptured{} = ev) do
    %RevokeAllCapsHeldBy{agent_uri: ev.agent_uri}  # step 1 now reads snapshot from aggregate state
  end
  ```
  The `DestroyPreSnapshotCaptured` event payload carries the pre-destroy caps/sessions/lineage_parent; the aggregate's `apply/2` writes these into the aggregate's own state (NOT into the saga). The compensation reverse commands read those snapshot fields directly from the aggregate at compensation time. defstruct EXTENDED with these fields. Step 2 DestroyChildAgents stays declared non-compensable per saga forward-only doctrine; the post-r3 runbook documents the operator-repair path (`mix ezagent.saga.repair --saga DestroyAgentSaga --uri <uri>` reads partial residue + emits manual cleanup commands).

- **MED-8 (§6.4 cleanup gate spoofable by fake ticket):** r2 only checked "matches docs/runbooks entry"; not a real artifact gate. **r3 fix:** §6.4 preflight requires a *drill receipt*: a signed JSON artifact at `priv/cleanup_receipts/<timestamp>.json` containing `{backup_path, backup_sha256, live_row_count, restored_row_count, parity_report_sha256, operator_email, drill_completed_at, expires_at: drill_completed_at + 24h}`. The `mix ezagent.cleanup.drill` task is the ONLY writer of that file; it computes the SHAs at drill time. The `mix ezagent.cleanup.execute` task verifies: (i) receipt exists, (ii) SHAs match the *current* live DB state, (iii) `drill_completed_at < now < expires_at`, (iv) `operator_email` is on `priv/cleanup_operators.allowlist` (committed file). Any tampering invalidates the SHA. The receipt cannot be forged via `--operator-approved` flag alone.

---

## r2 (prior) status

## r2 changelog (delta from r1, retained for trail)

Addresses 2 CRIT + 4 HIGH + 2 MED from codex r1 REJECT:

- **CRIT-1 (forward data migration plan was missing — §4.1 / §6 / §8):** r1 claimed migrated Kinds "do NOT migrate existing snapshots; first command creates fresh event-sourced state". That drops live User/Session/Agent/Workspace state at cutover. **r2 fix:** new §6.0 (Forward Data Migration) is mandatory at the start of every Phase (10-A through 10-C). It defines a per-Aggregate "snapshot import" event class (e.g. `%UserSnapshotImported{}`) emitted ONCE per existing URI by a `mix ezagent.aggregate.import --kind <kind>` task BEFORE production dispatch is routed to the aggregate. The import event carries the full pre-existing slice payload. The aggregate's `apply/2` has a dedicated clause for the snapshot import event that hydrates the aggregate state. A parity gate (read-back from event-replayed aggregate vs `kind_snapshots` row) is the import-step success criterion; the cutover does NOT happen until parity is green. §6.0 + §6.1/6.2/6.3 expanded to include the import task as Step 0 of each Phase.
- **CRIT-2 (Phase 10-A bridge gap — §6.1 / §8.2):** r1 had Phase 10-A migrate Worker only, but legacy Session `Behavior.ExternalMirror` still calls `Ezagent.Kind.spawn(Ezagent.Entity.ExternalMirrorWorker, params)` directly at `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:394` + `:677`. No `BindingCreated` event is emitted while Session remains a GenServer, so `BootstrapWorkerSaga` never fires. **r2 fix:** Phase 10-A is REVISED to either (a) migrate Session ExternalMirror behavior+Worker together (preferred — they're tightly coupled at the bind callsite) OR (b) ship an explicit `Ezagent.MigrationBridge.LegacyBind` shim that translates legacy `Kind.spawn(Worker, params)` calls into `%SpawnWorker{}` commands on the new aggregate AND emits a synthetic `%BindingCreated{}` event into the new event stream so saga triggers fire. Option (a) is taken as r2 default; option (b) documented as fallback if Session-side migration proves too entangled. §6.1 expanded to include the Session ExternalMirror behavior delta.
- **HIGH-3 (read-after-write consistency matrix was missing — §3.3 / §6.2):** r1 said "opt to :strong per dispatch site" without enumerating sites. r2 adds §4.8 (LV / Channel / CLI Consistency Matrix) — a table listing every write callsite that immediately re-reads state, with the required consistency mode. Sites already inventoried statically: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/users_live.ex:137` (create→list_users), `workspace_detail_live.ex:165` (add member→get_by_name), `entity_caps_live.ex:142` (grant cap→reload caps), `routing_live.ex:235` (add rule→reload rules). All MUST use `consistency: :strong` (or named-projector list). The Phase 10-B/10-C invariant tests assert each enumerated site does so; a CI grep gate rejects `consistency: :eventual` on these specific dispatch paths.
- **HIGH-4 (Kind/Behavior inventory was incomplete — §4.2 / §4.3):** r1 said "5 entity Kinds" + "11 Behavior modules" — actual count is much larger. r2 adds §4.1.5 (complete Kind/Behavior inventory) statically enumerated from the checkout: 15+ Kind modules (including durable `Ezagent.Entity.AgentTemplate` + `Ezagent.Entity.SessionTemplate`, both `{:snapshot, :on_change}`, plus per-flavor `CurlAgent` / `Echo` / `NpAgent`), 24 Behavior modules (added: `ApiKeys`, `Template`, `OrchestratorAdmin`, `Pty`, `UserBinding`, `FeishuAllow`, plus the 4 plugin agent-flavor behaviors). Each gets a per-Phase migration disposition column. §4.3 rewritten with the full list.
- **HIGH-5 (Session aggregate state omitted durable fields — §4.2.3):** r1's Session aggregate state struct missed `owner_uri`, `last_seen`, `monitors`, `last_message_id`, `last_message`, `send_cursor`, `recent_messages`, `template_working_copy`, plus Publisher's `ring` / `cursor` / `retention` (all durable — `Behavior.Chat.init_slice` at `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:144`-`:242` + `Publisher.SessionImpl.init_slice` at `apps/ezagent_domain_chat/lib/ezagent/behavior/publisher/session_impl.ex:150`-`:165`). r2 fix: §4.2.3 Session aggregate state struct is REWRITTEN to enumerate every durable field; non-durable runtime fields (`monitors` — process refs that don't survive restart) are explicitly excluded with a comment. Replay tests for rejoin / external mirror dedupe / publisher cursor catchup are added as Phase 10-B invariant tests.
- **HIGH-6 (User projection schema missed profile + token fields — §4.2.1 / §4.7):** r1's `user_profile_projection` had only `(uri, workspace_uri, registered_at, destroyed?)`. Current `Entity.Profile` schema (`apps/ezagent_domain_identity/lib/ezagent/entity/profile.ex:21`) has `display_name` (required) + `email`. Current `Entity.Token` schema (`apps/ezagent_domain_identity/lib/ezagent/entity/token.ex:43`) has `token_hash`, `label`, `last_used_at`. **r2 fix:** §4.2.1 User aggregate gains a `:profile` field (`%{display_name, email}`) + commands `%UpsertProfile{}` / events `%ProfileUpserted{}`. Token aggregate state + events extended to carry hash/label/last-used. Projections in §5.1 updated to match.
- **MED-7 (DestroyAgentSaga compensation was only retry/stop — §3.8 / §4.4):** r1's saga `error/3` retried then stopped. Current cleanup paths (`apps/ezagent_domain_chat/lib/ezagent_domain_chat.ex:189` session-create rollback, `apps/ezagent_core/lib/ezagent/behavior/sandbox.ex:240` sandbox-destroy cleanup) do explicit reverse-operations. **r2 fix:** §3.8 DestroyAgentSaga is REWRITTEN to use `{:continue, [%ReverseCommand{}, ...], context}` per-step compensation in the `error/3` callback. Each step is documented with: (a) idempotency contract; (b) residue on failure; (c) reverse command; (d) resume behavior. Step-failure tests are Phase 10-C invariants.
- **MED-8 (Phase 10-D destructive cleanup lacked operator gate — §6.4 / §8.4):** r1 said "delete `kind_snapshots` after a final data dump". Per `feedback_destructive_migration_anti_pattern` + `feedback_completion_requires_invariant_test`, that's not a gate. **r2 fix:** §6.4 Phase 10-D `DROP TABLE kind_snapshots` is gated on: (a) operator approval flag in the migration script (mix task requires `--operator-approved <ticket-id>`); (b) verified backup restore drill — operator restores last snapshot dump to a temp DB and asserts row count matches; (c) post-restore parity check — the import-replay vs original snapshots must equal across all migrated URIs. The gate is itself a `mix ezagent.cleanup.preflight` task that exits non-zero unless (a)+(b)+(c) hold. SPEC §8.4 expanded.

---

## r1 (initial) status

**Tier:** Cross-cutting architectural migration. Touches `apps/ezagent_core/` (Kind / Behavior / Invocation / Persistence / Snapshot / Audit), all `apps/ezagent_domain_*/` (User, Session, Agent, Workspace, ExternalMirror Worker entity Kinds), the LiveView reading layer (`apps/ezagent_plugin_liveview/`), the CLI (`apps/ezagent_cli/`), the web dispatch surface (`apps/ezagent_web/`), and every plugin authoring example. Introduces three new umbrella apps (`ezagent_event_store`, `ezagent_commanded_app`, `ezagent_projections`) and a runtime hybrid period where some Kinds are Aggregates and others remain GenServers.

**Trigger:** Allen 2026-05-28 06:31 — pause SPEC #440 (entity-destroy lifecycle) after 4 codex REJECT rounds. The destroy cascade's 3 critical findings (no transactional cross-Kind atomicity; partial-failure inconsistency window; saga-like recovery requires structural primitives the current Kind=GenServer model does not provide) all dissolve under event-sourced semantics with Process Managers. Allen flagged the deeper hypothesis: **every multi-Kind workflow we have built (boot reconciler, spawn registry races, cap grant-time check, workspace cap-vis 5-round iteration) hits the same wall**. The destroy-lifecycle blockage is the most visible instance of a class.

**Companion:** `2026-05-28-eventstore-commanded-migration.zh_cn.md` (per `feedback_bilingual_docs_convention`).

**Predecessor memories (load-bearing):**
- `feedback_let_it_crash_no_workarounds` — no shim / dual-path. If we adopt CQRS/ES, the snapshot table becomes a cache for Aggregate replay, NOT a parallel source of truth. The migration is committed (per-Kind hard flip), not toggled.
- `feedback_completion_requires_invariant_test` — Phase gates are invariant tests that FAIL when the architectural goal is unmet. For each migrated Kind, the gate is "this Kind's state reconstructs deterministically from its event stream alone" (no slice/snapshot fallback). For Sagas: "this multi-Kind workflow runs through a Process Manager (not direct cross-Kind GenServer.call)".
- `feedback_north_star_plugin_isolation` — plugin authors write Commands + Events + an Aggregate `execute/2` + `apply/2`. They do NOT touch `Commanded.Application`, the event store config, projection wiring, or the saga registry. The boundary tightens.
- `feedback_destructive_migration_anti_pattern` — see §6 / §8. The migration adds a new event store DB; it does NOT destroy existing snapshot data. The unwind path in §12 explicitly forks back to slice/snapshot for any Phase whose migration aborts.
- `feedback_register_lookup_key_parity` — Aggregate identity must canonicalize the same way as the existing Kind URI (`Ezagent.URI.parse!/1`). The `:identify` clause on the router uses the canonical URI string; divergent canonicalization between dispatch sites would silently mis-route a command to a fresh Aggregate ID. §4.6 enforces.
- `feedback_uuid_is_canonical_identifier` — Aggregate UUIDs MUST be the canonical URI string of the existing Kind URI. We do NOT mint a new UUID column. The URI IS the identifier.
- `feedback_subagent_must_load_project_skills` — every Phase impl subagent dispatch MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper`.
- `feedback_codex_review_every_pr` — codex review of THIS SPEC + every Phase impl PR carries the verbatim "no mix" clause.
- `feedback_phase_planning_reads_main_docs` — Phase numbering in §6 conforms to `IMPLEMENTATION_ROADMAP.md` §1.1 (current latest is Phase 6 / partial). This migration would be Phase 10 (post-Phase-9 PR-CC follow-ups complete, post-Phase-6 closeout).
- `feedback_explain_problem_not_code_structure` — §1 leads with the problem class (multi-Kind workflows lack atomicity primitives), §2 leads with the decision (CQRS/ES), code shape lives in §4-§5.

**Parent / historical context:**
- `IMPLEMENTATION_ROADMAP.md` §1.1 — Phase 0-6 are complete or in-flight. This SPEC would become Phase 10 (skipping reserved-but-unstarted Phase 7-9 follow-up work).
- `ARCHITECTURE.md` Decision Log #84 — chose path B (`@behaviour Ezagent.Kind` + shared `Kind.Server` GenServer) over path A (`use Ezagent.Kind` macro). This SPEC supersedes both with path C (`Commanded.Aggregate`).
- `ARCHITECTURE.md` Decision Log #59 + #60 — sync `on_change` snapshot writes + async batch writer for `periodic`. The event-sourced model REPLACES this with synchronous event append + optional aggregate snapshot every N events.
- `apps/ezagent_core/lib/ezagent/kind/server.ex` — the shared Kind GenServer that hosts every Kind today. Becomes deprecated post-Phase-10-D for each migrated Kind.
- `apps/ezagent_core/lib/ezagent/invocation.ex` (steps 1-4, 11-12) + `apps/ezagent_core/lib/ezagent/kind/runtime.ex` (steps 5-10) — the 12-step dispatch flow. Steps 5-10 collapse into `Commanded.Application.dispatch/2` after migration; steps 5.5 (CapBAC) + 5.6 (workspace isolation) move to a pre-dispatch authz pipeline (§4.5).
- `apps/ezagent_core/lib/ezagent/kind/snapshot.ex` — the per-Kind snapshot table. Becomes the Commanded aggregate snapshot store for migrated Kinds; remains in service for any not-yet-migrated Kind during the hybrid window.
- `apps/ezagent_core/lib/ezagent/audit.ex` + `Ezagent.Audit.Writer` — the SQLite `invocations` audit table. Becomes redundant for migrated Kinds (the event stream IS the audit log); REMAINS for un-migrated Kinds and for cross-cutting telemetry that isn't a domain event (e.g. `[:ezagent, :authz, :denied]` deny-side audit).
- `docs/superpowers/specs/2026-05-27-uri-canonicalization.md` — the canonical `%URI{}` chokepoint. Aggregate ID derivation in §4.6 routes through `Ezagent.URI.parse!/1` and emits `URI.to_string/1` for the router `:identify` clause.
- `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` — the dispatch-time authz invariant (step 5.5 chokepoint). §4.5 of this SPEC explains how the authz check moves out of `Kind.Runtime.handle_dispatch/4` into a pre-dispatch pipeline that wraps `Commanded.Application.dispatch/2`, preserving the chokepoint.

**Reference libraries:**
- [commanded](https://github.com/commanded/commanded) — CQRS/ES framework for Elixir. v1.4.10 latest. ([hexdocs](https://hexdocs.pm/commanded))
- [eventstore](https://github.com/commanded/eventstore) — PostgreSQL-backed event store for Elixir. v1.4.8 latest.
- [commanded_eventstore_adapter](https://hex.pm/packages/commanded_eventstore_adapter) — adapter wiring `commanded` to `eventstore`.
- [commanded_ecto_projections](https://hex.pm/packages/commanded_ecto_projections) — Ecto-backed read-model projector helpers.
- [Conduit reference app](https://github.com/slashdotdash/conduit) — Phoenix + Commanded Medium clone.
- [Gift-card demo](https://github.com/slashdotdash/gift-card-demo) — Phoenix LiveView + Commanded reference.

---

## 1. Problem statement — why migrate

### 1.1 The destroy-lifecycle 4-round codex failure as proof

SPEC #440 (entity destroy lifecycle) hit 4 consecutive codex REJECT rounds without converging. Each round addressed a different facet of the same structural shortfall:

- **r1 REJECT — atomicity:** the 7-step destroy cascade (revoke caps → unbind external mirrors → terminate child agents → drop session memberships → unlink lineage → terminate Kind processes → write deletion-audit row) cannot be atomic under the current Kind=GenServer model. Each step is a separate `Invocation.dispatch/1` against a different Kind; if step 4 raises (target Kind crashes mid-leave), steps 1-3 already committed and there is no transactional roll-back primitive. Mitigation proposed: "destroy_lock" GenServer per parent URI to serialize concurrent destroys. Codex flagged: lock acquisition does not give atomicity, only serialization; the partial-failure window persists.
- **r2 REJECT — fence/saga:** proposed a "destroy fence" mechanism — a sweeper that re-runs steps until idempotent. Codex flagged: the sweeper requires re-entrant idempotency on every step's invoke handler, retrofitting that onto 11 existing behaviors is a different SPEC; and the sweeper's progress is itself a workflow that needs its own state machine.
- **r3 REJECT — destroy-as-state-flag:** proposed a `:destroyed_at` slice column on each Kind so dispatch could deny invocations on a tombstoned Kind. Codex flagged: tombstone is a soft delete; the requirement was hard delete + cap unwind + audit; tombstone leaks the dead URI forever and does not address cascade.
- **r4 REJECT — destroy_log table:** proposed a side-table that records cascade progress + a reconciler that resumes interrupted destroys on boot. Codex flagged: this IS event-sourcing, badly. The `destroy_log` table is a hand-rolled append-only event stream; the reconciler is a hand-rolled Process Manager; we are reimplementing Commanded primitives one ad-hoc table at a time.

**Codex r4 verdict text (quoted from the review):** *"The destroy_log approach is event-sourcing without the framework. Every problem you're trying to solve — multi-aggregate atomic operations, mid-failure resumption, audit trail invariant — is what Commanded was designed for. This SPEC keeps re-inventing Commanded internals piecemeal. Step back: do you need to keep the GenServer+slice model, or is the architectural ceiling here?"*

That codex verdict is the proximate cause of THIS SPEC. The atomic-destroy problem is intractable in the current model. The CQRS/ES model has structural primitives — Aggregates carry their own state from events, Process Managers orchestrate multi-aggregate workflows with built-in compensation, EventStore append is the audit log, snapshots are a cache not a source of truth — that resolve all 4 codex blocker classes without re-invention.

### 1.2 The bigger class — every multi-Kind workflow hits this

Destroy is the most acute case, but the same pattern recurs:

- **`BootReconciler`** (Phase 3 PR-EM-9, external-mirror-domain SPEC §3.1) — on Application boot, scan the `external_mirror_bindings` projection table and re-spawn Workers for each persisted binding. The reconciler is a hand-rolled scan-and-spawn loop that races against Session boot (Worker `post_init/2` may run before its target Session reaches `:ready`, requiring a buffer + retry layer in `PendingDelivery`). Under CQRS/ES, "Worker for binding X exists when binding X exists in the read model" is a saga that subscribes to `BindingCreated` events and emits `SpawnWorker` commands. No boot scan; no race; the saga state machine encodes the ordering.
- **`SpawnRegistry` race classes** (Phase 2-3 incident retros) — concurrent `Kind.spawn/2` calls for the same URI race on `DynamicSupervisor.start_child`, with `{:error, {:already_started, pid}}` handled idempotently by callers BUT the second caller's `init_slice/1` args silently lost (the first call wins). Under CQRS/ES, "first command at this aggregate ID creates it" is a primitive — the aggregate doesn't exist until the create command lands; subsequent create commands fail with `{:error, :already_created}` deterministically; the aggregate state is built from the events of the FIRST creation regardless of which process emitted them.
- **Capability grant-time check ambiguity** (PR-CC-2 / caps-cleanup-v1 SPEC) — `Behavior.Identity.grant_cap` must verify the granter held the underlying ownership cap AT GRANT TIME, but caps are a slice that mutates on every grant — the check is a read-after-write against the granter's own slice. The current model resolves this with synchronous `GenServer.call` ordering (`Kind.Server.handle_call` serializes per-instance). Under CQRS/ES, the granter's caps at grant time are derivable from the granter Aggregate's event-replayed state at the instant the grant command was applied; the command's `execute/2` reads the aggregate state and emits the `CapGranted` event atomically (the aggregate-level serialization gives the same property; it's also durable in the event stream, so the audit query "what caps did the granter hold when they granted X" becomes a stream filter, not a forensic snapshot read).
- **Workspace cap-vis 5-round iteration** (`2026-05-27-workspace-cap-based-visibility.md`) — 5 codex rounds REJECT mostly over policy-helper placement + admin-bypass corner cases. The cap-vis SPEC itself was straightforward (`list_workspaces_for(caller, caps)`); the rounds went into "where does the helper live"; "does the helper match cross-workspace runtime semantics"; "does the helper handle the wildcard cap path"; "does the system-membership predicate live on Identity or Capability". Under CQRS/ES, "workspace visibility for caller" is a read-model query against a `workspace_visibility_per_caller` projection — the projection encodes the policy in one place at projection-time; the query at LV-read-time is `SELECT workspace_uri FROM ... WHERE caller_uri = ?`. Policy iteration happens in the projector, not at every read site, and the read site cannot drift from the policy.

The thread: **every multi-Kind workflow exposes a missing primitive in the current model — atomic cross-Kind operations, deterministic saga resumption, queryable historical state, single-place policy projection.** CQRS/ES provides each of these as a framework feature. The current model rebuilds each one ad-hoc per SPEC, and each ad-hoc rebuild costs 3-5 codex rounds.

### 1.3 Diagnosis — current architecture has CRUD but no event log

The current ezagent state model is structurally:

```
External request (LV / CLI / Feishu / MCP / HTTP)
  → Adapter constructs %Invocation{}
  → Invocation.dispatch/1
    → Idempotency check (step 1)
    → ReadyGate gate (step 4)
    → Kind.Runtime.handle_dispatch (steps 5-10):
      - BehaviorRegistry lookup
      - CapBAC step 5.5
      - Workspace isolation step 5.6
      - Behavior.invoke/4 — returns {:ok, new_slice} | {:ok, new_slice, result}
      - Kind.Server merges new_slice into state.state[slice_key]
      - Persistence write (if :on_change and changed)
      - Telemetry emit
    → reply/2 routes result to caller
```

State mutation is **CRUD-shaped**: each `Behavior.invoke/4` is a function `(slice, args) -> new_slice`. There is no formal command/event split. The audit log (`invocations` table) is a side-channel recording of `(caller, target, action, result)` tuples written by a telemetry handler — it is NOT the source of truth (the slice/snapshot is). Cross-Kind workflows are sequences of `Invocation.dispatch/1` calls strung together imperatively in caller code (e.g. `EzagentDomainChat.create_session/3` orchestrates 5 dispatches across 4 Kinds with try/rescue cleanup at each step).

The shape this leaves us with:
- **No formal command** — `Behavior.invoke/4`'s `args` argument is just a map; there is no Command struct, no router, no central catalog of what commands exist.
- **No formal event** — `Behavior.invoke/4`'s return is a new slice + optional result; the slice mutation is not named, not durable, not subscribable.
- **No saga primitive** — multi-Kind orchestration is imperative caller code with manual try/rescue cleanup; partial-failure compensation is ad-hoc per call site.
- **No replay** — restart restores the latest snapshot only; the history between snapshots is lost (audit table is a side-channel, not replayable into Kind state).
- **No subscription** — LV reads slice directly via `Kind.get_slice/2` (sync `GenServer.call`); to react to a slice change, LV must poll OR rely on `Phoenix.PubSub` broadcasts from Behavior code (e.g. `Behavior.Chat` broadcasts `:message_appended`). Each broadcast is opt-in per Behavior; there is no automatic event stream.

### 1.4 Hypothesis — CQRS/ES provides the missing primitives structurally

Commanded + EventStore provides:
- **Command** as a struct, dispatched through a router with `:identify` clauses that route by aggregate UUID. Catalog is the router config.
- **Event** as a struct, emitted by `Aggregate.execute/2`, persisted to the event stream BEFORE `Aggregate.apply/2` mutates the in-memory state. Audit is the event stream.
- **Aggregate** as a process, restored from event replay (+ optional snapshot every N events). State IS derived from events.
- **Process Manager (Saga)** as a stateful event subscriber that emits commands in response to events. Multi-aggregate workflows are explicit + resumable + compensable.
- **Projection** as an event-subscribing read-model updater (Ecto-backed via `commanded_ecto_projections`). LV reads the projection table; the projector updates it from events. Read-model decoupling is built-in.
- **Consistency mode** — `dispatch(cmd, consistency: :strong)` blocks until strong-consistent projectors have caught up; `:eventual` returns immediately. The read-after-write problem is a flag at dispatch time, not a hand-rolled wait loop.

Every one of §1.2's pain points dissolves to a framework primitive. The migration cost is real (Phase plan in §6), but the recurring cost of NOT migrating is 3-5 codex rounds per SPEC that touches a multi-Kind workflow — and we have one or more such SPECs every week.

---

## 2. Decision — adopt Commanded + EventStore as primary state model

### 2.1 What we adopt

| Component | Lib | Role |
|---|---|---|
| `Commanded.Application` | `commanded` | Per-deployment dispatch + aggregate hosting boundary |
| `Commanded.Commands.Router` | `commanded` | Command → Aggregate routing via `:identify` |
| `Commanded.Aggregates.Aggregate` | `commanded` | The behaviour replacing `Ezagent.Kind`'s GenServer pattern |
| `Commanded.ProcessManagers.ProcessManager` | `commanded` | Multi-aggregate workflows (the new home for destroy cascade etc.) |
| `Commanded.Event.Handler` | `commanded` | Non-projection event subscribers (e.g. mirror events to external systems, dispatch follow-up commands without state — the `:eventually consistent` variant of a process manager when state machine is overkill) |
| `Commanded.Projections.Ecto` | `commanded_ecto_projections` | Read-model projectors that Ecto.Multi-update tables on events |
| `EventStore` | `eventstore` | Postgres-backed event persistence |
| `Commanded.EventStore.Adapters.EventStore` | `commanded_eventstore_adapter` | Adapter wiring `commanded` to `eventstore` |
| `Commanded.EventStore.Adapters.InMemory` | bundled | Test / dev-loop event store |

### 2.2 What we do NOT adopt yet

- **EventStoreDB** (the standalone Erlang/Scala event store via `commanded_extreme_adapter`) — operationally heavier than Postgres + `eventstore` lib, and we have no clustering need at current scale. Postgres ops is widespread; EventStoreDB is niche. (Discussion in §7.4 + §10 OQ-1.)
- **Snapshot store on EventStoreDB** — we use Commanded's built-in snapshot-every-N-events stored in the same Postgres `eventstore` schema. The existing `kind_snapshots` SQLite table is retired per Kind on migration.
- **Multi-app Commanded topology** (one `Commanded.Application` per bounded context with cross-app event bridges) — overkill for our 5-Kind model; we run ONE `Ezagent.CommandedApp` with all aggregates + all process managers + all projectors. Splitting is a Phase N+1 question if scale demands it.

### 2.3 What stays unchanged (the external API surface)

- Phoenix.Channel `handle_in/3` callbacks. Today they construct `%Invocation{}` and call `Invocation.dispatch/1`; post-migration they construct `%Cmd{}` and call `Ezagent.CommandedApp.dispatch/2`. The channel topic, message shape, response shape are unchanged from the JS client's perspective.
- LiveView `mount/3` + `handle_event/3`. Same change: dispatch a Command instead of an Invocation. Reads come from projection queries instead of `Kind.get_slice/2` (§5).
- CLI `mix ezagent.*` tasks. Same dispatch change. Reads from projection tables.
- HTTP plug controllers (e.g. `EzagentWeb.SessionController.create`). Same.
- The `URI`-based addressing model. Aggregate UUIDs ARE the canonical URI strings; no new addressing scheme.
- Capability semantics. The cap struct + matcher are unchanged. The check moves from `Kind.Runtime` step 5.5 to a pre-dispatch pipeline (§4.5).
- The Behavior contract surface visible to plugin authors stays *substantively* the same — they declare a Kind (now an Aggregate), state (now event-derived), actions (now commands), invoke logic (now `execute/2` returning events + `apply/2` returning new state). The interface(s) differ syntactically but the mental model is preserved (§4.2 maps each callback).

### 2.4 What MUST change (the internals)

- `Ezagent.Kind.Server` is retired per-Kind on migration. The shared GenServer is replaced by `Commanded.Aggregates.Aggregate` processes managed by Commanded's `AggregateRegistry`.
- `Ezagent.Kind.Snapshot` is retired per-Kind on migration. Commanded's snapshot store (Postgres-backed, configured via `snapshot_every:`) replaces it.
- `Ezagent.Audit.Writer` (the `invocations` SQLite table) is retired for domain events; the event stream IS the audit log. Non-domain telemetry (denied authz, persistence-failure, cross-cutting boot/teardown) stays in the SQLite audit table (§4.7).
- `Ezagent.Invocation.dispatch/1` is retired as the public dispatch entry. Replaced by `Ezagent.CommandedApp.dispatch/2`. The 12-step flow becomes a 5-step pre-dispatch pipeline + Commanded's aggregate hosting (§4.5).
- `Ezagent.KindRegistry` is retired per-Kind on migration. Aggregate lookup is handled by Commanded internally; cross-Kind references go through events + sagas, not registry lookups.
- `Ezagent.SpawnRegistry` is retired per-Kind on migration. "Spawn" becomes "first command at aggregate ID creates it" — the aggregate doesn't exist until the create command applies; subsequent create commands fail deterministically.
- `Ezagent.PendingDelivery` is retired post-Phase-10-A (the not-yet-ready buffer pattern). Aggregates don't have a `:not_ready` state in the same sense — they're either created (history non-empty) or not (history empty); a dispatch against a non-created aggregate either creates it (per the `execute/2` clause for empty state) or fails with the aggregate's "not created" error.
- `Ezagent.Persistence.scope_by_workspace/2` and `workspace_uri_for/1` stay — they apply to PROJECTION tables now, not slice writes. The workspace isolation invariant is enforced in projectors + read queries.

### 2.5 Decision boundary — what this SPEC does and does not commit to

This SPEC commits to:
- Adopting Commanded + EventStore as the future state model.
- The 4-phase migration plan in §6 (Phase 10-A through 10-D), with explicit unwind at each phase boundary.
- The mapping table in §4.4 from current Kinds to Aggregates + the cross-Kind workflow inventory in §4.4.2 that defines which Process Managers exist post-migration.
- The dev-loop story (in-memory adapter for fast tests; Postgres for dev + prod). See §7.3.
- The audit decomposition in §4.7 — domain events go to event store, telemetry-only events stay in SQLite.

This SPEC explicitly does NOT commit to:
- The exact event schema for each Aggregate (per-Aggregate impl SPECs in Phase 10-B through 10-D).
- The exact projection table shape for each read-model (impl-time decisions per phase).
- Whether process managers run in-process with the Commanded Application or in a sibling supervisor (§10 OQ-5).
- Snapshot-every-N tuning per Aggregate (default = 50, override per-Aggregate where benchmarks justify it).
- The exact CLI / LV form changes for any command (per existing CLI ↔ LV isomorphism invariant in `IMPLEMENTATION_ROADMAP.md` §1.4; preserved post-migration but the specific binding details land in impl PRs).

---

## 3. Phoenix + Commanded hybrid integration — the critical research question

This is the section Allen specifically flagged for depth. The integration is **not novel** (production references in §3.6) but the patterns are subtle. The whole point of CQRS is the asymmetry between write-path (commands dispatched to aggregates, events persisted) and read-path (projections queried). LiveView and Phoenix.Channel sit on BOTH paths. This section enumerates each interaction.

### 3.1 The "Phoenix at the edges, Commanded at the core" pattern

The canonical pattern across Conduit, gift-card-demo, segment-challenge, and Honeydew is:

```
                       ┌─────────────────────────────┐
                       │  EXTERNAL TRANSPORT          │
                       │  (HTTP / WS / LV / CLI / MCP)│
                       └──────────────┬──────────────┘
                                      │
                                      ▼  (constructs %Cmd{})
                       ┌─────────────────────────────┐
                       │  PRE-DISPATCH PIPELINE       │
                       │  - authn (already happens)   │
                       │  - authz (CapBAC step 5.5)   │
                       │  - workspace isolation 5.6   │
                       │  - idempotency check         │
                       │  - URI canonicalization      │
                       └──────────────┬──────────────┘
                                      │
                                      ▼  Ezagent.CommandedApp.dispatch(cmd, opts)
                       ┌─────────────────────────────┐
                       │  COMMANDED.APPLICATION       │
                       │  Router → :identify by id    │
                       └──────────────┬──────────────┘
                                      │
                                      ▼
                       ┌─────────────────────────────┐
                       │  AGGREGATE                   │
                       │  execute(state, cmd)         │
                       │   → [event(s)] | error       │
                       │  apply(state, event)         │
                       │   → new_state                │
                       └──────────────┬──────────────┘
                                      │
                                      ▼  events appended to event store
                       ┌─────────────────────────────┐
                       │  EVENT STORE (Postgres)      │
                       └──────────────┬──────────────┘
                                      │
                ┌─────────────────────┼─────────────────────┐
                │                     │                     │
                ▼                     ▼                     ▼
        ┌──────────────┐    ┌──────────────┐      ┌──────────────┐
        │ PROJECTOR    │    │ PROCESS MGR  │      │ HANDLER      │
        │ Ecto.Multi   │    │ saga state + │      │ side effects │
        │ updates      │    │ emits cmds   │      │ (notifs, fan │
        │ read tables  │    │              │      │  out, etc.)  │
        └──────┬───────┘    └──────┬───────┘      └──────────────┘
               │                   │
               ▼                   ▼
       ┌─────────────┐     ┌─────────────┐
       │  LV / API   │     │  AGGREGATE  │
       │  reads from │     │  (follow-up │
       │  read table │     │   command)  │
       └─────────────┘     └─────────────┘
```

Phoenix.Channel and LiveView sit at the top (write-side, constructing commands) and the bottom (read-side, querying projections). Commanded owns the middle. Plugin authors write commands, events, aggregates, projectors, and process managers — they never touch the event store directly.

### 3.2 LiveView write-path — handle_event/3 → dispatch

The reference pattern from `gift-card-demo/lib/gift_card_demo/gift_cards.ex`:

```elixir
defmodule GiftCardDemo.GiftCards do
  alias GiftCardDemo.AppRouter
  alias GiftCardDemo.GiftCard.Commands.{IssueGiftCard, RedeemGiftCard}

  def issue_gift_card(amount) do
    command = %IssueGiftCard{id: UUID.uuid4(), amount: amount}
    AppRouter.dispatch(command)
  end

  def redeem_gift_card(id, amount) do
    command = %RedeemGiftCard{id: id, amount: amount}
    AppRouter.dispatch(command)
  end
end
```

LiveView's `handle_event/3` calls `GiftCards.issue_gift_card(amount)`. The function constructs a Command struct and dispatches. No direct EventStore access; no manual event emission; the aggregate's `execute/2` decides what events fire.

**For ezagent**, the equivalent context module is per-Domain (one per `apps/ezagent_domain_*`) — `Ezagent.Domain.Chat.create_session(...)`, `Ezagent.Domain.Identity.grant_cap(...)`, etc. Each context function:
1. Builds a `%Cmd{}` struct with the canonical aggregate URI as `:id`.
2. Calls `Ezagent.CommandedApp.dispatch(cmd, opts)` with opts derived from the caller's intent (`consistency: :strong` for read-after-write paths; `:eventual` otherwise — see §3.3).
3. Returns `:ok` / `{:error, reason}`.

The pre-dispatch pipeline (§4.5) wraps `Ezagent.CommandedApp.dispatch/2` so authz, workspace isolation, idempotency, and URI canonicalization happen ONCE at the boundary, not in every domain context function.

### 3.3 Read-after-write consistency — THE critical question

When LiveView `handle_event` dispatches a command and then re-renders, will the re-render see the new state?

**Three modes Commanded supports:**

**(a) `consistency: :eventual` (default).** Dispatch returns `:ok` as soon as the event is persisted. Projectors run asynchronously. LiveView's re-render fires immediately on dispatch return — but the projection table may not yet reflect the change. The next push from PubSub or projector `after_update/3` triggers a follow-up render with the new state. UX: a momentary stale read; users see the change within a typical 1-10ms projector latency.

**(b) `consistency: :strong`.** Dispatch blocks until ALL projectors flagged `consistency: :strong` have committed. LiveView's re-render after dispatch sees the new state synchronously. Cost: dispatch latency = event-append (5-50ms) + slowest strong projector commit (typically another 5-20ms). For dispatches that fan out to multiple strong projectors, the bound is max of them. ([hexdocs Commands.md](https://hexdocs.pm/commanded/Commanded.Commands.Router.html))

**(c) `consistency: [ProjectorA, ProjectorB]`.** Block until specific named projectors catch up. The middle ground: synchronous wait for only the projectors that feed THIS LiveView, async for everything else.

**ezagent's choice — per dispatch site, default `:eventual`, opt-in `:strong`:**

The default for `Ezagent.CommandedApp.dispatch/2` is `consistency: :eventual` because the majority of dispatches (chat send, audit-only writes, fanout-style mutations) do not require read-after-write at the dispatch site. The dispatch site opts into `:strong` (or named-projector-list) when:

- The same LiveView render reads back the projection it just updated (e.g. create_session → wizard redirects to /sessions/X and renders the session detail — the detail projection must be present).
- A CLI command prints the resulting state to stdout (deterministic CLI return).
- A controller responds 201 with the created resource's projection state.

The opt-in mechanism is explicit at the dispatch site: `Ezagent.CommandedApp.dispatch(cmd, consistency: :strong)`. Defaulting to `:eventual` keeps the hot path fast; the LV/PubSub pattern (3.4) makes the eventual case nearly invisible to users.

**Process-manager-emitted commands always use `:eventual`** — the saga is itself an event subscriber, so by the time it dispatches a follow-up command, the originating event has already persisted; blocking on strong consistency between saga-internal steps would deadlock with the saga's own event subscription.

### 3.4 LiveView read-path — subscribe to projections, not events

The reference pattern from gift-card-demo:

```elixir
defmodule GiftCardDemoWeb.GiftCardSummaryLive do
  use Phoenix.LiveView
  alias GiftCardDemo.GiftCards

  def mount(_session, socket) do
    if connected?(socket), do: GiftCards.subscribe()
    {:ok, fetch(socket)}
  end

  def handle_info({:gift_card_summary, %GiftCardSummary{}}, socket) do
    {:noreply, fetch(socket)}
  end

  defp fetch(socket) do
    assign(socket, gift_cards: GiftCards.list_gift_cards())
  end
end
```

And in the projector:

```elixir
project %GiftCardIssued{...} = event, fn multi -> ... end

def after_update(_event, _metadata, %{gift_card_summary: summary}) do
  Registry.dispatch(Registry.GiftCardSummary, :gift_card_summary, fn entries ->
    for {pid, _} <- entries, do: send(pid, {:gift_card_summary, summary})
  end)
end
```

**The flow:**
1. LV `mount/3` subscribes to a per-projection Registry topic.
2. LV initial render reads the projection table directly (sync DB query).
3. Projector's `after_update/3` callback (a `commanded_ecto_projections` hook) fans out the updated row to all subscribers.
4. LV `handle_info` re-fetches + re-renders.

**For ezagent**, we replace `Registry` with `Phoenix.PubSub` (already used elsewhere in the codebase; uniform topic naming). Per-Aggregate-class projector defines a topic like `"ezagent:projections:user:#{user_uri}"` and broadcasts on `after_update/3`. LV subscribes during mount.

The pattern is symmetric across all 5 Kinds — User, Session, Agent, Workspace, Worker — each gets a projector + a PubSub topic; LV subscribes per the URIs it's rendering.

**The cold-load problem.** When LV mounts and the projection has not yet caught up to the LATEST events (a race window because the LV mount runs in parallel with the projector subscription), the initial render shows stale state. Two solutions:

- **`Commanded.Subscriptions.wait_for/3`** — the LV mount blocks on a specific aggregate UUID + version until the projector catches up. Slightly more synchronous than the standard pattern but eliminates the stale-mount window when the LV is mounted RIGHT AFTER a dispatch (e.g. wizard redirect-then-mount).
- **Dispatch-then-mount-with-aggregate-version** — the dispatching code passes the `:aggregate_version` from the dispatch result through the redirect URL or session; the LV mount waits for THAT specific version before rendering. This is the gift-card-demo pattern, scaled up.

For ezagent, the standard LV pattern uses `consistency: :strong` on the dispatch that precedes the redirect; the destination LV mounts AFTER the dispatch returns, so the projection is guaranteed to be caught up at mount time. The wait_for/3 helper exists as a fallback for cross-tab races (user opens detail page in tab 2 while tab 1 is dispatching).

### 3.5 Phoenix.Channel write-path (CLI, agent_bridge, feishu)

Phoenix.Channel `handle_in/3` is structurally identical to LV `handle_event/3` — it constructs a command and dispatches. The only difference is the reply mechanism:

- **LV** — re-render is triggered automatically by `assign/2`; the user sees the result in HTML.
- **Channel** — `handle_in/3` returns `{:reply, {:ok, payload}, socket}` and the JS client (cli, agent_bridge) receives the reply. The dispatch result (typically `:ok` or `{:ok, %ExecutionResult{}}`) is serialized into the channel payload.

For commands whose dispatch site needs to return data to the caller (e.g. CLI `mix ezagent.user.token --mint` prints the minted token):
- The dispatch uses `consistency: :strong` (so the token is in the read model).
- The dispatch site queries the read model immediately after dispatch returns.
- The dispatch result + read-model row are returned together to the channel.

There is no `Behavior.invoke/4`-style return-value-in-the-event-itself pattern in Commanded — events are facts about the past, not return values. If the caller needs a return value, the return is derived from the read model AFTER dispatch.

### 3.6 Production references

| Project | Stack | Notes | URL |
|---|---|---|---|
| **Conduit** | Phoenix + Commanded | RealWorld example app (Medium clone); mature; demonstrates router, aggregates, projectors, process managers, Phoenix views | https://github.com/slashdotdash/conduit |
| **Gift-card-demo** | Phoenix LiveView + Commanded | Smaller, LV-focused; shows projection-via-Registry pattern + `after_update/3` hook | https://github.com/slashdotdash/gift-card-demo |
| **Segment Challenge** | Phoenix + Commanded | Production app for Strava competitions; larger-scale aggregate inventory | https://github.com/slashdotdash/segment-challenge |
| **Honeydew** | Phoenix LiveView + Commanded + Postgres ("CELP stack") | Starter template; demonstrates standard wiring | https://github.com/quarterpi/honeydew |
| **Casavo (medium post)** | Production company | Uses Commanded + LiveView for monitoring/debug tools sitting on top of event store; demonstrates "LiveView as event-store observer" pattern (we will use the same for `/admin/events` page) | https://medium.com/casavo/supercharging-our-event-sourcing-capabilities-with-phoenix-liveview-c4a9d1d4ab99 |
| **ElixirMerge guide** | Walkthrough | EventStoreDB + Phoenix + LiveView CQRS/ES guide | https://elixirmerge.com/p/comprehensive-guide-to-implementing-es-cqrs-with-eventstoredb-phoenix-and-liveview |
| **Cantido blog post** | Phoenix LV event-sourced | LV subscribes to `$all` event stream + push_event to JS hook for high-frequency render | https://dev.to/cantido/phoenix-liveview-but-event-sourced |
| **Christian Alexander blog post** | Phoenix API + Commanded | Read-after-write strong-consistency pattern walkthrough | https://christianalexander.com/2022/05/09/elixir-commanded/ |

**Verdict on maturity:** the integration is established; reference apps exist; community has Q&A on ElixirForum dating back to 2018. Not pioneering. The "Phoenix at the edges, Commanded at the core" pattern is the de-facto standard. ezagent is well within the precedented use-cases.

### 3.7 Failure modes — what can go wrong

| Failure | Cause | Recovery | SPEC §reference |
|---|---|---|---|
| **Aggregate process crashes mid-replay** | A corrupted event in the stream OR a bug in `apply/2` raises during state reconstruction | Commanded's `AggregateRegistry` restarts the aggregate; replay resumes from the last snapshot. If the bug is in `apply/2`, the crash loops until the code is fixed. Pin: snapshot every N events bounds the replay scope so a code fix immediately recovers (replay starts from the snapshot, not from event 0). | §4.4 + §6 Phase 10-A |
| **EventStore Postgres outage** | DB down | `dispatch/2` returns `{:error, _}`. Caller treats this as transient failure (retry policy). Aggregates in-memory state survives; on Postgres recovery, dispatch resumes. Sagas pause (their subscription stops receiving events); on recovery they resume from the last processed event. | §7.4 + §8 |
| **Saga partial failure** | Process Manager's `handle/2` returns a command that the target aggregate rejects | Saga's `error/3` callback decides: retry-with-backoff, compensate (dispatch reverse command), skip-and-continue, or stop. The compensation logic is explicit code in the saga; no framework auto-rollback. | §3.8 destroy cascade specifically |
| **New event type added to existing aggregate** | Code adds a new event variant the aggregate now emits | `apply/2` MUST have a clause for the new event. The aggregate's `behaviors/0`-equivalent list (the aggregate module itself) is the source of truth; the new event is also added to the projector's `project` clauses. | §10 OQ-3 + §11 q#6 — event schema evolution |
| **Old event type removed** | Code stops emitting a type that's in historical streams | `apply/2` MUST still have a clause for the historical event (replay needs it). The clause can be a no-op if the field is no longer relevant; the event itself is not deleted from history. | §10 OQ-3 |
| **Field added to existing event** | Need to add `caller_metadata` to `MessagesPosted` events | `Commanded.Event.Upcaster` impl runs at event-read time, transforming old events into the new shape before they reach `apply/2`. Historical events stay byte-identical on disk; in-memory shape is upgraded. | §10 OQ-3 |
| **Projection drift from aggregate** | Projector has a bug, write the wrong column | Rebuild from event stream: stop projector → truncate projection table → restart projector with `start_from: :origin`. Cost: O(events) replay; bounded by `snapshot_every` for aggregate snapshots but not for projections (projection replay reads the full stream). For our scale, projection replay is minutes not hours. | §7.4 + §8 |
| **Hot aggregate with 10K+ events** | A heavily-used Session aggregates 10K MessagesPosted over its lifetime | Snapshot every 50 events bounds replay to ≤50 events on cold start; warm aggregates stay in memory. Worst-case replay = ~50 events × `apply/2` latency (μs each) ≈ 1ms. | §7.2 |
| **Two writers race on same aggregate** | Concurrent LV + CLI both dispatch a command for the same aggregate UUID | Commanded serializes per aggregate (one process per UUID); the second command queues behind the first. Optimistic concurrency error only if explicit `expected_version` is set (which we don't for ezagent — we accept implicit serialization). | §4.5 |
| **Event store schema breaking change** | Commanded major version upgrade introduces event store table changes | Upgrade migration runs against Postgres; events are NOT rewritten (the event payload is JSON, schema-flexible); only the surrounding metadata columns change. Read [commanded changelog](https://hexdocs.pm/commanded/changelog.html) before each upgrade. | §7.4 |

### 3.8 Saga compensation pattern for the destroy cascade (the original trigger)

The destroy cascade from SPEC #440, expressed as a Process Manager:

```elixir
defmodule Ezagent.Saga.DestroyAgentSaga do
  use Commanded.ProcessManagers.ProcessManager,
    application: Ezagent.CommandedApp,
    name: "DestroyAgentSaga"

  # r3 fix (HIGH-7): defstruct includes the pre-destroy snapshot fields.
  defstruct [
    :agent_uri, :workspace_uri, :step,
    :pre_destroy_caps,         # captured at step 0 from agent_caps_projection
    :pre_destroy_sessions,     # captured at step 0 from session_members_projection
    :pre_destroy_lineage_parent, # captured at step 0 from agent_lineage_projection
    :caps_revoked,
    :children_destroyed
  ]

  # Starts on AgentDestroyRequested event (emitted by Agent aggregate
  # when it accepts a Destroy command).
  def interested?(%AgentDestroyRequested{agent_uri: uri}), do: {:start, uri}

  # Continues for each follow-up event the saga emits commands for.
  # r3 — added DestroyPreSnapshotCaptured as the step 0 follow-up.
  def interested?(%DestroyPreSnapshotCaptured{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentCapsRevoked{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentChildrenDestroyed{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentMembershipsDropped{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentLineageUnlinked{agent_uri: uri}), do: {:continue, uri}
  def interested?(%AgentTerminated{agent_uri: uri}), do: {:stop, uri}

  # Step 0 (r4 — HIGH-8 fix): capture the pre-destroy state from the
  # AUTHORITATIVE aggregate state, NOT from projections (which are
  # eventually consistent — stale-by-design baseline). The aggregate's
  # `execute/2` for %CaptureDestroyPreSnapshot{} reads from the aggregate's
  # OWN state struct (the aggregate's `caps: MapSet.t()`,
  # `lineage_parent_uri`, `sessions: MapSet.t()` fields — all hydrated from
  # the aggregate's own event history at aggregate-load time; no projection
  # lag concern).
  #
  # The emitted %DestroyPreSnapshotCaptured{} event payload carries the
  # snapshot. The aggregate's apply/2 writes them into the aggregate's
  # state (so future compensation reads see them); the saga also captures
  # them into PM state for fast lookup at error/3 compensation time.
  def handle(%__MODULE__{step: nil}, %AgentDestroyRequested{} = ev) do
    %CaptureDestroyPreSnapshot{agent_uri: ev.agent_uri}
  end

  # Aggregate-side execute/2 clause (in Ezagent.Aggregate.Agent):
  #
  #   def execute(%__MODULE__{} = aggregate, %CaptureDestroyPreSnapshot{} = _cmd) do
  #     %DestroyPreSnapshotCaptured{
  #       agent_uri:        aggregate.uri,
  #       caps:             aggregate.caps,                  # authoritative — from aggregate own state
  #       sessions:         aggregate.sessions,              # authoritative
  #       lineage_parent:   aggregate.lineage_parent_uri     # authoritative
  #     }
  #   end

  # Step 1: Revoke all caps held by this agent. Now driven by the
  # DestroyPreSnapshotCaptured event (step 0's emission) — saga state
  # captures the snapshot into its own fields for fast compensation lookup.
  def handle(%__MODULE__{step: :pre_snapshotted}, %DestroyPreSnapshotCaptured{} = ev) do
    %RevokeAllCapsHeldBy{agent_uri: ev.agent_uri}
  end

  # Step 2: After caps revoked, destroy child agents (lineage cascade).
  def handle(%__MODULE__{step: :caps_revoked} = pm, %AgentCapsRevoked{}) do
    case Ezagent.Projection.AgentLineage.children_of(pm.agent_uri) do
      [] -> %SkipChildrenDestruction{agent_uri: pm.agent_uri}
      children -> %DestroyChildAgents{agent_uri: pm.agent_uri, children: children}
    end
  end

  # Step 3: Drop session memberships.
  def handle(%__MODULE__{step: :children_destroyed} = pm, %AgentChildrenDestroyed{}) do
    %DropAllSessionMembershipsFor{agent_uri: pm.agent_uri}
  end

  # Step 4: Unlink lineage.
  def handle(%__MODULE__{step: :memberships_dropped} = pm, %AgentMembershipsDropped{}) do
    %UnlinkLineage{agent_uri: pm.agent_uri}
  end

  # Step 5: Terminate the aggregate (final).
  def handle(%__MODULE__{step: :lineage_unlinked} = pm, %AgentLineageUnlinked{}) do
    %TerminateAgent{agent_uri: pm.agent_uri}
  end

  # State machine — track step progression.
  def apply(%__MODULE__{} = pm, %AgentDestroyRequested{} = ev),
    do: %{pm | agent_uri: ev.agent_uri, workspace_uri: ev.workspace_uri, step: :requested}

  # r3: step 0 snapshot writes into saga PM state for fast compensation read.
  def apply(%__MODULE__{} = pm, %DestroyPreSnapshotCaptured{} = ev),
    do: %{pm |
      step: :pre_snapshotted,
      pre_destroy_caps: ev.caps,
      pre_destroy_sessions: ev.sessions,
      pre_destroy_lineage_parent: ev.lineage_parent
    }

  def apply(pm, %AgentCapsRevoked{}), do: %{pm | step: :caps_revoked, caps_revoked: true}
  def apply(pm, %AgentChildrenDestroyed{}), do: %{pm | step: :children_destroyed, children_destroyed: true}
  def apply(pm, %AgentMembershipsDropped{}), do: %{pm | step: :memberships_dropped}
  def apply(pm, %AgentLineageUnlinked{}), do: %{pm | step: :lineage_unlinked}

  # Error / compensation (r2 — explicit reverse-commands per step,
  # mirroring `apps/ezagent_domain_chat/lib/ezagent_domain_chat.ex:189`
  # session-create rollback and `apps/ezagent_core/lib/ezagent/behavior/sandbox.ex:240`
  # sandbox-destroy cleanup patterns).
  #
  # Per-step compensation contract (r2 — every step documents):
  #   (a) idempotency: command's `execute/2` returns `{:error, :no_op}` if already done
  #   (b) residue on failure: what partial state would persist if the step half-applied
  #   (c) reverse command: the explicit undo command for compensation
  #   (d) resume behavior: whether the saga resumes from this step or compensates back
  #
  # Step contracts:
  #   Step 1 RevokeAllCapsHeldBy — idempotent (revoke of absent cap is no-op);
  #     residue: partially-revoked caps; reverse: %RestoreCapsHeldBy{caps_snapshot}.
  #   Step 2 DestroyChildAgents — idempotent (each child destroy is itself a saga);
  #     residue: some children destroyed, some not; reverse: NO inverse possible
  #     (child destruction emits events that cannot be unwound) — failure here is
  #     non-compensable; transitions to :stop_with_residue.
  #   Step 3 DropAllSessionMembershipsFor — idempotent;
  #     residue: partial leaves; reverse: %RejoinSessionsAs{sessions_snapshot}.
  #   Step 4 UnlinkLineage — idempotent;
  #     residue: orphan child URIs (no parent ref); reverse: %RelinkLineage{parent_uri}.
  #   Step 5 TerminateAgent — idempotent (already-destroyed → :no_op);
  #     residue: aggregate marked destroyed?; reverse: NO inverse (destroyed? is sticky).
  #
  # The pre-step snapshot is captured at saga start in the PM state as
  # `pre_destroy_caps`, `pre_destroy_sessions`, `pre_destroy_lineage_parent`
  # — populated by reading projections in step 0 BEFORE step 1's command dispatches.

  def error({:error, :no_op}, _cmd, _ctx) do
    # Idempotent re-run — command already done. Continue.
    {:skip, :continue_pending}
  end

  def error({:error, :agent_not_found}, _cmd, _ctx) do
    # Aggregate never existed (or already fully destroyed via another path).
    {:skip, :discard_pending}
  end

  # Step-specific compensation. Each `error/3` clause matches `failed_message`
  # to dispatch the explicit reverse command + continue with a tombstone marker.
  def error({:error, reason}, %RevokeAllCapsHeldBy{} = _cmd, %{context: %{retries: n}} = ctx)
      when n >= 2 do
    # Step 1 failed twice — compensate by restoring snapshot caps then stop.
    {:continue, [%RestoreCapsHeldBy{
       agent_uri: ctx.pm.agent_uri,
       caps_snapshot: ctx.pm.pre_destroy_caps,
       reason: reason
     }],
     %{ctx | context: Map.put(ctx.context, :compensated, true)}}
  end

  def error({:error, _reason}, %DestroyChildAgents{} = _cmd, %{context: %{retries: n}})
      when n >= 2 do
    # Step 2 is non-compensable (per contract above) — stop with residue,
    # operator inspects via /admin/sagas and resolves manually.
    {:stop, :step2_non_compensable_residue}
  end

  def error({:error, reason}, %DropAllSessionMembershipsFor{} = _cmd, %{context: %{retries: n}} = ctx)
      when n >= 2 do
    {:continue, [%RejoinSessionsAs{
       agent_uri: ctx.pm.agent_uri,
       sessions_snapshot: ctx.pm.pre_destroy_sessions,
       reason: reason
     }],
     %{ctx | context: Map.put(ctx.context, :compensated, true)}}
  end

  def error({:error, reason}, %UnlinkLineage{} = _cmd, %{context: %{retries: n}} = ctx)
      when n >= 2 do
    {:continue, [%RelinkLineage{
       agent_uri: ctx.pm.agent_uri,
       parent_uri: ctx.pm.pre_destroy_lineage_parent,
       reason: reason
     }],
     %{ctx | context: Map.put(ctx.context, :compensated, true)}}
  end

  def error({:error, _failure}, _cmd, %{context: ctx}) do
    # Generic retry with backoff for the first 2 attempts.
    {:retry, 1_000, Map.update(ctx, :retries, 1, &(&1 + 1))}
  end
end
```

**Step-failure invariant tests (r2 — Phase 10-C gates):**
- Inject step-1 failure → assert `RestoreCapsHeldBy` event lands + aggregate cap set == pre-destroy snapshot.
- Inject step-2 failure → assert saga halts in `:stop_with_residue` + operator-visible audit row exists.
- Inject step-3 failure → assert `RejoinSessionsAs` events land for every session in snapshot.
- Inject step-4 failure → assert lineage parent ref is restored.
- Replay test: full happy-path destroy → step-5 success → aggregate `destroyed?: true`.

**What this resolves vs the SPEC #440 destroy_log table approach:**

| SPEC #440 r4 (destroy_log table) | This SPEC (DestroyAgentSaga) |
|---|---|
| Hand-rolled append-only side-table | Event stream (already append-only by definition) |
| Hand-rolled reconciler that resumes on boot | Saga subscription resumes from last-processed event automatically |
| Hand-rolled "is this step idempotent" discipline per behavior | Each step is a command to a specific aggregate; aggregate handles its own idempotency (`{:error, :already_destroyed}` on repeated destroy) |
| Hand-rolled partial-failure compensation | `error/3` callback + `{:retry, ...}` / `{:stop, ...}` framework primitives |
| Hand-rolled audit row for "destroy cascade progressed to step N" | Each step emits a domain event; the saga state IS the cascade audit |

The destroy cascade becomes ~100 lines of saga code + per-aggregate command/event variants. The framework owns the "atomic" property (atomic w.r.t. each step boundary, with explicit compensation between steps).

### 3.9 Open questions specific to Phoenix integration

These bubble up to §11 codex review:

- Does our LV codebase use enough `assign_new/3` and per-tab session state that we can safely make the read-path projection-driven? (Yes — current LVs already wrap `Kind.get_slice/2` in `assign/2`; the substitution is mechanical.)
- Do we have any code paths that READ FROM the slice DURING a Behavior.invoke/4 of a DIFFERENT Kind (cross-Kind read inside dispatch)? (Yes — `Behavior.Identity.check_grant_authorized` reads the owner URI's slice. Post-migration, this must read from a projection or query the target aggregate via a fresh dispatch — see §11 q#5.)
- Are there places where the audit table's `invocations` rows are queried by SQL with predicates (workspace_uri, time range)? (Yes — `/admin/audit` LV. Post-migration, audit queries against domain events become event-stream filter operations OR queries against an `audit_events` projection table. §4.7 + §11 q#8.)

---

## 4. Mapping current ezagent architecture → CQRS

### 4.1 Concept-by-concept mapping

| Current | New | Migration notes |
|---|---|---|
| `Ezagent.Kind` behaviour module | `Commanded.Aggregates.Aggregate` behaviour-implementing module | Kind module's `type_name/0` / `behaviors/0` / `persistence/0` callbacks → aggregate's `execute/2` / `apply/2` callbacks. `behaviors/0` (the list of Behaviors a Kind composes) is encoded by aggregate's per-event `apply/2` clauses — one clause per event emitted by any of the former behaviors. |
| `Ezagent.Behavior.X` modules with `actions/0` + `invoke/4` | Per-Behavior namespace of Command modules + Event modules + a per-Aggregate `execute/2` clause | E.g. `Behavior.Chat.actions == [:send, :join, :leave]` becomes `Behavior.Chat.Commands.SendMessage`, `JoinSession`, `LeaveSession` + matching `MessagesPosted`, `MemberJoined`, `MemberLeft` events. The dispatch routes the command to the Session aggregate, which has `execute/2` clauses for each command. |
| Per-Kind slice state (`state.state[behavior.state_slice()]`) | Aggregate state struct | The Kind GenServer's `state.state` map of slices becomes the Aggregate's `defstruct` fields. No more "slice key" — every field is just a struct field on the aggregate. |
| `Ezagent.Kind.Snapshot.save_now/3` (sync `:on_change`) | Commanded snapshot-every-N (Postgres-backed) | Default `snapshot_every: 50` events. Per-Aggregate override where benchmarks justify it. Replaces both `:on_change` and `:periodic` strategies. `:ephemeral` becomes "no snapshot config" (replay-from-events always). `:on_terminate` becomes irrelevant (aggregates have no terminate hook in Commanded). |
| `Ezagent.Persistence` per-workspace scoping (`scope_by_workspace/2`) | Same module + same scoping, applied to projection tables | Workspace isolation invariant moves from slice writes to projection writes + read queries. The function survives unchanged; it just operates on `projections.*` tables now. |
| `Ezagent.Invocation.dispatch/1` | `Ezagent.CommandedApp.dispatch/2` (wrapped by pre-dispatch pipeline) | The 12-step flow collapses (steps 5-10 become Commanded internals); steps 1-4 + 5.5-5.6 + 11-12 stay (now in pre-dispatch pipeline + `after_dispatch` projection-trigger). |
| `Ezagent.KindRegistry` (URI → pid) | Commanded's internal aggregate registry | Direct lookups (e.g. for `Kind.get_slice/2`) are replaced by projection reads. No external callers of `KindRegistry.lookup/1` survive post-migration. |
| `Ezagent.SpawnRegistry` + `Kind.spawn/2` | Implicit (first command at aggregate ID creates it) | The "spawn" verb disappears; aggregates are created by their first creation command (`%RegisterUser{}`, `%CreateSession{}`, etc.). `{:error, {:already_started, pid}}` race becomes `{:error, :already_created}` returned deterministically by the aggregate's `execute/2`. |
| Cross-Kind cascade in imperative caller code (e.g. `EzagentDomainChat.create_session/3`'s 5-dispatch orchestration) | Process Manager (Saga) subscribing to the originating event | E.g. `SessionCreated` event triggers `GrantOwnerCapsSaga` which dispatches `GrantCap` commands; saga's error/3 handles compensation. |
| `Ezagent.Audit.Writer` writing to `invocations` SQLite table | Event stream IS the audit log (for domain events) + audit-events projection for queryable subset | Cross-cutting telemetry (denied authz, persistence failure, cc_bridge events) stays in SQLite audit; domain events move to event stream + queryable projection. See §4.7. |
| `kind_snapshots` SQLite table | Commanded snapshot store (in `eventstore` Postgres schema) | **r4 corrected:** For migrated Kinds, existing snapshot data is forward-migrated via §6.0 snapshot-import as Step 0 of each Phase. The `kind_snapshots` table becomes read-only post-import (no new writes from migrated Kinds); deletion of the table itself is gated by §6.4 preflight (drill receipt + cooldown). Snapshot data for un-migrated Kinds continues to be written during the hybrid window. |
| `Ezagent.ReadyGate` (status: `:ready` / `:not_ready` / `:unknown`) | Implicit (aggregate exists ⇔ command can be dispatched) | The `:not_ready` post-init buffering pattern becomes "first creation command must precede any other command"; subsequent commands fail until the aggregate is created. Buffering (the old `Ezagent.PendingDelivery`) is retired for migrated Kinds. |
| `Ezagent.PendingDelivery` (cast buffer for not-yet-ready Kinds) | Retired for migrated Kinds | Cast commands to non-existent aggregates fail at dispatch (`{:error, :aggregate_not_found}` or whatever Commanded returns for a uncreated-aggregate cast — see §11 q#8). |
| `Ezagent.Behavior.X.post_init/2` + `handle_continue/3` (deferred work after Kind register) | Process Manager subscribed to `AggregateCreated`-style event | The split-init pattern from `external-mirror-domain` SPEC §6.1 becomes: aggregate's creation command emits `WorkerCreated`; a `WorkerBootstrapSaga` subscribes to this event and dispatches the follow-up commands (subscribe-to-publisher etc.). |
| `Ezagent.Kind.Server.handle_call({:ezagent_get_slice, slice_key}, ...)` | Projection table query | Cross-process slice read becomes `Ezagent.Projection.X.get(uri)`. The query routes through the read-model module; no aggregate process is touched on read. |
| `Ezagent.CapabilityRegistry` + `Ezagent.BehaviorRegistry` | Stay unchanged | Cap subjects are still registered at compile/boot time; the registry is consulted in the pre-dispatch pipeline. No event-sourcing concern. |
| `@behaviour Ezagent.Behavior` + cap_subjects/0 + data_owner/1 | Stay (with semantic shift) — cap_subjects represents what commands gate via CapBAC; data_owner represents which aggregate owns the underlying data | The CapBAC chokepoint at pre-dispatch is unchanged; the cap_subject IS the command's behavior + action axis. data_owner now points to an aggregate URI rather than a Kind's owning principal. |

### 4.1.5 Complete Kind / Behavior inventory (r2 — statically generated)

r1 said "5 entity Kinds + 11 Behavior modules" — actual checkout enumeration:

**All Kind modules + their statically-verified persistence (r3 — verified per file:line):**

| Kind module | App | Persistence (actual @file:line) | Durable source | Migration target |
|---|---|---|---|---|
| `Ezagent.Entity.User` | ezagent_domain_identity | `{:snapshot, :on_change}` @ `user.ex:234` | `kind_snapshots` + `users` + `entity_profiles` + `entity_tokens` | `Ezagent.Aggregate.User` (§4.2.1) |
| `Ezagent.Entity.Session` | ezagent_domain_chat | `{:snapshot, :on_change}` @ `session.ex:48` | `kind_snapshots` + `messages`+ `message_routings` + `external_mirror_bindings` | `Ezagent.Aggregate.Session` (§4.2.3) |
| `Ezagent.Entity.Agent` | ezagent_domain_chat | `{:snapshot, :on_change}` @ `agent.ex` | `kind_snapshots` + `agent_api_keys` + `agent_lineage` (registry, not DB) | `Ezagent.Aggregate.Agent` (§4.2.2) |
| `Ezagent.Workspace` | ezagent_domain_workspace | **`:ephemeral`** @ `workspace.ex:61` (r3 corrected) | `workspaces` SQLite table via `Workspace.Store` — durable EXTERNALLY | `Ezagent.Aggregate.Workspace` (§4.2.4) reading from `Workspace.Store` at import |
| `Ezagent.Entity.AgentTemplate` | ezagent_domain_chat | `{:snapshot, :on_change}` @ `agent_template.ex:118` | `kind_snapshots` | `Ezagent.Aggregate.AgentTemplate` (§4.2.6) |
| `Ezagent.Entity.SessionTemplate` | ezagent_domain_chat | `{:snapshot, :on_change}` @ `session_template.ex:61` | `kind_snapshots` | `Ezagent.Aggregate.SessionTemplate` (§4.2.7) |
| `Ezagent.Entity.ExternalMirrorWorker` | ezagent_domain_external_mirror | **`:ephemeral`** @ `external_mirror_worker.ex:71` (r3 corrected) | NOT durable per-Kind — bindings durable on Session in `external_mirror_bindings` | `Ezagent.Aggregate.ExternalMirrorWorker` (§4.2.5) reconstructed from binding events |
| `Ezagent.Entity.System` (r1+r2 missed) | ezagent_core | **`:ephemeral`** @ `system.ex:32` (r3 added) | NOT durable — config-derived bootstrap singleton | NOT migrated as Aggregate; stays as runtime `Ezagent.Entity.System` GenServer (singleton; analogous to Pty — documented exception) |
| `Ezagent.Entity.CurlAgent` | ezagent_plugin_curl_agent | `{:snapshot, :on_change}` @ `curl_agent.ex` | `kind_snapshots` + `agent_api_keys` | flavor variant of `Aggregate.Agent` |
| `Ezagent.Entity.Echo` (r4 corrected) | ezagent_plugin_echo | **`:ephemeral`** @ `echo.ex:21` | NONE — Echo is stateless responder; no aggregate state | flavor variant of `Aggregate.Agent` with NO durable state (commands accepted but emit no state-mutating events; emits message-reply events only) |
| `Ezagent.Entity.NpAgent` (r4 corrected) | ezagent_plugin_np | **`:ephemeral`** @ `np_agent.ex:65` | NONE — NpAgent is also stateless | flavor variant of `Aggregate.Agent` with NO durable state |

**r3 clarification — `:ephemeral` Kinds with external durability:** Three Kinds declare `:ephemeral` yet have durable state — durability lives in *external* tables/registries, not `kind_snapshots`. The §6.0 import task adapts per source:
- `Workspace`: read `workspaces` rows via `Workspace.Store.list/0`; emit `%WorkspaceSnapshotImported{}` per row.
- `ExternalMirrorWorker`: read `external_mirror_bindings` rows; emit `%WorkerSnapshotImported{}` reconstructed from each binding (cursor `:earliest`; the saga reconciles forward).
- `System`: NOT migrated. Stays singleton GenServer; cross-aggregate code references it via existing facade.

**Behavior modules (24 total — statically enumerated from `find apps -path "*/behavior/*.ex"`):**

| Behavior | App | Disposition r2 |
|---|---|---|
| `Ezagent.Behavior.Identity` | ezagent_domain_identity | decomposed into per-aggregate cap commands |
| `Ezagent.Behavior.IdentityAdmin` (r3 added — `identity.ex:328`) | ezagent_domain_identity | Workspace aggregate commands + admin-shortcut helper in pre-dispatch pipeline (separate behaviour module in same file as Identity) |
| `Ezagent.Behavior.UserCredentials` | ezagent_domain_identity | User aggregate commands |
| `Ezagent.Behavior.UserTokens` | ezagent_domain_identity | User aggregate commands |
| `Ezagent.Behavior.ApiKeys` (r1 missed) | ezagent_domain_identity | Agent aggregate commands |
| `Ezagent.Behavior.WorkspaceUserAdmin` | ezagent_domain_identity | Workspace aggregate commands |
| `Ezagent.Behavior.Chat` | ezagent_domain_chat | Session aggregate commands |
| `Ezagent.Behavior.Template` (r1 missed) | ezagent_domain_chat | AgentTemplate + SessionTemplate aggregate commands |
| `Ezagent.Behavior.OrchestratorAdmin` (r1 missed) | ezagent_domain_chat | Session aggregate commands (orchestrator-scoped) |
| `Ezagent.Behavior.Publisher.SessionImpl` | ezagent_domain_chat | Session aggregate + subscriber tracking moved to projection-side runtime |
| `Ezagent.Behavior.Publisher` (interface) | ezagent_domain_external_mirror | namespace; no slice |
| `Ezagent.Behavior.ExternalMirror` | ezagent_domain_external_mirror | Session aggregate commands |
| `Ezagent.Behavior.ExternalMirrorWorker` | ezagent_domain_external_mirror | Worker aggregate commands |
| `Ezagent.Behavior.Pty` (r1 missed) | ezagent_domain_pty | stays as runtime Behavior (not durable; PTY is ephemeral per-session); decision per §4.3 |
| `Ezagent.Behavior.Workspace` | ezagent_domain_workspace | Workspace aggregate commands |
| `Ezagent.Behavior.Presence` | ezagent_core | stays slice-based (transient runtime; OQ-7) |
| `Ezagent.Behavior.Sandbox` (r4 corrected) | ezagent_core | **PRODUCTION** — `Ezagent.Entity.Agent` declares it at `agent.ex:75`. Migrate to Agent aggregate commands `%SandboxRead{}` / `%SandboxWritePath{}` / `%SandboxDestroy{}` per `sandbox.ex:86` action list. r3 incorrectly classified as test-fixture-only. |
| `Ezagent.Behavior.Lifecycle` | ezagent_core | subsumed by aggregate create/destroy commands |
| `Ezagent.Behavior.Routing` | ezagent_core | Workspace aggregate commands (routing rules durable) |
| `Ezagent.Behavior.Notifications` | ezagent_core | `Commanded.Event.Handler` (side-effect emitter) |
| `Ezagent.Behavior.CurlAgent` | ezagent_plugin_curl_agent | per-flavor Agent aggregate commands |
| `Ezagent.Behavior.Echo` | ezagent_plugin_echo | per-flavor Agent aggregate commands |
| `Ezagent.Behavior.NpAgent` | ezagent_plugin_np | per-flavor Agent aggregate commands |
| `EzagentPluginFeishu.Behavior.UserBinding` (r1 missed) | ezagent_plugin_feishu | User aggregate commands (Feishu binding state) |
| `EzagentPluginFeishu.Behavior.FeishuAllow` (r1 missed) | ezagent_plugin_feishu | Workspace aggregate commands (allow-list state) |

**Phase gate (per `feedback_completion_requires_invariant_test`):** Each phase's invariant test enumerates EVERY Behavior in its scope and asserts each has a corresponding migration target (or an explicit "stays runtime" decision). A new `Ezagent.Invariants.NoBehaviorLeftBehindTest` walks the BehaviorRegistry at Phase 10-D pre-merge and fails if any dispatchable Behavior lacks an Aggregate command mapping.

### 4.2 The 5 entity Kinds — migration target per Kind

#### 4.2.1 `Ezagent.Entity.User` → `Ezagent.Aggregate.User`

**Current state shape (slice):**
```elixir
%{
  identity: %{caps: MapSet.t(Capability.t())},
  user_credentials: %{...counter state...},
  user_tokens: %{...counter state...}
}
```

**New aggregate state (r2 — expanded to cover profile + token-hash + Feishu binding):**
```elixir
defmodule Ezagent.Aggregate.User do
  defstruct [
    :uri,             # canonical URI string — also the aggregate ID
    :workspace_uri,
    :registered_at,
    :password_hash,   # mirrors users.password_hash column

    # Profile fields (r2 fix — `apps/ezagent_domain_identity/lib/ezagent/entity/profile.ex:21`)
    :display_name,    # required per current Profile changeset
    :email,           # optional; unique-constrained

    caps: MapSet.new(),

    # Tokens — r2 expansion. Each token is the full Entity.Token schema
    # shape per `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex:43`.
    # `token_hash` is the bcrypt hash; `label` is operator-visible;
    # `last_used_at` is updated by an event-handler on each auth use.
    tokens: %{}, # token_id => %{token_hash, label, expires_at, last_used_at, minted_at}

    # Feishu binding (r2 fix — UserBinding behavior).
    feishu_binding: nil, # %{open_id, allow_status, paired_at} or nil

    destroyed?: false
  ]
  ...
end
```

**Commands (r2 — expanded):**
- `%RegisterUser{uri, workspace_uri, password_hash, display_name, initial_caps}` → emits `%UserRegistered{}`
- `%UpsertProfile{uri, display_name, email}` → emits `%ProfileUpserted{}`
- `%GrantCapToUser{uri, cap, granted_by}` → emits `%CapGrantedToUser{}` (or `{:error, :grant_not_owner}` if granter lacks data-owner cap)
- `%RevokeCapFromUser{uri, cap, revoked_by}` → emits `%CapRevokedFromUser{}`
- `%MintTokenForUser{uri, token_id, token_hash, label, expires_at}` → emits `%TokenMintedForUser{}`
- `%MarkTokenUsed{uri, token_id, used_at}` → emits `%TokenUsedByUser{}` (issued by the auth handler; updates `last_used_at`)
- `%RevokeTokenForUser{uri, token_id}` → emits `%TokenRevokedForUser{}`
- `%RotatePasswordForUser{uri, new_password_hash}` → emits `%PasswordRotatedForUser{}`
- `%BindFeishuOpenId{uri, open_id}` → emits `%FeishuOpenIdBound{}` (UserBinding behavior)
- `%UnbindFeishuOpenId{uri}` → emits `%FeishuOpenIdUnbound{}`
- `%ImportUserSnapshot{uri, snapshot_payload}` (r2 forward-migration command — see §6.0) → emits `%UserSnapshotImported{}`
- `%DestroyUser{uri}` → emits `%UserDestroyRequested{}` (which triggers `DestroyUserSaga` for cascade)

**Events** — one per command above; payload is the command minus the routing UUID.

**Projections:**
- `user_caps_projection` — Ecto table `projections.user_caps(uri, cap_json, granted_by, granted_at)`. Read by `Behavior.Identity` queries and `/admin/users` LV. `consistency: :strong` for cap-grant dispatches that need read-after-write at the LV.
- `user_profile_projection` — Ecto table `projections.user_profile(uri, workspace_uri, display_name, email, registered_at, destroyed?)`. r3 fix (HIGH-5): added `display_name` (NOT NULL — required per `entity_profiles` changeset at `apps/ezagent_domain_identity/lib/ezagent/entity/profile.ex:41`) + `email` (optional, unique). Read by the user listing LV + login flow + workspace-scoped user filters.
- `user_tokens_projection` — Ecto table `projections.user_tokens(uri, token_id, token_hash, label, scope, expires_at, last_used_at, minted_at, revoked_at, workspace_uri)`. r3 fix (HIGH-5): added `token_hash` (bcrypt hash — required for auth verification), `label` (operator-visible name), `last_used_at` (updated on each auth-handler dispatch), `workspace_uri` (per-tenant scope). Read by bearer auth + token-list admin LV.

**Field-level parity gates (r3 — HIGH-5):** §6.0 `mix ezagent.aggregate.verify --kind user` reads every row in `entity_profiles` + `entity_tokens` and asserts a matching `user_profile_projection` + `user_tokens_projection` row exists post-replay with every column equal. Any divergence blocks cutover.

**Persistence:** snapshot every 50 events. User aggregate event volume is low (one event per cap grant + one per token mint); 50 events is ~weeks of activity per active user.

#### 4.2.2 `Ezagent.Entity.Agent` → `Ezagent.Aggregate.Agent`

**Current state (slice):** complex — flavor-specific state + lineage parent_uri + api_keys + workspace_uri + per-template fork state.

**New aggregate state:**
```elixir
defmodule Ezagent.Aggregate.Agent do
  defstruct [
    :uri,
    :workspace_uri,
    :flavor,           # :cc | :codex | :curl | :np | :echo | ...
    :parent_template_uri,
    :lineage_parent_uri,
    :config_dir,
    :api_keys,         # encrypted map; api_keys behavior's slice
    caps: MapSet.new(),
    flavor_state: %{},  # per-flavor sub-state, opaque to non-flavor code
    sessions: MapSet.new(),  # session URIs this agent is a member of
    destroyed?: false
  ]
end
```

**Commands** — split into flavor-agnostic core + per-flavor extensions:

Core:
- `%CreateAgent{uri, workspace_uri, flavor, parent_template_uri, lineage_parent_uri, initial_caps, config_dir}` → emits `%AgentCreated{}`
- `%GrantCapToAgent{uri, cap, granted_by}` → emits `%CapGrantedToAgent{}`
- `%RevokeCapFromAgent{uri, cap, revoked_by}` → emits `%CapRevokedFromAgent{}`
- `%PutApiKeyForAgent{uri, key_name, encrypted_key}` → emits `%ApiKeyPutForAgent{}`
- `%JoinSessionAsAgent{uri, session_uri}` → emits `%AgentJoinedSession{}`
- `%LeaveSessionAsAgent{uri, session_uri}` → emits `%AgentLeftSession{}`
- `%DestroyAgent{uri}` → emits `%AgentDestroyRequested{}` (triggers `DestroyAgentSaga`)

Per-flavor (cc, codex, ...):
- Each flavor exposes a `%FlavorSpecific{...}` command variant; the aggregate's `execute/2` dispatches to the flavor's logic + emits a flavor-specific event. The flavor's `apply/2` clause mutates `flavor_state` opaquely.

**Projections:**
- `agent_profile_projection` — Ecto table for the listing LV.
- `agent_caps_projection` — for cap queries.
- `agent_lineage_projection` — replaces `Ezagent.AgentLineage` registry (parent/child relationships).

#### 4.2.3 `Ezagent.Entity.Session` → `Ezagent.Aggregate.Session`

**Current state:** highest complexity in the codebase — Chat slice + Publisher slice + ExternalMirror slice; members; rules; routing.

**New aggregate state (r2 — every durable Chat/Publisher slice field enumerated):**

Sourced statically from `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:144-:242` (Chat slice) + `apps/ezagent_domain_chat/lib/ezagent/behavior/publisher/session_impl.ex:150-:165` (Publisher slice) + `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex` (ExternalMirror slice).

```elixir
defmodule Ezagent.Aggregate.Session do
  defstruct [
    :uri,
    :workspace_uri,
    :template_uri,
    :owner_uri,              # PR-OWN-2 caps-data-ownership SPEC §7 — durable

    # Chat slice — durable members & message-cursor state.
    members: %{},            # %{URI => %{online: bool}} — durable (rejoin replay)
    last_seen: %{},          # %{URI => DateTime} — when each offline member last seen
    last_message_id: nil,    # stable cross-ref to MessageStore row
    last_message: nil,       # full %Ezagent.Message{} for ExternalMirror adapter purity
    send_cursor: 0,          # monotonic; bumps on every successful send (idempotent retry safety)
    recent_messages: [],     # [{slice_change_cursor, msg_id}] — PR-N3 r4 bounded ring (durable)

    # NON-durable runtime — explicitly excluded from aggregate state.
    # (Per Chat slice: `monitors: %{}` — Process.monitor refs cannot survive
    # restart and have no event-sourced equivalent. The post-Phase-10 design
    # rebuilds monitor refs by walking aggregate-`members` and re-monitoring
    # in a runtime sidecar at aggregate-load time.)

    # Publisher slice — durable ring + cursor for SliceChange replay.
    publisher_ring: [],      # bounded ring of last N events for cursor catchup
    publisher_cursor: 0,     # monotonic event cursor
    publisher_retention: 100,# per-session override (default 100; from `init_slice` arg)
    # Publisher.subscribers / monitors — NON-durable; subscriber tracking moves
    # to a sibling `Ezagent.Publisher.SubscriberRegistry` GenServer that
    # rebuilds on aggregate load by re-subscribing each `Phoenix.PubSub` topic
    # the projection broadcasts on. Per §3.4 read-path pattern.

    # ExternalMirror slice — durable binding descriptors.
    external_mirror_bindings: [], # list of %{binding_id, descriptor, adapter} maps

    # SessionTemplate working copy — durable structured map staged before
    # instantiate. r3 fix (MED-6): actual default per
    # `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:255`
    # `default_template_working_copy/0` has these 5 sub-fields:
    # r4 (MED-7): nested field names verbatim from `default_template_working_copy/0`
    # at `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:255`-`:285`.
    template_working_copy: %{
      # [{slot_name :: String.t(),
      #   source_agent_template_uri :: URI.t(),   # NOT source_template_uri (r3 was wrong)
      #   live_worker_uri :: URI.t(),
      #   generation :: non_neg_integer()}]
      agent_slots: [],
      # [{matcher_ast :: term(), [slot_name :: String.t()]}]
      routing_rules: [],
      orchestrator_template_uri: nil, # URI.t() | nil
      default_workspace_uri: nil,     # URI.t() | nil
      description: ""                  # String.t()
    },

    destroyed?: false
  ]
end
```

**Replay tests (r2 — Phase 10-B invariant tests):**
- **Rejoin replay** — a member who left at `last_seen[uri]=T1` rejoins at T2; aggregate replay reconstructs `recent_messages` ring; the JoinSession command's `execute/2` reads the ring + emits `MissedMessagesReplayed` events sized to the gap.
- **External mirror dedupe** — `send_cursor` monotonically bumps even on idempotent message_id resends so ExternalMirror's adapter sees the retry as a fresh slice_change event.
- **Publisher cursor catchup** — a cold-spawning Worker subscribes from `cursor: -100`; aggregate replay reconstructs `publisher_ring` of last 100; Worker receives them in order.

These three tests directly exercise the durable fields r1 missed; failure of any constitutes a Phase 10-B blocker.

**Commands** — many; the largest aggregate by command count.

Core lifecycle:
- `%CreateSession{uri, template_uri, owner_uri, workspace_uri}` → emits `%SessionCreated{}`
- `%DestroySession{uri}` → emits `%SessionDestroyRequested{}` (triggers `DestroySessionSaga`)

Membership (`Behavior.Chat` actions):
- `%JoinSession{uri, joiner_uri}` → emits `%MemberJoinedSession{}`
- `%LeaveSession{uri, leaver_uri}` → emits `%MemberLeftSession{}`
- `%TransferSessionOwnership{uri, new_owner_uri}` → emits `%SessionOwnershipTransferred{}`

Messaging:
- `%PostMessageToSession{uri, message}` → emits `%MessagePosted{}` (also triggers fanout-via-projection)

Publisher (`Behavior.Publisher.SessionImpl`):
- `%SubscribeToSessionPublisher{uri, subscriber_pid, cursor}` → emits `%PublisherSubscriberAdded{}`
- `%UnsubscribeFromSessionPublisher{uri, subscriber_pid}` → emits `%PublisherSubscriberRemoved{}`
- (Note: PIDs in events is a smell — see §11 q#5. Maybe subscribers are tracked outside the aggregate.)

External mirror (`Behavior.ExternalMirror`):
- `%BindExternalMirror{uri, binding_descriptor}` → emits `%ExternalMirrorBound{}`
- `%UnbindExternalMirror{uri, binding_id}` → emits `%ExternalMirrorUnbound{}`

**Projections** — many:
- `session_profile_projection` — basic session state for LV listing.
- `session_messages_projection` — replaces the current `messages` SQLite table. Each `MessagePosted` event → insert row.
- `session_members_projection` — `(session_uri, member_uri, joined_at, left_at)` for membership queries.
- `external_mirror_bindings_projection` — replaces the current `external_mirror_bindings` SQLite table.

#### 4.2.4 `Ezagent.Workspace` → `Ezagent.Aggregate.Workspace`

**Current state:** tiny — workspace metadata + ownership.

**New aggregate state:**
```elixir
defmodule Ezagent.Aggregate.Workspace do
  defstruct [
    :uri,
    :name,
    :created_by,
    :created_at,
    members: MapSet.new(),
    destroyed?: false
  ]
end
```

**Commands:**
- `%CreateWorkspace{uri, name, created_by}` → emits `%WorkspaceCreated{}`
- `%AddMemberToWorkspace{uri, member_uri}` → emits `%MemberAddedToWorkspace{}`
- `%RemoveMemberFromWorkspace{uri, member_uri}` → emits `%MemberRemovedFromWorkspace{}`
- `%DestroyWorkspace{uri}` → emits `%WorkspaceDestroyRequested{}` (triggers `DestroyWorkspaceSaga` — cascades destroy on all sessions/agents/users in workspace; expensive)

**Projections:**
- `workspaces_projection` — for the picker LV. Replaces current `workspaces` SQLite table.
- `workspace_members_projection` — for the cap-vis SPEC's `list_workspaces_for/2`. Cap-based visibility becomes a JOIN against this + the cap projection.

#### 4.2.5 `Ezagent.ExternalMirror.Worker` → `Ezagent.Aggregate.ExternalMirrorWorker`

**Current state:** binding-specific worker state.

**New aggregate state:**
```elixir
defmodule Ezagent.Aggregate.ExternalMirrorWorker do
  defstruct [
    :uri,
    :session_uri,
    :workspace_uri,
    :binding_descriptor,
    :cursor,                # publisher cursor
    :adapter_state,         # per-adapter internal state
    destroyed?: false
  ]
end
```

**Commands:**
- `%SpawnWorker{uri, session_uri, binding_descriptor}` → emits `%WorkerSpawned{}` (triggers `BootstrapWorkerSaga`)
- `%AdvanceWorkerCursor{uri, new_cursor}` → emits `%WorkerCursorAdvanced{}`
- `%TerminateWorker{uri}` → emits `%WorkerTerminated{}`

**Projection:**
- `external_mirror_workers_projection` — live worker status + last-cursor.

#### 4.2.6 `Ezagent.Entity.AgentTemplate` → `Ezagent.Aggregate.AgentTemplate` (r2 — HIGH-4 fix)

r1 missed this. AgentTemplate is `{:snapshot, :on_change}` (durable; `apps/ezagent_domain_chat/lib/ezagent/entity/agent_template.ex:118`), carries 2 slices (Identity + Template), and serves dispatchable `:read` / `:write` / `:instantiate` actions.

**New aggregate state:**
```elixir
defmodule Ezagent.Aggregate.AgentTemplate do
  defstruct [
    :uri, :workspace_uri, :parent_template_uri,
    :template_content,  # the Template behavior's durable content
    caps: MapSet.new(),  # Identity slice
    versions: [],        # version history (template_hash, content_at_version)
    destroyed?: false
  ]
end
```

**Commands:** `%CreateAgentTemplate{}`, `%WriteAgentTemplate{}`, `%ForkAgentTemplate{new_uri, parent_uri}`, `%GrantCapToAgentTemplate{}`, `%InstantiateAgentTemplateAsAgent{}` (triggers `InstantiateAgentSaga`).

**Projection:** `agent_template_profile_projection` for `/admin/templates` LV.

#### 4.2.7 `Ezagent.Entity.SessionTemplate` → `Ezagent.Aggregate.SessionTemplate` (r2 — HIGH-4 fix)

Same shape as AgentTemplate; persistence `{:snapshot, :on_change}` (`apps/ezagent_domain_chat/lib/ezagent/entity/session_template.ex:61`). Carries `update_template` / `save_template_as` / `fork` action vocabulary on top of standard Template commands.

**Distinguishing commands:** `%UpdateSessionTemplate{}` (new version of current parent), `%SaveSessionTemplateAs{new_name}` (first version of new template — parent_template_uri set), `%ForkSessionTemplate{}`.

### 4.3 The 24 Behavior modules — disposition (r2 — HIGH-4 fix)

| Behavior | Disposition | Notes |
|---|---|---|
| `Behavior.Identity` | Decomposed into per-aggregate cap-handling commands | Cap grant/revoke commands land on the relevant aggregate (User/Agent); the Behavior module becomes a namespace for the commands + the cap_subjects/0 callback for CapBAC registration. data_owner/1 callback stays (drives saga compensation paths). |
| `Behavior.Chat` | Session aggregate commands + projector | All actions become Session commands; the Behavior module becomes a namespace + cap_subjects + the message projection's update logic. |
| `Behavior.Publisher` + `Behavior.Publisher.SessionImpl` | Session aggregate commands; subscriber tracking moved to projection-side | See §11 q#5 — PID-in-event smell; subscriber tracking is a runtime concern, not an event-sourced one. |
| `Behavior.ExternalMirror` | Session aggregate commands + Worker aggregate commands | Bindings are persisted as Session events; worker spawn is a saga (BootstrapWorkerSaga subscribes to BindingCreated, dispatches SpawnWorker). |
| `Behavior.IdentityAdmin` | Workspace aggregate commands + admin-shortcut helper module | The admin-cap-bypass logic lives in the pre-dispatch authz pipeline; the commands themselves land on the Workspace aggregate. |
| `Behavior.UserCredentials` | User aggregate commands | Password rotation is a User command. The `users.password_hash` column becomes a projection. |
| `Behavior.UserTokens` | User aggregate commands | Token mint/revoke is a User command. The `entity_tokens` table becomes a projection. |
| `Behavior.WorkspaceUserAdmin` | Workspace aggregate commands | User creation as a workspace admin → `AddUserToWorkspace` command on Workspace + `RegisterUser` command on User. The two-command sequence is bundled in a saga (`CreateUserInWorkspaceSaga`). |
| `Behavior.Presence` | Stays slice-based (NOT migrated) | Presence is real-time runtime state, not durable history. Kept as-is on a non-Aggregate `Ezagent.Presence` GenServer (or moved to `Phoenix.Presence` natively). §11 q#7. |
| `Behavior.Sandbox` | Stays runtime-only | Test-fixture-only Behavior; not part of production state model. |
| `Behavior.Routing` | Routes are workspace-scoped rules, stored as Workspace aggregate state | Workspace command `AddRoutingRule` / `RemoveRoutingRule` + matching events. |
| `Behavior.Notifications` | Event handler subscribing to relevant events + emitting notifications | See §11 q#5 — notification emission is a side-effect handler, not state-mutating. `Commanded.Event.Handler` impl. |
| `Behavior.Lifecycle` | Subsumed by aggregate creation/destruction commands | Lifecycle as a Behavior disappears post-migration; each Kind's create/destroy commands replace it. |
| `Behavior.ApiKeys` (r1 missed) | Agent aggregate commands | `Behavior.ApiKeys` lives on Agent (post 2026-05-26 flip per `apps/ezagent_domain_identity/lib/ezagent/behavior/api_keys.ex:53`); becomes `%PutApiKeyForAgent{}` + matching event. The `agent_api_keys` SQLite table becomes a projection (encrypted column preserved). |
| `Behavior.Template` (r1 missed) | AgentTemplate + SessionTemplate aggregate commands | Template `:read` / `:write` / `:instantiate` actions migrate to AgentTemplate/SessionTemplate aggregates (§4.2.6 + §4.2.7). |
| `Behavior.OrchestratorAdmin` (r1 missed) | Session aggregate commands | Orchestrator admin actions on a Session (e.g. `force_join`, `eject_member`) become Session aggregate commands gated by an orchestrator-admin cap. |
| `Behavior.Pty` (r1 missed) | Stays runtime Behavior (PTY is ephemeral per-session) | Pty state is transient (PID + buffer); no event-sourced equivalent makes sense. Pty Behavior stays as a runtime sidecar; dispatches go through legacy `Invocation.dispatch/1` permanently. Documented exception to the "all Behaviors migrate" pattern. |
| `Behavior.CurlAgent` | Agent aggregate per-flavor commands | curl_agent-specific actions become per-flavor Agent commands (§4.2.2). |
| `Behavior.Echo` | Agent aggregate per-flavor commands | echo-flavor actions become per-flavor Agent commands. |
| `Behavior.NpAgent` | Agent aggregate per-flavor commands | np-flavor actions become per-flavor Agent commands. |
| `EzagentPluginFeishu.Behavior.UserBinding` (r1 missed) | User aggregate commands | Feishu binding state is durable per-user; becomes `%BindFeishuOpenId{}` / `%UnbindFeishuOpenId{}` on User aggregate (§4.2.1). |
| `EzagentPluginFeishu.Behavior.FeishuAllow` (r1 missed) | Workspace aggregate commands | Feishu allow-list is workspace-scoped durable state; becomes Workspace aggregate commands. |

### 4.4 Cross-Kind workflows — the saga inventory

Post-migration sagas that replace ad-hoc cross-Kind orchestration:

| Saga | Triggered by | Cascade |
|---|---|---|
| `DestroyAgentSaga` | `AgentDestroyRequested` | RevokeAllCapsHeldBy → DestroyChildAgents → DropAllSessionMembershipsFor → UnlinkLineage → TerminateAgent |
| `DestroyUserSaga` | `UserDestroyRequested` | RevokeAllCapsHeldBy → DestroyChildAgents (where user is parent) → DropAllSessionMembershipsFor → TerminateUser |
| `DestroySessionSaga` | `SessionDestroyRequested` | EvictAllMembers → UnbindAllExternalMirrors → DestroyAllChildAgents → TerminateSession |
| `DestroyWorkspaceSaga` | `WorkspaceDestroyRequested` | DestroyAllSessions → DestroyAllAgents → DestroyAllUsers → TerminateWorkspace (expensive — requires explicit confirm + admin caps; reuses each child's destroy saga) |
| `CreateSessionSaga` | `SessionCreated` | GrantOwnerOrchestratorAdminCap (the bug 2 path from URI canonicalization SPEC) → InvokeTemplateClassInitHooks → AnnounceSessionReady |
| `CreateUserInWorkspaceSaga` | `WorkspaceAdminRequestedUserCreate` | RegisterUser → GrantDefaultCaps → AddUserToWorkspaceMembers → MintInitialToken (optional) |
| `BootstrapWorkerSaga` | `BindingCreated` | SpawnWorker → SubscribeToSessionPublisher → AnnounceWorkerReady |
| `RevokeCapCascadeSaga` | `WorkspaceMembershipRevoked` | RevokeAllWorkspaceScopedCapsFor (the principal whose membership was revoked loses all caps scoped to that workspace) |
| `CapGrantOwnershipVerifySaga` | `CapGrantRequested` | VerifyGranterHasDataOwnerCap (via reading granter's cap projection at command-time) → either dispatch the actual grant or reject with `:grant_not_owner` |

Each saga is ~50-150 lines + the per-step command/event variants. Total saga LOC across the inventory ≈ 1500-2000 LOC. Replaces the current ~3000 LOC of ad-hoc cross-Kind orchestration in domain modules.

### 4.5 The pre-dispatch pipeline — where step 5.5 + 5.6 + idempotency move to

Current dispatch routes steps 5.5 (CapBAC) + 5.6 (workspace isolation) through `Kind.Runtime.handle_dispatch/4`, inside the Kind GenServer's `handle_call`. Post-migration, these checks happen BEFORE `Commanded.Application.dispatch/2` — in a pre-dispatch pipeline module.

```elixir
defmodule Ezagent.CommandedApp.Dispatch do
  alias Ezagent.CommandedApp

  @spec dispatch(cmd :: struct(), opts :: keyword()) ::
    :ok | {:error, term()}
  def dispatch(cmd, opts \\ []) do
    with :ok <- Ezagent.URI.canonicalize_cmd(cmd),         # step 1 — canonicalize URIs in cmd
         :ok <- check_idempotency(cmd, opts),              # step 1.5 — idempotency key check
         :ok <- check_capbac(cmd, opts),                   # step 5.5 — CapBAC chokepoint
         :ok <- check_workspace_isolation(cmd, opts),      # step 5.6 — cross-workspace deny
         :ok <- CommandedApp.dispatch(cmd, opts) do        # step 6+ — Commanded internals
      :ok
    end
  end

  defp check_capbac(cmd, opts) do
    caller = Keyword.fetch!(opts, :caller)
    caps = Keyword.fetch!(opts, :caps)
    needed = Ezagent.CapabilityRegistry.cap_for_command(cmd.__struct__)
    if Enum.any?(caps, &Ezagent.Capability.matches?(&1, needed)),
      do: :ok,
      else: {:error, :unauthorized}
  end

  defp check_workspace_isolation(cmd, opts) do
    caller_workspace = Keyword.fetch!(opts, :caller_workspace)
    target_workspace = cmd.workspace_uri  # every cmd carries workspace_uri
    if caller_workspace == target_workspace or admin?(opts),
      do: :ok,
      else: {:error, :cross_workspace_denied}
  end

  ...
end
```

Every external entry (LV, Channel, CLI, MCP) calls `Ezagent.CommandedApp.Dispatch.dispatch(cmd, opts)`. The pre-dispatch pipeline is the new chokepoint — equivalent to step 5.5 + 5.6 today.

The `Ezagent.CommandedApp.dispatch/2` (the bare Commanded application) is private to this module; nothing outside the pipeline calls it directly. Invariant test: grep for `Ezagent.CommandedApp.dispatch` outside `Ezagent.CommandedApp.Dispatch` is empty (mirror of current `single_dispatch_entry_test.exs`).

### 4.6 Aggregate ID derivation — URI canonicalization parity

Per `feedback_register_lookup_key_parity` + `feedback_uuid_is_canonical_identifier`:

- Every command MUST carry a canonical URI string in a field named `:uri` (or the relevant variant, e.g. `:agent_uri`, `:session_uri`).
- The router's `identify` clause uses this field:
  ```elixir
  identify(Ezagent.Aggregate.User, by: :uri, prefix: "")
  ```
- The canonical form is `Ezagent.URI.parse!(...) |> URI.to_string()` — same as the URI-canonicalization SPEC.
- The pre-dispatch pipeline canonicalizes the URI fields before dispatch.
- Cross-aggregate references (e.g. a Session command that references an Agent URI) carry both URIs as canonical strings.

The aggregate ID is opaque to the aggregate (it's the routing key, not state); the URI inside the aggregate state is the same canonical string. Single source of truth; no divergence between routing and state.

### 4.7 The audit log — what's a domain event vs telemetry

Two distinct concepts collapse into one `invocations` table today; they DIVERGE post-migration:

**Domain events (in event stream):**
- `UserRegistered`, `CapGrantedToUser`, `MessagePosted`, `SessionCreated`, `MemberJoinedSession`, `WorkerSpawned`, ... — every state-mutating event.
- Persisted in event store with full payload; queryable via projection (`audit_events_projection`).
- The event stream is the audit log; no separate audit writer.

**Telemetry-only events (stay in SQLite `audit` table):**
- `[:ezagent, :authz, :denied]` — the dispatch was rejected; nothing was state-mutated; not a domain event.
- `[:ezagent, :persistence, :failed]` — infra-level failure; not part of aggregate history.
- `[:ezagent, :cc_bridge, :event]` — bridge sidechannel; not state-mutating.
- `[:ezagent, :chat, :receive, :dropped]` — runtime drop; not state-mutating.
- `[:ezagent, :notification, :emit]` — side-effect emission record; not state-mutating in the source aggregate.

**Audit query patterns:**
- "What did user X do between time A and B" → query event stream for events with `metadata.caller == "X"` AND `created_at BETWEEN A AND B`. Either via Postgres event store SQL OR via `audit_events_projection` (a denormalized read model for fast querying).
- "Why was this dispatch denied" → query the SQLite `audit` table for the `[:ezagent, :authz, :denied]` row (this is NOT in the event stream because nothing happened in the domain).
- "What's the current cap set for user X" → query `user_caps_projection`.
- "What's the cap-grant history for user X" → query event stream for `CapGrantedToUser` / `CapRevokedFromUser` events filtered by `metadata.target == "X"`.

This split keeps domain events pure (only state-mutating facts; no telemetry noise in the stream) while preserving telemetry for ops + debugging.

---

### 4.8 LV / Channel / CLI write-then-immediate-read consistency matrix (r2 — HIGH-3 fix)

Codex r1 HIGH-3: r1 said "opt to :strong per dispatch site" without enumerating sites. Default `:eventual` is unsafe at any callsite that immediately re-reads state.

**Statically-enumerated write→read sites that MUST use `consistency: :strong`** (or named-projector consistency list) — file:line verified at r3:

| Callsite | File:line | Write | Immediate re-read | Required mode |
|---|---|---|---|---|
| Create user | `users_live.ex:137` | RegisterUser | `list_users()` @ `:143` | `:strong` |
| Profile upsert | `users_live.ex:177` | UpsertProfile | `list_users()` @ `:181` | `:strong` |
| Set password (r3 added) | `users_live.ex:202` | RotatePasswordForUser | `list_users()` @ `:206` | `:strong` |
| Promote to system (r3 added) | `users_live.ex:230` | AddMemberToWorkspace(system) | `list_users()` @ `:235` | `:strong` |
| Revoke from system (r3 added) | `users_live.ex:250` | RemoveMemberFromWorkspace(system) | `list_users()` @ `:253` | `:strong` |
| Add workspace member | `workspace_detail_live.ex:165` | AddMemberToWorkspace | `Workspace.Store.get_by_name/1` | `:strong` |
| Remove workspace member (r3 added) | `workspace_detail_live.ex:255`/`:273` | RemoveMemberFromWorkspace | reload members | `:strong` |
| Grant cap | `entity_caps_live.ex:142` | GrantCapToUser / GrantCapToAgent | reload caps | `:strong` |
| Add routing rule | `routing_live.ex:235` | AddRoutingRule | reload rules | `:strong` |
| Delete routing rule (r3 added) | `routing_live.ex:307` | DeleteRoutingRule | reload rules | `:strong` |
| Enable/disable routing rule (r3 added) | `routing_live.ex:308`-region | ToggleRoutingRule | reload rules | `:strong` |
| Create agent — **r3 file corrected** | `agent_new_live.ex:120` | CreateAgent | redirect→agent detail | `:strong` |
| Set api_key — **r3 confirmed exists** | `agent_api_keys_live.ex` (put handler) | PutApiKeyForAgent | reload keys list | `:strong` |
| Delete api_key (r3 added) | `agent_api_keys_live.ex:159` | DeleteApiKeyForAgent | reload keys list | `:strong` |
| Create session (wizard) | `apps/ezagent_web/lib/ezagent_web/live/home_live.ex` wizard submit | CreateSession | redirect→/sessions/X mount | `:strong` |
| Mint user token (CLI) | `apps/ezagent_domain_identity/lib/mix/tasks/ezagent.user.token.ex:75` | MintTokenForUser | print token row | `:strong` |
| Bind external mirror | feishu bind LV/CLI | BindExternalMirror | reload bindings | `:strong` |
| Workspace create | `workspaces_live.ex` | CreateWorkspace | redirect→detail | `:strong` |
| Send chat message | LV / Channel chat send | PostMessageToSession | (NO re-read; fanout via PubSub) | `:eventual` (acceptable) |

**Additional callsites (r4 — facades + admin_live + feishu sites HIGH-3 added):**

| Callsite | File:line | Facade | Required mode |
|---|---|---|---|
| Workspace add_template | `workspace_detail_live.ex:307` (facade `Ezagent.Workspace.add_template/3`) | facade-declared `@consistency :strong` | `:strong` |
| Admin create session | `admin_live.ex:804` (facade `EzagentDomainChat.create_session/3`) | facade-declared `@consistency :strong` | `:strong` |
| Admin invite session member | `admin_live.ex:1019` (facade chat join via `Behavior.Chat`) | facade-declared `@consistency :strong` | `:strong` |
| Admin session routing CRUD | `admin_live.ex:1381` | facade-declared `@consistency :strong` | `:strong` |
| Feishu user bind | `feishu_bindings_live.ex:88` (facade `EzagentPluginFeishu.bind/2`) | facade-declared `@consistency :strong` | `:strong` |
| Feishu user unbind | `feishu_bindings_live.ex:88`-region | facade-declared `@consistency :strong` | `:strong` |
| Session ExternalMirror bind | `admin/session_external_mirror_live.ex:221` (facade `ExternalMirror.bind/4`) | facade-declared `@consistency :strong` | `:strong` |
| Session ExternalMirror unbind | `admin/session_external_mirror_live.ex:221`-region | facade-declared `@consistency :strong` | `:strong` |

**The matrix is the source of truth.** Every dispatch path is assigned a consistency mode here at SPEC-time; the impl PR cannot deviate.

**Phase 10-B/10-C invariant test (r4 — dual-gate, facade-aware):**

The r3 single-AST-rule "find dispatch in handle_event" was insufficient because LV writes go through facade modules (`Ezagent.Workspace.add_template/3`, `EzagentDomainChat.create_session/3`, etc) — the LV doesn't see `Commanded.App.dispatch/2` directly. r4 splits the gate in two:

**Gate 1 — Facade declaration (write side):** Every domain-context write facade (the modules under `apps/ezagent_domain_*/` that LVs/CLI/Channel call) declares a `@consistency :strong | :eventual | {:named, [projector]}` module attribute on each public function that ends in a `Ezagent.CommandedApp.dispatch/2` call. The attribute is the API contract. Example:

```elixir
defmodule EzagentDomainChat do
  @consistency :strong
  @doc "Create a new session — uses strong consistency because callers redirect to the detail page."
  def create_session(name, owner_uri, opts) do
    cmd = %CreateSession{...}
    Ezagent.CommandedApp.Dispatch.dispatch(cmd, opts ++ [consistency: :strong])
  end

  @consistency :eventual
  @doc "Post a chat message — fanout via PubSub is acceptable async."
  def post_message(session_uri, message) do
    ...
  end
end
```

A new invariant `Ezagent.Invariants.FacadeConsistencyDeclaredTest` walks every `apps/ezagent_domain_*/lib/**/*.ex` module + every `apps/ezagent_plugin_*/lib/**/*.ex` module, finds every public `def` that calls `Ezagent.CommandedApp.Dispatch.dispatch/2` (transitive — also matches `Ezagent.CommandedApp.dispatch/2` directly), and asserts the function has a `@consistency` attribute on its docstring/spec. Missing attribute → CI fail.

**Gate 2 — LV write→read coverage (read side):** `Ezagent.Invariants.LVConsistencyTest` walks every `apps/ezagent_plugin_liveview/lib/**/*.ex` LV module. For each `handle_event/3` clause, it finds:
1. The first facade call (a call to any module declared in Gate 1's set).
2. Any subsequent `assign(socket, ...)` that re-reads a projection table.
3. Looks up the facade's `@consistency` declaration. If the LV re-reads a projection updated by the facade's events, the facade must be `:strong` OR a named-projector list including that projection.
4. Asserts the projection coverage map (Appendix D) lists this facade as a source for the projection being re-read.

This catches facade-mediated writes that the r3 direct-AST rule missed.

**Projection→facade coverage map (new Appendix D):** an explicit mapping `%{<projection_module> => [<facades that emit events updating it>]}`. Updated at impl-time per phase. The Gate 2 lookup uses this map.

**Future callsites:** any new write→immediate-read pattern MUST be added to this matrix at SPEC-time + the invariant updated. The matrix is the discipline; the invariant is the gate.

---

## 5. Read Model strategy

### 5.1 One projection per logical read view

Each LiveView page / API endpoint has a corresponding projection table:

| Projection | Source events | Read by |
|---|---|---|
| `user_profile` | UserRegistered, PasswordRotatedForUser, UserDestroyRequested | `/admin/users`, login flow |
| `user_caps` | CapGrantedToUser, CapRevokedFromUser | `/admin/caps`, dispatch authz |
| `user_tokens` | TokenMintedForUser, TokenRevokedForUser | `entity_tokens` reads, bearer auth |
| `agent_profile` | AgentCreated, AgentDestroyRequested | `/admin/agents`, agent picker |
| `agent_caps` | CapGrantedToAgent, CapRevokedFromAgent | `/admin/caps`, dispatch authz |
| `agent_lineage` | AgentCreated (with parent_uri), AgentDestroyRequested | lineage queries |
| `agent_api_keys` | ApiKeyPutForAgent | runtime credential fetch (NOTE: encrypted in projection too; same encryption as current `agent_api_keys` table) |
| `session_profile` | SessionCreated, SessionDestroyRequested, SessionOwnershipTransferred | `/sessions`, session picker |
| `session_messages` | MessagePosted | `/sessions/X`, chat history (replaces `messages` SQLite table) |
| `session_members` | MemberJoinedSession, MemberLeftSession | membership queries, `/sessions/X` |
| `external_mirror_bindings` | ExternalMirrorBound, ExternalMirrorUnbound | bindings reconciler, `/admin/mirrors` |
| `external_mirror_workers` | WorkerSpawned, WorkerCursorAdvanced, WorkerTerminated | worker status |
| `workspaces` | WorkspaceCreated, WorkspaceDestroyRequested | workspace picker, `Workspace.list_*` |
| `workspace_members` | MemberAddedToWorkspace, MemberRemovedFromWorkspace | `list_workspaces_for/2` cap-vis query |
| `audit_events` | (all domain events filtered through audit projector) | `/admin/audit` queryable history |

Each projection is a module:

```elixir
defmodule Ezagent.Projection.UserCaps do
  use Commanded.Projections.Ecto,
    application: Ezagent.CommandedApp,
    name: "UserCapsProjection",
    consistency: :eventual  # opt to :strong for read-after-write LVs

  project %CapGrantedToUser{} = event, fn multi ->
    Ecto.Multi.insert(multi, :cap, %Ezagent.Projection.UserCap{
      user_uri: event.user_uri,
      cap_json: Jason.encode!(event.cap),
      granted_by: event.granted_by,
      granted_at: event.granted_at
    })
  end

  project %CapRevokedFromUser{} = event, fn multi ->
    Ecto.Multi.delete_all(multi,
      :cap,
      from(c in Ezagent.Projection.UserCap,
        where: c.user_uri == ^event.user_uri and c.cap_json == ^Jason.encode!(event.cap))
    )
  end

  def after_update(_event, _metadata, _changes) do
    Phoenix.PubSub.broadcast(EzagentCore.PubSub, "ezagent:projections:user_caps", :updated)
    :ok
  end
end
```

### 5.2 Workspace scoping on projections

Every projection row that's workspace-scoped carries a `workspace_uri` column (same convention as current SQLite tables). `Ezagent.Persistence.scope_by_workspace/2` works against projections unchanged; the existing workspace-isolation invariant test is repointed at projection tables.

### 5.3 Cold-load handling

When LV mounts, it reads the projection (sync DB query). If the LV was just redirected-to from a dispatch site, the dispatch used `consistency: :strong` so the projection is caught up.

For cross-tab races (tab 1 dispatches, tab 2 mounts a stale LV before the projector catches up):
- The LV mount uses `Commanded.Subscriptions.wait_for/3` with the latest known aggregate version for that URI. If known, wait. If not known, accept eventual.
- The LV subscribes to the PubSub topic for the projection; the projector's `after_update/3` fires the subscriber; the LV re-renders.

The cold-load defense is the SAME as gift-card-demo: subscribe + re-fetch on update + initial render is best-effort. Worst case: ≤10ms stale window.

### 5.4 Strong vs eventual per projector

Default: `consistency: :eventual` for all projectors. Opt to `:strong` only for projectors that gate a dispatch site's immediate redirect (e.g. `user_profile` for `/admin/users/create` → redirect to `/admin/users/X` flow needs the new user in the profile projection).

Tradeoff: each `:strong` projector adds latency to every dispatch that flags `:strong` consistency. Default `:eventual` keeps the hot path fast.

---

## 6. Migration plan — phased

The migration runs as **Phase 10** in the IMPLEMENTATION_ROADMAP. Four sub-phases (10-A through 10-D), each gated by a /goal + per-phase invariant test.

### 6.0 Forward data migration — snapshot import (r2 — CRIT-1 fix)

**Codex r1 CRIT-1:** r1 said migrated Kinds "do NOT migrate existing snapshots; first command creates fresh event-sourced state." That drops live User/Session/Agent/Workspace state at cutover. UNACCEPTABLE per `feedback_destructive_migration_anti_pattern`.

**r2 fix — every Phase 10-A through 10-C runs Step 0 (snapshot import) BEFORE production dispatch is routed to the aggregate:**

Each Aggregate class defines a dedicated `%XSnapshotImported{}` event variant. The aggregate's `apply/2` has a clause for this event that hydrates the aggregate state from the snapshot payload. The event is emitted ONCE per existing URI by a `mix ezagent.aggregate.import --kind <kind>` task BEFORE the per-Phase cutover.

**Per-Kind import event:**

| Kind | Import event | Payload |
|---|---|---|
| User | `%UserSnapshotImported{}` | the full pre-existing slice (identity caps, user_credentials counter, user_tokens counter), plus the `users.password_hash`, `entity_profiles.*`, `entity_tokens.*` joined columns |
| Session | `%SessionSnapshotImported{}` | the full Chat slice + Publisher slice + ExternalMirror slice + members + ring state |
| Agent | `%AgentSnapshotImported{}` | the full per-flavor slice + lineage + api_keys |
| Workspace | `%WorkspaceSnapshotImported{}` | name, members, routing rules |
| ExternalMirrorWorker | `%WorkerSnapshotImported{}` | binding descriptor + cursor state |
| AgentTemplate | `%AgentTemplateSnapshotImported{}` | identity caps + template content |
| SessionTemplate | `%SessionTemplateSnapshotImported{}` | identity caps + template content |

**The import task:**

```
mix ezagent.aggregate.import \
  --kind user \
  --batch-size 100 \
  --dry-run    # default — print what would be imported, exit
```

When `--dry-run` is dropped:
1. For each row in `kind_snapshots` matching the Kind type, read the `state_binary`.
2. JOIN supplemental tables (`users.password_hash`, `entity_profiles.*`, `entity_tokens.*` for User; `messages` for Session-not-included — see below).
3. Build the `%XSnapshotImported{}` event payload.
4. Dispatch as the first event on the aggregate's stream (via `EventStore.append_to_stream/4`, NOT through the aggregate's `execute/2` — these are not commands, they are direct events the aggregate accepts at construction time).
5. Replay the aggregate; the `apply/2` clause hydrates state.

**`messages` table treatment for Session (r3 — schema-correct):** the existing `messages` SQLite table contains all historical messages. Importing every historical message as a `%MessagePosted{}` event would balloon the event store. **Decision:** the `%SessionSnapshotImported{}` event payload carries a `last_message_id` + `recent_messages` ring only (the durable Chat slice fields); the FULL message history stays in the SQLite `messages` table (which becomes a read-only archive). The projection table `session_messages_projection` holds new post-cutover messages.

**Permanent history query (r3 — actual schema column + join shape from `apps/ezagent_core/priv/repo/migrations/20260516070500_phase2_messages.exs:23` + `apps/ezagent_core/lib/ezagent/message_store.ex:174`):**

The schema column is `inserted_at` (NOT `created_at`); per-session history is a JOIN over `message_routings ⋈ messages` filtered by routing's `session_uri` + the message's `inserted_at` window. The post-migration query becomes an ordered UNION:

**r4 — workspace-scoped UNION SQL with DateTime cursor (HIGH-5 fix):**

Real per-session history join also requires `m.workspace_uri = $workspace_str` filter (per `message_store.ex:174`/`:201`/`:149`); ordering + cursor use `r.inserted_at`; pagination cursor is `DateTime`, not message id (per `message_store.ex:195`). Three parity-preserving SQL templates per existing `MessageStore.recent_in_session/3`, `older_than/3`, `in_session_since/3` signatures:

**recent_in_session(session_uri, workspace_str, n):**
```sql
SELECT * FROM (
  -- pre-cutover archive
  SELECT m.*, r.inserted_at AS routing_inserted_at FROM messages m
  JOIN message_routings r ON r.message_id = m.id
  WHERE r.session_uri = $session_uri AND m.workspace_uri = $workspace_str
    AND r.inserted_at < $cutover_at

  UNION ALL

  -- post-cutover projection (already includes workspace_uri column)
  SELECT *, inserted_at AS routing_inserted_at FROM session_messages_projection
  WHERE session_uri = $session_uri AND workspace_uri = $workspace_str
    AND inserted_at >= $cutover_at
) merged
ORDER BY routing_inserted_at DESC
LIMIT $n;
```

**older_than(session_uri, workspace_str, before_dt :: DateTime, limit):**
```sql
SELECT * FROM (
  SELECT m.*, r.inserted_at AS routing_inserted_at FROM messages m
  JOIN message_routings r ON r.message_id = m.id
  WHERE r.session_uri = $session_uri AND m.workspace_uri = $workspace_str
    AND r.inserted_at < $before_dt
  UNION ALL
  SELECT *, inserted_at AS routing_inserted_at FROM session_messages_projection
  WHERE session_uri = $session_uri AND workspace_uri = $workspace_str
    AND inserted_at < $before_dt
) merged
ORDER BY routing_inserted_at DESC
LIMIT $limit;
```

**in_session_since(session_uri, workspace_str, since_dt :: DateTime):**
```sql
SELECT * FROM (
  SELECT m.*, r.inserted_at AS routing_inserted_at FROM messages m
  JOIN message_routings r ON r.message_id = m.id
  WHERE r.session_uri = $session_uri AND m.workspace_uri = $workspace_str
    AND r.inserted_at >= $since_dt
  UNION ALL
  SELECT *, inserted_at AS routing_inserted_at FROM session_messages_projection
  WHERE session_uri = $session_uri AND workspace_uri = $workspace_str
    AND inserted_at >= $since_dt
) merged
ORDER BY routing_inserted_at ASC;
```

`Ezagent.MessageStore.list_for_session/1` (the current entry point) is rewritten to issue the appropriate UNION at post-migration. The `inserted_at` schema column naming is preserved; no rename. Workspace scoping is enforced in both halves of the UNION; `Ezagent.Persistence.scope_by_workspace/2` invariants extend to session_messages_projection naturally.

**Parity gates added in §6.0 import (r4 — corrected signatures):**
- `recent_in_session(session_uri, workspace_str, n)` — returns the same `n` rows pre/post (DateTime ordering preserved).
- `older_than(session_uri, workspace_str, before_dt)` — `DateTime` cursor, NOT msg_id. Identical pages.
- `in_session_since(session_uri, workspace_str, since_dt)` — DateTime window. Both halves.

Phase 10-D documents this UNION shape as the permanent shape; the `messages` table is NOT dropped.

**Parity gate (the cutover criterion, per `feedback_completion_requires_invariant_test`):**

```
mix ezagent.aggregate.verify --kind <kind>
```

Reads every URI's event-replayed aggregate state + compares field-by-field against the original `kind_snapshots.state_binary`. Asserts equality on every durable field enumerated in §4.2.*.

**r4 — per-Kind additional explicit-table parity asserts (HIGH-6):**

For Kinds whose durable state spans multiple SQLite tables (User), `verify --kind user` runs additional explicit per-table SELECTs:

```
# After kind_snapshots parity:
For every row in entity_profiles where workspace_uri = w:
  Assert exists in user_profile_projection with
    (uri, workspace_uri, display_name, email, registered_at) equal

For every row in entity_tokens where workspace_uri = w:
  Assert exists in user_tokens_projection with
    (uri, token_id, token_hash, label, scope, expires_at, last_used_at, minted_at, workspace_uri) equal

For Session: For every row in messages joined message_routings where workspace_uri = w:
  Assert UNION query in §6.0 returns the same row at the same position
```

Each per-Kind verify is documented in §6.2/6.3 deliverables. Any mismatch → import is incomplete; cutover is blocked.

**Cutover is the moment** the pre-dispatch pipeline routes Aggregate-targeted commands to `Commanded.Application.dispatch/2` instead of the legacy `Invocation.dispatch/1`. The cutover commits when the parity gate is green for all migrated URIs.

**Rollback BEFORE cutover:** trivial — drop the events from the aggregate's stream; the aggregate is fresh again. The original `kind_snapshots` data is untouched.

**Rollback AFTER cutover:** harder — events written post-cutover by production dispatches need to be replayed back into slice/snapshot via the §12 unwind path.

### 6.1 Phase 10-A — dependencies + skeleton + ExternalMirror slice + Worker (r3 — bind-spawn coupling boundary)

**Goal (r3 — HIGH-3 fix):** prove the integration. The ExternalMirror slice + Worker Kind migrate together because the bind→spawn coupling at `external_mirror.ex:394`/`:677` cannot be broken by migrating Worker alone. If 10-A fails, the whole migration aborts.

**Phase 10-A scope (r4 — HIGH-4 fix; split-brain protocol REMOVED):**

The r3 slice-split protocol was unsafe because bind→spawn→subscribe is one atomic-from-the-user's-perspective workflow that touches both the `:external_mirror` slice (binding row) and the `:publisher` subscription (worker's reverse-callback). Splitting the slices placed the binding row in an event stream while the publisher subscription still went through the legacy Session GenServer — the worker's subscribe call at `external_mirror_worker.ex:639` could race the binding event.

**r4 Phase 10-A scope (Option a — saga bridges via PubSub, Session stays fully legacy):**

- Session aggregate is NOT created in 10-A. Session stays fully a GenServer Kind (Chat + Publisher + ExternalMirror + OrchestratorAdmin slices).
- Worker IS migrated to `Ezagent.Aggregate.ExternalMirrorWorker` in 10-A.
- The bind → spawn → subscribe coupling is replaced by a `BootstrapWorkerSaga` that subscribes to the LEGACY Session's existing `:slice_change` PubSub topic (NOT to an event stream).
- When a legacy bind dispatches `Behavior.ExternalMirror.bind/4`, the Session GenServer writes the binding row + emits a `:slice_change` PubSub event (existing behavior). The saga listens to PubSub, observes the binding addition, and dispatches `%SpawnWorker{}` on the new Worker aggregate.
- The Worker aggregate's `BootstrapWorkerSaga` (saga internal) then dispatches `%SubscribeToSessionPublisher{}` — but this command, since Session is legacy, routes back through the bridge to call `Ezagent.Invocation.dispatch/1` against the legacy Session's `Behavior.Publisher.SessionImpl.subscribe_from/4`. No race; the legacy Session and the new Worker aggregate are coordinated through PubSub events (push) + the bridge (pull).
- Cutover for Worker is per §6.0: the import task replays `external_mirror_bindings` rows as `%WorkerSnapshotImported{}` events on the Worker aggregate's stream BEFORE turning on production dispatch.

**SessionRouter (r3) is REMOVED.** No per-Behavior routing within Session. Phase 10-A is exclusively Worker migration + bridge module.

**Bridge module (r4):** `Ezagent.MigrationBridge` in `apps/ezagent_commanded_app/`. Two directions:
- **Aggregate → Legacy:** when an aggregate-side command needs to dispatch to a legacy GenServer Kind (e.g. Worker saga calls Session's `subscribe_from`), the bridge translates the call into `Ezagent.Invocation.dispatch/1`. The bridge is deleted in Phase 10-D.
- **Legacy → Aggregate:** when legacy code emits a `:slice_change` PubSub event that the saga listens to, the saga internally converts to an aggregate command. No bridge code needed — saga IS the bridge for the read direction.

**Phase 10-A is NOT a "small" phase under this revision.** It bundles dependency/skeleton work, Worker migration, and the saga bridge. The "smallest Kind" framing is dropped. Estimated calendar time revised in §6.5.

**r2 CRIT-2 fix — Worker cannot migrate in isolation:** r1 had Phase 10-A migrate Worker only, but `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:394` + `:677` shows the legacy Session-side bind calls `Ezagent.Kind.spawn(Ezagent.Entity.ExternalMirrorWorker, params)` DIRECTLY. No `BindingCreated` event is emitted while Session remains a GenServer Kind, so the `BootstrapWorkerSaga` would never fire. Two options:

**Option (a) — DEFAULT for r2: migrate Session ExternalMirror behavior + Worker together in Phase 10-A.** Worker is still the gating Kind (smallest, most isolated state); the Session `Behavior.ExternalMirror` actions (bind / unbind / list_bindings) become Session aggregate commands that emit `BindingCreated` / `BindingRemoved` events. This expands Phase 10-A scope but eliminates the heterogeneity gap. Session core (Chat / Publisher) stays GenServer-backed until Phase 10-B; only the ExternalMirror slice migrates in 10-A.

**Option (b) — fallback if (a) proves too entangled: ship `Ezagent.MigrationBridge.LegacyBind`** — a translation shim that wraps the legacy `Kind.spawn(Worker, params)` call and (i) constructs a `%SpawnWorker{}` command on the new aggregate AND (ii) synthesizes a `%BindingCreated{}` event into the new event stream so saga triggers fire. The bridge is deleted in Phase 10-D.

r2 commits to (a) unless impl PR-A1 codex review identifies a blocker.

**Deliverables (r2 — expanded):**
1. Add deps to root mix: `commanded ~> 1.4`, `eventstore ~> 1.4`, `commanded_eventstore_adapter ~> 1.4`, `commanded_ecto_projections ~> 1.3`, `postgrex ~> 0.19`.
2. Create new umbrella app `apps/ezagent_event_store` — config for `eventstore` lib (Postgres backend; dev uses local Postgres on port 5432, test uses in-memory adapter via Commanded's built-in test adapter).
3. Create new umbrella app `apps/ezagent_commanded_app` — `Ezagent.CommandedApp` module + the router + the pre-dispatch pipeline (§4.5).
4. Create new umbrella app `apps/ezagent_projections` — projection tables (Ecto repo against the existing SQLite for projection storage; events live in Postgres; the asymmetry is intentional — see §7.3).
5. **Step 0 — forward-migration import** (per §6.0) for Worker bindings + ExternalMirror slice on existing Sessions. Read `external_mirror_bindings` SQLite table; emit `%BindingSnapshotImported{}` events on Session aggregate stream; emit `%WorkerSnapshotImported{}` events on Worker aggregate stream. Parity gate green before cutover.
6. Migrate `Ezagent.ExternalMirror.Worker` to `Ezagent.Aggregate.ExternalMirrorWorker`.
   - Worker is the smallest Kind (117 LOC), the most isolated (its own domain app), and its in-process subscribers are bounded.
   - Existing `Ezagent.Entity.ExternalMirrorWorker` Kind module is REPLACED — not deprecated. Same URI shape; same callers (the BindingCreated saga that boot-spawns Workers is also added in this phase).
7. **Migrate `Behavior.ExternalMirror` actions on Session aggregate** (r2 CRIT-2 fix) — Session-aggregate-side commands `%BindExternalMirror{}` / `%UnbindExternalMirror{}` / `%ListBindings{}` (the last as a projection query, not a command). The Session aggregate gains an `external_mirror_bindings: []` field. The Session GenServer Kind is REMOVED from the ExternalMirror dispatch path for these 3 actions only; the rest of Session (Chat / Publisher / OrchestratorAdmin) stays GenServer-backed until Phase 10-B.
8. `BootstrapWorkerSaga` is implemented (replaces the boot reconciler scan).
9. `external_mirror_workers_projection` + `external_mirror_bindings_projection` are implemented.
10. Phoenix.Channel + LV that talk to Workers / ExternalMirror bind route through `Ezagent.CommandedApp.Dispatch`.

**Phase 10-A invariant test (the gate, per `feedback_completion_requires_invariant_test`):**
- `Worker aggregate state reconstructs deterministically from event stream alone` — test spins up an aggregate, dispatches N commands, stops the aggregate, restarts, asserts state equality.
- `BootstrapWorkerSaga resumes after BindingCreated event without rerunning the binding` — test plays a BindingCreated event, kills the saga process, replays, asserts no duplicate SpawnWorker dispatch.
- `Cross-Kind invocation from Worker → Session uses an event subscription, not direct GenServer.call` — grep test on the Worker code; no `Kind.get_slice/2` or `KindRegistry.lookup/1` for cross-Kind reads.

**Phase 10-A unwind (if failure):**
- Revert all deps in mix.exs.
- Delete the three new umbrella apps.
- Restore `Ezagent.Entity.ExternalMirrorWorker` from git.
- No data migration; the worker state was always derived from `external_mirror_bindings` rows (which never moved).

### 6.2 Phase 10-B — User + Session

**Pre-condition:** Phase 10-A merged + 1 week of soak in dev/staging.

**Goal:** the two most-used Kinds migrated. User: medium (240 LOC); Session: large (2272 LOC); both critical to every user-facing flow.

**Deliverables:**
- `Ezagent.Aggregate.User` + commands/events/projections (§4.2.1).
- `Ezagent.Aggregate.Session` + commands/events/projections (§4.2.3).
- Sagas: `CreateSessionSaga`, `DestroySessionSaga`, `DestroyUserSaga`, `CapGrantOwnershipVerifySaga`.
- All User + Session callsites migrated to the new Command-based API. Existing `EzagentDomainChat.create_session/3` becomes `EzagentDomainChat.create_session_command/3` returning `{:ok, cmd}` + a dispatch site OR is rewritten to dispatch directly.

**Phase 10-B invariant tests:**
- User caps reconstruct from event stream.
- Session messages reconstruct from event stream.
- `CreateSessionSaga` completes deterministically (no missing GrantOwnerOrchestratorAdminCap step).
- `DestroyUserSaga` compensates correctly on simulated step failure (the destroy_lifecycle 4-round failure resolved).

**Phase 10-B unwind:**
- More complex. User + Session aggregates have written events to the production event store. Unwind requires:
  1. Stop dispatch (new commands go to the GenServer-Kind code).
  2. Replay event stream → write back to slice/snapshot tables via a one-time `mix ezagent.unwind.user_session` task.
  3. Verify slice/snapshot state matches projection.
  4. Restore the GenServer Kind modules from git.
- Documented + reversible; the cost is the manual replay step.

### 6.3 Phase 10-C — Agent + Workspace

**Pre-condition:** Phase 10-B merged + 2 weeks soak.

**Goal:** the remaining Kinds. Agent: large (798 LOC) + per-flavor variants; Workspace: small but cross-cutting.

**Deliverables:**
- `Ezagent.Aggregate.Agent` + commands/events/projections (§4.2.2).
- `Ezagent.Aggregate.Workspace` + commands/events/projections (§4.2.4).
- Sagas: `DestroyAgentSaga` (the trigger SPEC #440), `DestroyWorkspaceSaga`, `CreateUserInWorkspaceSaga`, `BootstrapWorkerSaga` (refactored — was Phase 10-A but enriched here with Workspace context).
- All per-flavor agent code migrated. Flavor Behaviors (cc, codex, curl, np, echo) gain a Command + Event vocabulary.

**Phase 10-C invariant tests:**
- Agent lineage queries match aggregate state (no projection drift).
- `DestroyAgentSaga` completes the full 7-step cascade or compensates cleanly.
- `DestroyWorkspaceSaga` cascades through all child sessions/agents/users.

### 6.4 Phase 10-D — deprecate + cleanup

**Pre-condition:** Phases 10-A through 10-C merged + 1 month soak.

**Goal:** delete the old code.

**Deliverables:**
- Delete `Ezagent.Kind.Server`, `Ezagent.Kind.Snapshot`, `Ezagent.KindRegistry`, `Ezagent.SpawnRegistry`, `Ezagent.PendingDelivery`, `Ezagent.ReadyGate`.
- Delete `Ezagent.Invocation` (and all its callers).
- Delete the `kind_snapshots` SQLite table — **GATED**: see "Cleanup preflight gate" below.
- Delete `Ezagent.Audit.Writer` for domain-event paths; KEEP for telemetry paths.
- Delete `Ezagent.Behavior` (and all Behavior modules) — replaced by Command modules + per-Aggregate execute clauses.
- Update `IMPLEMENTATION_ROADMAP.md` §1.1 to mark Phase 10 complete + the new architectural baseline.
- Update `CLAUDE.md` skill `ezagent-developer` to point at the new dispatch / aggregate patterns.

**Cleanup preflight gate (r3 — MED-8 fix, hardened against flag spoofing):**

`DROP TABLE kind_snapshots` is destructive. The gate requires a *drill receipt* artifact, not just a flag.

**`mix ezagent.cleanup.drill`** (the only writer of receipts):
1. Operator runs `mix ezagent.cleanup.drill --backup-path /path/to/backup.sqlite --operator-email <ops@example>`.
2. Task computes `backup_sha256 = sha256(file)`, restores backup to a temp DB, counts rows in `kind_snapshots`, compares to live DB row count.
3. Task runs §6.0 parity gate (`mix ezagent.aggregate.verify`) against the *restored* temp DB; captures the parity report's SHA256.
4. Writes a signed JSON receipt at `priv/cleanup_receipts/<timestamp>.json` (r4 — MED-9: explicit `earliest_execute_at` cooldown + separate `expires_at` + execution_nonce):
   ```json
   {
     "backup_path": "...",
     "backup_sha256": "...",
     "live_row_count": 1234,
     "live_db_content_hash": "...",   // r4: SHA256 of the live DB's kind_snapshots table contents at drill time
     "restored_row_count": 1234,
     "parity_report_sha256": "...",
     "operator_email": "...",
     "drill_completed_at": "2026-05-28T14:00:00Z",
     "earliest_execute_at": "2026-05-29T14:00:00Z",  // r4: drill_completed_at + 24h cooldown (the real cooldown gate)
     "expires_at": "2026-06-04T14:00:00Z",            // r4: drill_completed_at + 7d (the receipt validity window)
     "execution_nonce": "<random uuid v4>",           // r4: written to audit_events row on execute
     "signature": "..."                               // HMAC over the above with deployment secret
   }
   ```
5. Receipt is committed to git for audit trail (the file path is in `.gitignore` exclusions for cleanup_receipts/).

**`mix ezagent.cleanup.execute --receipt <path-to-receipt-json>`** (the actual DROP, r4 — MED-9 hardened):
1. Checks `priv/cleanup_receipts/<timestamp>.consumed` does NOT exist. If it does → "receipt already consumed" → exit 1.
2. Reads receipt, verifies HMAC signature against deployment secret. Mismatch → exit 1.
3. Recomputes `backup_sha256` from `backup_path` in receipt → must equal stored SHA. Mismatch → exit 1.
4. Reads live DB `kind_snapshots` row count → must equal `live_row_count` AND content-hash must equal `live_db_content_hash`. Drift → exit 1 (live DB changed since drill, even if row count happens to coincide).
5. Reruns parity check on live DB → SHA must equal `parity_report_sha256`. Mismatch → exit 1.
6. Verifies `operator_email` is on `priv/cleanup_operators.allowlist` (committed file). Not on list → exit 1.
7. **r4 — real cooldown:** verifies `now >= earliest_execute_at` (cooldown elapsed) AND `now < expires_at` (receipt not stale). Either condition false → exit 1.
8. Only when ALL pass: prints "DROP TABLE kind_snapshots — final confirmation?" + reads operator interactive `y/N`; defaults `N`. Operator's `y` triggers the DROP.
9. **r4 — one-time consumption:** writes `priv/cleanup_receipts/<timestamp>.consumed` marker after a successful DROP. Replays see the marker (step 1) and fail.
10. **r4 — execution nonce audit:** writes an `audit_events` row with `event_type: "kind_snapshots_dropped"`, payload: `{execution_nonce, receipt_path, operator_email, executed_at}`. Forensic trail.

**The receipt cannot be forged.** Spoofing requires breaking the HMAC. Replaying an old receipt requires the live DB row count + parity SHA to still match (they won't, since events accumulate post-drill). Bypassing the allowlist requires git commit access (which the CI gate logs).

**Invariant test (r3 — MED-8):** CI runs `mix ezagent.cleanup.execute --receipt nonexistent.json` and asserts exit non-zero with "receipt not found". Also runs a synthesized invalid-signature receipt and asserts exit non-zero with "signature mismatch". The gate's resistance is itself tested.

**Phase 10-D invariant tests:**
- grep for `Ezagent.Kind.Server`, `Ezagent.Invocation`, `KindRegistry.lookup`, etc. across `apps/` is empty.
- All LVs read from projections; no `Kind.get_slice/2` calls anywhere.
- `mix ezagent.cleanup.preflight --table kind_snapshots` returns non-zero in CI (because no operator-approval flag is supplied) — this asserts the gate exists and refuses unconditional execution.
- The `NoBehaviorLeftBehindTest` from §4.1.5 returns green (every dispatchable Behavior has a Command mapping).

### 6.5 Estimated phase durations

| Phase | Estimated calendar time (1 developer + codex review) |
|---|---|
| 10-A | 2-3 weeks |
| 10-B | 4-5 weeks |
| 10-C | 4-5 weeks |
| 10-D | 1-2 weeks |
| **Total** | **~3 months** |

These are rough — they assume no major blockers and the patterns established in 10-A generalize. Allen's input needed on whether this aligns with current priorities (see §10 OQ-2).

---

## 7. Performance + ops cost analysis

### 7.1 Hot-path dispatch latency

| Operation | Current latency | New latency | Notes |
|---|---|---|---|
| Dispatch `:cast` to existing Kind | ~1ms (`GenServer.cast` + slice update + `:on_change` SQLite write) | ~5-50ms (event append to Postgres) | Postgres event append dominates; same order as SQLite `:on_change` today but slower per-op due to fsync semantics |
| Dispatch `:call` to existing Kind | ~5ms (`GenServer.call` + slice + write + reply) | ~10-60ms (event append + aggregate apply + reply) | Similar shape |
| Dispatch `:call` w/ `consistency: :strong` | n/a — current model is implicitly strong via GenServer serialization | ~15-80ms (event append + strong projector commit + reply) | The new "strong" mode is similar to current effective behavior |
| Cold aggregate replay (after restart) | n/a — Kind GenServer starts from latest snapshot | ~5-50ms (load snapshot + replay events since snapshot) | `snapshot_every: 50` bounds replay to ≤50 events |
| LV mount + initial read | ~1ms (Kind.get_slice sync call) | ~1-5ms (Postgres SELECT) | Roughly equivalent; SQLite local-disk is faster than Postgres networked but the gap is ~ms |
| LV update (projection-driven) | n/a (currently push-via-PubSub from Behavior) | ~10-20ms (projector commit + PubSub broadcast + LV re-render) | Similar to current — current also has the broadcast hop |

**Conclusion:** event-store-driven dispatch is **5-10x slower than current per-dispatch in the worst case** (50ms vs 5ms), but still well within human-perception bounds (<100ms). For batch workflows (CLI), this is acceptable; for real-time UI, it's seamless.

### 7.2 Aggregate snapshot frequency tuning

`snapshot_every: 50` events is the recommended default. Per-Aggregate override:

- **Session** — high event volume (1 event per message). `snapshot_every: 100` to amortize snapshot cost. Worst-case cold replay = 100 events × 50μs each = 5ms.
- **User** — low event volume. `snapshot_every: 20` is fine; replay cost is negligible.
- **Workspace** — very low volume. `snapshot_every: 10`.
- **Agent** — medium volume; `snapshot_every: 50` default.
- **Worker** — medium volume (per-cursor-advance event); `snapshot_every: 100`.

These are starting values; tune based on production telemetry post-launch.

### 7.3 Dev burden — Postgres in dev loop

The current dev loop uses SQLite (zero-config). Postgres requires:
- Running `postgres` locally (Docker: `docker run -p 5432:5432 postgres:16`, or homebrew: `brew install postgresql@16 && brew services start postgresql@16`).
- `mix event_store.create` + `mix event_store.init` at first-time setup.
- An additional repo for the event store schema (separate from the existing SQLite projections repo).

**Mitigations:**
- **Test mode uses in-memory adapter** — `Commanded.EventStore.Adapters.InMemory` runs in-process; no Postgres required for `mix test`. The test environment is unchanged from the dev's perspective.
- **`docker-compose.dev.yml`** ships a Postgres + adminer container; `mix ezagent.dev.up` brings it up. Onboarding cost: one Docker command at clone time.
- **Snapshot store also in Postgres** (Commanded's built-in `snapshotting` config) — no separate snapshot infra in dev.
- **Migration path documented in CONTRIBUTING.md** — first-PR-after-Phase-10-A devs read the new setup instructions; existing devs need to pull the docker-compose change.

**Trade-off acknowledged:** the zero-config dev experience is lost. Allen's input needed (§10 OQ-2).

### 7.4 Ops burden — Postgres backup, replication, PITR

Postgres ops is widespread; tooling is mature:
- **Backup**: `pg_dump` for full; WAL archiving for PITR.
- **Replication**: streaming replication; standby for failover.
- **PITR**: WAL-based; standard `recovery.conf`.

For ezagent's scale (single-tenant deployment per Allen's current ops model), a single Postgres node + nightly `pg_dump` + WAL archive is sufficient. Cloud-managed (RDS, Cloud SQL, Supabase) all work. No new ops skill required beyond "we now run Postgres in addition to SQLite for projections + telemetry".

**SQLite stays for:**
- Projections (the projection schema lives in SQLite for compatibility with all existing read paths).
- Telemetry audit (the `audit` table for non-domain events).
- Application config / templates / fixtures.

**Postgres handles only:**
- Event store (`eventstore` lib schema).
- Aggregate snapshots (Commanded's snapshot store, sharing the `eventstore` schema).

**Why split:** SQLite is unbeatable for low-latency local reads; Postgres's event-store schema is the only place a Postgres-only library is required. Splitting lets us keep SQLite for everything that doesn't NEED Postgres while paying the Postgres cost only for what does. Asymmetric, but pragmatic.

### 7.5 Disk footprint

Event store grows monotonically (events are append-only, never deleted). Estimate:
- Per event: ~200-1000 bytes JSON payload + ~100 bytes metadata.
- ezagent activity rate: very rough estimate ~1000-10,000 events/day in steady state.
- Daily disk growth: ~1MB-10MB/day; ~1GB/year worst case.

Event archival policy: snapshots make REPLAY fast regardless of stream length, so events don't need to be deleted for performance. They can be archived (move to cold storage) for cost; not required for years. §11 q#8 addresses query patterns over archived events.

---

## 8. Migration risks + rollback plan

### 8.1 Per-phase rollback

Each phase has explicit unwind documented in §6. Summary:

| Phase | Rollback complexity | Data risk |
|---|---|---|
| 10-A (Worker only) | Trivial — revert code; no data migration | None — Worker state always derived from `external_mirror_bindings`, which never moved |
| 10-B (User + Session) | Medium — manual event-replay → slice/snapshot via a `mix` task | Low — events exist in event store, can be replayed back to slice |
| 10-C (Agent + Workspace) | Medium — same as 10-B | Low — same |
| 10-D (cleanup) | Hard — old code is deleted; rollback means restoring from git + re-running 10-B/10-C unwind | Medium — but only triggered if every prior phase failed |

### 8.2 Hybrid-period heterogeneity risk

During Phases 10-A through 10-C, some Kinds are Aggregates and others are GenServers. How they interact:

- **Aggregate → GenServer Kind cross-Kind call:** A saga emits a Command that targets a GenServer Kind. The Command's "dispatch" routes through the OLD `Ezagent.Invocation.dispatch/1` path for that Kind. Bridge: in the pre-dispatch pipeline, if the command's target URI maps to a non-yet-migrated Kind, route through `Invocation.dispatch/1`. The bridge module is `Ezagent.MigrationBridge.dispatch_to_legacy/2`.
- **GenServer Kind → Aggregate cross-Kind call:** A `Behavior.invoke/4` calls into a migrated Kind. Bridge: the call constructs a Command and dispatches via the new pipeline. Equally explicit in the bridge module.

The bridge module is the SHIM that allows hybrid operation. It's intentionally narrow — exactly the two directions above. The bridge is deleted in Phase 10-D.

§11 q#5 enumerates this concern for codex review.

### 8.3 Event schema breakage during impl

If a Phase 10-B impl PR adds an event type and Phase 10-B v2 needs to rename a field, every historical event still has the old shape on disk. `Commanded.Event.Upcaster` handles this:

```elixir
defimpl Commanded.Event.Upcaster, for: MessagePosted do
  def upcast(%MessagePosted{content: c} = ev, _meta) when not is_nil(c) do
    %MessagePosted{ev | body: c, content: nil}
  end
  def upcast(%MessagePosted{} = ev, _meta), do: ev
end
```

The pattern is well-supported by Commanded ([hexdocs](https://hexdocs.pm/commanded/Commanded.Event.Upcaster.html)). Each event schema change adds an upcaster impl; the historical event is read-only.

### 8.4 Production data loss risk

Per `feedback_destructive_migration_anti_pattern`:
- **No DROP / TRUNCATE on existing SQLite tables during migration.** New code reads from event-derived projections; old code reads from slice tables (during hybrid window). Both coexist.
- **Final cleanup (Phase 10-D) drops `kind_snapshots` only AFTER 1 month of clean operation post-10-C.**
- **Event store is append-only by construction** — events cannot be deleted accidentally without explicit operator action.

The risk is bounded: in the worst case (every phase fails), data is recoverable from the never-truncated SQLite tables. Phase 10-D is the only point of no return, and it gates on a 1-month soak.

---

## 9. Backwards compat / external API

### 9.1 What surface stays the same

- Phoenix.Channel topic names + message shapes — unchanged.
- HTTP endpoint paths + JSON shapes — unchanged.
- LiveView URLs + Assigns — unchanged from the user's perspective.
- CLI command names + flag shapes — unchanged.
- MCP tool schemas — unchanged.
- The `URI` addressing scheme — unchanged.
- Capability struct shape — unchanged.

### 9.2 What surface changes

- Plugin authors: instead of `@behaviour Ezagent.Kind` + `Ezagent.Behavior` modules, they write `@behaviour Commanded.Aggregates.Aggregate` + Command modules + Event modules + a per-Aggregate execute clause. The `ezagent-developer` skill is rewritten Phase 10-D.
- Domain context modules: `EzagentDomainChat.create_session/3` either becomes a thin wrapper that constructs `%CreateSession{}` and dispatches, OR is deleted and replaced by direct dispatch from the LV / channel. Decision per impl PR.
- Audit consumers: queries against the SQLite `invocations` table for domain events fail post-10-D — those queries must move to `audit_events_projection` OR to event-stream filters via `EventStore.read_stream_forward/4`. Migrated piecewise during 10-B / 10-C.

### 9.3 Plugin compatibility

Plugins outside the umbrella (if any future plugins existed at a separate git remote) would need to migrate their Kind definitions to Aggregates. Per `feedback_north_star_plugin_isolation`, the migration cost is bounded — plugins write commands + events + an aggregate; they do NOT touch the event store, the router, or the saga infrastructure (those live in `ezagent_commanded_app`).

The 3-tier rule from existing SPECs holds:
- **Tier 1 — core:** `apps/ezagent_core/`, `apps/ezagent_commanded_app/`, `apps/ezagent_event_store/`, `apps/ezagent_projections/`. Owns Commanded wiring.
- **Tier 2 — domain:** `apps/ezagent_domain_*/`. Owns aggregates + commands + events + projectors + sagas for their domain Kinds.
- **Tier 3 — plugin:** `apps/ezagent_plugin_*/`. Owns flavor-specific aggregate extensions (per-flavor commands + events + per-flavor execute clauses on the Agent aggregate).

Plugins cannot reach across to other plugins' aggregates; they go through events + sagas.

---

## 10. Open questions for Allen

### OQ-1. DB choice — Postgres for event store, SQLite for projections — accept?

Decision: yes (recommended). Alternatives:
- (a) **Migrate everything to Postgres** — drop SQLite entirely. Cleaner; one DB to manage. Cost: existing SQLite-based code (audit, fixtures, templates) must move; bigger disruption.
- (b) **Keep SQLite for everything except event store** — current recommendation (§7.4). Asymmetric but pragmatic.
- (c) **Find a SQLite event-store adapter** — no maintained one exists; would require building + maintaining a custom `Commanded.EventStore.Adapter` impl. High risk; not recommended.

### OQ-2. Migration calendar — 3 months acceptable, or do we phase it differently?

Allen's input needed. The phased plan is conservative (one Kind class per phase + 1-2 week soak). Acceleration options:
- (a) Phase 10-B and 10-C in parallel (riskier; two teams; we don't have two teams).
- (b) Run 10-A then jump directly to 10-D-equivalent for all Kinds (big bang; rejected per `feedback_destructive_migration_anti_pattern`).
- (c) Pause non-migration feature work during Phase 10-A through 10-C (Allen's call).

### OQ-3. Dev experience — Postgres in dev loop, acceptable burden?

Mitigations in §7.3. Allen's call on whether the docker-compose hop is acceptable for daily dev.

### OQ-4. Multi-tenant — does event sourcing change tenant-isolation concerns?

The current per-workspace isolation invariant (Phase 9 / SPEC v3 §7) ports forward: each domain event carries `workspace_uri`; projections enforce isolation in queries. The event stream itself is NOT workspace-partitioned by default — all events for all workspaces live in the same stream. This may be a concern for ops (a workspace cannot be "deleted from the event log" without a full dump-filter-restore cycle).

Alternative: one event stream per workspace. Commanded supports per-stream subscriptions naturally; multi-stream aggregates require care. §11 q#6.

### OQ-5. Mid-migration interop — bridge module placement

Phase 10-A through 10-C has the bridge module `Ezagent.MigrationBridge`. Should it live in `apps/ezagent_core/` (Tier 1) or `apps/ezagent_commanded_app/` (also Tier 1)? Probably the latter — the bridge is migration-specific scaffolding, not a permanent feature. Allen agrees?

### OQ-6. Sagas — should they be supervised inside `Ezagent.CommandedApp` or in a sibling supervisor?

Commanded supports both. In-app is simpler (single supervisor tree); sibling is more isolated. Default recommendation: in-app for Phase 10-A; reconsider if saga count grows past ~20.

### OQ-7. Presence — keep slice-based or move to `Phoenix.Presence`?

Per §4.3, Presence is not migrated to event sourcing (it's transient runtime state). Two options:
- (a) Keep as a `Ezagent.Presence` GenServer + slice (current).
- (b) Migrate to `Phoenix.Presence` natively (better-tested; CRDT-backed; clustering-ready).

Independent decision from this SPEC; flag here.

### OQ-8. Audit retention — when do we archive old events?

EventStore grows monotonically (§7.5). At ~1GB/year, archival is not pressing for years. When do we want a policy?

---

## 11. Codex adv-review questions

Pre-loaded attack vectors for codex round 1:

1. **Phoenix + Commanded integration maturity — is there a production reference at comparable scale, or are we pioneering?** §3.6 enumerates Conduit, Gift-card-demo, Segment Challenge, Honeydew, Casavo. None is at "thousands of aggregate types"-scale. Verdict: the pattern is established; ezagent's scale is well within precedent.

2. **Read-after-write consistency for LV — when user dispatches a command and LV re-renders, will it see the updated state? Is `:strong` mode the right answer or does it block command return until projection catches up?** §3.3 explains the three modes; the recommendation is default `:eventual` with opt-in `:strong` per dispatch site. The blocking is exactly what we want for the "wizard → redirect → detail page" pattern. Codex: validate that our specific LV → dispatch → re-render flows all have an opt-in path documented.

3. **Saga partial-failure: destroy cascade has 7 steps; if step 4 fails, how does the Saga compensate? Are there published compensation patterns?** §3.8 shows the destroy saga with `error/3` callback. Compensation in Commanded sagas is explicit (no auto-rollback); the saga code MUST encode compensation. Codex: validate the destroy saga's compensation logic is complete (does step 4 failure require undoing steps 1-3 or just retrying step 4? — depends on idempotency of each).

4. **Postgres vs SQLite — ezagent uses SQLite; can we feasibly support both, or must we migrate fully?** §7.4 + OQ-1: the recommendation is split (Postgres for event store + snapshots; SQLite for projections + audit + everything else). Asymmetric but works. Codex: validate that the asymmetry doesn't create cross-DB query problems (it shouldn't — projections + event store don't share queries; they share only the projection update operation, which is an Ecto.Multi within the projection's own SQLite repo).

5. **Heterogeneous migration — Phase 10-A through 10-C has some Kinds as Aggregates and some as GenServers. How do cross-Kind workflows work in this mixed mode?** §8.2 + the `Ezagent.MigrationBridge` module. Codex: validate that the bridge module handles both directions (Aggregate → GenServer + GenServer → Aggregate) AND that the bridge deletion in Phase 10-D doesn't strand any callers.

6. **Event schema evolution — adding new fields to existing event types, handling old events on replay.** §8.3 + Commanded's `Event.Upcaster` pattern. Codex: validate the Upcaster impl path for each anticipated schema change in Phase 10-B/10-C (we have at least 5 known evolutions queued from the destroy SPEC).

7. **Performance: worst-case event-stream replay time for an aggregate with N events. Hot Aggregates may have 10K+ events.** §7.2 + snapshot_every: 50-100. Codex: validate that 50 events × 50μs = 2.5ms cold-start is acceptable for our LV mount budget (it is).

8. **Audit query: today's `invocations` table is queryable via SQL. With EventStore, ad-hoc audit queries require event-stream scan or projection. Define audit query patterns.** §4.7. Codex: validate that the `audit_events_projection` schema can satisfy the existing `/admin/audit` LV's filter predicates (workspace_uri, caller, time range, action type). If a query exists today that the projection can't satisfy, document it as a Phase 10-B impl-blocker.

---

## 12. Rollback plan — overall abort path

If, after Phase 10-A merges + 10-B / 10-C in progress, Allen decides the migration is not working:

1. **Stop new dispatch.** Set a feature flag in the pre-dispatch pipeline that routes all commands through the legacy `Ezagent.Invocation.dispatch/1` path. New dispatches stop emitting events; Aggregates stop receiving commands.
2. **Replay events back to slice/snapshot.** For each migrated Aggregate, a `mix ezagent.aggregate.unwind --uri <uri>` task reads the event stream + writes equivalent slice state into `kind_snapshots`. The replay is deterministic (Aggregate's `apply/2` IS the projection from event to state).
3. **Verify parity.** A `mix ezagent.aggregate.verify` task asserts that for every migrated URI, the slice-snapshot state equals the event-replayed Aggregate state. If parity fails, the unwind aborts at this point (data is preserved in the event store + the SQLite snapshot — operator inspects).
4. **Restore GenServer Kind code.** From git: revert the per-Phase code that replaced `Ezagent.Entity.X` with `Ezagent.Aggregate.X`. The legacy `Kind.Server` boots from the (now-replayed) snapshot.
5. **Keep the event store data.** Even on abort, the events are preserved. A future re-attempt at migration starts from the same event store.

The unwind is documented + automated per Aggregate. Cost: an operator-driven session (estimated 1-2 hours for the full unwind across all 5 Aggregate classes given the projections are already shaped for the inverse direction).

---

## Appendix A — Event-store schema (Postgres)

Standard `eventstore` library schema; documented at https://hexdocs.pm/eventstore/EventStore.html. Tables:

- `event_store.events` — append-only event log.
- `event_store.streams` — per-stream metadata (one stream per Aggregate UUID = canonical URI string).
- `event_store.subscriptions` — projector + saga subscription state (replayed events position).
- `event_store.snapshots` — aggregate snapshots (Commanded-managed).

No custom schema required for Phase 10-A; per-projection tables live in the SQLite projections repo (§4 + §5).

## Appendix B — Sample command + event + aggregate execute clause

```elixir
# Command
defmodule Ezagent.Aggregate.User.Commands.GrantCapToUser do
  @derive Jason.Encoder
  defstruct [:user_uri, :workspace_uri, :cap, :granted_by, :idempotency_key]
end

# Event
defmodule Ezagent.Aggregate.User.Events.CapGrantedToUser do
  @derive Jason.Encoder
  defstruct [:user_uri, :workspace_uri, :cap, :granted_by, :granted_at]
end

# Aggregate execute clause
defmodule Ezagent.Aggregate.User do
  alias Ezagent.Aggregate.User.Commands.{GrantCapToUser, ...}
  alias Ezagent.Aggregate.User.Events.{CapGrantedToUser, ...}

  @behaviour Commanded.Aggregates.Aggregate

  defstruct [:uri, :workspace_uri, :registered_at, caps: MapSet.new(), destroyed?: false]

  # GrantCapToUser → CapGrantedToUser
  def execute(%__MODULE__{destroyed?: true}, %GrantCapToUser{}),
    do: {:error, :user_destroyed}

  def execute(%__MODULE__{uri: nil}, %GrantCapToUser{}),
    do: {:error, :user_not_registered}

  def execute(%__MODULE__{} = state, %GrantCapToUser{} = cmd) do
    %CapGrantedToUser{
      user_uri: cmd.user_uri,
      workspace_uri: cmd.workspace_uri,
      cap: cmd.cap,
      granted_by: cmd.granted_by,
      granted_at: DateTime.utc_now()
    }
  end

  # apply — state mutation
  def apply(%__MODULE__{} = state, %CapGrantedToUser{} = ev),
    do: %{state | caps: MapSet.put(state.caps, ev.cap)}

  # ... other commands/events/apply clauses ...
end

# Router clause
defmodule Ezagent.CommandedApp.Router do
  use Commanded.Commands.Router

  identify(Ezagent.Aggregate.User, by: :user_uri)
  dispatch([
    Ezagent.Aggregate.User.Commands.GrantCapToUser,
    Ezagent.Aggregate.User.Commands.RevokeCapFromUser,
    ...
  ], to: Ezagent.Aggregate.User)
end

# Dispatch site (e.g. in EzagentDomainIdentity.Users)
def grant_cap(user_uri, cap, granted_by, caller_caps) do
  cmd = %GrantCapToUser{
    user_uri: URI.to_string(Ezagent.URI.parse!(user_uri)),
    workspace_uri: Ezagent.URI.entity_workspace_uri_string(user_uri),
    cap: cap,
    granted_by: granted_by,
    idempotency_key: UUID.uuid4()
  }
  Ezagent.CommandedApp.Dispatch.dispatch(cmd,
    caller: granted_by,
    caps: caller_caps,
    consistency: :strong
  )
end
```

## Appendix D — Projection→Facade coverage map (r4 — HIGH-3)

Used by `Ezagent.Invariants.LVConsistencyTest` to verify that LV write→read combinations have a facade declaring `@consistency :strong` covering the projection.

| Projection module | Source facades (emit events updating this projection) |
|---|---|
| `Ezagent.Projection.UserProfile` | `Ezagent.Users.create/3`, `Ezagent.Users.set_password/2`, `EzagentDomainIdentity.UserCredentials.rotate/2`, `Ezagent.Entity.Profile.upsert/1` |
| `Ezagent.Projection.UserCaps` | `EzagentDomainIdentity.grant_cap/3`, `EzagentDomainIdentity.revoke_cap/3`, `Ezagent.Workspace.add_member/2` (default-grant), `Ezagent.Workspace.remove_member/2` (cascade revoke) |
| `Ezagent.Projection.UserTokens` | `Ezagent.Users.Token.mint/2`, `Ezagent.Users.Token.revoke/2`, `EzagentDomainIdentity.UserTokens.mark_used/2` |
| `Ezagent.Projection.AgentProfile` | `EzagentDomainChat.create_agent/4`, `EzagentDomainChat.destroy_agent/2`, plugin-flavor facade `Ezagent.PluginCc.spawn_agent/3` |
| `Ezagent.Projection.AgentCaps` | `EzagentDomainIdentity.grant_cap/3` (agent target), `EzagentDomainIdentity.revoke_cap/3` (agent target) |
| `Ezagent.Projection.AgentLineage` | `EzagentDomainChat.create_agent/4` (parent_uri set), `EzagentDomainChat.destroy_agent/2` |
| `Ezagent.Projection.AgentApiKeys` | `EzagentDomainIdentity.ApiKeys.put/3`, `EzagentDomainIdentity.ApiKeys.delete/2` |
| `Ezagent.Projection.SessionProfile` | `EzagentDomainChat.create_session/3`, `EzagentDomainChat.destroy_session/2`, `EzagentDomainChat.transfer_ownership/3` |
| `Ezagent.Projection.SessionMembers` | `Behavior.Chat.invoke(:join, ...)`, `Behavior.Chat.invoke(:leave, ...)` |
| `Ezagent.Projection.SessionMessages` | `Behavior.Chat.invoke(:send, ...)` (after Phase 10-B); pre-cutover messages remain in `messages` table (archive) |
| `Ezagent.Projection.ExternalMirrorBindings` | `Behavior.ExternalMirror.invoke(:bind, ...)`, `:unbind`, `EzagentPluginFeishu.bind/2`, `EzagentPluginFeishu.unbind/2` |
| `Ezagent.Projection.ExternalMirrorWorkers` | saga-emitted `%SpawnWorker{}`, `%TerminateWorker{}`, `%AdvanceWorkerCursor{}` |
| `Ezagent.Projection.Workspaces` | `Ezagent.Workspace.create/2`, `Ezagent.Workspace.destroy/1` |
| `Ezagent.Projection.WorkspaceMembers` | `Ezagent.Workspace.add_member/2`, `Ezagent.Workspace.remove_member/2` |
| `Ezagent.Projection.AgentTemplateProfile` | `EzagentDomainChat.create_agent_template/3`, `Behavior.Template.invoke(:write, ...)`, `:instantiate` |
| `Ezagent.Projection.SessionTemplateProfile` | `EzagentDomainChat.save_template_as/3`, `EzagentDomainChat.update_template/3`, `:fork` |
| `Ezagent.Projection.AuditEvents` | (all domain events; updated by AuditProjector subscribing to `$all` stream) |

Each facade in this table MUST carry an `@consistency` module attribute (Gate 1 §4.8). The LV invariant uses this map to validate that LV re-reads after facade calls have the right consistency mode.

## Appendix C — Reference URLs

- Commanded: https://github.com/commanded/commanded · https://hexdocs.pm/commanded
- EventStore (lib): https://github.com/commanded/eventstore · https://hexdocs.pm/eventstore
- commanded_eventstore_adapter: https://hex.pm/packages/commanded_eventstore_adapter
- commanded_ecto_projections: https://hex.pm/packages/commanded_ecto_projections · https://hexdocs.pm/commanded_ecto_projections
- Awesome-Elixir-CQRS (project list): https://github.com/slashdotdash/awesome-elixir-cqrs
- Conduit reference app: https://github.com/slashdotdash/conduit
- Gift-card-demo: https://github.com/slashdotdash/gift-card-demo
- Segment Challenge: https://github.com/slashdotdash/segment-challenge
- Honeydew CELP starter: https://github.com/quarterpi/honeydew
- Casavo Phoenix LiveView + ES tools: https://medium.com/casavo/supercharging-our-event-sourcing-capabilities-with-phoenix-liveview-c4a9d1d4ab99
- "Phoenix LiveView but event-sourced" (cantido): https://dev.to/cantido/phoenix-liveview-but-event-sourced-7pe
- Christian Alexander Phoenix API + Commanded: https://christianalexander.com/2022/05/09/elixir-commanded/
- ElixirMerge ES/CQRS guide: https://elixirmerge.com/p/comprehensive-guide-to-implementing-es-cqrs-with-eventstoredb-phoenix-and-liveview
- Commanded process managers / sagas: https://hexdocs.pm/commanded/process-managers.html
- Commanded read-model projections: https://hexdocs.pm/commanded/Read%20Model%20Projections.md
- Commanded event upcasting: https://hexdocs.pm/commanded/Commanded.Event.Upcaster.html
- Saga pattern in Elixir (Peter Ullrich): https://peterullrich.com/saga-pattern-in-elixir
