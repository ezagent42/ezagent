# SPEC — Entity deletion lifecycle (User / Agent / Worker)

**Status:** r1 — DRAFT for codex adversarial-review. 2026-05-28.

**Tier:** `Ezagent.Behavior.EntityDeletion` (new) in `apps/ezagent_core/`, with per-entity-type `DeletionAdapter` modules in `apps/ezagent_domain_identity/` (User), `apps/ezagent_domain_chat/` (Agent), `apps/ezagent_domain_external_mirror/` (Worker). Admin LV integration in `apps/ezagent_plugin_liveview/`.

**Trigger:** Allen 2026-05-28 — after observing the `system/linyilun` ghost-user problem (deleted from DB + snapshot, but Kind keeps respawning, so the "deleted" user can still be addressed through LV / Feishu binding routing / dispatch). Allen's diagnosis: "should we add forced-logout at runtime, not just LV?".

**Companion:** `2026-05-28-entity-deletion.zh_cn.md` (per `feedback_bilingual_docs_convention`).

**Predecessor memories (load-bearing):**
- `feedback_let_it_crash_no_workarounds` — no shim, no dual-path. Deletion is atomic-cascade-or-explicit-failure. No "soft delete" with a flag (we considered + rejected in §7).
- `feedback_north_star_plugin_isolation` — the generic `EntityDeletion` Behavior lives in `ezagent_core`; per-entity-type cascade logic lives in its OWN domain app via the `DeletionAdapter` callback. Future entity types (Worker, Cap, Template — see §3.6) add via DeletionAdapter, never touch core.
- `feedback_completion_requires_invariant_test` — the merge gate is an invariant test that proves a deleted entity is unreachable through EVERY routing surface (KindRegistry, SpawnRegistry, LV mount, Feishu sender resolution, dispatch).
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
- `Ezagent.SpawnRegistry.spawn(uri)` returns `{:error, :not_found}` (NOT auto-creates)
- `Ezagent.KindRegistry.lookup(uri)` returns `:error`
- No Kind respawns from any path (snapshot, workspace member, Feishu binding, LV session cookie, dispatch from another agent's reply, …)
- `Workspace.list_workspaces_for/2` excludes them from every caller's view
- All historical references to the URI (sessions.owner_uri, caps.granted_by, audit rows) either point to a tombstone sentinel OR remain as historical record (caller's choice; see §3.7)

Today none of these are enforced as a unit. Each is a separate ad-hoc cleanup. Operators trying to "delete a user" follow no playbook; missing one step leaves a ghost.

### 1.3 Why "logout" is insufficient (Allen's framing refinement)

Allen's initial framing: "force runtime logout at User.Deletion". Logout-only is necessary-but-insufficient:

- Logout drops the LV/web session cookie → caller_uri becomes invalid for future requests
- But the Kind GenServer still alive in memory → other dispatches addressed at the URI succeed
- The Kind respawns on next lookup → logout would need to be repeated indefinitely

The structural fix is `EntityDeletion`: an atomic, audited, cascade operation that makes the URI **structurally unreachable** through every routing path — logout falls out as ONE consequence among many.

### 1.4 Bug class this prevents

- "I deleted user X but they can still send Feishu messages" (Feishu binding lookup hits a still-alive Kind)
- "I deleted user X but the session they own still routes to them" (sessions.owner_uri unscrubed)
- "I deleted agent Y but its cc bridge is still connected" (sidecar / PTY / bridge_registry entry orphaned)
- "I deleted a workspace but agents in it keep running" (workspace deletion did not cascade-delete agents)
- "I removed user X from workspace W but they can still see W in their dropdown" (caps not revoked)
- "On rare boot, deleted user X resurrects" (snapshot reload race + missing tombstone)

All six are observed or theoretically observable today. EntityDeletion + DeletionAdapter make every one a regression test.

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
2. **Runtime kill** — kill Kind GenServer, **set tombstone in SpawnRegistry** to prevent respawn (the missing piece today; see §3.3)
3. **Snapshot purge** — delete `kind_snapshots` row, audited
4. **DB cascade** — run `Adapter.cascade_steps/2` in order (each step idempotent + audited)
5. **Cross-reference scrub** — sessions.owner_uri / caps.granted_by / membership lists → tombstone sentinel
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
  audit_event_id: binary()
}}
| {:error, {:partial, %{
   step_failed: atom(),
   steps_completed: [atom()],
   reason: term(),
   recovery_hint: String.t()
}}}
| {:error, {:precheck_failed, term()}}
```

**Three return shapes** parallel the Generator-Reconciler three-arm (`:ok | :partial | :error`):

- `{:ok, summary}` — every cascade step completed, tombstone installed, audit emitted.
- `{:error, {:partial, _}}` — pre-check passed, runtime kill done, but at least one DB cascade step failed. The Kind is dead + tombstoned (cannot resurrect), but cross-reference scrub is incomplete. `recovery_hint` tells the operator which step + how to manually re-run.
- `{:error, {:precheck_failed, _}}` — no state was mutated. Adapter's `can_delete?/2` refused (e.g. bootstrap admin protection).

### 3.3 Step 2: Tombstone (the missing structural piece)

**This is the structural fix for the ghost-respawn problem.** Today's `SpawnRegistry` has no concept of "this URI is deleted; refuse to spawn". Anybody calling `SpawnRegistry.spawn(uri)` on a deleted URI gets a fresh Kind because the entity spawn fn (registered by chat / identity application) blindly creates one.

**EntityDeletion** introduces a `SpawnRegistry` tombstone:

```elixir
defmodule Ezagent.SpawnRegistry do
  # NEW API
  @spec tombstone(URI.t()) :: :ok
  def tombstone(uri), do: :ets.insert(@tombstone_table, {URI.to_string(uri), :tombstoned, DateTime.utc_now()})

  @spec tombstoned?(URI.t()) :: boolean()
  def tombstoned?(uri), do: :ets.member(@tombstone_table, URI.to_string(uri))

  # MODIFIED spawn — refuses tombstoned URIs
  def spawn(uri) do
    if tombstoned?(uri) do
      {:error, :tombstoned}
    else
      # ... existing scheme-dispatch logic ...
    end
  end
