defmodule Mix.Tasks.Ezagent.Identity.Cutover do
  @shortdoc "#189 PR-3 — run the fenced identity-plane cutover and activate the epoch"
  @moduledoc """
  #189 PR-3 (FIX 5) — the governed, one-shot identity-plane CUTOVER.

  The store-authoritative read-flip + the store-driven ephemeral ever-created
  signal ship DORMANT behind the persisted cutover epoch
  (`Ezagent.Identity.Cutover`). This task is the ONLY sanctioned way to activate
  that epoch from a dev/CI box with Mix available. Run it under a
  write-quiescence fence (no concurrent grant/revoke/provision) so the parity
  the barrier proves is the parity that holds at the cutover instant:

    1. **Backfill** — mirror every legacy durable principal into the store
       (license-valid ⇒ `active`; known but license-invalid ⇒
       `revoked_unprovisioned`, NEVER `active`; tombstones preserved). Then the
       **session self-license migration** (FIX 4) — augment pre-carrier
       Session instances into principals.
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

  ## Release nodes (canary/prod — no Mix)

  This task is a THIN SHELL over `Ezagent.Identity.Cutover.Runbook.run/1` (a
  plain lib module). A release container has no Mix, so use the release
  entrypoint instead:

      bin/ezagent eval "EzagentCore.Release.identity_cutover()"
      bin/ezagent eval "EzagentCore.Release.identity_cutover(dry_run: true)"

  Both paths run the IDENTICAL interlock (backfill → session migration →
  parity barrier → decide → activate); only the exit-signaling differs (`mix`
  exits nonzero, the release `raise`s so `bin/ezagent eval` fails loudly).
  """

  use Mix.Task

  alias Ezagent.Identity.Cutover.Runbook

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)

    dry_run? = "--dry-run" in args

    io = fn msg -> Mix.shell().info(msg) end
    io_err = fn msg -> Mix.shell().error(msg) end

    case Runbook.run(dry_run: dry_run?, io: io, io_err: io_err) do
      :activated -> :ok
      :dry_run -> :ok
      {:refused, _reason} -> exit({:shutdown, 1})
    end
  end

  @doc "See `Ezagent.Identity.Cutover.Runbook.decide/2` — the operator safety interlock."
  defdelegate decide(result, dry_run?), to: Runbook
end
