defmodule Mix.Tasks.Ezagent.Session.MigrateSlice do
  @shortdoc "chat→session: rename the :chat state-slice key to :session on session snapshots"

  @moduledoc """
  chat→session rename (Allen 2026-06-12, NO back-compat) — one-shot rename of
  the top-level `:chat` state-slice key to `:session` on every persisted
  session `kind_snapshots` row.

  The internal "Chat" Behavior is now `Ezagent.Behavior.Session`, whose
  `state_slice/0` auto-derives to `:session`. There is NO dual-read shim, so a
  snapshot persisted under the old `:chat`-slice code MUST be rewritten to
  `:session` BEFORE the new code serves it.

  > **TEST / sandbox DB only** here. Do NOT run against dev/prod from this
  > task. As a production cutover step it runs under the ordered-cutover
  > discipline (stop nodes → deploy → migrate → gate → start) documented on
  > `Ezagent.Session.SliceMigration`.

  ## Usage

      mix ezagent.session.migrate_slice            # apply
      mix ezagent.session.migrate_slice --dry-run  # report, no writes
      mix ezagent.session.migrate_slice --gate     # go/no-go: nonzero exit if any :chat rows remain

  The core logic lives in `Ezagent.Session.SliceMigration` (pure + testable);
  this task is the operator front door.
  """

  use Mix.Task

  alias Ezagent.Session.SliceMigration

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
    {:ok, counts} = SliceMigration.run(dry_run: dry_run?)

    Mix.shell().info(
      "chat→session slice migration: scanned=#{counts.scanned} renamed=#{counts.renamed} " <>
        "already=#{counts.already} dry_run=#{counts.dry_run}"
    )

    if dry_run? do
      Mix.shell().info("(no rows written — re-run without --dry-run to apply)")
    else
      {:ok, remaining} = SliceMigration.gate()

      if remaining == 0 do
        Mix.shell().info("Gate: 0 session rows with a :chat slice — safe to start new-code nodes.")
      else
        Mix.raise(
          "Gate: #{remaining} session row(s) STILL carry a :chat slice after migration — NO-GO."
        )
      end
    end
  end

  defp run_gate do
    {:ok, remaining} = SliceMigration.gate()

    if remaining == 0 do
      Mix.shell().info("Gate: 0 session rows with a :chat slice — safe to start new-code nodes.")
    else
      Mix.raise(
        "Gate: #{remaining} session row(s) carry a :chat slice — NO-GO (run the migration)."
      )
    end
  end
end