end
```

A tombstone is a one-bit "this URI is gone, do not resurrect" flag. Persisted in ETS owned by `EzagentCore.EtsOwner` (joins the other system tables it owns) + mirrored in a new `entity_tombstones` DB table at the same time the Kind is killed, so the tombstone survives BEAM restart.

`Adapter.cascade_steps/2`'s "kind_killed" step writes the ETS tombstone in the same atomic block as the brutal_kill. The `entity_tombstones` row write is committed before the kill completes (so even if BEAM crashes mid-delete, restart sees the tombstone and refuses to respawn).

Tombstones are append-only — there's no `untombstone/1`. To "reuse" a deleted URI, the operator must create a NEW entity at a different URI; the deleted one is permanently un-reusable. This is the structural cousin of "immutable identity" (see `feedback_uuid_is_canonical_identifier` analog: URI is the canonical identity; deletion is permanent).

### 3.4 Step 3: Snapshot purge

`kind_snapshots` row delete. Trivial, ordered AFTER tombstone (so if delete fails halfway, the snapshot points at nothing and tombstone refuses respawn — fail-safe; ghost cannot resurrect).

### 3.5 Step 4: Adapter cascade

`Adapter.cascade_steps/2` returns a `[{step_name, step_fn}]` ordered list. The Behavior iterates in order, applying each step. Each step is idempotent (re-running is a no-op if state already applied).

**User cascade** (`Ezagent.Domain.Identity.UserDeletionAdapter.cascade_steps/2`):

```
:revoke_all_caps               → Identity.revoke_all_caps(target_uri)
:drop_feishu_bindings          → delete feishu_user_bindings WHERE user_uri = target
:drop_entity_profile           → delete entity_profiles WHERE entity_uri = target
:drop_workspace_memberships    → Enum.each(workspaces, &Workspace.remove_member/2)
:drop_session_memberships      → Enum.each(sessions, &Chat.leave/2)
:scrub_owner_uri_to_tombstone  → UPDATE sessions SET owner_uri = '<deleted>' WHERE owner_uri = target
:delete_users_row              → Repo.delete(user)
```

**Agent cascade** (`Ezagent.Domain.Chat.AgentDeletionAdapter.cascade_steps/2`):

```
:stop_sidecars                 → flavor-specific (cc bridge / codex PTY+app-server / curl ...)
:unbind_bridge_registry        → BridgeRegistry.unbind(agent_uri)
:drop_session_memberships      → Enum.each(sessions, &Chat.leave/2)
:scrub_mention_routing_rules   → RoutingRules.remove_by_target(agent_uri)
:revoke_agent_api_keys         → AgentApiKeys.revoke_all(agent_uri)
:drop_agent_lineage            → AgentLineage.delete(agent_uri)
:delete_workspace_template     → Workspace.remove_template/3 (if registered)
```

**Worker cascade** (`Ezagent.Domain.ExternalMirror.WorkerDeletionAdapter.cascade_steps/2`):

```
:drop_external_mirror_bindings → delete external_mirror_bindings WHERE bound_by = target
:unsubscribe_session_publisher → Publisher.unsubscribe(target)
:terminate_adapter             → adapter_module.terminate(target)
```

Each step records to `invocations` audit before invoking the inner function (so partial-failure audit shows which step blew up). The audit row's `target` field is the deletion-target URI; the `caller` is the operator; the `action` is `entity.deleted.<step_name>`.

### 3.6 Future entity types

New `entity://<subscheme>/<workspace>/<name>` types add a `DeletionAdapter` implementation; no changes to `Behavior.EntityDeletion` or `SpawnRegistry`. Examples:

