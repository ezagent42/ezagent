defmodule EzagentPluginWorld.Application do
  @moduledoc """
  Next-generation ezagent web app plugin.

  The plugin owns the `world` LiveView shell and React/Vite source. It declares no
  Kinds, Behaviors, spawns, template classes, agent flavors, or routing tables in
  PR-0; later PRs add dispatch-backed surfaces.
  """

  use Application
  use Ezagent.Plugin

  @impl Application
  def start(_type, _args) do
    with {:ok, pid} <- Ezagent.Plugin.boot(__MODULE__) do
      register_session_views()
      {:ok, pid}
    end
  end

  # world consumes the SessionView registry (owned by ezagent_domain_ui, a
  # declared dep). Registering ConversationView here makes chat a first-class
  # registry view, enumerated alongside pty / hello-page / … via
  # `Ezagent.UI.SessionViewRegistry.applicable_views/2` — no hard-coded chat tab.
  defp register_session_views do
    :ok = Ezagent.UI.SessionViewRegistry.init()
    :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.World.ConversationView)
    :ok
  end

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "world",
      name: "World",
      description: "The React/shadcn ezagent app over a LiveView comms shell.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def behaviors do
    [
    ]
  end

  @doc """
  World-owned renderers use the same refresh declaration seam as plugin pages.
  The shell only consumes this data; it does not know which conversation
  template, socialware, or sender produced the session change.
  """
  @spec refresh_surfaces() :: [Ezagent.World.UiSurfaceProvider.refresh_surface()]
  def refresh_surfaces do
    [
      %{
        id: "conversation",
        component: "conversation",
        target: {:assign, :current_session_uri},
        state_builder: Ezagent.World.ConversationSessionState
      }
    ]
  end

  @impl Ezagent.Plugin
  def resource_types, do: []

  @impl Ezagent.Plugin
  def after_boot, do: :ok
end
