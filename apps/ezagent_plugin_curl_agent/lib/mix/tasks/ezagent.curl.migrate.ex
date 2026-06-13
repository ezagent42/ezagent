defmodule Mix.Tasks.Ezagent.Curl.Migrate do
  @shortdoc "curl-as-flavor: migrate curl_agent snapshots onto the unified Agent Kind"

  @moduledoc """
  curl-as-flavor forward-only migration (PR-6+7, Allen — NO back-compat
  window) — one-shot rewrite of every pre-fold `curl_agent` `kind_snapshots`
  row onto the unified `Ezagent.Entity.Agent` Kind + `curl` flavor.

  The standalone curl Kind (formerly `:curl_agent`) is DELETED. There is NO
  rollback alias — a `curl_agent` row left un-migrated can no longer cold-load
  (its `kind_type` resolves to nothing). So as a production cutover this runs
  under the ordered-cutover discipline: **stop nodes → deploy new code →
  migrate → gate → start new-code nodes** (same as
  `mix ezagent.session.migrate_slice`).

  > **TEST / sandbox DB only** from this task. Do NOT run against dev/prod
  > (`~/.ezagent`) while a node is serving the affected rows (memory
  > `feedback_destructive_migration_anti_pattern`).

  ## Usage

      mix ezagent.curl.migrate            # apply
      mix ezagent.curl.migrate --dry-run  # report, no writes
      mix ezagent.curl.migrate --gate     # go/no-go: nonzero exit if any curl_agent rows remain

  The core logic lives in `Ezagent.PluginCurlAgent.CurlSnapshotMigration`
  (pure + testable); this task is the operator front door.
  """

  use Mix.Task

  alias Ezagent.PluginCurlAgent.CurlSnapshotMigration, as: Migration

  @impl Mix.Task
  def run(argv) do
    {opts, _positional, _} =
      OptionParser.parse(argv,
        switches: [dry_run: :boolean, gate: :boolean, help: :boolean],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)
        :ok

      opts[:gate] ->
        # Start ONLY the Repo (NOT the domain runtime — #52 lesson): the
        # `curl_agent` resolver branch is GONE and the standalone curl Kind is
        # DELETED, so a domain boot that cold-loaded a still-`curl_agent`-typed
        # row before the rewrite ran would crash (no Kind module). See
        # `Ezagent.Migration.RepoOnly`.
        Ezagent.Migration.RepoOnly.run(&run_gate/0)

      true ->
        Ezagent.Migration.RepoOnly.run(fn -> run_migrate(!!opts[:dry_run]) end)
    end
  end

  defp run_migrate(dry_run?) do
    {:ok, counts} = Migration.run(dry_run: dry_run?)

    Mix.shell().info(
      "curl→agent snapshot migration: scanned=#{counts.scanned} " <>
        "migrated=#{counts.migrated} already=#{counts.already} dry_run=#{counts.dry_run}"
    )

    if dry_run? do
      Mix.shell().info("(no rows written — re-run without --dry-run to apply)")
    else
      {:ok, remaining} = Migration.gate()

      if remaining == 0 do
        Mix.shell().info(
          "Gate: 0 curl_agent rows remain — safe to start new-code nodes."
        )
      else
        Mix.raise(
          "Gate: #{remaining} curl_agent row(s) STILL present after migration — NO-GO."
        )
      end
    end
  end

  defp run_gate do
    {:ok, remaining} = Migration.gate()

    if remaining == 0 do
      Mix.shell().info("Gate: 0 curl_agent rows remain — safe to start new-code nodes.")
    else
      Mix.raise(
        "Gate: #{remaining} curl_agent row(s) remain — NO-GO (run the migration)."
      )
    end
  end
end
