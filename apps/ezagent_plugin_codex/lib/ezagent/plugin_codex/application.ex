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
  def config_surface do
    %{kind: :flavor, flavor: "codex", label: "Codex Agents"}
  end

  @impl Ezagent.Plugin
  def children do
    [
      {Registry, keys: :unique, name: EzagentPluginCodex.AppServerRegistry},
      {DynamicSupervisor, name: EzagentPluginCodex.AppServerSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: EzagentPluginCodex.BridgeSidecarRegistry},
      {DynamicSupervisor,
       name: EzagentPluginCodex.BridgeSidecarSupervisor, strategy: :one_for_one}
    ]
  end

  @impl Ezagent.Plugin
  def after_boot do
    _ = Ezagent.Workspace.Loader.load_all()
    :ok
  end
end
