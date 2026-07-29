defmodule Mix.Tasks.Ezagent.Identity.Cutover do
  @shortdoc "#189 PR-3 — run the fenced identity-plane cutover and activate the epoch"
  @moduledoc """
  #189 PR-3 (FIX 5) — the governed, one-shot identity-plane CUTOVER.

  The store-authoritative read-flip + the store-driven ephemeral ever-created
  signal ship DORMANT behind the persisted cutover epoch
  (`Ezagent.Identity.Cutover`). This task is the ONLY sanctioned way to activate
  that epoch. Run it under a write-quiescence fence (no concurrent
  grant/revoke/provision) so the parity the barrier proves is the parity that
  holds at the cutover instant:

    1. **Backfill** — `mix ezagent.identity.backfill`: mirror every legacy
       durable principal into the store (license-valid ⇒ `active`; known but
       license-invalid ⇒ `revoked_unprovisioned`, NEVER `active`; tombstones
       preserved). Then **`mix ezagent.session.self_license_migration`** (FIX 4)
       — augment pre-carrier Session instances into principals.
    2. **Fleet-parity barrier** — `Ezagent.Identity.FleetParity.check/0`: the
       store must be a complete, bidirectionally parity-correct mirror of the
       legacy self-license set.
    3. **REFUSE unless COMPLETE** — a single discrepancy aborts with a non-zero
       exit; the epoch is NOT activated. Production stays on the PR-1
       legacy-authoritative semantics.
    4. **Activate the epoch** — `Ezagent.Identity.Cutover.activate/0` writes the
       durable singleton row atomically. From this instant the store is
       authoritative for reads on every node (each node's next epoch read picks
       it up; a fleet restart / `prime/0` promotes the fast path).

      mix ezagent.identity.cutover            # backfill → barrier → activate
      mix ezagent.identity.cutover --dry-run  # backfill(dry) + barrier only; NEVER activates

  Idempotent: re-running after activation re-verifies and re-affirms the epoch
  (the singleton insert is `ON CONFLICT DO NOTHING`; the epoch is monotone).
  """

  use Mix.Task

  alias Ezagent.Identity.{Cutover, FleetParity}

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)

    dry_run? = "--dry-run" in args

    Mix.shell().info("=== #189 identity-plane cutover ===")

    if Cutover.activated?() do
      Mix.shell().info("Epoch ALREADY active — re-verifying parity (idempotent).")
    end

    run_backfill(dry_run?)

    result = FleetParity.check()
    Mix.shell().info("Fleet parity — #{result.checked} durable holder(s) checked.")

    case decide(result, dry_run?) do
      :refuse ->
        report_incomplete(result)
        Mix.shell().error("REFUSED: the store is NOT a parity-correct mirror. Epoch NOT activated.")
        exit({:shutdown, 1})

      :dry_run ->
        Mix.shell().info("COMPLETE — parity holds. (--dry-run: epoch NOT activated.)")

      :activate ->
        activate!()
    end
  end

  @doc """
  The operator SAFETY INTERLOCK, extracted PURE for test coverage: the epoch is
  activated ONLY when parity is `complete` and this is not a `--dry-run`. An
  INCOMPLETE barrier ALWAYS `:refuse`s — the epoch is never activated on
  divergence. (`activate/0` itself is exercised by `Ezagent.Identity.CutoverTest`.)
  """
  @spec decide(%{complete: boolean()}, boolean()) :: :refuse | :dry_run | :activate
  def decide(%{complete: false}, _dry_run?), do: :refuse
  def decide(%{complete: true}, true), do: :dry_run
  def decide(%{complete: true}, false), do: :activate

  defp run_backfill(true) do
    Mix.shell().info("Step 1/2 — backfill (--dry-run)…")
    Mix.Task.rerun("ezagent.identity.backfill", ["--dry-run"])
    run_session_migration(["--dry-run"])
  end

  defp run_backfill(false) do
    Mix.shell().info("Step 1/2 — backfill…")
    Mix.Task.rerun("ezagent.identity.backfill", [])
    run_session_migration([])
  end

  # FIX 4 — the Session self-license migration lives in the session domain
  # (it references `Ezagent.ActionSet.SelfLicense`); invoke it as a mix task
  # (a runtime string, so NO identity→session compile dependency is created).
  defp run_session_migration(args) do
    Mix.shell().info("Step 1b — session self-license migration…")
    Mix.Task.rerun("ezagent.session.self_license_migration", args)
  end

  defp activate! do
    Mix.shell().info("Step 2/2 — COMPLETE. Activating the cutover epoch…")

    case Cutover.activate() do
      :ok ->
        if Cutover.activated?() do
          Mix.shell().info("EPOCH ACTIVE — the store is now authoritative for identity reads.")
        else
          Mix.shell().error("Activation reported :ok but the epoch row is not readable. ABORTING.")
          exit({:shutdown, 1})
        end

      {:error, reason} ->
        Mix.shell().error("Activation FAILED: #{inspect(reason)}. Epoch NOT activated.")
        exit({:shutdown, 1})
    end
  end

  defp report_incomplete(result) do
    Mix.shell().error("INCOMPLETE — #{length(result.discrepancies)} discrepancy(ies):")

    result.discrepancies
    |> Enum.group_by(fn {kind, _uri} -> kind end)
    |> Enum.sort_by(fn {kind, _} -> to_string(kind) end)
    |> Enum.each(fn {kind, entries} ->
      Mix.shell().error("  #{kind} (#{length(entries)}):")
      Enum.each(entries, fn {_kind, uri} -> Mix.shell().error("    #{uri}") end)
    end)
  end
end
