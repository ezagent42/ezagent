defmodule EzagentDomainSocialware.Application do
  @moduledoc """
  OTP application for the Socialware domain.

  P1 owns the `session.socialware` Kind and registers the Turn action set
  against it. Later phases add Surface and customer-feed components here.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # P5-1b (socialware substrate collapse) — `register_behaviors/0` is GONE.
    # The Session+Turn+Surface (and `SocialwarePublisherRead`) action sets are
    # no longer registered on `Entity.SocialwareSession`: that Kind no longer
    # spawns (the advisor template now spawns the UNIFIED `Entity.Session` with
    # the socialware `:kind_base` subset; see `AdvisorSession.ensure_session/1`).
    # All those registrations now live on `Entity.Session` in
    # `EzagentDomainInstanceMessage.Application.register_session_behaviors/0`.
    # `Entity.SocialwareSession` stays present-but-unreferenced-by-spawns until
    # its module deletion in P5-3.

    children = [
      {DynamicSupervisor,
       name: EzagentDomainSocialware.SocialwareSessionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
