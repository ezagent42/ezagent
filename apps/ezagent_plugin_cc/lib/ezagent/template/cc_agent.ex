defmodule Ezagent.PluginCc.Template.CcAgent do
  @moduledoc """
  Unified CC agent Template Class (PR-D2, Allen 2026-05-19; mode field
  removed PR-V1-fix Allen 2026-05-21).

  Replaces the previous split between `cc.pty` and `cc.channel_instance`
  Template Classes. The operator now adds ONE template (`cc.agent`)
  per CC agent and the spawn path is always local-pty.

  The earlier PR-D2 plan reserved a `mode` field with values
  `"local-pty"` / `"remote-channel"` so a future external-bridge mode
  could share the same Template Class. Allen 2026-05-21 cut this:
  remote-channel was never wired and the placeholder + dichotomy were
  dead weight. If/when remote support returns, it will land as a
  separate plugin + Template Class, not a mode field. The `"mode"`
  field is no longer part of the schema; if a legacy row still carries
  it the template is accepted and the field ignored (no migration
  required — see PR-D2 migration that originally seeded the field).

  ## Architecture: instantiate PRODUCES the Kind (Allen 2026-05-21)

  Allen's mental model is "Template.instantiate produces a new Kind".
  Pre-V1-fix the AgentNewLive flow inverted this: it called
  `SpawnRegistry.spawn(agent_uri)` directly (which spawned the Agent
  Kind) BEFORE `Workspace.add_template/3` (which chains to
  instantiate). cc.agent.instantiate then short-circuited on the
  already-alive Kind and started PtyServer only — making it look like
  templates couldn't bring an Agent Kind up standalone.

  The V1 fix removed the pre-spawn from AgentNewLive AND made this
  template do the full job: when instantiate runs it BOTH ensures the
  Agent Kind exists (via `SpawnRegistry.spawn/1`) AND starts the
  PtyServer. After `add_template → invoke_template → instantiate`
  returns, the caller has a fully-operational cc agent.

  ## Template data

      %{
        "class" => "cc.agent",
        "agent_uri" => "entity://agent/<workspace>/cc_<name>",
        "cwd" => "/path"
      }

  ## Idempotency (PR-D2 + V1 fix)

  `instantiate/3` first looks up `agent_uri` in `KindRegistry`.
  If alive, returns the existing URI — no respawn, no PTY waste.
  Otherwise spawns the Agent Kind via `SpawnRegistry.spawn/1` then
  starts the PtyServer via `Ezagent.Domain.Pty.start/2` (facade over
  the `ezagent_domain_pty` Tier-2 app). Both layers are atomically
  dedup'd: Agent Kind via `KindRegistry` (entity:// spawn fn returns
  `{:error, {:already_started, _}}` for duplicates), PtyServer via the
  Domain.Pty :via Registry (`EzagentDomainPty.Registry`).

  ## Domain.Pty PR-A (2026-05-21 SPEC v1)

  The cc-specific claude invocation (mcp.json generation, settings
  override path, `--dangerously-load-development-channels`,
  `--permission-mode bypassPermissions`) used to live inside
  `Ezagent.PluginCc.PtyServer.spawn_claude_directly/1` (historical).
  It now lives here (`build_claude_cmd/1`) because Domain.Pty.Server
  is Tier-2 and cannot reference cc-plugin modules like
  `EzagentPluginCc.McpConfigWriter`.
  The cmd string is supplied as `cmd_override` on the Server init
  args; Server just runs whatever string the caller hands it under
  erlexec's PTY.
  """

  @behaviour Ezagent.Kind.Template
  @behaviour Ezagent.UI.Form

  require Logger

  @impl Ezagent.Kind.Template
  def template_name, do: "cc.agent"

  @impl Ezagent.Kind.Template
  def validate(tmpl) when is_map(tmpl) do
    with :ok <- check_class(tmpl),
         :ok <- check_agent_uri(tmpl),
         :ok <- check_cwd(tmpl) do
      :ok
    end
  end

  def validate(_), do: {:error, :not_a_map}

  defp check_class(%{"class" => "cc.agent"}), do: :ok
  defp check_class(%{"class" => other}), do: {:error, {:wrong_class, other}}
  defp check_class(_), do: {:error, :missing_class_field}

  defp check_agent_uri(%{"agent_uri" => uri_str}) when is_binary(uri_str) and uri_str != "" do
    case URI.new(uri_str) do
      {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> rest}} when rest != "" ->
        # Phase 9 PR-2 (SPEC v3 §3): entity URIs are 3-segment:
        # /<workspace>/<entity_name>. Flavor lives in the entity_name
        # prefix as `<flavor>_<rest>` (SPEC v2 §5.14). cc.agent
        # template requires flavor=cc.
        with [_workspace, entity_name] when entity_name != "" <-
               String.split(rest, "/", parts: 2),
             [flavor, suffix] when flavor != "" and suffix != "" <-
               String.split(entity_name, "_", parts: 2) do
          if flavor == "cc" do
            :ok
          else
            {:error, {:wrong_agent_flavor, flavor, expected: "cc"}}
          end
        else
          _ ->
            {:error,
             {:missing_flavor_prefix, uri_str,
              "agent URIs must be `entity://agent/<workspace>/cc_<name>` (Phase 9 PR-2)"}}
        end

      {:ok, %URI{scheme: "entity"}} ->
        {:error,
         {:invalid_agent_uri, uri_str,
          "agent URIs must be `entity://agent/<workspace>/cc_<name>` (Phase 9 PR-2)"}}

      _ ->
        {:error, {:bad_agent_uri, uri_str}}
    end
  end

  defp check_agent_uri(_), do: {:error, :missing_agent_uri}

  defp check_cwd(%{"cwd" => cwd}) when is_binary(cwd) and cwd != "", do: :ok
  defp check_cwd(_), do: {:error, :missing_cwd}

  @impl Ezagent.Kind.Template
  def instantiate(_tmpl_name, %{"agent_uri" => uri_str} = tmpl, _workspace_uri) do
    agent_uri = URI.parse(uri_str)

    # PR-D2 idempotency short-circuit: if BOTH the Agent Kind and the
    # PtyServer are already alive we have nothing to do. Each plugin
    # re-running Workspace.Loader.load_all/0 hits this on subsequent
    # passes; the first pass spawns, the rest no-op.
    cond do
      agent_kind_alive?(agent_uri) and pty_server_alive?(agent_uri) ->
        {:ok, [agent_uri]}

      true ->
        spawn_for_local_pty(agent_uri, tmpl)
    end
  end

  def instantiate(_tmpl_name, tmpl, _workspace_uri), do: {:error, {:invalid_template, tmpl}}

  # V1 fix Allen 2026-05-21: template instantiate PRODUCES the Kind.
  # Before this fix, instantiate started only PtyServer and assumed
  # someone else (AgentNewLive's direct SpawnRegistry.spawn call) had
  # already created the Agent Kind. The new flow:
  #
  # 1. Ensure the Agent Kind exists (via SpawnRegistry — routed by
  #    chat plugin's "entity" spawn fn to AgentSupervisor).
  # 2. Start the PtyServer for this agent_uri.
  #
  # Both steps are idempotent: SpawnRegistry returns
  # `{:error, {:already_started, _}}` for an existing Agent Kind, and
  # the PtyServer's :via Registry collapses concurrent starts.
  defp spawn_for_local_pty(agent_uri, tmpl) do
    cwd = Map.fetch!(tmpl, "cwd")

    with :ok <- ensure_agent_kind(agent_uri),
         :ok <- ensure_pty_server(agent_uri, cwd) do
      {:ok, [agent_uri]}
    end
  end

  defp ensure_agent_kind(agent_uri) do
    case Ezagent.SpawnRegistry.spawn(agent_uri) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        # Atomic dedup at KindRegistry level — Kind was spawned by a
        # concurrent caller (or by an earlier instantiate that crashed
        # between Kind spawn and PtyServer start). Treat as success.
        :ok

      {:error, reason} ->
        Logger.warning(
          "cc.agent: SpawnRegistry.spawn failed for #{URI.to_string(agent_uri)}: " <>
            inspect(reason)
        )

        {:error, {:agent_kind_spawn_failed, reason}}
    end
  end

  defp ensure_pty_server(agent_uri, cwd) do
    # Domain.Pty PR-A: route through the facade instead of
    # DynamicSupervisor.start_child on EzagentPluginCc.PtyServerSupervisor.
    # The cmd string (claude + flags + mcp config path) is built here
    # in the cc plugin and handed to Server as :cmd_override, keeping
    # ezagent_domain_pty Tier-2.
    #
    # In `:test` env we deliberately SKIP the McpConfigWriter side
    # effect — the Server short-circuits `:exec.run/2` via `test_mode:
    # true` (Mix.env() default), so the cmd string is never spawned;
    # building it would write `~/.ezagent/bridge.mcp.json` to disk on
    # every test, which the pre-Domain.Pty-PR-A path also avoided.
    params =
      case Mix.env() do
        :test -> %{cwd: cwd, test_mode: true}
        _ -> %{cwd: cwd, cmd_override: build_claude_cmd(agent_uri)}
      end

    case Ezagent.Domain.Pty.start(agent_uri, params) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        # Atomic dedup at supervisor layer (PtyServer's :via Registry
        # name made this happen). Treat as success.
        :ok

      {:error, reason} ->
        Logger.warning(
          "cc.agent: PtyServer start failed for #{URI.to_string(agent_uri)}: " <>
            inspect(reason)
        )

        {:error, {:pty_server_spawn_failed, reason}}
    end
  end

  # Phase 6 PR 23 + Domain.Pty PR-A (2026-05-21): build the full
  # claude invocation cc agents run under PTY. Moved here from
  # `Ezagent.PluginCc.PtyServer.spawn_claude_directly/1` so the Server
  # module (now `Ezagent.Domain.Pty.Server`) stays Tier-2 — no
  # dependency on cc-plugin modules like `McpConfigWriter`.
  defp build_claude_cmd(agent_uri) do
    {:ok, mcp_path} =
      EzagentPluginCc.McpConfigWriter.write!(
        agent_uri: URI.to_string(agent_uri)
      )

    # Phase 6 PR 23: operator's ~/.claude/settings.json may have
    # `remoteControlAtStartup: true` (cc-openclaw + others enable
    # it). That redirects interactive I/O to claude.ai cloud session
    # — local PTY becomes a passive observer. Override to false via
    # --settings on a plugin-shipped JSON.
    settings_path =
      :code.priv_dir(:ezagent_plugin_cc)
      |> Path.join("claude-pty-settings.json")

    "claude --permission-mode bypassPermissions " <>
      "--dangerously-load-development-channels server:esr-bridge " <>
      "--settings #{settings_path} " <>
      "--mcp-config #{mcp_path}"
  end

  defp agent_kind_alive?(agent_uri) do
    case Ezagent.KindRegistry.lookup(agent_uri) do
      {:ok, _pid} -> true
      :error -> false
    end
  end

  defp pty_server_alive?(agent_uri), do: Ezagent.Domain.Pty.alive?(agent_uri)

  # --- Ezagent.UI.Form ---------------------------------------------------------

  @impl Ezagent.UI.Form
  def form_fields do
    [
      %{
        name: "agent_uri",
        type: :uri,
        label: "Agent URI (entity://agent/<workspace>/cc_<name>)",
        required: true,
        placeholder: "entity://agent/default/cc_architect"
      },
      %{
        name: "cwd",
        type: :path,
        label: "Working directory",
        required: true,
        placeholder: "/Users/me/Workspace/proj"
      }
    ]
  end
end
