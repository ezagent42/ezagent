defmodule Mix.Tasks.Ezagent.CapRevocation.Cutover do
  @shortdoc "Atomically re-mint durable capabilities as v2 and activate per-cap revocation"

  @moduledoc """
  Runs the stopped-node per-cap revocation cutover.

      mix ezagent.cap_revocation.cutover --dry-run
      mix ezagent.cap_revocation.cutover --approved-manifest-hash HASH

  See `docs/operations/per-cap-revocation-cutover.md` before running it.
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [dry_run: :boolean, approved_manifest_hash: :string]
      )

    if rest != [] or invalid != [] do
      Mix.raise("invalid arguments: #{inspect(rest ++ invalid)}")
    end

    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)

    opts = Keyword.put(opts, :io, fn message -> Mix.shell().info(message) end)

    case Ezagent.Identity.CapRevocationCutover.run(opts) do
      {:ok, report} ->
        Mix.shell().info("ACTIVE: #{inspect(report)}")

      {:dry_run, report} ->
        Mix.shell().info("DRY RUN (no writes): #{inspect(report)}")

      {:error, {:manifest_required, report}} ->
        Mix.shell().error("REFUSED: semantic diff requires reviewed manifest hash")
        Mix.shell().error("manifest_hash=#{report.manifest_hash}")
        Mix.shell().error(inspect(report))
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("REFUSED: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
