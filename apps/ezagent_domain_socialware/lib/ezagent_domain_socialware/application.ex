defmodule EzagentDomainSocialware.Application do
  @moduledoc """
  OTP application for the Socialware domain.

  P1 owns the `session.socialware` Kind and registers the Turn action set
  against it. Later phases add Surface and customer-feed components here.
  """

  use Application

  alias Ezagent.CapabilityRegistry
  alias Ezagent.Behavior.{Chat, SocialwarePublisherRead, Surface, Turn}
  alias Ezagent.Entity.{Session, SocialwareSession}

  @impl true
  def start(_type, _args) do
    :ok = register_behaviors()

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

    # P5-A (codex H3; Allen option B) — UNIFY the two publisher READs into
    # ONE membership-gated read. Register `SocialwarePublisherRead`
    # (`:snapshot` / `:history`, cap-EXEMPT + a live `ChatMembership`
    # owner/member check) for the chat `Session` Kind TOO — not just
    # `SocialwareSession`. After this, EVERY session read (chat AND
    # socialware) is authorized by MEMBERSHIP ("谁在 session 里谁能读"),
    # NOT by a held `Publisher.SessionImpl :snapshot`/`:history` cap.
    #
    # WHY HERE (not in instance_message): the dep direction. This module
    # (`ezagent_domain_socialware`) DEPENDS ON `instance_message`, so it
    # CAN name `Ezagent.Entity.Session`; `instance_message` does NOT depend
    # on socialware, so it CANNOT name `SocialwarePublisherRead`. The chat
    # Session's read-action registration is therefore REMOVED from
    # `instance_message/application.ex` (it kept only `:subscribe_from`) and
    # ADDED here. This avoids the `{Kind, action}` collision that
    # `CapabilityRegistry.register/3` would raise if both behaviors claimed
    # `{Session, :snapshot|:history}`.
    #
    # `SocialwarePublisherRead` is registry-only (NOT in
    # `Session.behaviors/0`), so it never materializes the `:publisher`
    # slice — `Publisher.SessionImpl` stays the sole owner of `:publisher`
    # on the chat Session AND keeps `:subscribe_from`. The read handler
    # reads the trunk via `ctx.read` + authorizes via the `:chat` sibling
    # slice (`reads_siblings [:chat]`), which the chat Session has from the
    # `Chat` behavior — same shape `ChatMembership.authorize/2` expects.
    Enum.each(SocialwarePublisherRead.actions(), fn action ->
      :ok = CapabilityRegistry.register(Session, action, SocialwarePublisherRead)
    end)

    :ok
  end
end
