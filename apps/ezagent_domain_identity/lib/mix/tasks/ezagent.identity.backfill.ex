defmodule Mix.Tasks.Ezagent.Identity.Backfill do
  @shortdoc "#189 PR-2 — backfill the unified identity-caps store from the legacy sources"
  @moduledoc """
  #189 PR-2 D1 — the EXPLICIT, operator-triggered, idempotent migration that
  populates `Ezagent.EntityCaps.Store` from the LEGACY authoritative sources
  for every existing durable principal, so PR-3 can atomically cut reads over
  to the store.

  Release-runnable extraction: this task is now a THIN SHELL over
  `Ezagent.Identity.Backfill.run/1` (a plain lib module — no Mix dependency),
  which does all the actual work. See that module's docs for the resurrection
  guard (codex F1) + the per-holder-class population rules (codex F2). This
  task only parses `--dry-run` and wires `Mix.shell()` as the info/error line
  sinks.

  ## Usage

      mix ezagent.identity.backfill          # run the migration
      mix ezagent.identity.backfill --dry-run # enumerate + classify, write nothing
  """

  use Mix.Task

  @impl Mix.Task
  # Returns `{:ok, results}` where `results` is the per-URI `{uri, outcome}` list
  # (outcome is `{:error, reason}` for a failed principal). #189 PR-3 FINAL
  # (ITEM 2) — the cutover Runbook (`Ezagent.Identity.Cutover.Runbook`) CONSUMES
  # this result and aborts on ANY error, so a failed authority-history adoption
  # can never be followed by `complete: true` + epoch activation. Standalone
  # (`mix ezagent.identity.backfill`) the return is discarded by Mix; the
  # printed report is unchanged.
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)

    dry_run? = "--dry-run" in args

    Ezagent.Identity.Backfill.run(
      dry_run: dry_run?,
      io: fn msg -> Mix.shell().info(msg) end,
      io_err: fn msg -> Mix.shell().error(msg) end
    )
  end
end
