# SPEC — Agent duplicate/clone primitive (Behavior.Agent `:duplicate`)

**Status:** DRAFT rev 4 · 2026-05-25 (codex r1 + r2 + r3 fixes)
**Tier:** `apps/ezagent_domain_chat/` (new `Behavior.Agent` + action) + `apps/ezagent_core/` (new `AgentOwnership` registry + Kind.Template snapshot callback adapter + BehaviorRegistry slot) + `apps/ezagent_plugin_cc/` (cc snapshot+restore impl) + `apps/ezagent_domain_workspace/` (mix task wrapper + ownership-write on `:create_agent`)
**Trigger:** Allen 2026-05-24 (memory `feedback_agent_clone_not_via_template`) — "agent 创建的 template 如果不走正常的 template 创建和 fork 流程，可能导致开发 drift，但如果走标准流程，又可能导致 Template Registry 里面大量临时创建后再也不用的 template". Clone must live as a domain.agent primitive, NEVER via Template Registry.
**Predecessors:**
- `docs/superpowers/specs/2026-05-25-agent-create-cli-gui-parity.md` — `Behavior.Workspace.:create_agent` (NOT reused for spawn — see §3.4 rev-2 fix)
- PR #289 (`2c66903`) — per-agent config_dir + Kind.Template extension callbacks
- PR #288 — `Ezagent.Behavior.Sandbox` (the slice that holds `config_dir_path` + `template_class`)
- PR #330 (`8277d08`) — `Ezagent.Workspace.create_agent/3` facade (referenced but not reused)
- `feedback_let_it_crash_no_workarounds` — no `:warning + degrade`, no shims
- `feedback_uuid_is_canonical_identifier` — agent URIs canonical; username display-only
- `feedback_fork_is_generic_template_concern` — distinguishes Template-level fork (PR1 #287 `Behavior.Template.:fork`) from this Agent-level clone
- SPEC `caps-data-ownership-v2.md` §3.3 + §5.2 (CapBAC default grants + admin branch)
**Companion ZH:** `2026-05-25-agent-duplicate-clone.zh_cn.md`

**Rev 2 changes (codex r1 verdict needs-attention → addressed):**
- CRITICAL: source consent now REQUIRED — target-ws-admin alone CANNOT exfiltrate source config (§4)
- HIGH: `data_owner/1` returns `:no_owner`; duplicate cap is admin-granted, not auto-derived (§4.2)
- HIGH: all-or-nothing target spawn — config staged to temp + verified BEFORE target Kind comes up (§3.5)
- HIGH: no `Workspace.create_agent` routing — dedicated primitive avoids template residue + adoption TOCTOU (§3.4)
- MEDIUM: new `Kind.Template.snapshot_config_dir/2` callback owns plugin-side quiesce + manifest (§3.6)

**Rev 4 changes (codex r3 verdict needs-attention → addressed):**
- CRITICAL: rollback now waits for target Kind process death BEFORE deleting `Kind.Snapshot` row. `Sandbox.:destroy`'s delayed termination Task previously could re-write the snapshot AFTER our delete. Rev 4 changes the rollback order: terminate synchronously (`DynamicSupervisor.terminate_child` + `Process.monitor` wait for `:DOWN`), THEN delete snapshot. Snapshot delete now happens on a dead process — no re-write possible (§3.4.2 rewritten).
- HIGH: explicit `Ezagent.Agent.Provisioning.provision_agent/3` helper module (NEW; in `apps/ezagent_domain_chat/lib/ezagent/agent/provisioning.ex`) shared by BOTH `Behavior.Workspace.:create_agent` and `Behavior.Agent.:duplicate` spawn paths. Steps: (1) `AgentOwnership.record/2`, (2) `CapabilityRegistry.default_grants_from_data_owner/2` for every Behavior of Agent Kind → apply via `Identity.grant_cap`, (3) failure of (2) rolls back (1). Closes codex r3 HIGH-2 (avoiding the "spawn lifecycle auto-synthesizes" assumption that codex grep'd as false). §3.9 new.
- HIGH: `Ezagent.AgentOwnership` is now a **dets-backed ETS cache** (NOT pure ETS). Mirrors `Workspace.Store`'s SQLite-backing pattern: SQLite table `agent_ownership(agent_uri pk, owner_uri, created_at)` is the durable source of truth; ETS table is a boot-time-hydrated read cache. `record/2` writes BOTH (sync). `forget/1` deletes BOTH. Restart test (§7 row 15 new) creates an agent, restarts the runtime, verifies owner still resolves + can delegate `:duplicate`.

**Rev 3 changes (codex r2 verdict needs-attention → addressed):**
- CRITICAL: rollback now closes the `:on_terminate` persistence hole — dispatches `Sandbox.:destroy` (clears slice + plugin-side cleanup) + deletes `KindSnapshot` row + revokes any granted caps BEFORE `Kind.terminate/1`. Failure-injection tests added for every post-spawn step (§3.4.2 + §7).
- HIGH: `Behavior.Agent.data_owner(agent_uri)` now resolves to the **owning user URI** via a new `Ezagent.AgentOwnership` registry (ETS, parallel to `AgentLineage`). Source-owner can delegate the `:duplicate` cap to a target-ws admin via standard `Identity.grant_cap` — bilateral consent is now structurally possible, not bootstrap-admin-only (§3.8 + §4.2).
- HIGH: `Kind.Template` snapshot callbacks remain `@optional` BUT the action body calls a core adapter `Ezagent.Kind.Template.snapshot_or_default/2` that checks `function_exported?` and normalizes missing callbacks to `{:ok, %{path: nil, manifest: %{}}}`. Acceptance test against a plugin with no callback (§7 row 10 expanded).
- MEDIUM: cc snapshot manifest now content-hashes every file before + after copy, fails if any hash differs. `.credentials.json` rotation mid-snapshot is detected (§3.6.1 rewritten). §1 wording softened: "snapshot consistency is enforced by manifest verification; live writes during snapshot ABORT cleanly" (no more "point-in-time" claim that the V1 impl couldn't honor).

---

## 0. Design decisions (pre-defaulted by Allen via `wake-but-don't-stop`)

Three open questions answered by Allen's autonomous default. Flagged for human reaffirmation at SPEC review.

| # | Question                                          | Default                              | Rationale                                                                                                                  |
|---|---------------------------------------------------|--------------------------------------|----------------------------------------------------------------------------------------------------------------------------|
| 1 | Ownership transfer **or** copy?                   | **Copy**                             | Source agent stays live + owned by source user; target is a fresh instance owned by `target_owner_uri`. Cleaner reversal. |
| 2 | Bring conversation history?                       | **Fresh (none)**                     | Agent Kind does not carry chat history slice (Session does). Identity caps reset. If user wants history they keep the source agent. |
| 3 | `config_dir` semantics?                           | **Plugin-owned snapshot+restore**    | Source plugin Template Class owns snapshot (quiesce + manifest); core writes the unpack into target's per-agent dir.       |

These are SPEC defaults. If reviewers want different semantics, raise in PR review BEFORE impl PR opens.

---

## 1. Goal

**Add a single dispatchable Behavior action — `Ezagent.Behavior.Agent.:duplicate` — that clones an existing agent into a new agent URI, optionally in a different workspace and/or owned by a different user, with all-or-nothing semantics and explicit two-sided authorization.** No Template Registry intermediary; no `save_as_template + fork + spawn` round-trip; no Template-Class drift risk; no `Workspace.create_agent` routing (avoids template residue + TOCTOU adoption — codex r1 HIGH-4).

After this SPEC's impl PR lands:
- `mix ezagent.agent.duplicate <source_uri> <target_uri> --owner <owner_uri>` produces a brand-new live agent at `target_uri`, with its own config_dir (FS-independent of source; snapshot consistency enforced by per-file hash manifest — live writes during snapshot ABORT the clone cleanly, no half-copied state escapes), fresh Identity caps, and **NO** chat-history coupling to source.
- The clone primitive lives on the **Agent Kind**, not on Template Registry. Template Class metadata is *referenced* (target agent keeps the same flavor + template_class) but no new Template Class is registered.
- **Two-sided authorization** (codex r1 CRITICAL): caller needs BOTH (a) `{Behavior.Agent, :duplicate}` cap on **source** (held by source-owner or source-ws-admin) AND (b) `{Behavior.Workspace, :create_agent}` cap on **target workspace** (held by target-ws-admin). Target-ws-admin alone CANNOT exfiltrate source config.
- **All-or-nothing** (codex r1 HIGH-3): config snapshot + verification happen BEFORE target Kind spawns. If snapshot fails, no target is created. If post-snapshot spawn fails, the staged dir is cleaned + caller sees a clean error.
- A regression-bar invariant test asserts cloned `config_dir` is structurally independent of source's: touching files in source's dir does NOT affect target's.

---

## 2. Scope

In-scope:
- New `Ezagent.Behavior.Agent` module (apps/ezagent_domain_chat/lib/ezagent/behavior/agent.ex) — the Agent Kind currently has no Behavior file of its own. New module hosts `:duplicate` as the first action.
- New action `:duplicate` on that Behavior. Args: `%{target_uri: URI.t(), target_owner_uri: URI.t()}` (source_uri is the dispatch self_uri).
- New `Kind.Template` optional callback: `snapshot_config_dir/2` (source plugin-side quiesce + temp-dir manifest) — paired with existing `create_config_dir/2` (target plugin-side unpack). cc plugin implements both.
- Cap subject `{Behavior.Agent, :duplicate}` — `data_owner/1` returns `:no_owner` (codex r1 HIGH-2: source agent URI as data_owner would silently grant cap to the agent itself, not the owning user). Cap is granted **explicitly at agent-spawn** to the agent's creator (the user that called `create_agent`).
- Target spawn via a dedicated path (NOT `Workspace.create_agent`): direct `SpawnRegistry.spawn_detailed/1` against `target_uri`, then explicit `WorkspaceRegistry.bind` + `AgentLineage.record` + `Sandbox.write_path` + plugin-side `restore_from_snapshot` of the staged dir + PTY start. Atomic `:started` vs `:already_started` is reified — adoption refused (codex r1 HIGH-4).
- Mix task `Mix.Tasks.Ezagent.Agent.Duplicate` (`mix ezagent.agent.duplicate`) — thin construct-args + dispatch wrapper.
- ExUnit acceptance tests (in impl PR) covering: happy path, BOTH cap-denial scenarios (source-cap missing / target-cap missing), collision, missing source, cross-workspace consensual, snapshot failure rollback, spawn-after-snapshot failure rollback.
- Invariant test `apps/ezagent_core/test/invariants/agent_duplicate_isolation_invariant_test.exs` — touches source `config_dir` after clone, asserts target unchanged.
- Invariant: `apps/ezagent_core/test/invariants/agent_duplicate_no_create_agent_routing_test.exs` — greps action body, asserts `:duplicate` does NOT call `Workspace.create_agent` (codex r1 HIGH-4 lock).
- Allowlist entry in `agent_create_single_path_test.exs` for the new SpawnRegistry use site (per SPEC #330 PR conventions).

Out-of-scope:
- LV admin UI for clone. Operator-only-CLI for V1 (deferred per `docs/futures/todo.md` — flagged in §10).
- "Save as template" semantics. That's `Behavior.Template.:fork` (PR1 #287).
- Migration of any existing data. Clone is forward-only.
- MCP-tool exposure.
- Quiesce of running cc PTY mid-snapshot. V1 cc impl documents the live-write race window honestly (§3.6); future cc PR adds true quiesce via `claude --quiesce`-style mechanism if/when Anthropic ships one. The snapshot manifest detects partial state and the duplicate action retries-or-fails based on it.

---

## 3. Design

### 3.1 Behavior module — `Ezagent.Behavior.Agent`

New file: `apps/ezagent_domain_chat/lib/ezagent/behavior/agent.ex`. Agent's domain (chat domain — Agents live under chat's AgentSupervisor per `Ezagent.Entity.Agent.supervisor/0`).

```elixir
defmodule Ezagent.Behavior.Agent do
  @moduledoc """
  Agent Behavior — actions whose subject is the agent itself (the
  agent-domain operations that don't fit Chat / Identity / Sandbox).

  ## Actions

  - `:duplicate` (`:call`) — clone the source agent into a new agent
    at `target_uri`, owned by `target_owner_uri`. Per SPEC
    `docs/superpowers/specs/2026-05-25-agent-duplicate-clone.md`.

  Future actions (out of scope for V1): `:rename`, `:archive`,
  `:restore`.

  ## CapBAC — `data_owner/1` is `:no_owner`

  `data_owner/1` returns `:no_owner` (NOT the source agent URI).
  Rationale (codex r1 HIGH-2): the existing
  `CapabilityRegistry.default_grants_from_data_owner/2` treats a
  returned URI as the grantee directly. If we returned source_uri
  the cap would be silently granted to the AGENT itself, not the
  owning user. There is no built-in "agent → owning user" resolver
  in the current architecture (lineage holds `granted_by`, not
  `owner`); rather than smuggle one in via this Behavior, we
  declare `:no_owner` and grant the cap EXPLICITLY at agent-spawn
  time to the agent's creator (see §4.3).
  """

  @behaviour Ezagent.Behavior

  @impl Ezagent.Behavior
  def actions, do: [:duplicate]

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:duplicate,
       "clone this agent into a new agent at <target_uri>, owned by " <>
         "<target_owner_uri>. Snapshot-then-restore config_dir; " <>
         "fresh Identity caps; no chat history. Source unchanged. " <>
         "Requires ALSO a Workspace.create_agent cap on the target workspace."}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :agent

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{}

  @impl Ezagent.Behavior
  def invoke(:duplicate, slice, args, ctx), do: # ... see §3.2

  @impl Ezagent.Behavior
  def interface, do: # ... see §3.3

  # codex r1 HIGH-2 fix — :no_owner, not source_uri. The Identity-
  # style "entity is its own owner" pattern doesn't work here
  # because the Behavior subject (the agent) is NOT the user we
  # want to grant. The cap is granted explicitly at agent-spawn
  # to the creator (see §4.3).
  @impl Ezagent.Behavior
  def data_owner(_), do: :no_owner
end
```

And `Ezagent.Entity.Agent.behaviors/0` (line 67-68 of `apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex`) is amended:

```elixir
def behaviors,
  do: [Ezagent.Behavior.Chat, Ezagent.Behavior.Identity,
       Ezagent.Behavior.Sandbox, Ezagent.Behavior.Agent]
```

### 3.2 Action body — `:duplicate` (rev-2 all-or-nothing)

Runs inside the **source agent's** Kind GenServer. The action enforces TWO-SIDED authorization, performs SNAPSHOT-BEFORE-SPAWN, and rolls back atomically on any failure.

```elixir
def invoke(:duplicate, _slice, args, ctx) do
  source_uri        = Map.fetch!(ctx, :self_uri)
  target_uri        = Map.fetch!(args, :target_uri)
  target_owner_uri  = Map.fetch!(args, :target_owner_uri)
  caller            = Map.fetch!(ctx, :caller)
  caps              = Map.fetch!(ctx, :caps)

  with {:ok, target_uri}     <- validate_target_uri(target_uri),
       :ok                   <- refuse_if_target_exists(target_uri),
       {:ok, source_meta}    <- read_source_metadata(source_uri),
       {:ok, target_ws_uri}  <- workspace_uri_from_agent(target_uri),
       # TWO-SIDED AUTH (codex r1 CRITICAL):
       :ok                   <- check_target_create_cap(caller, caps, target_ws_uri),
       # Source-cap was checked by dispatch (the :duplicate cap on source_uri
       # is the cap_subject this action runs under). The target-create cap
       # is the SECOND check this action body does explicitly.

       # STAGE — snapshot source config to temp dir (codex r1 MEDIUM-5):
       {:ok, staged_path}    <- snapshot_source_config_to_temp(source_meta, source_uri, target_uri),

       # SPAWN — dedicated path, NOT Workspace.create_agent (codex r1 HIGH-4):
       {:ok, result}         <- spawn_target_directly(target_uri, source_meta, target_ws_uri, target_owner_uri, staged_path) do
    {:ok, %{}, %{
      source_uri: source_uri,
      target_uri: result.agent_uri,
      owner_uri: target_owner_uri
    }}
  else
    {:error, _reason} = err ->
      # Atomic rollback (codex r1 HIGH-3) — staged_path is cleaned
      # by spawn_target_directly on failure; here we don't need
      # extra cleanup because we abort BEFORE target is registered.
      err
  end
end
```

Where each helper is:

- `check_target_create_cap/3` — synthesizes the needed cap
  (`%Capability{kind: :workspace, behavior: Behavior.Workspace, instance: target_ws_uri, ...}`)
  matching against the caller's caps via `Ezagent.Capability.matches?/2`. Same
  check the workspace-admin pathway uses (per `caps-data-ownership-v2.md` §5.2).
- `read_source_metadata/1` — dispatch `sandbox.read` against source to get
  `config_dir_path` + `template_class`. Source flavor derived from URI prefix.
- `snapshot_source_config_to_temp/3` — calls the plugin Template Class's new
  `snapshot_config_dir/2` callback (see §3.6). Returns absolute path to a
  TEMP dir containing the snapshot + manifest. Plugin owns quiesce semantics.
- `spawn_target_directly/5` — see §3.4.

### 3.3 Interface schema

```elixir
def interface do
  %{
    duplicate: %{
      description:
        "Clone the source agent into a fresh agent at target_uri, owned by " <>
          "target_owner_uri. Snapshot-then-restore config_dir; fresh Identity caps; " <>
          "no chat history. Two-sided auth: source-side :duplicate cap (dispatch-time) " <>
          "+ target-workspace :create_agent cap (action-body-time).",
      args: %{
        target_uri: :uri,
        target_owner_uri: :uri
      },
      returns: %{
        source_uri: :uri,
        target_uri: :uri,
        owner_uri: :uri
      },
      modes: [:call]
    }
  }
end
```

`source_uri` is NOT in `args` — it's `ctx.self_uri`, the dispatch target.

### 3.4 Target spawn — dedicated primitive (NOT Workspace.create_agent)

Per codex r1 HIGH-4, routing through `Ezagent.Workspace.create_agent/3` would:
1. Register a workspace-scoped template (the cc/echo path) in the workspace's `session_templates` slice → persists to `Workspace.Store` → exactly the "throwaway template residue" memory `feedback_agent_clone_not_via_template` warns against.
2. The create_agent path's catch-all `:already_started` → `:ok` collapse means a concurrent spawn at `target_uri` would be silently adopted as success, after which step 5 (config restore) would overwrite a foreign agent's dir.

The dedicated `spawn_target_directly/5`:

```elixir
defp spawn_target_directly(target_uri, source_meta, target_ws_uri, target_owner_uri, staged_path) do
  with {:ok, :started, _pid}   <- spawn_atomic_fresh(target_uri),  # NO adoption (§3.4.1)
       :ok                     <- WorkspaceRegistry.bind(target_uri, target_ws_uri),
       :ok                     <- AgentLineage.record(target_uri, target_owner_uri),
       {:ok, final_dir}        <- restore_snapshot_into_target(source_meta, target_uri, staged_path),
       :ok                     <- dispatch_sandbox_write_path(target_uri, final_dir, source_meta.template_class),
       :ok                     <- grant_initial_caps_for_owner(target_uri, target_owner_uri),
       :ok                     <- start_pty_or_no_pty(target_uri, source_meta, target_ws_uri) do
    {:ok, %{agent_uri: target_uri}}
  else
    err -> rollback_partial_target(target_uri, staged_path, err)
  end
end
```

#### 3.4.1 `spawn_atomic_fresh/1` — refuses adoption

```elixir
defp spawn_atomic_fresh(target_uri) do
  case Ezagent.SpawnRegistry.spawn_detailed(target_uri) do
    {:ok, :started, pid} -> {:ok, :started, pid}
    {:ok, :already_started, _pid} -> {:error, {:adopted_not_fresh, target_uri}}  # NOT success
    {:error, _} = err -> err
  end
end
```

This differs from the existing `:already_started → :ok` patterns. For duplicate we MUST be the one that created the target — an adopted target's config we're about to overwrite is not our property.

#### 3.4.2 `rollback_partial_target/3` — terminate-then-purge (codex r3 CRITICAL fix)

Codex r3 CRITICAL: rev-3 ordering had `dispatch_sandbox_destroy/1` schedule a delayed Task (20ms) that calls `Kind.Server.terminate/2`. That terminate's `:on_terminate` snapshot write could fire AFTER our `Kind.Snapshot.delete(target_uri)` — re-writing the row we just deleted. Rev-4 fix: terminate SYNCHRONOUSLY (await `:DOWN`), THEN delete snapshot on a process that can no longer write.

```elixir
defp rollback_partial_target(target_uri, staged_path, err) do
  # Step 1: revoke any caps we granted (Identity slice clear).
  #   Done synchronously via dispatch BEFORE termination so any
  #   :on_terminate snapshot write does NOT contain stale caps.
  _ = revoke_initial_caps_if_granted(target_uri)

  # Step 2: dispatch Sandbox.:destroy (call mode, synchronous) — clears
  #   :sandbox slice + invokes plugin destroy_config_dir/2 for FS
  #   cleanup of the AGENT-config-dir (not staging). Returns after the
  #   slice mutation is committed via Kind.Server.commit_and_notify/3,
  #   so subsequent slice reads see the cleared state. Sandbox.:destroy
  #   ALSO schedules a delayed terminate Task — we explicitly DO NOT
  #   rely on that; we run our own synchronous termination next.
  _ = dispatch_sandbox_destroy(target_uri)

  # Step 3 (rev-4 critical fix): SYNCHRONOUSLY terminate the target
  #   Kind process and AWAIT death. Use the supervisor's
  #   terminate_child path with Process.monitor so we know the process
  #   is gone before proceeding. This is the cleaner kill path
  #   (`:shutdown` exit reason) — Kind.Server.terminate/2 still runs
  #   and will write the :on_terminate snapshot, BUT at this point
  #   slices have been cleared by step 1+2 so the snapshot written
  #   carries no stale state. After this returns, the process is dead
  #   and no further snapshot writes are possible from it.
  :ok = terminate_target_synchronously(target_uri)

  # Step 4: forget registries (ESR-domain registry rows).
  _ = Ezagent.AgentOwnership.forget(target_uri)
  _ = Ezagent.AgentLineage.forget(target_uri)
  _ = Ezagent.WorkspaceRegistry.unbind(target_uri)

  # Step 5: now safe to delete the persisted KindSnapshot row.
  #   The target process is dead (step 3 awaited :DOWN); no
  #   further writes from Kind.Server.terminate/2 can race us.
  #   Idempotent — no-op if row absent.
  :ok = Ezagent.Kind.Snapshot.delete(target_uri)

  # Step 6: clean up the staging temp dir (outside agent-config tree,
  #   not handled by Sandbox.:destroy).
  _ = File.rm_rf(staged_path)

  err
end

# Synchronous terminate-and-wait. Returns :ok only after the process
# is confirmed dead. Idempotent (no-op if target wasn't registered).
defp terminate_target_synchronously(target_uri) do
  case Ezagent.KindRegistry.lookup(target_uri) do
    {:ok, pid} ->
      ref = Process.monitor(pid)
      _ = DynamicSupervisor.terminate_child(target_supervisor(target_uri), pid)
      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 -> {:error, :terminate_timeout}  # exceptional; let-it-crash
      end
    :error -> :ok
  end
end
```

**Why slice-clear BEFORE terminate (not after):**

The slice mutation done by `revoke_initial_caps_if_granted` and `dispatch_sandbox_destroy` runs via the public dispatch path (`Invocation.dispatch/1`), which routes to `Kind.Server.handle_call(:ezagent_dispatch, ...)` → `Behavior.invoke/4` → `Kind.Server.commit_and_notify/3` → in-memory slice update. The slice IS committed to memory before the dispatch returns. When `terminate_target_synchronously/1` then runs the Kind's `terminate/2` callback, it reads the (already-cleared) slice and writes that EMPTY shape to `Kind.Snapshot`. Step 5's `delete/1` then runs on a dead process and removes the (empty) row.

So the snapshot write from `:on_terminate` is harmless in rev 4: it writes empty slice. Step 5 deletes that empty row entirely so even a hypothetical "load the empty row on next spawn" can't happen.

**Failure-injection acceptance tests (§7 rows 7-9):** for each post-spawn step (`restore_snapshot`, `sandbox.write_path`, `grant_initial_caps`, `start_pty`), assert post-rollback: no `Kind.Snapshot.get(target_uri)` row, no `WorkspaceRegistry.lookup(target_uri)` binding, no `AgentLineage.lookup(target_uri)` row, no `AgentOwnership.lookup(target_uri)` row, no `template_class.agent_config_dir(target_uri)` on FS, no `staged_path` on FS, AND no process at `KindRegistry.lookup(target_uri)`. The rollback test must include `Process.alive?(pid)` check returning false BEFORE checking snapshot absence — otherwise a flaky test could observe the row deleted then the terminate's snapshot write race-replaces it.

This is the "checked rollback" shape `feedback_let_it_crash_no_workarounds` allows — not a defensive catch-all, but a deterministic teardown that AWAITS each step's completion before the next.

### 3.5 Stage → spawn ordering rationale (codex r1 HIGH-3)

Pre-rev-2: spawn target → cp_r config over it → on cp_r fail, leave target alive.

Rev-2: snapshot source to temp → spawn target → restore snapshot into target → on any post-spawn fail, rollback target completely.

Why the two-phase: the SNAPSHOT phase is purely source-side + temp-dir; if it fails, no target was ever created (target_uri stays free). The SPAWN phase is bounded by `rollback_partial_target/3`. The single failure that creates an inconsistent state (cp_r fails after target is up but BEFORE rollback) is now self-recovered: the rollback runs Kind termination + dir cleanup, leaving target_uri free for retry.

### 3.6 `Kind.Template.snapshot_config_dir/2` — new optional callback + core adapter (codex r2 HIGH-3 fix)

New `@optional_callback` on `Ezagent.Kind.Template`:

```elixir
@doc """
Snapshot the source agent's config_dir into a temp dir, returning
the temp path + a content-hash manifest. The manifest enables
post-copy verification that no source file changed during snapshot
(codex r2 MEDIUM-4 fix).

The temp dir lives under `Ezagent.Home.path("cc-agents/.snapshots")/<uuid>/`
— outside the agent-config tree, safely rm'able.

Returns `{:ok, %{path: String.t(), manifest: map()}}` or `{:error, term()}`.
On failure, the plugin MUST clean its own temp partial — the caller
does NOT attempt to clean a path it never received.

For agents with no config_dir to snapshot (echo, curl, np), the
plugin SHOULD return `{:ok, %{path: nil, manifest: %{}}}` —
positive "I have nothing to snapshot" rather than missing-function.
Plugins that don't implement the callback at all are handled by
the `snapshot_or_default/2` core adapter (see below).

Manifest shape (cc V1): `%{file_count: N, files: %{relpath => %{size:, mtime:, sha256:}}, taken_at: DateTime, source_uri: String}`.
"""
@callback snapshot_config_dir(source_uri :: URI.t(), source_dir :: String.t()) ::
            {:ok, %{path: String.t() | nil, manifest: map()}} | {:error, term()}

@doc """
Restore a snapshot into the target agent's per-agent config_dir
location. Plugin uses its `agent_config_dir/1` builder for target
path, atomically moves the snapshot into place, writes the
`.ezagent-config-complete` marker LAST.

Caller (Behavior.Agent.:duplicate) is responsible for rm'ing the
snapshot temp dir on success or failure.

When `snapshot_path == nil` (echo/curl/np / opted-out), the
plugin's `restore_from_snapshot/3` is NOT called by the action
body — the action body checks `snapshot.path == nil` and skips
the restore step entirely.

Returns `{:ok, final_path}` or `{:error, term()}`.
"""
@callback restore_from_snapshot(
            target_uri :: URI.t(),
            snapshot_path :: String.t(),
            manifest :: map()
          ) :: {:ok, String.t()} | {:error, term()}

@optional_callbacks snapshot_config_dir: 2, restore_from_snapshot: 3
```

**Core adapter (`Ezagent.Kind.Template.snapshot_or_default/2`)** — the action body calls THIS, not `template_class.snapshot_config_dir/2` directly. The adapter checks `function_exported?` and returns the default for plugins that opted out:

```elixir
defmodule Ezagent.Kind.Template do
  # ... existing contract definitions ...

  @doc """
  Adapter — calls `template_class.snapshot_config_dir(source_uri, source_dir)`
  if the callback is exported, returns the no-op default otherwise.

  Returns `{:ok, %{path: nil | String.t(), manifest: map()}}` or `{:error, _}`.
  """
  @spec snapshot_or_default(module(), URI.t(), String.t() | nil) ::
          {:ok, %{path: String.t() | nil, manifest: map()}} | {:error, term()}
  def snapshot_or_default(template_class, source_uri, source_dir)
      when is_atom(template_class) do
    cond do
      is_nil(source_dir) ->
        # Plugin doesn't manage a dir for this agent — snapshot has no
        # content. Skip without involving the plugin.
        {:ok, %{path: nil, manifest: %{}}}

      function_exported?(template_class, :snapshot_config_dir, 2) ->
        template_class.snapshot_config_dir(source_uri, source_dir)

      true ->
        # Template Class exists but didn't implement the optional callback.
        # Treat as "I have nothing to snapshot".
        {:ok, %{path: nil, manifest: %{}}}
    end
  end

  @doc """
  Paired adapter — calls `template_class.restore_from_snapshot/3`
  if `snapshot.path != nil` and the callback is exported.
  Returns `:noop` when the action body should skip restore entirely.
  """
  @spec restore_or_noop(module(), URI.t(), map()) ::
          {:ok, String.t()} | :noop | {:error, term()}
  def restore_or_noop(_tc, _target_uri, %{path: nil}), do: :noop

  def restore_or_noop(template_class, target_uri, %{path: path, manifest: manifest})
      when is_atom(template_class) and is_binary(path) do
    if function_exported?(template_class, :restore_from_snapshot, 3) do
      template_class.restore_from_snapshot(target_uri, path, manifest)
    else
      # Snapshot produced a path but plugin can't restore — contract violation.
      # Better to crash than silently skip restore of a real snapshot.
      {:error, {:restore_callback_missing, template_class}}
    end
  end
end
```

The action body uses these:

```elixir
{:ok, snapshot} <- Kind.Template.snapshot_or_default(source_meta.template_class, source_uri, source_meta.config_dir_path),
# ...
result <- Kind.Template.restore_or_noop(source_meta.template_class, target_uri, snapshot)
# result is :noop OR {:ok, final_dir} OR {:error, _}
```

Acceptance test (§7 row 10 expanded): a plugin with NO callback definitions at all → `snapshot_or_default/3` returns `{:ok, %{path: nil, manifest: %{}}}`; `restore_or_noop/3` returns `:noop`; action body completes with `sandbox.config_dir_path: nil`.

#### 3.6.1 cc V1 snapshot impl — content-hash manifest (codex r2 MEDIUM-4 fix)

```elixir
@impl Ezagent.Kind.Template
def snapshot_config_dir(%URI{} = source_uri, source_dir) when is_binary(source_dir) do
  snapshots_root = Path.join(Ezagent.Home.path("cc-agents"), ".snapshots")
  snapshot_dir = Path.join(snapshots_root, "#{:erlang.unique_integer([:positive])}-#{System.os_time(:millisecond)}")

  with :ok               <- File.mkdir_p(snapshots_root),
       # 1. Pre-copy manifest — every regular file under source_dir,
       #    `%{relpath => %{size, mtime, sha256}}`. Symlinks and special
       #    files are explicitly REJECTED here (cp_r handles them but the
       #    manifest can't hash them; we refuse to snapshot a dir
       #    containing them rather than silently skip).
       {:ok, pre_manifest} <- build_file_manifest(source_dir),
       # 2. Atomic cp_r.
       {:ok, _}           <- File.cp_r(source_dir, snapshot_dir),
       :ok                <- File.chmod(snapshot_dir, 0o700),
       :ok                <- chmod_credentials(snapshot_dir),
       # 3. Post-copy manifest of the SOURCE (not the snapshot) — verifies
       #    no source file changed during cp_r. Detects `.credentials.json`
       #    rotation, plugin add/remove, etc. If any file's size/mtime/sha
       #    differs from pre_manifest, snapshot fails — caller sees a
       #    clean error AND the snapshot_dir is rm'd.
       {:ok, post_manifest} <- build_file_manifest(source_dir),
       :ok                <- compare_manifests(pre_manifest, post_manifest) do
    manifest = %{
      file_count: map_size(pre_manifest),
      files: pre_manifest,
      taken_at: DateTime.utc_now(),
      source_uri: URI.to_string(source_uri)
    }
    {:ok, %{path: snapshot_dir, manifest: manifest}}
  else
    {:error, _} = err ->
      _ = File.rm_rf(snapshot_dir)
      err
    other ->
      _ = File.rm_rf(snapshot_dir)
      {:error, {:snapshot_failed, other}}
  end
end

# build_file_manifest/1 walks source_dir, returns
# {:ok, %{relpath_string => %{size: int, mtime: int, sha256: binary}}}
# or {:error, {:unsupported_file_type, path}} if it encounters a
# symlink / device / fifo / socket (cc config dirs should only have
# regular files + subdirs; anything else is suspicious).
#
# compare_manifests/2 returns :ok if every key matches on size+mtime+sha,
# {:error, {:source_changed_during_snapshot, [diffs]}} otherwise.
```

The pre/post-source manifest comparison detects:
- Same-file content mutation (`.credentials.json` rotation): sha256 differs.
- File added during snapshot: post has key pre lacks.
- File removed during snapshot: pre has key post lacks.
- File size/mtime change: detected even when reading the file mid-write would yield inconsistent sha (the in-process compare picks up either way).

Symlink/special-file rejection is enforced (the manifest builder refuses them) — defense-in-depth against operator-crafted dirs that contain unsafe FS entries.

**Acceptance test for live-mutation race (§7 row 13 new):** snapshot a cc dir while a concurrent task mutates a credentials-like file → expect `{:error, {:source_changed_during_snapshot, _}}`; verify no `staged_path` left behind; verify no target spawned.

### 3.8 `Ezagent.AgentOwnership` registry — SQLite-backed ETS cache (codex r2 HIGH-2 + codex r3 HIGH-3 fix)

Codex r2 HIGH-2 noted that rev-2's `data_owner: :no_owner` defaults all `:duplicate` cap grants to bootstrap-admin only — source-owner CANNOT delegate the cap to a target-ws admin via standard `Identity.grant_cap`, breaking the bilateral consent path the spec promises.

The fix is a real "agent → owning user" resolution. We add a new ETS registry parallel to `AgentLineage`:

```elixir
defmodule Ezagent.AgentOwnership do
  @moduledoc """
  Agent ownership registry — `agent_uri → owner_user_uri`.

  Distinct from `AgentLineage`:
  - `AgentLineage.spawned_by(agent_uri)` = who SPAWNED this agent
    (orchestrator chain — may be another agent, used for `:spawned_by`
    cap shape per Decision #137).
  - `AgentOwnership.lookup(agent_uri)` = which USER OWNS this agent
    (always a `entity://user/...` URI; never a chain). Used by
    `Behavior.Agent.data_owner/1` to resolve cap grantees.

  Populated at agent-spawn by `Behavior.Workspace.:create_agent`'s
  action body: the calling user (from `ctx.caller`, validated to be
  a User URI) becomes the new agent's owner. A future `:transfer`
  action could mutate; V1 ownership is write-once at spawn.

  ## Storage layout (rev 4 — durable, codex r3 HIGH-3 fix)

  Two-tier:
  - **Durable source of truth:** SQLite table `agent_ownership(agent_uri pk, owner_uri, created_at)` in the existing ezagent DB (same Ecto repo `Workspace.Store` uses). Migration in this PR adds the table.
  - **ETS read cache:** `:ezagent_agent_ownership` table owned by `EzagentCore.EtsOwner`. Hydrated at boot via `boot_load/0` (reads ALL rows from SQLite into ETS); subsequent reads avoid SQL round-trip.

  Why two-tier (not ETS-only): rev-3 had ETS-only; codex r3 HIGH-3 noted ETS is volatile so a node restart loses ownership and every agent falls back to `:no_owner` (bootstrap-admin-only). Mirroring `Workspace.Store`'s SQLite-backing pattern gives durability without sacrificing the sync-read property `data_owner/1` needs.

  ## API
  - `record(agent_uri, owner_user_uri)` — writes SQLite first, then ETS. Idempotent (`on_conflict: :nothing` for legacy ownership; new ownership replaces). Synchronous; returns after SQLite commit.
  - `lookup(agent_uri)` — reads ETS only (cache; populated at boot from SQLite); falls back to SQLite + repopulates ETS if cache miss (handles ETS owner crash + restart).
  - `forget(agent_uri)` — deletes from SQLite, then ETS. Synchronous.
  - `boot_load/0` — called once by `EzagentCore.EtsOwner` after creating the ETS table; populates from SQLite. Idempotent if called multiple times.
  """

  @table :ezagent_agent_ownership

  @spec record(URI.t() | String.t(), URI.t() | String.t()) :: :ok
  def record(agent_uri, owner_uri) do
    a = to_string(agent_uri)
    o = to_string(owner_uri)
    # 1. Durable write first — if SQLite fails, no ETS poisoning
    :ok = persist(a, o)
    # 2. ETS cache update
    :ets.insert(@table, {a, o})
    :ok
  end

  @spec lookup(URI.t() | String.t()) :: {:ok, URI.t()} | :error
  def lookup(agent_uri) do
    a = to_string(agent_uri)
    case :ets.lookup(@table, a) do
      [{_, owner_str}] -> {:ok, URI.parse(owner_str)}
      [] -> lookup_from_sqlite_and_warm(a)  # ETS cache miss → re-load
    end
  end

  @spec forget(URI.t() | String.t()) :: :ok
  def forget(agent_uri) do
    a = to_string(agent_uri)
    :ok = delete_from_sqlite(a)
    :ets.delete(@table, a)
    :ok
  end

  @spec boot_load() :: :ok
  def boot_load do
    # Called by EzagentCore.EtsOwner after :ets.new/2 creates the table.
    # SELECT * FROM agent_ownership; foreach insert into ETS.
    # Idempotent — repeat calls clear+reload.
    :ets.delete_all_objects(@table)
    for {a, o} <- load_all_from_sqlite(), do: :ets.insert(@table, {a, o})
    :ok
  end

  defp persist(a, o), do: # Ecto.insert via Repo (Workspace.Store.repo)
  defp delete_from_sqlite(a), do: # Ecto.delete via Repo
  defp load_all_from_sqlite, do: # Ecto query
  defp lookup_from_sqlite_and_warm(a), do: # SELECT one + populate ETS
end
```

Then `Behavior.Agent.data_owner/1` becomes:

```elixir
@impl Ezagent.Behavior
def data_owner(%URI{scheme: "entity", host: "agent"} = agent_uri) do
  case Ezagent.AgentOwnership.lookup(agent_uri) do
    {:ok, %URI{} = owner_user_uri} -> owner_user_uri  # grants to the user
    :error -> :no_owner  # legacy / pre-registry agent: bootstrap-admin only
  end
end

def data_owner(:any), do: :any
def data_owner(_), do: :no_owner
```

This wires the `default_grants_from_data_owner/2` machinery correctly:
- New agent created via `Behavior.Workspace.:create_agent` → `AgentOwnership.record(agent_uri, ctx.caller)` runs in the action body BEFORE the dispatch returns; `BehaviorRegistry.default_grants_from_data_owner(Entity.Agent, agent_uri)` is then called by `Kind.Server` post-spawn (the standard PR-OWN-3 pathway), iterates `Behavior.Agent`, sees `data_owner -> user_uri`, synthesizes a `{Behavior.Agent, :duplicate}` cap grant to `user_uri`.
- The owner can then delegate to any other principal via the standard `Identity.grant_cap` mechanism (per IdentityAdmin's owner-branch).
- A target-ws admin who receives the delegated cap satisfies cap #1; their existing target-ws admin satisfies cap #2; bilateral consent works.

**Concern: Behavior coupling to ESR-domain registry.** This DOES couple `Behavior.Agent` to `AgentOwnership`. Justification: the same coupling already exists for `Behavior.Chat.data_owner/1` (reads Session slice's `:owner_uri`) and Workspace's admin branch (reads workspace data). The north-star principle (`feedback_north_star_plugin_isolation`) targets PLUGIN-to-CORE coupling — not Behavior-to-its-own-domain-registry. AgentOwnership lives in `ezagent_core` (boot-time available, plugin-independent); Behavior.Agent lives in `ezagent_domain_chat`. The coupling is core-from-domain (legitimate) not plugin-from-core (forbidden).

Acceptance test (§7 row 14 new): a non-bootstrap user creates an agent → that user can call `Identity.grant_cap` to grant `{Behavior.Agent, :duplicate}` on their agent to a target-ws admin → target-ws admin successfully dispatches `:duplicate`.

### 3.9 `Ezagent.Agent.Provisioning.provision_agent/3` — shared owner+caps helper (codex r3 HIGH-2 fix)

Codex r3 HIGH-2 noted that rev-3 §4.3 claimed "`Kind.Server`'s existing post-spawn pathway iterates the Agent Kind's Behaviors, calls `data_owner/1` on each, and synthesizes the per-Behavior default grants" — but `default_grants_from_data_owner/2` is NOT called by any current spawn lifecycle (grep confirmed). And the rev-3 spawn body still called `grant_initial_caps_for_owner/2`. The owner-derived `:duplicate` grant pathway was a phantom.

Rev 4 makes provisioning explicit and shared. New module `Ezagent.Agent.Provisioning`:

```elixir
defmodule Ezagent.Agent.Provisioning do
  @moduledoc """
  Shared agent-provisioning helper — records ownership AND applies
  data_owner-derived default caps. Used by BOTH:
  - `Behavior.Workspace.:create_agent` (post-spawn step)
  - `Behavior.Agent.:duplicate` (post-spawn step)

  Replaces the rev-2 `grant_initial_caps_for_owner/2` snippet (which
  was hand-rolled per spawn site, drifted between paths). One
  helper → one code path → one source of cap semantics.

  ## Steps

  1. `AgentOwnership.record(agent_uri, owner_user_uri)` — durable write
  2. `CapabilityRegistry.default_grants_from_data_owner(Entity.Agent, agent_uri)`
     iterates every Behavior on Agent Kind, asks each `data_owner/1`,
     synthesizes `[{grantee, %Capability{}}]`. With §3.8 in place,
     Behavior.Agent contributes `{owner_user_uri, :duplicate_cap}`;
     other Behaviors contribute their own. The synthesizer returns
     a flat list.
  3. For each `{grantee, cap}` in the list, dispatch
     `entity://user/<grantee>?action=identity_admin.grant_cap`
     (admin-mode dispatch — `caller: bootstrap_admin`, `caps:
     bootstrap_admin_caps`). Idempotent at the IdentityAdmin layer
     (re-grant of same cap is no-op).
  4. On any grant failure, roll back (1): `AgentOwnership.forget(agent_uri)`.
     Caller's spawn-rollback path then handles broader cleanup.

  ## Return

  `:ok` on full success, `{:error, {:provisioning_failed, step, reason}}` otherwise.

  ## Why split out of `:create_agent` action body

  - DRY: same logic in two places, kept identical structurally
  - Testable: unit test the helper without dragging full action body in
  - Composable: future actions (rename / fork / transfer) reuse it
  """

  @spec provision_agent(URI.t(), URI.t(), map()) ::
          :ok | {:error, term()}
  def provision_agent(%URI{} = agent_uri, %URI{} = owner_user_uri, ctx)
      when is_map(ctx) do
    with :ok                 <- validate_owner_is_user(owner_user_uri),
         :ok                 <- Ezagent.AgentOwnership.record(agent_uri, owner_user_uri),
         {:ok, grants}        = {:ok, Ezagent.CapabilityRegistry.default_grants_from_data_owner(Ezagent.Entity.Agent, agent_uri)},
         :ok                 <- apply_grants(grants, ctx) do
      :ok
    else
      {:error, reason} ->
        # Step 4 — partial-grant rollback. AgentOwnership is the only
        # mutation we own at this layer; caller's broader rollback
        # handles Workspace + Kind state.
        _ = Ezagent.AgentOwnership.forget(agent_uri)
        {:error, {:provisioning_failed, reason}}
    end
  end

  defp apply_grants([], _ctx), do: :ok
  defp apply_grants([{grantee_uri, cap} | rest], ctx) do
    target = URI.new!("#{URI.to_string(grantee_uri)}?action=identity_admin.grant_cap")
    case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
           target: target,
           mode: :call,
           args: %{cap: cap},
           ctx: %{caller: ctx.caller, caps: ctx.caps, reply: {:caller_inbox, self()}}
         }) do
      {:ok, _} -> apply_grants(rest, ctx)
      {:error, reason} -> {:error, {:grant_failed, grantee_uri, cap, reason}}
    end
  end

  defp validate_owner_is_user(%URI{scheme: "entity", host: "user"}), do: :ok
  defp validate_owner_is_user(other), do: {:error, {:owner_not_a_user, other}}
end
```

`Behavior.Workspace.:create_agent`'s action body adds (right before the existing return):

```elixir
:ok <- Ezagent.Agent.Provisioning.provision_agent(agent_uri, ctx.caller, ctx),
```

`Behavior.Agent.:duplicate`'s `spawn_target_directly/5` replaces the `grant_initial_caps_for_owner` step with:

```elixir
:ok <- Ezagent.Agent.Provisioning.provision_agent(target_uri, target_owner_uri, %{caller: bootstrap_granter(), caps: bootstrap_admin_caps()}),
```

(Bootstrap-admin context here because we're synthesizing the defaults; the duplicate action's CALLER cap-check already gated whether this call should happen. The provisioning step itself is a system-trusted operation.)

Acceptance test (§7 row 16 new): explicitly assert that after `:create_agent`, the caller user has `{Behavior.Agent, :duplicate}` cap on the new agent URI (via `Identity.list_caps`). Without this test row, the §7 row 14 assertion is testing one half of the chain in isolation; row 16 tests the full Provisioning round-trip end-to-end.

### 3.7 Mix task — `mix ezagent.agent.duplicate`

New file: `apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.agent.duplicate.ex`.

```bash
mix ezagent.agent.duplicate <source_uri> <target_uri> --owner <owner_uri>
```

Example:

```bash
mix ezagent.agent.duplicate \
    entity://agent/system/cc_linyilun-default \
    entity://agent/acme/cc_linyilun-acme \
    --owner entity://user/acme/linyilun
```

Body mirrors `agent.create.ex` (`parse_uri` + `decompose` + `Invocation.dispatch`). The dispatch target is `<source_uri>?action=agent.duplicate`. Caller context is the operator-admin (mix task running as admin).

---

## 4. Cap-BAC — TWO-SIDED authorization (codex r1 CRITICAL)

### 4.1 The two caps required

| # | Cap                                          | On                  | Held by                                  | Checked at         |
|---|----------------------------------------------|---------------------|------------------------------------------|--------------------|
| 1 | `{Behavior.Agent, :duplicate}`              | **source** agent    | Source-owner OR source-ws-admin          | Dispatch-time      |
| 2 | `{Behavior.Workspace, :create_agent}`       | **target** workspace| Target-owner OR target-ws-admin          | Action-body-time   |

**Both** must succeed. The pre-rev-2 design's "target-ws-admin alone is enough" was the codex r1 CRITICAL — it turned target-admin into a source-data export capability. Rev-2 closes this: a target-ws-admin who cannot satisfy cap #1 sees a clean dispatch denial; their cap on target workspace is irrelevant if source-owner hasn't authorized the export.

### 4.2 Cap resolution (rev 3 — backed by AgentOwnership)

`Behavior.Agent.data_owner(agent_uri)` resolves to the agent's owning USER URI via `AgentOwnership.lookup(agent_uri)` (see §3.8). Consequence: `default_grants_from_data_owner/2` synthesizes an AUTOMATIC grant of `{Behavior.Agent, :duplicate}` to that user at agent-spawn time. The owner can then delegate the cap via standard `Identity.grant_cap` (PR-OWN-3 owner-branch in `IdentityAdmin`) — making bilateral consent for cross-tenant clone a normal user operation, NOT a bootstrap-admin operation (closing codex r2 HIGH-2).

**Pre-AgentOwnership agents:** agents that existed before this PR have no row in `AgentOwnership`; `data_owner/1` falls back to `:no_owner` for them → only bootstrap-admin can grant `:duplicate`. Operators can backfill via a one-shot mix task `mix ezagent.agent.set_owner <agent_uri> <user_uri>` (also in this PR; trivial wrapper around `AgentOwnership.record/2`).

Why this is NOT the same as the rev-2 HIGH-2 (`data_owner: source_uri`) mistake: the previous draft would have grant`:duplicate` cap to `source_uri` (the agent URI itself), and `IdentityAdmin`'s grant-authorization treats agents as not-quite-users. The rev-3 design resolves to the **user URI** via the registry; standard user-grants-user pathway applies; the codex critique is structurally addressed.

### 4.3 Where the `:duplicate` cap comes from (rev 3 — synthesized, not explicit)

At agent-spawn (`Behavior.Workspace.:create_agent` action body, after target spawn), a single NEW step runs BEFORE post-spawn obligations:

```elixir
# new line in Behavior.Workspace.:create_agent action body, BEFORE
# Kind.Server's post-spawn default-grants step
:ok <- Ezagent.AgentOwnership.record(agent_uri, ctx.caller),
```

Then `Kind.Server`'s existing post-spawn pathway (PR-OWN-1) iterates the Agent Kind's Behaviors, calls `data_owner/1` on each, and synthesizes the per-Behavior default grants. With §3.8's `data_owner -> user_uri`, the `{Behavior.Agent, :duplicate}` cap is synthesized AUTOMATICALLY to the owner. The previous rev-2 "explicit grant_initial_caps" line is REMOVED in favor of the standard PR-OWN-1 synthesis path — fewer special cases, one mechanism.

Source-ws admin grant for `:duplicate` happens via `caps-data-ownership-v2.md` §5.2 (Workspace.data_owner = `:any` → admin branch). No spec change needed for that pathway.

<!-- legacy rev-2 explicit-grant block kept for diff context, now superseded
```elixir
# new step in Behavior.Workspace.:create_agent action body, after target spawn
:ok <- grant_initial_caps(agent_uri, [
  {Behavior.Agent, :duplicate, instance: agent_uri},
  # ... existing Identity grants
], ctx_with_creator_caps)
```

The agent's **creator** (the user that called `create_agent`) gets `{Behavior.Agent, :duplicate}` on the new agent's URI. Workspace admins ALSO get this cap via §5.2 admin branch on the workspace (Workspace `cap_subjects` enumeration + `Workspace.data_owner = :any` already routes admin grants per `caps-data-ownership-v2.md`).

This means: a freshly-created agent's `:duplicate` cap is held by (a) its creator and (b) the workspace admin of the source workspace — NEVER automatically by the target-workspace admin (until source-side explicitly grants it).

The grant step lives in SPEC #330's already-shipped `Behavior.Workspace.:create_agent` body (line 158-176 of `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex`); this SPEC's impl PR adds the duplicate-cap row to that grant list.

### 4.4 Caller scenarios (rev-2)

| Caller                                                | Source-side :duplicate cap | Target-ws :create_agent cap | Allowed? |
|-------------------------------------------------------|----------------------------|-----------------------------|----------|
| Source creator, cloning into own workspace             | yes (granted at spawn)     | yes (own workspace)         | **Yes**  |
| Source creator, cloning into another user's workspace  | yes                        | no (no admin on target)     | **No**   |
| Source-ws admin, cloning into own workspace            | yes (admin §5.2)           | yes                         | **Yes**  |
| Source-ws admin, cloning into another ws (no admin)    | yes                        | no                          | **No**   |
| Target-ws admin, NO source cap                         | **NO**                     | yes                         | **No** ← codex r1 CRITICAL fix |
| Bilateral: source-owner authorizes target-ws admin     | yes (granted by source)    | yes                         | **Yes**  |
| Random user                                            | no                         | no                          | **No**   |

The "bilateral" case is the consensual cross-tenant clone path: source-owner explicitly grants `{Behavior.Agent, :duplicate}` on source to a target-workspace admin (via Identity's `grant_cap`), then that target-workspace admin can run the duplicate.

---

## 5. Audit

The dispatch chain logs every `Invocation.dispatch/1`. The duplicate audit record carries:

- `caller` — who initiated
- `target` — `<source_uri>?action=agent.duplicate`
- `args` — `%{target_uri:, target_owner_uri:}`
- `result` — `{:ok, %{source_uri, target_uri, owner_uri}}` or `{:error, _}`

ADDITIONALLY, the snapshot manifest (§3.6) is logged (info level) at snapshot time with its hash so operators can correlate audit + snapshot artifact.

---

## 6. Migration

**Schema-level:** None. New Behavior's slice empty; new Kind.Template callbacks `@optional`; new ETS table created at `EzagentCore.EtsOwner` startup.

**Existing-agent ownership:** agents that existed before this PR have no `AgentOwnership` row → `data_owner -> :no_owner` → only bootstrap-admin can grant `:duplicate` on them. Operator backfill via new mix task:

```bash
mix ezagent.agent.set_owner entity://agent/<ws>/<flavor>_<name> entity://user/<ws>/<user>
```

Trivial wrapper around `AgentOwnership.record/2`. NOT a destructive one-shot — operators apply it agent-by-agent as needed. Listed in impl PR's CHANGELOG.

Rationale: a bulk retroactive migration is a destructive change to a live cap set (`feedback_destructive_migration_anti_pattern`); per-agent operator action is the standard pattern.

---

## 7. Acceptance tests

In impl PR. Rows 7-9 are the codex-r2-CRITICAL durable-cleanup tests; row 10 covers the codex-r2-HIGH-3 no-callback adapter; row 13 covers the codex-r2-MEDIUM-4 live-mutation race; row 14 covers the codex-r2-HIGH-2 bilateral-consent path.

The bar:

1. **Happy path (same workspace, same owner)** — creator clones own cc agent → new agent has independent config_dir; sandbox slice carries new path; new Identity caps are creator's defaults; AgentOwnership row written for target_uri pointing to target_owner_uri; source unchanged.
2. **Bilateral cross-tenant clone (NON-bootstrap)** — non-bootstrap user creates source agent; user delegates `:duplicate` to a target-workspace admin via `Identity.grant_cap`; target-ws admin dispatches `:duplicate`; succeeds. Asserts the codex-r2 HIGH-2 fix is structurally real (not bootstrap-admin-gated).
3. **Cap denial — target-ws admin, NO source grant** — `{:error, :unauthorized}` at dispatch-time. NO target spawn attempted. NO snapshot taken.
4. **Cap denial — source-owner, no target-ws admin** — `{:error, :unauthorized}` at action-body-time. NO target spawn attempted. NO snapshot taken.
5. **Target URI collision** — `target_uri` already alive → `{:error, {:already_exists, target_uri}}`. NO snapshot taken (collision check runs BEFORE snapshot per §3.2 `with` order).
6. **Source missing** — dispatch fails at lookup time.
7. **Snapshot failure rollback** — inject a partial-cp_r fault in `snapshot_config_dir/2`; verify `{:error, {:source_changed_during_snapshot, _}}` returned; verify NO target spawn happened; verify snapshot temp dir cleaned; verify no `AgentOwnership` / `AgentLineage` / `WorkspaceRegistry` rows for target_uri.
8. **restore_from_snapshot failure → DURABLE rollback (codex r2 CRITICAL)** — inject failure in `restore_from_snapshot/3`; verify:
   - target Kind terminated
   - `Kind.Snapshot.get(target_uri)` returns `:error` (snapshot row deleted)
   - `WorkspaceRegistry.lookup(target_uri)` returns `:error`
   - `AgentLineage.lookup(target_uri)` returns `:error`
   - `AgentOwnership.lookup(target_uri)` returns `:error`
   - `template_class.agent_config_dir(target_uri)` does NOT exist on FS
   - `staged_path` does NOT exist on FS
   - target_uri is free for retry (next `:duplicate` succeeds without `{:already_exists, _}`)
9. **sandbox.write_path failure → DURABLE rollback** — same assertions as row 8 but injection point is the `dispatch_sandbox_write_path/3` step. Critically, verify the `:sandbox` slice did NOT persist via `:on_terminate` snapshot (this is the precise hole codex r2 CRITICAL identified).
   - **9a.** Same with injection at `grant_initial_caps_for_owner` step — verify `:identity` slice did NOT persist with the partial cap set.
   - **9b.** Same with injection at `start_pty` step — verify PtyServer is not running, no stranded process.
10. **Plugin with NO snapshot callback (adapter path)** — a Template Class that doesn't implement `snapshot_config_dir/2` at all → `Kind.Template.snapshot_or_default/2` returns `{:ok, %{path: nil, manifest: %{}}}`; `restore_or_noop/3` returns `:noop`; action body completes; target's `sandbox.config_dir_path` is `nil`. (Asserts codex r2 HIGH-3 fix.)
11. **Adoption-refused TOCTOU** — race: pre-create target_uri via concurrent `SpawnRegistry.spawn`, then run duplicate; verify duplicate fails with `{:adopted_not_fresh, target_uri}`. Pre-existing agent at target_uri unchanged.
12. **Invariant: no `Workspace.create_agent` routing** — static grep test asserts `:duplicate` action body never calls the create_agent facade.
13. **Live mutation during snapshot (codex r2 MEDIUM-4)** — start snapshot, concurrently mutate a credentials-like file in source_dir mid-cp_r; expect `{:error, {:source_changed_during_snapshot, _}}`; verify staging cleaned; no target spawned.
14. **AgentOwnership write at spawn (codex r2 HIGH-2 prerequisite)** — `Behavior.Workspace.:create_agent` writes `AgentOwnership.record(agent_uri, ctx.caller)` before post-spawn obligations run; verify row exists with correct user_uri. Verify `Behavior.Agent.data_owner(agent_uri)` returns the user URI, and `default_grants_from_data_owner` synthesizes the `:duplicate` cap to that user.
15. **Restart durability (codex r3 HIGH-3)** — create an agent → confirm AgentOwnership has row + caller has `:duplicate` cap → simulate runtime restart (stop+start `EzagentCore.EtsOwner`) → confirm `AgentOwnership.lookup(agent_uri)` still returns owner_user_uri from SQLite-backed boot reload → confirm owner can dispatch `:duplicate` (no bootstrap-admin required). Also test ETS owner crash mid-flight: kill the ETS owner process, let supervisor restart it, confirm boot_load repopulates from SQLite.
16. **Provisioning end-to-end (codex r3 HIGH-2)** — after `:create_agent`, the caller user holds `{Behavior.Agent, :duplicate}` cap on the new agent URI per `Identity.list_caps` query. Asserts the `Provisioning.provision_agent/3` helper actually fires AND applies grants end-to-end (not just records ownership in isolation per row 14).

---

## 8. Invariant tests (per `feedback_completion_requires_invariant_test`)

### 8.1 FS isolation invariant

`apps/ezagent_core/test/invariants/agent_duplicate_isolation_invariant_test.exs`:

```elixir
test "cloned agent's config_dir is FS-independent of source" do
  # 1. spawn source cc agent
  # 2. write canary file into source's config_dir
  # 3. dispatch :duplicate → target agent
  # 4. read canary from source — present
  # 5. read canary from target — present (snapshot+restore carried it)
  # 6. mutate canary in source
  # 7. read canary in target — UNCHANGED (no symlink / shared inode)
  # 8. delete source's entire config_dir
  # 9. target's config_dir still intact + functional
end
```

### 8.2 No-create-agent-routing invariant

`apps/ezagent_core/test/invariants/agent_duplicate_no_create_agent_routing_test.exs`:

```elixir
test ":duplicate action body does NOT call Workspace.create_agent" do
  source = File.read!("apps/ezagent_domain_chat/lib/ezagent/behavior/agent.ex")
  refute source =~ "Ezagent.Workspace.create_agent("
  refute source =~ "Behavior.Workspace.:create_agent"
  # The whole point of this primitive (memory feedback_agent_clone_not_via_template):
  # clone is on Agent Kind, not via Template/Workspace facades.
end
```

Both invariants must pass for the PR to merge. If either would fail given the architecture, the PR is not complete regardless of unit tests passing.

---

## 9. CLAUDE.md / docs

No CLAUDE.md change. Mix task `--help` auto-renders. Operator docs go in `docs/operations/agent-duplicate.md` in the impl PR (bilingual per `feedback_bilingual_docs_convention`).

---

## 10. Open follow-ups (deferred — flagged per `feedback_dont_defer_what_is_solvable_now`)

- **True cc quiesce.** Rev-3 cc snapshot uses content-hash manifest (pre+post comparison) which DETECTS live mutation — but doesn't PREVENT it. A mid-rotation `.credentials.json` causes snapshot to abort cleanly (test §7 row 13); the operator can retry. Future PR: add a `claude --quiesce` analog OR brief PTY pause + fsync to make snapshots succeed across writes. V1 detects + aborts.
- **LV admin UI for clone.** `/admin/agents/<uri>/clone` form. Deferred per §2.
- **MCP tool surface.** 10-line wrapper post-primitive.
- **Bulk clone.** Wrapper around primitive.
- **Cross-host federation.** cwd semantics on cross-host clone; out of V1.
- **Backfill of AgentOwnership for legacy agents.** `mix ezagent.agent.set_owner` ships in this PR; operators run per-agent.
- **`Behavior.Agent` future actions.** `:rename`, `:archive`, `:transfer-ownership`, etc. — `:transfer-ownership` is a natural follow-up that mutates AgentOwnership; out of V1.

---

## 11. Codex adversarial review (per `feedback_spec_codex_adversarial_review`)

- **Rev 1** (initial draft): codex returned `needs-attention` with 1 CRITICAL, 3 HIGH, 1 MEDIUM. All addressed in rev 2.
- **Rev 2**: codex returned `needs-attention` with 1 CRITICAL (rollback durable-state hole) + 2 HIGH (data_owner :no_owner closed bilateral consent, snapshot optional-callback raises) + 1 MEDIUM (snapshot not actually point-in-time). All addressed in rev 3.
- **Rev 3**: codex returned `needs-attention` with 1 CRITICAL (rollback deletes snapshot BEFORE delayed terminate re-writes it) + 2 HIGH (default_grants_from_data_owner not actually called by spawn lifecycle → owner-derived caps are phantom; AgentOwnership is volatile ETS → restart loses authorization). All addressed in rev 4:
  - §3.4.2 rewritten: synchronous terminate-then-purge ordering with `Process.monitor` `:DOWN` await.
  - §3.9 new: `Ezagent.Agent.Provisioning.provision_agent/3` makes ownership-record + default-grants application explicit and shared between create_agent and duplicate.
  - §3.8 rewritten: SQLite-backed AgentOwnership with ETS read cache (mirroring `Workspace.Store` pattern), `boot_load/0` rehydrates on restart.
  - §7 rows 15 + 16 new: restart durability test + provisioning end-to-end test.
- **Rev 4** (this revision): codex r4 adversarial review will run on this branch before the impl PR opens. If r4 is clean, this SPEC merges via admin merge per `feedback_admin_merge_authorized`. If r4 still finds CRITICAL+ findings, this becomes a "needs more architectural input" pause — Allen is notified via Feishu before further iteration.

---

## 12. User-assist steps (per `feedback_flag_user_assist_steps`)

**None.** Impl PR runs entirely in CI + local mix tests. End-to-end manual verification via `mix ezagent.agent.duplicate` against `linyilun-default` is *suggested* but not gated.
