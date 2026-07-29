defmodule Ezagent.Identity.Cutover.Runbook do
  @moduledoc """
  #189 PR-3 (FIX 5) release-runnable extraction — the governed, one-shot
  identity-plane CUTOVER operator flow, as a plain lib module (no Mix
  dependency) so it runs from a RELEASE node (`bin/ezagent eval`) as well as
  from `mix ezagent.identity.cutover` (now a thin shell over `run/1`).

  Run it under a write-quiescence fence (no concurrent grant/revoke/provision)
  so the parity the barrier proves is the parity that holds at the cutover
  instant:

    1. **Backfill** — `Ezagent.Identity.Backfill.run/1`: mirror every legacy
       durable principal into the store (license-valid ⇒ `active`; known but
       license-invalid ⇒ `revoked_unprovisioned`, NEVER `active`; tombstones
       preserved).
    2. **Session self-license migration** —
       `Ezagent.Socialware.SessionSelfLicenseMigration.run/1` (FIX 4) —
       augment pre-carrier Session instances into principals. This module
       lives in the `ezagent_domain_session` app; identity does not (and must
       not) declare a compile dependency on it, so it is dispatched via
       `apply/3` on a bare module VALUE (see `@session_migration_mod` below) —
       the release-safe analogue of the old `Mix.Task.rerun/2` runtime-string
       dispatch, which does not survive into a release (no `:mix` app there).
    3. **Fleet-parity barrier** — `Ezagent.Identity.FleetParity.check/0`: the
       store must be a complete, bidirectionally parity-correct mirror of the
       legacy self-license set (INCLUDING every real Session having gone
       through step 2).
    4. **REFUSE unless COMPLETE** — a single discrepancy (or a step-1/2
       failure) refuses; the epoch is NOT activated. Production stays on the
       legacy-authoritative semantics.
    5. **Activate the epoch** — `Ezagent.Identity.Cutover.activate/0` writes
       the durable singleton row atomically.

  Idempotent: re-running after activation re-verifies and re-affirms the epoch.

  ## Result contract

  `run/1` returns a structured result — `:activated | :dry_run | {:refused,
  reason}` — and never exits the calling process. Turning `{:refused, _}` into
  a nonzero exit status (mix task) or a raise (release) is the CALLER's job:

    * `Mix.Tasks.Ezagent.Identity.Cutover` — `exit({:shutdown, 1})`.
    * `EzagentCore.Release.identity_cutover/1` — `raise/1`, so `bin/ezagent
      eval "EzagentCore.Release.identity_cutover()"` fails loudly (nonzero
      exit) on divergence.
  """

  alias Ezagent.Identity.{Cutover, FleetParity}

  # Bare module VALUE (an alias literal, not a `Mod.fun()` qualified call) —
  # dispatched via `apply/3` below. This is NOT a hard reference per
  # `Ezagent.Architecture.UndeclaredUmbrellaDepTest`'s own documented exemption
  # ("reach the peer via `apply/3` / a module value"): it creates no compile
  # dependency from `ezagent_domain_identity` onto `ezagent_domain_session`,
  # preserving the acyclic im→session→agent / identity-is-a-lower-layer
  # dependency graph. Do NOT "simplify" this into a direct
  # `SessionSelfLicenseMigration.run(...)` call — that would declare an
  # undeclared cross-domain dep and redden `mix gate.arch`.
  @session_migration_mod Ezagent.Socialware.SessionSelfLicenseMigration

  @type io_fn :: (String.t() -> any())
  @type refusal_reason ::
          {:backfill_errors, [{String.t(), term()}]}
          | {:session_migration_errors, [{String.t(), term()}]}
          | {:parity_incomplete, FleetParity.result()}
          | {:activation_unreadable, term()}
          | {:activation_failed, term()}
  @type result :: :activated | :dry_run | {:refused, refusal_reason()}

  @doc """
  Run the fenced cutover operator flow.

  Options:

    * `:dry_run` (boolean, default `false`) — backfill(dry) + session-migration
      (dry) + barrier only; NEVER activates.
    * `:io` (`t:io_fn/0`, default `&IO.puts/1`) — info-level progress sink.
    * `:io_err` (`t:io_fn/0`, default writes to `:stderr`) — error-level sink.
      Kept SEPARATE from `:io` (not merged into one channel) because the
      stdout/stderr split is part of the existing observable CLI contract
      (`Ezagent.Identity.CutoverTest` captures `:stderr` specifically).
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    io = Keyword.get(opts, :io, &IO.puts/1)
    io_err = Keyword.get(opts, :io_err, &IO.puts(:stderr, &1))

    io.("=== #189 identity-plane cutover ===")

    if Cutover.activated?() do
      io.("Epoch ALREADY active — re-verifying parity (idempotent).")
    end

    with :ok <- run_backfill(dry_run?, io, io_err),
         :ok <- run_session_migration(dry_run?, io, io_err) do
      result = FleetParity.check()
      io.("Fleet parity — #{result.checked} durable holder(s) checked.")

      case decide(result, dry_run?) do
        :refuse ->
          report_incomplete(result, io_err)
          io_err.("REFUSED: the store is NOT a parity-correct mirror. Epoch NOT activated.")
          {:refused, {:parity_incomplete, result}}

        :dry_run ->
          io.("COMPLETE — parity holds. (--dry-run: epoch NOT activated.)")
          :dry_run

        :activate ->
          activate!(io, io_err)
      end
    else
      {:abort, reason} -> {:refused, reason}
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

  defp run_backfill(dry_run?, io, io_err) do
    args_note = if dry_run?, do: " (--dry-run)", else: ""
    io.("Step 1/3 — backfill#{args_note}…")

    # #189 PR-3 FINAL (ITEM 2) — CONSUME the backfill result. Any per-URI error
    # (a failed user/snapshot backfill OR authority-history adoption) is FATAL to
    # the cutover: abort BEFORE the session migration, the parity barrier, and
    # activation, so the epoch is never activated on an incomplete backfill.
    {:ok, results} = Ezagent.Identity.Backfill.run(dry_run: dry_run?, io: io, io_err: io_err)
    abort_on_backfill_errors(results, io_err)
  end

  # ITEM 2 — every backfill error aborts the cutover before the session
  # migration / barrier.
  defp abort_on_backfill_errors(results, io_err) do
    case for {uri, {:error, reason}} <- results, do: {uri, reason} do
      [] ->
        :ok

      errors ->
        io_err.("\nBACKFILL FAILED — #{length(errors)} principal(s) did not migrate:")
        Enum.each(errors, fn {uri, reason} -> io_err.("  #{uri}: #{inspect(reason)}") end)

        io_err.(
          "REFUSED: the backfill is INCOMPLETE. Epoch NOT activated — re-run the " <>
            "cutover after resolving the failure(s)."
        )

        {:abort, {:backfill_errors, errors}}
    end
  end

  # FIX 4 — the Session self-license migration lives in the session domain
  # (it references `Ezagent.ActionSet.SelfLicense`); dispatched via `apply/3`
  # on `@session_migration_mod` (a runtime module value, so NO
  # identity→session compile dependency is created — see the moduledoc note).
  defp run_session_migration(dry_run?, io, io_err) do
    io.("Step 2/3 — session self-license migration…")
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_session)

    {:ok, result} = apply(@session_migration_mod, :run, [[dry_run: dry_run?]])

    io.(
      (dry_run? && "DRY RUN — session self-license migration (no writes).") ||
        "Session self-license migration complete."
    )

    for key <- [:migrated, :already_principal, :destroyed, :not_session, :revoked_adopted] do
      io.("  #{String.pad_trailing(to_string(key), 20)} #{Map.get(result, key, 0)}")
    end

    case result.errors do
      [] ->
        :ok

      errors ->
        io_err.("\n#{length(errors)} session(s) FAILED to migrate:")
        Enum.each(errors, fn {uri, reason} -> io_err.("  #{uri}: #{inspect(reason)}") end)
        {:abort, {:session_migration_errors, errors}}
    end
  end

  defp activate!(io, io_err) do
    io.("Step 3/3 — COMPLETE. Activating the cutover epoch…")

    case Cutover.activate() do
      :ok ->
        if Cutover.activated?() do
          io.("EPOCH ACTIVE — the store is now authoritative for identity reads.")
          :activated
        else
          io_err.("Activation reported :ok but the epoch row is not readable. ABORTING.")
          {:refused, {:activation_unreadable, :not_readable_after_activate}}
        end

      {:error, reason} ->
        io_err.("Activation FAILED: #{inspect(reason)}. Epoch NOT activated.")
        {:refused, {:activation_failed, reason}}
    end
  end

  defp report_incomplete(result, io_err) do
    io_err.("INCOMPLETE — #{length(result.discrepancies)} discrepancy(ies):")

    result.discrepancies
    |> Enum.group_by(fn {kind, _uri} -> kind end)
    |> Enum.sort_by(fn {kind, _} -> to_string(kind) end)
    |> Enum.each(fn {kind, entries} ->
      io_err.("  #{kind} (#{length(entries)}):")
      Enum.each(entries, fn {_kind, uri} -> io_err.("    #{uri}") end)
    end)
  end
end
