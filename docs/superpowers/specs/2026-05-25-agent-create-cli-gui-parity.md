# SPEC — Agent create: CLI ↔ GUI parity via single dispatch path

**Status:** DRAFT rev 1 · 2026-05-25
**Tier:** `apps/ezagent_domain_workspace/` (new Behavior action) + `apps/ezagent_domain_identity/` (CLI rewrite) + `apps/ezagent_plugin_liveview/` (LV rewrite)
**Trigger:** Allen 2026-05-25 — CLI and LV agent creation must derive from a single Behavior `:create_agent` action, then deprecate the bypass path. Closes audit Finding #137 row "agent.create".
**Predecessors:**
- `docs/futures/todo.md` § "CLI ↔ GUI parity (audit findings #137 still partial)" — `mix ezagent.agent.create` row
- `docs/superpowers/specs/2026-05-24-caps-data-ownership-v2.md` (data_owner contract)
- `docs/superpowers/specs/2026-05-23-capability-registry.md` (single cap-subject registration entry)
- SKILL P14 (dispatch is the only path between Kinds), P19 (3 dispatch hygiene rules), P3 (single source of truth)
- Codex PR #304 round-2 HIGH ("NOT a bare FacadeRegistry op — that bypasses dispatch")
- `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex` `add_template/3` (orchestration the LV currently uses)
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/agent_new_live.ex` `register_and_instantiate/3` (current LV path)
- `apps/ezagent_domain_identity/lib/mix/tasks/ezagent.agent.create.ex` (current CLI bypass — `SpawnRegistry.spawn + Identity.grant_cap`, no template, no PTY)
**Companion ZH:** `2026-05-25-agent-create-cli-gui-parity.zh_cn.md`.

---

## 0. Allen's directive (verbatim 2026-05-25)

> "CLI 和 GUI 创建 agent 的路径必须收敛到一个 Behavior `:create` action — 一个代码路径。CLI 是薄包装。LV 也走同一个 dispatch。然后把 bypass path 删掉。no back-compat。"

Operational constraint (reaffirmed 2026-05-25): no back-compat shim (`feedback_let_it_crash_no_workarounds`).

---

## 1. Goal

**One dispatchable Behavior action — `Behavior.Workspace.:create_agent` — is the single code path through which agents are created**, whether the caller is the CLI (`mix ezagent.agent.create`), the LV (`/admin/agents/new`), a future MCP tool, or programmatic test fixture. The path is CapBAC-checked (caller needs `Behavior.Workspace` cap on the target workspace) and produces a fully-provisioned agent (Kind alive, sandbox slice populated, PTY started for cc, PtyServer started for echo when `with_pty: true`).

After this SPEC's impl PR lands:
- Both `mix ezagent.agent.create` and the LV form call the same facade `Ezagent.Workspace.create_agent/3`, which dispatches `:create_agent`.
- The CLI's old `SpawnRegistry.spawn + Identity.grant_cap` bypass path is **deleted** (no stub, no back-compat).
- The LV's old direct call to `Ezagent.Workspace.add_template + invoke_template_now` is **deleted** (the orchestration moves into the dispatched action body).
- A cc-flavor agent created via CLI now has a PTY (the bug the audit flagged); operator behaviour is identical between CLI and LV.
- An invariant test guards the unification: direct `SpawnRegistry.spawn(...)` for `entity://agent/` URIs OUTSIDE the new `:create_agent` action body fails CI.

---

## 2. Scope

In-scope:
- New `:create_agent` action on `Ezagent.Behavior.Workspace` with cap subject, `data_owner/1` semantics derived from existing Workspace Behavior (workspace-admin granted), and `invoke/4` body wrapping the current LV orchestration.
- New facade `Ezagent.Workspace.create_agent/3` (the dispatch entry the CLI + LV both call).
- Rewrite `Mix.Tasks.Ezagent.Agent.Create` (`mix ezagent.agent.create`) — `do_create` becomes a thin construct-args + dispatch wrapper.
- Rewrite `EzagentPluginLiveview.AgentNewLive.handle_event("create_agent", ...)` — `register_and_instantiate/3` deleted, replaced by `Workspace.create_agent/3` call.
- Invariant test: `apps/ezagent_core/test/invariants/agent_create_single_path_test.exs` — greps production code for direct `SpawnRegistry.spawn(...)` against `entity://agent/` URIs OUTSIDE the action body's call site. Allowlist is the action body + reconciler.
- Acceptance tests (in impl PR, not this SPEC) — see §7.

