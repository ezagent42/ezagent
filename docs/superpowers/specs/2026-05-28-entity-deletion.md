# SPEC — Kind lifecycle CRUD parity (destroy callback + DB-backing spawn)

**Status:** r11 — ground all r10 fixes in the actual codebase + suppress terminate-time snapshot + correct lock URIs + complete lock list per codex r10 REJECT verdict. Two critical + two high + one consistency addressed; one new invariant (INV-27) added.

**r11 changes (over r10):**

- **B6'' — drop the fictitious SessionRow direct-write; rely on the existing read-site DB-backing defense (codex r10 CRITICAL §3.5/§3.7).** r10 introduced `Repo.update_all(from s in SessionRow, ...)` as a direct cross-Kind write, but codex r10 verified that **no `SessionRow` schema or `sessions` table exists** in the codebase. Session ownership lives in the live `:chat` slice via `Ezagent.Kind.get_slice(uri, :chat)` (apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex:649). r10's mechanism was groundless.
  **r11 fix:** drop the cross-Kind scrub entirely. The read-site DB-backing defense (preserved from r1–r6) is the structural mechanism that handles "owner is now destroyed":
  - `Chat.data_owner/1` reads `:chat` slice's `owner_uri` AND checks `Users.get_by_uri(owner_uri)` (the r1–r6 design's check). If user is destroyed, returns `:no_owner` even though slice cache is stale.
  - `Publisher.SessionImpl.data_owner/1` does the same DB-backing check at its read site (preserved from r1–r6).
  - **`ExternalMirror.data_owner/1` is the GAP** — apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:593 currently reads `slice.owner_uri` directly without the DB defense. r11 PR-B adds the same `Users.get_by_uri/1` check here, completing the three-site defense.
  Plugin isolation is preserved by this approach: cleanup is DISTRIBUTED via the read-site defense pattern (every consumer of `owner_uri` reads-through-DB), not centralized via cross-Kind writes. The "Chat.scrub_owner" Behavior action + `system://kind-destroy-cascade` principal are removed entirely (not needed under the read-site defense). The slice's stale `owner_uri` is harmless because no production read path returns it without consulting the DB. User.destroy_db/2 now does NOT touch session rows — there are none to touch. INV-16 already covered the three-site coverage; r11 adds explicit INV-16b assertion that the ExternalMirror site is wired.
- **B8 — Kind.Server.terminate/2 skips snapshot under destroy-induced shutdown (codex r10 CRITICAL §3.4/q25).** r10 step 3c deletes the kind_snapshots row, but the existing `Kind.Server.terminate/2` (apps/ezagent_core/lib/ezagent/kind/server.ex:753) writes a fresh snapshot for `:on_terminate` Kinds. After step 3 commits + step 6 terminates the GenServer, terminate/2 fires → re-creates the just-deleted snapshot row → ghost state.
  **r11 fix:** the Kind.Server.destroy orchestrator's step 6 calls `Process.exit(pid, :destroyed)` (or `DynamicSupervisor.terminate_child` with a custom shutdown reason via an explicit GenServer.call to set state.shutdown_reason FIRST, then terminate). The `Kind.Server.terminate/2` callback adds a guard clause:
  ```elixir
  def terminate(:destroyed, _state), do: :ok                # NEW r11 — skip snapshot
  def terminate(reason, state), do: existing_terminate_body(reason, state)
  ```
  Similarly when the in-GenServer dispatch fence (B1'') self-shuts via `{:stop, :normal, state}`, r11 changes that to `{:stop, :destroyed, state}` so terminate/2 also skips snapshot. INV-27 NEW.
