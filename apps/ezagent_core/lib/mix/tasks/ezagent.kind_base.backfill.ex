defmodule Mix.Tasks.Ezagent.KindBase.Backfill do
  @shortdoc "P5-0: backfill nil :kind_base on session snapshots + go/no-go gate"

  @moduledoc """
  P5-0 (socialware substrate collapse) — one-shot backfill of every persisted
  session snapshot's `:kind_base` slice with its concrete as-built behavior set,
  classified by DURABLE SLICE SHAPE (`:surface`/`:turns` ⇒ socialware, else
  `:external_mirror` ⇒ chat; ambiguous/unclassifiable rows FAIL LOUD).

  This is the load-bearing precondition for P5-1 (the behavior-set union on the
  single collapsed session Kind): once the declared list is the union, a
  nil-`:kind_base` chat row would cold-load with the entire socialware superset
  and silently break P1's per-instance denial invariant. The backfill makes
  every existing session row's set explicit + non-nil BEFORE the union lands.

  > **TEST / sandbox DB only** per the P5 plan. Do NOT run against dev/prod.

  ## Usage

      mix ezagent.kind_base.backfill            # apply
      mix ezagent.kind_base.backfill --dry-run  # classify + report, no writes
      mix ezagent.kind_base.backfill --gate     # go/no-go: print + exit nonzero if >0 remain

  The core logic lives in `Ezagent.Kind.KindBaseBackfill` (pure +
  testable); this task is the operator front door.
  """

  use Mix.Task

  alias Ezagent.Kind.KindBaseBackfill

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
        run_backfill(!!opts[:dry_run])
    end
  end

  defp run_backfill(dry_run?) do
    {:ok, counts} = KindBaseBackfill.run(dry_run: dry_run?)

    Mix.shell().info(
      "P5-0 kind_base backfill: scanned=#{counts.scanned} backfilled=#{counts.backfilled} " <>
        "already=#{counts.already} dry_run=#{counts.dry_run}"
    )

    if dry_run? do
      Mix.shell().info("(no rows written — re-run without --dry-run to apply)")
    else
      {:ok, remaining} = KindBaseBackfill.gate()

      if remaining == 0 do
        Mix.shell().info("Gate: 0 session rows with nil :kind_base — GO for P5-1.")
      else
        Mix.raise(
          "Gate: #{remaining} session row(s) STILL have nil :kind_base after backfill — NO-GO."
        )
      end
    end
  end

  defp run_gate do
    {:ok, remaining} = KindBaseBackfill.gate()

    if remaining == 0 do
      Mix.shell().info("Gate: 0 session rows with nil :kind_base — GO for P5-1.")
    else
      Mix.raise(
        "Gate: #{remaining} session row(s) with nil :kind_base — NO-GO (run the backfill)."
      )
    end
  end
end