- `entity://tool/<workspace>/<name>` (hypothetical Tool entity): adapter scrubs ToolRegistry, drops permissions
- `entity://group/<workspace>/<name>` (hypothetical Group): adapter cascade-removes from member lists

The Behavior + Adapter contract is closed; the cascade vocabulary is open. Plugin authors writing a new domain follow the same shape they already know from AgentBridge.Adapter / Ezagent.Plugin.

### 3.7 Cross-reference scrub policy — tombstone-sentinel vs hard-delete

For historical references (audit rows, snapshots from other Kinds that mention the deleted URI, completed-session metadata), there are two cleanup policies:

**(a) Tombstone-sentinel** (default): rewrite the URI in historical rows to a static `entity://tombstone/deleted/<original_subscheme>` sentinel. Preserves audit trail (you can SEE that user X did things, just not WHO they were). Reversible-ish (the sentinel doesn't carry identity, but the row count is preserved).

**(b) Hard-delete**: delete every historical row that references the URI. Lighter on DB. Destroys audit history.

The cascade adapter chooses (a) or (b) per cross-reference table. The default is (a) for audit-bearing tables (`invocations`, `sessions.owner_uri`) and (b) for non-audit operational state (membership lists, registry entries).

§10 OQ-3 proposes a config knob to flip the default.

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

Between step 1 (pre-check) and step 5 (cross-ref scrub), the target Kind is in mid-tear-down. Dispatch attempts in this window have three outcomes:

- Dispatch to the dying Kind: `GenServer.call` blocks until terminate completes, then returns `{:error, :noproc}`. Acceptable — caller gets a clean error.
- Dispatch to a tombstoned-but-Kind-still-dying URI: `SpawnRegistry.spawn` refuses with `:tombstoned` before reaching the dead Kind. The lookup-then-call pattern (which most call sites use) handles this gracefully — the lookup either hits the dying Kind (case above) or the tombstone refuses re-spawn.
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
- `apps/ezagent_core/lib/ezagent/entity_deletion/tombstone.ex` (new) — ETS + DB store
- `apps/ezagent_core/priv/repo/migrations/<timestamp>_entity_tombstones.exs` (new) — DB table
- Modify `apps/ezagent_core/lib/ezagent/spawn_registry.ex` — add tombstone check at `spawn/1` entry
- `apps/ezagent_domain_identity/lib/ezagent_domain_identity/user_deletion_adapter.ex` (new)
- Tests: §5 invariant test + adapter unit tests

**PR-C admin LV integration**:

- Modify `users_live.ex` — add delete button + confirm dialog + reason input
- Modify `workspaces_live.ex` — add delete button (calls Workspace deletion → cascades to all members + templates + sessions)
- Modify `identities_live.ex` — add per-row delete action
- Modify `agent_detail_live.ex` — add delete action in agent detail page
- Add `mix ezagent.entity.delete <uri> --reason "<reason>"` CLI task

**PR-D Agent + Worker DeletionAdapter**:

- `apps/ezagent_domain_chat/lib/ezagent/domain/chat/agent_deletion_adapter.ex` (new)
- `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/worker_deletion_adapter.ex` (new)
- Per-flavor sidecar termination (cc / codex / echo / curl / np — each domain adds its own teardown)

### 4.2 Backwards compatibility

NO existing code path is removed. NO change to `Users.delete/1` semantics — that path still exists as the LOW-LEVEL DB-only delete, BUT will emit a deprecation warning suggesting `EntityDeletion.delete/3` instead. Migration target: in a follow-up PR-E, mark `Users.delete/1` as `@deprecated` and route operator-facing call sites through `EntityDeletion`.

Backfill for historical deletions: a `mix ezagent.entity.deletion.backfill_tombstones` mix task scans `kind_snapshots` for orphaned rows (a Kind URI with no corresponding `users` or `agents` row) and installs tombstones. Run once at deploy.

### 4.3 No DB migration for production data

`entity_tombstones` is a new table; no existing rows. No destructive schema change. Per `feedback_destructive_migration_anti_pattern` this is operator-runnable without phx restart.

### 4.4 Coordinated PR sequence

PR-A (this SPEC) lands first. Subsequent PRs (B/C/D) are dispatched as separate subagent runs, each merged independently with codex review. The Behavior + tombstone + UserDeletionAdapter (PR-B) is the **smallest viable shippable** — closes the User ghost problem. PR-C unlocks operator-facing UI; PR-D extends to Agent + Worker.

The plugin-isolation north-star is preserved: PR-B+ adds the contract; PR-C/D plug into it. Future entity types (Tool, Group, etc) add `DeletionAdapter`s without touching core.

---

## §5 Invariant test — the merge gate

Per `feedback_completion_requires_invariant_test`, this SPEC is "done" iff the test below passes AND would fail if any partial impl is shipped.

**File:** `apps/ezagent_core/test/invariants/entity_deletion_invariant_test.exs`

**Setup** (DataCase, `async: false`):

1. Create a non-admin User: `entity://user/team-alpha/test-deletable` via `Users.create/3`
2. Grant them caps + add to workspace + bind feishu open_id (so cross-references exist)
3. Spawn the User Kind: `SpawnRegistry.spawn("entity://user/team-alpha/test-deletable")` → `{:ok, pid}`
4. Call `Behavior.EntityDeletion.invoke(:delete, slice, %{target: target, reason: "test"}, %{caller: admin_uri, caps: admin_caps})`

**Assertions** (the test fails if ANY is violated):

| # | Assertion | What it catches |
|---|---|---|
| INV-1 | `KindRegistry.lookup(target)` returns `:error` immediately after delete | Kind not killed → ghost route alive |
| INV-2 | `SpawnRegistry.spawn(target)` returns `{:error, :tombstoned}` (NOT a fresh pid) | Tombstone missing or not enforced at spawn boundary → respawn ghost |
| INV-3 | `Users.get_by_uri(target)` returns `nil` | DB row leak |
| INV-4 | `Repo.get(EntityProfile, target_uri_str)` returns `nil` | Profile leak |
| INV-5 | `Repo.get(KindSnapshot, target_uri_str)` returns `nil` | Snapshot leak → resurrection on next boot |
| INV-6 | `Repo.all(from f in feishu_user_bindings, where f.user_uri == target)` returns `[]` | Feishu sender resolution → dead user |
| INV-7 | For every workspace W where target was a member: `target NOT IN W.member_uris` | Membership leak |
| INV-8 | For every session S where target was a member: `target NOT IN S.members` | Session membership leak (could re-resurrect Kind on `chat.join`) |
| INV-9 | `Workspace.list_workspaces_for(target, ...)` raises or returns `[]` (target itself is gone) | Visibility leak |
| INV-10 | An audit row exists: `invocations` with `action = "entity.deleted"`, `target = target_uri_str`, `caller = admin_uri_str`, AND every cascade step has a sub-row | Audit trail incomplete |
| INV-11 | Kill the BEAM (simulate restart via `Application.stop(:ezagent_core) + Application.start(:ezagent_core)`). After restart, INV-1 + INV-2 + INV-3 still hold | Tombstone DB persistence failed |
| INV-12 | `Behavior.EntityDeletion.invoke(:delete, ..., %{target: Ezagent.Entity.User.admin_uri()})` returns `{:error, :bootstrap_admin_undeletable}` | Bootstrap admin protection missing |

**Cannot pass with partial impl** — if any cascade step is skipped, the corresponding INV fails:

- Skip "kind_killed": INV-1 fails
- Skip "tombstone install": INV-2 fails
- Skip "snapshot purge": INV-5 + INV-11 fail
- Skip "users row delete": INV-3 fails
- Skip "feishu bindings drop": INV-6 fails
- Skip "memberships drop": INV-7 + INV-8 fail
- Skip "audit emit": INV-10 fails
- Skip "bootstrap protection": INV-12 fails

The test fails on the FIRST mismatch, with a message identifying the leak. Operators see the cascade-step name + the row that leaked.

---

## §6 Plugin isolation analysis

Per `feedback_north_star_plugin_isolation`, the architectural seam:

| Layer | Knows about | Does NOT know about |
|---|---|---|
| `ezagent_core` | `Behavior.EntityDeletion` action, `EntityDeletion.Adapter` behaviour, `SpawnRegistry.tombstone` | how to drop a Feishu binding, how to terminate a cc bridge, how to scrub session membership |
| `ezagent_domain_identity` | `UserDeletionAdapter` (User-specific cascade: caps, Feishu bindings, profile, memberships) | Agent or Worker cascade |
| `ezagent_domain_chat` | `AgentDeletionAdapter` (Agent-specific cascade: sidecars, bridge registry, lineage) | User or Worker cascade |
| `ezagent_plugin_codex` (etc) | how to stop ITS sidecar | how to terminate cc's sidecar |
| `ezagent_plugin_liveview` | how to render a "Delete" button + confirm dialog | the cascade semantics |

A future plugin author adding a new entity type (e.g. a hypothetical `entity://tool/...`) writes a `ToolDeletionAdapter` + registers it. **Zero changes to `ezagent_core`** required. This is the north-star applied to the deletion lifecycle.

Tiebreaker test ("keeps plugin authors out of core"): does `Behavior.EntityDeletion` expose internal cascade state to plugin code? Answer: NO. The Behavior calls `Adapter.cascade_steps/2` and gets back a list of `{step_name, function}`. The plugin's adapter never sees the deletion target's slice state, never sees other adapters' cascades, never touches the SpawnRegistry tombstone (the Behavior owns that). ✅

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

### 9.2 External callers

The `external_mirror_bindings` table's `bound_by` column references user URIs. If a bound user is deleted, the binding stays (don't cascade-delete bindings just because their creator was deleted; the binding may still be active). The `scrub_owner_uri_to_tombstone` adapter step rewrites `bound_by` to the tombstone sentinel — audit trail preserved.

