defmodule Ezagent.Migration.RepoOnly do
  @moduledoc """
  Shared "start ONLY the Repo, run a one-shot snapshot migration, stop it"
  helper for the snapshot-migration Mix tasks (#52 lesson).

  ## Why this exists

  A snapshot migration MUST NOT `app.start` the domain runtime before it runs:
  a half-booted node's workspace loader / session delivery could try to
  cold-load the very rows the migration is repairing — under a renamed slice
  key, a deleted Kind type, or a rewritten cap axis — and silently prune or
  crash on the un-migrated durable state. `Ecto.Migrator.with_repo/2` starts
  ONLY the repo (and its Ecto adapter deps), runs the work, then stops it.

  Both `mix ezagent.session.migrate_slice` and `mix ezagent.curl.migrate` need
  the identical Repo-only boot. Extracted here (PR-6+7 curl-as-flavor) so the
  pattern lives in one place instead of being copy-pasted per task — a single
  sanctioned chokepoint for the ordered-cutover discipline.

  > **TEST / sandbox DB only** for the migrations driven through this. As a
  > production cutover step they run under the ordered-cutover discipline
  > (stop nodes → deploy → migrate → gate → start).
  """

  @doc """
  Load the app config (DB url / pool) WITHOUT starting any application, then
  run `fun` inside `Ecto.Migrator.with_repo/2` for `EzagentCore.Repo` — repo
  (+ Ecto adapter deps) only, no domain runtime. Returns `:ok`.
  """
  @spec run((-> any())) :: :ok
  def run(fun) when is_function(fun, 0) do
    Mix.Task.run("app.config")
    {:ok, _result, _started} = Ecto.Migrator.with_repo(EzagentCore.Repo, fn _repo -> fun.() end)
    :ok
  end
end
