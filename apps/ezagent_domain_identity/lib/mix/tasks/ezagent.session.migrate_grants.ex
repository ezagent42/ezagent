defmodule Mix.Tasks.Ezagent.Session.MigrateGrants do
  @shortdoc "chat→session: rewrite persisted Behavior.Chat caps to Behavior.Session"

  @moduledoc """
  chat→session rename (Allen 2026-06-12, NO back-compat) — one-shot rewrite of
  every persisted capability grant whose `behavior` is the OLD
  `Ezagent.ActionSet.Chat` to the NEW `Ezagent.ActionSet.Session`, in both
  persisted homes: `users.caps_json` (the SSOT) and the `:identity` slice in
  `kind_snapshots` (the cache).

  > **TEST / sandbox DB only** here. Do NOT run against dev/prod from this
  > task. As a production cutover step it runs under the same ordered cutover as
  > `mix ezagent.session.migrate_slice` (stop nodes → deploy → migrate → start).

  ## Usage

      mix ezagent.session.migrate_grants            # apply
      mix ezagent.session.migrate_grants --dry-run  # report, no writes
      mix ezagent.session.migrate_grants --gate     # go/no-go: nonzero exit if any Chat caps remain

  The core logic lives in `Ezagent.Identity.GrantMigration` (pure +
  testable); this task is the operator front door.
  """

  use Mix.Task

  alias Ezagent.Identity.GrantMigration

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
        Mix.Task.run("app.start")
        run_gate()

      true ->
        Mix.Task.run("app.start")
        run_migrate(!!opts[:dry_run])
    end
  end

  defp run_migrate(dry_run?) do
    {:ok, c} = GrantMigration.run(dry_run: dry_run?)

    Mix.shell().info(
      "chat→session grant migration: users(scanned=#{c.users_scanned} " <>
        "rewritten=#{c.users_rewritten}) snapshots(scanned=#{c.snapshots_scanned} " <>
        "rewritten=#{c.snapshots_rewritten}) dry_run=#{c.dry_run}"
    )

    if dry_run? do
      Mix.shell().info("(no rows written — re-run without --dry-run to apply)")
    else
      {:ok, remaining} = GrantMigration.gate()

      if remaining == 0 do
        Mix.shell().info("Gate: 0 persisted Behavior.Chat grants — safe to start new-code nodes.")
      else
        Mix.raise(
          "Gate: #{remaining} persisted home(s) STILL hold a Behavior.Chat grant after migration — NO-GO."
        )
      end
    end
  end

  defp run_gate do
    {:ok, remaining} = GrantMigration.gate()

    if remaining == 0 do
      Mix.shell().info("Gate: 0 persisted Behavior.Chat grants — safe to start new-code nodes.")
    else
      Mix.raise(
        "Gate: #{remaining} persisted home(s) hold a Behavior.Chat grant — NO-GO (run the migration)."
      )
    end
  end
end
