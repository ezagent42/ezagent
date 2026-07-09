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

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  # `Application.load/1` (not `ensure_all_started`) — we only need the app's
  # env (ecto_repos + repo config) to run the migrator; the supervision tree
  # is NOT started (the endpoint/agents must not boot during a migrate step).
  defp load_app, do: Application.load(@app)
end
