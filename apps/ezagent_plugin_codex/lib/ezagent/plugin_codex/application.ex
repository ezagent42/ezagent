defmodule EzagentPluginCodex.Application do
  @moduledoc """
  Codex agent plugin.

  A codex agent is the shared `Ezagent.Entity.Agent` Kind with flavor
  `"codex"`. The plugin starts a Codex app-server sidecar, a user-visible
  Codex TUI through Domain.Pty, and a Python bridge sidecar that connects
  AgentBridge delivery to the same app-server thread.
  """

  use Application
  use Ezagent.Plugin

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "codex",
      name: "Codex",
      description: "Spawn Codex agents with a shared app-server, PTY TUI, and AgentBridge.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def template_classes,
    do: [
      Ezagent.PluginCodex.Template.CodexAgent,
      Ezagent.PluginCodex.Template.CodexRemoteAgent
    ]

  @impl Ezagent.Plugin
  def agent_flavors do
    [
      %{
        flavor: "codex",
        kind: Ezagent.Entity.Agent,
        template_class: Ezagent.PluginCodex.Template.CodexAgent,
        bridge_adapter: EzagentPluginCodex.BridgeAdapter
      },
      %{
        flavor: "codex-remote",
        kind: Ezagent.Entity.Agent,
        template_class: Ezagent.PluginCodex.Template.CodexRemoteAgent,
        bridge_adapter: EzagentPluginCodex.CodexRemoteBridgeAdapter
      }
    ]
  end

  @impl Ezagent.Plugin
  def roles, do: [Ezagent.Orchestrator.OrchestratorRecipe.recipe()]

  @impl Ezagent.Plugin
  def resource_types do
    Ezagent.Resource.FsResolver.config_dir_resource_types([
      Ezagent.PluginCodex.Template.CodexAgent,
      Ezagent.PluginCodex.Template.CodexRemoteAgent
    ])
  end

  @impl Ezagent.Plugin
  def config_surface do
    %{kind: :flavor, flavor: "codex", label: "Codex Agents"}
  end

  @impl Ezagent.Plugin
  def children do
    # V5 pid-closure A1b: the private `AppServerRegistry` is RETIRED — the
    # AppServer sidecar self-registers in the unified
    # `Ezagent.Runtime.SidecarRegistry` (started by `EzagentActor.Application`)
    # and is reached only through the `Ezagent.Runtime.Resolver` seam. The
    # supervisors stay: spawn remains the plugin's own
    # `DynamicSupervisor.start_child`. (`BridgeSidecarRegistry` retires with
    # the BridgeSidecar migration, next commit.)
    [
      {DynamicSupervisor, name: EzagentPluginCodex.AppServerSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: EzagentPluginCodex.BridgeSidecarRegistry},
      {DynamicSupervisor,
       name: EzagentPluginCodex.BridgeSidecarSupervisor, strategy: :one_for_one}
    ]
  end

  # Codex sidecar orphan reaping (erlexec sidecar runtime, 2026-06-25).
  # In :test env we SKIP the reap by default: codex sidecars don't spawn in
  # :test (test_mode short-circuit), so no pid-files accumulate; more
  # importantly, reaping in :test would indiscriminately kill any codex/uv
  # OS processes from prior e2e runs that the next test wants to inspect.
  # Flippable via `config :ezagent_plugin_codex, :reap_orphans_on_boot, true`.
  #
  # `Mix.env()` resolved at compile time (baked in; same pattern as
  # EzagentPluginCc.Application).
  @compile_env Mix.env()
  @default_reap_enabled? @compile_env != :test

  @impl Ezagent.Plugin
  def after_boot do
    _ = maybe_reap_codex_orphans()
    _ = Ezagent.Workspace.Loader.load_all()
    :ok = Ezagent.Orchestrator.CodexOrchestratorSeed.seed()
    :ok
  end

  defp maybe_reap_codex_orphans do
    enabled? =
      Application.get_env(:ezagent_plugin_codex, :reap_orphans_on_boot, @default_reap_enabled?)

    if enabled? do
      _ = Ezagent.Runtime.OrphanReaper.reap("codex-appserver")
      _ = Ezagent.Runtime.OrphanReaper.reap("codex-bridge")
      :ok
    else
      :ok
    end
  end
end
