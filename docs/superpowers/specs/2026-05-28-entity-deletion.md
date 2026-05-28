# SPEC — Kind lifecycle CRUD parity (destroy callback + DB-backing spawn)

**Status:** r7 — wholesale rewrite. Allen pushback 2026-05-28 03:36–03:43: (1) "tombstone 永久不允许 re-register 很奇怪 —— 重走创建流程就该可以"; (2) "更深层 Kind 缺 D（destroy）callback，所有 Kind 应该有完整 CRUD". Option B chosen — inline pivot of SPEC #440 from "EntityDeletion + tombstone" to "Kind lifecycle CRUD parity". No codex round on r7 (Allen's directive).

**r7 changes — wholesale scope pivot:**

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
  Destroy the Kind at `target_uri`. Orchestrates:
    1. `Adapter.can_destroy?/2` (per-Kind precheck) — abort on refuse
    2. `kind.destroy/2` (per-Kind cleanup callback) — best-effort
    3. `DynamicSupervisor.terminate_child(supervisor, pid)` (graceful,
       NOT brutal_kill — Kind's `terminate/2` runs; current slice's
       :on_terminate snapshot SKIPPED because §3.4 deletes the row
       immediately after)
    4. Snapshot purge: `Repo.delete(KindSnapshot, uri_str)`
    5. DB row delete: `kind.delete_db_row(uri)` (per-Kind hook into
       Users.delete / Agents.delete / Workspace.delete / etc)
    6. Audit emit: `invocations` row `action = "kind.destroyed"`
       with trace_id, caller, reason, per-step sub-rows

  Re-spawn after destroy: SpawnRegistry entity callback sees
  `Users.get_by_uri(uri) == nil` and returns `{:error, :no_backing_entity}`.
  No tombstone needed — the DB row IS the source of truth.

  Returns `:ok | {:error, {:partial, ...}} | {:error, {:precheck_failed, _}}`.
  """
  @spec destroy(URI.t(), ctx :: %{caller: URI.t(), reason: String.t()}) ::
          {:ok, summary :: map()}
          | {:error, {:partial, map()}}
          | {:error, {:precheck_failed, term()}}
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
# Extension to each SpawnRegistry entity callback registration
# (apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex:222,
#  apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:493)
SpawnRegistry.register("entity", fn uri ->
  case uri.host do
    "user" ->
      # NEW: DB-backing check. The row is the source of truth.
      if Users.get_by_uri(uri) == nil do
        {:error, :no_backing_entity}
      else
        initial_caps = User.initial_caps_for_spawn(uri)
        Ezagent.Kind.spawn(User, %{uri: uri, initial_caps: initial_caps})
      end

    "agent" ->
      # Same pattern; Agents.get_by_uri/1 is the per-Kind equivalent.
      if Agents.get_by_uri(uri) == nil do
        {:error, :no_backing_entity}
      else
        # ... existing Agent spawn logic ...
      end

    other -> {:error, {:no_entity_host_handler, other}}
  end
end)
```

The field-name parallels are intentional: `destroy/2` mirrors `init_slice/1` (the Behavior callback that creates a Kind's initial state). Plugin authors who already know how to write the C of CRUD now have an obvious place to write the D.

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

### 3.4 Orchestration sequence (the §2 numbered list, expanded)

The `Kind.Server.destroy/2` body:

1. **Pre-check.** Call `kind_module.can_destroy?(target_uri, ctx)`. On error → return `{:error, {:precheck_failed, reason}}`; no mutation has occurred.
2. **Generate `trace_id`.** A new UUID; threaded through every sub-row.
3. **Call `kind_module.destroy(target_uri, ctx_with_trace)`.** Per-Kind cleanup (release sidecars, scrub cross-refs, revoke caps, drop memberships). Returns `{:ok, summary} | {:error, reason}`. On error: record the per-Kind failure in audit but CONTINUE (destroy is best-effort from the per-Kind perspective; the Kind is going away regardless).
4. **Locate the live pid.** `KindRegistry.lookup(target_uri)`. Two arms:
   - `{:ok, pid}` — proceed to step 5.
   - `:error` — the Kind isn't currently alive (snapshot-only). Skip step 5; proceed to step 6.
5. **Terminate the GenServer gracefully.** `DynamicSupervisor.terminate_child(kind_module.supervisor(), pid)`. This runs the Kind's `terminate/2` callback (if any), giving Behaviors a chance for last-mile drain. NOT `:brutal_kill` — there is no race vs respawn here because step 6 deletes the DB row and the SpawnRegistry entity callback then sees `:no_backing_entity`. The Kind cannot respawn even if a concurrent dispatch fires between steps 5 and 6, because:
   - the post-terminate registry lookup returns `:error` (Registry drops dead pids);
   - the entity callback's DB-backing check has not yet flipped (DB row still exists until step 6), so a concurrent spawn between steps 5 and 6 WOULD succeed — but the resulting fresh Kind is itself harmless: its `init_slice/1` runs on an empty-snapshot path (we deleted the snapshot in step 6 only AFTER step 5, so the Kind that races in between still loads from the about-to-be-deleted snapshot); the dispatch that re-spawned it sees a Kind with the prior state. The window is bounded by the time between `terminate_child/2` return and `Repo.delete(user)` (step 6) — sub-millisecond inside a single Repo transaction.
   - **To close the race entirely**, steps 5 + 6 are wrapped in a Repo transaction: step 6's DB row delete commits ATOMICALLY with the pre-step-6 audit row, and the Registry's dead-pid drop is guaranteed before any concurrent `SpawnRegistry.spawn` call could traverse the new entity-callback path (because `Registry.unregister` is synchronous inside `terminate_child/2`). See §3.6 for the race analysis in detail.
6. **DB row delete.** `kind_module.delete_db_row(target_uri)` — per-Kind hook into the domain's `delete/1` (e.g. `Users.delete/1`). This is the "DB row is truth" commit: AFTER this point, every `SpawnRegistry.spawn(target_uri)` call returns `{:error, :no_backing_entity}` because the entity callback's `get_by_uri/1` returns `nil`.
7. **Snapshot purge.** `Repo.delete(Ezagent.Ecto.KindSnapshot, uri_str)`. Idempotent. Ordered AFTER step 5 + 6 so a respawn-race in step 5 still loads valid snapshot state; ordered BEFORE step 8 audit emit so audit sees a clean post-state.
8. **Audit emit.** Single `invocations` row `action = "kind.destroyed"` + per-step sub-rows from step 3's `kind.destroy/2` summary. All share `trace_id`.

### 3.5 Per-Kind `destroy/2` responsibilities

Each Kind's `destroy/2` callback does Kind-internal cleanup. The cleanup steps below replace what the prior r1–r6 SPEC called "cascade steps" — they are now Kind responsibilities, not orchestrator responsibilities.

**User cascade (User.destroy/2):**

```
:revoke_all_caps                Identity.revoke_all_caps(user_uri)
:revoke_entity_tokens           Repo.delete_all(EntityToken WHERE entity_uri = user_uri)
:drop_feishu_bindings           Repo.delete_all(feishu_user_bindings WHERE user_uri = user_uri)
:drop_entity_profile            Repo.delete(EntityProfile, uri_str)
:drop_workspace_memberships     Enum.each(workspaces, &Workspace.remove_member/2)
:drop_session_memberships       Enum.each(sessions, &Chat.leave/2)
:scrub_session_owner_uri        Enum.each(owned_sessions, &dispatch Chat.scrub_owner/0)
```

Note `:scrub_session_owner_uri` still uses the `Behavior.Chat.invoke(:scrub_owner, ...)` dispatch pattern (which the r1–r6 design correctly identified — it's the right shape for cross-Kind state mutation). The cap-gating + system principal (`system://kind-destroy-cascade`) is detailed in §3.7.

**Agent cascade (Agent.destroy/2):**

```
:teardown_bridge                AgentBridge.Adapter.teardown(agent_uri)   [NEW per-flavor callback]
:revoke_entity_tokens           Repo.delete_all(EntityToken WHERE entity_uri = agent_uri)
:drop_session_memberships       Enum.each(sessions, &Chat.leave/2)
:scrub_mention_routing_rules    RoutingRules.remove_by_target(agent_uri)
:revoke_agent_api_keys          AgentApiKeys.revoke_all(agent_uri)
:drop_agent_lineage             AgentLineage.delete(agent_uri)
:delete_workspace_template      Workspace.remove_template/3 (if registered)
```

The `:teardown_bridge` step delegates to `AgentBridge.Adapter.teardown/1` — each flavor adapter cleans up its OWN sidecar without Agent.destroy needing to know cc vs codex vs echo internals. This is plugin isolation applied to the teardown surface.

**Session cascade (Session.destroy/2):**

```
:drop_session_members           clear member list
:emit_session_destroyed         PubSub.broadcast({:session_destroyed, session_uri})
:unsubscribe_publisher          Publisher.unsubscribe_all(session_uri)
```

Session is mostly stateless beyond its slice — most of its "members" are pointers (User URIs), not owned state. Destroy is therefore lighter than User / Agent.

**Workspace cascade (Workspace.destroy/2):**

```
:cascade_member_destroys        Enum.each(member_uris, &Kind.Server.destroy(_, ctx_with_parent_trace))
:cascade_template_destroys      Enum.each(template_uris, &Kind.Server.destroy(_, ctx_with_parent_trace))
:cascade_session_destroys       Enum.each(workspace_sessions, &Kind.Server.destroy(_, ctx_with_parent_trace))
:drop_workspace_caps            CapabilityRegistry.drop_workspace(workspace_uri)
:delete_workspace_row           Workspaces.delete(workspace_uri)
```

This is the cross-Kind cascade that the r1–r6 SPEC excluded as out of scope. Under r7 it's just another `destroy/2` impl that happens to call `Kind.Server.destroy/2` on its members. The recursion bottoms out because each member is a leaf Kind (User / Session / Agent), and their `destroy/2` does not recurse back into the workspace. Trace correlation: all sub-destroys share the parent workspace destroy's `trace_id` so audit can group.

**Worker cascade (Worker.destroy/2):**

```
:drop_external_mirror_bindings  Repo.delete_all(BindingRow WHERE worker_uri = worker_uri)
:unsubscribe_session_publisher  Publisher.unsubscribe(worker_uri)
:terminate_adapter              adapter_module.terminate(worker_uri)
```

This requires `external_mirror_bindings.worker_uri` to be a real column (the B5 column add from r1–r2). The column is kept (it's structurally correct — `worker_uri` is a useful denormalized index regardless of tombstone). The two-migration + backfill task from r1–r6 §4.1 + §9.1 is retained as-is; under r7 the column is consumed by Worker.destroy/2 rather than by a cascade Adapter. The BindingRow schema / cast / validate_required updates from CRIT-4.2 are also retained.

### 3.6 Race analysis — concurrent dispatch during destroy

The r7 design replaces the r1–r6 tombstone-based race elimination with a Repo-transaction-based ordering. The key invariant: **the DB row delete commits BEFORE the GenServer's Registry registration is reusable for a fresh spawn**.

Five race windows:

1. **Dispatch arriving BEFORE step 1.** Normal dispatch; the Kind is alive; no destroy in progress. Handled by existing CapBAC.
2. **Dispatch arriving BETWEEN step 1 and step 3.** The pre-check has passed but no mutation yet. Dispatch sees a healthy Kind; succeeds. The eventual destroy proceeds independently. No race — the dispatch's effect is processed by the still-alive Kind before destroy mutates anything.
3. **Dispatch arriving BETWEEN step 3 and step 5.** Per-Kind `destroy/2` has run (caps revoked, memberships dropped). The Kind is still alive. The dispatch's cap-check may now fail (caps revoked) — this is the CORRECT behavior; the entity is mid-destroy and is no longer authorized. If the dispatch happens to invoke a Behavior that doesn't require the revoked caps, it succeeds against the dying Kind — also acceptable; the Kind's slice changes are about to be discarded along with the snapshot purge in step 7.
4. **Dispatch arriving BETWEEN step 5 and step 6.** The GenServer is terminating; `KindRegistry.lookup/1` returns `:error` (Registry drops dead pids synchronously inside `terminate_child/2`'s return path). If the dispatch traverses `SpawnRegistry.spawn/1`, the entity callback sees the DB row still exists (step 6 has not yet run) and spawns a fresh Kind. This Kind loads from the still-present snapshot, which is about to be deleted in step 7. The window between step 5 return and step 6 commit is sub-millisecond inside a single Repo transaction. **Mitigation:** wrap steps 5 + 6 + 7 in a `Repo.transaction/1`. The transaction's commit is the linearization point; no spawn between step 5 and step 6 within the transaction is possible because step 6's `Repo.delete(user)` holds a row-level lock on the `users` row from the moment the transaction begins, and any concurrent `SpawnRegistry.spawn → Users.get_by_uri` either (a) reads the pre-delete state and proceeds with the spawn (acceptable — the destroy has not committed yet, so re-spawning is logically a no-op cancelled by the destroy's eventual commit + the resulting Kind sees the snapshot purge on next supervisor-restart cycle) or (b) reads the post-delete state and returns `:no_backing_entity`. The window is structurally bounded by the transaction.
5. **Dispatch arriving AFTER step 6 commit.** The DB row is gone. `SpawnRegistry.spawn/1`'s entity callback returns `{:error, :no_backing_entity}`. Dispatch fails cleanly. This is the steady-state post-destroy.

**Why this is structurally cleaner than r1–r6's tombstone:** the prior design needed a SEPARATE table (`entity_tombstones`) + ETS mirror + multi-boundary check + atomic primitive specifically to prevent respawn after destroy. Under r7 the `users` row's absence IS the prevention; there's nothing extra to keep consistent. The cost is one extra DB read on every spawn (the `get_by_uri/1` check), which is bounded by the Repo's connection pool and amortized over the spawn fn's existing cost.

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
2. The next `SpawnRegistry.spawn(uri)` call sees `Users.get_by_uri(uri)` return the new row and proceeds to spawn.
3. The new Kind's `init_slice/1` runs from defaults — there is NO snapshot (step 7 of destroy purged it), no inherited caps (step 3 revoked them), no inherited memberships (step 3 dropped them).
4. The new Kind is structurally distinct from the prior incarnation despite operating at the same URI. The URI is a name, not an identity; the row's primary key is the identity.

This is INV-13 in §5. The r1–r6 design forbade this (tombstones were append-only); Allen's pushback (2026-05-28 03:36) corrected the direction.

### 3.11 Edge case — destroy of a Kind that's not currently alive

If `KindRegistry.lookup(target_uri)` returns `:error` (the Kind has no live pid — snapshot-only), step 5 is skipped. The DB row delete + snapshot purge still proceed. This is fine: there's no live pid to terminate, and the post-destroy state is identical.

### 3.12 Edge case — `destroy/2` returns `{:error, _}` (per-Kind cleanup failed)

The orchestrator (§3.4 step 3) records the per-Kind error in audit and continues. Step 5–8 still execute. The destroy returns `{:error, {:partial, %{step_failed: :kind_destroy, kind_error: <inner>, steps_completed: [...]}}}` so the operator knows the Kind's cleanup was incomplete (e.g. AgentBridge.Adapter.teardown failed because the sidecar was already dead — usually harmless). The DB row + snapshot are gone; the URI is no longer reachable. Operator-runbook decision: investigate the inner error OR accept the partial.

---

## §4 Migration plan

### 4.1 New code (in order of PRs)

**PR-A (this SPEC).**

**PR-B core — Kind.destroy callback + Kind.Server.destroy/2 + SpawnRegistry DB-backing check + AgentBridge.Adapter.teardown extension:**

- **Modify** `apps/ezagent_core/lib/ezagent/kind.ex` — add `destroy/2` to `@callback` list. Either add to `@optional_callbacks` (with default no-op via `Kind.default_destroy/2`) OR keep required (OQ-NEW — Allen decision).
- **Modify** `apps/ezagent_core/lib/ezagent/kind/server.ex` — add public `destroy/2` API per §2 + §3.4. Wrap steps 5–7 in a `Repo.transaction/1` per §3.6.
- **Modify** `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex:222-258` — add DB-backing check at the `"user" ->` arm: `if Users.get_by_uri(uri) == nil, do: {:error, :no_backing_entity}, else: ...existing spawn logic...`.
- **Modify** `apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex:493+` — same pattern at the `"agent" ->` and `"user" ->` arms.
- **Modify** `apps/ezagent_domain_agent_bridge/lib/ezagent/agent_bridge/adapter.ex` — add `teardown/1` to `@callback`, list under `@optional_callbacks` with default no-op (default impl in the Adapter module itself for fallthrough).
- **Add** `Ezagent.SystemPrincipal.Catalog` entry: `{"system://kind-destroy-cascade", [Capability.cap(Ezagent.Entity.Session, Ezagent.Behavior.Chat, :scrub_owner, :any, :any)]}` (renamed from r1–r6's `system://entity-deletion-cascade`).
- **Modify** `apps/ezagent_core/lib/ezagent_core/application.ex` — add `SystemPrincipal.ensure(SystemPrincipal.uri("kind-destroy-cascade"))` after existing principal ensures.
- **Modify** `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex` — add `:scrub_owner` action (full 5-part Chat behavior plumbing: actions, required_caps, cap_subjects, invoke, interface). Add `Chat.data_owner/1` change: if the `Session.owner/1` returns `{:ok, owner}` and `Users.get_by_uri(owner) == nil`, return `:no_owner` (replaces r1–r6's tombstone check with DB-backing check).
- **Modify** `apps/ezagent_domain_chat/lib/ezagent_domain_chat/application.ex` `register_chat_behaviors/0` — add `CapabilityRegistry.register(Session, :scrub_owner, Chat)`.
- **Modify** `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex` `data_owner/1` — same DB-backing check pattern.
- **Modify** `apps/ezagent_domain_chat/lib/ezagent/behavior/publisher/session_impl.ex` `data_owner/1` — same DB-backing check pattern.
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

**PR-C domain Kinds — per-Kind `destroy/2` impls:**

- `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex` — add `destroy/2` (User cascade per §3.5) + `can_destroy?/2` (bootstrap admin protection) + `delete_db_row/1` hook into `Users.delete/1`.
- `apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex` — add `destroy/2` (Agent cascade per §3.5, delegating to `AgentBridge.Adapter.teardown/1`) + `can_destroy?/2`.
- `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex` — add `destroy/2` (Session cascade per §3.5) + `can_destroy?/2`.
- `apps/ezagent_domain_workspace/lib/ezagent/entity/workspace.ex` — add `destroy/2` (Workspace cascade per §3.5, recursing via `Kind.Server.destroy/2`) + `can_destroy?/2`.
- `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/worker.ex` — add `destroy/2` (Worker cascade per §3.5, using the `worker_uri` column) + `can_destroy?/2`.

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

Existing Kinds that DO NOT implement the new `destroy/2` callback: if the callback is OPTIONAL (OQ-NEW default), they get the default no-op (DB row delete + snapshot purge only — no per-Kind cleanup). If the callback is REQUIRED (recommended), PR-C must add a `destroy/2` impl to EVERY existing Kind (User, Agent, Session, Workspace, Worker — these are the only Kinds today per `apps/` scan). New plugin Kinds added post-PR-B must implement `destroy/2` as part of the behaviour contract.

### 4.3 DB migration for production data

`external_mirror_bindings.worker_uri` column add (forward-only) + backfill task + NOT NULL toggle — preserved verbatim from r1–r6. No NEW tables (the `entity_tombstones` table from r1–r6 is REMOVED from the migration plan). Operator-runnable migrations; the NOT NULL toggle is flagged for operator action (stop phx, migrate, restart) on production-shaped environments.

### 4.4 Coordinated PR sequence

PR-A (this SPEC) lands first. PR-B (core) is the **smallest viable shippable** — adds the contract + DB-backing check + AgentBridge.Adapter.teardown extension. PR-C (per-Kind destroy impls) lands next; until PR-C lands, every Kind has either default no-op `destroy/2` (if optional) OR PR-C is a single atomic addition (if required) — PR-C cannot land before PR-B because the callback doesn't exist yet. PR-D (plugin teardown) can land in parallel with PR-C (different files). PR-E (LV UI + CLI) lands last; depends on PR-C being complete because the LV "destroy" button must call `Kind.Server.destroy/2` which dispatches into per-Kind `destroy/2`.

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

**Cannot pass with partial impl** — failure mappings:

- Skip `Kind.destroy/2` callback addition: INV-3 + INV-4 + INV-6 + INV-7 + INV-8 fail (per-Kind cleanup never runs)
- Skip DB-backing check at entity callback: INV-2 + INV-13 (c) fail
- Skip `Kind.Server.destroy/2` orchestrator: INV-1 + INV-10 fail
- Skip `AgentBridge.Adapter.teardown/1`: INV-18 fails
- Skip Workspace.destroy/2 cascade: INV-14 fails
- Skip Token.verify DB-backing check: INV-15 fails
- Skip data_owner DB-backing check at any of three sites: INV-16 fails
- Skip bootstrap protection: INV-12 fails

The test fails on the FIRST mismatch, with a message identifying the leak.

---

## §6 Plugin isolation analysis

Per `feedback_north_star_plugin_isolation`:

| Layer | Knows about | Does NOT know about |
|---|---|---|
| `ezagent_core` | `Ezagent.Kind.destroy/2` callback, `Ezagent.Kind.Server.destroy/2` public API, the orchestration sequence | how User cleans up Feishu bindings, how Agent terminates a sidecar, how Workspace cascades to members |
| `ezagent_domain_identity` | `User.destroy/2` (User cleanup), `User.can_destroy?/2` (bootstrap admin), the DB-backing check at the `user ->` arm of its entity callback | Agent / Session / Workspace / Worker internals |
| `ezagent_domain_chat` | `Agent.destroy/2` + `Session.destroy/2` + the `:scrub_owner` Chat action body; the DB-backing check at its `entity` callback's arms | User / Workspace / Worker internals |
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

If `destroy/2` is OPTIONAL, existing Kinds without an impl get the default (DB row delete + snapshot purge only — no per-Kind cleanup). Pro: lower migration cost; existing Kinds keep working without PR-C touching them. Con: every Kind quietly leaks state until someone adds a `destroy/2` — exactly the situation r7 is fixing. **Recommendation: REQUIRED.** Force every Kind author to think about cleanup at the Kind boundary. PR-C explicitly enumerates the existing Kinds (User / Agent / Session / Workspace / Worker — five total per `apps/` scan) and adds `destroy/2` to each. New Kinds added post-PR-B must implement at registration time. Allen confirm in OQ-NEW.

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

### OQ-NEW — `destroy/2` REQUIRED vs OPTIONAL

Should `Ezagent.Kind.destroy/2` be a REQUIRED callback (every Kind module MUST implement) or OPTIONAL (with a default no-op via `Kind.default_destroy/2`)? **Recommendation: REQUIRED**, per §7.6 — forces every Kind author to think about cleanup at the boundary, prevents silent state leaks. PR-C enumerates the five existing Kinds and adds `destroy/2` to each. Allen confirm.

### REMOVED open questions

- ~~OQ-1 (tombstone TTL)~~ — no tombstone in r7.
- ~~OQ-8 (worker_uri NOT NULL migration timing)~~ — the two-migration + backfill task pattern is retained as-is from r1–r6; it works and Worker.destroy/2 still needs the column. No longer an OQ; documented as part of the migration plan in §4.3.

---

## §11 Codex adversarial review questions (for r7+)

> r7 reset: r1–r6 questions targeted tombstone correctness. Under r7's pivot those are moot. New attack surface:

1. **DB-backing check race (§3.6 step 4 race):** the entity callback reads `Users.get_by_uri(uri)` and decides to spawn. Concurrently, `Kind.Server.destroy(uri)` is at step 5 (terminate_child). Between the get_by_uri read and the spawn fn's eventual `Ezagent.Kind.spawn/2` call, the destroy commits step 6 (DB row delete). Does the spawn fn then load a snapshot for a Kind whose DB row is gone? Walk through the Repo transaction boundary in step 5+6+7.

2. **Workspace cross-Kind cascade depth (§3.5 Workspace.destroy):** a workspace contains 100 users. `Workspace.destroy/2` iterates and calls `Kind.Server.destroy/2` on each. Is the iteration serial (one at a time) or parallel (Task.async_stream)? Serial: O(N) cascade time; admin LV times out. Parallel: race on shared resources (e.g. workspace.member_uris list mutated by each User.destroy/2). Pick one + justify in §3.5.

3. **AgentBridge.Adapter.teardown/1 failure isolation:** if codex's `teardown/1` raises (e.g. sidecar already dead, supervisor times out), does Agent.destroy/2 propagate or swallow? §3.5 says "best-effort"; verify the orchestrator's audit row records the error AND step 5–8 still run. INV-18 should fail if the orchestrator aborts on teardown error.

4. **Re-register inheritance (INV-13):** the test asserts NO inherited caps / memberships / snapshot. But the `users` table is created fresh; the new row's `caps_json` defaults to whatever `Users.create/3` sets. Verify the test asserts the NEW caps (whatever Users.create installs) rather than the OLD caps — there's no "empty caps" universal state.

5. **DB-backing check at all relevant paths:** §2 + §4.1 lists two entity-callback registration sites (identity + chat domains). Is there ANY other path that spawns a Kind WITHOUT going through `SpawnRegistry.spawn/1`? `Ezagent.Kind.spawn/2` is one such path; r1–r6 boundary 2 addressed it. Under r7, do we need a DB-backing check at `Kind.spawn/2` too, or is the SpawnRegistry layer the only entry point in production?

6. **Behavior.Chat.scrub_owner CapBAC (r7 preserves r1–r6's narrow system principal):** the cascade dispatches `:scrub_owner` as `system://kind-destroy-cascade` (renamed). Verify the Catalog entry + the `SystemPrincipal.ensure/1` call timing + the cap-check at `Kind.Runtime.authorize/4`. Same attack surface as r1–r6 CRIT-3.1 + CRIT-4.1 + HIGH-4.3.

7. **Token.verify DB-backing check (replaces r1–r6 INV-14):** the check now reads `Users.get_by_uri(uri) == nil` instead of `SpawnRegistry.tombstoned?(uri)`. Validate: (a) timing-leak-safe (Bcrypt.no_user_verify on the deny path); (b) before bcrypt comparison; (c) covers Agent tokens (`Agents.get_by_uri/1`) not just User.

8. **Cold-load data_owner across three sites (replaces r1–r6 INV-13b):** same three resolvers (Chat / ExternalMirror / Publisher.SessionImpl), now with DB-backing checks instead of tombstone checks. Verify no fourth resolver exists, AND the DB-backing check is positioned BEFORE the URI is returned.

9. **`destroy/2` REQUIRED migration cost:** if OQ-NEW chooses REQUIRED, every existing Kind module must add `destroy/2`. Enumerate: `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex`, `apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex`, `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex`, `apps/ezagent_domain_workspace/lib/ezagent/entity/workspace.ex`, `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/worker.ex`. Is anything missed? Are there test-fixture Kinds that need it?

10. **LV confirm dialog UX (preserved from r1–r6 q9):** type-the-URI confirmation default. Allen confirm in OQ-9.

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
  │ step 1: kind.can_destroy?(target_uri, ctx)  → :ok or {:precheck_failed, _}
  │ step 2: generate trace_id
  │
  ▼ step 3 (per-Kind cleanup callback)
kind.destroy(target_uri, ctx_with_trace)
  │   - User: revoke caps / drop bindings / drop memberships / scrub session owners
  │   - Agent: AgentBridge.Adapter.teardown / revoke tokens / drop memberships
  │   - Workspace: recursively Kind.Server.destroy each member (shared trace_id)
  │   - Worker: drop external_mirror_bindings (worker_uri column) / unsubscribe
  │   - Session: drop members / unsubscribe publisher
  ▼ {:ok, summary} or {:error, reason} (best-effort; orchestrator continues)
  │
  ▼ step 4: KindRegistry.lookup(target_uri)
  │     {:ok, pid} → step 5
  │     :error → skip step 5 (Kind wasn't alive)
  │
  ▼ step 5: DynamicSupervisor.terminate_child(supervisor, pid)
  │     (graceful — runs Kind's terminate/2 if any)
  │
  ▼ steps 6+7 wrapped in Repo.transaction (race-bounded)
  │     step 6: kind.delete_db_row(target_uri)  [DB row IS the source of truth]
  │     step 7: Repo.delete(KindSnapshot, target_uri_str)
  │
  ▼ step 8: audit emit
  │     invocations action = "kind.destroyed"
  │     per-step sub-rows from step 3's summary (shared trace_id)
  │
  ▼ broadcast
Phoenix.PubSub.broadcast({:kind_destroyed, target_uri, reason})
  │
  ▼
{:ok, %{deleted_uri, steps_completed, cascade_summary, audit_event_id, trace_id}}

# Re-spawn after destroy
SpawnRegistry.spawn(target_uri)
  │ entity callback: Users.get_by_uri(target_uri) == nil → {:error, :no_backing_entity}
  ▼
{:error, :no_backing_entity}

# Re-register
Users.create(target_uri, fresh_attrs)  # writes new row
SpawnRegistry.spawn(target_uri)
  │ entity callback: Users.get_by_uri → new row exists → Kind.spawn(User, ...)
  ▼
{:ok, fresh_pid}  # no inherited state — fresh Kind, fresh slice, no snapshot
```

## Appendix B — Why this SPEC is shorter than r6

r6 was 985 lines. r7 is ~60% of that: the tombstone mechanism (entity_tombstones table, ETS mirror, atomic primitive, three-boundary enforcement, the codex-driven rev history) was the bulk of r6. r7 removes that artifact entirely. What remains: the `Kind.destroy/2` callback contract (~20 lines), the `Kind.Server.destroy/2` orchestration (~50 lines), the per-Kind cascade tables (preserved from r6, ~80 lines), the AgentBridge.Adapter.teardown extension (~10 lines), the DB-backing check at entity callbacks (~10 lines), the INV table (16 entries, ~40 lines), the OQ list (6 entries, ~30 lines).

## Appendix C — Author's recommendation

Land PR-A (this SPEC) → PR-B (core: Kind.destroy callback + Kind.Server.destroy + DB-backing check + AgentBridge.Adapter.teardown). PR-C (per-Kind destroy impls) follows immediately because the callback contract is required (per OQ-NEW recommendation); PR-D (plugin teardown impls) can land parallel to PR-C; PR-E (LV UI + CLI) lands last.

The `system/linyilun` ghost — surfaced 2026-05-28 — is the empirical motivation, but the structural fix is broader: every Kind gains a clean lifecycle CRUD parity, and re-register at a destroyed URI works naturally because the DB row is the source of truth. The architectural goal Allen articulated (2026-05-28 03:43) is met: "all Kinds should have complete CRUD".

🤖 Generated with [Claude Code](https://claude.com/claude-code)