- **B7'' — workspace URI is `workspace://name`, not `entity://workspace/...` (codex r10 HIGH §3.5.x/q28).** r10's add_member example used `"entity://workspace/" <> name` but the actual code (apps/ezagent_domain_workspace/lib/ezagent/entity/workspace.ex:81) constructs `"workspace://#{name}"`. r11 corrects the lock key in §3.5.x to use the actual canonical form. The `with_locks/2` helper takes `%URI{}` structs and serializes via `URI.to_string/1`, so the canonical form is automatic — the example pseudocode in §2 was just illustrative and is updated. Also r10's `locks_in_order` snippet computed the sorted list but then ignored it; r11 makes the example use `with_locks/2` instead.
- **B7''' — User.destroy_db locks every workspace it mutates (codex r10 HIGH §3.4/q28).** r10 said "for a leaf User/Agent/Session destroy: only one lock (the target)" but User.destroy_db calls `Workspaces.remove_member_in_txn/2` for every workspace the user is a member of — which mutates the workspace's `member_uris` column, violating the §3.5.x rule that every operation mutating a Kind DB row must lock that URI.
  **r11 fix:** `Kind.Server.destroy/2` step 3a's lock list MUST include every URI that step 3b's `destroy_db/2` will mutate. For User: compute `[target_uri | workspaces_containing(user) | sessions_with_member(user)]` (the latter is empty under r11 since there's no session table — see B6''). For Workspace: `[target_uri | member_uris | template_uris | session_uris]` (the recursive cascade). The `with_locks/2` helper sorts + acquires all of them in order. Each per-Kind destroy_db has a sibling callback `destroy_db_locks(uri, ctx)` returning the URI list it will mutate; `Kind.Server.destroy` invokes this BEFORE entering the transaction to compute the lock set.
- **N4 — §3.12 stale ReadyGate references removed (codex r10 consistency).** §3.12.a and §3.12.b mentioned ReadyGate `:destroying` as still-active state; r9 removed that state but r10's §3.12 update missed those two lines. r11 replaces with the r10 mental model (DB row state is the source of truth; no ETS state needed).
- **INV-27 NEW** — Kind.Server.terminate/2 skips snapshot under destroy-induced shutdown: the test triggers a destroy on an `:on_terminate` Kind, then asserts (a) `Repo.get(KindSnapshot, target_uri_str)` returns `nil` after step 6 (no resurrection); (b) the in-GenServer fence's self-shutdown also produces no snapshot row.

**r10 changes (preserved for history — over r9):**

- **B1'' — Kind.Server's `handle_call`/`handle_cast` does backing_check (codex r9 CRITICAL §3.6.1).** r9's ReadyGate `:destroying` fence had a rollback race: if destroy A captures `:ready`, sets `:destroying`, then rolls back; concurrent destroy B (on same URI) commits and reaches step 6 terminate_child; A's revert to `:ready` overwrites B's `:destroying`, making the tearing-down pid dispatch-reachable. Or A crashes after setting `:destroying` and before reverting → `:destroying` stuck forever. The blind ETS-based prior-state restore is fundamentally racy.
  **r10 fix:** the dispatch fence moves INSIDE the Kind.Server GenServer itself, where it cannot race. `Kind.Server.handle_call/3` and `Kind.Server.handle_cast/2` now run `kind_module.backing_check(state.uri)` at the TOP of each message — if false, reply `{:error, :no_backing_entity}` AND initiate self-shutdown via `{:stop, :normal, state}` (graceful — flushes any `:on_terminate` snapshot tasks, but since the row is gone, no snapshot is written). This makes the fence:
  - **Single source of truth** — the Kind itself decides based on the DB row's existence.
  - **Race-free** — no ETS prior-state capture, no rollback restore, no cross-process synchronization. The fence is a synchronous DB read inside the dispatched Kind's process.
  - **Crash-tolerant** — orchestrator crashes leave a `:destroying` row only if the transaction had partially committed (impossible — Postgres transactions are atomic).
  ReadyGate `:destroying` from r9 is REMOVED. Dispatch goes straight `Invocation.dispatch → KindRegistry.lookup → live pid → Kind.Server.handle_call → backing_check`. Cost: one DB read per dispatch (only on FIRST message after destroy; the row is gone and the Kind self-shuts, so subsequent dispatches see `:error` from `KindRegistry.lookup` immediately — the slow path is one-shot per destroyed Kind). For the common (alive Kind) case, `backing_check` is a primary-key DB read, cached at the Repo's prepared-statement layer, microseconds — comparable to the existing slice access patterns. INV-24 updated to assert the in-GenServer check.
- **B6' — cross-Kind cleanup uses DIRECT Repo writes, not Behavior dispatch (codex r9 CRITICAL §3.5/§3.7).** r9 claimed `User.destroy_db/2` dispatched `Chat.scrub_owner` "using the same Repo connection" — but Ecto transactions are PROCESS-BOUND. Dispatch crosses into the Session GenServer via `GenServer.call`, which uses a DIFFERENT Repo connection. Session's scrub_owner write CANNOT join the User.destroy_db/2 transaction; a User destroy rollback leaves the Session scrubbed → ghost state.
  **r10 fix:** drop the cross-Kind dispatch entirely from User.destroy_db/2. Issue DIRECT `Repo.update_all(from s in SessionRow, where: s.owner_uri == ^user_uri, set: [owner_uri: nil])` inside `User.destroy_db/2`'s transaction. The Session GenServer's in-memory `:chat` slice is stale (owner_uri still points to the dead User), but `Session.data_owner/1` already does `Users.get_by_uri/1` DB-backing defense at the read site (preserved from r1–r6) — sees the row is gone OR has the scrubbed nil — returns `:no_owner`. Same outcome as before; one fewer cross-process boundary. The `Behavior.Chat.invoke(:scrub_owner, ...)` action + the `system://kind-destroy-cascade` system principal are KEPT for non-destroy callers but no longer used by `User.destroy_db/2`. §3.7 updated. Plugin isolation preserved — User domain still doesn't know Session's internal slice shape; it operates on the `SessionRow` schema which IS the domain-stable contract (just like every other cross-domain read in the codebase).
- **B2'' — WorkerSpawn.spawn/4 backing-check fence (codex r9 HIGH §2/§4.1).** r9 claimed `Kind.spawn/2` is the universal lower-layer, but `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/worker_spawn.ex:112` calls `DynamicSupervisor.start_child` DIRECTLY with a custom `PerBindingSupervisor` child spec (external_mirror's two-tier supervision tree). This path bypasses `Kind.spawn/2` entirely. r10 fix: add the backing_check at the TOP of `WorkerSpawn.spawn/4` — `if Worker.backing_check(worker_uri), do: continue, else: {:error, :no_backing_entity}`. The same per-Kind `backing_check/1` callback (B2' from r9) gates both `Kind.spawn/2` AND `WorkerSpawn.spawn/4`. PR-B adds this. **General principle**: ANY new direct `DynamicSupervisor.start_child` call site (now or future) MUST add the backing_check; PR-B includes a Credo/Sobelow lint rule (or a static-analysis script) flagging such calls as "must be preceded by backing_check". INV-25 NEW.
- **B7' — Workspace.add_member acquires the advisory lock + global lock ordering (codex r9 HIGH §3.5).** r9's INV-23 contract requires `Workspace.add_member/2` to take `Repo.advisory_xact_lock("workspace:#{uri_str}")` before mutating `member_uris`, but `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:103-135`'s actual `add_member/2` has NO transaction, NO advisory lock. r10 fix: PR-B explicitly modifies `Workspace.add_member/2` to wrap its (pre-spawn + dispatch + Store.update_members) sequence in `Repo.transaction(fn -> Repo.advisory_xact_lock("workspace:#{uri_str}"); ... end)`. The same lock is acquired by `Workspace.destroy_db/2` (B7 from r9).
  **Global advisory lock ordering — §3.5.x new section**: locks are acquired in **alphabetical order of URI strings**. `Workspace.destroy_db/2` cascade computes the list of all locks it needs (workspace + all member URIs), sorts them lexicographically, acquires them in that order, then cascades. This eliminates the W1→U→W2 deadlock pattern (concurrent destroys of overlapping workspaces both acquire locks in the same order; one waits for the other to commit). Per PR-B `__using__/0` macro: `Ezagent.Kind.Server.destroy/2` provides a `with_locks/2` helper that takes a list of URIs and a fn, sorts + acquires + invokes + releases.
- **N3 — audit outcome stored in `result` JSON (codex r9 HIGH §3.4).** The `invocations` table has `result jsonb` but NO standalone `outcome` column. r9 wrote `Repo.insert(InvocationsAudit, %{..., outcome: ...})` which would fail at runtime. r10 fix: outcome nests inside `result`: `result: %{"outcome" => "ok" | "already_destroyed", "kind_summary" => %{...}, "cascade_outcomes" => [...]}`. INV-19 updated to assert `result["outcome"]` rather than a top-level `outcome` field. No DB migration needed.
- **INV-25 NEW** — WorkerSpawn.spawn/4 returns `{:error, :no_backing_entity}` when called for a URI whose binding row was deleted (the test simulates the race where a binding was scrubbed via `Workspace.destroy_db/2` cascade but a stale `AdapterInstall.reinstall_all/0` boot-time call tries to respawn from the deleted row).
- **INV-26 NEW** — Kind.Server's in-GenServer dispatch fence: after `Kind.Server.destroy/2` step 3 commits (DB row gone), if a stale `KindRegistry.lookup` reference somehow returns the still-alive pid (the window between step 4 commit and step 6 terminate_child), an `Invocation.dispatch` sending a `:cast` to that pid: (a) the Kind.Server's `handle_cast` runs `backing_check(uri)` → false → replies (or rather drops the cast) and self-shuts via `{:stop, :normal, state}`; (b) the test process observing post-dispatch state asserts the pid is dead (Process.alive? returns false within 100ms). For `:call` mode: the GenServer's `handle_call` returns `{:reply, {:error, :no_backing_entity}, state, {:continue, :shutdown}}` (or equivalent), letting the caller see the error before the process exits.

**r9 changes (preserved for history — over r8):**

- **B1' — dispatch-path fence (codex r8 CRITICAL q11).** r8's claim "no new dispatches reach the live-but-DB-deleted pid" was FALSE: production dispatch goes `Invocation.dispatch → ReadyGate.status → KindRegistry.lookup → GenServer.call/cast` (`apps/ezagent_core/lib/ezagent/invocation.ex:87,111`), bypassing `SpawnRegistry` entirely. The backing_check_fn at SpawnRegistry only covers SPAWN paths, not DISPATCH paths. r9 fix: introduce **`ReadyGate :destroying` state** as the universal dispatch fence. `Kind.Server.destroy/2` step 3a (NEW first sub-step of step 3, before any per-Kind cleanup) calls `ReadyGate.put(target_uri, :destroying)`. `Invocation.dispatch/1` is modified to match `:destroying` and return `{:error, :no_backing_entity}` (same error code as backing_check_fn). The ReadyGate ETS write is atomic and read by every dispatcher. After the transaction commits, the row is gone AND ReadyGate is :destroying — both fences hold; after terminate_child, ReadyGate is purged (the entry is removed) since the URI no longer exists. ReadyGate.put on re-register's spawn naturally re-initializes to `:not_ready` then `:ready`.
- **B2' — universal backing-check in `Ezagent.Kind.spawn/2` (codex r8 CRITICAL q12/q5).** r8 only guarded `SpawnRegistry.spawn/1`, but production has MULTIPLE direct `Kind.spawn/2` callers that bypass SpawnRegistry: session creation (`apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message.ex:157`), workspace spawn (`apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:48`), system principal ensure (`apps/ezagent_core/lib/ezagent/system_principal.ex:90`), identity demand-spawn (`apps/ezagent_domain_identity/lib/ezagent/entity.ex:128`). r9 moves the backing-check to `Ezagent.Kind.spawn/2` itself — it is the universal lower-layer through which ALL spawn paths flow (including SpawnRegistry, which calls it under the hood). The check is keyed by `kind_module.backing_check/1` (a NEW callback on `Ezagent.Kind` behaviour) — each Kind owns its existence test. `SpawnRegistry`'s per-scheme `backing_check_fn` from r8 is REMOVED (redundant — replaced by the per-Kind callback).
- **B3' — existence precheck step 0 (codex r8 HIGH q13).** r8's `{:ok, :already_destroyed}` conflated "concurrent loser" with "URI never existed (operator typo)". r9 adds **step 0** to the orchestration BEFORE step 1: `if kind.backing_check(target_uri) == false → {:error, :not_found}`. So a typo'd URI returns `:not_found` (clear caller-actionable error), and `{:ok, :already_destroyed}` is reserved for the genuine concurrent-race loser. INV-22 NEW. The destroy operation thereby exhibits three distinct return shapes for "no row at the end": `:not_found` (never existed), `:already_destroyed` (lost the race after passing step 0), `:precheck_failed` (existed but undestroyable per can_destroy?/2).
- **B6 — q16 ghost-user mode: transaction encompasses external cleanup (codex r8 HIGH q16).** r8's step 3 (caps revocation, membership drop, binding scrub) ran OUTSIDE the transaction; if 4b's DB delete failed, step 3's effects persisted while the row remained — exactly the ghost-user bug. r9 fix: **move all DB-write cleanup INTO the Repo.transaction** (steps 3+4 collapse into a single atomic transaction). The transaction wraps: caps revocation (`Identity.revoke_all_caps/1`), membership rows delete, binding rows delete, profile delete, kind_snapshot delete, domain DB row delete, audit insert — all atomic. Per-Kind `destroy/2` callback splits into two phases: (a) `destroy_db/2` (DB-write cleanup — runs INSIDE the transaction) and (b) `destroy_runtime/2` (external resource release — sidecars, file handles, PubSub broadcasts — runs OUTSIDE the transaction AFTER commit, best-effort). If 4b fails, the transaction rolls back everything atomically: no caps revoked, no memberships dropped, no audit row. Operator sees the failure and re-runs cleanly. The runtime-release phase is the only "let-it-crash" surface, and it operates on already-deleted rows.
- **B7 — workspace cascade slice freeze (codex r8 HIGH q14).** r8 read `member_uris` from the live slice once at precheck, then cascaded. Concurrent `Workspace.add_member/2` between precheck and cascade could add a member that escapes destruction. r9 fix: `Workspace.destroy_db/2` (the inside-transaction phase) acquires a `Repo.advisory_xact_lock` on `workspace:<uri>` at the start, then reads `member_uris` from the workspace's DB row (NOT the live slice). The advisory lock blocks any concurrent `Workspace.add_member/2` that also attempts the same lock. The member list read inside the transaction is the **consistent point**; any add_member call concurrent with destroy either (a) acquires the lock first and adds, then destroy sees the new member, OR (b) waits for destroy's lock release and finds the workspace already gone — `add_member` then fails with `:no_such_workspace`. INV-23 NEW.
- **Nit fixes (codex r8 Notes):**
  - **§2 doc-comment list updated** — the Server.destroy numbered list still showed the old r7 ordering (terminate before snapshot/DB/audit). Updated to the r9 order: step 0 backing check → step 1 can_destroy? → step 2 trace_id → step 3+4 transaction (caps + memberships + bindings + snapshot + DB row + audit) → step 5 lookup → step 6 terminate_child → step 7 runtime-cleanup → step 8 broadcast.
  - **§7.6 inventory text updated** — was "five existing Kinds"; now references B5 full inventory (11 + 6 Templates).
- **INV-22 NEW** — typo'd URI returns `{:error, :not_found}` (NOT `:already_destroyed`, NOT `:precheck_failed`).
- **INV-23 NEW** — concurrent `Workspace.destroy/2` + `Workspace.add_member/2`: regardless of interleaving, never a state where a member is left alive AND its workspace is destroyed. Either (a) workspace destroyed before add_member committed (add_member fails `:no_such_workspace`) OR (b) add_member committed before destroy's lock acquisition (destroy cascades the new member).
- **INV-24 NEW** — dispatch-path fence: after Step 3a (`ReadyGate.put(uri, :destroying)`), any concurrent `Invocation.dispatch/1` (either `:cast` or `:call`) against the URI returns `{:error, :no_backing_entity}` (NOT `{:ok, _}` from the live pid, NOT `:not_ready`). Verifies the dispatch-path fence — the r8 CRITICAL B1 finding's gate.

**r8 changes (preserved for history — over r7):**

- **B1 — transaction scope unified + race fenced by reordering.** §3.4 / §4.1 / Appendix A previously gave three inconsistent transaction-scope claims (steps 5+6 / 5–7 / 6+7). r8 picks ONE normative scope: the Repo.transaction wraps the **three DB writes** — `delete kind_snapshot row` + `delete domain row (Users.delete / Agents.delete / …)` + `audit row insert`. Per `feedback_let_it_crash_no_workarounds`, the race is fenced by **structural reordering** (DB delete BEFORE terminate_child), NOT by adding ETS markers or extra state: the orchestration now runs `pre-check → per-Kind destroy → Repo.transaction[snapshot purge + DB row delete + audit insert] → terminate_child → broadcast`. Between the transaction commit and `terminate_child`, the live pid is still alive — but the DB-backing check at the SpawnRegistry entry point (B2) means no new dispatch can spawn a fresh Kind, and the live pid is being drained by `terminate/2`. Linearization point: the transaction commit. After commit, no spawn path can produce a Kind at this URI; the in-flight pid is unreachable to new callers because (a) its caps are revoked (step 3), (b) the DB-backing check rejects re-entry (B2), and (c) `terminate_child` completes synchronously immediately after.
- **B2 — `SpawnRegistry.spawn/1` DB-backing check moved BEFORE `KindRegistry.lookup/1`.** r7 placed the DB-backing check inside each scheme's spawn fn (only reached after `lookup` MISSES). If the Kind is alive (mid-tear-down or recently respawned via another path), `spawn_detailed/1` returns the live pid WITHOUT consulting the DB. r8 introduces a per-scheme `backing_check_fn/1` registered alongside `spawn_fn/1`; `SpawnRegistry.spawn/1` calls the backing check FIRST and returns `{:error, :no_backing_entity}` if the row is gone — even if a live pid happens to still exist. Each scheme owner (identity / chat / workspace / external_mirror) provides its own backing_check_fn.
- **B3 — concurrent-destroy idempotency contract.** r7's return shape did not cover "two callers race to destroy the same URI". r8 adds `{:ok, :already_destroyed}`: the loser of the race (whose DB delete affects 0 rows because the winner already committed) returns success-with-tag. Both callers' audit rows are recorded under distinct `trace_id`s. Single DB row delete actually happens. INV-19 pins this.
- **B4 — Workspace cascade refuses nested workspaces.** r7 said "every member is a leaf Kind" but did not enforce. r8 adds explicit rejection in `Workspace.can_destroy?/2`: if any member URI's scheme/host starts with `workspace://`, return `{:error, :nested_workspace_not_supported}`. Fail-fast, no cycle-detection. INV-14 fixture extended.
- **B5 — REQUIRED destroy/2 migration inventory expanded.** Real grep of `@behaviour Ezagent.Kind` across lib/ (excluding test/support): **11 production Kinds + 6 production Kind.Templates**, not the 5 r7 claimed. Production Kinds: `User`, `Agent`, `Session`, `Workspace`, `ExternalMirrorWorker`, `System`, `AgentTemplate`, `SessionTemplate`, `Echo`, `CurlAgent`, `NpAgent`. Production Templates (impl `Ezagent.Kind.Template`): `CcAgent`, `CodexAgent`, `EchoAgent`, `CurlAgent` template, `GenericSession`, `NpAgent` template. Per recommendation (a): REQUIRED for all production Kinds + Templates; test-support Kinds get a default no-op `Kind.default_destroy/2` macro. PR-C migration list expanded accordingly.
- **N1 — Loader / BootReconciler note.** §3.5 adds one line: "Loader/BootReconciler paths accept the same DB-backing check at SpawnRegistry entry; no cache layer planned." Closes codex r7 N1.
- **N2 — Appendix INV count corrected.** Appendix B previously said "16 entries"; the INV table actually went to INV-18. r8 adds INV-19/20/21 → 21 total. Appendix B updated.
- **INV-19 NEW** — concurrent double-destroy idempotency: two parallel `Kind.Server.destroy(uri)` calls; assert one `{:ok, %{...}}` + one `{:ok, :already_destroyed}`; single DB delete; both audit rows present with distinct trace_ids.
- **INV-20 NEW** — spawn-after-DB-delete returns `{:error, :no_backing_entity}` even when a live pid still exists from a pre-delete spawn (the B2 check fires before `KindRegistry.lookup`).
- **INV-21 NEW** — backing_check_fn ordering: monkey-patch `KindRegistry.lookup` to assert NOT called before `backing_check_fn`; verifies §2 / §4.1 wiring is correct.

**r7 (compressed):** wholesale pivot from r1–r6 tombstone design to "Kind lifecycle CRUD parity" — added `Ezagent.Kind.destroy/2` callback, `Ezagent.Kind.Server.destroy/2` orchestrator, DB-backing check at SpawnRegistry entity callback, `AgentBridge.Adapter.teardown/1` extension. INV-13 (re-register works) + INV-14 (Workspace cascade) as architectural-goal gates. No codex round on r7 (Allen's directive).

**r7 changes (preserved for history):**

- **DELETE** entire tombstone design (the r1–r6 mechanism): `entity_tombstones` DB table, ETS mirror, `Ezagent.SpawnRegistry.tombstone_and_kill/1` atomic primitive, multi-boundary `tombstoned?/1` checks at three spawn paths, append-only "permanent deny" semantics, OQ-1 TTL discussion, all r1–r6 codex review responses about tombstone correctness.
- **ADD** `Ezagent.Kind.destroy/2` callback to the `Ezagent.Kind` behaviour. This is the structural fix — Kinds today expose `type_name/0`, `behaviors/0`, `persistence/0`, `uri_from_args/1`, `snapshot_version/0`, `supervisor/0`, `spawn_strategy/0`, `terminate_strategy/0`, `holds_cap?/2` (the C and R of CRUD plus operational metadata) but NO D. r7 closes the gap.
- **ADD** `Ezagent.Kind.Server.destroy/2` as the public API that orchestrates: `Adapter.can_destroy?/2` → `kind.destroy/2` (per-Kind cleanup) → `DynamicSupervisor.terminate_child/2` (graceful — NOT `:brutal_kill`) → snapshot purge → DB row delete → cross-ref scrub → audit emit.
- **ADD** DB-backing check at each registered SpawnRegistry entity callback. If `Users.get_by_uri(uri) == nil` for `entity://user/...`, the spawn fn returns `{:error, :no_backing_entity}` instead of spawning. This replaces tombstone's "permanent deny" mechanism with "DB-row-is-truth" semantics: deletion = DB row removal, re-creation = DB row insert, next spawn = fresh Kind.
- **EXTEND** `Ezagent.AgentBridge.Adapter` behaviour with `teardown/1` optional callback (default no-op) — parallel to `deliver/2` / `handle_client_event/3` / `join_info/2`. Per-flavor sidecar cleanup (cc unbinds BridgeRegistry, codex stops sidecar+app_server+PTY+removes per-agent dir, echo no-op, curl no-op, np stops nested-process state). Agent Kind's `destroy/2` delegates to `AgentBridge.Adapter.teardown/1` for plugin isolation.
- **Workspace deletion NO LONGER excluded** — naturally falls under same machinery. `Workspace.Kind.destroy/2` iterates member entities and calls `Ezagent.Kind.Server.destroy/2` on each (cross-Kind cascade). Workspace deletion gets the same primitives the SPEC defines for all Kinds.
- **§1 problem statement re-scoped** from "ghost user is special" to "Kind contract lacks D in CRUD". The `system/linyilun` ghost was an instance of the broader gap.
- **Re-register naturally supported** — `Users.create(deleted_uri, ...)` writes a fresh row; next `SpawnRegistry.spawn` succeeds because the DB-backing check passes; the new Kind starts with NO inherited state (caps, memberships, snapshot — all gone, fresh init).
- **PR sequence revised** — PR-A (this SPEC) → PR-B core (Kind.destroy callback + Kind.Server.destroy/2 + SpawnRegistry DB-backing check + AgentBridge.Adapter.teardown extension) → PR-C domain Kinds (User.destroy + Agent.destroy + Session.destroy + Workspace.destroy + Worker.destroy) → PR-D plugin bridge teardown impls (cc / codex / echo / curl / np) → PR-E admin LV delete UI + CLI.
- **§5 INV** renumbered: tombstone-specific INVs (INV-2 `:tombstoned`, INV-2a/2b boundary checks, INV-11 ETS reload, INV-13a system principal) removed; replaced with `:no_backing_entity` semantics. Two NEW invariants: **INV-13** re-register-same-URI works (no inherited state); **INV-14** cross-Kind cascade (Workspace.destroy cascades to members).
- **§10 OQ trimmed**: OQ-1 (tombstone TTL) and OQ-8 (NOT NULL migration timing — backfill stays as written but no longer an open question) REMOVED. One NEW OQ: should `Ezagent.Kind.destroy/2` be REQUIRED or OPTIONAL (default no-op)? Recommendation: REQUIRED — forces every Kind author to think about cleanup.

**r1–r6 history (compressed):** Six prior revisions resolved codex findings against the tombstone design (multi-boundary enforcement, atomic primitive, Session owner scrub via Chat action, Worker URI column add, entity_tokens cascade, system principal narrowing, cold-load defense at three data_owner sites, Chat behavior 5-part plumbing). Those mechanics are obsolete under r7; the lessons that survive ("DB-row-is-truth", "every read-site asks the source of truth", "behavior registration is N-part — actions / required_caps / cap_subjects / invoke / interface / register_chat_behaviors", "structural cleanup over policy flags") inform r7's design but the tombstone artifact is fully removed.

**Tier:** `Ezagent.Kind` behaviour extension (`apps/ezagent_core/`) + `Ezagent.Kind.Server` public destroy API (`apps/ezagent_core/`) + `Ezagent.AgentBridge.Adapter.teardown/1` extension (`apps/ezagent_domain_agent_bridge/`) + per-Kind `destroy/2` impls in their owning domain apps + per-flavor teardown impls in their owning plugins. Admin LV integration in `apps/ezagent_plugin_liveview/`.

**Trigger:** Allen 2026-05-28 — after observing the `system/linyilun` ghost-user problem (deleted from DB + snapshot, but Kind keeps respawning via SpawnRegistry catch-all). r1–r6 attempted a tombstone fix; r7 pivots to the structural fix Allen identified: every Kind needs a `destroy` callback, and the SpawnRegistry's entity callback must check DB-backing rather than maintain a separate "tombstoned" flag.

**Companion:** `2026-05-28-entity-deletion.zh_cn.md` (per `feedback_bilingual_docs_convention`).

**Predecessor memories (load-bearing):**
- `feedback_let_it_crash_no_workarounds` — the r7 pivot is itself an application of this: the tombstone flag was POLICY (append-only deny-list, separate table, multi-boundary enforcement). The DB-row-is-truth + Kind.destroy is STRUCTURAL (the DB row is the source of truth; absence means absence; presence means presence; deletion writes nothing extra).
- `feedback_north_star_plugin_isolation` — `Ezagent.Kind.destroy/2` is a behaviour callback (every plugin's Kind impls it); `AgentBridge.Adapter.teardown/1` is a per-flavor callback (each bridge plugin impls it); generic orchestration in `Kind.Server.destroy/2`. Plugin authors writing a new Kind add a `destroy/2`; plugin authors writing a new bridge flavor add a `teardown/1`. Zero touch to core.
- `feedback_completion_requires_invariant_test` — INV-13 (re-register same URI works) is the architectural-goal gate: a passing INV-13 proves the "DB-row-is-truth" semantics is real, not just claimed. INV-14 (cross-Kind cascade) is the workspace-as-Kind gate.
- `feedback_uuid_is_canonical_identifier` — operate on URIs not display names. Re-register at the same URI is allowed BECAUSE the URI is canonical; the second incarnation is structurally distinct from the first (different snapshot, different caps, different memberships) but operates at the same address.
- `feedback_destructive_migration_anti_pattern` — destroy of LIVE entity in production needs operator awareness. SPEC includes LV confirm dialog + `mix ezagent.kind.destroy` CLI gate.
- `feedback_register_lookup_key_parity` — the entity spawn lookup and the Kind.destroy must use the SAME identity key (URI). Diverging keys = ghost reintroduction risk.

**Parent / historical context:**
- `system/linyilun` retire (2026-05-26): the empirical motivator. Partial deletion left the in-memory Kind respawning from SpawnRegistry catch-all because the entity callback had NO check on backing data — it spawned a User Kind unconditionally for any `entity://user/...` URI. r7 fixes that with the DB-backing check; the broader gap (no D in CRUD) is addressed by `Kind.destroy/2`.
- `2026-05-27-workspace-cap-based-visibility.md`: `Workspace.list_workspaces_for/2` uses cap-membership to derive visibility. A destroyed user's caps are revoked in `User.destroy/2`, so visibility drops as a consequence.
- `2026-05-27-uri-canonicalization.md`: destroy compares URIs with strict equality; canonical URI form makes the cascade audit reliable.

---

## §1 Problem statement — Kind contract lacks D in CRUD

### 1.1 The empirical observation

Allen attempted to retire `entity://user/system/linyilun` on 2026-05-26 via DB-side cleanup:

1. **DB level** — completed: `users` row DELETED, `entity_profiles` DELETED, `kind_snapshots` DELETED, `feishu_user_bindings` rebound to `system/admin`.
2. **Runtime level** — left dangling: `KindRegistry.lookup("entity://user/system/linyilun")` STILL returned `{:ok, pid}` because the entity callback (`SpawnRegistry.register("entity", fn ...)`) had no DB-backing check; any path that called `SpawnRegistry.spawn(deleted_uri)` resurrected the Kind from defaults. Three successive `brutal_kill` attempts with snapshot deleted between each: ghost still alive at next lookup.
3. **User-facing symptoms:** caller_uri stayed valid; LV display name + cookie session identity resolved to the ghost; dispatch attempts got `chat.join` cap denied (caps were emptied) but the IDENTITY itself was not "deleted" — it was "exists but has no permissions". Operator UX suggested "this user has no caps" not "this user does not exist".

### 1.2 Diagnosis: D is missing from CRUD on the Kind contract

`Ezagent.Kind` (`apps/ezagent_core/lib/ezagent/kind.ex:1-182`) is the behaviour every Kind implements. Its current callbacks cover:

- **C (Create):** `uri_from_args/1` + `spawn_strategy/0` + Kind args plumbing.
- **R (Read):** `behaviors/0` + slice access via `Ezagent.Kind.get_slice/2` + `holds_cap?/2`.
- **U (Update):** Behavior dispatch (`Behavior.invoke/4`) mutates slice state; `persistence/0` policy + snapshot.
- **D (Destroy):** **MISSING.** There is no callback that says "the Kind owning this URI is being permanently retired; do per-Kind cleanup (in-memory teardown, external resource release, side-effect notification) before the supervisor terminates the GenServer."

The ghost problem is a symptom. The deeper gap is that operators (and the generic destroy orchestrator we want to build) have nowhere to ask the Kind: "you're being destroyed — what do YOU need to clean up?" Today every Kind would have to be torn down by an external cascade that knows its internals — that violates plugin isolation.

The `system/linyilun` case made this concrete: User had Feishu bindings, profile rows, entity_tokens, workspace memberships, sessions it owned. NONE of those is core's responsibility; ALL of them are User-internal. Without a `User.destroy/2` callback, the destroy orchestrator (or the operator running SQL) has to know User's internals — which is exactly what the Kind boundary is supposed to hide.

### 1.3 Identity reachability after destroy

A URI is "destroyed" iff:

- `Users.get_by_uri/1` (or the per-Kind equivalent) returns `nil` (DB row is the source of truth)
- `Ezagent.SpawnRegistry.spawn(uri)` returns `{:error, :no_backing_entity}` (entity callback checks DB; refuses to spawn if no row)
- `Ezagent.KindRegistry.lookup(uri)` returns `:error` (the Kind was terminated; Registry drops dead pids)
- No Kind respawns from any path (workspace member iteration, Feishu binding lookup, LV session cookie, dispatch from another agent's reply, adapter reconcile, …) because every path that ultimately calls `SpawnRegistry.spawn/1` gets `:no_backing_entity`
- `Workspace.list_workspaces_for/2` excludes them from every caller's view (caps revoked + memberships dropped by `User.destroy/2`)
- Cross-references (sessions slice owner_uri, audit rows) are scrubbed or nullified by the responsible Kind's `destroy/2`
- Per-Kind external resources are released (Agent's sidecar via `AgentBridge.Adapter.teardown/1`, Worker's adapter terminate, etc)

These are not separate ad-hoc cleanups — they are the output of `Ezagent.Kind.Server.destroy/2` invoking the Kind's own `destroy/2` callback. Adding a row back at the same URI re-enables the spawn, and the next spawn produces a fresh Kind (no inherited state).

### 1.4 Bug class this prevents

- "I deleted user X but they can still send Feishu messages" (binding lookup hits a respawned Kind because no DB-backing check)
- "I deleted user X but the session they own still routes to them" (Session.destroy/2 was never called; or User.destroy/2 didn't scrub Session.owner_uri)
- "I deleted user X but their old cli token still authenticates" (User.destroy/2 didn't revoke entity_tokens)
- "I deleted agent Y but its cc bridge is still connected" (Agent.destroy/2 didn't call AgentBridge.Adapter.teardown/1)
- "I removed user X from workspace W but they can still see W in their dropdown" (caps not revoked by User.destroy/2)
- "On rare boot, deleted user X resurrects" (SpawnRegistry entity callback had no DB-backing check)
- "I deleted Worker W but external_mirror_bindings still cause adapter reconcile to spawn a fresh one" (Worker.destroy/2 didn't drop bindings; `worker_uri` column lets the query target the row directly)
- "I deleted Workspace W but its member User Kinds are still alive" (Workspace.destroy/2 didn't iterate + call Kind.Server.destroy/2 on each member)

All eight become regression tests under `Ezagent.Kind.destroy/2` + the DB-backing check. The first six were observed or theoretically observable today; #7 is the original B5 bug rediscovered in r1–r2; #8 is the workspace deletion case the prior SPEC explicitly excluded.

---

## §2 Decision: **`Ezagent.Kind.destroy/2` callback + `Kind.Server.destroy/2` orchestrator + DB-backing spawn**

The `Ezagent.Kind` behaviour gains a `destroy/2` callback (the D). The `Ezagent.Kind.Server` GenServer gains a public `destroy/2` API that orchestrates the structural sequence. The SpawnRegistry entity callbacks gain a DB-backing check (refusing to spawn if no row exists). The `AgentBridge.Adapter` behaviour gains an optional `teardown/1` callback for per-flavor sidecar cleanup.

```elixir
# Extension to existing Ezagent.Kind behaviour
defmodule Ezagent.Kind do
  # ... existing callbacks: type_name/0, behaviors/0, persistence/0,
  #     uri_from_args/1, snapshot_version/0, supervisor/0,
  #     spawn_strategy/0, terminate_strategy/0, holds_cap?/2 ...

  @doc """
  D in CRUD. Called by `Ezagent.Kind.Server.destroy/2` BEFORE the
  GenServer is terminated. Per-Kind cleanup: release external
  resources (sidecars, file handles, sockets), scrub cross-references
  the Kind owns (User scrubs Session.owner_uri it created, Agent
  scrubs its bridge registry binding), revoke caps, drop memberships.

  Receives the URI being destroyed + the destroy context (caller,
  reason, trace_id). Returns `{:ok, summary}` on full success or
  `{:error, reason}` on per-Kind cleanup failure. Returning an error
  does NOT prevent the GenServer termination — destroy is best-effort
  from the per-Kind perspective; the orchestrator records the partial
  outcome and continues to terminate.
  """
  @callback destroy(uri :: URI.t(), ctx :: %{caller: URI.t(), reason: String.t(), trace_id: binary()}) ::
              {:ok, summary :: map()} | {:error, reason :: term()}
end
```

```elixir
# Public destroy API — the entry point operators / admin LV / CLI use
defmodule Ezagent.Kind.Server do
  @doc """
  Destroy the Kind at `target_uri`. Orchestrates (r10 ordering):
    0. Existence precheck — `kind.backing_check(uri)`; nil → {:error, :not_found}
    1. `kind.can_destroy?(uri, ctx)` (per-Kind precheck) — abort on refuse
    2. Generate trace_id
    3. Repo.transaction (atomic):
       3a. lock_uris = kind.destroy_db_locks(uri, ctx)   — r11 B7''': the Kind
                                            declares every URI it will mutate.
                                            with_locks(sorted lock_uris, fn ->
                                              acquire each Repo.advisory_xact_lock
                                              in URI-string sort order
                                              (§3.5.x global ordering rule)
       3b. kind.destroy_db(uri, ctx)         — caps revoke + memberships drop
                                              + bindings delete + profile delete.
                                              All via SAME Repo connection
                                              (transaction-bound). NO cross-process
                                              dispatch (r10 B6' / r11 B6'' — for
                                              ownership scrub the read-site
                                              DB-backing defense at consumers
                                              handles staleness; no direct write
                                              needed because session ownership
                                              lives in the live slice, not a DB row).
       3c. Repo.delete(KindSnapshot, uri_str)
       3d. kind.delete_db_row(uri)           — Users.delete / Agents.delete / …
                                              — if rows_affected == 0, treat as
                                              idempotent loser → tag
                                              outcome :already_destroyed
       3e. Repo.insert(InvocationsAudit, %{action: "kind.destroyed", ...,
                                            result: %{"outcome" => ...,
                                                      "trace_id" => ..., ...}})
                                              — r10 N3: outcome nests inside
                                              result JSON, NOT a top-level column
    4. (transaction commits OR rolls back atomically; on rollback, the
        DB row is unchanged — no state mutation occurred)
    5. KindRegistry.lookup(uri) — locate live pid (if any)
    6. DynamicSupervisor.terminate_child(supervisor, pid) with :destroyed
       shutdown reason — r11 B8: Kind.Server.terminate(:destroyed, _) skips
       the :on_terminate snapshot write that would otherwise resurrect
       the just-deleted snapshot row.
    7. kind.destroy_runtime(uri, ctx) — sidecar teardown, external resource
                                         release; OUTSIDE transaction;
                                         best-effort; errors logged not raised
    8. PubSub.broadcast({:kind_destroyed, uri, reason})

  Re-spawn after destroy: `Ezagent.Kind.spawn/2` calls
  `kind_module.backing_check(uri)` at the TOP (BEFORE
  DynamicSupervisor.start_child) and returns
  `{:error, :no_backing_entity}` if the row is gone. ALSO
  `Ezagent.ExternalMirror.WorkerSpawn.spawn/4` (the bypass codex r9
  found) gets the same check at its entry — see §4.1 PR-B.

  Re-dispatch after destroy (r10 B1''): `Ezagent.Invocation.dispatch/1`
  goes via `KindRegistry.lookup` (no ReadyGate `:destroying` fence —
  removed in r10). If the lookup hits a live tearing-down pid in the
  window between step 4 commit and step 6 terminate_child, the message
  arrives at `Kind.Server.handle_call`/`handle_cast`, which runs
  `kind_module.backing_check(state.uri)` at the TOP — sees row gone —
  replies `{:error, :no_backing_entity}` (or drops the cast) and
  self-shuts via `{:stop, :normal, state}`. The fence lives inside the
  Kind itself; no ETS state to revert; no rollback race.

  Returns:
    * `{:ok, summary}`            — destroy completed cleanly
    * `{:ok, :already_destroyed}` — concurrent destroy lost the DB-delete
                                    race; the row is already gone (idempotent
                                    success — INV-19). Both callers' audit
                                    rows are recorded under distinct trace_ids.
    * `{:error, :not_found}`             — backing_check(uri) returned false at
                                            step 0 — URI never existed (typo
                                            or already-destroyed-pre-this-call
                                            where caller is NOT in a concurrent
                                            race). INV-22 distinguishes this
                                            from :already_destroyed.
    * `{:error, {:partial, ...}}`        — runtime-cleanup (step 7) failed AFTER
                                            transaction committed; DB row + snapshot
                                            are gone; external resource may have
                                            leaked (sidecar, file handle).
    * `{:error, {:precheck_failed, _}}`  — can_destroy?/2 refused; no mutation.
    * `{:error, {:transaction_failed, _}}` — Repo.transaction rolled back (rare;
                                              DB error during step 3). NO state
                                              mutation occurred (atomicity).
  """
  @spec destroy(URI.t(), ctx :: %{caller: URI.t(), reason: String.t()}) ::
          {:ok, summary :: map()}
          | {:ok, :already_destroyed}
          | {:error, :not_found}
          | {:error, {:partial, map()}}
          | {:error, {:precheck_failed, term()}}
          | {:error, {:transaction_failed, term()}}
  def destroy(%URI{} = target_uri, ctx), do: ...
end
```

```elixir
# Extension to existing Ezagent.AgentBridge.Adapter behaviour
defmodule Ezagent.AgentBridge.Adapter do
  # ... existing callbacks: flavor/0, agent_uri_prefix/0, deliver/2,
  #     handle_client_event/3, join_info/2 (optional), socket_path/0,
  #     channel_topic_prefix/0 ...

  @doc """
  Per-flavor bridge teardown. Called by `Agent.destroy/2` when an
  Agent is destroyed. Default no-op (echo / curl). Plugins that
  hold external state implement: cc unbinds BridgeRegistry, codex
  stops sidecar + app_server + PTY + removes per-agent dir, np
  stops nested-process state.

  Best-effort — errors are logged but do not block the destroy
  pipeline. The Agent Kind is going away regardless.
  """
  @callback teardown(agent_uri :: URI.t()) :: :ok | {:error, term()}

  @optional_callbacks teardown: 1, join_info: 2, socket_path: 0,
                      channel_topic_prefix: 0
end
```

```elixir
# (r9) Ezagent.Kind gains a backing_check/1 callback. Every Kind owns its
# own existence test. The check is invoked at the TOP of Ezagent.Kind.spawn/2
# — the UNIVERSAL lower-layer through which ALL spawn paths flow
# (SpawnRegistry.spawn/1, direct Kind.spawn/2 callers in chat / workspace /
# identity / system_principal). r8's SpawnRegistry-only backing_check_fn is
# REMOVED — replaced by this per-Kind callback.
defmodule Ezagent.Kind do
  @callback backing_check(uri :: URI.t()) :: boolean()
  # ... existing callbacks ...
end

# Each production Kind implements backing_check:
defmodule Ezagent.Entity.User do
  @impl Ezagent.Kind
  def backing_check(uri), do: Users.get_by_uri(uri) != nil
end

defmodule Ezagent.Entity.Agent do
  @impl Ezagent.Kind
  def backing_check(uri), do: Agents.get_by_uri(uri) != nil
end

# System Kind always returns true (the URI's existence IS its row in the
# system principal catalog, not a DB table):
defmodule Ezagent.Entity.System do
  @impl Ezagent.Kind
  def backing_check(_uri), do: true
end

# Test-support Kinds use the default macro:
defmodule SomeTestKind do
  use Ezagent.Kind.TestImpl   # default backing_check returns true
end
```

```elixir
# Extension to Ezagent.Kind.spawn/2 (apps/ezagent_core/lib/ezagent/kind.ex:293+).
# The B2' universal fence. EVERY spawn path passes through here.
def spawn(kind_module, %{uri: uri} = params) when is_atom(kind_module) do
  if kind_module.backing_check(uri) do
    case spawn_strategy(kind_module) do
      :standard ->
        DynamicSupervisor.start_child(
          resolve_supervisor(kind_module),
          {Ezagent.Kind.Server, {kind_module, params}}
        )
      {:custom, mod, fun} ->
        apply(mod, fun, [params])
    end
  else
    {:error, :no_backing_entity}
  end
end
```

```elixir
# (r10/r11) Dispatch fence moves INSIDE the Kind.Server GenServer.
# Single source of truth — the Kind itself, with a synchronous DB read
# at the top of each message handler. No ETS state to revert, no
# cross-process race, no orphan-:destroying state.
#
# Ezagent.Invocation.dispatch/1 is UNCHANGED from upstream (no :destroying
# arm needed). The fence lives one layer deeper.
#
# r11 — uses {:stop, :destroyed, state} so terminate/2's :destroyed arm
# skips the :on_terminate snapshot (B8 fix). Plain :normal would resurrect
# the just-deleted snapshot row.
defmodule Ezagent.Kind.Server do
  # ... existing handle_continue/handle_info/etc ...

  @impl true
  def handle_call({:dispatch, %Invocation{} = inv}, _from, %{kind_module: km, uri: uri} = state) do
    if km.backing_check(uri) do
      # Normal dispatch path — Behavior.invoke etc.
      do_handle_dispatch_call(inv, state)
    else
      # The row is gone (destroy committed). Reply with the standard
      # no-backing-entity error and self-shutdown with :destroyed reason
      # (B8 — terminate/2 :destroyed arm skips snapshot).
      {:reply, {:error, :no_backing_entity}, state, {:continue, :shutdown_destroyed}}
    end
  end

  @impl true
  def handle_cast({:dispatch, %Invocation{} = inv}, %{kind_module: km, uri: uri} = state) do
    if km.backing_check(uri) do
      do_handle_dispatch_cast(inv, state)
    else
      # Drop the cast and self-shutdown with :destroyed (skips snapshot).
      {:stop, :destroyed, state}
    end
  end

  @impl true
  def handle_continue(:shutdown_destroyed, state) do
    {:stop, :destroyed, state}
  end

  # r11 B8 — under destroy-induced shutdown, skip the :on_terminate snapshot
  # write that would otherwise resurrect the just-deleted snapshot row.
  @impl true
  def terminate(:destroyed, _state), do: :ok
  def terminate(reason, state), do: existing_terminate_body(reason, state)
end
```

```elixir
# (r11) User.destroy_db — cross-Kind state is handled by the read-site
# DB-backing defense, NOT by direct cross-Kind writes (codex r10
# CRITICAL §3.5/§3.7: no SessionRow schema exists; r10's mechanism was
# fictitious). Session ownership lives in the live :chat slice; the
# slice becomes stale when User is destroyed but reads always go
# through Users.get_by_uri/1 at the consumer (Chat / Publisher /
# ExternalMirror data_owner/1), returning :no_owner when the user row
# is gone.
defmodule Ezagent.Entity.User do
  @impl Ezagent.Kind
  def destroy_db(%URI{} = user_uri, _ctx) do
    # All inside the orchestrator-supplied Repo.transaction.
    user_uri_str = URI.to_string(user_uri)

    Identity.revoke_all_caps(user_uri)                                             # [DB write]
    Repo.delete_all(from t in EntityToken, where: t.entity_uri == ^user_uri_str)   # [DB write]
    Repo.delete_all(from b in FeishuUserBinding, where: b.user_uri == ^user_uri_str)  # [DB write]
    Repo.delete(EntityProfile, user_uri_str)                                       # [DB write]

    # Workspace memberships: each remove_member is a Workspaces.Store.update_members
    # call against the SAME Repo connection (transaction-bound). r10 B7''' — the
    # orchestrator's lock set includes EACH of these workspace URIs (see destroy_db_locks/2).
    workspaces = Workspaces.list_workspaces_containing(user_uri)
    Enum.each(workspaces, fn ws ->
      Workspaces.remove_member_in_txn(ws.uri, user_uri)                             # [DB write]
    end)

    # NO direct write to "session rows" — there are none. The Session Kind's
    # :chat slice may still cache user_uri as owner, but every read site does
    # the Users.get_by_uri/1 DB-backing check (Chat.data_owner, Publisher.SessionImpl.data_owner,
    # ExternalMirror.data_owner per r11 B6'' new addition) and returns :no_owner.
    # Slice cache staleness is harmless under this discipline.

    {:ok, %{
      caps_revoked: true,
      tokens_revoked: true,
      bindings_dropped: true,
      profile_dropped: true,
      workspace_memberships_dropped: length(workspaces)
    }}
  end

  @impl Ezagent.Kind
  def destroy_db_locks(%URI{} = user_uri, _ctx) do
    # r11 B7''' — the orchestrator's step 3a acquires locks for ALL URIs this
    # destroy_db will mutate. Workspace memberships count: each workspace row
    # mutation needs the workspace's lock.
    [user_uri | Enum.map(Workspaces.list_workspaces_containing(user_uri), & &1.uri)]
  end
end
```

The field-name parallels are intentional: `destroy_db/2` mirrors `init_slice/1` (Behavior callbacks that create / destroy Kind state in DB); `destroy_runtime/2` mirrors `terminate/2` (the external-resource release pair); `backing_check/1` mirrors `uri_from_args/1` (URI introspection callbacks); `destroy_db_locks/2` mirrors `holds_cap?/2` (introspective queries the Kind answers for the orchestrator). Plugin authors writing CRUD have parallel callbacks for each letter — the structure is symmetric. The in-GenServer dispatch fence (Kind.Server's `handle_call`/`handle_cast` running `backing_check` at the top, r10 B1'') is a Behavior-agnostic gate — every Kind benefits without per-Kind code. The `terminate(:destroyed, _)` arm (r11 B8) is also Behavior-agnostic — it sits in `Kind.Server`, not in any Kind.

---

## §3 Semantics — `Kind.destroy/2` + `Kind.Server.destroy/2` defined precisely

### 3.1 Inputs to `Kind.Server.destroy/2`

- `target_uri` — the `%URI{}` of the Kind being destroyed. MUST be registered with a SpawnRegistry scheme.
- `ctx.caller` — the operator URI doing the destroy. MUST hold a cap to destroy this Kind (see §3.2 cap shape).
- `ctx.reason` — operator-supplied free-text. Stored in the audit row. NOT optional.

### 3.2 Cap-gating

The destroy operation is cap-gated. The cap shape:

```
Capability{
  kind: <target_kind_module>,   # e.g. Ezagent.Entity.User
  behavior: Ezagent.Kind,        # the behaviour that owns destroy/2
  action: :destroy,
  instance: :any | <specific_uri>,
  workspace_uri: :any | <workspace>
}
```

Admin-only by default (`system://bootstrap/default` carries `instance: :any` + `workspace_uri: :any`). Workspace admins MAY hold a narrowed cap (`instance: :any` within `workspace_uri: <their_workspace>`). Per-Kind policies can refine via `can_destroy?/2` (§3.3).

### 3.3 Pre-check via `Adapter.can_destroy?/2`

Per-Kind pre-check that runs BEFORE any mutation. Used for invariants the cap system can't express (e.g. "bootstrap admin is undestroyable", "cannot destroy a workspace admin who is the sole admin"). Returns `:ok | {:error, reason}`. If `{:error, _}`, the destroy aborts with `{:error, {:precheck_failed, reason}}` and NO state is mutated.

```elixir
@callback can_destroy?(uri :: URI.t(), ctx :: map()) ::
            :ok | {:error, reason :: atom() | {atom(), term()}}
```

Each Kind module defines its own `can_destroy?/2`. Example invariants:
- `User.can_destroy?` refuses the bootstrap admin URI
- `Workspace.can_destroy?` refuses a workspace that contains live members the operator can't also destroy
- `Agent.can_destroy?` MAY refuse an Agent currently serving an in-flight session (operator-policy decision)

### 3.4 Orchestration sequence — normative (r10: in-GenServer dispatch fence + direct cross-Kind writes + global lock order)

The `Kind.Server.destroy/2` body. r10 builds on r9 by replacing the racy ETS-based dispatch fence with an in-GenServer check, and replacing the cross-process Behavior dispatch with direct Repo writes:

- **r9's ReadyGate `:destroying` is REMOVED.** The dispatch fence moves into `Kind.Server.handle_call`/`handle_cast` (B1'' — see §2 + §3.6).
- **r9's `Chat.scrub_owner` cross-Kind dispatch is REPLACED with direct `Repo.update_all`** inside the User's destroy_db transaction (B6' — see §3.5 User destroy_db).
- **r9's "universal `Kind.spawn/2` backing check"** is supplemented with an explicit `WorkerSpawn.spawn/4` check at the external_mirror layer (B2'' — see §4.1 PR-B).
- **r9's workspace advisory lock** is paired with a matching `Workspace.add_member/2` lock + global URI-string ordering for deadlock-free cascade (B7' — see §3.5.x).

Per `feedback_let_it_crash_no_workarounds`, every r10 fix is at the single source of truth (the Kind's own GenServer, the row's own DB write, the function's own entry) rather than at a higher coordination layer (ETS state machine, advisory cache).

0. **Existence precheck.** Call `kind_module.backing_check(target_uri)`. If `false`, return `{:error, :not_found}` — the URI never had a DB row (typo or already-destroyed by a previous separate call). NO mutation. INV-22 gate.
1. **Pre-check.** Call `kind_module.can_destroy?(target_uri, ctx)`. On error → return `{:error, {:precheck_failed, reason}}`; no mutation has occurred.
2. **Generate `trace_id`.** A new UUID; threaded through every audit row.
3. **Repo.transaction — atomic cleanup + DB delete + audit.** Inside the transaction:
   - **3a.** **Advisory lock acquisition (r11 B7''' grounded).** Compute the full set of URIs that step 3b will mutate by calling `kind_module.destroy_db_locks(target_uri, ctx)` — a new Kind callback (r11) that returns the URI list. For a leaf User: `[user_uri | workspaces_containing(user)]` (the workspace mutations are part of remove_member_in_txn). For Workspace: `[workspace_uri | member_uris | template_uris | session_uris]`. For Session/Agent/Worker: typically `[target_uri]`. Sort lexicographically by `URI.to_string/1`. Acquire `Repo.advisory_xact_lock("kind:#{uri_str}")` for each, in sorted order. This guarantees deadlock-free cascade per §3.5.x global lock ordering — every operation that mutates a Kind DB row pre-declares all locks it needs, and acquisition follows the global order.
   - **3b.** `kind_module.destroy_db(target_uri, ctx_with_trace)` — the **DB-write phase** of per-Kind cleanup. INSIDE the transaction. All writes use the SAME Repo connection (transaction-bound; NO cross-process dispatch — r11 B6'' grounds this in the codebase: there is no SessionRow / sessions table, so r10's direct-Repo-update fictitious scrub is REMOVED). For User: revoke caps (`Identity.revoke_all_caps/1`), drop feishu_user_bindings, drop entity_profile, drop workspace memberships (direct `Workspaces.remove_member_in_txn/2` calls — each workspace's lock was acquired in 3a). **Session ownership is in the live `:chat` slice, NOT a DB row — User.destroy_db does NOT scrub session ownership; the read-site DB-backing defense at all three `data_owner/1` sites (Chat / Publisher / ExternalMirror — r11 adds the missing ExternalMirror site) returns `:no_owner` when `Users.get_by_uri/1` is nil.** For Agent: revoke entity_tokens, drop session memberships (no session row mutation — see B6''), scrub mention routing rules. For Workspace: cascade-destroy each member by recursively entering this orchestration (each cascade member's destroy joins the same transaction via Ecto's savepoint nesting; the member's locks were already acquired by the parent's 3a). For Worker: drop external_mirror_bindings. For Session: drop session_members (the Session Kind's `:chat` slice member list — this is in-memory, NOT a DB row; Session.destroy_db has no DB writes here, only the snapshot purge in 3c). Returns `{:ok, db_summary}` or raises (transaction rollback triggered). Per `feedback_let_it_crash_no_workarounds`, raises are NOT caught here — they propagate to the transaction's rollback path.
   - **3c.** `Repo.delete(Ezagent.Ecto.KindSnapshot, uri_str)` — idempotent.
   - **3d.** `kind_module.delete_db_row(target_uri)` — Users.delete / Agents.delete / etc. Returns `{rows_affected, _}`. If `rows_affected == 0`, treat as **idempotent loser** (a concurrent destroy committed first under READ COMMITTED row locking): proceed to 3e tagging `outcome: :already_destroyed`. Step 0's backing_check already ruled out "never existed" — so 0 rows here IS necessarily the race-loser case (INV-19 gate + clean distinction from INV-22's `:not_found`).
   - **3e.** `Repo.insert(InvocationsAudit, %{action: "kind.destroyed", target: target_uri_str, caller: caller_uri_str, args: %{"reason" => reason}, result: %{"outcome" => "ok" | "already_destroyed", "kind_summary" => db_summary, "cascade_outcomes" => [...], "trace_id" => trace_id_str}})`. Inside the transaction. r10 N3: `outcome` nests inside the existing `result jsonb` column — NO schema migration needed. If 3b or 3d raised, this insert never runs (rollback).
4. **Transaction commit OR rollback.**
   - **Commit:** all of step 3 atomic. DB row gone. Snapshot gone. Audit row present. Proceed to step 5.
   - **Rollback:** Repo.transaction returned `{:error, _}`. NONE of step 3 took effect (atomicity). Return `{:error, {:transaction_failed, inner}}`. Operator sees the error and may re-run; re-run is safe because nothing was mutated. No ETS state to revert (r9's revert mechanism is REMOVED in r10).
5. **Locate the live pid.** `KindRegistry.lookup(target_uri)`. Two arms:
   - `{:ok, pid}` — proceed to step 6.
   - `:error` — the Kind isn't currently alive (snapshot-only). Skip step 6; proceed to step 7.
6. **Terminate the GenServer gracefully (with `:destroyed` shutdown reason).** `DynamicSupervisor.terminate_child(kind_module.supervisor(), pid)` would normally use `:shutdown` as the reason and run `Kind.Server.terminate/2`. For `:on_terminate` persistence Kinds, that terminate/2 callback writes a fresh snapshot row — which would resurrect the snapshot just deleted in step 3c. **r11 B8 fix**: the orchestrator FIRST sends a `GenServer.call(pid, :prepare_for_destroy)` (or similar synchronous signal) that sets `state.shutdown_reason = :destroyed`, THEN calls `DynamicSupervisor.terminate_child`. The Kind.Server's `terminate/2` has a NEW arm clause: `def terminate(:destroyed, _state), do: :ok` — explicitly skips the snapshot write. The in-GenServer dispatch fence (B1'') uses `{:stop, :destroyed, state}` for the same reason. (Alternative implementation: store `:destroyed` flag in process dictionary or state and check inside terminate/2's existing body — either works as long as the `:on_terminate` snapshot is unconditionally skipped under destroy-induced shutdown.) NOT `:brutal_kill`. **No respawn race**: at this point the DB row is already gone (step 3d committed). Two fences hold:
   - Spawn path: `Kind.spawn/2` AND `WorkerSpawn.spawn/4` consult `kind_module.backing_check/1` → row absent → return `{:error, :no_backing_entity}`.
   - Dispatch path: in the small window between step 4 commit and step 6 completion, a dispatch may still reach the live tearing-down pid via `KindRegistry.lookup`. The `Kind.Server.handle_call`/`handle_cast` at the receiving end runs `kind_module.backing_check(state.uri)` at the top — sees row absent — replies `{:error, :no_backing_entity}` and self-shuts via `{:stop, :destroyed, state}` (NOT `:normal`, so terminate/2's `:destroyed` arm fires and skips snapshot). The fence is INSIDE the Kind itself; no race. INV-26 gate. (Note: r11 keeps `Invocation.dispatch/1` unchanged from upstream — no ReadyGate `:destroying` arm — the fence is purely at the message-handler layer.)
   Existing in-flight messages already in the pid's mailbox at terminate_child time drain naturally; their handlers each run the backing_check first and reply / drop / shutdown.
7. **Runtime cleanup — `kind_module.destroy_runtime(target_uri, ctx)`.** OUTSIDE the transaction. Best-effort. Per-Kind external-resource release: Agent calls `AgentBridge.Adapter.teardown/1` (cc unbinds BridgeRegistry; codex stops sidecar + app_server + PTY + removes per-agent dir; np stops nested-process state); Worker calls `adapter_module.terminate/1`; Session calls `Publisher.unsubscribe_all/1`. Errors LOGGED, not raised; if this step partially fails, the destroy returns `{:error, {:partial, %{runtime_errors: [...], db_outcome: :ok | :already_destroyed}}}` so the operator knows external resources may have leaked. DB state is irreversibly gone; no compensating action is attempted.
8. **Broadcast.** `Phoenix.PubSub.broadcast({:kind_destroyed, target_uri, reason})` for LV consumers.

**Linearization point** = the Repo.transaction commit (end of step 3 / start of step 4). After commit:
- The URI is destroyed from the perspective of every spawn path (`Kind.spawn/2`'s and `WorkerSpawn.spawn/4`'s backing_check returns false).
- The dispatch path either misses (`KindRegistry.lookup` returns `:error` after step 6) or hits the live pid which immediately rejects + self-shuts (in-GenServer backing_check).
- A concurrent destroy that lost the row-lock race ENTERED step 3 (passed step 0's existence check on the still-existing pre-commit row), then 3d found 0 rows, tagged `:already_destroyed`, and committed its audit row in a separate transaction.

### 3.5 Per-Kind `destroy_db/2` + `destroy_runtime/2` responsibilities (r9 split)

r9 splits per-Kind cleanup into two callbacks per the B6 fix (codex r8 q16):
- `destroy_db/2` — DB-write cleanup, runs INSIDE the orchestrator's `Repo.transaction`; raises on failure (transaction rolls back atomically).
- `destroy_runtime/2` — external resource release, runs OUTSIDE the transaction after step 6's `terminate_child`; best-effort, errors logged not raised.

Each Kind implements both callbacks. The orchestrator (§3.4 step 3b + step 7) is the only place these are invoked.

**User (User.destroy_db/2 — inside transaction; r11 B6'' read-site-defense):**

```
:revoke_all_caps                Identity.revoke_all_caps(user_uri)         [DB write]
:revoke_entity_tokens           Repo.delete_all(EntityToken …)             [DB write]
:drop_feishu_bindings           Repo.delete_all(feishu_user_bindings …)    [DB write]
:drop_entity_profile            Repo.delete(EntityProfile, uri_str)        [DB write]
:drop_workspace_memberships     Enum.each(workspaces, fn ws ->
                                  Workspaces.remove_member_in_txn(ws, user_uri)
                                end)                                       [DB write; each
                                                                            workspace's lock
                                                                            acquired in 3a]
```

**Session ownership is NOT scrubbed in destroy_db** (codex r10 CRITICAL §3.5/§3.7 / r11 B6'' grounded): session ownership lives in the Session Kind's live `:chat` slice (via `Ezagent.Kind.get_slice(uri, :chat)`), NOT a DB row. The r1–r6 design's read-site DB-backing defense handles staleness — when User is destroyed, every `data_owner/1` consumer of the slice's `owner_uri` does `Users.get_by_uri(owner_uri)` and returns `:no_owner` if nil. The three consumer sites:
- `Chat.data_owner/1` — already has the check (preserved from r1–r6).
- `Publisher.SessionImpl.data_owner/1` — already has the check (preserved from r1–r6).
- `ExternalMirror.data_owner/1` — **r11 B6'' ADDS the missing check** (apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:593 currently reads `slice.owner_uri` directly without DB-backing defense). PR-B includes this modification.

No data is lost when User is destroyed: any code that needs to enumerate sessions owned by the destroyed user can do so by iterating live Session Kinds + comparing slice owner_uri + applying the DB-backing check. For operator-runbook awareness, the audit row includes `affected_session_uris` (computed before destroy_db's commit by an opt-in query that the orchestrator's audit step picks up if `:include_affected_sessions` flag in ctx is true).

**User (User.destroy_runtime/2 — outside transaction):** no-op (User has no sidecar / file handle / socket; all User state was DB-resident).

**User.destroy_db_locks/2 (r11 B7''' new callback):**

```elixir
def destroy_db_locks(%URI{} = user_uri, _ctx) do
  # The orchestrator's step 3a acquires these locks (sorted) before step 3b.
  workspaces = Workspaces.list_workspaces_containing(user_uri)
  [user_uri | Enum.map(workspaces, & &1.uri)]
end
```

**On Behavior.Chat.scrub_owner removal (r11 cleanup):** the Behavior action + `system://kind-destroy-cascade` system principal were introduced in r1–r6 as the cross-Kind cleanup path. Under r11's read-site DB-backing defense, scrub_owner is unused by destroy. PR-B may keep the action defined (for non-destroy callers who want event-driven scrubs — e.g. operator manually triggering an owner-handoff) but the `system://kind-destroy-cascade` principal is no longer mounted at boot. Removed from `Ezagent.SystemPrincipal.Catalog` in PR-B.

**Agent (Agent.destroy_db/2 — inside transaction):**

```
:revoke_entity_tokens           Repo.delete_all(EntityToken …)             [DB write]
:drop_session_memberships       Enum.each(sessions, &Chat.leave/2)
:scrub_mention_routing_rules    RoutingRules.remove_by_target(agent_uri)   [DB write]
:revoke_agent_api_keys          AgentApiKeys.revoke_all(agent_uri)         [DB write]
:drop_agent_lineage             AgentLineage.delete(agent_uri)             [DB write]
:delete_workspace_template      Workspace.remove_template/3 (if registered)
```

**Agent (Agent.destroy_runtime/2 — outside transaction):**

```
:teardown_bridge                AgentBridge.Adapter.teardown(agent_uri)
                                — sidecar / per-agent dir / PTY / BridgeRegistry unbind.
                                  Errors LOGGED, not raised.
```

The `:teardown_bridge` step delegates to `AgentBridge.Adapter.teardown/1` — each flavor adapter cleans up its OWN sidecar without Agent's destroy callbacks needing to know cc vs codex vs echo internals. This is plugin isolation applied to the teardown surface. Crucially the bridge teardown is OUTSIDE the transaction — sidecar shutdown can be slow (seconds) and unreliable (external process); blocking the transaction on it would be wrong.

**Session (Session.destroy_db/2 — inside transaction):**

```
:drop_session_members           clear member list (DB write to session row)
```

**Session (Session.destroy_runtime/2 — outside transaction):**

```
:unsubscribe_publisher          Publisher.unsubscribe_all(session_uri)
                                — PubSub state, in-memory only.
```

The `:emit_session_destroyed` PubSub broadcast is hoisted to the orchestrator's step 8 (the universal `{:kind_destroyed, _, _}` broadcast), so Session.destroy_runtime/2 only needs the unsubscribe call.

**Workspace (Workspace.destroy_db/2 — inside transaction; r10 B7' refined):**

Step 3a of the orchestrator acquires the workspace advisory lock + cascade member locks in lexicographic URI order (see §3.5.x). Then:

```
:reread_members_from_db         workspace_row = Workspaces.get_by_uri!(uri)
                                member_uris  = workspace_row.member_uris
                                — read members from DB (consistent point),
                                  NOT from the live slice. Locks already held
                                  via step 3a's global-order acquisition.
:cascade_member_destroys        Enum.each(member_uris, &recursive Kind.Server.destroy)
                                — each cascade joins the same transaction
                                  via Ecto's savepoint nesting. Each member's
                                  lock was acquired in step 3a (alphabetical
                                  order across the entire cascade); no deadlock.
                                  Shared trace_id with the parent destroy.
:cascade_template_destroys      Enum.each(template_uris, &Kind.Server.destroy)
:cascade_session_destroys       Enum.each(workspace_sessions, &Kind.Server.destroy)
:drop_workspace_caps            CapabilityRegistry.drop_workspace(workspace_uri)  [DB write]
```

**Workspace (Workspace.destroy_runtime/2 — outside transaction):** no-op.

**Workspace.add_member/2 — r11 B7'' grounded lock contract (codex r10 HIGH §3.5.x).** r9 said `Workspace.add_member/2` "MUST also acquire the same advisory lock" but the actual code (`apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:103-135`) has NO transaction, NO advisory lock. r10's example used the wrong URI form (`entity://workspace/...`); r11 corrects to the actual canonical form (`workspace://name`, per `Ezagent.Entity.Workspace.uri_for/1` at apps/ezagent_domain_workspace/lib/ezagent/entity/workspace.ex:81). PR-B explicitly modifies `Workspace.add_member/2` using the `Kind.Server.with_locks/2` helper for global ordering:

```elixir
def add_member(name, %URI{} = member_uri) do
  workspace_uri = Ezagent.Entity.Workspace.uri_for(name)   # workspace://name

  Repo.transaction(fn ->
    # r11 B7'' — use Kind.Server.with_locks/2 helper which sorts +
    # acquires per §3.5.x global ordering rule. Pass URI structs;
    # helper canonicalizes via URI.to_string/1.
    Ezagent.Kind.Server.with_locks([workspace_uri, member_uri], fn ->
      case Store.get_by_name(name) do
        nil ->
          Repo.rollback({:error, :no_such_workspace})
        %{members: existing} ->
          new_members = Enum.uniq([member_uri | existing])
          with :ok <- ensure_member_kind_spawned_at_facade(member_uri),
               :ok <- dispatch_mutation(name, "add_member", %{member: member_uri}, :call),
               {:ok, _} <- Store.update_members(name, new_members) do
            :ok
          end
      end
    end)
  end)
end
```

Under this discipline:
- **add_member wins the lock first:** add_member acquires workspace + member locks (sorted order), commits its member-list update, releases. destroy then acquires the same locks, re-reads `member_uris` (now includes the new member), cascades.
- **destroy wins the lock first:** destroy acquires all locks (workspace + all members + the new-to-be-added member's URI is NOT in the workspace yet, so not in destroy's sort list). add_member blocks on the workspace lock. After destroy commits, the workspace row is gone; add_member wakes, reads workspace → nil → returns `{:error, :no_such_workspace}`.

Either way: no member is left alive while its workspace is destroyed. INV-23 pins this.

#### §3.5.x — Global advisory-lock ordering (r10 B7')

To prevent deadlocks in workspace-cascade destroys (codex r9 HIGH §3.5: "the spec still does not define a global advisory-lock order, so overlapping workspace destroys can deadlock via W1→U→W2 and W2→U→W1 style acquisition"), r10 defines:

**Lock keys are URI strings prefixed with `"kind:"`.** Every operation that mutates a Kind's DB row (destroy, add_member, etc.) acquires `Repo.advisory_xact_lock("kind:#{uri_str}")`.

**Acquisition order:** lexicographically sorted URI strings. For an operation that needs multiple locks (e.g. workspace destroy with N members), the operation computes the full list, sorts it, and acquires in sorted order BEFORE any other DB work. The PR-B helper `Ezagent.Kind.Server.with_locks(uris, fn -> ... end)` enforces this:

```elixir
def with_locks(uris, fun) do
  lock_keys = uris |> Enum.map(&"kind:#{URI.to_string(&1)}") |> Enum.sort()
  Enum.each(lock_keys, &Repo.advisory_xact_lock/1)
  fun.()
end
```

This guarantees: concurrent destroys of overlapping workspaces W1={U1,U2} and W2={U2,U3} both compute `["U1","U2","W1"]` and `["U2","U3","W2"]` (sorted). They acquire `U1` and `U2` in the same order. Whichever gets `U2` first wins; the other waits. No circular wait → no deadlock.

**Why this works under Postgres advisory locks:** `pg_advisory_xact_lock` is reentrant within the same transaction (a transaction can acquire the same lock multiple times without blocking itself) AND released on COMMIT/ROLLBACK (no explicit unlock needed). The sorted acquisition is the canonical "global lock order" rule for deadlock prevention.

**Why not row-level locks (`SELECT FOR UPDATE`)?** Postgres row locks would force every read to lock the row, blocking unrelated reads. Advisory locks are explicit, voluntary, and only block other code that opts into the same key — perfect for "destroy is exclusive of add_member" without making every read pay the cost.

**Workspace.can_destroy?/2 — nested workspace refusal (r8 B4 preserved):** Member URI scheme must be `entity://...`. If `Workspace.can_destroy?/2` sees ANY member URI whose scheme starts with `workspace://`, it returns `{:error, :nested_workspace_not_supported}`. Fail-fast; no cycle-detection. The member list for this precheck is read from the live slice (it's a refusal pre-check, not the consistent-point read); under contention, the precheck may miss a nested-workspace member added concurrently, but the consistent-point read inside destroy_db/2 will catch it: `cascade_member_destroys` will recurse into the nested workspace's own `Workspace.destroy/2`, which itself will go through step 1's can_destroy?/2 and refuse → its `Kind.Server.destroy/2` returns `{:error, :nested_workspace_not_supported}` → parent destroy returns `{:error, {:partial, %{cascade_errors: [...]}}}`. Operator sees a clean error, no data corruption.

**Loader / BootReconciler note (r8 N1 — updated for r9):** The Loader and BootReconciler paths that materialize Kinds at boot ALSO go through `Ezagent.Kind.spawn/2` (since SpawnRegistry.spawn/1 itself is a thin wrapper that calls Kind.spawn/2). Therefore the universal `backing_check/1` callback (r9 B2') gates them too. A row deleted via `Kind.Server.destroy/2` is invisible at boot — no cache layer is planned; the DB read on every spawn is acceptable.

**Worker cascade (Worker.destroy/2):**

```
:drop_external_mirror_bindings  Repo.delete_all(BindingRow WHERE worker_uri = worker_uri)
:unsubscribe_session_publisher  Publisher.unsubscribe(worker_uri)
:terminate_adapter              adapter_module.terminate(worker_uri)
```

This requires `external_mirror_bindings.worker_uri` to be a real column (the B5 column add from r1–r2). The column is kept (it's structurally correct — `worker_uri` is a useful denormalized index regardless of tombstone). The two-migration + backfill task from r1–r6 §4.1 + §9.1 is retained as-is; under r7 the column is consumed by Worker.destroy/2 rather than by a cascade Adapter. The BindingRow schema / cast / validate_required updates from CRIT-4.2 are also retained.

### 3.6 Race analysis — concurrent dispatch during destroy (r10: in-GenServer fence + direct cross-Kind writes)

r10 closes the ReadyGate rollback race that codex r9 identified as CRITICAL by moving the dispatch fence INSIDE the Kind.Server GenServer:

- **Spawn path** (Kind creation): `Ezagent.Kind.spawn/2` AND `Ezagent.ExternalMirror.WorkerSpawn.spawn/4` (the r9-missed bypass) both consult `kind_module.backing_check/1` at their entry. r10 makes the check a per-Kind callback on `Ezagent.Kind`, applied at every direct-supervisor-start-child layer (`Kind.spawn` covers SpawnRegistry + chat/workspace/identity/system-principal direct callers; `WorkerSpawn` covers the external_mirror two-tier supervision tree).
- **Dispatch path** (existing Kind communication): `Ezagent.Invocation.dispatch/1` is UNCHANGED from upstream (no `:destroying` arm — r9's mechanism is REMOVED). The fence lives at `Kind.Server.handle_call`/`handle_cast`: every message handler invokes `kind_module.backing_check(state.uri)` at the TOP, replying `:no_backing_entity` and self-shutting via `{:stop, :normal, state}` on false. This is the SINGLE source of truth (the Kind itself) — no race window between an ETS state change and a transactional commit.

Six race windows under the r10 order (step 0 backing precheck → step 1 can_destroy → step 2 trace_id → step 3 transaction[3a locks + 3b destroy_db + 3c snapshot + 3d DB row + 3e audit] → step 4 commit → step 5 lookup → step 6 terminate_child → step 7 destroy_runtime → step 8 broadcast):

1. **Dispatch arriving BEFORE step 0.** Normal dispatch; Kind alive; row exists. Backing_check at the Kind.Server's `handle_call`/`handle_cast` returns true → proceeds normally.
2. **Dispatch arriving BETWEEN step 0 and step 3 (transaction begin).** Existence precheck + can_destroy passed but no mutation. Row still exists. Backing_check at handler still returns true. Dispatch proceeds normally; destroy continues independently.
3. **Dispatch arriving INSIDE step 3, BEFORE transaction COMMIT.** The destroy's transaction holds row-level locks on the per-Kind backing row (e.g. `users(uri)`) from step 3b's first write. The dispatch arrives at the Kind.Server's handler; the handler runs `kind_module.backing_check(uri)`. Under READ COMMITTED isolation, the backing_check's SELECT reads the **pre-transaction state** (the row is still there as far as other connections see) → returns true → dispatch proceeds. The dispatch's effects are on the still-alive Kind's slice — about to be discarded when the orchestrator commits and step 6 terminates the pid. Acceptable: the destroy hasn't committed yet, so the system isn't in a "destroyed" state visible anywhere.
4. **Dispatch arriving DURING the transaction (between 3b / 3c / 3d / 3e).** Same as window 3 — READ COMMITTED hides the in-flight transaction's writes.
5. **Dispatch arriving AFTER transaction commit (step 4) and BEFORE / DURING terminate_child (step 6).** This is the critical window. DB row is GONE; backing_check on a fresh connection returns false. `KindRegistry.lookup` may still return the live tearing-down pid (terminate_child hasn't completed). The dispatch arrives at `Kind.Server.handle_call` / `handle_cast`; the handler runs `kind_module.backing_check(state.uri)` → false → replies `{:error, :no_backing_entity}` (call) or drops (cast) AND self-shuts via `{:stop, :normal, state}`. The fence is INSIDE the Kind itself. No ETS state to revert; no race. INV-26 gate.
6. **Dispatch arriving AFTER step 6 (terminate_child returns).** Steady state. `KindRegistry.lookup` returns `:error`. Dispatch returns `{:error, :no_such_actor}`. Spawn returns `:no_backing_entity`.

**Why r10 has no ReadyGate revert race.** r9 captured prior ReadyGate state at step 3a and restored on rollback. The race: destroy A captures `:ready`, sets `:destroying`, rolls back, restores `:ready`. Concurrent destroy B (same URI) captures `:destroying` at its step 3a (or `:ready` if A captured first); B commits while A is restoring. A's restore can clobber B's `:destroying`. r10 has NO ETS state to capture or restore — the fence lives in the Kind's own message handler, which reads the DB on every message. The DB is the source of truth; no race.

**Why r10 has no orchestrator-crash orphan-`:destroying`.** r9's `:destroying` state could be left stranded if the orchestrator process crashed between Repo.transaction's `{:error, _}` and the revert call. r10 has nothing to revert — Postgres rolls back the row state on connection-close (transaction abort); the Kind's message handler reads the rolled-back row state on the next dispatch and proceeds normally. No external cleanup needed.

#### 3.6.1 Concurrent destroys (idempotency — INV-19, refined for r10)

Two callers race `Kind.Server.destroy(uri)`:
- Both pass step 0 (existence check — row exists in pre-commit state).
- Both pass step 1 (caps + can_destroy?/2).
- Both generate distinct `trace_id`s.
- Both enter step 3 transaction. Both acquire the advisory lock `"kind:#{uri_str}"` (3a) — Postgres serializes them on this lock; one waits.
- **Winner:** 3a acquires lock; 3b destroy_db idempotent (revoking already-revoked caps = no-op); 3c snapshot delete idempotent; 3d returns `{1, _}`; 3e audit insert with `result["outcome"] = "ok"`; commit; lock released. Step 5–8 proceed.
- **Loser:** acquires lock AFTER winner commits; 3b runs (per-Kind cleanup; idempotent over already-empty state); 3d returns `{0, _}` (row gone); step 0's backing_check WAS true at loser's entry (pre-commit read), so this 0-row case IS the concurrent-loser case (NOT the typo case which step 0 already filtered). 3e audit insert with `result["outcome"] = "already_destroyed"`; commit. Returns `{:ok, :already_destroyed}`. Skips step 5–8 (winner already did them; loser must not double-terminate, double-broadcast).
- Single actual DB delete; both audit rows present with distinct trace_ids; one terminate_child call (winner only); one broadcast.

**Distinction from typo'd URI:** the typo case is filtered at step 0 (`backing_check` returns false; return `{:error, :not_found}`). A typo never reaches the transaction. INV-22 pins this distinction (`:not_found` ≠ `:already_destroyed`).

#### 3.6.2 Why r10 is structurally cleaner than r9

r9 fenced the dispatch path with ReadyGate `:destroying` — a NEW ETS state that needed orchestrator-level capture/restore on rollback. The state machine introduced a race (codex r9 CRITICAL §3.6.1): two concurrent destroys could clobber each other's prior-state restores. r10 puts the dispatch fence at the single source of truth (the Kind's own message handler reading the DB) — no ETS state to manage, no rollback restore, no race.

r9 had `User.destroy_db` dispatch `Chat.scrub_owner` to the Session GenServer (cross-process). Codex r9 CRITICAL §3.5/§3.7 caught that Ecto transactions are process-bound — the Session's write was in a different transaction, breaking the atomicity claim. r10 replaces the dispatch with direct `Repo.update_all` inside the User.destroy_db transaction — same Repo connection, same transaction, atomic rollback.

r9 claimed `Kind.spawn/2` was the universal lower-layer, but `WorkerSpawn.spawn/4` bypassed it. Codex r9 HIGH §2/§4.1 caught the bypass. r10 adds the backing_check at WorkerSpawn's entry too; every `DynamicSupervisor.start_child` call site has the gate.

r9's Workspace.add_member contract assumed lock acquisition but the actual code didn't take it. Codex r9 HIGH §3.5 caught the gap + raised the deadlock concern. r10 explicitly modifies add_member + introduces global URI-string lock ordering (§3.5.x).

Per `feedback_let_it_crash_no_workarounds`, every r10 fix is at the single source of truth (the Kind's own GenServer, the row's own DB write, the function's own entry) rather than at a higher coordination layer (ETS state machine, advisory cache, cross-process dispatch).

**Cost vs r1–r6 tombstone:** one DB read per spawn (the per-Kind `backing_check/1` callback) + one DB read per dispatch entering a Kind whose row may have just been deleted (the in-handler `backing_check`). The dispatch-time DB read is bounded: only on the first message after a destroy commit will the handler see false; the self-shutdown removes the pid from `KindRegistry`, so subsequent dispatches short-circuit at `:no_such_actor`. The amortized dispatch overhead approaches zero (the gate fires once per destroyed Kind). The spawn-time gate is one primary-key read per spawn, comparable to existing slice access patterns. No separate table, no ETS mirror, no multi-boundary check, no atomic primitive. The cost is bounded by what already existed.

### 3.7 Cross-Kind dispatch during destroy — system principal

When User.destroy/2 dispatches `Behavior.Chat.invoke(:scrub_owner, ...)` against each owned Session, the dispatch needs CapBAC authorization. The operator's `:destroy` cap on the User Kind does NOT satisfy `Chat:scrub_owner` on a Session Kind. The cascade therefore dispatches as a dedicated narrow system principal `system://kind-destroy-cascade` (carrying ONLY the Chat:scrub_owner cap, per the r1–r6 CRIT-3.1 pattern — preserved verbatim except for naming).

The `Behavior.Chat.invoke(:scrub_owner, ...)` action body, the `:scrub_owner` action registration (5-part Chat behavior plumbing: actions / required_caps / cap_subjects / invoke / interface + `register_chat_behaviors/0`), the `Chat.data_owner/1` read-site nil-owner handling (no tombstone defense now — just falls through to `:no_owner` when `owner_uri == nil` per existing semantics), and the cold-load semantics of `Session.owner/1` ALL inherit the r1–r6 design. The only delta: the read-site SpawnRegistry tombstone defense check is REPLACED with a `Users.get_by_uri(owner)` DB check that returns `:no_owner` if the row is absent. This applies to all three data_owner resolvers (Chat / ExternalMirror / Publisher.SessionImpl) — the CRIT-5.2 lesson is preserved with a different check function.

### 3.8 Edge case — bootstrap admin protection

`entity://user/system/admin` MUST NOT be destroyable. `User.can_destroy?/2` hardcodes this (see §3.3):

```elixir
def can_destroy?(%URI{} = uri, _ctx) do
  if URI.to_string(uri) == URI.to_string(Ezagent.Entity.User.admin_uri()) do
    {:error, :bootstrap_admin_undestroyable}
  else
    :ok
  end
end
```

Other Kinds MAY add similar protected URIs (e.g. system orchestrator agent).

### 3.9 Edge case — operator who destroys themselves

A workspace admin who calls `Kind.Server.destroy(their_own_uri, ctx)` proceeds: the action runs to completion because their caps are evaluated at step 1 BEFORE the User.destroy/2 strips them. The LV intercepts a self-destroy in `users_live.ex` with a confirm-dialog warning ("You are destroying yourself; you will be logged out") but does not block — operator may have a legitimate reason. (OQ-5 — Allen may want a second-admin gate.)

### 3.10 Edge case — re-register after destroy

After `Kind.Server.destroy(uri)` completes, the operator may immediately call `Users.create(uri, ...)`. This:

1. Inserts a fresh `users` row at the same URI (with new password_hash, new initial caps, fresh metadata).
2. The next spawn call (via any path — SpawnRegistry, direct `Kind.spawn/2`, or `WorkerSpawn.spawn/4`): the entry-level backing_check reads the new row → returns true → `DynamicSupervisor.start_child` produces a fresh pid; `KindRegistry.lookup` would return `:error` for the URI right before this call (the old pid was terminated in step 6 of the prior destroy; r10 has no ReadyGate state to purge).
3. The new Kind's `init_slice/1` runs from defaults — there is NO snapshot (step 3c of destroy purged it), no inherited caps (step 3b revoked them), no inherited memberships (step 3b dropped them).
4. The new Kind is structurally distinct from the prior incarnation despite operating at the same URI. The URI is a name, not an identity; the row's primary key is the identity.

This is INV-13 in §5. The r1–r6 design forbade this (tombstones were append-only); Allen's pushback (2026-05-28 03:36) corrected the direction.

### 3.11 Edge case — destroy of a Kind that's not currently alive

If `KindRegistry.lookup(target_uri)` returns `:error` at step 5 (the Kind has no live pid — snapshot-only), step 6 is skipped. The DB writes (step 3) already committed atomically. The runtime cleanup (step 7) still runs (a snapshot-only Kind has no in-memory state, but a snapshot-only Agent's bridge may still be bound externally — `destroy_runtime/2` releases it). This is fine: there's no live pid to terminate, and the post-destroy state is identical.

### 3.12 Edge case — failure modes per phase

r9 splits failure handling into the two phases:

**3.12.a destroy_db/2 (inside transaction) raises or returns error.** The transaction rolls back atomically. The destroy returns `{:error, {:transaction_failed, inner}}`. NO state was mutated — operator may re-run cleanly. This is the path that fixes r8's q16 ghost-user mode: in r8, partial cleanup outside the transaction left the system in "row exists, caps gone" state; in r9+, atomicity guarantees all-or-nothing. r11 has no ETS state to revert (ReadyGate `:destroying` was removed in r10).

**3.12.b destroy_runtime/2 (outside transaction; step 7) raises or returns error.** The DB writes have already committed; the GenServer has been terminated (step 6 with `:destroyed` reason — no snapshot was written). The runtime error is LOGGED. The destroy returns `{:error, {:partial, %{step_failed: :destroy_runtime, runtime_error: <inner>, db_outcome: :ok}}}`. Operator knows external resources may have leaked (e.g. AgentBridge.Adapter.teardown failed because the sidecar was already dead — usually harmless). The DB row + snapshot + audit are durably gone; the URI is no longer reachable from any production code path. Operator-runbook decision: investigate the inner error (e.g. orphan codex sidecar to manually kill) OR accept the partial. Re-running destroy returns `{:error, :not_found}` (step 0 — the row is gone), so the partial cleanup is NOT auto-retriable from within `Kind.Server.destroy/2` — operator must clean up runtime leftovers manually (per `feedback_let_it_crash_no_workarounds`, no auto-compensation).

**3.12.c terminate_child/2 fails (step 6).** Rare — the supervisor may report a timeout if the Kind's `terminate/2` hangs. Logged. Step 7 still runs (the DynamicSupervisor will eventually force-kill via shutdown timeout). The destroy returns `{:error, {:partial, %{step_failed: :terminate_child}}}`.

---

## §4 Migration plan

### 4.1 New code (in order of PRs)

**PR-A (this SPEC).**

**PR-B core — Kind.destroy callback + Kind.Server.destroy/2 + SpawnRegistry DB-backing check + AgentBridge.Adapter.teardown extension:**

- **Modify** `apps/ezagent_core/lib/ezagent/kind.ex` — add `backing_check/1` + `destroy_db/2` + `destroy_runtime/2` + `destroy_db_locks/2` + `can_destroy?/2` + `delete_db_row/1` to `@callback` list. Per OQ-NEW recommendation (a), REQUIRED for all production Kinds; test-support Kinds use `use Ezagent.Kind.TestImpl` which injects default impls (`backing_check/1 → true`, `destroy_db/2 → {:ok, %{}}`, `destroy_runtime/2 → :ok`, `destroy_db_locks/2 → [uri]`). r9 split per B6: `destroy/2` from r8 is REMOVED — superseded by the `destroy_db/2` (inside-transaction) + `destroy_runtime/2` (outside-transaction) pair. r11 B7''' adds `destroy_db_locks/2` for the orchestrator's pre-transaction lock acquisition.
- **Modify** `apps/ezagent_core/lib/ezagent/kind.ex:293` — modify `Ezagent.Kind.spawn/2` to call `kind_module.backing_check(uri)` BEFORE `DynamicSupervisor.start_child` (or the custom strategy). Returns `{:error, :no_backing_entity}` on false. This is the **universal fence** — covers SpawnRegistry callers AND direct Kind.spawn callers (chat session creation, workspace spawn, system principal ensure, identity demand-spawn). Closes r8 B2 hole.
- **Modify** `apps/ezagent_core/lib/ezagent/kind/server.ex` — (a) add public `destroy/2` API per §2 + §3.4 (r11 ordering: step 0 backing check → 1 can_destroy → 2 trace_id → 3 atomic transaction[3a destroy_db_locks + global-order advisory locks + 3b destroy_db + 3c snapshot + 3d DB row + 3e audit] → 5 lookup → 6 terminate_child with `:destroyed` reason → 7 destroy_runtime → 8 broadcast). Wrap step 3 in `Repo.transaction/1`. (b) **r10 B1''** — add the in-GenServer dispatch fence: `Kind.Server.handle_call/3` and `handle_cast/2` invoke `kind_module.backing_check(state.uri)` at the top of every message; on false, reply `{:error, :no_backing_entity}` and `{:stop, :destroyed, state}` (NOT `:normal` — terminate/2's `:destroyed` arm skips snapshot, r11 B8). (c) **r10 B7'** — add `Ezagent.Kind.Server.with_locks/2` helper that sorts URIs (via `URI.to_string/1`) and acquires `Repo.advisory_xact_lock("kind:#{uri_str}")` in order. (d) **r11 B8** — modify `Kind.Server.terminate/2`: add `def terminate(:destroyed, _state), do: :ok` clause BEFORE the existing body. This skips the `:on_terminate` snapshot persistence that would otherwise resurrect the just-deleted snapshot row. The orchestrator's step 6 signals destroy-induced shutdown by passing `:destroyed` as the GenServer stop reason — modifying `DynamicSupervisor.terminate_child` to use a custom reason is not directly supported (it always uses `:shutdown`); the orchestrator instead does `GenServer.stop(pid, :destroyed)` which triggers terminate/2 with `:destroyed`.
- **r9 changes REVERTED in r10:**
  - `apps/ezagent_core/lib/ezagent/ready_gate.ex` `:destroying` state — REMOVED. r10 has no dispatch-fence state in ReadyGate; the existing 3 states (`:unknown` / `:not_ready` / `:ready`) are unchanged.
  - `apps/ezagent_core/lib/ezagent/invocation.ex:87` `{:destroying, _}` arm — REMOVED. r10 fences dispatch INSIDE Kind.Server's message handlers, not in `Invocation.dispatch/1`.
- **Modify** `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:593` — **r11 B6'' ADDS** the missing read-site DB-backing defense at `data_owner/1`. Currently reads `slice.owner_uri` directly without the `Users.get_by_uri/1` check. r11 modifies to:
  ```elixir
  def data_owner(%URI{scheme: "session"} = session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :chat) do
      {:ok, %{owner_uri: %URI{} = owner_uri}} ->
        # r11 B6'' — DB-backing defense, parity with Chat / Publisher data_owner sites.
        if Ezagent.Users.get_by_uri(owner_uri) != nil do
          Ezagent.URI.instance(owner_uri)
        else
          :no_owner
        end
      _ -> :no_owner
    end
  end
  ```
  This completes the three-site read-defense pattern (Chat, Publisher, ExternalMirror — all do the DB-backing check before returning the slice's owner_uri).
- **Modify** `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/worker_spawn.ex:72-85` — **r10 B2''** — add `if Worker.backing_check(worker_uri), do: continue, else: {:error, :no_backing_entity}` at the top of `spawn/4`, BEFORE the `DynamicSupervisor.start_child` call on line 112. Closes the codex r9 bypass.
- **Modify** `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:103-135` — **r10 B7'** — wrap `add_member/2` body in `Repo.transaction(fn -> ... end)`; first ops acquire `Repo.advisory_xact_lock("kind:#{workspace_uri_str}")` + `Repo.advisory_xact_lock("kind:#{member_uri_str}")` (per global ordering rule §3.5.x). Also modify `Workspace.remove_member/2` (existing function) similarly.
- **Add `Workspaces.remove_member_in_txn/2`** — a domain-level helper that takes a workspace URI + member URI and issues the appropriate `Workspaces.Store.update_members/2` inside the caller's transaction. Used by `User.destroy_db/2` and `Agent.destroy_db/2` for direct cross-Kind workspace-membership cleanup. **Note:** there is NO equivalent `Sessions.remove_member_in_txn/2` — Session membership lives in the live `:chat` slice (in-memory), not a DB row. Per r11 B6'', stale slice state is handled by the read-site DB-backing defense at all three `data_owner/1` consumers, not by a write.
- **REMOVE from r8 PR-B plan:**
  - `Ezagent.SpawnRegistry.register/3` with `backing_check_fn` keyword — REMOVED. r9 moves the check to `Kind.spawn/2` (universal). SpawnRegistry keeps its existing 2-arity `register/2`.
  - Per-scheme `backing_check_fn` registration in each domain Application — REMOVED. Each Kind now owns its own `backing_check/1` callback.
- **Modify** `apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/adapter.ex` — add `teardown/1` to `@callback`, list under `@optional_callbacks` with default no-op (default impl in the Adapter module itself for fallthrough).
- **Add** `Ezagent.SystemPrincipal.Catalog` entry: `{"system://kind-destroy-cascade", [Capability.cap(Ezagent.Entity.Session, Ezagent.Behavior.Chat, :scrub_owner, :any, :any)]}` (renamed from r1–r6's `system://entity-deletion-cascade`).
- **Modify** `apps/ezagent_core/lib/ezagent_core/application.ex` — add `SystemPrincipal.ensure(SystemPrincipal.uri("kind-destroy-cascade"))` after existing principal ensures.
- **Modify** `apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex` — add `:scrub_owner` action (full 5-part Chat behavior plumbing: actions, required_caps, cap_subjects, invoke, interface). Add `Chat.data_owner/1` change: if the `Session.owner/1` returns `{:ok, owner}` and `Users.get_by_uri(owner) == nil`, return `:no_owner` (replaces r1–r6's tombstone check with DB-backing check).
- **Modify** `apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/application.ex` `register_chat_behaviors/0` — add `CapabilityRegistry.register(Session, :scrub_owner, Chat)`.
- **Modify** `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex` `data_owner/1` — same DB-backing check pattern.
- **Modify** `apps/ezagent_domain_instance_message/lib/ezagent/behavior/publisher/session_impl.ex` `data_owner/1` — same DB-backing check pattern.
- **Modify** `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex` `verify/2` — replace the r1–r6 `SpawnRegistry.tombstoned?(uri)` check with `Users.get_by_uri(uri) == nil` (or per-Kind equivalent — `Agents.get_by_uri/1`). Same defense-in-depth purpose; same `Bcrypt.no_user_verify()` timing-leak handling; new error tag `{:error, :no_backing_entity}`.
- **Migrations** for the `external_mirror_bindings.worker_uri` column (Migration A `null: true` + backfill task `mix ezagent.entity.backfill_worker_uri` + Migration B `NOT NULL`) — preserved verbatim from r1–r6 §4.1; these are independently useful and Worker.destroy/2 still needs the column.
- **Modify** `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/binding_row.ex` — add `:worker_uri` to schema + `@type t` + cast + validate_required (CRIT-4.2 preserved verbatim).
- **Modify** `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex` `:bind` action body — populate `worker_uri` in attrs map (B5 preserved verbatim).
- **REMOVE from prior PR-B plan:**
  - `apps/ezagent_core/lib/ezagent/spawn_registry/tombstone.ex` — never created
  - `apps/ezagent_core/priv/repo/migrations/<timestamp>_entity_tombstones.exs` — never created
  - Three-boundary tombstone enforcement in `Kind.Server.init/1` + `Kind.spawn/2` + `SpawnRegistry.spawn/1` — replaced by the single DB-backing check in each entity callback
  - `Ezagent.SpawnRegistry.tombstone_and_kill/1` + `tombstoned?/1` — replaced by `Kind.Server.destroy/2`'s graceful `terminate_child/2` + DB row delete
  - `Ezagent.Behavior.EntityDeletion` + `EntityDeletion.Adapter` + `EntityDeletion.AdapterRegistry` — replaced by `Kind.destroy/2` callback on `Ezagent.Kind` + per-Kind impls
- Tests: §5 invariant test + per-Kind destroy unit tests + DB-backing-check unit test on each entity callback + AgentBridge.Adapter.teardown unit test + Chat.scrub_owner unit test + data_owner DB-backing-check tests at all three sites + Token.verify DB-backing-check test.

**PR-C domain Kinds — per-Kind `backing_check/1` + `destroy_db/2` + `destroy_runtime/2` impls (B5 FULL inventory from grep `@behaviour Ezagent.Kind` in lib/; r9 split per B6):**

Each Kind below implements FOUR callbacks (per r9):
- `backing_check(uri) :: boolean()` — existence test (DB query) for the universal Kind.spawn/2 fence
- `destroy_db(uri, ctx) :: {:ok, summary} | raises` — DB-write cleanup, runs INSIDE orchestrator transaction
- `destroy_runtime(uri, ctx) :: :ok | {:error, _}` — external resource release, runs OUTSIDE transaction
- `can_destroy?(uri, ctx) :: :ok | {:error, reason}` — operator-policy precheck (unchanged from r8)

Production Kinds (`@behaviour Ezagent.Kind`):

- `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex` — `destroy/2` (User cascade per §3.5) + `can_destroy?/2` (bootstrap admin protection) + `delete_db_row/1` → `Users.delete/1`.
- `apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex` — `destroy/2` (Agent cascade per §3.5; delegates to `AgentBridge.Adapter.teardown/1`) + `can_destroy?/2`.
- `apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex` — `destroy/2` (Session cascade per §3.5) + `can_destroy?/2`.
- `apps/ezagent_domain_instance_message/lib/ezagent/entity/agent_template.ex` — `destroy/2` cascades to all agents instantiated from this template (`Agents.list_by_template/1` + each `Kind.Server.destroy(agent_uri, ctx_with_parent_trace)`) + `can_destroy?/2` refuses templates with active in-flight sessions. **NEW for r8 — codex r7 caught this gap.**
- `apps/ezagent_domain_instance_message/lib/ezagent/entity/session_template.ex` — `destroy/2` cascades to sessions instantiated from this template + `can_destroy?/2`. **NEW for r8.**
- `apps/ezagent_domain_workspace/lib/ezagent/entity/workspace.ex` — `destroy/2` (Workspace cascade per §3.5; recurses via `Kind.Server.destroy/2`) + `can_destroy?/2` (B4 — rejects nested workspace members).
- `apps/ezagent_domain_external_mirror/lib/ezagent/entity/external_mirror_worker.ex` — `destroy/2` (Worker cascade per §3.5; uses `worker_uri` column) + `can_destroy?/2`.
- `apps/ezagent_core/lib/ezagent/entity/system.ex` — System Kind (system principal carrier). `destroy/2` returns `{:ok, %{steps: []}}` (no per-Kind state) + `can_destroy?/2` returns `{:error, :system_principal_undestroyable}` for ALL bootstrap system URIs. **NEW for r8 — codex r7 caught this.**
- `apps/ezagent_plugin_echo/lib/ezagent/entity/echo.ex` — `destroy/2` no-op (echo is stateless) + `can_destroy?/2` `:ok`. **NEW for r8.**
- `apps/ezagent_plugin_curl_agent/lib/ezagent/entity/curl_agent.ex` — `destroy/2` releases any in-flight curl handles + `can_destroy?/2` `:ok`. **NEW for r8.**
- `apps/ezagent_plugin_np/lib/ezagent/entity/np_agent.ex` — `destroy/2` stops nested-process state (parallel to bridge teardown) + `can_destroy?/2` `:ok`. **NEW for r8.**

Production Templates (`@behaviour Ezagent.Kind.Template` — these are template Kinds, deletable as their own URI):

- `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` — `destroy/2` cascades to cc agents using this template + `can_destroy?/2`. **NEW for r8.**
- `apps/ezagent_plugin_codex/lib/ezagent/template/codex_agent.ex` — `destroy/2` cascades to codex agents + `can_destroy?/2`. **NEW for r8.**
- `apps/ezagent_plugin_echo/lib/ezagent/template/echo_agent.ex` — `destroy/2` cascades + `can_destroy?/2`. **NEW for r8.**
- `apps/ezagent_plugin_curl_agent/lib/ezagent/template/curl_agent.ex` — `destroy/2` cascades + `can_destroy?/2`. **NEW for r8.**
- `apps/ezagent_plugin_np/lib/ezagent/template/np_agent.ex` — `destroy/2` cascades + `can_destroy?/2`. **NEW for r8.**
- `apps/ezagent_domain_instance_message/lib/ezagent/template/generic_session.ex` — `destroy/2` cascades to sessions using this template + `can_destroy?/2`. **NEW for r8.**

Test-support Kinds (`apps/ezagent_core/test/support/test_behavior.ex`, `post_init_test_behaviors.ex`, etc.) use `Kind.default_destroy/2` macro (no-op) — they exist only inside test runs and have no production lifecycle. The macro lives in `Ezagent.Kind.TestImpl` (new helper module added in PR-B).

**PR-D plugin bridge teardown impls (each plugin adds `teardown/1` to its `AgentBridge.Adapter` impl):**

- `apps/ezagent_plugin_cc/...` — `teardown/1` calls `BridgeRegistry.unbind(agent_uri)`.
- `apps/ezagent_plugin_codex/...` — `teardown/1` stops sidecar + app_server + PTY + removes per-agent dir.
- `apps/ezagent_plugin_echo/...` — `teardown/1` no-op (no external state).
- `apps/ezagent_plugin_curl_agent/...` — `teardown/1` no-op.
- `apps/ezagent_plugin_np/...` — `teardown/1` stops nested-process state.

**PR-E admin LV destroy UI + CLI:**

- Modify `users_live.ex` — add destroy button + confirm dialog + reason input + type-the-URI confirmation (OQ-9 default).
- Modify `identities_live.ex` — per-row destroy action.
- Modify `agent_detail_live.ex` — destroy action in agent detail page.
- Modify `workspaces_live.ex` — destroy workspace (NOW IN SCOPE under r7 — see §3.5 Workspace cascade).
- Add `mix ezagent.kind.destroy <uri> --reason "<reason>"` CLI task.

### 4.2 Backwards compatibility

NO existing code path is removed. NO change to `Users.delete/1` (or per-Kind equivalent) semantics — those paths still exist as the LOW-LEVEL DB-only delete, BUT will emit a deprecation warning suggesting `Kind.Server.destroy/2` instead. Migration target: in a follow-up PR (post PR-E), mark each `XXX.delete/1` as `@deprecated` and route operator-facing call sites through `Kind.Server.destroy/2`.

Existing Kinds that DO NOT implement the new `destroy/2` callback: per OQ-NEW recommendation (a) — REQUIRED for ALL production Kinds + Templates. PR-C adds `destroy/2` to all 11 production Kinds (User, Agent, Session, AgentTemplate, SessionTemplate, Workspace, ExternalMirrorWorker, System, Echo, CurlAgent, NpAgent) + 6 production Templates (CcAgent, CodexAgent, EchoAgent, CurlAgent, GenericSession, NpAgent template). Test-support Kinds use the `Kind.default_destroy/2` macro (no-op) via `use Ezagent.Kind.TestImpl`. New plugin Kinds added post-PR-B must implement `destroy/2` as part of the behaviour contract.

### 4.3 DB migration for production data

`external_mirror_bindings.worker_uri` column add (forward-only) + backfill task + NOT NULL toggle — preserved verbatim from r1–r6. No NEW tables (the `entity_tombstones` table from r1–r6 is REMOVED from the migration plan). Operator-runnable migrations; the NOT NULL toggle is flagged for operator action (stop phx, migrate, restart) on production-shaped environments.

### 4.4 Coordinated PR sequence

PR-A (this SPEC) lands first. PR-B (core) is the **smallest viable shippable** — adds the contract + SpawnRegistry 3-arity + AgentBridge.Adapter.teardown extension. PR-C (per-Kind destroy impls) lands next as a SINGLE atomic addition spanning 17 production Kind/Template modules (per B5 full inventory). PR-C cannot land before PR-B because the callback doesn't exist yet. PR-D (plugin teardown for bridge flavors) can land in parallel with PR-C (different files; PR-D is about `AgentBridge.Adapter.teardown/1`, not `Kind.destroy/2`). PR-E (LV UI + CLI) lands last; depends on PR-C being complete because the LV "destroy" button must call `Kind.Server.destroy/2` which dispatches into per-Kind `destroy/2`.

The plugin-isolation north-star is preserved: PR-B adds the contract; PR-C/D/E plug into it. Future Kinds add `destroy/2` without touching core; future bridge flavors add `teardown/1` without touching core.

---

## §5 Invariant test — the merge gate

Per `feedback_completion_requires_invariant_test`, this SPEC is "done" iff the test below passes AND would fail if any partial impl is shipped.

**File:** `apps/ezagent_core/test/invariants/kind_lifecycle_invariant_test.exs` (renamed from r1–r6's `entity_deletion_invariant_test.exs`).

**Setup** (DataCase, `async: false`):

1. Create a non-admin User: `entity://user/team-alpha/test-destroyable` via `Users.create/3`.
2. Grant caps + add to workspace + bind Feishu open_id + mint a token via `Token.create/2`.
3. Create a Session whose `owner_uri = target` (so Session.owner_uri scrub path is exercised).
4. Spawn the User Kind: `SpawnRegistry.spawn(target)` → `{:ok, pid}`.
5. Call `Kind.Server.destroy(target, %{caller: admin_uri, reason: "test"})`.

**Assertions** (the test fails if ANY is violated):

| # | Assertion | What it catches |
|---|---|---|
| INV-1 | `KindRegistry.lookup(target)` returns `:error` after destroy | Kind not terminated → ghost route alive |
| INV-2 | `SpawnRegistry.spawn(target)` returns `{:error, :no_backing_entity}` | DB-backing check missing or wired wrong |
| INV-3 | `Users.get_by_uri(target)` returns `nil` | DB row delete missing |
| INV-4 | `Repo.get(EntityProfile, target_uri_str)` returns `nil` | Profile leak (User.destroy didn't drop it) |
| INV-5 | `Repo.get(KindSnapshot, target_uri_str)` returns `nil` | Snapshot purge missing → resurrection on row re-creation |
| INV-6 | `Repo.all(from f in feishu_user_bindings, where: f.user_uri == ^target_uri_str)` returns `[]` | Feishu binding scrub missing |
| INV-7 | For every workspace W where target was a member: `target NOT IN W.member_uris` | Membership scrub missing |
| INV-8 | For every session S where target was a member: `target NOT IN S.members` | Session membership scrub missing |
| INV-9 | `Workspace.list_workspaces_for(target, ...)` raises or returns `[]` | Visibility leak (caps not revoked) |
| INV-10 | An audit row exists: `invocations` with `action = "kind.destroyed"`, `target = target_uri_str`, `caller = admin_uri_str`, AND every per-Kind destroy sub-step has a sub-row with the SAME `trace_id` | Audit trail incomplete or trace correlation broken |
| INV-11 | Kill the BEAM (simulate restart via `Application.stop(:ezagent_core) + Application.start(:ezagent_core)`). After restart: INV-1 + INV-2 + INV-3 still hold. No tombstone table consultation needed; DB row absence is sufficient. | DB row delete persistence failed |
| INV-12 | `Kind.Server.destroy(Ezagent.Entity.User.admin_uri(), ...)` returns `{:error, {:precheck_failed, :bootstrap_admin_undestroyable}}` | Bootstrap admin protection missing |
| INV-13 | **(NEW — Allen's pushback)** After destroy completes, call `Users.create(target, %{password: "fresh", ...})` (re-register at the same URI). Assert: (a) `Users.get_by_uri(target)` returns a new row with the new password_hash + new metadata; (b) `SpawnRegistry.spawn(target)` returns `{:ok, fresh_pid}` (NOT `:no_backing_entity`); (c) `:identity` slice of `fresh_pid` has the bootstrap caps for a new user, NOT the destroyed user's prior caps; (d) `:chat` slice (or whichever Behavior carries memberships) shows ZERO prior memberships; (e) `Repo.get(KindSnapshot, target_uri_str)` is fresh, not the destroyed Kind's prior snapshot. | Re-register works AND no inherited state — the core architectural goal of the r7 pivot |
| INV-14 | **(NEW — Workspace cross-Kind cascade)** Create a workspace `entity://workspace/team-beta` with 3 members (U1, U2, U3). Call `Kind.Server.destroy(workspace_uri, ...)`. Assert: (a) `Workspaces.get_by_uri(workspace_uri)` returns `nil`; (b) `Users.get_by_uri(U1)` etc. return `nil` (cascade destroyed members too); (c) the audit emits ONE parent row `action = "kind.destroyed"` for workspace_uri + 3 child rows for U1/U2/U3 sharing the parent's `trace_id`. | Workspace.destroy doesn't cascade to members — the case r1–r6 excluded from scope |
| INV-15 | For a token minted in setup for target: `Token.verify(plain_token, target)` returns `{:error, :no_backing_entity}` (NOT `{:error, :invalid_credentials}` AND NOT `{:ok, _}`). The DB-backing check fires BEFORE bcrypt comparison; `Bcrypt.no_user_verify()` is invoked to defeat timing leaks. | Token defense-in-depth missing or placed after bcrypt |
| INV-16 | **(replaces r1–r6 INV-13b)** Cold-load a snapshotted Session whose `:chat` slice has `owner_uri = target` AFTER destroy. Call ALL THREE production data-owner resolvers and assert each returns `:no_owner` (NOT the destroyed target URI): (1) `Behavior.Chat.data_owner(S_uri)`; (2) `Behavior.ExternalMirror.data_owner(S_uri)`; (3) `Behavior.Publisher.SessionImpl.data_owner(S_uri)`. Each applies the `Users.get_by_uri/1` DB-backing defense at the read site. | Cold-Session privilege disclosure across all data_owner resolvers |
| INV-17 | After PR-B + backfill task + Migration B: every row in `external_mirror_bindings` has non-NULL `worker_uri` matching `WorkerSpawn.worker_uri_for(parsed_session_uri, adapter_id, target_id) |> URI.to_string()`. | Backfill incorrect (preserved verbatim from r1–r6 INV-15) |
| INV-18 | **(Agent bridge teardown)** Spawn an Agent + bind its bridge via the cc flavor adapter. Call `Kind.Server.destroy(agent_uri, ...)`. Assert: `BridgeRegistry.lookup(agent_uri)` returns `:error` (cc's `teardown/1` unbinds). For a codex Agent: assert the sidecar process has exited + the per-agent dir is removed. | AgentBridge.Adapter.teardown/1 not wired or not invoked from Agent.destroy/2 |
| INV-19 | **(NEW r8 — B3 concurrent-destroy idempotency; r10 N3 result-shape)** Two `Task.async` calls to `Kind.Server.destroy(target, ctx_a)` + `Kind.Server.destroy(target, ctx_b)` on the SAME `target_uri`. Wait for both. Assert: (a) exactly ONE returns `{:ok, %{...full summary...}}`; (b) exactly ONE returns `{:ok, :already_destroyed}`; (c) `Users.get_by_uri(target)` returns `nil` (single delete); (d) TWO audit rows present in `invocations`, both with `action = "kind.destroyed"`, target = target_uri_str, with DISTINCT `trace_id`s (in `result["trace_id"]`), and **`result["outcome"]`** fields `"ok"` + `"already_destroyed"` respectively (r10: nested in result jsonb, not a top-level outcome column). | Race produces double-delete error, duplicate audit, OR one caller sees `{:error, _}` instead of the idempotent success tag, OR the SPEC's audit shape doesn't match the actual invocations table schema |
| INV-20 | **(NEW r8 — B2 spawn-race-after-DB-delete)** Spawn target Kind → `{:ok, pid_old}`. In test process: (1) MANUALLY call `Users.delete(target)` to delete the DB row WITHOUT calling `Kind.Server.destroy` (simulates the race window where `terminate_child` hasn't run yet — `pid_old` is still alive). (2) Call `SpawnRegistry.spawn(target)`. Assert: returns `{:error, :no_backing_entity}` — NOT `{:ok, pid_old}` (which would happen if `KindRegistry.lookup` fired before the backing check). | `SpawnRegistry.spawn/1` consulted `KindRegistry.lookup` before `backing_check_fn` — B2 reordering wired wrong |
| INV-21 | **(NEW r8 — B2 backing_check ordering verification, updated r9 for Kind.spawn placement)** Replace `Ezagent.KindRegistry` with a test-double that increments a counter on `lookup/1`. Call `Ezagent.Kind.spawn(SomeKind, %{uri: uri_with_deleted_row})`. Assert: (a) result is `{:error, :no_backing_entity}`; (b) `DynamicSupervisor.start_child` was NOT invoked (assert via supervisor inspection / mock); (c) `kind_module.backing_check/1` was invoked exactly once. Then call `Ezagent.Kind.spawn(SomeKind, %{uri: uri_with_existing_row})`. Assert: (a) result is `{:ok, pid}`; (b) `start_child` invoked. | `backing_check/1` is placed AFTER `start_child` (would let zombie spawns happen) OR is missing from the Kind contract |
| INV-22 | **(NEW r9 — B3' typo-vs-race distinction)** Call `Kind.Server.destroy(uri, ctx)` where `uri = "entity://user/typo/no_such_user"` and `Users.get_by_uri(uri) == nil` (never existed). Assert: (a) result is `{:error, :not_found}` (NOT `{:ok, :already_destroyed}`, NOT `{:error, :precheck_failed}`); (b) NO audit row inserted; (c) NO ReadyGate state change. Then call `Kind.Server.destroy(uri, ctx)` twice serially on a URI that DID exist for the first call (returns `{:ok, %{...}}`) and is gone for the second call. Assert: second call returns `{:error, :not_found}` (NOT `{:ok, :already_destroyed}` — the loser-of-race tag is reserved for genuine concurrent destroys). | Step 0 existence precheck missing; typo'd URIs masquerade as `:already_destroyed` |
| INV-23 | **(NEW r9 — B7 workspace cascade slice freeze)** Spawn a workspace `entity://workspace/team-beta` with 2 initial members (U1, U2). In two parallel tasks: Task A calls `Kind.Server.destroy(workspace_uri, ctx)`; Task B calls `Workspace.add_member(workspace_uri, U3)` (with a small `:timer.sleep` so the timing is interleaved). Run the test 100 iterations. Across all iterations, assert one of two outcomes always holds: (i) workspace destroyed before add_member committed → `Workspaces.get_by_uri(workspace_uri) == nil` AND U1/U2 destroyed AND `Workspace.add_member` returned `{:error, :no_such_workspace}` AND U3's User Kind is NOT destroyed (was never added); OR (ii) add_member committed before destroy's lock acquisition → `Users.get_by_uri(U3) == nil` (U3 destroyed in cascade) AND `Workspaces.get_by_uri(workspace_uri) == nil`. The forbidden state is: U3 added AND workspace destroyed AND U3 NOT destroyed. | Workspace.destroy_db/2 missing the advisory_xact_lock + member re-read; concurrent add_member can race past the precheck |
| INV-24 | **(NEW r9; r10 RE-ARCHITECTED — in-GenServer dispatch fence)** Spawn target Kind → `{:ok, pid}`. Manually `Users.delete(target)` to delete the DB row WITHOUT calling `Kind.Server.destroy` (simulates the race window where step 4 committed but step 6 terminate_child has not yet run; pid still alive). Then call `GenServer.call(pid, {:dispatch, %Invocation{target: target, mode: :call, ...}})` directly. Assert: (a) the call returns `{:error, :no_backing_entity}` (NOT `:ok`, NOT a normal dispatch result); (b) within 200ms, `Process.alive?(pid)` returns false (the Kind.Server's `handle_call` self-shut via `{:stop, :normal, state}`); (c) `KindRegistry.lookup(target_uri)` returns `:error`. Verifies the in-GenServer backing_check fence at the message-handler entry. | `Kind.Server.handle_call`/`handle_cast` missing the top-of-handler `backing_check` invocation; live tearing-down pid processes the dispatch as normal |
| INV-25 | **(NEW r10 — B2'' WorkerSpawn fence)** Create an external_mirror binding row in the DB; manually `Repo.delete` the binding row WITHOUT calling `Worker.destroy/2`. Then call `Ezagent.ExternalMirror.WorkerSpawn.spawn(session_uri, adapter_id, target_id, opts)` for the URI that the deleted binding's `worker_uri_for/3` would derive. Assert: (a) result is `{:error, :no_backing_entity}` (NOT `{:ok, _}`, NOT a `DynamicSupervisor` error); (b) `DynamicSupervisor.start_child` was NOT invoked (test-double counter = 0). | WorkerSpawn.spawn/4 missing the entry-level `Worker.backing_check/1` invocation; codex r9 bypass not closed |
| INV-26 | **(NEW r10 — B7' Workspace.add_member lock contract)** Workspace `W` with no members. In two parallel tasks: Task A calls `Kind.Server.destroy(W, ctx)`; Task B calls `Workspace.add_member(W_name, U_new)`. Run 100 iterations with random small sleeps. Assert across all iterations one of two outcomes: (i) add_member returned `{:error, :no_such_workspace}` AND `Workspaces.get_by_uri(W) == nil` AND `Users.get_by_uri(U_new)` returns the ORIGINAL user (was never cascaded into); OR (ii) add_member returned `:ok` AND `Workspaces.get_by_uri(W) == nil` AND `Users.get_by_uri(U_new) == nil` (cascaded out). The forbidden states: (a) U_new was added AND W destroyed AND U_new still alive; (b) U_new partially added (e.g. in members list but no caps granted) AND W destroyed. | `Workspace.add_member/2` missing `Repo.advisory_xact_lock` acquisition; concurrent add slips past destroy's precheck window |
| INV-27 | **(NEW r11 — B8 terminate-time snapshot suppression)** Use an `:on_terminate` persistence Kind (e.g. a test fixture Kind that returns `:on_terminate` from `persistence/0`). Spawn it → some slice state. Confirm `Repo.get(KindSnapshot, uri_str) == nil` initially (no snapshot yet). Call `Kind.Server.destroy(uri, ctx)`. Assert: after destroy returns, `Repo.get(KindSnapshot, uri_str)` returns `nil` (NOT a non-nil row). Then separately: spawn the Kind again (re-register a fresh row first), and SEND a dispatch directly via `GenServer.call(pid, {:dispatch, inv})` AFTER manually `Users.delete(row)` — verifies the in-GenServer fence path. Assert: (a) the call returns `:no_backing_entity`; (b) `Repo.get(KindSnapshot, uri_str)` returns `nil` (the self-shutdown via `{:stop, :destroyed, state}` also skipped snapshot — terminate(:destroyed, _) arm). | `Kind.Server.terminate/2` missing the `:destroyed` arm — the existing `:on_terminate` snapshot write would re-create the just-deleted snapshot row, leaving a ghost snapshot AND the live Kind seeing fresh defaults on next re-spawn. |

**Cannot pass with partial impl** — failure mappings:

- Skip `Kind.destroy_db/2` callback addition: INV-3 + INV-4 + INV-6 + INV-7 + INV-8 fail (per-Kind DB cleanup never runs)
- Skip `Kind.destroy_runtime/2` callback addition: INV-18 fails (bridge teardown never runs)
- Skip `backing_check/1` callback at `Kind.spawn/2`: INV-2 + INV-13 (c) + INV-20 + INV-21 fail
- Skip `backing_check/1` at `WorkerSpawn.spawn/4`: INV-25 fails
- Skip step 0 existence precheck in orchestrator: INV-22 fails (typo'd URIs masquerade as success)
- Skip in-GenServer dispatch fence (Kind.Server.handle_call/handle_cast top-of-handler backing_check): INV-24 fails (live tearing-down pid processes dispatch)
- Skip Workspace.destroy_db/2 advisory_xact_lock acquisition: INV-23 fails
- Skip Workspace.add_member/2 advisory_xact_lock acquisition: INV-26 fails
- Skip global URI-string lock ordering (§3.5.x): cascade destroys with overlapping members may deadlock — caught by integration test under load (no specific INV; documented as PR-B Credo lint rule)
- Use cross-Kind Behavior dispatch (Chat.scrub_owner) instead of read-site DB-backing defense (r11 B6''): no INV directly catches this for Chat/Publisher (the existing r1–r6 defense is already wired); for ExternalMirror, INV-16 fails because ExternalMirror.data_owner doesn't apply the defense by default — r11's PR-B fix is required.
- Skip the `Kind.Server.terminate(:destroyed, _)` arm: INV-27 fails (snapshot row resurrected after destroy)
- Skip `destroy_db_locks/2` callback: workspace destroys + user destroys that mutate workspaces deadlock under contention — caught by INV-23 + INV-26 under stress runs (no specific INV but the lock-ordering rule is violated)
- Skip `Kind.Server.destroy/2` orchestrator: INV-1 + INV-10 fail
- Skip Workspace.destroy_db/2 cascade: INV-14 fails
- Skip Token.verify DB-backing check: INV-15 fails
- Skip data_owner DB-backing check at any of three sites: INV-16 fails
- Skip bootstrap protection: INV-12 fails
- Skip `{:ok, :already_destroyed}` idempotency return: INV-19 fails
- Use a separate `outcome` column instead of `result["outcome"]`: INV-19 fails (the migration would need to add a column; r10 N3 nests in existing jsonb)
- Place caps revocation OUTSIDE the transaction (r8 ghost-user mode): operator-visible ghost state on 3d failure — caught by §3.12.a contract review
- Use single `destroy/2` callback without DB/runtime split: 3d failure leaves caps revoked (regression to r8 q16 bug)

The test fails on the FIRST mismatch, with a message identifying the leak.

---

## §6 Plugin isolation analysis

Per `feedback_north_star_plugin_isolation`:

| Layer | Knows about | Does NOT know about |
|---|---|---|
| `ezagent_core` | `Ezagent.Kind.destroy/2` callback, `Ezagent.Kind.Server.destroy/2` public API, the orchestration sequence | how User cleans up Feishu bindings, how Agent terminates a sidecar, how Workspace cascades to members |
| `ezagent_domain_identity` | `User.destroy/2` (User cleanup), `User.can_destroy?/2` (bootstrap admin), the DB-backing check at the `user ->` arm of its entity callback | Agent / Session / Workspace / Worker internals |
| `ezagent_domain_instance_message` | `Agent.destroy/2` + `Session.destroy/2` + the `:scrub_owner` Chat action body; the DB-backing check at its `entity` callback's arms | User / Workspace / Worker internals |
| `ezagent_domain_workspace` | `Workspace.destroy/2` cascading to members via `Kind.Server.destroy/2` | per-member internals (each member is itself a Kind whose `destroy/2` does its own cleanup) |
| `ezagent_domain_external_mirror` | `Worker.destroy/2` using `worker_uri` column | User / Agent / Session / Workspace internals |
| `ezagent_domain_agent_bridge` | `AgentBridge.Adapter.teardown/1` callback contract (default no-op) | how cc unbinds, how codex stops sidecar |
| `ezagent_plugin_cc` / `codex` / `np` / `echo` / `curl_agent` | how to tear down ITS sidecar (via `teardown/1`) | how OTHER flavors tear down |
| `ezagent_plugin_liveview` | how to render a "Destroy" button + confirm dialog + call `Kind.Server.destroy/2` | per-Kind cleanup semantics |

A future plugin author adding a new Kind: implements `Ezagent.Kind` behaviour including `destroy/2`. **Zero changes to `ezagent_core`** required.

A future plugin author adding a new bridge-backed flavor: implements `AgentBridge.Adapter` behaviour including `teardown/1`. **Zero changes to `ezagent_core` or `ezagent_domain_agent_bridge`** required.

Generic destroy orchestration lives in `Kind.Server.destroy/2`. Plugin authors never touch it — they implement the callback, not the orchestrator.

Tiebreaker test ("keeps plugin authors out of core"): does `Kind.Server.destroy/2` expose internal state to plugin code? Answer: NO. The orchestrator calls `kind_module.destroy(uri, ctx)` and gets back `{:ok, summary} | {:error, reason}`. The plugin's per-Kind impl never sees other Kinds' destroy paths, never touches the SpawnRegistry entity callbacks directly (those are in the domain Application's `start/2`), never calls `terminate_child/2` itself. ✅

---

## §7 Trade-offs / alternatives considered

### 7.1 "Tombstone + permanent-deny re-register" (r1–r6 — rejected in r7 per Allen 2026-05-28 03:36)

The r1–r6 design installed an append-only `entity_tombstones` table + ETS mirror + multi-boundary check at three spawn paths. After destroy, the URI was PERMANENTLY un-respawnable. Allen's pushback: "tombstone 永久不允许 re-register 很奇怪——重走创建流程就该可以" — making the URI permanently dead even when an operator wants to re-create at the same address is operator-hostile. And the deeper gap is `Ezagent.Kind` lacks D in CRUD; tombstone is a workaround for the missing callback.

**Rejected in r7**: structural cleanup (Kind.destroy callback + DB-row-is-truth + DB-backing spawn check) replaces policy mechanism (tombstone flag + multi-boundary deny). Re-register is naturally supported by the structural mechanism (DB row absent → spawn refuses; DB row created → spawn allowed). The new design strictly subsumes the old (every tombstone INV maps to a DB-backing-check INV) AND adds INV-13 (re-register works) + INV-14 (Workspace cascade) that the old design couldn't satisfy.

### 7.2 "Soft delete" with `deleted_at` flag (rejected — preserved from r1)

`users.deleted_at` + filter every read site. Same anti-pattern: every read site becomes responsible for filtering; missing one = ghost. The discipline problem mirrors `visible: false` from `2026-05-27-workspace-cap-based-visibility.md`. r7 doesn't add a flag — it adds a callback + uses row absence as the signal.

### 7.3 "Use Ecto soft-delete library" (rejected — preserved from r1)

7.2 with a library wrapper. Same fundamental brittleness. r7 prefers structural over policy per `feedback_let_it_crash_no_workarounds`.

### 7.4 "Per-entity-type Behavior `EntityDeletion`" (rejected — preserved from r1 as 7.4 + reinforced in r7)

The r1–r6 design used `Ezagent.Behavior.EntityDeletion` as the entry point + `EntityDeletion.Adapter` for per-Kind cascade. r7 collapses this into `Ezagent.Kind.destroy/2` — the Kind owns its own cleanup, not a separate adapter module. **Why r7 is cleaner:** the cascade adapter pattern from PR-G (AgentBridge) is for cross-cutting concerns where many flavors implement the same operation. Destroy is per-Kind, not per-flavor; the Kind itself is the right home for the callback. The AgentBridge.Adapter.teardown/1 callback IS still per-flavor (because bridge teardown is genuinely per-flavor and Agent delegates to it).

### 7.5 "Don't allow runtime destroy; require operator-side DB script + phx restart" (rejected — preserved from r1)

Today's de-facto path. Fails at scale N (tenants creating + destroying test entities can't tolerate phx restart). Allen explicitly asked for runtime fix. r7 closes this.

### 7.6 "Optional `destroy/2` callback with default no-op" (considered in r7 — OQ-NEW)

If `destroy/2` is OPTIONAL, existing Kinds without an impl get the default (DB row delete + snapshot purge only — no per-Kind cleanup). Pro: lower migration cost; existing Kinds keep working without PR-C touching them. Con: every Kind quietly leaks state until someone adds a `destroy/2` — exactly the situation r7 is fixing. **Recommendation: REQUIRED** (per §10 OQ-NEW). r8 corrected the inventory undercount: full grep of `@behaviour Ezagent.Kind` in `lib/` returns 11 production Kinds + 6 production Kind.Templates (NOT five as r7 claimed). PR-C must add the four r9 callbacks (`backing_check`, `destroy_db`, `destroy_runtime`, `can_destroy?`) to each of the 17 production modules. Test-support Kinds use `use Ezagent.Kind.TestImpl` for default impls. New Kinds added post-PR-B must implement at registration time. Allen confirm in OQ-NEW.

### 7.7 "DB-backing check via FK constraint instead of explicit Kernel guard" (considered — rejected)

Alternative: add a foreign-key constraint `kind_snapshots.entity_uri REFERENCES users(uri) ON DELETE CASCADE`. The DB enforces "no snapshot without backing row" structurally. **Rejected**: (a) snapshots and users are in different scope-pools (Workspace / Worker URIs don't FK to users); (b) FK CASCADE on a row delete would silently nuke the snapshot without `Kind.Server.destroy/2`'s audit + per-Kind cleanup running; (c) we want destruction to be operator-mediated, not a side-effect of a row delete. The Kernel guard at the entity callback is the right placement — it's the gate that controls spawn, not the row insert.

---

## §8 SPEC interactions — concurrent specs

### 8.1 [2026-05-27-workspace-cap-based-visibility.md](2026-05-27-workspace-cap-based-visibility.md) (merged)

`Workspace.list_workspaces_for/2` uses cap-membership for visibility. `User.destroy/2` revokes caps + removes from `workspace.member_uris`. After destroy, `list_workspaces_for/2` returns `[]` for that caller. INV-9 pins this.

### 8.2 [2026-05-27-uri-canonicalization.md](2026-05-27-uri-canonicalization.md) (merged)

Destroy compares URIs at every cascade step. All URI parsing uses `Ezagent.URI.parse!/1`; assertions use `URI.to_string` comparison (canonical-form-invariant). No new URI-parsing path is introduced.

### 8.3 [2026-05-27-capability-action-axis.md](2026-05-27-capability-action-axis.md) (merged)

The destroy cap declares `action: :destroy` — a concrete atom, not `:any`. Per the axis SPEC §3.6.1(b), the cap grant flow always produces a per-action cap.

### 8.4 [2026-05-27-reconciler-return-shape.md](2026-05-27-reconciler-return-shape.md) (merged)

`Kind.Server.destroy/2`'s return shape is `:ok | :partial | :error` — same three-arm pattern. `:partial` here means "DB row + snapshot gone (irreversible) but per-Kind cleanup incomplete". Caller treats `:partial` the same way Reconciler callers do.

### 8.5 [2026-05-27-agent-bridge-domain-extraction.md](2026-05-27-agent-bridge-domain-extraction.md) (merged)

PR-G introduced `AgentBridge.Adapter.deliver/2` + `handle_client_event/3` + `join_info/2`. r7 adds `teardown/1` as an optional callback in the same behaviour. Existing flavor adapters get a default no-op; PR-D updates each plugin to add a real impl. Plugin isolation preserved end-to-end.

---

## §9 Backwards compatibility / external API

### 9.1 Operator workflows

- `mix ezagent.user.create` (existing) — unchanged.
- `mix ezagent.user.delete` (current behavior: low-level DB delete) — **DEPRECATED**, will emit warning + suggest `mix ezagent.kind.destroy`.
- `mix ezagent.kind.destroy <uri> --reason "<reason>"` (new) — calls `Kind.Server.destroy/2`.
- `mix ezagent.entity.backfill_worker_uri` (preserved from r1–r6 — pre-flight for Migration B).

### 9.2 External callers

The `external_mirror_bindings.worker_uri` column gain (preserved). External callers reading the table see one new field; existing reads are unaffected.

New Phoenix.PubSub broadcast: `{:kind_destroyed, target_uri, reason}` for LV consumers (admin dashboard refreshes).

### 9.3 Re-register is naturally supported (NEW under r7)

A destroyed URI can be re-created via `Users.create(uri, ...)` (or per-Kind equivalent) immediately. The next `SpawnRegistry.spawn(uri)` returns a fresh pid with no inherited state. This is INV-13. Operators no longer need to coin a new URI when "deleting and re-creating" a test entity.

### 9.4 Rollback plan

`Kind.Server.destroy/2` is forward-only — there is no `undestroy`. To "restore" an accidentally-destroyed entity, the operator re-runs the original `Users.create/3` (or per-Kind equivalent) with the prior metadata. The history (caps, memberships, snapshot, audit) is GONE — the restored entity is structurally a new one. This is intentional friction. LV confirm dialog warns "this is permanent; re-creating at the same URI does NOT restore prior state".

---

## §10 Open questions for Allen

### OQ-3 — cross-reference scrub default (preserved from r1–r6)

§3.7 implicitly chooses scrub-to-nil (Session.owner_uri scrubbed to `nil`; falls through to `data_owner/1`'s `:no_owner`). Allen confirm? Could also be per-tenant config.

### OQ-5 — admin self-destroy (preserved from r1–r6)

§3.9 allows operator to destroy themselves with a confirm dialog. Should self-destroy be allowed at all? Some systems require a "second admin" to confirm self-destruction. Default: allowed with single confirm. Allen may want second-admin requirement.

### OQ-6 — Feishu binding cascade (preserved from r1–r6)

When a user is destroyed, their `feishu_user_bindings` rows are dropped. The user's Feishu open_id is still valid in the platform; messages from that open_id will fail to resolve. Should the cascade attempt to re-bind the open_id to a fallback (e.g. `system/destroyed` sentinel user)? Default: drop binding; messages get "no user found" at the routing layer (acceptable error). Allen MAY want sentinel-rebind.

### OQ-7 — Kind destruction audit row schema (refined from r1–r6 OQ-7)

The audit row uses the existing `invocations` table with `action = "kind.destroyed"` + per-step sub-rows. Allen confirm, OR prefer a separate `kind_destruction_audit` table for queryability?

### OQ-9 — Type-the-URI LV confirmation (preserved from r1–r6 q9 / §11)

PR-E admin LV adds a "Destroy" button + confirm dialog asking for reason. Should we also require the operator to TYPE the URI being destroyed (GitHub repo-name-confirmation parity)? Default proposed: type-the-name confirmation for irreversible operations. Allen confirm?

### OQ-NEW — Kind callback contract REQUIRED vs OPTIONAL (r8 — fully scoped; r9 split into 4 callbacks)

Should the new Kind contract (r9: `backing_check/1` + `destroy_db/2` + `destroy_runtime/2` + `can_destroy?/2`) be REQUIRED (every Kind module MUST implement all four) or OPTIONAL (with defaults via `use Ezagent.Kind.TestImpl`)? **r9 recommendation (a): REQUIRED for all production Kinds + Templates.** Full grep of `lib/` produces 11 production `@behaviour Ezagent.Kind` modules + 6 production `@behaviour Ezagent.Kind.Template` modules:

Production Kinds: User / Agent / Session / AgentTemplate / SessionTemplate / Workspace / ExternalMirrorWorker / System / Echo / CurlAgent / NpAgent.

Production Templates: CcAgent / CodexAgent / EchoAgent / CurlAgent template / GenericSession / NpAgent template.

Even AgentTemplate / SessionTemplate get a meaningful `destroy/2` because destroying a template SHOULD cascade to entities instantiated from it (open question: cascade vs refuse-when-in-use — r8 picks cascade per `feedback_let_it_crash_no_workarounds`; operator can use `can_destroy?/2` to refuse if they want). System Kind's `destroy/2` is a no-op + `can_destroy?/2` refuses (system principals are bootstrap-only). Test-support Kinds (`test/support/test_behavior.ex` etc.) use the `Kind.default_destroy/2` macro via `use Ezagent.Kind.TestImpl` (PR-B new helper).

Alternatives considered:
- **(b)** REQUIRED only for "true entities" (User/Agent/Session/Workspace/Worker — 5 Kinds); rest OPTIONAL no-op. **Rejected**: prone to silent state leak (the original ghost-user bug had the same character — "no one thought to cascade").
- **(c)** Two-tier: REQUIRED for deletable-concept Kinds, OPTIONAL for utility Kinds. **Rejected**: subjective boundary; what's "utility" today becomes deletable tomorrow.

Allen confirm.

### REMOVED open questions

- ~~OQ-1 (tombstone TTL)~~ — no tombstone in r7.
- ~~OQ-8 (worker_uri NOT NULL migration timing)~~ — the two-migration + backfill task pattern is retained as-is from r1–r6; it works and Worker.destroy/2 still needs the column. No longer an OQ; documented as part of the migration plan in §4.3.

---

## §11 Codex adversarial review questions (r7+ history; r8/r9/r10/r11 status noted)

> r11 closes 4 r10-REJECT findings (B6'' read-site defense vs fictitious SessionRow + B8 terminate-time snapshot suppression + B7'' canonical workspace URI + B7''' User locks workspaces) and one consistency issue (§3.12 stale ReadyGate refs). New attack surface for codex r11:

1. **DB-backing check race (§3.6 step 4 race):** the entity callback reads `Users.get_by_uri(uri)` and decides to spawn. Concurrently, `Kind.Server.destroy(uri)` is at step 5 (terminate_child). Between the get_by_uri read and the spawn fn's eventual `Ezagent.Kind.spawn/2` call, the destroy commits step 6 (DB row delete). Does the spawn fn then load a snapshot for a Kind whose DB row is gone? Walk through the Repo transaction boundary in step 5+6+7. **r8 STATUS: addressed by reorder — DB delete (step 4b) is now BEFORE terminate_child (step 6). The "Kind dead + DB row alive" interleaving no longer exists. backing_check_fn at the TOP of SpawnRegistry.spawn/1 short-circuits before KindRegistry.lookup; INV-20 + INV-21 pin this.**

2. **Workspace cross-Kind cascade depth (§3.5 Workspace.destroy):** a workspace contains 100 users. `Workspace.destroy/2` iterates and calls `Kind.Server.destroy/2` on each. Is the iteration serial (one at a time) or parallel (Task.async_stream)? Serial: O(N) cascade time; admin LV times out. Parallel: race on shared resources (e.g. workspace.member_uris list mutated by each User.destroy/2). Pick one + justify in §3.5.

3. **AgentBridge.Adapter.teardown/1 failure isolation:** if codex's `teardown/1` raises (e.g. sidecar already dead, supervisor times out), does Agent.destroy/2 propagate or swallow? §3.5 says "best-effort"; verify the orchestrator's audit row records the error AND step 4 + step 6 still run. INV-18 should fail if the orchestrator aborts on teardown error.

4. **Re-register inheritance (INV-13):** the test asserts NO inherited caps / memberships / snapshot. But the `users` table is created fresh; the new row's `caps_json` defaults to whatever `Users.create/3` sets. Verify the test asserts the NEW caps (whatever Users.create installs) rather than the OLD caps — there's no "empty caps" universal state.

5. **DB-backing check at all relevant paths:** §2 + §4.1 lists two entity-callback registration sites (identity + chat domains). Is there ANY other path that spawns a Kind WITHOUT going through `SpawnRegistry.spawn/1`? `Ezagent.Kind.spawn/2` is one such path; r1–r6 boundary 2 addressed it. Under r7, do we need a DB-backing check at `Kind.spawn/2` too, or is the SpawnRegistry layer the only entry point in production?

6. **Behavior.Chat.scrub_owner CapBAC (r7 preserves r1–r6's narrow system principal):** the cascade dispatches `:scrub_owner` as `system://kind-destroy-cascade` (renamed). Verify the Catalog entry + the `SystemPrincipal.ensure/1` call timing + the cap-check at `Kind.Runtime.authorize/4`. Same attack surface as r1–r6 CRIT-3.1 + CRIT-4.1 + HIGH-4.3.

7. **Token.verify DB-backing check (replaces r1–r6 INV-14):** the check now reads `Users.get_by_uri(uri) == nil` instead of `SpawnRegistry.tombstoned?(uri)`. Validate: (a) timing-leak-safe (Bcrypt.no_user_verify on the deny path); (b) before bcrypt comparison; (c) covers Agent tokens (`Agents.get_by_uri/1`) not just User.

8. **Cold-load data_owner across three sites (replaces r1–r6 INV-13b):** same three resolvers (Chat / ExternalMirror / Publisher.SessionImpl), now with DB-backing checks instead of tombstone checks. Verify no fourth resolver exists, AND the DB-backing check is positioned BEFORE the URI is returned.

9. **`destroy/2` REQUIRED migration cost:** if OQ-NEW chooses REQUIRED, every existing Kind module must add `destroy/2`. Enumerate: `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex`, `apps/ezagent_domain_instance_message/lib/ezagent/entity/agent.ex`, `apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex`, `apps/ezagent_domain_workspace/lib/ezagent/entity/workspace.ex`, `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/worker.ex`. Is anything missed? Are there test-fixture Kinds that need it?

10. **LV confirm dialog UX (preserved from r1–r6 q9):** type-the-URI confirmation default. Allen confirm in OQ-9.

### §11.r8 — new attack surface introduced by r8

11. **Reorder coherence (B1):** DB delete moved BEFORE terminate_child. Is there a new race introduced? Specifically: between transaction commit (step 4) and `KindRegistry.lookup` (step 5), can a concurrent dispatch reach the live-but-DB-deleted pid via *another* path (e.g. a previously cached pid reference held by another GenServer's slice state, a process Dictionary)? Walk through every place a `pid` reference might be retained across the destroy window. The B2 SpawnRegistry check guards the spawn path; what about non-spawn dispatch paths?

12. **Per-scheme backing_check_fn placement (B2):** the new `SpawnRegistry.spawn/1` calls `backing_check_fn` BEFORE `KindRegistry.lookup`. Verify: (a) NO other entry point produces a Kind without going through `SpawnRegistry.spawn/1` (e.g. `Ezagent.Kind.spawn/2` direct calls in Loader / BootReconciler / test helpers); (b) `backing_check_fn` is registered for EVERY scheme that has DB-backed Kinds (identity / chat / workspace / external_mirror / system — and System might not need it); (c) the legacy 2-arity `register/2` fallback (returns "always true") doesn't quietly bypass the check for an in-prod scheme.

13. **Idempotency contract under partial failure (B3):** `{:ok, :already_destroyed}` returns when 4b returns 0 rows. But what if 4b returns 0 because the row NEVER existed (operator typo'd a URI)? Distinguish that from "concurrent destroy already committed"? `Kind.Server.destroy` of a URI that never had a row: should that be `{:error, :not_found}` or `{:ok, :already_destroyed}` (idempotent)? Walk through the orchestrator's behavior on a non-existent URI; verify can_destroy?/2 catches it OR the precheck does.

14. **Workspace nested-member refusal (B4):** `Workspace.can_destroy?/2` refuses if any member URI is `workspace://...`. But the member list comes from the live Workspace slice; can a member be ADDED concurrently between can_destroy?/2 and the cascade in step 3? Verify the cascade itself re-reads the member list under a consistent point (or that the slice is frozen by the orchestrator). What if a member is a workspace via *indirect* construction (a User Kind whose URI scheme is `entity://` but whose host is `workspace` — typo case)?

15. **B5 — REQUIRED enforcement at compile time:** if `destroy/2` is `@callback` (REQUIRED), every Kind module that fails to implement it should produce a compile warning. Verify the behavior contract is REQUIRED not `@optional_callbacks`. For test-support Kinds, the `Kind.default_destroy/2` macro is described — is it a `defmacro use` that injects the impl, OR is it a separate `Ezagent.Kind.TestImpl` behavior? The spec is ambiguous (the §4.1 wording uses both phrasings).

16. **Transaction atomicity vs per-Kind cleanup (4a/4b/4c):** the transaction wraps snapshot + DB row + audit. Per-Kind `destroy/2` (step 3 — caps revocation, binding deletion, etc.) is OUTSIDE the transaction. What happens if 4b's DB delete fails (e.g. FK constraint, DB error)? The transaction rolls back; the audit row is NOT inserted; but step 3's caps revocation has already happened (it's outside the transaction). The system ends up in a "user exists in DB, has no caps" state — the EXACT bug the original ghost issue had. Is there a compensating action, or does the orchestrator return `{:error, {:partial, ...}}` and rely on the operator to re-run? The §3.12 says "let-it-crash, no compensating action" — does this satisfy `feedback_let_it_crash_no_workarounds` cleanly, or does it leave a footgun? **r9 STATUS: addressed — step 3 collapsed into a single Repo.transaction wrapping caps + memberships + snapshot + DB row + audit (B6). Per-Kind destroy split into destroy_db/2 (inside-tx) + destroy_runtime/2 (outside-tx, post-terminate). If 3d fails, ALL of step 3 rolls back atomically.**

17. **INV-19 race precision:** the test races two concurrent destroys. Under Postgres READ COMMITTED, both may pass can_destroy?/2 + run destroy/2; both enter the transaction; one blocks on the row lock. The blocked transaction, when unblocked after the winner commits, will see the row gone. `Users.delete(uri)` returns `{0, _}`. Does the SECOND transaction's audit insert COMMIT successfully, or does it fail because the per-Kind destroy/2 in step 3 left the system in a state that step 4c's audit row references something now-deleted (FK to caller? to target?)? Verify the audit table has no FK that breaks under this ordering. **r9 STATUS: codex r8 verified `invocations` table has NO FK to users/targets (audit fields are strings, not refs) — so the second transaction's audit insert succeeds under r9. r9 distinguishes the loser case from the typo case via step 0 backing_check, removing the ambiguity codex r8 raised in q13.**

### §11.r9 — new attack surface introduced by r9

18. **B1' dispatch fence — `:destroying` ETS write is NOT transaction-aware.** r9 step 3a does `ReadyGate.put(uri, :destroying)` INSIDE the Repo.transaction, but ETS is not Repo-aware. §3.6.1 describes a "revert on rollback" mechanism: capture prior state, restore on `{:error, _}` from `Repo.transaction`. Walk the revert in detail:
    - What if the orchestrator process CRASHES between transaction rollback and the revert call? ReadyGate is stuck at `:destroying`; the Kind is alive but unreachable. Operator needs a recovery path (manual `ReadyGate.put(uri, :ready)` or a sweeper that detects orphan `:destroying` entries).
    - What if multiple destroy calls race the same URI, both set `:destroying`, one rolls back, one commits? The committed one's terminate_child + step 8 purge handles the rollback peer's stale `:destroying` correctly — but is the ordering deterministic?
    - Does the `:destroying` state cause `KindRegistry.lookup` (other consumers, not just Invocation.dispatch) to misbehave? Cross-reference: any other consumer of `KindRegistry.lookup` (other than Invocation.dispatch)? Grep the codebase.

19. **B2' universal backing_check — `Kind.spawn/2` is called with `params`, not always a URI.** §2's pseudocode assumes `params.uri` exists. But the existing `Kind.spawn/2` signature is `(kind_module, params :: map())` — `uri` may not always be at the `:uri` key (some Kinds derive URI from other args via `uri_from_args/1`). The r9 fix needs to call `kind_module.uri_from_args(params)` OR rely on every call site providing `:uri`. Walk the existing call sites — do they all set `params.uri`? If not, the backing_check has a hole.

20. **B6 atomic transaction — `Repo.advisory_xact_lock` inside `Repo.transaction` deadlock potential.** Workspace.destroy_db/2 acquires an advisory lock, then cascades into `Kind.Server.destroy` for each member. Each member's destroy starts its own `Repo.transaction`. Under Ecto's default semantics, a nested `Repo.transaction/1` becomes a savepoint within the outer transaction — and the advisory_xact_lock from the workspace is held across all member destroys. Member destroys themselves acquire OTHER advisory locks (per-User, per-Session) — is there ANY ordering where two concurrent workspace destroys deadlock on overlapping member sets? (E.g. Workspace1 contains User1+User2; Workspace2 contains User2+User3. Concurrent destroys.) The advisory lock key namespace and the lock acquisition order need to be documented.

21. **`destroy_db/2` raise propagation through `Workspace.destroy_db/2` cascade.** If member User1's `destroy_db/2` raises (e.g. FK constraint violation on a row the cascade missed), the recursion bubbles up; Workspace.destroy_db/2 raises; the outer transaction rolls back; ReadyGate `:destroying` reverts for the workspace BUT NOT for User1 (User1's ReadyGate was set inside the rolled-back transaction's nested savepoint — Postgres' savepoint rollback would undo the row-lock acquisition but ReadyGate ETS writes are not savepoint-aware). Walk through: does User1's ReadyGate stay `:destroying` after the workspace destroy rolls back? If yes, INV-23 fails (the inconsistent state codex r8 was worried about).

22. **`backing_check/1` is the same DB read as r8's `backing_check_fn` — does the per-Kind callback compile-check correctly for ALL 17 production Kinds?** PR-C must add `backing_check/1` to each. For Kinds without a single backing table (e.g. System Kind's URI is a derived value from `SystemPrincipal.Catalog`, not a row), `backing_check/1` returns `true` unconditionally. Is this honest? An operator could `Kind.Server.destroy(system://kind-destroy-cascade)` and step 0 would pass (true), then step 1's `can_destroy?/2` refuses with `:system_principal_undestroyable`. Acceptable, but the SPEC should make it explicit: System Kinds' backing_check is a tautology because their existence IS their code (no DB row to delete). What about Echo / CurlAgent — do they have backing tables?

23. **Cross-Kind cascade audit correlation under `:already_destroyed`.** A workspace cascade calls `Kind.Server.destroy` on each member; if a member returns `{:ok, :already_destroyed}` (the loser case), does the workspace's audit row aggregate that correctly? The cascade summary in step 3e's audit row needs an explicit field for per-member outcomes. **r10 STATUS: addressed — step 3e's `result` JSON now includes `cascade_outcomes: [...]` field listing per-member outcome strings. INV-19 updated.**

### §11.r10 — new attack surface introduced by r10

24. **B1'' in-GenServer fence — `backing_check` runs on EVERY handle_call/handle_cast.** This adds a synchronous DB read to every dispatch (per Kind, per message). Walk performance: under realistic load (many dispatches per second per Kind), is the additional DB read a meaningful regression? Prepared-statement caching makes it fast (~50µs in-process), but if a Kind processes 1000 msg/s the overhead is 50ms/s. Is there a smarter strategy — e.g. cache the "row exists" answer in the Kind's process state, invalidated by a PubSub broadcast from `Kind.Server.destroy/2` step 8? The r10 design accepts the cost as bounded by the slow-path (only fires on the FIRST dispatch after destroy commit) but doesn't make that bound explicit.

25. **In-GenServer fence + `terminate/2` semantics.** When `handle_call` returns `{:reply, _, state, {:continue, :shutdown_after_reply}}`, the GenServer replies, then runs `handle_continue`, then `{:stop, :normal, state}`. But `terminate/2` runs on `:normal` exit — does the Kind's `terminate/2` callback re-trigger `:on_terminate` snapshot writes? The destroy already deleted the snapshot row in step 3c; a `terminate/2` write would re-create it. Walk: is the Kind.Server's `terminate/2` aware of "we're shutting down because we lost our backing row, don't snapshot"? Need a state flag (`:destroyed_self_terminating` or similar) that suppresses snapshot in `terminate/2`. **r11 STATUS: addressed (B8) — Kind.Server.terminate(:destroyed, _) explicitly skips snapshot. In-GenServer fence uses `{:stop, :destroyed, state}` (not `:normal`). Orchestrator's step 6 uses `GenServer.stop(pid, :destroyed)`. INV-27 NEW.**

26. **B6' direct Repo writes — Session in-memory slice cache invalidation.** `User.destroy_db` does `Repo.update_all` to scrub Session.owner_uri in the DB. The Session GenServer's `:chat` slice still has the old owner_uri cached. The codebase's existing read-site DB-backing defense (Users.get_by_uri at the read site) saves correctness, but the slice cache is now stale forever (until Session is restarted). Is the staleness harmless (all reads bypass to DB defense) OR are there code paths that read the slice directly without the DB defense? Grep `:chat slice` consumers. **r11 STATUS: re-architected (B6'' grounded) — there is no SessionRow / sessions table in the codebase; r10's mechanism was fictitious. r11 drops the direct write entirely and relies on the read-site DB-backing defense at all three `data_owner/1` sites. ExternalMirror.data_owner was missing the defense — r11 PR-B adds it (closes the codex r10 gap).**

27. **B7' Workspace.add_member — composed-operations atomicity.** r10's add_member: `Repo.transaction(fn -> advisory_lock; ensure_member_kind_spawned_at_facade; dispatch_mutation; Store.update_members end)`. The `ensure_member_kind_spawned_at_facade` calls `Kind.spawn/2` which calls `DynamicSupervisor.start_child` — that's a CROSS-PROCESS spawn that does NOT run inside the Repo transaction. If `dispatch_mutation` fails after the spawn, the transaction rolls back but the spawned Kind is left alive (with no caps and no membership recorded). Same class of bug as r8's q16 — cross-process side effects inside a "transactional" wrapper. **r11 STATUS: not introduced by r10/r11 — this is a pre-existing pattern in `Workspace.add_member`. r11 inherits it. Spawn-without-membership leak is bounded: the next dispatch to that spawned Kind will see no caps (caps come from membership) and reject; the Kind will eventually be terminated by snapshot-strategy + supervisor restart-intensity. Out of scope for SPEC #440 but documented for follow-up.**

28. **Global lock ordering — workspace_uri vs member_uri lexicographic comparison.** §3.5.x sorts URI strings lexicographically. But `entity://user/foo/bar` and `entity://workspace/baz` sort by scheme+host, with `user` < `workspace`. For a workspace destroy of `entity://workspace/team` with members `entity://user/a` and `entity://user/z`, the sort gives `[entity://user/a, entity://user/z, entity://workspace/team]`. Locks acquired in that order. Concurrent destroy of `entity://user/a` (a different operator action) would acquire `[entity://user/a]` only. Workspace destroy waits on the user lock (already held by the concurrent user destroy). Acceptable serialization, no deadlock. But what if the user destroy ALSO cascades to other resources (e.g. revokes a workspace-scoped cap that touches the workspace row's caps_json)? Does the user destroy need the workspace lock too? Trace dependencies.

29. **`Kind.Server.with_locks/2` helper — savepoint semantics.** §3.5.x's helper acquires multiple advisory locks in sorted order then invokes `fun`. If `fun` itself opens a nested `Repo.transaction/1` (savepoint), the advisory locks stay held by the OUTER transaction. Releasing on rollback of an inner savepoint — does Postgres release inner-savepoint-acquired advisory locks? Per Postgres docs: `pg_advisory_xact_lock` is released ONLY on transaction COMMIT or ROLLBACK; savepoint rollback does NOT release them. r10's recursive cascade depends on this — each nested member destroy uses the outer transaction's already-held locks. Verify.

30. **Direct Repo.update_all in destroy_db — Ecto changeset bypass.** `User.destroy_db` does `Repo.update_all(from s in SessionRow, set: [owner_uri: nil])` directly, bypassing the SessionRow changeset (which may have validations or callbacks). Is that safe? `owner_uri = nil` may be a constraint violation (e.g. session_owner NOT NULL). Verify the SessionRow schema's nullability. **r11 STATUS: moot — there is no SessionRow schema. r11 drops the direct write entirely (see q26 r11 status).**

### §11.r11 — new attack surface introduced by r11

31. **B6'' read-site defense — race between slice cache and Users.get_by_uri.** Under READ COMMITTED, a dispatch reads the slice (in-memory, no DB), gets `owner_uri = some_user`, then reads `Users.get_by_uri(owner_uri)` — sees nil (User just destroyed) → returns `:no_owner`. But what if the user was destroyed AFTER the slice was read but BEFORE the DB-backing check? The dispatch returns `:no_owner` correctly. Reverse: user destroyed BEFORE the slice read, slice still cached the old owner_uri — DB check returns nil → `:no_owner`. Either order: correct. Verify there's NO code path that reads the slice's owner_uri WITHOUT the Users.get_by_uri check (grep for `:chat slice` consumers beyond Chat / Publisher / ExternalMirror).

32. **B8 terminate(:destroyed, _) — `GenServer.stop(pid, :destroyed)` vs `DynamicSupervisor.terminate_child`.** `DynamicSupervisor.terminate_child/2` uses `:shutdown` as the reason and does NOT support a custom reason. To pass `:destroyed`, the orchestrator must use `GenServer.stop(pid, :destroyed, timeout)` directly. But `GenServer.stop` doesn't go through the supervisor — does it bypass the supervisor's shutdown order / linking? Walk: when `GenServer.stop` is called on a child of a `DynamicSupervisor`, the supervisor receives the EXIT signal as normal child death; does the supervisor try to restart it? `DynamicSupervisor` with `restart: :transient` does NOT restart on `:normal` or `:shutdown` exits, but `:destroyed` is a custom reason — does transient restart fire? Need to verify the `restart_strategy` semantics for custom reasons.

33. **B7''' destroy_db_locks must enumerate ALL workspaces — list query inside the orchestrator BEFORE the transaction.** `destroy_db_locks(user_uri, _ctx)` returns `[user_uri | workspaces_containing(user_uri)]`. The `workspaces_containing` query reads the DB. Between this read and the transaction's lock acquisition, a concurrent `Workspace.add_member` could add the user to a NEW workspace. The lock list would be stale; the new workspace wouldn't be locked. `User.destroy_db`'s subsequent `Workspaces.list_workspaces_containing(user_uri)` (called inside the transaction) would return the FRESH list, including the new workspace — but the new workspace's lock was never acquired. Repercussion: violates the §3.5.x lock-ordering rule. Mitigation: either acquire a "user lock" first (covers all the user's workspace memberships transitively — but membership is not a 1:1 relationship), OR re-compute the workspace list inside the transaction with a `SELECT FOR UPDATE` semantic (the Postgres row lock on the workspace rows themselves would serialize the add). Walk the consistency story.

34. **B6'' three-site coverage assertion (INV-16b).** The r11 fix adds the DB-backing defense to `ExternalMirror.data_owner/1`. Are there other consumers of the `:chat` slice's `owner_uri` (or any cached User URI from another slice) that haven't been audited? grep for `slice.owner_uri` AND `Map.get(slice, :owner_uri)` AND `%{owner_uri:` consumers.

35. **No SessionRow schema means User.destroy_db doesn't need a Session lock — but does Workspace destroy?** Workspace destroy cascades to its session_uris (workspace.destroy_db's `:cascade_session_destroys` step). Those Session Kinds are spawned/destroyed via Kind.Server.destroy. Each Session destroy adds the session_uri to the parent workspace's lock list (via destroy_db_locks). Verify the lock list includes Session URIs.

---

## §12 Rollback plan

This SPEC's impl is forward-only (no rollback of an applied destroy). Rollback of the SPEC ITSELF (revert PR-A → PR-B → ...):

1. Revert the merge commits in reverse order.
2. The `external_mirror_bindings.worker_uri` column remains (NULL-able orphaned column; harmless).
3. The `Ezagent.Kind.destroy/2` callback addition reverts; existing Kinds lose the callback contract (compile fails if REQUIRED — operators MUST roll back PR-C alongside PR-B if REQUIRED).
4. The `AgentBridge.Adapter.teardown/1` extension reverts; default no-op was the only impact.
5. Operators who had relied on `Kind.Server.destroy/2` lose access; manual SQL delete is the fallback again.
6. No tombstone table to clean up (r7 never created one).

The DB schema additions are non-destructive (worker_uri column only); rolling back is safe at any time.

---

## Appendix A — Sequence diagram

```
Operator (admin LV)
  │ click "Destroy" + type reason + type-the-URI confirmation
  ▼
Kind.Server.destroy(target_uri, %{caller, reason})
  │
  ▼ step 0: existence precheck (r9 B3')
  │     kind.backing_check(target_uri) → true/false
  │     false → {:error, :not_found}                                   [INV-22]
  │
  ▼ step 1: kind.can_destroy?(target_uri, ctx) → :ok or :precheck_failed
  ▼ step 2: generate trace_id
  │
  ▼ step 3 — Repo.transaction (atomic; r11 ordering)
  │     step 3a: lock_uris = kind.destroy_db_locks(target_uri, ctx)
  │             with_locks(sorted lock_uris, fn ->
  │               # Repo.advisory_xact_lock("kind:#{URI.to_string(uri)}") per URI
  │               # in alphabetical order — r11 B7''' global ordering rule
  │     step 3b: kind.destroy_db(target_uri, ctx_with_trace)
  │             — User: revoke_all_caps / drop bindings / drop memberships
  │                     (no session-row scrub — r11 B6'' grounded: no SessionRow
  │                      table; read-site defense at consumers handles staleness)
  │             — Agent: revoke tokens / drop memberships / scrub routing rules
  │             — Workspace: re-read members from DB + recurse
  │                          Kind.Server.destroy each (B7)             [INV-23]
  │             — Worker: drop external_mirror_bindings (worker_uri column)
  │             — Session: drop session_members (in-memory only — no DB writes)
  │             RAISES on failure → transaction rolls back atomically
  │     step 3c: Repo.delete(KindSnapshot, target_uri_str)             [idempotent]
  │     step 3d: kind.delete_db_row(target_uri)
  │             rows_affected == 0 → result["outcome"] = "already_destroyed"  [INV-19]
  │             rows_affected == 1 → result["outcome"] = "ok"
  │     step 3e: Repo.insert(InvocationsAudit, %{action: "kind.destroyed",
  │             target, caller, args: %{"reason" => reason},
  │             result: %{"outcome" => ..., "trace_id" => ...,
  │                       "kind_summary" => ..., "cascade_outcomes" => [...]}})
  │             — r10 N3: outcome nests in result jsonb (no schema change)
  │           end)  # advisory locks released on transaction commit
  │
  ▼ step 4: transaction commit OR rollback
  │     commit → proceed to step 5
  │     rollback → return {:error, {:transaction_failed, _}}; NO state mutated
  │              — r10 has NO ETS state to revert (ReadyGate :destroying REMOVED)
  │
  ▼ step 5: KindRegistry.lookup(target_uri)
  │     {:ok, pid} → step 6
  │     :error → skip step 6 (Kind wasn't alive)
  │
  ▼ step 6: GenServer.stop(pid, :destroyed) — r11 B8
  │     Kind.Server.terminate(:destroyed, _state) → :ok    [INV-27]
  │     (skips :on_terminate snapshot persistence that would
  │      resurrect the just-deleted snapshot row)
  │     NOTE: at this point both fences hold (r10/r11):
  │       Spawn:    Kind.spawn/2 + WorkerSpawn.spawn/4 → backing_check
  │                 → false → :no_backing_entity
  │       Dispatch: in-flight messages reach Kind.Server.handle_call/cast
  │                 → backing_check(state.uri) → false
  │                 → reply :no_backing_entity + {:stop, :destroyed, state}
  │                 → terminate(:destroyed, _) → skip snapshot
  │
  ▼ step 7: kind.destroy_runtime(target_uri, ctx)   [outside transaction]
  │     - Agent: AgentBridge.Adapter.teardown / sidecar / per-agent dir
  │     - Worker: adapter_module.terminate
  │     - Session: Publisher.unsubscribe_all
  │     errors LOGGED; partial → return {:error, {:partial, %{runtime_errors}}}
  │
  ▼ step 8: broadcast (r10: no ReadyGate purge — there is no ReadyGate :destroying state)
Phoenix.PubSub.broadcast({:kind_destroyed, target_uri, reason})
  │
  ▼
{:ok, %{deleted_uri, steps_completed, cascade_summary, audit_event_id, trace_id}}

# Re-spawn after destroy (any path — Kind.spawn/2 or WorkerSpawn.spawn/4)
Ezagent.Kind.spawn(SomeKind, %{uri: target_uri, ...})
  │ STEP 1: kind_module.backing_check(target_uri) → false (row gone)
  │         [r9 + r10 — UNIVERSAL fence at Kind.spawn/2 AND WorkerSpawn.spawn/4]
  ▼
{:error, :no_backing_entity}

Ezagent.ExternalMirror.WorkerSpawn.spawn(session_uri, adapter_id, target_id, opts)
  │ STEP 1: Worker.backing_check(derived_worker_uri) → false (binding row gone)
  │         [r10 B2'' — closes codex r9 bypass]
  ▼
{:error, :no_backing_entity}

# Re-dispatch after destroy
Ezagent.Invocation.dispatch(%Invocation{target: target_uri, ...})
  │ STEP 1: KindRegistry.lookup → :ok (pid alive, mid-terminate) OR :error
  │   if :ok → GenServer.call(pid, {:dispatch, inv})
  │   pid's handle_call: kind_module.backing_check(state.uri) → false
  │                    → {:reply, {:error, :no_backing_entity}, state,
  │                       {:continue, :shutdown_after_reply}}
  │                    → handle_continue :shutdown_after_reply → {:stop, :normal, state}
  │   if :error → return {:error, :no_such_actor}
  ▼
{:error, :no_backing_entity}  during destroy (in-flight tearing-down pid)
{:error, :no_such_actor}      after step 6 (pid gone)

# Re-register
Users.create(target_uri, fresh_attrs)  # writes new row
Ezagent.Kind.spawn(User, %{uri: target_uri, ...})
  │ STEP 1: User.backing_check(target_uri) → true (new row exists)
  │ STEP 2: DynamicSupervisor.start_child → fresh pid
  ▼
{:ok, fresh_pid}  # no inherited state — fresh Kind, fresh slice, no snapshot

# Concurrent destroy race [INV-19]
A: Kind.Server.destroy(uri, ctx_a)  ─┐
B: Kind.Server.destroy(uri, ctx_b)  ─┤ both pass step 0 + 1 (row still exists)
                                     │ both enter step 3 transaction
                                     │ Postgres row-lock serializes them
A: 3d returns {1, _} → outcome :ok ──┘    → {:ok, %{...}}
B: 3d returns {0, _} → outcome :already_destroyed → {:ok, :already_destroyed}
  Both audit rows present, distinct trace_ids
  Only A runs steps 5/6/7/8 (B skips — winner already did the runtime work)

# Typo'd URI [INV-22]
Kind.Server.destroy("entity://user/typo/no_such_user", ctx)
  │ step 0: backing_check → false
  ▼
{:error, :not_found}  # NOT :already_destroyed; NO audit row; NO mutation
```

## Appendix B — Why this SPEC is shorter than r6

r6 was 985 lines. r11 ≈ 130% of r6: each revision added rigor on top of the prior. r7 removed the tombstone artifact entirely; r8 added race/idempotency/inventory rigor; r9 added dispatch fence + universal Kind.spawn check + destroy_db/destroy_runtime split + existence precheck + workspace advisory lock; r10 replaced the ETS-based dispatch fence with an in-GenServer check, attempted cross-Kind Behavior dispatch removal via direct Repo writes (later revealed by codex r10 to target a non-existent schema), added the WorkerSpawn bypass fix, added Workspace.add_member lock, and defined global advisory-lock ordering; r11 grounded the cross-Kind cleanup in the actual codebase (read-site DB-backing defense at three consumers instead of direct DB writes to a fictitious SessionRow), added terminate-time snapshot suppression for destroy-induced shutdowns, corrected workspace lock URI to the canonical form, and added the `destroy_db_locks/2` callback for orchestrator pre-transaction lock acquisition. What remains: the `Kind` callback contract (5 callbacks: backing_check + destroy_db + destroy_runtime + destroy_db_locks + can_destroy?, ~50 lines), the `Kind.Server.destroy/2` orchestration (~160 lines under r11's atomic-transaction + lock-ordering + in-GenServer-fence + destroyed-terminate detail), the per-Kind callback tables (preserved from r6 and split per r9, ~120 lines), the AgentBridge.Adapter.teardown extension (~10 lines), the Kind.spawn/2 + WorkerSpawn.spawn/4 + Kind.Server.handle_call/cast + Kind.Server.terminate(:destroyed) extensions (~50 lines, r10/r11), the ExternalMirror.data_owner DB-backing defense addition (~5 lines, r11), the **INV table (27 entries — INV-1 through INV-27, ~80 lines)**, the OQ list (6 entries, ~30 lines).

## Appendix C — Author's recommendation

Land PR-A (this SPEC) → PR-B (core: Kind contract — backing_check + destroy_db + destroy_runtime + destroy_db_locks + can_destroy? + Kind.Server.destroy + Kind.spawn universal backing check + WorkerSpawn.spawn entry-level backing check + Kind.Server.handle_call/cast in-GenServer dispatch fence + **Kind.Server.terminate(:destroyed) snapshot-skip arm** + Workspace.add_member advisory lock + global URI-string lock ordering helper + **ExternalMirror.data_owner DB-backing defense** + AgentBridge.Adapter.teardown). PR-C (per-Kind destroy impls — 11 Kinds + 6 Templates per B5 full inventory) follows immediately because the callback contract is REQUIRED (per OQ-NEW recommendation (a)); PR-D (plugin bridge teardown impls) can land parallel to PR-C; PR-E (LV UI + CLI) lands last.

The `system/linyilun` ghost — surfaced 2026-05-28 — is the empirical motivation, but the structural fix is broader: every Kind gains a clean lifecycle CRUD parity, re-register at a destroyed URI works naturally because the DB row is the source of truth, concurrent destroy is idempotent (`{:ok, :already_destroyed}` for the loser), typo'd URIs return a clear `{:error, :not_found}`, cross-Kind cleanup uses the read-site DB-backing defense (no cross-process dispatch; no fictitious DB schemas), the dispatch fence lives inside the Kind's own GenServer (single source of truth), and the destroy-induced shutdown skips the snapshot persistence that would otherwise resurrect the just-deleted row. The architectural goal Allen articulated (2026-05-28 03:43) is met: "all Kinds should have complete CRUD".

INV-1 through INV-27 (27 invariants total) are the merge gates: a passing test suite proves the design's claims; a partial impl is structurally unable to pass.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