No external HTTP / RPC / Phoenix.Channel consumer pattern-matches on identity-deletion behavior today; this SPEC introduces a NEW Phoenix.PubSub broadcast `{:entity_deleted, target_uri, reason}` for LV consumers (admin dashboard refreshes when a user is deleted).

### 9.3 Snapshots

Pre-SPEC snapshots that reference deleted entities are not auto-rewritten. Two paths:

- (a) On Kind boot, `Kind.Server.init/1` checks if the URI is tombstoned → refuse to boot; the snapshot row is then orphaned (operator can manually purge later)
- (b) The PR-A backfill mix task scans for orphaned snapshots + installs tombstones at deploy

(b) is the recommended path for pre-existing deployments.

### 9.4 Rollback plan

Deletion is **append-only**; there is no `undelete`. To "restore" an accidentally-deleted entity, the operator must:

1. Manually remove the tombstone row from `entity_tombstones` (admin-only SQL)
2. Manually re-create the user/agent/etc with the same URI (fresh entity, no history continuity)

This is intentional friction. SPEC documents it loudly. The LV confirm dialog warns "this is irreversible; the URI cannot be reused".

---

## §10 Open questions for Allen

### OQ-1 — tombstone TTL?

Tombstones in `entity_tombstones` are permanent by default. Should there be a TTL after which the URI becomes reusable? Default: NO (permanent), per `feedback_uuid_is_canonical_identifier` analog (immutable identity). Allen MAY override per-tenant if there's a real tenant lifecycle reason.

