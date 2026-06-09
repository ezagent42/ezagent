defmodule EzagentPluginAdvisor.Application do
  @moduledoc """
  Advisor vertical plugin.

  The plugin contributes the first socialware vertical template:
  `session.advisor`. It owns only Tier-3 declarations and materialization
  metadata; the runtime session remains the domain-owned
  `Ezagent.Entity.SocialwareSession`.
  """

  use Application
  use Ezagent.Plugin

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "advisor",
      name: "Advisor",
      description: "Socialware advisor vertical session template.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def template_classes, do: [EzagentPluginAdvisor.Template.AdvisorSession]

  @impl Ezagent.Plugin
  def config_surface, do: nil
end
