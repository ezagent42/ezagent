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

  # P3-2: the socialware customer feed declared as a BARE `:pull`
  # `Ezagent.ExternalMirror.Adapter` (no binding — served by the customer
  # channel). Registering it installs the `allow_customer_feed` cap subject and
  # spawns NO Worker (pull adapters have no per-binding transport).
  #
  # P4: the chat feed — a SECOND bare `:pull` adapter that projects a chat
  # session into the SAME SPA + channel + json-render shape, sourced from the
  # chat `inserted_at` cursor and gated by chat membership. Installs the
  # `allow_chat_feed` cap subject; likewise spawns NO Worker.
  @impl Ezagent.Plugin
  def adapters,
    do: [Ezagent.Socialware.CustomerFeedAdapter, Ezagent.Socialware.ChatFeedAdapter]
end
