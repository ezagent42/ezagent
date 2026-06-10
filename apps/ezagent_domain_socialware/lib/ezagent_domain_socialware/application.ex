defmodule EzagentDomainSocialware.Application do
  @moduledoc """
  OTP application for the Socialware domain.

  P1 owns the `session.socialware` Kind and registers the Turn action set
  against it. Later phases add Surface and customer-feed components here.
  """

  use Application

  alias Ezagent.CapabilityRegistry
  alias Ezagent.Behavior.{Chat, ConfigUpdate, Surface, Turn}
  alias Ezagent.Entity.SocialwareSession
  alias Ezagent.Socialware.ConfigProjection

  @impl true
  def start(_type, _args) do
    :ok = register_behaviors()
    :ok = ConfigProjection.register()

    children = [
      {DynamicSupervisor,
       name: EzagentDomainSocialware.SocialwareSessionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  @doc false
  @spec register_behaviors() :: :ok
  def register_behaviors do
    Enum.each([:send, :join, :leave, :set_working_copy, :set_legends, :set_prompt_templates], fn
      action ->
        :ok = CapabilityRegistry.register(SocialwareSession, action, Chat)
    end)

    Enum.each(Turn.actions(), fn action ->
      :ok = CapabilityRegistry.register(SocialwareSession, action, Turn)
    end)

    Enum.each(Surface.actions(), fn action ->
      :ok = CapabilityRegistry.register(SocialwareSession, action, Surface)
    end)

    Enum.each(ConfigUpdate.actions(), fn action ->
      :ok = CapabilityRegistry.register(SocialwareSession, action, ConfigUpdate)
    end)

    :ok
  end
end