### OQ-2 — cascade ordering: kill before or after DB delete?

Today proposed: kill Kind FIRST, then DB. Rationale: if Kind is alive while DB row is gone, `Users.get_by_uri/1` returns nil → caller assumes user-not-found → caller may take action that conflicts with the still-alive Kind. Killing FIRST gives a brief window where "Kind is dying" before DB row is gone — clean error from dispatch (`{:error, :noproc}`). Allen confirm?

### OQ-3 — cross-reference scrub default

§3.7 lists tombstone-sentinel vs hard-delete. Default proposed: tombstone-sentinel for audit-bearing rows (preserve history), hard-delete for operational state. Allen confirm? Could also be per-tenant config.

### OQ-4 — Workspace deletion cascade

If a workspace is deleted, what happens to all entities within it? Two policies:

- (a) Recursive cascade: delete every entity in the workspace BEFORE deleting the workspace. Slow but complete.
- (b) Refuse-if-non-empty: workspace deletion errors if any entity remains. Operator must delete entities first.

Default proposed: (b). Workspace deletion errors with `:workspace_not_empty, [<entity_uris>]`. Allen MAY override to (a) for tenant offboarding scripts.

### OQ-5 — admin LV self-delete

§3.10 allows operator to delete themselves with a confirm dialog. Should self-delete be allowed at all? Some systems require a "second admin" to confirm self-deletion. Default: allowed with single confirm. Allen may want to gate behind a second-admin requirement.

