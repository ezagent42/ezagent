defmodule Mix.Tasks.Ezagent.Caps.SigningAudit do
  @shortdoc "Audit signed capabilities across all durable authority homes"
  @moduledoc """
  Reports the capability-signing drain across `users.caps_json`, latest
  `kind_snapshots` identity slices, `recipe_cap_bindings`, and the open
  quarantine ledger.

      mix ezagent.caps.signing_audit
      mix ezagent.caps.signing_audit --strict

  `--strict` fails when either unsigned authorizers or open quarantine rows
  remain. The task is read-only and never schedules or applies healing.
  """

  use Mix.Task

  alias Ezagent.Identity.CapSigningAudit

  @switches [strict: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, switches: @switches)

    if rest != [] or invalid != [] do
      Mix.raise("usage: mix ezagent.caps.signing_audit [--strict]")
    end

    Mix.Task.run("app.start")

    report = CapSigningAudit.scan()
    print_report(report)

    if opts[:strict] and not CapSigningAudit.clean?(report) do
      Mix.raise(
        "signing audit failed: #{report.totals.unsigned_authorizer} unsigned authorizer(s), " <>
          "#{report.totals.open_quarantined} open quarantine row(s)"
      )
    end

    :ok
  end

  @doc false
  def print_report(report) do
    totals = report.totals

    Mix.shell().info("Capability signing audit (read-only, four durable sources)")
    Mix.shell().info("signed: #{totals.signed}")
    Mix.shell().info("unsigned-authorizer: #{totals.unsigned_authorizer}")
    Mix.shell().info("sentinel-excluded: #{totals.sentinel_excluded}")
    Mix.shell().info("open-quarantined: #{totals.open_quarantined}")
    print_breakdown("unsigned by class", report.unsigned_by_class)
    print_breakdown("unsigned by source", report.unsigned_by_source)
    print_breakdown("open quarantine by reason", report.open_quarantine_by_reason)
  end

  defp print_breakdown(label, counts) do
    Mix.shell().info("")
    Mix.shell().info("#{label}:")

    if map_size(counts) == 0 do
      Mix.shell().info("  (none)")
    else
      counts
      |> Enum.sort_by(fn {key, _count} -> to_string(key) end)
      |> Enum.each(fn {key, count} -> Mix.shell().info("  #{key}: #{count}") end)
    end
  end
end
