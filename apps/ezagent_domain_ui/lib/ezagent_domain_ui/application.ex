defmodule EzagentDomainUi.Application do
  @moduledoc """
  Domain.UI Application — promotes `ezagent_domain_ui` from a library
  to an OTP application so it can register its own UI extensions at
  boot.

  Added in Domain.Pty PR-C (2026-05-21) when `EzagentPluginCc.Views.PtyView`
  moved here as `EzagentDomainUi.Pty.TerminalView`. The cc plugin used
  to own this SessionView registration; with the terminal view now
  cross-flavor (any session member backed by `Ezagent.Domain.Pty`), the
  registration belongs at the Domain tier, not in any single plugin.

  ## Children

  None. This Application boots no GenServers — `ezagent_domain_ui` is
  still a library at heart (stateless `Phoenix.Component` primitives).
  The `start/2` callback exists purely to register UI extensions
  (currently the `Ezagent.UI.SessionViewRegistry` entry for
  `EzagentDomainUi.Pty.TerminalView`).

  Per Tier-2 rules: deps are `:ezagent_core` and other Domain-tier
  apps. `:ezagent_domain_pty` was added in PR-C because
  `EzagentDomainUi.Pty.TerminalView.applies_to?/1` calls
  `Ezagent.Domain.Pty.alive?/1` for cross-flavor detection.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = []

    case Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__) do
      {:ok, sup_pid} ->
        :ok = register_session_views()
        {:ok, sup_pid}

      other ->
        other
    end
  end

  # Per Domain.Pty SPEC v1 §3.2 + §5.1: the terminal view applies to
  # any session whose members include a live `Ezagent.Domain.Pty`
  # server — cross-flavor (cc / echo-with-pty / curl-with-pty / ...).
  defp register_session_views do
    :ok = Ezagent.UI.SessionViewRegistry.init()
    :ok = Ezagent.UI.SessionViewRegistry.register(EzagentDomainUi.Pty.TerminalView)
    :ok
  end
end