### OQ-6 — Feishu binding cascade

When a user is deleted, their `feishu_user_bindings` rows are dropped (§3.5). But: in production, the user's Feishu open_id is still valid (they're still in Feishu the platform); their messages will start failing to resolve. Should the cascade attempt to re-bind the open_id to a fallback (e.g. `system/deleted` sentinel user) so messages get a clean "user deleted" reply? Default: drop binding entirely; Feishu messages from that open_id will get "no user found" at the routing layer (acceptable error). Allen MAY want the sentinel-rebind.

### OQ-7 — Tombstone DB table partitioning

`entity_tombstones` is one row per deleted URI. At scale (e.g. 10K tenants × 100 test users × delete cycles), the table grows. Should it be partitioned by workspace? Default: no, single table; revisit if performance issue. Documenting for future awareness.

---

## §11 Codex adversarial review questions (for r1)

1. **Tombstone enforcement at boot**: `SpawnRegistry.spawn/1` checks the tombstone. But what about a Kind that's already alive in memory at boot (e.g. loaded from snapshot) BEFORE the tombstone is checked? PR-A backfill mix task is supposed to handle pre-existing deployments — verify the ordering: backfill BEFORE first boot after deploy, OR boot-time check that aborts Kind boot if URI is tombstoned. Which is the structural answer?

2. **Race: deletion in progress + concurrent spawn**: `Behavior.EntityDeletion` kills the Kind THEN installs the tombstone. Between these two steps, a concurrent `SpawnRegistry.spawn(uri)` call finds the Kind dead → spawn fn creates a fresh Kind → tombstone install fails because Kind is alive again. Need to install tombstone FIRST (atomic with Kind kill via `SpawnRegistry.tombstone_and_kill/1`?). Verify §3.3's proposed sequence is race-free.

