defmodule EzagentDomainSocialware.Application do
  @moduledoc """
  OTP application for the Socialware domain.

  P1 owns the `session.socialware` Kind and registers the Turn action set
  against it. Later phases add Surface and customer-feed components here.
  """

  use Application

  alias Ezagent.CapabilityRegistry
  alias Ezagent.Behavior.{Chat, ConfigUpdate, SocialwarePublisherRead, Surface, Turn}
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

    # P3-3 (codex #711 HIGH) — the socialware publisher READ API. A DISTINCT,
    # registry-only behavior (NOT in `SocialwareSession.behaviors/0`) exposing
    # `:snapshot` + `:history` (no `:subscribe_from`) over the publisher trunk.
    #
    # The reads are CAP-EXEMPT (`cap_exempt_actions/0`) — the behavior's
    # handler is the SOLE fail-closed authority (a live socialware owner/member
    # check against the `:chat` sibling slice). Registering it ONLY for these
    # read actions on `SocialwareSession` (NOT `Publisher.SessionImpl`) is what
    # keeps a broad chat `kind: :session, behavior: Publisher.SessionImpl` grant
    # from ever dispatching a read on a `SocialwareSession` — the chat publisher
    # read actions are registered ONLY against the chat `Session` Kind, so there
    # is no `{kind, action}` collision and no trunk/read split is needed; the
    # trunk `Publisher.SessionImpl` stays the sole `:publisher` owner.
    Enum.each(SocialwarePublisherRead.actions(), fn action ->
      :ok = CapabilityRegistry.register(SocialwareSession, action, SocialwarePublisherRead)
    end)

    :ok
  end
end
