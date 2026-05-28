# SPEC — Entity deletion lifecycle (User / Agent / Worker)

**Status:** r5 — codex r4 review (REJECT) addressed: 2 CRIT + 1 HIGH + 1 MED + 1 LOW. 2026-05-28.

**r5 changes (codex r4 verdict REJECT — 5 findings resolved):**

- **CRIT-5.1 (`:scrub_owner` registration plumbing incomplete):** codex r4 found that r4's Chat change list mentioned `actions/0`, `required_caps/0`, `invoke/4`, `data_owner/1` but missed THREE additional places Chat behaviors must be wired: (a) `register_chat_behaviors/0` in `apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:605-614` registers each action with the BehaviorRegistry — without an entry there, `Kind.Runtime.authorize/4` returns `{:unknown_action, :scrub_owner}` at `apps/ezagent_core/lib/ezagent/kind/runtime.ex:212-216`; (b) `cap_subjects/0` in `chat.ex:108-116` declares the cap shape for `CapabilityRegistry.register/3` at `apps/ezagent_core/lib/ezagent/capability_registry.ex:61-98` — without it, the registration raises; (c) `interface/0` in `chat.ex:1036-1072` declares the action's args validator — without it, `Kind.Runtime` rejects the dispatch before `invoke/4` runs (`runtime.ex:615-628`). **Fix:** §4.1 PR-B change list expanded to enumerate ALL FIVE Chat-touching changes: actions, required_caps, invoke, data_owner, AND `register_chat_behaviors`, `cap_subjects`, `interface`. §3.5 now explicitly notes that the `:scrub_owner` registration is a five-part change, not a four-part change.
- **CRIT-5.2 (cold-load defense incomplete — additional data_owner sites):** codex r4 found that r4 placed the tombstone defense only in `Chat.data_owner/1` but TWO other production data-owner resolvers read the same stale slice without checking tombstones: (a) `Ezagent.Behavior.ExternalMirror.data_owner/1` at `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:593-600` reads the Session's `:chat.owner_uri` slice and returns it for CapBAC; (b) `Ezagent.Behavior.Publisher.SessionImpl.data_owner/1` at `apps/ezagent_domain_chat/lib/ezagent/behavior/publisher/session_impl.ex:136-144` calls `Session.owner/1` and returns the owner directly. Both are CapBAC paths, not display reads — a cold-loaded Session would still authorize a deleted user via these resolvers. **Fix:** §3.5 + §4.1 require the SAME tombstone defense at BOTH additional sites. The defense pattern (call `SpawnRegistry.tombstoned?(owner)`; if true return `:no_owner`) is identical at all three sites. INV-13b expanded to assert all three data_owner resolvers return `:no_owner` for a tombstoned URI cold-load.
- **HIGH-5.3 (kill_timeout overstates structural unreachability):** codex r4 found that r4 §3.3 + §3.9 claim a `:kill_timeout` leaves the URI "structurally unreachable through dispatch." This is FALSE for an already-ready live pid: `Invocation.dispatch/1` (`apps/ezagent_core/lib/ezagent/invocation.ex:87-107`) calls `KindRegistry.lookup/1` (`kind_registry.ex:59-64`) which returns the still-registered pid AND then `GenServer.cast`/`call` (`invocation.ex:111-130`) goes directly to the pid; it does NOT consult the tombstone table. Boundaries 1/2/3 prevent RE-SPAWN, not delivery to a still-alive process that boundary 1 has not yet had a chance to refuse. **Fix:** §3.9 + §3.3 clarified — on `:kill_timeout`, the live pid IS still reachable through dispatch for the brief window it survives the kill signal. The structural unreachability claim is narrowed to: (a) the URI cannot RE-SPAWN after death (boundaries 1/2/3 hold); (b) `KindRegistry.lookup/1` returns `:error` after the process eventually dies (Registry drops dead pids); (c) the live pid may receive a final burst of casts/calls until it dies. The operator runbook now correctly says: SIGKILL the BEAM node to force the live pid down — the `:partial` deletion is structurally bounded but not instantaneously complete. The `Behavior.EntityDeletion` return is unchanged (`{:error, {:partial, step_failed: :tombstone_and_kill_kill_timeout, ...}}`).
- **MED-5.4 (Capability example struct missing `granted_at`):** codex r4 found that the §3.5 `system://entity-deletion-cascade` cap example uses a raw `%Capability{}` literal with `granted_by` but no `granted_at`, but `Ezagent.Capability` has `@enforce_keys [:kind, :behavior, :instance, :workspace_uri, :granted_by, :granted_at]` at `apps/ezagent_core/lib/ezagent/capability.ex:36-46` — the literal would fail at compile/runtime. Other Catalog entries use `Capability.cap/3` helpers that populate required fields. **Fix:** §3.5 cap example switched to `Capability.cap(Ezagent.Entity.Session, Ezagent.Behavior.Chat, :scrub_owner, :any, :any)` followed by a comment noting `granted_by` + `granted_at` are populated by the catalog's existing pattern.
- **LOW-5.5 (ZH §11 stale r2 questions tail):** codex r4 found that EN §11 ends cleanly at q9, but ZH continues past q9 into old r2-era B1/B2/B3/B5 prompts that were superseded. **Fix:** ZH §11 tail trimmed to match EN's q0-q9 set.

**r4 changes (preserved — codex r3 verdict REJECT — 6 findings resolved):**

