defmodule Ezagent.Entity.Agent do
  @moduledoc """
  Agent Kind — represents an external participant (e.g. a Claude CLI
  session via the CC bridge) inside ESR's chat router.

  Per Decision #61: an Agent is a peer of admin User in the Session —
  it can send messages (when its bridge surfaces a reply) and receive
  messages (forwarded by Session). The bridge wire is provided by
  `EzagentPluginCc` (Phoenix.Channel WebSocket); the Agent
  Kind itself stays transport-agnostic.

  ## Spawn lifecycle

  Two paths spawn an Agent Kind:

  1. **Cold spawn** from a workspace's `cc.pty` Template Class →
     `EzagentPluginCc.Template.instantiate/3` starts a PtyServer
     which writes the v2 mcp.json; claude reads it and spawns the
     Python WS bridge.

  2. **Channel-join spawn** when the WS bridge joins
     `cc:bridge:<agent_uri>` — `EzagentPluginCc.Channel.join/3`
     calls `Ezagent.SpawnRegistry.spawn(agent_uri)` to ensure the
     Agent Kind exists in `KindRegistry` before binding the channel
     pid to it (PR 32a).

  Both paths land at:

      Ezagent.SpawnRegistry.spawn(agent_uri)
        → Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri})

  (V1 prevention, Allen 2026-05-21: `Ezagent.Kind.spawn/2` is the sole
  entry; Agent declares `EzagentDomainChat.AgentSupervisor` via its
  `supervisor/0` callback.)

  This is the realization of memory `feedback_north_star_plugin_isolation`:
  the Agent module knows nothing about bridges; the bridge plugin
  knows nothing about Chat internals. `Ezagent.Kind.spawn/2` +
  `Ezagent.Kind.Server` are the only contact points, and they're both
  `ezagent_core` machinery.

  ## URI shape (PR #141 SPEC v2)

  Bridges supply `agent_uri` either via the mcp.json `env` field
  (preferred — PtyServer writes it deterministically) or via
  `EZAGENT_AGENT_URI` operator-shell env (legacy fallback). The
  canonical shape is `entity://agent/<flavor>_<name>` per SPEC §5.14
  (flavor in name prefix); anything matching `entity://agent/*` works
  at the routing layer.
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :agent

  # Phase 3d: Agent carries Identity Behavior alongside Chat. Default
  # initial_caps is empty (Agent has no authority to initiate; chat
  # receive only). Operators can grant caps via Identity invoke if
  # they want to elevate a specific Agent.
  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.Chat, Ezagent.Behavior.Identity]

  # Phase 4-completion Spec 04: `:on_terminate` so granted Identity
  # caps survive graceful shutdown. Abrupt crash still loses them
  # (bridge re-announce re-creates Agent fresh; acceptable). Bump to
  # `:on_change` in Phase 5 once Agent caps see real promotion volume.
  @impl Ezagent.Kind
  def persistence, do: :on_terminate

  # V1 prevention (Allen 2026-05-21): Agent Kinds (including Echo —
  # chat's `spawn_agent/1` flavor-resolver routes echo here too) live
  # under the chat domain's AgentSupervisor. `Ezagent.Kind.spawn/2`
  # reads this.
  @impl Ezagent.Kind
  def supervisor, do: EzagentDomainChat.AgentSupervisor

  @doc """
  Phase 7 PR 40 — Spawn a worker agent from an AgentTemplate.

  Composes existing primitives without introducing a new spawn
  contract: builds the instance Agent URI, calls
  `Ezagent.SpawnRegistry.spawn/1` (URI-only per Decision #65), then
  records lineage in `Ezagent.WorkspaceRegistry` for workspace scope +
  `Ezagent.AgentLineage` for `{:spawned_by, _}` cap resolution (PR 42
  / Decision #137).

  ## Args

  - `template_uri` — `template://agent/<template_name>` (must
    be an already-registered AgentTemplate Kind)
  - `instance_name` — string, becomes the instance Agent URI's
    name segment (`entity://agent/<instance_name>` — PR #141 SPEC v2;
    caller supplies the full flavor-prefixed name like `cc_<id>`).
    Caller's job to ensure uniqueness; collisions return
    `{:error, {:already_started, _}}` per SpawnRegistry semantics.
  - `workspace_uri` — `%URI{}` scope this Agent belongs to;
    bound via `Ezagent.WorkspaceRegistry.bind/2` so workspace-scoped
    routing rules apply (invariant 4 per esr-developer skill).
  - `granted_by` — `%URI{}` of the principal authorizing the spawn
    (orchestrator URI in the typical case). Recorded in
    `Ezagent.AgentLineage` to support `{:spawned_by, granted_by}`
    scoped delegation caps.

  ## Return

  `{:ok, agent_uri}` on success, `{:error, reason}` on spawn or
  lineage-record failure. Lineage failure (registry not started)
  is logged but not fatal — the agent spawns successfully and
  loses lineage tracking only.

  ## What this PR does NOT do

  - Does NOT instantiate the underlying claude process (PtyServer
    spawns that on bridge announce). AgentTemplate's
    `working_directory` / `claude_config_dir` / `settings_path`
    are consumed by the PR 32 v2 bridge / PtyServer integration —
    Agent.spawn/4 is the ESR-side Kind registration, not the
    PTY-side process spawn.
  - Does NOT populate AgentTemplate slice content from the
    template Kind (the template's slice is empty per PR 37 — admin
    populates it). Calling Agent.spawn/4 against an empty
    AgentTemplate produces an Agent with default settings (operator
    `~/.claude/`).
  """
  @spec spawn(
          template_uri :: URI.t(),
          instance_name :: String.t(),
          workspace_uri :: URI.t(),
          granted_by :: URI.t()
        ) :: {:ok, URI.t()} | {:error, term()}
  def spawn(%URI{} = _template_uri, instance_name, %URI{} = workspace_uri, %URI{} = granted_by)
      when is_binary(instance_name) do
    # Phase 9 PR-2 (SPEC v3 §3): agent URI carries its workspace name
    # as the first path segment under the type axis. Workspace URI
    # host carries the bare workspace name (workspace:// is 1-seg).
    workspace_name = workspace_uri.host || "default"
    agent_uri = URI.new!("entity://agent/#{workspace_name}/#{instance_name}")

    with {:ok, _pid} <- spawn_or_resume(agent_uri),
         :ok <- Ezagent.WorkspaceRegistry.bind(agent_uri, workspace_uri),
         :ok <- record_lineage(agent_uri, granted_by) do
      {:ok, agent_uri}
    else
      err -> err
    end
  end

  defp spawn_or_resume(agent_uri) do
    case Ezagent.SpawnRegistry.spawn(agent_uri) do
      {:ok, _pid} = ok -> ok
      {:error, {:already_started, pid}} -> {:ok, pid}
      err -> err
    end
  end

  @doc """
  Phase 7 completion PR-1 (SPEC §1.6a) — spawn a worker agent from an
  AgentTemplate's `:template` slice CONTENT, delegating the launch to
  the flavor's plugin Template Class and re-establishing the post-spawn
  obligations (lineage + workspace binding) the Class does not perform.

  This is the **content-taking** spawn helper. It takes the template
  content as an ARGUMENT — it does NOT dispatch `:read` (the
  `Ezagent.Behavior.Template` `:instantiate` action that calls it is
  ALREADY running inside the AgentTemplate Kind process with the slice
  in hand; a `:read` self-dispatch would be a `GenServer.call(self)`
  deadlock — codex rev-5 HIGH-2).

  ## Contract (SPEC §1.6a)

  1. **Look up the Class** — from `content.flavor`,
     `Ezagent.AgentFlavorRegistry.lookup/1` → `%{template_class: tc}`.
  2. **Build the Class data map** — `AgentTemplate.to_template_data/2`
     (§1.5 adapter) from the content + `instance_uri`.
  3. **Delegate the launch** — `tc.instantiate(tc.template_name(),
     data, workspace_uri)` → `{:ok, [worker_uri]}` (the plugin owns
     exactly this — the Agent Kind + PTY).
  4. **Record lineage (helper-owned)** — for each returned
     `worker_uri`, `Ezagent.AgentLineage.record(worker_uri,
     spawned_by_uri)`. The plugin Template Class does NOT do this, so
     cap #2 (`{:spawned_by, orchestrator}`) would never resolve without
     this step.
  5. **Bind workspace (helper-owned)** — for each `worker_uri`,
     `Ezagent.WorkspaceRegistry.bind(worker_uri, workspace_uri)`
     (invariant 4 — workspace-scoped routing rules must fire).

  NO `:read` dispatch anywhere.

  ## Args

  - `template_content_map` — the AgentTemplate `:template` slice content
    (carries `flavor`, `working_directory`, the sandbox keys).
  - `instance_uri` — the per-instance agent URI the caller built.
  - `spawned_by_uri` — `%URI{}` of the principal authorizing the spawn
    (the owner for the orchestrator agent; the orchestrator's own URI
    for `add_agent_slot` workers, so cap #2 resolves).
  - `workspace_uri` — `%URI{}` scope the worker belongs to.

  ## Return

  `{:ok, [worker_uri]}` on success, `{:error, reason}` otherwise.
  """
  @spec spawn_from_template_content(map(), URI.t(), URI.t(), URI.t()) ::
          {:ok, [URI.t()]} | {:error, term()}
  def spawn_from_template_content(
        template_content_map,
        %URI{} = instance_uri,
        %URI{} = spawned_by_uri,
        %URI{} = workspace_uri
      )
      when is_map(template_content_map) do
    with {:ok, template_class} <- resolve_template_class(template_content_map),
         {:ok, data} <-
           Ezagent.Entity.AgentTemplate.to_template_data(template_content_map, instance_uri),
         {:ok, workers} <-
           template_class.instantiate(template_class.template_name(), data, workspace_uri) do
      Enum.each(workers, fn worker_uri ->
        :ok = record_lineage(worker_uri, spawned_by_uri)
        :ok = bind_workspace(worker_uri, workspace_uri)
      end)

      {:ok, workers}
    end
  end

  def spawn_from_template_content(_content, _instance, _spawned_by, _workspace) do
    {:error, :invalid_spawn_from_template_content_args}
  end

  defp resolve_template_class(content) do
    flavor = Map.get(content, :flavor) || Map.get(content, "flavor")

    case flavor do
      f when is_binary(f) and f != "" ->
        case Ezagent.AgentFlavorRegistry.lookup(f) do
          {:ok, %{template_class: tc}} -> {:ok, tc}
          :error -> {:error, {:unknown_flavor, f}}
        end

      _ ->
        {:error, :missing_flavor}
    end
  end

  defp bind_workspace(worker_uri, workspace_uri) do
    case Ezagent.WorkspaceRegistry.bind(worker_uri, workspace_uri) do
      :ok -> :ok
      other -> other
    end
  end

  defp record_lineage(agent_uri, granted_by) do
    if Code.ensure_loaded?(Ezagent.AgentLineage) and function_exported?(Ezagent.AgentLineage, :record, 2) do
      Ezagent.AgentLineage.record(agent_uri, granted_by)
    else
      # AgentLineage registry not loaded — log + continue. PR 42's
      # {:spawned_by, _} cap shape returns false in this case, so
      # absence of lineage data degrades gracefully (no false grants).
      require Logger

      Logger.debug(
        "Ezagent.Entity.Agent.spawn: AgentLineage registry not loaded; " <>
          "{:spawned_by, _} cap shapes will deny for #{URI.to_string(agent_uri)}"
      )

      :ok
    end
  end
end
