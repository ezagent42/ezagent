defmodule EzagentPluginContent.Application do
  @moduledoc "OTP Application for the content plugin — soul/skill/KB CRUD."
  use Application
  use Ezagent.Plugin

  @impl true
  def start(_type, _args) do
    children = []
    opts = [strategy: :one_for_one, name: EzagentPluginContent.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "content",
      name: "Content",
      description: "Generic content management — soul, skill, KB CRUD, tenant-agnostic.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def behaviors, do: []
end
