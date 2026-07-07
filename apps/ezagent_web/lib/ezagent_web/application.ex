defmodule EzagentWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = EzagentWeb.RateLimiter.init_table()

    children = [
      EzagentWeb.Telemetry,
      # Start a worker by calling: EzagentWeb.Worker.start_link(arg)
      # {EzagentWeb.Worker, arg},
      # Start to serve requests, typically the last entry
      EzagentWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: EzagentWeb.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, sup_pid} ->
        # sw-home lane (2026-07-07) — the ONE late socialware manifest scan.
        # P13 note: ezagent_web is transport, not business logic; this call is
        # ONLY a trigger. It lives here because ezagent_web depends on every
        # plugin app, so by OTP start ordering it is the last app in the
        # umbrella dep closure to boot — at this point every plugin's
        # views/recipes are registered, so manifests that reference them
        # resolve. The scanning logic itself is owned by the session domain
        # (`Ezagent.Socialware.ManifestSeed`). Fail-loud: a broken manifest
        # or unsatisfied `uses` aborts the boot. No-op when disabled
        # (`enabled?/0` — test default off).
        :ok = Ezagent.Socialware.ManifestSeed.scan_all!()
        {:ok, sup_pid}

      other ->
        other
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EzagentWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
