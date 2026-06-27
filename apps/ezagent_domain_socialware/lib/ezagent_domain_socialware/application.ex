defmodule EzagentDomainSocialware.Application do
  @moduledoc """
  OTP application for the Socialware domain.

  The socialware domain contributes the customer-feed / settlement substrate
  and PageView projection. After the P5 substrate collapse it no longer owns a
  session Kind: socialware/advisor sessions are instances of the UNIFIED
  `Ezagent.Entity.Session` (carrying the `Session.socialware_behaviors/0`
  `:kind_base` subset), whose action sets are registered in
  `EzagentDomainInstanceMessage.Application`.
  """

  use Application

  alias Ezagent.ExternalMirror.AdapterRegistry
  alias Ezagent.Socialware.{ChatFeedAdapter, ExternalFeedAdapter}

  @impl true
  def start(_type, _args) do
    # P5-1b/P5-3 (socialware substrate collapse) — `register_behaviors/0` is
    # GONE and the standalone socialware-session Kind has been DELETED. The
    # Session+Turn+Surface (and `SocialwarePublisherRead`) action sets are
    # registered on the UNIFIED `Entity.Session` in
    # `EzagentDomainInstanceMessage.Application.register_session_behaviors/0`,
    # and socialware sessions spawn that unified Kind with the socialware
    # `:kind_base` subset (`Session.socialware_behaviors/0`). They run under
    # instance_message's `SessionSupervisor`, so this domain no longer boots a
    # session supervisor of its own. (The advisor demo vertical that once drove
    # this via `AdvisorSession.ensure_session/1` was retired in
    # `chore/retire-session-advisor`; the unified `Entity.Session` substrate it
    # exercised is unchanged.)
    #
    # #51 §3.4 — the in-app GC sweeper for abandoned anonymous external users.
    # `init` only arms a timer (no boot-time DB work), so it is safe to supervise
    # in every env; the default interval is hourly, so the first tick is well past
    # any test's lifetime.
    children = [
      Ezagent.Socialware.AnonUser.Sweeper
    ]

    case Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__) do
      {:ok, sup_pid} ->
        :ok = register_adapters()
        {:ok, sup_pid}

      other ->
        other
    end
  end

  defp register_adapters do
    for adapter <- [ChatFeedAdapter, ExternalFeedAdapter] do
      case AdapterRegistry.register(adapter) do
        :ok -> :ok
        {:ok, :already_present} -> :ok
      end
    end

    :ok
  end
end
