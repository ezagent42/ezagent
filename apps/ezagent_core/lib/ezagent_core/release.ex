defmodule EzagentCore.Release do
  @moduledoc """
  Release tasks for the prod OTP release (`mix release`). There is no Mix in a
  release, so migrations run via `bin/ezagent eval "EzagentCore.Release.migrate()"`
  from the release entrypoint. dev/test still use `mix ecto.migrate`.
  """
  @app :ezagent_core

  # #189 — the identity-plane cutover Runbook, as a bare module VALUE (an
  # alias literal, not a `Mod.fun()` qualified call). Dispatched via `apply/3`
  # below so `ezagent_core` — a layer BELOW every domain app, which must never
  # declare a compile dependency on one (that would invert the umbrella's IoC
  # backbone and risk a cycle) — creates no hard reference to
  # `ezagent_domain_identity`. This mirrors the identity→session dispatch
  # inside `Ezagent.Identity.Cutover.Runbook` itself; see that module's
  # moduledoc for the `undeclared_umbrella_dep_test` rationale. Do NOT
  # "simplify" this into a direct call.
  @cutover_runbook Ezagent.Identity.Cutover.Runbook

  @doc "Run all pending migrations for every configured repo (idempotent)."
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc "Roll a single repo back to `version`."
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  #189 — activate the identity-plane cutover epoch from a RELEASE node
  (canary/prod containers have no Mix; their entrypoint is `bin/ezagent
  eval`). Runs the IDENTICAL interlock as `mix ezagent.identity.cutover`
  (backfill → session self-license migration → fleet-parity barrier → decide
  → activate) via `Ezagent.Identity.Cutover.Runbook.run/1`, dispatched
  dynamically (see `@cutover_runbook`) so this module has no compile
  dependency on the identity domain.

  Unlike the mix task (which sets a process exit status), this RAISES on
  `{:refused, reason}` — the release `eval` entrypoint has no Mix exit-status
  convention to hook, so a raised exception is what makes `bin/ezagent eval
  "EzagentCore.Release.identity_cutover()"` fail loudly (nonzero exit) on
  divergence, instead of silently returning while the epoch stays inactive.

  Options: `:dry_run` (boolean, default `false`) — see
  `Ezagent.Identity.Cutover.Runbook.run/1`.

      bin/ezagent eval "EzagentCore.Release.identity_cutover()"
      bin/ezagent eval "EzagentCore.Release.identity_cutover(dry_run: true)"
  """
  def identity_cutover(opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)

    opts =
      opts
      |> Keyword.put_new(:io, &IO.puts/1)
      |> Keyword.put_new(:io_err, &IO.puts(:stderr, &1))

    case apply(@cutover_runbook, :run, [opts]) do
      :activated ->
        :activated

      :dry_run ->
        :dry_run

      {:refused, reason} ->
        raise "#189 identity cutover REFUSED — epoch NOT activated: #{inspect(reason)}"
    end
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  # `Application.load/1` (not `ensure_all_started`) — we only need the app's
  # env (ecto_repos + repo config) to run the migrator; the supervision tree
  # is NOT started (the endpoint/agents must not boot during a migrate step).
  defp load_app, do: Application.load(@app)
end
