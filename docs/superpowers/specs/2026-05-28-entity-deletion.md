# SPEC — Entity deletion lifecycle (User / Agent / Worker)

**Status:** r2 — codex r1 review (REJECT) addressed: 6 critical blockers + 3 nits. 2026-05-28.

**r2 changes (codex r1 verdict REJECT — 6 blockers + 3 nits resolved):**

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
- `{:error, {:partial, _}}` — pre-check passed, tombstone-and-kill done (irreversible), but at least one DB cascade step failed. The Kind is dead + tombstoned (cannot resurrect), but cross-reference scrub is incomplete. `recovery_hint` tells the operator which step + how to manually re-run.
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
    3. Process.exit(pid, :brutal_kill) + wait for terminate-monitor.
       Returns :ok once the registered pid is gone (or was already
       absent, in which case steps 1+2 still hold).

  Because the DB row is committed BEFORE the kill, a BEAM crash between
  steps 1 and 3 leaves the tombstone authoritative on next boot — the
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

**B3 — Session owner scrub via real Behavior.Chat action.** `Behavior.Chat` (`apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:88`) declares actions `[:send, :receive, :join, :leave, :set_working_copy]` today. This SPEC adds a NEW Session-side action `:scrub_owner` with:

- `actions/0`: `[:send, :receive, :join, :leave, :set_working_copy, :scrub_owner]`
- `required_caps/0`: `:scrub_owner` is gated on the bootstrap-admin shape via `cap(:any, __MODULE__, :scrub_owner)` (only the EntityDeletion cascade ever invokes this — operator-level dispatch is structurally rejected by `Adapter.can_delete?/2`'s admin-only path)
- `invoke(:scrub_owner, slice, %{deleted_uri}, _ctx)`: if `slice.owner_uri == deleted_uri`, set `owner_uri: nil` (NOT a sentinel URI — `nil` falls through to `data_owner/1`'s `:no_owner` clause at `chat.ex:1337`, preserving existing semantics for system sessions). Returns `{:ok, %{owner_scrubbed: true}, slice_with_nil_owner, dispatch_envelope}` so the standard `Kind.Runtime` step 9.5 persists via `:on_change` strategy.

The cascade step body:

```elixir
def scrub_session_owner_uri(target_user_uri, _ctx) do
  # Lookup is over the live registry — only sessions whose Kind is alive
  # AND whose slice currently has owner_uri = target. Snapshotted-but-
  # not-resident sessions don't matter: when they rehydrate, the merged
  # slice is overlaid by the post-tombstone DB cascade's audit, and the
  # next reconcile (Kind.Snapshot.load_or_init/3) sees the User's URI is
  # tombstoned — but no action runs on a non-resident Session here.
  # SAFETY: any Session that loads later with stale owner_uri = deleted
  # is reconciled at chat.join time (the deleted user can't join, so
  # the session can't act on their behalf; owner authority falls
  # through to :no_owner via chat.ex:1337 since the deleted URI is
  # tombstoned and Session.owner/1 returns an error path).
  alive_sessions =
    Ezagent.KindRegistry.list_matching(scheme: "session")
    |> Enum.filter(fn {_uri, pid} -> alive_session_owned_by?(pid, target_user_uri) end)

  Enum.reduce(alive_sessions, %{scrubbed: 0, errors: []}, fn {session_uri, _pid}, acc ->
    case Ezagent.Invocation.dispatch(%Invocation{
           kind: Ezagent.Entity.Session,
           behavior: Ezagent.Behavior.Chat,
           action: :scrub_owner,
           target: session_uri,
           args: %{deleted_uri: target_user_uri},
           ctx: %{caller: cascade_caller_uri, trace_id: cascade_trace_id}
         }) do
      {:ok, _} -> %{acc | scrubbed: acc.scrubbed + 1}
      {:error, reason} -> %{acc | errors: [{session_uri, reason} | acc.errors]}
    end
  end)
end
```

**Session-deleted-between-lookup-and-dispatch race:** if a Session Kind dies between `KindRegistry.list_matching/1` and `Invocation.dispatch/1`, dispatch returns `{:error, :noproc}`. The cascade treats this as success (the session is gone; there's nothing to scrub). If the Session was tombstoned (by a concurrent Session deletion), dispatch returns `{:error, :tombstoned}` from boundary 1 — also treated as success. The cascade step's idempotency contract holds: re-running is a no-op.

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
:drop_external_mirror_bindings → delete external_mirror_bindings WHERE worker_uri = target    [B5 — see below]
:unsubscribe_session_publisher → Publisher.unsubscribe(target)
:terminate_adapter             → adapter_module.terminate(target)
```

**B5 — Worker cascade column fix.** r1's `WHERE bound_by = target` was wrong: `bound_by` records the CREATING USER URI per `apps/ezagent_core/priv/repo/migrations/20260607000000_pr_em_3_external_mirror_bindings.exs:54`, while the Worker URI is structurally derived from `(session_uri, adapter_id, target_id)` via `WorkerSpawn.worker_uri_for/3` (`worker_spawn.ex:217-230`) and NOT stored in the table.

Per `feedback_let_it_crash_no_workarounds` (structural over policy), the r2 fix adds a persisted `worker_uri` column to `external_mirror_bindings`:

- **Forward-only migration** (`apps/ezagent_core/priv/repo/migrations/<timestamp>_pr_a_worker_uri_column.exs`): `add :worker_uri, :string, null: true` initially (to allow backfill), then populate via the same backfill mix task in PR-A, then a follow-up migration sets `NOT NULL`. Greenfield deployments (dev / test) get `NOT NULL` immediately because there are no pre-existing rows.
- **Write path:** `Behavior.ExternalMirror.invoke(:bind, ...)`'s persistence step (the action body that writes to `external_mirror_bindings`) is updated to populate `worker_uri = WorkerSpawn.worker_uri_for(session_uri, adapter_id, target_id) |> URI.to_string()`.
- **Read path:** `AdapterInstall.reconcile_persisted_bindings/1` (`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_install.ex:193-220`) still derives the Worker URI structurally (it has session_uri + adapter_id + target_id from the row); the new column is for the deletion cascade, not the reconcile path.
- **Cascade query:** `Repo.delete_all(from b in BindingRow, where: b.worker_uri == ^target_uri_str)` — direct + race-free.
- **`bound_by` unchanged.** Still records creator identity. The User cascade scrubs `bound_by` references separately (no, actually — `bound_by` doesn't need a cascade since a user being deleted doesn't invalidate the bindings they CREATED; the bindings stay bound to a still-alive Worker/Session and the operator-of-record is rewritten to the tombstone sentinel only when the cascade's `:scrub_audit_owner_refs` step runs, which is User-scope, not Binding-scope). See §3.7 for the cross-reference scrub policy.

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

### 3.9 Edge case — concurrent dispatch during deletion

The atomic `tombstone_and_kill/1` (§3.3) closes the original kill-vs-tombstone race. Remaining concurrency:

- Dispatch to the dying Kind: `GenServer.call` blocks until terminate completes, then returns `{:error, :noproc}`. Acceptable — caller gets a clean error.
- Dispatch arrives after `tombstone_and_kill` but before later cascade steps: SpawnRegistry.spawn refuses with `:tombstoned` (boundary 3); the dispatch surfaces a clean error.
- Dispatch from a queued message already in the Kind's mailbox: `Kind.Server.terminate/2` drains the mailbox naturally per OTP semantics; queued messages effectively get `{:error, :noproc}`.

No "transactional dispatch barrier" is needed.

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
- `apps/ezagent_core/priv/repo/migrations/<timestamp>_pr_a_worker_uri_column.exs` (new) — adds `worker_uri` to `external_mirror_bindings` (B5)
- **Modify** `apps/ezagent_core/lib/ezagent/spawn_registry.ex` — add `tombstone_and_kill/1` public primitive + `tombstoned?/1` read + tombstone check at `spawn/1` entry (boundary 3)
- **Modify** `apps/ezagent_core/lib/ezagent/kind.ex` — add tombstone check at `spawn/2` entry (boundary 2)
- **Modify** `apps/ezagent_core/lib/ezagent/kind/server.ex` — add tombstone check at `init/1` entry, return `{:stop, :tombstoned}` (boundary 1 — authoritative)
- **Modify** `apps/ezagent_core/lib/ezagent_core/application.ex` — slot `Ezagent.SpawnRegistry.Tombstone.load_into_ets/0` call AFTER `Repo` migrate + BEFORE `Ezagent.KindSupervisor` boot
- **Modify** `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex` (the `:bind` action body) — populate `worker_uri` column on insert (B5)
- **Modify** `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex` — add `:scrub_owner` action (B3); update `actions/0` + `required_caps/0` + `invoke/4`
- `apps/ezagent_domain_identity/lib/ezagent_domain_identity/user_deletion_adapter.ex` (new)
- Tests: §5 invariant test + adapter unit tests + boundary-1 unit test (Kind.Server refuses tombstoned URI) + boundary-2 + boundary-3 + chat.scrub_owner unit test

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
| INV-13 | For the Session S created in setup with `owner_uri = target`: dispatch `Behavior.Chat.data_owner(S_uri)` returns `:no_owner` (not the deleted target URI), AND inspect S's live slice: `slice.owner_uri == nil` | B3 — Session owner not scrubbed via the new `:scrub_owner` action → deleted user still drives data_owner authz |
| INV-14 | For a token minted in setup for the target: `Token.verify(plain_token, target)` returns `{:error, :tombstoned}` (NOT `{:error, :invalid_credentials}` and NOT `{:ok, _}`) | B6 — token-row escapes cascade OR Token.verify lacks the tombstone defense check |

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

### OQ-8 — `external_mirror_bindings.worker_uri` NOT NULL timing (r2 — added)

The B5 fix adds `worker_uri` as `null: true` initially with a follow-up migration to set `NOT NULL` after backfill. Allen confirms the two-step is acceptable, OR prefers a single migration that requires a maintenance window with phx stopped? Default: two-step (greenfield deployments get NOT NULL immediately since they have no pre-existing rows; production-shaped deployments do backfill + flag).

---

## §11 Codex adversarial review questions (for r2)

1. **Multi-boundary tombstone enforcement (B1 verification):** the r2 fix installs the check at THREE boundaries (Kind.Server.init/1 authoritative + Kind.spawn/2 + SpawnRegistry.spawn/1). Trace every code path in the apps/ tree that culminates in a Kind being alive in memory. Is `Kind.Server.init/1` truly the only chokepoint every Kind start traverses, OR is there a path that constructs a `Kind.Server`-like GenServer without going through `init/1`? (Hot-takeover from another node? Direct `:proc_lib.start_link`? Some plugin custom DynamicSupervisor child_spec that doesn't use `Kind.Server`?) Find ANY bypass path that survives the r2 fix.

2. **Atomicity contract soundness (B2 verification):** `SpawnRegistry.tombstone_and_kill/1` performs (1) DB insert, (2) ETS insert, (3) brutal_kill + wait. The SPEC says "if step 2 fails, rollback step 1". But what if step 1 succeeds, step 2 succeeds, step 3 fails (e.g. the Kind's terminate/2 callback blocks indefinitely on some external IO)? The tombstone is now installed but the Kind is alive — does subsequent dispatch hit boundary 1 (the running Kind continues until next supervisor cycle restarts it, at which point init/1 refuses)? Walk through the failure modes; identify any state where the tombstone is half-installed.

3. **Session owner scrub well-defined (B3 verification):** the cascade dispatches `Behavior.Chat.invoke(:scrub_owner, ...)` against every live Session whose `owner_uri == target`. Three concerns:
   (a) Is the live-session lookup race-free? Between `KindRegistry.list_matching(scheme: "session")` and the per-session dispatch, a session Kind may die / be tombstoned. The SPEC says dispatch returns `{:noproc, :tombstoned}` are treated as success. Verify this is correct under all session-lifecycle states.
   (b) The new `:scrub_owner` Chat action has a `required_caps/0` shape. The cascade dispatches from the operator's caller_uri (which has `:delete` on EntityDeletion). Does the dispatch satisfy the `:scrub_owner` cap? Or do we need a system-principal cap injection? Trace the cap check path.
   (c) What about Sessions whose snapshot has stale `owner_uri = target` but are NOT in KindRegistry (cold-loaded later)? The SPEC argues they're safe because `Session.owner/1` returns an error path when the User URI is tombstoned — but verify this is actually how `Session.owner/1` resolves (or amend the SPEC if not).

4. **Worker cascade race-free (B5 verification):** the new `worker_uri` column is populated by `Behavior.ExternalMirror.invoke(:bind, ...)`. But what about Workers spawned via `AdapterInstall.reconcile_persisted_bindings/1` from pre-r2 rows whose `worker_uri` is NULL (during the backfill window)? Verify the backfill mix task is idempotent and that the cascade's `WHERE worker_uri = target` doesn't silently skip NULL rows that haven't been backfilled yet. Also verify the `NOT NULL` follow-up migration's pre-condition check.

5. **r2 contradictory text introduced?** (cap-vis r2 had bugs codex found — be careful) — Re-read §3, §10 RESOLVED, §11 of the r2 SPEC. Do any two statements about ordering, atomicity, or scope contradict each other? Specifically check: §3.3 atomic claim vs §3.9 concurrent-dispatch paragraph; §3.5 trace_id share vs §3.2 return-shape's `trace_id` field; §3.5 B5 paragraph vs §4.1 migration list.

6. **Bilingual lockstep maintained?** Verify the corresponding sections in `2026-05-28-entity-deletion.zh_cn.md` r2 reflect the same B1-B6 + N1-N3 resolutions. Specifically check that the §3.5 cascade tables match byte-for-byte (the cascade table is structural, not narrative).

7. **Plugin isolation tiebreaker check (post-r2):** the §6 table after r2 still claims plugin adapters never touch `SpawnRegistry.tombstone/1` directly. Verify: is there any code path where a DeletionAdapter (in domain or plugin layer) calls into the SpawnRegistry tombstone machinery NOT via `tombstone_and_kill/1`? If so, fix or rationalize.

8. **Entity_tokens defense-in-depth (B6 verification):** INV-14 asserts `Token.verify` rejects tombstoned URIs even if a row escapes the cascade. Verify the verify-side check is structurally placed (before bcrypt comparison? after? where in `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex:159-181` does the tombstone check belong?).

9. **LV confirm dialog UX (preserved from r1 q9):** PR-C admin LV adds a "Delete" button. The confirm dialog asks for a reason. Should we also require the operator to TYPE the URI being deleted (parity with GitHub's "type the repo name to delete")? Adds friction but prevents accidental misclicks. Default proposed: type-the-name confirmation for irreversible operations. Allen confirm?

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
  ▼ step 2 (THE atomic primitive — B2)
SpawnRegistry.tombstone_and_kill(target):
  │   - INSERT entity_tombstones row (DB)
  │   - :ets.insert(@tombstone_table, ...) (rollback DB on failure)
  │   - Process.exit(Kind pid, :brutal_kill)
  │   - wait for terminate to complete
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
  │   [B3: :scrub_session_owner_uri dispatches Chat.invoke(:scrub_owner, ...) per session]
  │   [B5: :drop_external_mirror_bindings uses WHERE worker_uri = target]
  │   [B6: :revoke_entity_tokens deletes from entity_tokens]
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
