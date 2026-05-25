# SPEC — Agent duplicate/clone primitive (Behavior.Agent `:duplicate`)

**Status:** DRAFT rev 2 · 2026-05-25 (codex r1 fixes)
**Tier:** `apps/ezagent_domain_chat/` (new `Behavior.Agent` + action) + `apps/ezagent_core/` (Kind.Template snapshot callback + BehaviorRegistry slot) + `apps/ezagent_plugin_cc/` (cc snapshot impl) + `apps/ezagent_domain_workspace/` (mix task wrapper)
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
- `mix ezagent.agent.duplicate <source_uri> <target_uri> --owner <owner_uri>` produces a brand-new live agent at `target_uri`, with its own config_dir (FS-independent of source, point-in-time-consistent snapshot), fresh Identity caps, and **NO** chat-history coupling to source.
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

#### 3.4.2 `rollback_partial_target/3`

```elixir
defp rollback_partial_target(target_uri, staged_path, err) do
  # Order matters: terminate Kind first (stops any in-flight work on the
  # target's slice), then registry cleanup, then FS cleanup.
  _ = Ezagent.Kind.terminate(target_uri)
  _ = Ezagent.WorkspaceRegistry.unbind(target_uri)
  _ = Ezagent.AgentLineage.forget(target_uri)
  # Remove the staged config dir AND the final-dir if restore_snapshot
  # progressed that far. Final-dir is `template_class.agent_config_dir(target_uri)`.
  _ = File.rm_rf(staged_path)
  case template_class_for(target_uri) do
    {:ok, tc} when is_atom(tc) -> _ = tc.destroy_config_dir(target_uri, tc.agent_config_dir(target_uri))
    _ -> :ok
  end
  err
end
```

This is the only "checked rollback" shape allowed under `feedback_let_it_crash_no_workarounds` — it's not a defensive catch-all, it's a deterministic teardown of resources THIS action created, with the error preserved verbatim.

### 3.5 Stage → spawn ordering rationale (codex r1 HIGH-3)

Pre-rev-2: spawn target → cp_r config over it → on cp_r fail, leave target alive.

Rev-2: snapshot source to temp → spawn target → restore snapshot into target → on any post-spawn fail, rollback target completely.

Why the two-phase: the SNAPSHOT phase is purely source-side + temp-dir; if it fails, no target was ever created (target_uri stays free). The SPAWN phase is bounded by `rollback_partial_target/3`. The single failure that creates an inconsistent state (cp_r fails after target is up but BEFORE rollback) is now self-recovered: the rollback runs Kind termination + dir cleanup, leaving target_uri free for retry.

### 3.6 `Kind.Template.snapshot_config_dir/2` — new optional callback

New `@optional_callback` on `Ezagent.Kind.Template`:

```elixir
@doc """
Take a point-in-time snapshot of the source agent's config_dir into
a temp dir, returning the temp path + a manifest.

The plugin owns quiesce semantics — for cc, this means (V1): record
the source PTY state, run `cp_r` with a marker, verify file count
matches a pre-cp_r `find . | wc -l` (basic partial-write detector).
Future cc V2 may add real quiesce (pause claude, fsync, copy, resume).

The temp dir lives under `Ezagent.Home.path("cc-agents/.snapshots")/<uuid>/`
so it's outside the agent-config tree and can be safely rm'd.

Returns `{:ok, %{path: String.t(), manifest: map()}}` or
`{:error, term()}`. On failure, the plugin MUST clean its own temp
partial — the caller (Behavior.Agent.:duplicate) does NOT attempt
to clean a path it never received.

@param source_uri  — the source agent URI
@param source_dir  — the source's current config_dir_path

The manifest carries plugin-specific metadata that
`restore_from_snapshot/3` (next callback) needs to do the unpack.
For cc V1: `%{file_count: N, marker: "...", taken_at: DateTime}`.
"""
@callback snapshot_config_dir(source_uri :: URI.t(), source_dir :: String.t()) ::
            {:ok, %{path: String.t(), manifest: map()}} | {:error, term()}

@doc """
Restore a snapshot (as produced by `snapshot_config_dir/2`) into the
target agent's per-agent config_dir location. The plugin computes
the target path via its `agent_config_dir/1` builder, atomically
moves the snapshot into place, then writes the
`.ezagent-config-complete` marker as the LAST step.

Caller (Behavior.Agent.:duplicate) is responsible for rm'ing the
snapshot temp dir on success or failure.

Returns `{:ok, final_path}` or `{:error, term()}`.
"""
@callback restore_from_snapshot(
            target_uri :: URI.t(),
            snapshot_path :: String.t(),
            manifest :: map()
          ) :: {:ok, String.t()} | {:error, term()}

@optional_callbacks snapshot_config_dir: 2, restore_from_snapshot: 3
```