- **CRIT-4.1 (`SystemPrincipal.caps/1` argument shape):** codex r3 found that the r3 cascade code sample calls `Ezagent.SystemPrincipal.caps("entity-deletion-cascade")` but `SystemPrincipal.caps/1` (`apps/ezagent_core/lib/ezagent/system_principal.ex:156-163`) parses its input through `parse!/1` and enforces `scheme == "system"` (`:168-176`) — a bare service-name string crashes before any cap is returned. **Fix:** the cascade now uses `cascade_principal = SystemPrincipal.uri("entity-deletion-cascade")` (returns a `%URI{}`) for both the caller field AND as the argument to `SystemPrincipal.caps/1`. The r3 sample code in §3.5 is updated to call `SystemPrincipal.caps(cascade_principal)`. INV-13a updated to assert the cascade dispatch runs cleanly (no ArgumentError raised).
- **CRIT-4.2 (BindingRow schema lacks `worker_uri`):** codex r3 found that r3's `:bind` action body change at `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:747-758` is insufficient — production persistence flows through `Ezagent.ExternalMirror.BindingRow.insert/1` (`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/binding_row.ex:42-50, :87-108`) whose `schema "external_mirror_bindings"` block does NOT include `:worker_uri` and whose `cast`/`validate_required` lists also exclude it. Without BindingRow updates, Ecto silently drops `worker_uri` from the attrs map (cast ignores unknown fields) and after Migration B (NOT NULL) inserts would fail. **Fix:** §4.1 PR-B change list explicitly adds BindingRow updates: (1) add `field(:worker_uri, :string)` to the schema block, (2) update `@type t` to include `worker_uri: String.t()`, (3) add `:worker_uri` to BOTH `cast` and `validate_required` lists. The `:bind` action body passes a derived `worker_uri` value via the attrs map. Without these BindingRow changes, the column is unreachable from Elixir code.
- **HIGH-4.3 (INV-13a's "exactly one cap" too strict):** codex r3 correctly observed that `SystemPrincipal.ensure/1` (`apps/ezagent_core/lib/ezagent/system_principal.ex:88-92`) spawns the principal as a User Kind, and `Behavior.Identity.init_slice/1` (`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:91-122`) unconditionally adds a SELF `:list_caps` cap for ANY URI — including `system://...`. So the principal's slice carries TWO caps: the cascade's `Chat:scrub_owner` cap AND a `kind: :system, behavior: Identity, action: :list_caps, instance: <self>, workspace_uri: ...` self-introspection cap. **Fix:** INV-13a weakened from "exactly one cap" to "the cascade's `Chat:scrub_owner` cap is present AND the principal's caps set is the disjoint union of `Catalog.caps_for!(uri)` PLUS the structural self-`:list_caps` cap that Identity.init_slice/1 grants every Entity Kind". Threat model now acknowledged: the principal can read its own caps (`Identity.list_caps` on `system://entity-deletion-cascade`) — a no-op operation that does not escalate (it returns the same MapSet). The cascade principal CANNOT invoke anything besides Chat:scrub_owner on Sessions OR Identity.list_caps on itself. The structural self-cap is documented as benign per the existing PR-OWN-3 design (`identity.ex:100-122` rationale).
- **MED-4.4 (B2 timeout return shape under-specified):** codex r3 found that r3 §3.3 step 4 introduces a Process.monitor + receive with a short timeout but does NOT specify what happens on timeout. §3.2 lists three return shapes (`:ok | :partial | :error`) but none describes the post-tombstone-timeout state. §3.9 assumes a dead pid. **Fix:** §3.3 explicitly documents the timeout path: if the DOWN message does not arrive within the timeout, `tombstone_and_kill/1` returns `{:error, :kill_timeout}` AND leaves the tombstone installed (DB + ETS — they are durable, the kill is the only retry-able step). The Behavior at §3 maps this to `{:error, {:partial, %{step_failed: :tombstone_and_kill_kill_timeout, ...}}}` because the tombstone is irreversible (no future dispatch can resurrect the Kind via boundaries 1/2/3) but the live process is still consuming resources. Operator runbook: SIGKILL the BEAM node or wait for OS-level supervisor restart. §3.9 updated: the "Kind dead" assumption is reframed as "Kind dead OR scheduled to die — either way structurally unreachable through dispatch".
- **MED-4.5 (INV-15 doesn't exercise pre-backfill NULL row):** codex r3 found that INV-15 only asserts the POST-backfill state where NULL rows are impossible by construction; it does NOT test the transitional cascade query's second clause (the NULL-safety branch in §3.5). **Fix:** new INV-15a explicitly constructs a pre-backfill scenario: insert a row with `worker_uri: nil`, then invoke Worker deletion for the URI derived from that row's `(session_uri, adapter_id, target_id)`; assert the row is deleted (via the transitional branch). INV-15 still asserts the post-backfill steady state.
- **LOW-4.6 (§11 stale r2 prompts):** codex r3 found §11 still contains review prompts that were resolved or rendered inaccurate by r3 (KindRegistry.list_matching reference, operator-caller authorization claim, terminate/2 drain claim, Session.owner/1 returning error path claim). **Fix:** §11 questions 1-9 reworded to align with r3 normative text. The question stems remain (codex still attacks these areas in r4) but the framing matches the post-r3 reality.

**r3 changes (preserved — codex r2 verdict REJECT — 6 findings resolved):**

- **CRIT-3.1 (`:scrub_owner` unsatisfiable for cascade caller):** codex r2 found that the proposed Chat action `:scrub_owner` with `cap(:any, Chat, :scrub_owner)` would fail CapBAC at `Kind.Runtime.authorize/4` (`apps/ezagent_core/lib/ezagent/kind/runtime.ex:249`) — the operator's `:delete` cap on EntityDeletion does NOT satisfy `Chat:scrub_owner`, and the r2 example dispatch did not provide `ctx.caps` or a system caller. **Fix:** the cascade dispatches `:scrub_owner` AS the dedicated system principal `system://entity-deletion-cascade` (new entry in `Ezagent.SystemPrincipal.Catalog` carrying ONLY `Capability{kind: Ezagent.Entity.Session, behavior: Ezagent.Behavior.Chat, action: :scrub_owner, instance: :any, workspace_uri: :any}` — narrowly scoped per `feedback_let_it_crash_no_workarounds`). `Behavior.EntityDeletion` step 4 ensures the principal via `SystemPrincipal.ensure/1` once at install time (PR-B Application boot) and the cascade builds the dispatch envelope with `caller = SystemPrincipal.uri("entity-deletion-cascade")` + `caps = SystemPrincipal.caps("entity-deletion-cascade")`. This is structurally narrow — the principal cannot do anything else. §3.5 + Catalog entry + INV-13a updated accordingly.
- **CRIT-3.2 (cold-session `Session.owner/1` doesn't consult tombstones):** codex r2 found that production `Session.owner/1` (`apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:649-657`) reads only the live `:chat` slice via `Ezagent.Kind.get_slice/2` and returns `{:ok, owner_uri}` unconditionally — it does NOT check User existence or tombstones. A cold-loaded Session with stale `owner_uri = target` would keep the deleted user as its data owner, defeating B3's safety argument. **Fix:** `Chat.data_owner/1` (`apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:1333-1342`) gains a tombstone defense check — after `Session.owner/1` returns `{:ok, %URI{} = owner}`, call `SpawnRegistry.tombstoned?(owner)`; if true, return `:no_owner` instead of the URI. This is defense-in-depth at the read site (parallel to INV-14's Token.verify check), AND the cascade still does the proactive in-memory scrub for live Sessions. INV-13b added: cold-load a Session with stale `owner_uri` AFTER deletion; assert `Chat.data_owner/1` returns `:no_owner`.
- **CRIT-3.3 (B5 backfill path under-specified):** codex r2 found that §9.3 defines only a discovery task for snapshot orphans, NOT an idempotent `worker_uri` backfill; the cascade `WHERE worker_uri = target` silently skips NULL rows; the NOT NULL migration has no documented pre-condition. **Fix:** new mix task `mix ezagent.entity.deletion.backfill_worker_uri` defined explicitly in §4.2 + §9.1 — idempotent (sets `worker_uri` ONLY where NULL, derives via `WorkerSpawn.worker_uri_for/3`, logs row count), with a documented pre-condition check (`SELECT count(*) FROM external_mirror_bindings WHERE worker_uri IS NULL`) that the follow-up `NOT NULL` migration runs first and aborts if non-zero. PR-B also includes a defensive read-path: the cascade does `Repo.delete_all(...)` against `WHERE worker_uri = target OR worker_uri IS NULL AND <derived match>` as a transitional safety net, removed in the follow-up PR after `NOT NULL` lands. INV-15 added: after PR-B + backfill, every row has non-NULL `worker_uri` matching `WorkerSpawn.worker_uri_for(session_uri, adapter_id, target_id)`.
- **HIGH-3.4 (B6 Token.verify defense not in PR-B change list):** codex r2 found INV-14 requires `Token.verify/2` to reject tombstoned URIs but §4.1's PR-B change list omitted `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex`. **Fix:** §4.1 explicitly adds the Token.verify modification: at `verify/2` entry (BEFORE bcrypt comparison, AFTER the `uri_str` derivation), call `Ezagent.SpawnRegistry.tombstoned?(uri)`; if true, run `Bcrypt.no_user_verify()` (timing-leak-safe per the existing pattern at `token.ex:112`) and return `{:error, :tombstoned}`. Structural placement BEFORE bcrypt is correct: we don't want to advertise that a token row exists or even that the URI was ever provisioned. INV-14 phrasing updated.
- **MED-3.5 (§3.9 brutal_kill / cast semantics misstated):** codex r2 found `:brutal_kill` bypasses `terminate/2` entirely (so the "drains the mailbox" claim is wrong), AND `GenServer.cast` to a killed process returns `:ok` (the cast was already sent; the process death drops the message silently — there's no `{:error, :noproc}` for casts). **Fix:** §3.9 rewritten to state the truth: (1) `brutal_kill` skips `terminate/2`; mailbox messages are dropped, not drained; (2) in-flight `cast` returns `:ok` on the sender side and is silently lost (this is acceptable because boundary 3 refuses re-spawn — the next dispatch attempt gets `:tombstoned` cleanly); (3) in-flight `call` returns `{:error, :noproc}` from the link-monitor; (4) Kind's persistence is durable via the SYNCHRONOUS pre-kill snapshot save in `tombstone_and_kill/1`'s ordering (see Appendix A — DB tombstone insert happens BEFORE the kill, so even if any in-flight cast is lost, the entity is structurally gone). Concretely: the §3.3 atomic primitive ordering is updated to (1) DB insert, (2) ETS insert, (3) `Process.exit(pid, :brutal_kill)`, (4) Process.monitor + receive `{:DOWN, ...}` (NOT a `terminate/2` drain — there isn't one). The "wait for terminate to complete" phrasing is replaced with "wait for the registered pid's DOWN message via Process.monitor".
- **LOW-3.6 (ZH §3.5 cascade tables not byte-identical):** codex r2 found EN cascade markers `[B3 — see below]` / `[B5 — see below]` / `[B6]` differ from ZH `[B3 —— 见下]` / `[B5 —— 见下]` / `[B6]`. The instruction was "byte-for-byte" not "semantically aligned". **Fix:** ZH §3.5 cascade table code blocks now use the EN annotations VERBATIM (`[B3 — see below]`, `[B5 — see below]`, `[B6]`) — these are structural markers, not narrative prose, and the byte-identical rule applies. Surrounding paragraphs remain translated.

**r2 changes (preserved — codex r1 verdict REJECT — 6 blockers + 3 nits resolved):**

- **B1 (CRIT — multi-boundary tombstone enforcement):** r1 §3.3 + PR-B only guarded tombstone at `Ezagent.SpawnRegistry.spawn/1`. But production has direct `Ezagent.Kind.spawn/2` paths (`apps/ezagent_core/lib/ezagent/kind.ex:293-308`) and `Ezagent.ExternalMirror.WorkerSpawn` (`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/worker_spawn.ex:72-113`) that build child specs via `DynamicSupervisor.start_child/2` directly — bypassing the SpawnRegistry layer entirely. Boot path was also unresolved: `Ezagent.Kind.Server.init/1` (`apps/ezagent_core/lib/ezagent/kind/server.ex:103-130`) loads slice state without tombstone consultation. **Fix:** §3.3 + §4.1 rewritten to make tombstone enforcement authoritative at THREE boundaries: (1) `Ezagent.Kind.Server.init/1` (the only chokepoint every Kind start traverses) — this is the source-of-truth check; (2) `Ezagent.Kind.spawn/2` (pre-check before `DynamicSupervisor.start_child`); (3) `Ezagent.SpawnRegistry.spawn/1` (pre-check before scheme-dispatch). Tombstone ETS table loaded BEFORE `KindSupervisor` boots, in `EzagentCore.Application.start/2`. Backfill mix task demoted to DISCOVERY/CLEANUP (not source of truth) in §9.3.
- **B2 (CRIT — atomic primitive replaces race-prone sequence):** r1 had THREE inconsistent descriptions of the kill-vs-tombstone ordering (§3 :110-112 sequential, §10 OQ-2 :495-498 "kill FIRST then DB", §11 q2 :528-530 "kills the Kind THEN installs the tombstone"); only Appendix A showed `SpawnRegistry.tombstone_and_kill/1` atomic. **Fix:** `Ezagent.SpawnRegistry.tombstone_and_kill/1` promoted to the SOLE normative primitive in §3.3 with an atomicity contract: tombstone DB row + ETS row + Kind brutal_kill happen as one operation; rollback discipline on partial failure. OQ-2 DELETED (resolved by atomicity, moved to §10 RESOLVED). §11 q2 rewritten to attack the new primitive instead of the obsolete race.
- **B3 (CRIT — Session owner scrub had no real DB target):** r1 §3.5 listed `:scrub_owner_uri_to_tombstone → UPDATE sessions SET owner_uri = '<deleted>' WHERE owner_uri = target`. But there is NO `sessions` DB table — Session `owner_uri` lives only in the LIVE `:chat` slice (`apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:132-145`) and is persisted via the standard `kind_snapshots` mechanism. The deleted user's URI continued to drive `data_owner/1` (`chat.ex:1318-1336`), meaning a deleted owner could still author grants. **Fix:** the cascade step now dispatches a new `Behavior.Chat.invoke(:scrub_owner, ...)` action against EVERY session Kind whose live slice has `owner_uri == target_user_uri`, mutating the slice in-memory and persisting via Kind's existing snapshot strategy. New cascade step `:scrub_session_owner_uri`. New INV-13 asserts `data_owner/1` returns `:no_owner` for previously-owned sessions after a User deletion.
- **B4 (CRIT — workspace deletion scope contradiction):** r1 PR-C plan added a `workspaces_live.ex` delete button but `workspace://<name>` URIs cannot route through the `entity_scheme/0 + entity_subscheme/0` Adapter dispatch (different scheme entirely). **Fix:** Workspace deletion EXCLUDED from this SPEC's scope. PR-C item removed. §10 OQ-4 marked RESOLVED (out of scope) with a forward-looking note pointing to a future dedicated Workspace lifecycle SPEC. Rationale: workspace deletion is structurally distinct (cascade-deletes ALL workspace members + templates + sessions + bindings; far more complex than a single-URI entity) and deserves its own SPEC, not a side-channel through this Adapter machinery.
- **B5 (CRIT — Worker cascade `bound_by` column was wrong target):** r1 §3.5 Worker cascade had `:drop_external_mirror_bindings → delete external_mirror_bindings WHERE bound_by = target` where target is the worker URI. But `bound_by` is the CREATING USER URI (`apps/ezagent_core/priv/repo/migrations/20260607000000_pr_em_3_external_mirror_bindings.exs:54`), and the Worker URI is DERIVED from `(session_uri, adapter_id, target_id)` via `Ezagent.ExternalMirror.WorkerSpawn.worker_uri_for/3` (`worker_spawn.ex:217-230`). The query as written would match ZERO rows for any Worker deletion. **Fix:** Per `feedback_let_it_crash_no_workarounds` (structural over policy), add a persisted `worker_uri` column to `external_mirror_bindings` (forward-only schema migration; new column, populated by `:bind` action body going forward; backfill via the same PR-A mix task). Worker cascade now uses `WHERE worker_uri = target` directly. Bonus: `bound_by` is unchanged — it still records creator identity for audit (which the User cascade scrubs separately).
- **B6 (CRIT — entity_tokens not in cascade):** r1 missed `entity_tokens` table entirely. Token rows persist per `entity_uri` (`apps/ezagent_core/priv/repo/migrations/20260525000000_pr142_entity_tokens.exs:24-35`); `Ezagent.Entity.Token.verify/2` (`apps/ezagent_domain_identity/lib/ezagent/entity/token.ex:155-181`) authenticates any matching row regardless of whether the principal entity exists. After User or Agent deletion, surviving tokens would continue to authenticate the ghost. **Fix:** `:revoke_entity_tokens → delete entity_tokens WHERE entity_uri = target` added to BOTH User cascade AND Agent cascade (§3.5). New INV-14: `Token.verify/2` rejects any token whose `entity_uri` is tombstoned — defense-in-depth even if a row escapes the cascade.
- **N1 (Nit — SpawnRegistry public API leak):** r1 §3.3 exposed both `tombstone/1` and `tombstone_and_kill/1`. Per plugin isolation north-star, adapters must never touch tombstones directly. **Fix:** `tombstone/1` made private (used only by the internal atomic primitive); `tombstone_and_kill/1` is the SOLE public primitive. `tombstoned?/1` remains public (read-only check, used by Kind.Server.init/1).
- **N2 (Nit — audit row trace_id parent grouping):** r1 §3.5 said cascade emits per-step audit rows but didn't specify trace correlation. The existing `invocations` table (`apps/ezagent_core/priv/repo/migrations/20260515160000_phase1_audit_dlq_snapshots.exs:5-20`) already carries `trace_id`. **Fix:** §3.5 explicitly says all cascade sub-rows share the parent `entity.deleted` row's `trace_id` so audit consumers can group by trace. No schema change.
- **N3 (Nit — bilingual sync):** EN + ZH parity confirmed in r1. r2 changes propagated to `.zh_cn.md` in lockstep.

**r1 changes (preserved):** Initial draft; problem statement + Behavior + Adapter + tombstone + cascade + INV table.

**Tier:** `Ezagent.Behavior.EntityDeletion` (new) in `apps/ezagent_core/`, with per-entity-type `DeletionAdapter` modules in `apps/ezagent_domain_identity/` (User), `apps/ezagent_domain_chat/` (Agent), `apps/ezagent_domain_external_mirror/` (Worker). Admin LV integration in `apps/ezagent_plugin_liveview/`.

**Trigger:** Allen 2026-05-28 — after observing the `system/linyilun` ghost-user problem (deleted from DB + snapshot, but Kind keeps respawning, so the "deleted" user can still be addressed through LV / Feishu binding routing / dispatch). Allen's diagnosis: "should we add forced-logout at runtime, not just LV?".

**Companion:** `2026-05-28-entity-deletion.zh_cn.md` (per `feedback_bilingual_docs_convention`).

**Predecessor memories (load-bearing):**
- `feedback_let_it_crash_no_workarounds` — no shim, no dual-path. Deletion is atomic-cascade-or-explicit-failure. No "soft delete" with a flag (we considered + rejected in §7). r2 B5 picks the structural column-add over the lookup hack per this principle.
- `feedback_north_star_plugin_isolation` — the generic `EntityDeletion` Behavior lives in `ezagent_core`; per-entity-type cascade logic lives in its OWN domain app via the `DeletionAdapter` callback. Future entity types (Worker, Cap, Template — see §3.6) add via DeletionAdapter, never touch core.
- `feedback_completion_requires_invariant_test` — the merge gate is an invariant test that proves a deleted entity is unreachable through EVERY routing surface (KindRegistry, SpawnRegistry, LV mount, Feishu sender resolution, dispatch). r2 adds INV-13 + INV-14.
- `feedback_uuid_is_canonical_identifier` — operate on URIs not on display names. Cascade scrubs all references by URI.
- `feedback_destructive_migration_anti_pattern` — deletion of LIVE entity in production-shaped environments needs operator awareness. SPEC includes an LV confirm-dialog flow + `mix ezagent.entity.delete` CLI gate.

**Parent / historical context:**
- `system/linyilun` retire (2026-05-26): partial deletion that exposed the gap. caps_json was emptied, password_hash nulled, users row deleted, snapshot deleted — but the in-memory Kind kept respawning from SpawnRegistry catch-all. This is the empirical proof that DB-side cleanup is insufficient.
- `2026-05-27-workspace-cap-based-visibility.md`: `Workspace.list_workspaces_for/2` uses cap-membership to derive visibility. A deleted user should be unreachable through this path too (their caps + memberships drop together).
- `2026-05-27-uri-canonicalization.md`: deletion cascade compares URIs with strict equality; canonical URI form makes the cascade audit reliable.
- `feedback_register_lookup_key_parity`: the entity spawn lookup (`SpawnRegistry.spawn → entity_spawn_fn → User.from_uri`) and the deletion must use the SAME identity key. Diverging keys = ghost reintroduction risk.

---

## §1 Problem statement — there is no deletion lifecycle

### 1.1 The empirical observation

Allen attempted to retire `entity://user/system/linyilun` on 2026-05-26:

1. **DB level (manual SQL via Ecto)** — completed:
   - `users` row: DELETED ✓
   - `entity_profiles` row: DELETED ✓
   - `kind_snapshots` row: DELETED ✓
   - `feishu_user_bindings` rebound to `system/admin` ✓ (correct mitigation)

2. **Runtime level** — left dangling:
   - `KindRegistry.lookup("entity://user/system/linyilun")` STILL returns `{:ok, pid}`
   - `Process.exit(pid, :brutal_kill)` → supervisor restarts → new pid (still alive)
   - 3 successive `brutal_kill` attempts with snapshot deleted between each: ghost still alive at next lookup

3. **User-facing symptoms** (Allen reported 2026-05-28):
   - "I can still log in as system/linyilun and enter the system workspace" — caller_uri stays valid because Kind responds
   - "Switching to h2oslabs still shows me as system/linyilun" — LV display name + cookie session identity still resolves to the ghost
   - Dispatch attempts as system/linyilun get `chat.join` cap denied — caps_json is `[]` (correct) so authorization fails, but the IDENTITY itself is not "deleted"; it's "exists but has no permissions"

The cap-emptied + DB-row-deleted ghost is the worst kind of half-deleted state: **operations look like permission denials, not identity-not-found errors**. Operator UX suggests "this user has no caps" not "this user does not exist".

### 1.2 Why this matters (the broader contract)

**Identity in this codebase is operationally definable as "the URI is reachable through dispatch"**. A user URI is "deleted" iff:

- `Users.get_by_uri/1` returns `nil`
- `Ezagent.SpawnRegistry.spawn(uri)` returns `{:error, :tombstoned}` (NOT auto-creates)
- `Ezagent.Kind.spawn(kind_module, %{uri: uri, ...})` returns `{:error, :tombstoned}` (the OTHER spawn boundary)
- `Ezagent.Kind.Server.init/1` refuses to boot (last-line-of-defense at the Kind start chokepoint)
- `Ezagent.KindRegistry.lookup(uri)` returns `:error`
- No Kind respawns from any path (snapshot, workspace member, Feishu binding, LV session cookie, dispatch from another agent's reply, adapter reconcile, …)
- `Workspace.list_workspaces_for/2` excludes them from every caller's view
- All historical references to the URI (sessions.owner_uri in live slice, caps.granted_by, audit rows) either point to a tombstone sentinel OR are scrubbed (see §3.7)
- `Token.verify/2` rejects every token whose `entity_uri` is tombstoned (defense in depth)

Today none of these are enforced as a unit. Each is a separate ad-hoc cleanup. Operators trying to "delete a user" follow no playbook; missing one step leaves a ghost.

### 1.3 Why "logout" is insufficient (Allen's framing refinement)

Allen's initial framing: "force runtime logout at User.Deletion". Logout-only is necessary-but-insufficient:

- Logout drops the LV/web session cookie → caller_uri becomes invalid for future requests
- But the Kind GenServer still alive in memory → other dispatches addressed at the URI succeed
- The Kind respawns on next lookup → logout would need to be repeated indefinitely

The structural fix is `EntityDeletion`: an atomic, audited, cascade operation that makes the URI **structurally unreachable** through every routing path — logout falls out as ONE consequence among many.

### 1.4 Bug class this prevents

- "I deleted user X but they can still send Feishu messages" (Feishu binding lookup hits a still-alive Kind)
- "I deleted user X but the session they own still routes to them" (sessions slice owner_uri unscrubed → Chat.data_owner returns the dead URI)
- "I deleted user X but their old cli token still authenticates" (entity_tokens row survives)
- "I deleted agent Y but its cc bridge is still connected" (sidecar / PTY / bridge_registry entry orphaned)
- "I removed user X from workspace W but they can still see W in their dropdown" (caps not revoked)
- "On rare boot, deleted user X resurrects" (snapshot reload race + missing tombstone)
- "I deleted Worker W but external_mirror_bindings still cause adapter reconcile to spawn a fresh one" (cascade column mismatch — r1 bug)

All seven are observed or theoretically observable today. EntityDeletion + DeletionAdapter make every one a regression test.

---

## §2 Decision: **`Ezagent.Behavior.EntityDeletion` + per-entity-type `DeletionAdapter`**

A single Behavior owns the deletion lifecycle. Per-entity-type cascade specifics live in a `DeletionAdapter` module the entity's domain implements + registers (same pattern as `Ezagent.AgentBridge.Adapter` from PR-G).

```elixir
defmodule Ezagent.Behavior.EntityDeletion do
  # Behavior actions: :delete (cap-gated, audited, cascade)
  # actions/0: [:delete]
  # required_caps/0: kind: :entity, behavior: __MODULE__, action: :delete
end

defmodule Ezagent.EntityDeletion.Adapter do
  # Behaviour callbacks every entity-type domain implements
  @callback entity_scheme() :: String.t()                 # "entity"
  @callback entity_subscheme() :: String.t()              # "user", "agent", "worker"
  @callback cascade_steps(URI.t(), %{caller: URI.t(), reason: String.t()}) ::
              [{step_name :: atom(), Ezagent.EntityDeletion.CascadeStep.t()}]
  @callback can_delete?(URI.t(), %{caller: URI.t()}) ::
              :ok | {:error, reason :: atom() | {atom(), term()}}
end
```

The Behavior owns the **structural sequence**:

1. **Pre-check** — `Adapter.can_delete?/2` (e.g. "can't delete bootstrap admin", "can't delete user who is the sole member of a workspace they own", per-adapter business rules)
2. **Atomic tombstone-and-kill** — `Ezagent.SpawnRegistry.tombstone_and_kill/1` (the new sole-normative primitive — see §3.3); installs tombstone in DB + ETS + brutal_kills the Kind in one synchronous operation
3. **Snapshot purge** — delete `kind_snapshots` row, audited
4. **DB cascade** — run `Adapter.cascade_steps/2` in order (each step idempotent + audited, sharing parent trace_id)
5. **Cross-reference scrub** — sessions slice owner_uri / caps.granted_by / membership lists → tombstone sentinel (live-Kind dispatch where applicable; see §3.5 B3 fix)
6. **Audit emission** — single `entity.deleted` event with full cascade summary

Each step records to the `invocations` audit table; the operation as a whole is atomic from the operator's perspective (success = all cascade steps completed AND tombstone installed).

The field-name parallels are intentional: this SPEC reuses the established Behavior contract (`actions/0`, `required_caps/0`, `invoke/4`) + the Adapter pattern from PR-G, so plugin authors writing a new entity type follow the SAME wire format they already know.

---

## §3 Semantics — `Behavior.EntityDeletion` defined precisely

### 3.1 Inputs

- `target_uri` — the `%URI{}` of the entity being deleted. MUST match a `DeletionAdapter`'s `entity_scheme/0 + entity_subscheme/0` filter (so `entity://user/...` routes to UserDeletionAdapter, `entity://agent/...` routes to AgentDeletionAdapter, etc).
- `caller_uri` — the operator doing the deletion. MUST hold `:delete` cap (per `required_caps/0`). Admin-only by default; per-adapter policy MAY narrow (e.g. workspace admin can delete users in their workspace, but not cross-workspace; see `Adapter.can_delete?/2`).
- `reason` — operator-supplied free-text. Stored in the audit row. NOT optional.

### 3.2 Output

```elixir
{:ok, %{
  deleted_uri: URI.t(),
  steps_completed: [step_name :: atom()],
  cascade_summary: %{deleted: integer(), scrubbed: integer(), tombstoned: integer()},
  audit_event_id: binary(),
  trace_id: binary()
}}
| {:error, {:partial, %{
   step_failed: atom(),
   steps_completed: [atom()],
   reason: term(),
   recovery_hint: String.t(),
   trace_id: binary()
}}}
| {:error, {:precheck_failed, term()}}
```

**Three return shapes** parallel the Generator-Reconciler three-arm (`:ok | :partial | :error`):

- `{:ok, summary}` — every cascade step completed, tombstone installed, audit emitted.
- `{:error, {:partial, _}}` — pre-check passed, tombstone-and-kill done (DB + ETS irreversible), but at least one of (a) the kill confirmation (`{:DOWN, ...}`) timed out (MED-4.4), OR (b) a downstream DB cascade step failed. The tombstone is durable (boundaries 1/2/3 refuse re-spawn) but cross-reference scrub may be incomplete. The two `:partial` subshapes are distinguished by `step_failed`:
  - `step_failed: :tombstone_and_kill_kill_timeout` — tombstone installed, kill signal sent, but DOWN message did not arrive in time. Live process may still consume resources. Operator runbook in `recovery_hint`: SIGKILL the BEAM node or wait for the OS-level supervisor cycle. The deleted URI is already structurally unreachable through dispatch — this is a cleanup concern, not a correctness one.
  - `step_failed: :<cascade_step_name>` — a specific cascade step raised. Other cascade steps may have run; `steps_completed` lists those that succeeded.
- `{:error, {:precheck_failed, _}}` — no state was mutated. Adapter's `can_delete?/2` refused (e.g. bootstrap admin protection).

The `trace_id` is propagated into every cascade sub-row in `invocations` for downstream audit grouping (N2 fix — see §3.5).

### 3.3 Tombstone — multi-boundary enforcement (B1) + atomic primitive (B2)

**This is the structural fix for the ghost-respawn problem.** r1 had two distinct gaps:

(a) **Single-boundary check.** r1 guarded tombstone only at `SpawnRegistry.spawn/1`. But the production code has MULTIPLE Kind-spawn paths that bypass SpawnRegistry:

- `Ezagent.Kind.spawn/2` (`apps/ezagent_core/lib/ezagent/kind.ex:293-308`) — direct `DynamicSupervisor.start_child` of `{Ezagent.Kind.Server, {kind_module, params}}`. Called by every domain Application boot + the SpawnRegistry's own registered fns.
- `Ezagent.ExternalMirror.WorkerSpawn.spawn/4` (`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/worker_spawn.ex:72-113`) — builds PerBindingSupervisor child spec; called from `Behavior.ExternalMirror.invoke(:bind, ...)` AND from `AdapterInstall.reconcile_persisted_bindings/1` (`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_install.ex:193-220`) on adapter install.
- Boot-time `Kind.Server.init/1` from snapshot reload (`apps/ezagent_core/lib/ezagent/kind/server.ex:103-130`) — any path that hands a `(kind_module, args)` pair to the `Kind.Server` GenServer.

(b) **Race-prone non-atomic sequence.** r1's three normative passages contradicted each other on whether to kill first or tombstone first. Any non-atomic ordering admits a race: between kill and tombstone-install, a concurrent spawn can resurrect the Kind.

**r2 fix — three boundaries + one atomic primitive:**

The **atomic primitive** is the only public mutation API:

```elixir
defmodule Ezagent.SpawnRegistry do
  @doc """
  Atomically tombstone + kill. The SOLE public primitive for installing
  a tombstone. Plugin code (DeletionAdapters) MUST go through this.

  Atomicity contract:
    1. INSERT entity_tombstones row (DB).
       If fails → return {:error, {:tombstone_db_failed, _}}; no other
       mutation has occurred.
    2. :ets.insert(@tombstone_table, ...) (ETS mirror).
       If fails (extremely unlikely — protected ETS) → DELETE the DB
       row inserted in step 1; return {:error, {:tombstone_ets_failed, _}}.
    3. Process.exit(pid, :brutal_kill) — bypasses terminate/2 entirely
       (this is intentional; see §3.9 for why the cascade does NOT rely
       on graceful terminate semantics for the deleted Kind).
    4. Process.monitor(pid) + receive {:DOWN, _ref, :process, pid, _reason}
       with a short timeout (5s by default — defensive against a stuck
       linked process holding a C-NIF). Three terminal states:
       - DOWN arrived: return :ok.
       - pid was already absent (never registered or died mid-call):
         return :ok (steps 1+2 still hold).
       - timeout elapsed without DOWN: return {:error, :kill_timeout}.
         Tombstone (DB + ETS) is STILL installed and durable, and
         boundaries 1/2/3 already refuse RE-SPAWN once the live pid
         dies. HOWEVER — see HIGH-5.3 in §3.9 — for the brief window
         the live pid survives the brutal_kill signal (e.g. trapping
         in a C-NIF), Invocation.dispatch/1 calls KindRegistry.lookup/1
         (apps/ezagent_core/lib/ezagent/invocation.ex:87-107 +
         kind_registry.ex:59-64) which returns the still-registered pid
         and delivers casts/calls directly without consulting the
         tombstone table. The Behavior at §3 maps this to
         {:error, {:partial, step_failed: :tombstone_and_kill_kill_timeout,
         ...}} per §3.2 — the structural cleanup is bounded (the URI
         is permanently un-respawnable) but not instantaneously
         complete (the live pid may briefly continue serving messages).

  Because the DB row is committed BEFORE the kill, a BEAM crash between
  steps 1 and 4 leaves the tombstone authoritative on next boot — the
  Kind cannot resurrect because Kind.Server.init/1 (see boundary 1 below)
  refuses to boot any tombstoned URI.
  """
  @spec tombstone_and_kill(URI.t()) :: :ok | {:error, term()}
  def tombstone_and_kill(%URI{} = uri), do: ...

  @doc "Read-only check used by boundaries 1/2/3 below + diagnostics."
  @spec tombstoned?(URI.t()) :: boolean()
  def tombstoned?(%URI{} = uri), do: :ets.member(@tombstone_table, URI.to_string(uri))

  # PRIVATE — internal to the atomic primitive.
  # No plugin code may call this directly. (N1 fix)
  defp tombstone(uri), do: ...
end
```

The **three enforcement boundaries**:

**Boundary 1 (authoritative — every Kind start traverses this):** `Ezagent.Kind.Server.init/1`. Before `Ezagent.Kind.Snapshot.load_or_init/3` runs, check `SpawnRegistry.tombstoned?(uri)`. If true, return `{:stop, :tombstoned}` and the GenServer never registers. This is the source-of-truth check because EVERY Kind start — whether through `Kind.spawn/2`, `WorkerSpawn.spawn/4`, `DynamicSupervisor.start_child/2` from a custom plugin, or a supervisor restart from a snapshot — eventually calls `Kind.Server.init/1`. The other two boundaries are defense-in-depth.

**Boundary 2:** `Ezagent.Kind.spawn/2`. Pre-check tombstone BEFORE `DynamicSupervisor.start_child`. If tombstoned, return `{:error, :tombstoned}`. Saves the wasted supervisor cycle of starting a process that boundary 1 would then kill.

**Boundary 3:** `Ezagent.SpawnRegistry.spawn/1`. Pre-check tombstone BEFORE scheme-dispatch. Same rationale as boundary 2 — short-circuits the dispatch fn (which would call `Kind.spawn/2` and trigger boundary 2 anyway). Provides a clearer error at the SpawnRegistry layer for callers (`Workspace.list_workspaces_for/2`'s reconcilers, LV mounts, etc).

**Boot-order load.** `Ezagent.SpawnRegistry.Tombstone.load_into_ets/0` MUST run inside `EzagentCore.Application.start/2` BEFORE `Ezagent.KindSupervisor` is started (and therefore before any plugin Application's boot-time spawn paths fire). Per the current application children order, this means it slots in between `EzagentCore.Repo` (children ④) and `Ezagent.KindSupervisor` (children ⑨). The ETS table is created by `EzagentCore.EtsOwner` (children ①); the load fn populates from the DB.

**Backfill is DISCOVERY, not source of truth.** §9.3 demotes `mix ezagent.entity.deletion.backfill_tombstones` to a discovery/cleanup tool: it scans for `kind_snapshots` rows whose `entity_uri` has no matching `users` / `agents` row and lists them for the operator to review (and optionally tombstone). The backfill is NOT how production deletion works.

**`entity_tombstones` is append-only** — there's no `untombstone/1` API. To "reuse" a deleted URI, the operator must create a NEW entity at a different URI; the deleted one is permanently un-reusable. This is the structural cousin of "immutable identity" (see `feedback_uuid_is_canonical_identifier` analog: URI is the canonical identity; deletion is permanent). An admin-only SQL row-delete is documented in §9.4 (rollback) for forensic recovery, but is NOT a normal operator workflow.

### 3.4 Snapshot purge

`kind_snapshots` row delete. Trivial, ordered AFTER `tombstone_and_kill` (so if any later step fails, the snapshot points at nothing AND tombstone refuses respawn — fail-safe; ghost cannot resurrect).

### 3.5 Adapter cascade — including B3, B5, B6 fixes + N2 trace correlation

`Adapter.cascade_steps/2` returns a `[{step_name, step_fn}]` ordered list. The Behavior iterates in order, applying each step. Each step is idempotent (re-running is a no-op if state already applied).

**Trace correlation (N2):** the Behavior creates ONE `trace_id` at entry. Every cascade sub-row (`action = "entity.deleted.<step_name>"`) carries the same `trace_id` as the parent `entity.deleted` row, so audit consumers can `WHERE trace_id = ?` to retrieve the full cascade. No schema change — `invocations.trace_id` already exists (`apps/ezagent_core/priv/repo/migrations/20260515160000_phase1_audit_dlq_snapshots.exs:8`).

**User cascade** (`Ezagent.Domain.Identity.UserDeletionAdapter.cascade_steps/2`):

```
:revoke_all_caps               → Identity.revoke_all_caps(target_uri)
:revoke_entity_tokens          → Repo.delete_all(from t in EntityToken, where: t.entity_uri == ^target_uri_str)    [B6]
:drop_feishu_bindings          → delete feishu_user_bindings WHERE user_uri = target
:drop_entity_profile           → delete entity_profiles WHERE entity_uri = target
:drop_workspace_memberships    → Enum.each(workspaces, &Workspace.remove_member/2)
:drop_session_memberships      → Enum.each(sessions, &Chat.leave/2)
:scrub_session_owner_uri       → Enum.each(owned_sessions, &dispatch_chat_scrub_owner/1)    [B3 — see below]
:delete_users_row              → Repo.delete(user)
```

**B3 — Session owner scrub via real Behavior.Chat action (dispatched as a system principal — CRIT-3.1 fix).** `Behavior.Chat` (`apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:88`) declares actions `[:send, :receive, :join, :leave, :set_working_copy]` today. This SPEC adds a NEW Session-side action `:scrub_owner` with:

- `actions/0`: `[:send, :receive, :join, :leave, :set_working_copy, :scrub_owner]`
- `required_caps/0`: `:scrub_owner` declares `cap(Ezagent.Entity.Session, __MODULE__, :scrub_owner, :any, :any)` — a per-action cap, NOT `:any`. Per the capability-action-axis SPEC §3.6.1, this is a concrete atom.
- `invoke(:scrub_owner, slice, %{deleted_uri}, _ctx)`: if `slice.owner_uri == deleted_uri`, set `owner_uri: nil` (NOT a sentinel URI — `nil` falls through to `data_owner/1`'s `:no_owner` clause at `chat.ex:1337`, preserving existing semantics for system sessions). Returns `{:ok, %{owner_scrubbed: true}, slice_with_nil_owner, dispatch_envelope}` so the standard `Kind.Runtime` step 9.5 persists via `:on_change` strategy.

**Dispatch authorization (CRIT-3.1).** The operator's `:delete` cap on `Behavior.EntityDeletion` does NOT satisfy `Behavior.Chat.scrub_owner` at `Kind.Runtime.authorize/4` (`apps/ezagent_core/lib/ezagent/kind/runtime.ex:249-298`). The cascade therefore dispatches `:scrub_owner` AS a dedicated narrow system principal:

```
system://entity-deletion-cascade
  caps: [
    # MED-5.4 (r5) — use the helper, not a raw struct literal.
    # Ezagent.Capability has @enforce_keys including :granted_at; the helper
    # populates it. The Catalog's other entries use the same pattern
    # (apps/ezagent_core/lib/ezagent/system_principal/catalog.ex:132-149).
    Ezagent.Capability.cap(
      Ezagent.Entity.Session,           # kind
      Ezagent.Behavior.Chat,            # behavior
      :scrub_owner,                     # action
      :any,                             # instance (narrowed at dispatch time)
      :any                              # workspace_uri (narrowed at dispatch time)
    )
    # `granted_by` defaults to system://bootstrap/default per the catalog
    # convention (catalog.ex:101); `granted_at` is set by the helper.
  ]
```

Added to `Ezagent.SystemPrincipal.Catalog` as a new entry alongside `system://chat-router`, `system://chat-reply`, etc (`apps/ezagent_core/lib/ezagent/system_principal/catalog.ex:135+`). Structurally narrow with one CAVEAT noted below. `Ezagent.SystemPrincipal.ensure(SystemPrincipal.uri("entity-deletion-cascade"))` is called at `EzagentCore.Application.start/2` AFTER the existing system kinds registration so the principal's `:identity` slice is ready before any deletion fires.

**HIGH-4.3 — structural self-`:list_caps` cap.** `Ezagent.SystemPrincipal.ensure/1` (`apps/ezagent_core/lib/ezagent/system_principal.ex:88-92`) spawns the principal as a `Ezagent.Entity.User` Kind. `Ezagent.Behavior.Identity.init_slice/1` (`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:91-122`) unconditionally adds a SELF `:list_caps` cap to ANY Entity Kind it initializes — the PR-OWN-3 design at `:100-122` injects this so an entity can read its OWN caps (the user-facing read path `Identity.list_caps_for/1` requires it). The cascade principal's `:identity` slice therefore carries TWO caps after ensure:

1. The cascade cap (from `initial_caps`): `Capability{kind: Ezagent.Entity.Session, behavior: Ezagent.Behavior.Chat, action: :scrub_owner, ...}`
2. The structural self-cap (from `Identity.init_slice/1`): `Capability{kind: <kind_for_uri(system://...)>, behavior: Ezagent.Behavior.Identity, action: :list_caps, instance: <self>, workspace_uri: <self>}`

The self-cap is benign by design: `Identity.list_caps_for(self_uri)` returns the same MapSet that authorized the call — there is no escalation surface. The cascade principal CANNOT invoke anything besides `Chat:scrub_owner` on Sessions AND `Identity:list_caps` on its OWN URI. Threat model: an attacker who somehow assumes this principal cannot use it as a stepping stone to any other action on any other Kind. INV-13a (below) asserts the disjoint-union shape rather than the original "exactly one cap" claim.

The cascade step body:

```elixir
def scrub_session_owner_uri(target_user_uri, _ctx) do
  # Lookup is over the live registry. KindRegistry exposes `list_all/0`
  # (no list_matching — see apps/ezagent_core/lib/ezagent/kind_registry.ex:73);
  # we filter to session:// URIs and probe each for owner match.
  # Snapshotted-but-not-resident sessions are handled at READ time by
  # the Chat.data_owner/1 tombstone defense (CRIT-3.2 fix) — see below.
  # CRIT-4.1 (r4): SystemPrincipal.caps/1 enforces scheme == "system" and
  # parses its input via parse!/1; a bare service-name string ArgumentErrors
  # at apps/ezagent_core/lib/ezagent/system_principal.ex:168-176. Pass the
  # %URI{} returned by SystemPrincipal.uri/1.
  cascade_principal = Ezagent.SystemPrincipal.uri("entity-deletion-cascade")
  cascade_caps = Ezagent.SystemPrincipal.caps(cascade_principal)

  alive_sessions =
    Ezagent.KindRegistry.list_all()
    |> Enum.filter(fn {uri_str, _pid} -> String.starts_with?(uri_str, "session://") end)
    |> Enum.filter(fn {uri_str, _pid} ->
      case Ezagent.Entity.Session.owner(uri_str) do
        {:ok, %URI{} = owner} -> URI.to_string(owner) == URI.to_string(target_user_uri)
        _ -> false
      end
    end)

  Enum.reduce(alive_sessions, %{scrubbed: 0, errors: []}, fn {uri_str, _pid}, acc ->
    session_uri = Ezagent.URI.parse!(uri_str)

    case Ezagent.Invocation.dispatch(%Invocation{
           kind: Ezagent.Entity.Session,
           behavior: Ezagent.Behavior.Chat,
           action: :scrub_owner,
           target: session_uri,
           args: %{deleted_uri: target_user_uri},
           ctx: %{
             caller: cascade_principal,
             caps: cascade_caps,
             trace_id: cascade_trace_id
           }
         }) do
      {:ok, _} -> %{acc | scrubbed: acc.scrubbed + 1}
      {:error, :noproc} -> %{acc | scrubbed: acc.scrubbed}  # session died — fine
      {:error, :tombstoned} -> %{acc | scrubbed: acc.scrubbed}  # session deleted — fine
      {:error, reason} -> %{acc | errors: [{uri_str, reason} | acc.errors]}
    end
  end)
end
```

**Cold-load defense (CRIT-3.2 fix).** Production `Session.owner/1` (`apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:649-657`) reads only the live `:chat` slice and returns `{:ok, owner_uri}` unconditionally — it does NOT check tombstones. So a Session that loads from snapshot AFTER deletion still reports the deleted URI as owner. The fix is at the data-owner read site:

`Behavior.Chat.data_owner/1` (`apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:1333-1342`) gains a tombstone defense check:

```elixir
@impl Ezagent.Behavior
def data_owner(%URI{scheme: "session"} = session_uri) do
  case Ezagent.Entity.Session.owner(session_uri) do
    {:ok, %URI{} = owner} ->
      # CRIT-3.2 defense — even if the live slice (or a cold-loaded
      # snapshot) carries a stale owner_uri, the tombstone check
      # refuses to honor a deleted URI as data_owner.
      if Ezagent.SpawnRegistry.tombstoned?(owner) do
        :no_owner
      else
        owner
      end
    _ -> :no_owner
  end
end
```

This is defense-in-depth at the read site (parallel to INV-14's Token.verify check). The proactive in-memory scrub (above) handles live Sessions immediately; the read-site check covers cold loads + the lookup/dispatch race window.

**CRIT-5.2 — TWO MORE data_owner sites need the same defense.** codex r4 found that `Chat.data_owner/1` is not the only production CapBAC data-owner resolver that reads Session ownership. Two additional sites also need the tombstone check:

- `Ezagent.Behavior.ExternalMirror.data_owner/1` (`apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:593-600`) — reads the Session's `:chat.owner_uri` slice directly and returns it for ExternalMirror cap-grant authorization. Without the tombstone check, a cold-loaded Session with stale `owner_uri = target` would still authorize the deleted user via ExternalMirror caps (e.g. binding management).
- `Ezagent.Behavior.Publisher.SessionImpl.data_owner/1` (`apps/ezagent_domain_chat/lib/ezagent/behavior/publisher/session_impl.ex:136-144`) — calls `Session.owner/1` and returns the owner URI directly for Publisher cap-grant authorization.

Both need the identical pattern: after fetching the owner URI, call `Ezagent.SpawnRegistry.tombstoned?(owner)`; if true, return `:no_owner`. The PR-B change list (§4.1) explicitly adds these two file modifications.

INV-13b's assertion is expanded to test all THREE data_owner resolvers in a single cold-load scenario.

**Session-deleted-between-lookup-and-dispatch race:** if a Session Kind dies between `KindRegistry.list_all/0` and `Invocation.dispatch/1`, dispatch returns `{:error, :noproc}`. The cascade treats this as success (the session is gone; there's nothing to scrub). If the Session was tombstoned (by a concurrent Session deletion), dispatch returns `{:error, :tombstoned}` from boundary 1 — also treated as success. The cascade step's idempotency contract holds: re-running is a no-op.

**Agent cascade** (`Ezagent.Domain.Chat.AgentDeletionAdapter.cascade_steps/2`):

```
:stop_sidecars                 → flavor-specific (cc bridge / codex PTY+app-server / curl ...)
:unbind_bridge_registry        → BridgeRegistry.unbind(agent_uri)
:revoke_entity_tokens          → Repo.delete_all(from t in EntityToken, where: t.entity_uri == ^target_uri_str)    [B6]
:drop_session_memberships      → Enum.each(sessions, &Chat.leave/2)
:scrub_mention_routing_rules   → RoutingRules.remove_by_target(agent_uri)
:revoke_agent_api_keys         → AgentApiKeys.revoke_all(agent_uri)
:drop_agent_lineage            → AgentLineage.delete(agent_uri)
:delete_workspace_template     → Workspace.remove_template/3 (if registered)
```

**Worker cascade** (`Ezagent.Domain.ExternalMirror.WorkerDeletionAdapter.cascade_steps/2`):

```
:drop_external_mirror_bindings → see B5 cascade query below                                   [B5 — see below]
:unsubscribe_session_publisher → Publisher.unsubscribe(target)
:terminate_adapter             → adapter_module.terminate(target)
```

**B5 — Worker cascade column fix + r3 backfill specification (CRIT-3.3).** r1's `WHERE bound_by = target` was wrong: `bound_by` records the CREATING USER URI per `apps/ezagent_core/priv/repo/migrations/20260607000000_pr_em_3_external_mirror_bindings.exs:54`, while the Worker URI is structurally derived from `(session_uri, adapter_id, target_id)` via `WorkerSpawn.worker_uri_for/3` (`worker_spawn.ex:217-230`) and NOT stored in the table.

Per `feedback_let_it_crash_no_workarounds` (structural over policy), the r2 fix adds a persisted `worker_uri` column to `external_mirror_bindings`. r3 fully specifies the backfill + cascade race-free behavior:

- **Forward-only migration A** (`apps/ezagent_core/priv/repo/migrations/<timestamp>_pr_a_worker_uri_column.exs`): `add :worker_uri, :string, null: true` initially (to allow backfill on pre-r2 rows). Adds index `create index(:external_mirror_bindings, [:worker_uri])` for the cascade query. Greenfield deployments (dev / test) start with the column from day one.
- **Backfill task `mix ezagent.entity.deletion.backfill_worker_uri`** (new in PR-B, NOT the discovery task — that's a different unrelated tool):
  - **Idempotent:** `WHERE worker_uri IS NULL` filter; only NULL rows are updated.
  - **Derivation:** for each NULL row, parse `session_uri`, compute `WorkerSpawn.worker_uri_for(parsed, adapter_id, target_id)`, write the result back as a string.
  - **Logging:** prints count of updated rows + count of remaining NULL rows. Exits 0 on full success; non-zero if any derivation raises (per `feedback_let_it_crash_no_workarounds` — bad row is a bug, not a soft-fail).
  - **Operator workflow:** runs once between Migration A and Migration B; mix task is operator-runnable without phx restart.
- **Forward-only migration B** (`apps/ezagent_core/priv/repo/migrations/<later_timestamp>_pr_a_worker_uri_not_null.exs`): the `NOT NULL` flag. Pre-condition check executes BEFORE the alter: `SELECT count(*) FROM external_mirror_bindings WHERE worker_uri IS NULL`; if non-zero, the migration aborts with a clear error pointing the operator at the backfill task. The follow-up migration belongs to PR-A (this SPEC's impl pair) but runs ONLY after the backfill task has been run; documented in §9.1.
- **Write path (CRIT-4.2 — three places must change, not just the action body):**
  1. **Schema:** `Ezagent.ExternalMirror.BindingRow` (`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/binding_row.ex:42-50`) adds `field(:worker_uri, :string)` to the `schema "external_mirror_bindings"` block. `@type t` (`:54-65`) gains `worker_uri: String.t() | nil` (the type union acknowledges the transitional NULL window — narrowed to `String.t()` after Migration B).
  2. **Changeset:** `BindingRow.insert/1` (`:87-108`) adds `:worker_uri` to BOTH the `Ecto.Changeset.cast` field list (`:90-99`) AND the `Ecto.Changeset.validate_required` list (`:100-108`). Without these, Ecto silently drops the field from the attrs map (cast ignores unknown keys) and post-Migration-B inserts would fail at the DB layer instead of the changeset layer.
  3. **Action body:** `Behavior.ExternalMirror.invoke(:bind, ...)`'s persistence step in `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex` (around `:747-758`) populates `worker_uri = WorkerSpawn.worker_uri_for(session_uri, adapter_id, target_id) |> URI.to_string()` in the attrs map passed to `BindingRow.insert/1`. All NEW rows have non-NULL `worker_uri` from PR-B forward.
- **Read path:** `AdapterInstall.reconcile_persisted_bindings/1` (`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_install.ex:193-220`) still derives the Worker URI structurally (it has session_uri + adapter_id + target_id from the row); the new column is for the deletion cascade, not the reconcile path. The reconcile path is unchanged.
- **Cascade query (transitional, PR-B impl):**

  ```elixir
  # Until Migration B lands and pre-r2 NULL rows are backfilled, the
  # cascade defensively matches BOTH worker_uri-equality AND the derived
  # match for any still-NULL rows. After Migration B asserts NOT NULL,
  # the second clause is dead and can be removed in a follow-up PR.
  worker_uri_str = URI.to_string(target_worker_uri)

  # Direct match — populated rows.
  Repo.delete_all(
    from b in BindingRow,
    where: b.worker_uri == ^worker_uri_str
  )

  # Transitional safety net — defensively re-derive Worker URI for any
  # still-NULL row and compare. Removed in the follow-up PR after
  # Migration B's NOT NULL is in effect (at which point NULL rows
  # cannot exist by invariant).
  null_rows = Repo.all(
    from b in BindingRow,
    where: is_nil(b.worker_uri)
  )

  Enum.each(null_rows, fn row ->
    derived =
      WorkerSpawn.worker_uri_for(
        Ezagent.URI.parse!(row.session_uri),
        row.adapter_id,
        row.target_id
      )
      |> URI.to_string()

    if derived == worker_uri_str do
      Repo.delete(row)
    end
  end)
  ```

  Race-free + NULL-safe. The transitional second clause is gated by the same `null:` filter; once Migration B's pre-condition asserts zero NULL rows, the second clause is dead. INV-15 (added) pins the post-backfill invariant.
- **`bound_by` unchanged.** Still records creator identity. `bound_by`'s User cascade scrub belongs to the User cascade's audit-tombstone-sentinel step; not Worker-scope.

Each step records to `invocations` audit before invoking the inner function (so partial-failure audit shows which step blew up). The audit row's `target` field is the deletion-target URI; the `caller` is the operator; the `action` is `entity.deleted.<step_name>`; the `trace_id` is the parent cascade's trace.

### 3.6 Future entity types

New `entity://<subscheme>/<workspace>/<name>` types add a `DeletionAdapter` implementation; no changes to `Behavior.EntityDeletion` or `SpawnRegistry`. Examples:

- `entity://tool/<workspace>/<name>` (hypothetical Tool entity): adapter scrubs ToolRegistry, drops permissions
- `entity://group/<workspace>/<name>` (hypothetical Group): adapter cascade-removes from member lists

The Behavior + Adapter contract is closed; the cascade vocabulary is open. Plugin authors writing a new domain follow the same shape they already know from AgentBridge.Adapter / Ezagent.Plugin.

### 3.7 Cross-reference scrub policy — tombstone-sentinel vs hard-delete

For historical references (audit rows, snapshots from other Kinds that mention the deleted URI, completed-session metadata), there are two cleanup policies:

**(a) Tombstone-sentinel** (default): rewrite the URI in historical rows to a static `entity://tombstone/deleted/<original_subscheme>` sentinel. Preserves audit trail (you can SEE that user X did things, just not WHO they were). Reversible-ish (the sentinel doesn't carry identity, but the row count is preserved).

**(b) Hard-delete**: delete every historical row that references the URI. Lighter on DB. Destroys audit history.

The cascade adapter chooses (a) or (b) per cross-reference table. The default is (a) for audit-bearing tables (`invocations`) and (b) for non-audit operational state (membership lists, registry entries, entity_tokens, feishu_user_bindings).

For LIVE-slice references (Session `owner_uri`), the scrub is via `Behavior.Chat.invoke(:scrub_owner, ...)` (see B3 above), which sets the field to `nil` — preserving the column type while signaling "no owner" via the existing `:no_owner` clause in `data_owner/1`. The DB snapshot persists naturally via `:on_change`.

§10 OQ-3 proposes a config knob to flip the default; remains an Allen decision.

### 3.8 Edge case — bootstrap admin protection

`entity://user/system/admin` MUST NOT be deletable. `UserDeletionAdapter.can_delete?/2` hardcodes this:

```elixir
def can_delete?(%URI{} = uri, _ctx) do
  if URI.to_string(uri) == URI.to_string(Ezagent.Entity.User.admin_uri()) do
    {:error, :bootstrap_admin_undeletable}
  else
    :ok
  end
end
```

Other adapters MAY add similar protected URIs (e.g. system orchestrator agent, system feishu binding).

### 3.9 Edge case — concurrent dispatch during deletion (MED-3.5 — corrected BEAM/OTP semantics)

The atomic `tombstone_and_kill/1` (§3.3) closes the original kill-vs-tombstone race. The remaining concurrency story relies on the truth of `:brutal_kill` and `GenServer` semantics, NOT on a graceful terminate drain:

1. **`:brutal_kill` bypasses `terminate/2` entirely.** The Kind.Server GenServer's `terminate/2` callback at `apps/ezagent_core/lib/ezagent/kind/server.ex:752-791` (which handles `:on_terminate` snapshot save + Behavior teardown drain) is NOT invoked when the parent does `Process.exit(pid, :brutal_kill)`. This is intentional: any state the deleted Kind was about to snapshot is now-irrelevant (the entity is being permanently removed). Durability instead comes from the SYNCHRONOUS DB tombstone insert that precedes the kill — at the moment the kill fires, the durability promise ("this URI is permanently gone") is already in the DB.

2. **In-flight `GenServer.cast` to the killed pid.** Production dispatch uses raw `GenServer.cast` at `apps/ezagent_core/lib/ezagent/invocation.ex:111`. A cast already sent before the kill returns `:ok` to the sender (the cast was enqueued; the sender does not know whether it was processed). After the kill, the mailbox is dropped silently — there is no `{:error, :noproc}` for casts. **This is acceptable** because: (a) boundary 3 (SpawnRegistry.spawn) refuses re-spawn on the next dispatch attempt, so the system does not respawn a Kind to handle the lost cast; (b) the entity is being structurally removed — silently losing a cast to a deleted entity is the correct outcome, NOT a bug.

3. **In-flight `GenServer.call` to the killed pid.** Calls use `GenServer.call(pid, ..., timeout)`. If the call was issued BEFORE the kill and the pid was monitored (the standard call path), the call returns `{:error, :noproc}` (or raises `:exit, {:noproc, _}` depending on `GenServer.call` vs `GenServer.cast` semantics) once the link/monitor fires. Callers that use `Invocation.dispatch_call/1` (the `:call` mode path) surface this as a clean error to the LV/HTTP caller.

4. **Dispatch arriving AFTER `tombstone_and_kill` but before later cascade steps complete.** The lookup phase (`KindRegistry.lookup/1`) returns `:error` (pid dropped from the Registry on process death), or the SpawnRegistry path returns `{:error, :tombstoned}` (boundary 3). Either way, the dispatch surfaces a clean error.

5. **Dispatch arriving after the FULL deletion sequence (normal path).** All three boundaries refuse — caller gets `:tombstoned` or `:noproc` depending on the path it took.

6. **HIGH-5.3 — dispatch arriving DURING a `:kill_timeout` window.** If `tombstone_and_kill/1` returned `{:error, :kill_timeout}` (§3.3 step 4 timeout) because the brutal_kill signal has not yet completed (a stuck C-NIF or other unkillable state), the live pid is STILL registered in `KindRegistry`. `Invocation.dispatch/1` (`apps/ezagent_core/lib/ezagent/invocation.ex:87-107`) calls `KindRegistry.lookup/1` which returns the still-registered pid and forwards the cast/call directly — it does NOT consult the tombstone table on the dispatch hot path. So the live pid may continue serving messages for the brief window it survives the kill signal. This is documented as a known cleanup-bounded edge case: (a) `Behavior.EntityDeletion` returns `:partial` with `step_failed: :tombstone_and_kill_kill_timeout`, telling the operator the deletion is irreversibly committed (DB + ETS tombstone) but cleanup is incomplete; (b) the operator runbook says SIGKILL the BEAM node OR wait for the OS-level supervisor restart, after which `Registry` drops the dead pid + boundary 1 refuses re-spawn. The URI is permanently un-respawnable (boundaries 1/2/3 hold structurally) but not instantaneously dead-on-the-wire.

No "transactional dispatch barrier" is needed. The combination of (a) DB-tombstone-before-kill (durability), (b) `:brutal_kill` (immediate termination, no graceful drain), (c) the three enforcement boundaries (no re-spawn), and (d) accepting cast-loss as correct semantics for deleted entities, is structurally race-free for the NORMAL path. The `:kill_timeout` path narrows the structural guarantee from "instantaneously unreachable" to "permanently un-respawnable + reachable only for the brief window of an unkillable live pid."

### 3.10 Edge case — operator who deletes themselves

A workspace admin who calls `Behavior.EntityDeletion.invoke(:delete, slice, %{target: their_own_uri})` is structurally fine: the action runs to completion (because their caps are evaluated at dispatch step 5.5 BEFORE the cascade strips them), and after the cascade their session is invalidated on next refresh. The LV intercepts a self-delete in `users_live.ex` with a confirm-dialog warning ("You are deleting yourself; you will be logged out") but does not block — operator may have a legitimate reason.

---

## §4 Migration plan

### 4.1 New code (in order of PRs)

**PR-A (this SPEC) → PR-B Behavior + tombstone + UserDeletionAdapter**:

- `apps/ezagent_core/lib/ezagent/behavior/entity_deletion.ex` (new) — `Ezagent.Behavior.EntityDeletion`
- `apps/ezagent_core/lib/ezagent/entity_deletion/adapter.ex` (new) — adapter behaviour contract
- `apps/ezagent_core/lib/ezagent/entity_deletion/adapter_registry.ex` (new) — flavor-style registry (mirror of `Ezagent.AgentBridge.AdapterRegistry`)
- `apps/ezagent_core/lib/ezagent/spawn_registry/tombstone.ex` (new) — internal ETS + DB store; `load_into_ets/0` called from `EzagentCore.Application.start/2`
- `apps/ezagent_core/priv/repo/migrations/<timestamp>_entity_tombstones.exs` (new) — DB table for tombstones
- `apps/ezagent_core/priv/repo/migrations/<timestamp>_pr_a_worker_uri_column.exs` (new) — adds `worker_uri` to `external_mirror_bindings` as `null: true` (B5 Migration A)
- `apps/ezagent_core/priv/repo/migrations/<later_timestamp>_pr_a_worker_uri_not_null.exs` (new) — sets `worker_uri NOT NULL` with the documented pre-condition check (CRIT-3.3 Migration B)
- `apps/ezagent_core/lib/mix/tasks/ezagent_entity_deletion_backfill_worker_uri.ex` (new) — idempotent backfill mix task (CRIT-3.3); MUST be run between Migration A and Migration B
- **Modify** `apps/ezagent_core/lib/ezagent/spawn_registry.ex` — add `tombstone_and_kill/1` public primitive + `tombstoned?/1` read + tombstone check at `spawn/1` entry (boundary 3); the primitive's kill step uses `Process.exit(pid, :brutal_kill)` + `Process.monitor` + `receive {:DOWN, ...}` per §3.3 (MED-3.5)
- **Modify** `apps/ezagent_core/lib/ezagent/kind.ex` — add tombstone check at `spawn/2` entry (boundary 2)
- **Modify** `apps/ezagent_core/lib/ezagent/kind/server.ex` — add tombstone check at `init/1` entry, return `{:stop, :tombstoned}` (boundary 1 — authoritative)
- **Modify** `apps/ezagent_core/lib/ezagent_core/application.ex` — slot `Ezagent.SpawnRegistry.Tombstone.load_into_ets/0` call AFTER `Repo` migrate + BEFORE `Ezagent.KindSupervisor` boot; add `SystemPrincipal.ensure(SystemPrincipal.uri("entity-deletion-cascade"))` call AFTER `register_system_kind/0` so the cascade principal exists before any deletion fires (CRIT-3.1)
- **Modify** `apps/ezagent_core/lib/ezagent/system_principal/catalog.ex` — add `{"system://entity-deletion-cascade", [<narrow Chat:scrub_owner cap>]}` entry (CRIT-3.1)
- **Modify** `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/binding_row.ex` (CRIT-4.2) — add `field(:worker_uri, :string)` to schema block, update `@type t`, add `:worker_uri` to BOTH the `cast` and `validate_required` lists in `insert/1`
- **Modify** `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex` (the `:bind` action body) — populate `worker_uri` in attrs map passed to `BindingRow.insert/1` (B5)
- **Modify** `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex` — add `:scrub_owner` action (B3); **FIVE separate updates** per CRIT-5.1: (1) `actions/0` (chat.ex:88) — add `:scrub_owner` to the list; (2) `required_caps/0` (chat.ex:~102) — add the cap shape for `:scrub_owner`; (3) `cap_subjects/0` (chat.ex:108-116) — declare the cap subject so `CapabilityRegistry.register/3` registers it; (4) `invoke/4` — implement the slice mutation per §3.5; (5) `interface/0` (chat.ex:1036-1072) — declare the args validator (`{:deleted_uri, :uri}`); ALSO (6) `data_owner/1` (`chat.ex:1333-1342`) — add the tombstone defense check (CRIT-3.2)
- **Modify** `apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex` (`:605-614` `register_chat_behaviors/0`) — add `CapabilityRegistry.register(Session, :scrub_owner, Chat)` call (CRIT-5.1)
- **Modify** `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex` (`:593-600` `data_owner/1`) — add the SAME tombstone defense (CRIT-5.2); after fetching the owner from the Session's slice, call `SpawnRegistry.tombstoned?(owner)`; if true, return `:no_owner`
- **Modify** `apps/ezagent_domain_chat/lib/ezagent/behavior/publisher/session_impl.ex` (`:136-144` `data_owner/1`) — add the SAME tombstone defense (CRIT-5.2)
- **Modify** `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex` — at `verify/2` entry (BEFORE bcrypt), call `SpawnRegistry.tombstoned?(uri)`; if true, run `Bcrypt.no_user_verify()` and return `{:error, :tombstoned}` (HIGH-3.4 — INV-14 defense-in-depth)
- `apps/ezagent_domain_identity/lib/ezagent_domain_identity/user_deletion_adapter.ex` (new)
- Tests: §5 invariant test + adapter unit tests + boundary-1 unit test (Kind.Server refuses tombstoned URI) + boundary-2 + boundary-3 + chat.scrub_owner unit test + chat.data_owner cold-load test (INV-13b) + token.verify tombstone test (INV-14)

**PR-C admin LV integration**:

- Modify `users_live.ex` — add delete button + confirm dialog + reason input
- Modify `identities_live.ex` — add per-row delete action
- Modify `agent_detail_live.ex` — add delete action in agent detail page
- Add `mix ezagent.entity.delete <uri> --reason "<reason>"` CLI task
- **REMOVED in r2 (B4):** `workspaces_live.ex` delete button. Workspace deletion is out of scope; deferred to a future Workspace lifecycle SPEC.

**PR-D Agent + Worker DeletionAdapter**:

- `apps/ezagent_domain_chat/lib/ezagent/domain/chat/agent_deletion_adapter.ex` (new)
- `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/worker_deletion_adapter.ex` (new) — uses the new `worker_uri` column (B5)
- Per-flavor sidecar termination (cc / codex / echo / curl / np — each domain adds its own teardown)

### 4.2 Backwards compatibility

NO existing code path is removed. NO change to `Users.delete/1` semantics — that path still exists as the LOW-LEVEL DB-only delete, BUT will emit a deprecation warning suggesting `EntityDeletion.delete/3` instead. Migration target: in a follow-up PR-E, mark `Users.delete/1` as `@deprecated` and route operator-facing call sites through `EntityDeletion`.

Discovery for historical orphans: a `mix ezagent.entity.deletion.discover_orphans` mix task scans `kind_snapshots` for orphaned rows (a Kind URI with no corresponding `users` or `agents` row) and PRINTS them. Operator decides whether to tombstone each. **This is DISCOVERY, not source of truth** — see §3.3 boundary-1 paragraph.

Worker URI backfill (CRIT-3.3, separate from discover_orphans): a SECOND mix task `mix ezagent.entity.deletion.backfill_worker_uri` populates the new `external_mirror_bindings.worker_uri` column for pre-r2 rows. Idempotent (filter `WHERE worker_uri IS NULL`). MUST run between B5 Migration A (`null: true` column add) and Migration B (`NOT NULL`); Migration B aborts if any NULL rows remain.

### 4.3 No DB migration for production data

`entity_tombstones` is a new table; no existing rows. `external_mirror_bindings.worker_uri` is a new column added forward-only (`null: true` initially → backfill → `NOT NULL` follow-up). No destructive schema change. Per `feedback_destructive_migration_anti_pattern` both are operator-runnable, but the follow-up `NOT NULL` toggle is flagged for explicit operator action (stop phx, migrate, restart) on any production-shaped environment.

### 4.4 Coordinated PR sequence

PR-A (this SPEC) lands first. Subsequent PRs (B/C/D) are dispatched as separate subagent runs, each merged independently with codex review. The Behavior + tombstone + UserDeletionAdapter (PR-B) is the **smallest viable shippable** — closes the User ghost problem. PR-C unlocks operator-facing UI; PR-D extends to Agent + Worker.

The plugin-isolation north-star is preserved: PR-B+ adds the contract; PR-C/D plug into it. Future entity types (Tool, Group, etc) add `DeletionAdapter`s without touching core.

---

## §5 Invariant test — the merge gate

Per `feedback_completion_requires_invariant_test`, this SPEC is "done" iff the test below passes AND would fail if any partial impl is shipped.

**File:** `apps/ezagent_core/test/invariants/entity_deletion_invariant_test.exs`

**Setup** (DataCase, `async: false`):

1. Create a non-admin User: `entity://user/team-alpha/test-deletable` via `Users.create/3`
2. Grant them caps + add to workspace + bind feishu open_id + mint a token via `Token.create/2` (so cross-references exist, including the entity_tokens row)
3. Create a Session whose `owner_uri = target` (so B3's scrub path is exercised)
4. Spawn the User Kind: `SpawnRegistry.spawn("entity://user/team-alpha/test-deletable")` → `{:ok, pid}`
5. Call `Behavior.EntityDeletion.invoke(:delete, slice, %{target: target, reason: "test"}, %{caller: admin_uri, caps: admin_caps})`

**Assertions** (the test fails if ANY is violated):

| # | Assertion | What it catches |
|---|---|---|
| INV-1 | `KindRegistry.lookup(target)` returns `:error` immediately after delete | Kind not killed → ghost route alive |
| INV-2 | `SpawnRegistry.spawn(target)` returns `{:error, :tombstoned}` (NOT a fresh pid) | Tombstone missing or boundary 3 not enforced → respawn ghost |
| INV-2a | `Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: target})` returns `{:error, :tombstoned}` | Boundary 2 not enforced — direct Kind.spawn path bypass (B1) |
| INV-2b | Manually starting `Ezagent.Kind.Server` with `{Ezagent.Entity.User, %{uri: target}}` returns `{:error, :tombstoned}` (or the GenServer terminates with `{:stop, :tombstoned}`) | Boundary 1 not enforced — the authoritative chokepoint (B1) |
| INV-3 | `Users.get_by_uri(target)` returns `nil` | DB row leak |
| INV-4 | `Repo.get(EntityProfile, target_uri_str)` returns `nil` | Profile leak |
| INV-5 | `Repo.get(KindSnapshot, target_uri_str)` returns `nil` | Snapshot leak → resurrection on next boot |
| INV-6 | `Repo.all(from f in feishu_user_bindings, where: f.user_uri == ^target_uri_str)` returns `[]` | Feishu sender resolution → dead user |
| INV-7 | For every workspace W where target was a member: `target NOT IN W.member_uris` | Membership leak |
| INV-8 | For every session S where target was a member: `target NOT IN S.members` | Session membership leak (could re-resurrect Kind on `chat.join`) |
| INV-9 | `Workspace.list_workspaces_for(target, ...)` raises or returns `[]` (target itself is gone) | Visibility leak |
| INV-10 | An audit row exists: `invocations` with `action = "entity.deleted"`, `target = target_uri_str`, `caller = admin_uri_str`, AND every cascade step has a sub-row with the SAME `trace_id` (N2) | Audit trail incomplete or trace correlation broken |
| INV-11 | Kill the BEAM (simulate restart via `Application.stop(:ezagent_core) + Application.start(:ezagent_core)`). After restart, INV-1 + INV-2 + INV-2a + INV-2b + INV-3 still hold. Specifically, `Kind.Server.init/1` on the target URI returns `{:stop, :tombstoned}` proving boundary 1 loads its check from the boot-time-populated ETS table | Tombstone DB persistence failed OR boot-time load missed |
| INV-12 | `Behavior.EntityDeletion.invoke(:delete, ..., %{target: Ezagent.Entity.User.admin_uri()})` returns `{:error, :bootstrap_admin_undeletable}` | Bootstrap admin protection missing |
| INV-13 | For the Session S created in setup with `owner_uri = target`: after deletion, dispatch `Behavior.Chat.data_owner(S_uri)` returns `:no_owner` (not the deleted target URI), AND inspect S's live slice: `slice.owner_uri == nil` | B3 — Session owner not scrubbed via the new `:scrub_owner` action → deleted user still drives data_owner authz |
| INV-13a | The `system://entity-deletion-cascade` principal exists in `KindRegistry` after `EzagentCore.Application.start/2` AND its caps set is the disjoint union of (1) `SystemPrincipal.Catalog.caps_for!(self_uri)` (containing the cascade `Chat:scrub_owner` cap) and (2) the structural self-`Identity:list_caps` cap from `Identity.init_slice/1` (HIGH-4.3). NO other caps. Additionally: the actual cascade dispatch (calling `SystemPrincipal.caps(cascade_principal)` per CRIT-4.1's fix) completes without raising an ArgumentError. | CRIT-3.1 + CRIT-4.1 + HIGH-4.3 — narrow system principal not installed correctly, OR caps drift wider, OR the caps/1 invocation crashes |
| INV-13b | **(CRIT-3.2 + CRIT-5.2)** Cold-load a snapshotted Session whose `:chat` slice has `owner_uri = target` AFTER the User deletion (and AFTER restart so the principal is absent from KindRegistry until lookup-driven respawn). Then call ALL THREE production data-owner resolvers and assert each returns `:no_owner` (NOT the deleted target URI): (1) `Behavior.Chat.data_owner(S_uri)`; (2) `Behavior.ExternalMirror.data_owner(S_uri)`; (3) `Behavior.Publisher.SessionImpl.data_owner(S_uri)`. Each must apply the SpawnRegistry tombstone defense at the read site. | CRIT-3.2 + CRIT-5.2 — cold-Session safety relies on the read-site tombstone check across ALL data_owner resolvers; missing the check at any of the three sites leaves a privilege-disclosure surface |
| INV-14 | For a token minted in setup for the target: `Token.verify(plain_token, target)` returns `{:error, :tombstoned}` (NOT `{:error, :invalid_credentials}` and NOT `{:ok, _}`). Validation: the tombstone check at `Token.verify/2` entry fires BEFORE the bcrypt comparison, AND `Bcrypt.no_user_verify()` is invoked to defeat timing leaks. | B6 + HIGH-3.4 — token-row escapes cascade OR Token.verify lacks the tombstone defense check OR the check is placed AFTER bcrypt (timing leak) |
| INV-15 | After PR-B + backfill task run + Migration B applied, for every row in `external_mirror_bindings`: `worker_uri` is non-NULL AND equals `WorkerSpawn.worker_uri_for(parsed_session_uri, adapter_id, target_id) |> URI.to_string()`. Additionally: the `Repo.delete_all(WHERE worker_uri IS NULL)` transitional branch in the cascade query is structurally dead (returns 0 affected rows). | CRIT-3.3 — backfill task did not run, OR derivation is wrong, OR Migration B's pre-condition check was bypassed |
| INV-15a | **(MED-4.5 — transitional branch coverage)** Before backfill: directly INSERT a `BindingRow` with `worker_uri: nil` (bypassing the `:bind` action body, e.g. via `Repo.insert/1` with raw struct). Derive the target Worker URI structurally via `WorkerSpawn.worker_uri_for(session_uri, adapter_id, target_id)`. Invoke Worker deletion for that URI. Assert: (a) the cascade query's transitional second clause matches the NULL row and `Repo.delete/1`s it; (b) the row is absent from the table after deletion. | MED-4.5 — transitional NULL-safety branch is silently broken; pre-backfill Worker deletions miss the row |

**Cannot pass with partial impl** — if any cascade step or boundary is skipped, the corresponding INV fails:

- Skip "tombstone install": INV-2 + INV-2a + INV-2b + INV-11 fail
- Skip boundary 1 only: INV-2b fails (and INV-11's boot path)
- Skip boundary 2 only: INV-2a fails
- Skip boundary 3 only: INV-2 fails
- Skip "users row delete": INV-3 fails
- Skip "feishu bindings drop": INV-6 fails
- Skip "memberships drop": INV-7 + INV-8 fail
- Skip "session owner scrub" (B3): INV-13 fails
- Skip "revoke_entity_tokens" (B6): INV-14 fails (the row-delete half)
- Skip Token.verify tombstone check (B6 defense-in-depth): INV-14 fails (the verify-rejects half)
- Skip "audit emit": INV-10 fails
- Skip "bootstrap protection": INV-12 fails

The test fails on the FIRST mismatch, with a message identifying the leak. Operators see the cascade-step name + the row that leaked.

---

## §6 Plugin isolation analysis

Per `feedback_north_star_plugin_isolation`, the architectural seam:

| Layer | Knows about | Does NOT know about |
|---|---|---|
| `ezagent_core` | `Behavior.EntityDeletion` action, `EntityDeletion.Adapter` behaviour, `SpawnRegistry.tombstone_and_kill/1` (public), `SpawnRegistry.tombstoned?/1` (public read), the three enforcement boundaries | how to drop a Feishu binding, how to terminate a cc bridge, how to scrub session membership |
| `ezagent_domain_identity` | `UserDeletionAdapter` (User-specific cascade: caps, Feishu bindings, profile, memberships, tokens, owned-session-owner scrub via dispatch) | Agent or Worker cascade; the internal `tombstone/1` (private to core); the boundary-2/3 internals |
| `ezagent_domain_chat` | `AgentDeletionAdapter` (Agent-specific cascade: sidecars, bridge registry, lineage, tokens); the `:scrub_owner` Chat action body (the cascade dispatches into Chat, not the reverse) | User or Worker cascade |
| `ezagent_domain_external_mirror` | `WorkerDeletionAdapter` (Worker cascade: bindings via the new `worker_uri` column, publisher unsubscribe, adapter terminate) | User or Agent cascade |
| `ezagent_plugin_codex` (etc) | how to stop ITS sidecar | how to terminate cc's sidecar |
| `ezagent_plugin_liveview` | how to render a "Delete" button + confirm dialog | the cascade semantics |

A future plugin author adding a new entity type (e.g. a hypothetical `entity://tool/...`) writes a `ToolDeletionAdapter` + registers it. **Zero changes to `ezagent_core`** required. This is the north-star applied to the deletion lifecycle.

Tiebreaker test ("keeps plugin authors out of core"): does `Behavior.EntityDeletion` expose internal cascade state to plugin code? Answer: NO. The Behavior calls `Adapter.cascade_steps/2` and gets back a list of `{step_name, function}`. The plugin's adapter never sees the deletion target's slice state, never sees other adapters' cascades, never touches `SpawnRegistry.tombstone/1` directly (it's private; only `tombstone_and_kill/1` is public, and that's invoked by `Behavior.EntityDeletion` step 2 — not by adapter code). ✅

**Note on `system://entity-deletion-cascade` principal authority (HIGH-4.3):** the principal carries TWO caps after `SystemPrincipal.ensure/1` — the cascade-purpose `Chat:scrub_owner` cap (from Catalog) AND a structural self-`Identity:list_caps` cap that `Behavior.Identity.init_slice/1` injects for every Entity Kind. The self-cap is a no-op authority surface (reading own caps returns the same MapSet that authorized the call), not a cascade-related concern. INV-13a asserts the disjoint-union shape explicitly — caps drift wider than this set is a SPEC violation.

---

## §7 Trade-offs / alternatives considered

### 7.1 "Soft delete" with `deleted_at` flag (rejected)

`users.deleted_at` column + filter every read site to exclude rows where `deleted_at` is not null.

**Rejected**: this is the canonical anti-pattern for identity deletion. Every read site becomes responsible for filtering; missing one = ghost resurrection. The discipline problem is identical to the `visible: false` problem rejected by `2026-05-27-workspace-cap-based-visibility.md`. Cap-based + tombstone is the structural fix; flag-based is policy-based.

### 7.2 "Hard delete + no tombstone, hope SpawnRegistry can't find the URI" (rejected)

Just delete the row and the snapshot. Rely on the fact that no path will try to spawn a non-existent URI.

**Rejected**: empirically false. The 2026-05-26 system/linyilun retire DID this — DB row gone, snapshot gone — and the Kind kept respawning. Some path WAS trying to spawn the URI (LV mount, Feishu binding lookup, dispatch from another Kind), and the entity spawn fn happily created a fresh Kind because there's no "deleted" signal at the SpawnRegistry layer. The tombstone is the missing signal.

### 7.3 "Use Ecto soft-delete library" (rejected)

Pull in `ecto_soft_delete` or similar.

**Rejected**: this is 7.1 with a library wrapper. The library makes the discipline EASIER to maintain but doesn't change its fundamental brittleness. Per `feedback_let_it_crash_no_workarounds` we prefer structural over policy.

### 7.4 "Per-entity-type Behavior" (rejected)

`Behavior.UserDeletion`, `Behavior.AgentDeletion`, `Behavior.WorkerDeletion` — three separate Behaviors with parallel structure.

**Rejected**: duplicates the structural sequence (pre-check / kill / tombstone / cascade / audit) three times. A bug fix in one Behavior would need three-way replication. The Adapter pattern (one Behavior, three adapters) is the structural deduplication; per-entity Behaviors is policy-based.

### 7.5 "Don't allow runtime deletion; require operator-side DB script + phx restart" (rejected)

Today's de-facto path. Operator does SQL deletes + restarts phx so all in-memory state rebuilds clean.

**Rejected**: works for system-internal entities at scale 1 (system/linyilun migration), fails at scale N. Tenants creating + deleting test users routinely cannot tolerate "restart phx for every delete". Production-grade SaaS needs runtime deletion. (Also Allen explicitly asked for runtime fix.)

### 7.6 "Single-boundary tombstone at SpawnRegistry.spawn/1 only" (r1 — rejected in r2 per B1)

r1 originally guarded only `SpawnRegistry.spawn/1`. Codex r1 identified that production has additional spawn paths (`Kind.spawn/2` direct, `WorkerSpawn.spawn/4`, supervisor-restart from snapshot) which bypass SpawnRegistry. **Rejected**: a single-boundary tombstone is structurally insufficient. The r2 fix installs the check at THREE boundaries with `Kind.Server.init/1` as the authoritative source-of-truth (the only chokepoint every Kind start traverses).

### 7.7 "Worker→binding lookup at deletion time without persisting worker_uri" (r1 — rejected in r2 per B5)

Alternative to B5's column add: at deletion time, given a worker URI, reverse-engineer the `(session_uri, adapter_id, target_id)` triple from the rows OR iterate every row and call `WorkerSpawn.worker_uri_for/3` to match. **Rejected**: O(N) lookup hack instead of an O(1) indexed column; per `feedback_let_it_crash_no_workarounds` (structural fix over policy fix); also fragile — `worker_uri_for/3` is a private hash-derivation contract and any future change to the hash function (truncation length, salting, scheme) silently invalidates the reverse lookup. The persisted column is the simpler, more robust answer.

### 7.8a "Cascade dispatches `:scrub_owner` with `ctx.caps = admin_wildcard`" (r3 — rejected per CRIT-3.1)

Alternative to CRIT-3.1's narrow system principal: inject `Ezagent.SystemPrincipal.caps("bootstrap")` (the wildcard admin caps) into `ctx.caps` at the cascade dispatch site. **Rejected**: per `feedback_let_it_crash_no_workarounds`, prefer structural narrowness over policy-wildcards. The wildcard would let any future bug in the cascade dispatch escalate to ANY action on any Kind. The dedicated `system://entity-deletion-cascade` principal carries exactly the cap it needs and nothing more, auditable via the Catalog.

### 7.8b "Only proactive in-memory scrub for B3, skip read-site defense" (r3 — rejected per CRIT-3.2)

Alternative: rely entirely on the cascade's `:scrub_session_owner_uri` step to mutate live Sessions, and accept that cold-loaded Sessions briefly carry stale `owner_uri` until next user-driven action triggers a re-read. **Rejected**: cold loads are not the only race — there's also the window between `KindRegistry.list_all/0` and per-session dispatch in the cascade itself. The read-site tombstone defense in `Chat.data_owner/1` is defense-in-depth (parallel to `Token.verify`'s tombstone check) and closes BOTH windows with one check.

### 7.8c "Single migration with maintenance window for B5 NOT NULL" (r3 — considered, deferred to OQ-8)

Alternative to CRIT-3.3's two-migration + backfill-task approach: a single migration that adds the column + populates it + sets NOT NULL atomically, requiring phx to be stopped (per `feedback_destructive_migration_anti_pattern`). **Deferred**: this is a real choice for Allen; the two-migration path is friendlier in CI and dev (greenfield deployments don't notice it) but requires operator discipline in prod (must run backfill task before Migration B). OQ-8 documents the choice.

### 7.8 "Workspace deletion via the same Adapter dispatch" (rejected in r2 per B4)

r1 PR-C added a `workspaces_live.ex` delete button that would route through `Behavior.EntityDeletion`. But `workspace://<name>` URIs don't match the `entity://<scheme>/<subscheme>` shape that the `entity_scheme/0 + entity_subscheme/0` Adapter dispatch keys on. **Rejected**: workspace deletion is structurally distinct — it cascade-deletes ALL members + templates + sessions + bindings within the workspace; the semantics are different from entity deletion (which is per-URI). Forcing both under one Adapter contract conflates two unrelated lifecycle responsibilities. Workspace deletion gets its own future SPEC.

---

## §8 SPEC interactions — concurrent specs

### 8.1 [2026-05-27-workspace-cap-based-visibility.md](2026-05-27-workspace-cap-based-visibility.md) (merged)

`Workspace.list_workspaces_for/2` uses cap-membership for visibility. EntityDeletion's cascade revokes a user's caps + removes them from workspace.member_uris. After deletion, `list_workspaces_for/2` returns `[]` for that caller (cap-membership union is empty). INV-9 pins this interaction.

### 8.2 [2026-05-27-uri-canonicalization.md](2026-05-27-uri-canonicalization.md) (merged)

EntityDeletion compares URIs at every cascade step. All URI parsing uses `Ezagent.URI.parse!/1`; INV assertions use `URI.to_string` comparison (canonical-form-invariant). No new URI-parsing path is introduced; SPEC #431's chokepoint suffices.

### 8.3 [2026-05-27-capability-action-axis.md](2026-05-27-capability-action-axis.md) (merged)

`Behavior.EntityDeletion`'s `required_caps/0` declares `action: :delete` — a CONCRETE atom, not `:any`. Per SPEC §3.6.1(b) (the wildcard-action-grant gate), this means the cap grant flow ALWAYS produces a per-action cap, never `:any`. Aligns with the lesson from BindingPolicy fix (#426).

### 8.4 [2026-05-27-reconciler-return-shape.md](2026-05-27-reconciler-return-shape.md) (merged)

EntityDeletion's return shape is `:ok | :partial | :error` — same three-arm pattern. `:partial` here means "Kind killed + tombstoned (irreversible) but DB cascade incomplete". Caller treats `:partial` the same way Reconciler callers do: retry-the-cascade-steps OR escalate to operator. Both patterns ratified by the same precedent.

### 8.5 [2026-05-27-agent-bridge-domain-extraction.md](2026-05-27-agent-bridge-domain-extraction.md) (merged)

Agent deletion needs to terminate sidecars. PR-G introduced `Ezagent.AgentBridge.Adapter.deliver/2` for outbound and `handle_client_event/3` for inbound. AgentDeletionAdapter needs a parallel "teardown" path. Two options:

- Add `teardown/1` callback to `Ezagent.AgentBridge.Adapter` — flavor adapter knows how to stop its own bridge
- Or have `AgentDeletionAdapter` directly call known sidecar shutdown APIs (cc: `BridgeRegistry.unbind`, codex: `BridgeSidecar.stop`)

**Recommendation**: add `teardown/1` to `Ezagent.AgentBridge.Adapter` (optional callback, default no-op). PR-D includes this extension; PR-G's existing adapters add a `teardown/1` impl each. Plugin isolation preserved.

---

## §9 Backwards compatibility / external API

### 9.1 Operator workflows

- `mix ezagent.user.create` (existing) — unchanged
- `mix ezagent.user.delete` (current behavior: low-level DB delete) — **DEPRECATED**, will emit warning + suggest `mix ezagent.entity.delete`
- `mix ezagent.entity.delete <uri> --reason "<reason>"` (new) — calls `Behavior.EntityDeletion.invoke(:delete, ...)`
- `mix ezagent.entity.deletion.discover_orphans` (new) — DISCOVERY only (scans snapshot-orphans, prints, NO automatic tombstone install)
- `mix ezagent.entity.deletion.backfill_worker_uri` (new — CRIT-3.3) — idempotent backfill of `external_mirror_bindings.worker_uri` for pre-r2 rows. Pre-flight for B5 Migration B (NOT NULL). Operator runs once per environment after Migration A lands; Migration B will refuse to run if any NULL rows remain.

### 9.2 External callers

The `external_mirror_bindings` table gains a `worker_uri` column (B5) populated by the `:bind` action body. External callers reading the table see one new field; existing reads are unaffected.

No external HTTP / RPC / Phoenix.Channel consumer pattern-matches on identity-deletion behavior today; this SPEC introduces a NEW Phoenix.PubSub broadcast `{:entity_deleted, target_uri, reason}` for LV consumers (admin dashboard refreshes when a user is deleted).

### 9.3 Snapshots — boot-time tombstone load is the source of truth (r2 B1 demotion)

Pre-SPEC snapshots that reference deleted entities are not auto-rewritten. The structural protection is the boot-time tombstone load:

- `EzagentCore.Application.start/2` runs `Ezagent.SpawnRegistry.Tombstone.load_into_ets/0` AFTER `Repo` + Migrator and BEFORE `Ezagent.KindSupervisor` boot
- All `Kind.Server.init/1` calls thereafter consult the ETS check (boundary 1) and refuse to boot any tombstoned URI
- A snapshot row referencing a tombstoned URI is **inert** — it sits in DB but no Kind ever loads it; `kind_snapshots` orphan rows are operationally invisible

The `mix ezagent.entity.deletion.discover_orphans` task is DISCOVERY/CLEANUP — for forensic curiosity or DB hygiene. **It is NOT the source of truth for deletion.** The source of truth is boundary 1's tombstone check at every Kind start.

### 9.4 Rollback plan

Deletion is **append-only**; there is no `undelete`. To "restore" an accidentally-deleted entity, the operator must:

1. Manually remove the tombstone row from `entity_tombstones` (admin-only SQL)
2. Manually re-create the user/agent/etc with the same URI (fresh entity, no history continuity)

This is intentional friction. SPEC documents it loudly. The LV confirm dialog warns "this is irreversible; the URI cannot be reused".

---

## §10 Open questions for Allen

### OQ-1 — tombstone TTL?

Tombstones in `entity_tombstones` are permanent by default. Should there be a TTL after which the URI becomes reusable? Default: NO (permanent), per `feedback_uuid_is_canonical_identifier` analog (immutable identity). Allen MAY override per-tenant if there's a real tenant lifecycle reason.

### OQ-2 — RESOLVED in r2 — cascade ordering atomic via `tombstone_and_kill/1`

(r1: "kill Kind FIRST, then DB. Rationale: ...") **Resolved by B2.** The race that motivated this question was eliminated by promoting `SpawnRegistry.tombstone_and_kill/1` to the sole normative primitive. There is no longer a "kill then tombstone" or "tombstone then kill" sequence — it's one atomic operation per §3.3. The cascade order (per §3) is now: pre-check → `tombstone_and_kill` (atomic) → snapshot purge → cascade steps → audit emit.

### OQ-3 — cross-reference scrub default

§3.7 lists tombstone-sentinel vs hard-delete. Default proposed: tombstone-sentinel for audit-bearing rows (preserve history), hard-delete for operational state. Allen confirm? Could also be per-tenant config.

### OQ-4 — RESOLVED in r2 — Workspace deletion OUT OF SCOPE

(r1: "If a workspace is deleted, what happens to all entities within it?") **Resolved by B4.** Workspace deletion is OUT OF SCOPE for this SPEC. The `workspace://<name>` URI shape doesn't match `entity://<scheme>/<subscheme>` Adapter dispatch, and workspace cascade semantics (members + templates + sessions + bindings) are structurally distinct from entity deletion. Forward-looking note: a future Workspace lifecycle SPEC will design this with its own dedicated cascade machinery, which MAY or MAY NOT reuse `Behavior.EntityDeletion` as a sub-call for individual entity teardown. This SPEC stays focused on User / Agent / Worker.

### OQ-5 — admin LV self-delete

§3.10 allows operator to delete themselves with a confirm dialog. Should self-delete be allowed at all? Some systems require a "second admin" to confirm self-deletion. Default: allowed with single confirm. Allen may want to gate behind a second-admin requirement.

### OQ-6 — Feishu binding cascade

When a user is deleted, their `feishu_user_bindings` rows are dropped (§3.5). But: in production, the user's Feishu open_id is still valid (they're still in Feishu the platform); their messages will start failing to resolve. Should the cascade attempt to re-bind the open_id to a fallback (e.g. `system/deleted` sentinel user) so messages get a clean "user deleted" reply? Default: drop binding entirely; Feishu messages from that open_id will get "no user found" at the routing layer (acceptable error). Allen MAY want the sentinel-rebind.

### OQ-7 — Tombstone DB table partitioning

`entity_tombstones` is one row per deleted URI. At scale (e.g. 10K tenants × 100 test users × delete cycles), the table grows. Should it be partitioned by workspace? Default: no, single table; revisit if performance issue. Documenting for future awareness.

### OQ-8 — `external_mirror_bindings.worker_uri` NOT NULL timing (r3 — refined per CRIT-3.3)

The B5 fix adds `worker_uri` as `null: true` initially (Migration A) with a follow-up Migration B to set `NOT NULL` after the operator runs `mix ezagent.entity.deletion.backfill_worker_uri`. Migration B has a pre-condition check that aborts if any NULL rows remain. Greenfield deployments (dev/test/fresh prod) skip the gap entirely. Allen confirm the two-migration + backfill-task pattern is acceptable, OR prefer a single migration with maintenance window?

---

## §11 Codex adversarial review questions (for r4)

0. **Narrow system principal soundness (CRIT-3.1 + CRIT-4.1 + HIGH-4.3):** the new `system://entity-deletion-cascade` is meant to authorize only `Chat:scrub_owner` on Sessions; r4 acknowledges the structural self-`Identity:list_caps` cap that `Identity.init_slice/1` adds for any Entity Kind. Validate that the actual cascade dispatch path resolves correctly (no ArgumentError from `SystemPrincipal.caps/1`, no unauthorized cap-set drift from `Identity.init_slice/1` injection). Trace `Capability.matches?/2` for the cascade's `Chat:scrub_owner` dispatch AND for any hypothetical attempt by the principal to invoke OTHER Chat actions (e.g. `:send`, `:join`) — confirm those are denied.

0a. **Cold-load defense correctness (CRIT-3.2):** the `Chat.data_owner/1` defense calls `SpawnRegistry.tombstoned?(owner)` on every read. Validate: (a) the ETS lookup is fast enough for the data_owner hot path; (b) the check runs BEFORE the URI is returned; (c) no fast-path optimization bypasses the check; (d) consistent with INV-13b's cold-load assertion.

0b. **r4 contradictory text?** Re-read §3.2 (`:partial` subshape distinction), §3.3 (4-step ordering with timeout return), §3.5 (CRIT-4.2 BindingRow write-path triple), §3.9 (corrected BEAM semantics), §4.1 (PR-B change list — now larger). Do any two statements contradict? Specifically: §3.2's `:tombstone_and_kill_kill_timeout` step_failed vs §3.3's `{:error, :kill_timeout}` raw return; §3.5 cascade query's NULL-safety branch vs §4.1 BindingRow's `validate_required` list (transitional vs post-Migration-B state); the disjoint-union INV-13a vs the §6 plugin-isolation table that still says the principal "ONLY invokes Chat:scrub_owner".

1. **Multi-boundary tombstone enforcement (B1):** Trace every code path in the apps/ tree that culminates in a Kind being alive in memory. Is `Kind.Server.init/1` truly the only chokepoint every Kind start traverses? Find ANY bypass path (hot-takeover from another node? Direct `:proc_lib.start_link`? Plugin custom DynamicSupervisor child_spec that doesn't use `Kind.Server`?) that survives the r3 fix.

2. **Atomicity contract + timeout semantics (B2 + MED-4.4):** `SpawnRegistry.tombstone_and_kill/1` has 4 steps with `{:error, :kill_timeout}` on receive timeout. Walk through failure modes: (a) step 3 succeeds but the DOWN message is lost (e.g. monitor not set up correctly); (b) step 3 returns false (pid was already dead); (c) the receive raises (e.g. mailbox flooded). Identify any state where the tombstone is half-installed OR the Behavior's `:partial` mapping is inconsistent with §3.3's actual return.

3. **Session owner scrub via system principal (B3 + CRIT-3.1 + CRIT-3.2 + CRIT-4.1 + HIGH-4.3):** the cascade now dispatches `:scrub_owner` AS `system://entity-deletion-cascade`. Concerns:
   (a) Lookup is via `KindRegistry.list_all/0` + scheme filter (no `list_matching/1` API in production per `kind_registry.ex:73`). Verify the EN code sample uses the correct API and that the filter doesn't accidentally miss any session URIs.
   (b) The cap-check path for the cascade dispatch: `Kind.Runtime.authorize/4` (`apps/ezagent_core/lib/ezagent/kind/runtime.ex:249-298`) checks `ctx.caps` BEFORE the slice-resolved `holds_cap?` path. r4 sets `ctx.caps = SystemPrincipal.caps(cascade_principal)`. Does the `Capability.matches?/2` predicate accept this cap shape against the cascade's needed cap?
   (c) Cold-load: r3/r4 fix puts the defense in `Chat.data_owner/1`. Verify there is NO other production read site (e.g. an LV view, an admin script, a different Behavior's `data_owner/1`) that reads `Session.owner/1` directly and would still honor the tombstoned URI.

4. **Worker cascade complete (B5 + CRIT-3.3 + CRIT-4.2 + MED-4.5):** r4 fixes the BindingRow schema/cast/required omissions. Verify: (a) every code path that writes to `external_mirror_bindings` goes through `BindingRow.insert/1` (no direct SQL inserts elsewhere); (b) the backfill task derives `worker_uri` correctly from `(session_uri, adapter_id, target_id)`; (c) the transitional NULL-safety cascade branch handles the pre-backfill scenario (INV-15a); (d) Migration B's pre-condition check actually fires (Ecto migration `def change` body — does the SPEC document a concrete query or just claim it?).

5. **r4 introduced contradictions?** Same as q0b but looking specifically for r4-introduced contradictions vs r3 text that didn't get updated. Spot-check: the §6 plugin-isolation table claim about "exactly the cap it needs" vs HIGH-4.3's acknowledgment of the self-`Identity:list_caps` cap.

6. **Bilingual lockstep maintained in r4?** The r4 §3.5 cascade tables already byte-identical (verified at the LOW-3.6 fix). r4 adds prose around BindingRow + system principal + timeout return. Verify ZH §3.5 + §3.3 + §3.2 reflect the new r4 text.

7. **Plugin isolation tiebreaker check (post-r4):** the §6 table claims plugin adapters never touch `SpawnRegistry.tombstone/1` directly. Verify: is there any code path where a DeletionAdapter calls into the SpawnRegistry tombstone machinery NOT via `tombstone_and_kill/1`?

8. **Entity_tokens defense-in-depth (B6 + HIGH-3.4):** Verify the new tombstone check in `Token.verify/2` (`token.ex:106-118`) is structurally BEFORE bcrypt AND that `Bcrypt.no_user_verify()` is called on the tombstone-hit path to defeat timing leaks.

9. **LV confirm dialog UX (preserved from r1 q9):** PR-C admin LV adds a "Delete" button + confirm dialog asking for reason. Should we also require the operator to TYPE the URI being deleted (GitHub repo-name-confirmation parity)? Default proposed: type-the-name confirmation for irreversible operations. Allen confirm?

---

## §12 Rollback plan

This SPEC's impl is forward-only (no rollback of an applied deletion). Rollback of the SPEC ITSELF (revert PR-A → PR-B → ...):

1. Revert the merge commits in reverse order
2. The `entity_tombstones` table remains in DB (orphaned, no code reads it)
3. The `external_mirror_bindings.worker_uri` column remains (a NULL-able orphaned column; harmless)
4. Operators who had relied on `Behavior.EntityDeletion` lose access; manual SQL delete is the fallback again
5. Pre-existing tombstones remain inert (no enforcement until the SPEC is re-applied)

The DB schema additions are non-destructive; rolling back is safe at any time. The deletion semantics LOSS is acceptable (operators revert to today's manual workflow).

---

## Appendix A — Sequence diagram

```
Operator (admin LV)
  │ click "Delete" + type reason + confirm
  ▼
Behavior.EntityDeletion.invoke(:delete, slice, %{target, reason}, ctx)
  │ step 5.5 CapBAC: caller has :delete cap?  → audit "granted"
  │ generate trace_id = audit row uuid
  │
  ▼ step 1
Adapter.can_delete?(target, ctx)
  │ adapter-specific pre-check
  ▼ :ok or {:error, :precheck_failed_reason}
  │
  ▼ step 2 (THE atomic primitive — B2 + MED-3.5 corrections)
SpawnRegistry.tombstone_and_kill(target):
  │   - INSERT entity_tombstones row (DB)
  │   - :ets.insert(@tombstone_table, ...) (rollback DB on failure)
  │   - Process.exit(Kind pid, :brutal_kill)  [bypasses terminate/2 — intentional]
  │   - Process.monitor(pid) + receive {:DOWN, ...} (short timeout)
  ▼ tombstone installed; Kind dead; respawn refused at boundaries 1/2/3
  │
  ▼ step 3
delete kind_snapshots row
  │
  ▼ step 4 (iterated via Adapter.cascade_steps/2; each row shares parent trace_id)
for each {step_name, step_fn} in adapter steps:
  │   audit "cascade.<step_name>.start" (trace_id = parent)
  │   step_fn.()
  │   audit "cascade.<step_name>.complete" (trace_id = parent)
  │   [B3 + CRIT-3.1: :scrub_session_owner_uri dispatches as system://entity-deletion-cascade]
  │   [CRIT-3.2: Chat.data_owner/1 read-site tombstone defense covers cold-loaded sessions]
  │   [B5 + CRIT-3.3: :drop_external_mirror_bindings uses worker_uri = target + transitional null safety net]
  │   [B6 + HIGH-3.4: :revoke_entity_tokens + Token.verify rejects tombstoned URIs (defense-in-depth)]
  ▼
  │
  ▼ step 5 (audit emit)
audit "entity.deleted" {target, caller, reason, steps_completed, summary, trace_id}
  │
  ▼ step 6 (broadcast)
Phoenix.PubSub.broadcast(@entity_deletion_topic, {:entity_deleted, target, reason})
  │
  ▼
{:ok, %{deleted_uri, steps_completed, cascade_summary, audit_event_id, trace_id}}
```

## Appendix B — Why this SPEC is longer than the others

It introduces TWO new structures (Behavior + Adapter + tombstone + cascade contract), each with its own semantics. The cascade tables in §3.5 are exhaustive; the INV table in §5 is now 14 entries (every leak vector + B1's three boundary tests + B3's owner-scrub + B6's token defense); the OQ list in §10 is 8 (each is a real product decision Allen could override). r2 added the multi-boundary tombstone enforcement section + the Session-owner-scrub via Chat action + the Worker URI column add + the entity_tokens cascade — all driven by codex r1's REJECT findings.

## Appendix C — Author's recommendation

Land PR-A (this SPEC) + PR-B (Behavior + UserDeletionAdapter + 3-boundary tombstone + Chat `:scrub_owner` + Worker URI column add) as ONE pair. PR-C (admin LV without workspace delete) + PR-D (Agent + Worker adapters) can be parallelized — they're independent. The 4-PR sequence shouldn't take longer than 1.5-2 days end-to-end at the cap-vis / URI-canonical rhythm; r2 grew PR-B's scope by ~30% (boundary 1 + Chat action + Worker column migration) so factor that into the estimate.

The `system/linyilun` ghost — surfaced 2026-05-28 — is the empirical motivation. After PR-B lands + operator runs the discovery mix task to inventory orphans, the ghost is structurally impossible (boundary 1 refuses every tombstoned URI at the only chokepoint every Kind start traverses).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