Out-of-scope:
- Other `mix ezagent.*` tasks (user.create, user.set_password, feishu.bind, etc.) — they each get their own follow-up PR per the audit table in `docs/futures/todo.md`.
- The reconciler's `spawn_fresh/4` path (its `SpawnRegistry.spawn_detailed/1` use is explicitly allowlisted — orchestrator-spawned workers are a different surface; agent-CREATE via this SPEC is the operator-facing surface).
- The Phoenix.Channel bridge re-spawn path (`EzagentPluginCc.Channel.join/3` calls `SpawnRegistry.spawn(agent_uri)` to ensure the URI is alive before binding the channel — that's a defensive ensure, not a CREATE; allowlisted).
- Federation / cross-runtime agent creation (single-machine assumption holds; CLI talks to local runtime via distributed Erlang RPC, same as today).

---

## 3. Design

### 3.1 Behavior action — `Ezagent.Behavior.Workspace`

New action on the existing Workspace Behavior (NOT a new Behavior — `Workspace` is the scope-owning Kind; agent creation is workspace-scoped):

```elixir
@impl Ezagent.Behavior
def actions, do: [..., :create_agent]   # add to existing list

@impl Ezagent.Behavior
def cap_subjects do
  [
    ...,
    {:create_agent,
     "create a new agent in this workspace (registers Template Class, " <>
       "spawns Agent Kind, starts PTY for cc/echo-with-PTY)"}
  ]
end

@impl Ezagent.Behavior
def interface do
  %{
    ...,
    create_agent: %{
      description: "Provision a new agent (Template Class + spawn) in this workspace",
      args: %{
        flavor: :string,         # "cc" | "echo" | "curl" | future
        name: :string,           # entity-name suffix (becomes <flavor>_<name>)
        cwd: :string,            # "" for flavors that don't need it
        with_pty: :boolean       # echo opt-in for /bin/bash -i sidecar
      },
      returns: %{agent_uri: :uri, template_name: :string},
      modes: [:call]
    }
  }
end
```

`data_owner/1` stays `:any` (already returned by `Behavior.Workspace.data_owner/1` — workspace admin can grant via §5.2 admin branch). No change to `data_owner` semantics.

### 3.2 Action body

The `invoke(:create_agent, slice, args, ctx)` callback runs inside the Workspace Kind's GenServer and orchestrates EXACTLY what the LV facade does today, but inline + dispatched:

```elixir
def invoke(:create_agent, slice, %{flavor: flavor, name: name, cwd: cwd, with_pty: with_pty?}, ctx) do
  workspace_uri = Map.get(ctx, :self_uri)
  workspace_name = workspace_uri.host

  with :ok <- validate_flavor(flavor),
       :ok <- validate_name(name),
       :ok <- validate_cwd_for_flavor(flavor, with_pty?, cwd),
       {:ok, agent_uri} <- compose_agent_uri(flavor, name, workspace_name),
       :ok <- refuse_if_exists(agent_uri),
       {:ok, tmpl_name, new_slice} <- register_template_and_mutate_slice(slice, flavor, agent_uri, %{cwd: cwd, with_pty?: with_pty?}, workspace_name),
       :ok <- invoke_template(workspace_uri, tmpl_name, flavor, agent_uri) do
    {:ok, new_slice, %{agent_uri: agent_uri, template_name: tmpl_name}}
  else
    {:error, _} = err -> err
  end
end
```

Implementation notes:

- **Template registration** for `cc` and `echo` flavors writes a Workspace-scoped template (matches current LV `register_and_instantiate/3` for those flavors verbatim) + persists to `Ezagent.Workspace.Store` + adds to `slice.session_templates`.
- **Direct-spawn** for `curl` / `np` / future flavors that have no Template Class: `SpawnRegistry.spawn(agent_uri)` inline (the only allowlisted call site for `entity://agent/` URIs per §4 invariant).
- **Loader.invoke_template** called for cc/echo to fully provision (Agent Kind + sidecar). This is a synchronous call OUT of the GenServer — safe because Loader.invoke_template does NOT dispatch back to Workspace (it only calls Template Class's `instantiate/3` which spawns Agent + PtyServer).
- **`refuse_if_exists/1`** checks `KindRegistry.lookup(agent_uri)` and returns `{:error, {:already_exists, _}}` (same shape as LV).
- The action returns `{:ok, new_slice, %{agent_uri, template_name}}`; the dispatch reply carries that map back to the caller.

### 3.3 Facade — `Ezagent.Workspace.create_agent/3`

```elixir
@spec create_agent(URI.t(), map(), map()) ::
        {:ok, %{agent_uri: URI.t(), template_name: String.t()}}
        | {:error, term()}
def create_agent(%URI{} = workspace_uri, args, %{caller: caller_uri, caps: caps} = ctx)
    when is_map(args) do
  target = URI.new!("#{URI.to_string(workspace_uri)}?action=workspace.create_agent")

  Ezagent.Invocation.dispatch(%Ezagent.Invocation{
    target: target,
    mode: :call,
    args: args,
    ctx: %{caller: caller_uri, caps: caps, reply: {:caller_inbox, self()}}
  })
end
```

After a successful create_agent dispatch, the CALLER (CLI or LV) grants initial caps via the existing `identity.grant_cap` dispatch loop (caller's ctx, caller's caps — preserves CapBAC). The facade does NOT inline cap grants — keeping caller-context-bound is the canonical authority shape (§3.4).

### 3.4 Cap grants stay caller-context

The LV's existing `grant_all/3` loop (one `identity.grant_cap` dispatch per cap, caller's ctx) is preserved. The CLI gains the same loop (it previously called `Ezagent.Identity.grant_cap/3` directly, a facade bypass). Both call sites now dispatch:

```elixir
Invocation.dispatch(%Invocation{
  target: URI.new!("#{agent_uri}?action=identity.grant_cap"),
  mode: :call,
  args: %{cap: cap},
  ctx: %{caller: caller_uri, caps: caller_caps, reply: {:caller_inbox, self()}}
})
```

This is the SAME pattern the LV already uses, lifted into a shared helper `Ezagent.Workspace.grant_initial_caps/3` so the CLI and LV both call it.

### 3.5 CLI rewrite — `Mix.Tasks.Ezagent.Agent.Create`

```elixir
defp do_create(agent_uri_str, opts) do
  caps_str = Keyword.get(opts, :caps, "")
  allow_allcaps = Keyword.get(opts, :allow_allcaps, false)
  cwd = Keyword.get(opts, :cwd, "")
  with_pty? = Keyword.get(opts, :with_pty, false)

  with {:ok, agent_uri} <- parse_uri(agent_uri_str),
       {:ok, workspace_uri, flavor, name} <- decompose(agent_uri),
       :ok <- check_allcaps_flag(caps_str, allow_allcaps),
       {:ok, caps} <- Ezagent.Capability.Parser.parse(caps_str, Ezagent.Entity.User.admin_uri()),
       {:ok, %{agent_uri: created_uri}} <-
         Ezagent.Workspace.create_agent(workspace_uri,
           %{flavor: flavor, name: name, cwd: cwd, with_pty: with_pty?},
           %{caller: Ezagent.Entity.User.admin_uri(), caps: Ezagent.Entity.User.admin_caps()}
         ),
       :ok <- Ezagent.Workspace.grant_initial_caps(created_uri, caps,
         %{caller: Ezagent.Entity.User.admin_uri(), caps: Ezagent.Entity.User.admin_caps()}) do
    Mix.shell().info("✓ created #{URI.to_string(created_uri)}")
    Mix.shell().info("  caps: #{length(caps)}")
  else
    {:error, reason} -> Mix.raise("create failed: #{inspect(reason)}")
  end
end
```

New `--cwd` and `--with-pty` flags exposed so CLI parity with the LV's PTY / cwd controls is complete (per Allen audit Finding 4 — the LV has PTY + cwd; the CLI must too).

Removed:
- `--no-spawn` flag (the LV doesn't have a "register without spawn" mode; the bypass-only path it relied on is deleted).
- Direct `SpawnRegistry.spawn` call site.
- Direct `Ezagent.Identity.grant_cap` call site.

### 3.6 LV rewrite — `EzagentPluginLiveview.AgentNewLive`

`handle_event("create_agent", ...)` collapses from ~40 lines (with three `register_and_instantiate/3` clauses for cc/echo/other) into a single dispatched call:

```elixir
def handle_event("create_agent", %{"agent" => params}, socket) do
  with :ok <- validate_flavor(...),
       :ok <- validate_name(...),
       :ok <- validate_cwd_for_flavor(...),
       {:ok, caps} <- Capability.Parser.parse(caps_str, caller_uri(socket)),
       workspace_uri = current_workspace_uri(socket),
       {:ok, %{agent_uri: agent_uri}} <-
         Ezagent.Workspace.create_agent(workspace_uri,
           %{flavor: flavor, name: name, cwd: cwd, with_pty: with_pty?},
           %{caller: caller_uri(socket), caps: caller_caps(socket)}),
       :ok <- Ezagent.Workspace.grant_initial_caps(agent_uri, caps,
         %{caller: caller_uri(socket), caps: caller_caps(socket)}) do
    encoded = URI.encode_www_form(URI.to_string(agent_uri))
    {:noreply, push_navigate(socket, to: "/identities/agents/#{encoded}")}
  else
    {:error, reason} -> {:noreply, assign(socket, :flash_error, friendly_error(reason))}
  end
end
```

Deleted from the LV (moves into the action body or facade):
- `register_and_instantiate/3` (all three clauses).
- `compose_uri/3` (the action body owns URI composition).
- `refuse_if_exists/1` (the action body owns existence check).
- `grant_all/3` (the facade owns the cap-grant loop).
- `agent_name/1` (no longer needed at LV layer — action body owns it).

Form validation (`validate_flavor/2`, `validate_name/1`, `validate_cwd_for_flavor/3`, `validate_cwd_dir/1`) STAYS in the LV — these are early-feedback UX validators; the action body re-runs them as a safety net (defence in depth — LV validators don't reach over RPC from a future remote LV).

### 3.7 Why the cap subject is `Behavior.Workspace.create_agent` (not a new Behavior on Agent Kind)

Three reasons:

1. **Dispatch needs an existing target.** A `:create` action whose dispatch target is the new agent URI fails ReadyGate (target doesn't exist yet). The Workspace URI exists; dispatching against it works.
2. **Authority shape matches.** Creating an agent IN workspace X is a workspace-scoped operation — workspace admins should be able to do it, mirroring `:add_template` / `:add_member` / `:set_routing_rules`. The cap shape is identical to existing Workspace cap subjects.
3. **No new Behavior file required.** Allen's directive prefers minimal new abstractions (`feedback_let_it_crash_no_workarounds`; SKILL P8 "少发明,多装配"). One new action on an existing Behavior is the least-invented option.

Allen's task description floated `Ezagent.Behavior.Agent.:create` as an option ("or create that Behavior if it doesn't exist") — this SPEC picks the simpler equivalent. The cap_subject string makes the intent obvious to operators.

---

## 4. Invariant test

`apps/ezagent_core/test/invariants/agent_create_single_path_test.exs`:

```elixir
defmodule EzagentCore.Invariants.AgentCreateSinglePathTest do
  use ExUnit.Case, async: true

  # Direct `SpawnRegistry.spawn(...)` for entity://agent/ URIs is FORBIDDEN
  # outside the allowlist below. The unified create path goes through
  # `Behavior.Workspace.:create_agent` action.
  @forbidden ~r/SpawnRegistry\.(spawn|spawn_detailed)\s*\(\s*[^)]*entity:\/\/agent/

  # Allowlisted call sites — each has a documented reason this is NOT
  # an operator-facing create:
  @allowlist [
    # The new action body — the ONE legitimate operator-facing create.
    "apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex",
    # cc channel re-spawn (defensive ensure — see EzagentPluginCc.Channel.join/3).
    "apps/ezagent_plugin_cc/lib/ezagent_plugin_cc/channel.ex",
    # Reconciler / spawn_fresh — orchestrator-spawned workers, not operator-facing.
    "apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex",
    # SpawnRegistry itself.
    "apps/ezagent_core/lib/ezagent/spawn_registry.ex"
  ]

  test "operator-facing create goes through Behavior.Workspace.:create_agent only" do
    # ... grep production files, skip test/, skip allowlisted, assert no hits ...
  end
end
```

This invariant **fails** if a future PR re-introduces a CLI / LV / mix task that directly spawns an `entity://agent/` URI without going through the `:create_agent` action.

---

## 5. Migration

Per Allen no-back-compat:

- `Mix.Tasks.Ezagent.Agent.Create.do_create/2` rewritten in-place; old `--no-spawn` flag deleted; new `--cwd` + `--with-pty` flags added; usage error message updated.
- `EzagentPluginLiveview.AgentNewLive.register_and_instantiate/3` + helpers deleted; `handle_event("create_agent", ...)` rewritten.
- No DB migration. No version flag. No stub.
- Tests using the old CLI flag `--no-spawn` are updated to use the new dispatch path (the test count is small — the audit module-level doc already notes the bypass nature).

If any external script calls `mix ezagent.agent.create --no-spawn`, it BREAKS with a usage error (intentional, per `feedback_let_it_crash_no_workarounds`).

---

## 6. PR sequence

Single impl PR — the change is tight enough to land atomically:

**PR: `feat/agent-create-cli-gui-parity`**
1. Add `:create_agent` action + cap subject + interface entry on `Ezagent.Behavior.Workspace`.
2. Implement action body in `Ezagent.Behavior.Workspace.invoke(:create_agent, ...)` (template registration + slice mutation + Loader.invoke_template + direct-spawn fallback). Helpers (`validate_flavor/2`, `compose_agent_uri/3`, etc.) moved from the LV into the Behavior module.
3. Add facade `Ezagent.Workspace.create_agent/3` + `Ezagent.Workspace.grant_initial_caps/3`.
4. Rewrite `Mix.Tasks.Ezagent.Agent.Create` (CLI thin wrapper).
5. Rewrite `EzagentPluginLiveview.AgentNewLive.handle_event("create_agent", ...)` (LV thin wrapper).
6. Delete obsolete helpers from the LV.
7. Add invariant test `agent_create_single_path_test.exs`.
8. Update + add acceptance tests (§7).
9. Run `mix ezagent.agent.create entity://agent/system/test-parity --flavor cc --cwd /tmp` manually; verify agent exists in KindRegistry + has PTY (sandbox slice `config_dir_path` non-nil).
10. `mix test`, `mix format --check-formatted`, `mix ezagent.caps.audit` all clean.
11. Codex r1 + r2 per round-2 cap.
12. Admin merge.

---

## 7. Acceptance tests (in impl PR)

`apps/ezagent_domain_workspace/test/ezagent/behavior/workspace_create_agent_test.exs`:

1. **CLI path produces a cc-flavor agent with PTY.** Dispatch `:create_agent` with `flavor: "cc", cwd: <tmpdir>`. Assert agent URI is in KindRegistry, `Sandbox.invoke(:read, ...)` returns non-nil `config_dir_path`, PtyServer is registered.
2. **LV path produces an identical state.** Same dispatch, different caller URI. Assert the same shape — agent URI, sandbox slice, PtyServer.
3. **echo-with-PTY produces a /bin/bash -i sidecar.** Dispatch with `flavor: "echo", with_pty: true, cwd: <tmpdir>`. Assert PtyServer is up.
4. **echo-without-PTY produces no sidecar.** Dispatch with `flavor: "echo", with_pty: false`. Assert no PtyServer.
5. **curl direct-spawn works.** Dispatch with `flavor: "curl"`. Assert agent URI in KindRegistry, no PtyServer.
6. **Cap denial: caller without Workspace cap on this workspace.** Dispatch from a non-admin caller without the workspace cap → `{:error, :unauthorized}`.
7. **Cap grant after create works.** After successful create, dispatch `identity.grant_cap` from same caller → `{:ok, _}`.
8. **Refuse if exists.** Dispatch twice with same flavor/name → second call returns `{:error, {:already_exists, _}}`.

The invariant test (§4) is the gate per SKILL P6 (completion claim requires invariant test).

---

## 8. Open questions

- **OQ-1: Should `:create_agent` be `:cast` or `:call`?** `:call` — the caller needs the agent_uri back to navigate / grant caps. `:cast` would force a separate read-back, doubling round-trips. Resolved: `:call`.
- **OQ-2: Should the action body call `Loader.invoke_template` directly, or dispatch `:invoke_template`?** Direct call — `Loader.invoke_template` is the existing facade pattern used by `Workspace.add_template/3`. No dispatch action exists for it. Inventing one for this SPEC violates P8 (少发明). Resolved: direct call.
- **OQ-3: Do we need `template_args` field in args?** No — `cwd` + `with_pty` cover all current template params. Future flavors with more complex params can extend the args map; the action body validates per-flavor. Resolved: keep args flat.

---

## 9. Risks

- **R-1: Template instantiate inside Workspace GenServer blocks the GenServer.** The Workspace Kind handles all workspace mutations serialized; an in-progress create_agent blocks add_member / set_routing_rules calls. Mitigation: SpawnRegistry.spawn is normally fast (<200ms); Workspace mutations are infrequent (operator-driven, not chat traffic). If this surfaces as a real bottleneck, follow-up: spawn template invoke in a Task and return a pending-status reply.
- **R-2: The action body grew larger.** ~150 LOC of validation + orchestration inside one `invoke/4` clause. Mitigation: helpers extracted to private functions in the same module (mirrors existing `Behavior.Workspace` style).
- **R-3: Tests depending on old CLI flag `--no-spawn` break.** Mitigation: grep + update; small surface area (none in production runbooks per Allen).

---

## 10. Non-goals

- Generic "create any Kind" action (would be P8 over-abstraction).
- Federation-aware create (single-machine; runtime RPC remains the boundary).
- Template Class authoring kit (each plugin's Template Class is its own SPEC; this SPEC only consumes existing classes via `Loader.invoke_template`).
