defmodule EzagentWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    :ok = EzagentWeb.RateLimiter.init_table()

    # Every dependency app (including plugins) has already started before OTP
    # enters this callback. Freeze the deterministic Session-Config extension
    # set before Endpoint can accept a request, so no caller can observe a
    # transient core-only catalog during boot.
    :ok =
      Ezagent.Session.Config.ExtensionRegistry.assemble!(
        Ezagent.Session.Config.ExtensionRegistry.discover_loaded_extensions()
      )

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
        # Skill distribution P2: recover/copy release-bundled skill seeds into
        # EZAGENT_HOME and scan the single runtime origin before consumers read.
        :ok = Ezagent.Home.SkillSeed.boot!(index?: System.get_env("MIX_ENV") != "test")

        # R2 boot lane: reconcile per-agent skill homes after seed + registry
        # refresh. Fail-soft — telemetry + continue boot on any error.
        _ = Ezagent.Home.SkillReconcile.reconcile_all(fail_soft: true)

        # sw-home lane (2026-07-07) — the ONE late socialware manifest scan.
        # P13 note: ezagent_web is transport, not business logic; this call is
        # ONLY a trigger. It lives here because ezagent_web depends on every
        # plugin app, so by OTP start ordering it is the last app in the
        # umbrella dep closure to boot — at this point every plugin's
        # views/recipes are registered, so manifests that reference them
        # resolve. The scanning logic itself is owned by the session domain
        # (`Ezagent.Socialware.ManifestSeed`).
        #
        # PER-PACKAGE isolation (2026-07-30, #206/#1633 follow-up ③): use the
        # non-raising `scan_all/1`, NOT `scan_all!/1`. #206 was exactly this
        # call site raising on the FIRST bad socialware package and aborting
        # the whole node — a stale kanban manifest killed autoservice + hello
        # + the node too. `scan_all/1` isolates each package: a failure is
        # still fail-LOUD (`Logger.error/1` with the package name + reason,
        # plus a boot summary line), but it no longer aborts boot, and every
        # other package still seeds. No-op when disabled (`enabled?/0` —
        # test default off).
        _ = Ezagent.Socialware.ManifestSeed.scan_all()
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
