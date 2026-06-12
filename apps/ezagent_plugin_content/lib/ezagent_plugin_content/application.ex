defmodule EzagentPluginContent.Application do
  @moduledoc "OTP Application for the content plugin — soul/skill/KB CRUD + Admin Behaviors."

  use Application
  use Ezagent.Plugin

  alias Ezagent.Behavior.Introspection
  alias Ezagent.Entity.{System, Workspace}
  alias EzagentPluginContent.Behavior.{ContentAdmin, TenantAdmin}

  @impl true
  def start(_type, _args) do
    Ezagent.Plugin.boot(__MODULE__)
  end

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "content",
      name: "Content",
      description: "Generic content management — soul, skill, KB CRUD + Admin Behaviors (ContentAdmin, TenantAdmin).",
      version: "0.2.0"
    }
  end

  @impl Ezagent.Plugin
  def behaviors do
    ws_actions = Introspection.action_names(ContentAdmin)
    sys_actions = Introspection.action_names(TenantAdmin)

    Enum.map(ws_actions, fn action -> {Workspace, action, ContentAdmin} end) ++
      Enum.map(sys_actions, fn action -> {System, action, TenantAdmin} end)
  end
end
