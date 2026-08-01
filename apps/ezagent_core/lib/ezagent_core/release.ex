defmodule EzagentCore.Release do
  @moduledoc """
  Release tasks for the prod OTP release (`mix release`). There is no Mix in a
  release, so migrations run via `bin/ezagent eval "EzagentCore.Release.migrate()"`
  from the release entrypoint. dev/test still use `mix ecto.migrate`.
  """
  @app :ezagent_core

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

  # Runtime-resolved (no compile-time dep from `ezagent_core` → the identity
  # domain, which would reverse the umbrella graph). Mirrors #1625's cutover
  # release entrypoint pattern.
  @admin_key_rotation Ezagent.Identity.AdminKeyRotation

  @doc """
  RELEASE-node entrypoint for the manual genesis-admin key rotation (#1627
  B1-hybrid) — dev/test use `mix ezagent.identity.rotate_admin`; a release has no
  Mix, so:

      bin/ezagent eval "EzagentCore.Release.rotate_admin()"

  Rotates the root authority + re-mints its self-license atomically (see
  `Ezagent.Identity.AdminKeyRotation`). Raises on failure so `bin/ezagent eval`
  exits non-zero (the release entrypoint has no Mix exit-status convention).
  """
  @spec rotate_admin() :: {:ok, pos_integer()}
  def rotate_admin do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)

    case apply(@admin_key_rotation, :run, [[]]) do
      {:ok, generation} ->
        {:ok, generation}

      {:error, reason} ->
        raise "#1627 admin key rotation FAILED — root generation NOT advanced: #{inspect(reason)}"
    end
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  # `Application.load/1` (not `ensure_all_started`) — we only need the app's
  # env (ecto_repos + repo config) to run the migrator; the supervision tree
  # is NOT started (the endpoint/agents must not boot during a migrate step).
  defp load_app, do: Application.load(@app)
end
