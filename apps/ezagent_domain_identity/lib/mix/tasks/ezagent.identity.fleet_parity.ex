defmodule Mix.Tasks.Ezagent.Identity.FleetParity do
  @shortdoc "#189 PR-2 — report whether the identity-caps store is a parity-correct legacy mirror"
  @moduledoc """
  #189 PR-2 D2 — run the fleet-completion barrier
  (`Ezagent.Identity.FleetParity.check/0`) and print the result.

  Answers "is `Ezagent.EntityCaps.Store` a complete, bidirectionally
  parity-correct mirror of the legacy durable-holder self-license set?" — the
  predicate PR-3's atomic read-cutover is gated on. Enumerates the closed
  durable-holder worklist from the LEGACY source, so an empty store reports
  incomplete (never "done").

  Exit status is `0` when complete, `1` when incomplete — so a deployment /
  CI step can gate on it (under the write-quiescence fence PR-3 owns; see the
  module docs for the TOCTOU caveat).

      mix ezagent.identity.fleet_parity
  """

  use Mix.Task

  alias Ezagent.Identity.FleetParity

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)

    result = FleetParity.check()

    Mix.shell().info("Fleet parity — #{result.checked} durable holder(s) checked.")

    if result.complete do
      Mix.shell().info("COMPLETE — the store is a parity-correct mirror of legacy.")
    else
      Mix.shell().error("INCOMPLETE — #{length(result.discrepancies)} discrepancy(ies):")

      result.discrepancies
      |> Enum.group_by(fn {kind, _uri} -> kind end)
      |> Enum.sort_by(fn {kind, _} -> to_string(kind) end)
      |> Enum.each(fn {kind, entries} ->
        Mix.shell().error("  #{kind} (#{length(entries)}):")
        Enum.each(entries, fn {_kind, uri} -> Mix.shell().error("    #{uri}") end)
      end)

      exit({:shutdown, 1})
    end
  end
end