Plugins that don't implement these (echo, curl, np — anything that doesn't manage config_dir) result in `source_meta.template_class.snapshot_config_dir` returning `:no_op` and the action body skipping the stage+restore — those agents clone "structurally" only (the spawn happens, but there's no FS state to carry).

For echo/curl/np: `snapshot_config_dir/2` SHOULD be implemented to return `{:ok, %{path: nil, manifest: %{}}}` explicitly — making "I have no config_dir to snapshot" a positive callback, not a missing-function default. The action body checks `path == nil` and skips restore entirely.

#### 3.6.1 cc V1 snapshot impl (illustrative)

```elixir
@impl Ezagent.Kind.Template
def snapshot_config_dir(%URI{} = source_uri, source_dir) when is_binary(source_dir) do
  snapshots_root = Path.join(Ezagent.Home.path("cc-agents"), ".snapshots")
  snapshot_dir = Path.join(snapshots_root, "#{:erlang.unique_integer([:positive])}-#{System.os_time(:millisecond)}")

  with :ok               <- File.mkdir_p(snapshots_root),
       pre_count          = file_count(source_dir),
       {:ok, _}           <- File.cp_r(source_dir, snapshot_dir),
       post_count         = file_count(snapshot_dir),
       true               <- pre_count == post_count or {:error, {:partial_copy, pre_count, post_count}},
       :ok                <- File.chmod(snapshot_dir, 0o700),
       :ok                <- chmod_credentials(snapshot_dir) do
    manifest = %{
      file_count: post_count,
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
```

The `pre_count == post_count` check is a coarse "did we miss files" gate. It won't catch a `.credentials.json` mid-rotation (file count stays same, content changes); V1 documents this as a known limitation. The invariant test (§8) doesn't trigger this race because it uses static canary files.

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

### 4.2 Cap resolution

`Behavior.Agent.data_owner/1` returns `:no_owner`. Consequence: `default_grants_from_data_owner/2` synthesizes NO automatic grant of `{Behavior.Agent, :duplicate}` on agent-spawn. The cap is granted EXPLICITLY (see §4.3).

This is intentional. The alternative (returning source_uri as data_owner) would silently grant the cap to the agent itself (codex r1 HIGH-2 — `default_grants_from_data_owner/2:371` uses the returned URI verbatim as grantee). And adding "agent → owning user" resolution requires either (a) a new lineage field that doesn't exist OR (b) reaching into Workspace owner_uri / AgentLineage.granted_by from inside the Behavior, which couples Behavior to ESR-domain registries (anti-pattern per `feedback_north_star_plugin_isolation`).

### 4.3 Where the `:duplicate` cap comes from

At agent-spawn (`Behavior.Workspace.:create_agent` action body, after the Agent Kind is alive), an additional explicit grant runs:

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

**Schema-level:** None. New Behavior's slice empty; new Kind.Template callbacks `@optional`.

**Existing-agent cap:** the `{Behavior.Agent, :duplicate}` cap on PRE-EXISTING agents (those alive before this PR) is NOT retroactively granted. The grant happens only at NEW agent-spawn via the §4.3 grant-list change. Operators wanting clone on a legacy agent must run an explicit `mix ezagent.identity.grant_cap` (existing CLI). Documented in the impl PR's CHANGELOG.

Rationale: a one-shot retroactive grant migration is a destructive change to a live cap set (`feedback_destructive_migration_anti_pattern`); the explicit-grant path is the standard cap workflow.

---

## 7. Acceptance tests

In impl PR. The bar:

1. **Happy path (same workspace, same owner)** — creator clones own cc agent → new agent has independent config_dir; sandbox slice carries new path; new Identity caps are creator's defaults; source unchanged.
2. **Bilateral cross-tenant clone** — source-owner grants `:duplicate` to a target-workspace admin; target-ws admin runs duplicate; succeeds.
3. **Cap denial — target-ws admin, NO source grant** — `{:error, :unauthorized}` at dispatch-time. NO target spawn attempted. NO snapshot taken.
4. **Cap denial — source-owner, no target-ws admin** — `{:error, :unauthorized}` at action-body-time. NO target spawn attempted. NO snapshot taken.
5. **Target URI collision** — `target_uri` already alive → `{:error, {:already_exists, target_uri}}`. NO snapshot taken (collision check runs BEFORE snapshot per §3.2 `with` order).
6. **Source missing** — dispatch fails at lookup time.
7. **Snapshot failure** — inject a partial-cp_r fault in `snapshot_config_dir/2`; verify `{:error, {:partial_copy, _, _}}` returned; verify NO target spawn happened; verify snapshot temp dir cleaned.
8. **Post-spawn restore failure** — inject failure in `restore_from_snapshot/3`; verify target Kind terminated; WorkspaceRegistry unbound; AgentLineage forgotten; staged_path removed; target_uri free for retry.
9. **Deep-copy isolation** — modify a file in source `config_dir` post-clone; target's file at same relative path unchanged. **(Invariant — §8.)**
10. **Non-cc flavor (echo)** — `snapshot_config_dir/2` returns `{:ok, %{path: nil, manifest: %{}}}`; restore skipped; target spawns without FS state; sandbox slice `config_dir_path: nil`.
11. **Adoption-refused TOCTOU** — race: pre-create target_uri via concurrent `SpawnRegistry.spawn`, then run duplicate; verify duplicate fails with `{:adopted_not_fresh, target_uri}`. Pre-existing agent at target_uri unchanged.
12. **Invariant: no `Workspace.create_agent` routing** — static grep test asserts `:duplicate` action body never calls the create_agent facade.

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

- **True cc quiesce.** V1 cc snapshot uses pre/post file-count gate. A `.credentials.json` rotation during snapshot would not be detected. Future PR: add a `claude --quiesce` analog OR a brief PTY pause + fsync OR a hash manifest. V1 documents the limitation; production cloning of a freshly-token-rotating agent is rare.
- **LV admin UI for clone.** `/admin/agents/<uri>/clone` form. Deferred per §2.
- **MCP tool surface.** 10-line wrapper post-primitive.
- **Bulk clone.** Wrapper around primitive.
- **Cross-host federation.** cwd semantics on cross-host clone; out of V1.
- **Retroactive duplicate-cap grant for legacy agents.** Documented in §6 — operators run `mix ezagent.identity.grant_cap` explicitly.

---

## 11. Codex adversarial review (per `feedback_spec_codex_adversarial_review`)

- **Rev 1** (initial draft): codex returned `needs-attention` with 1 CRITICAL, 3 HIGH, 1 MEDIUM. All addressed in rev 2 (see header `Rev 2 changes` bullet list + §3.4 §3.5 §3.6 §4 rewrites).
- **Rev 2** (this revision): codex adversarial review will run on this branch before the impl PR opens.

---

## 12. User-assist steps (per `feedback_flag_user_assist_steps`)

**None.** Impl PR runs entirely in CI + local mix tests. End-to-end manual verification via `mix ezagent.agent.duplicate` against `linyilun-default` is *suggested* but not gated.
