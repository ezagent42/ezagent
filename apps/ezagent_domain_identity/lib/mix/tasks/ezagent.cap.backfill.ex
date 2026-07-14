defmodule Mix.Tasks.Ezagent.Cap.Backfill do
  @shortdoc "Dry-run Phase-4 capability signing re-authorization backfill"

  @moduledoc """
  Classify unsigned capability artifacts for Phase-4 signing without writing.

  The task has no apply mode. It reads durable capability homes, locates each
  matching `cap_granted` EventLog record, and re-authorizes the event through
  `Ezagent.Cap.issue/3` only to report whether a replacement could be issued.
  It never stores that replacement.

  ## Usage

      mix ezagent.cap.backfill --dry-run
  """

  use Mix.Task

  alias Ezagent.Identity.CapSigningBackfill

  @impl Mix.Task
  def run(argv) do
    {opts, positional, invalid} = OptionParser.parse(argv, strict: [dry_run: :boolean])

    if opts == [dry_run: true] and positional == [] and invalid == [] do
      Mix.Task.run("app.start")
      {:ok, report} = CapSigningBackfill.dry_run()

      Mix.shell().info(
        "cap signing backfill dry-run: scanned=#{report.scanned} " <>
          "would_sign=#{report.would_sign} quarantined=#{report.quarantined} skipped=#{report.skipped}"
      )

      Enum.each(report.entries, fn entry ->
        Mix.shell().info("#{entry.status}: #{inspect(entry)}")
      end)
    else
      Mix.raise("mix ezagent.cap.backfill only supports --dry-run; it has no apply mode")
    end
  end
end