3. **Cross-Kind scrub during deletion**: when scrubbing `sessions.owner_uri = deleted_user`, the Session Kind is alive in memory with `owner_uri` field. Two paths:
   - Scrub the DB row + send a Session message that updates the slice
   - Skip the DB scrub for live Sessions (the Session's terminate/snapshot will eventually mirror DB)
   
   Which is correct? If DB and live slice diverge briefly, do other dispatches care?

4. **Adapter capability boundary**: `Adapter.can_delete?/2` checks per-adapter business rules. But the cap check at `Behavior.EntityDeletion.invoke(:delete, ...)` already enforces the `:delete` cap. Are these two checks redundant? Or is `can_delete?/2` strictly the cascade-feasibility check (e.g. "this user owns a session that has unfinished work; refuse")? Clarify the contract.

5. **Audit row volume**: every cascade step emits an audit row. For a User with 10 workspaces + 50 sessions, that's 60+ audit rows per delete. Is that OK, or should the Behavior emit a SINGLE audit row with a list of cascade results? Tradeoff: per-step rows = granular debugging; single row = less audit noise. Allen MAY prefer aggregated.

6. **Workspace deletion cascade depth**: §10 OQ-4 covers the policy choice. For (b) refuse-if-non-empty, the workspace delete checks `member_uris == []` + `session_templates == {}` + (any other workspace-owned state). Verify the check is COMPLETE — list every workspace-owned table.

7. **Tombstone DB migration safety**: adding `entity_tombstones` table is a forward-only schema change. Verify: NO existing code path reads or writes this table; it's truly new. Greenfield migration is safe.

8. **Plugin isolation tiebreaker check**: a future plugin author writing a `Tool` entity with `entity://tool/...` URIs adds a `ToolDeletionAdapter`. Trace what they need to know about `ezagent_core`. Should be: `Ezagent.Behavior.EntityDeletion`, `Ezagent.EntityDeletion.Adapter` behaviour, the cascade-step contract. NOTHING ELSE. Verify they don't need to know about SpawnRegistry tombstone internals.

9. **LV confirm dialog UX**: PR-C admin LV adds a "Delete" button. The confirm dialog asks for a reason. Should we also require the operator to TYPE the URI being deleted (parity with GitHub's "type the repo name to delete")? Adds friction but prevents accidental misclicks. Default proposed: type-the-name confirmation for irreversible operations. Allen confirm?

10. **bilingual sync**: en + zh_cn lockstep enforced — verify §3 / §5 / §10 are content-aligned and that the cascade table at §3.5 is byte-identical in both files (the table is structurally meaningful, not narrative).

---

## §12 Rollback plan

This SPEC's impl is forward-only (no rollback of an applied deletion). Rollback of the SPEC ITSELF (revert PR-A → PR-B → ...):

1. Revert the merge commits in reverse order
2. The `entity_tombstones` table remains in DB (orphaned, no code reads it)
3. Operators who had relied on `Behavior.EntityDeletion` lose access; manual SQL delete is the fallback again
4. Pre-existing tombstones remain inert (no enforcement until the SPEC is re-applied)

The DB schema addition is non-destructive; rolling back is safe at any time. The deletion semantics LOSS is acceptable (operators revert to today's manual workflow).

---

## Appendix A — Sequence diagram

```
Operator (admin LV)
  │ click "Delete" + type reason + confirm
  ▼
Behavior.EntityDeletion.invoke(:delete, slice, %{target, reason}, ctx)
  │ step 5.5 CapBAC: caller has :delete cap?  → audit "granted"
  │
  ▼ step 1
Adapter.can_delete?(target, ctx)
  │ adapter-specific pre-check
  ▼ :ok or {:error, :precheck_failed_reason}
  │
  ▼ step 2 (atomic)
SpawnRegistry.tombstone_and_kill(target):
  │   - INSERT entity_tombstones row
  │   - :ets.insert(@tombstone_table, ...)
  │   - Process.exit(Kind pid, :brutal_kill)
  │   - wait for terminate to complete
  ▼ tombstone installed; Kind dead; respawn refused
  │
  ▼ step 3
delete kind_snapshots row
  │
  ▼ step 4 (iterated via Adapter.cascade_steps/2)
for each {step_name, step_fn} in adapter steps:
  │   audit "cascade.<step_name>.start"
  │   step_fn.()
  │   audit "cascade.<step_name>.complete"
  ▼
  │
  ▼ step 5 (audit emit)
audit "entity.deleted" {target, caller, reason, steps_completed, summary}
  │
  ▼ step 6 (broadcast)
Phoenix.PubSub.broadcast(@entity_deletion_topic, {:entity_deleted, target, reason})
  │
  ▼
{:ok, %{deleted_uri, steps_completed, cascade_summary, audit_event_id}}
```

## Appendix B — Why this SPEC is longer than the others

It introduces TWO new structures (Behavior + Adapter + tombstone + cascade contract), each with its own semantics. The cascade tables in §3.5 are exhaustive; the INV table in §5 is 12 entries (every leak vector); the OQ list in §10 is 7 (each is a real product decision Allen could override). Compared to URI canonicalization (which is 1 structure with 5 phases), EntityDeletion has more surface — hence the length.

## Appendix C — Author's recommendation

Land PR-A (this SPEC) + PR-B (Behavior + UserDeletionAdapter) as ONE pair. PR-C (admin LV) + PR-D (Agent + Worker adapters) can be parallelized — they're independent. The 4-PR sequence shouldn't take longer than 1.5 days end-to-end at the cap-vis / URI-canonical rhythm.

The `system/linyilun` ghost — surfaced 2026-05-28 — is the empirical motivation. After PR-B lands + operator runs the backfill mix task, the ghost is structurally impossible.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
