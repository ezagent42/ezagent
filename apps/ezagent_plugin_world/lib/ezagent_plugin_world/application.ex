defmodule EzagentPluginWorld.Application do
  @moduledoc """
  Next-generation ezagent web app plugin.

  The plugin owns the `world` LiveView shell and React/Vite source. It declares no
  Kinds, Behaviors, spawns, template classes, agent flavors, or routing tables in
  PR-0; later PRs add dispatch-backed surfaces and layout management.
  """

  use Application
  use Ezagent.Plugin

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "world",
      name: "World",
      description: "The React/shadcn ezagent app over a LiveView comms shell.",
      version: "0.1.0"
    }
  end
end
