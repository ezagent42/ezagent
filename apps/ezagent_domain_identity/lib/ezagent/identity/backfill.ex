defmodule Ezagent.Identity.Backfill do
  @moduledoc """
  #189 PR-2 D1 (release-runnable extraction) — the EXPLICIT, operator-triggered,
  idempotent migration that populates `Ezagent.IdentityCaps.Store` from the LEGACY
  authoritative sources for every existing durable principal, so the cutover can
  atomically cut reads over to the store.

  > Reads stay LEGACY-authoritative here. This module ONLY writes the store (a
  > complete, parity-verified mirror). It changes no authorization outcome.

  This is the WORK previously embedded in `Mix.Tasks.Ezagent.Identity.Backfill`,
  extracted so it can run from a context with no Mix available (a `bin/ezagent
  eval` release node via `EzagentCore.Release.identity_cutover/1` →
  `Ezagent.Identity.Cutover.Runbook`) as well as from the mix task, which is now
  a thin shell over `run/1`.

  ## What it does (the resurrection guard — codex spec-review F1)

  For each legacy principal it calls the DEDICATED, row-locked
  `Ezagent.IdentityCaps.Store.backfill/2` transition (NOT the generic shadow
  `persist/2`), which:

    * freshly verifies the legacy self-license against the URI's CURRENT
      authority generation — presence in `caps_json` / the snapshot is NOT
      enough (a revocation only bumps the generation and leaves stale
      licenses behind);
    * a license-valid principal → `active` (grandfathered activation);
    * a KNOWN principal with NO current-valid license (a regenesis'd /
      revoked / retired principal) → a durable `revoked_unprovisioned` row,
      NEVER `active` and NEVER left absent;
    * an existing invalid `active` row → DOWNGRADED to
      `revoked_unprovisioned`; a `revoked_unprovisioned` / `tombstoned` row
      is NEVER upgraded (only an authenticated re-provision restores it),
      tombstones preserved.

  Idempotent — safe to re-run.

  ## Population (codex F2 — explicit treatment for each holder class)

    * **Users** → from `users.caps_json` (`Ezagent.Users.list_all/0`).
    * **Snapshot-backed durable entities** (agents, sessions, …) → from the
      durable `:identity` slice read through the PUBLIC
      `Ezagent.Kind.read_durable/2` surface (never a raw snapshot reach-in).
    * **Ephemeral authenticated holders** (e.g. `ExternalMirrorWorker`) are
      DELIBERATELY NOT backfilled here — they have no durable legacy source;
      their durable identity + the fleet-barrier exemption are owned by the
      PR-3 read-cutover. See `Ezagent.Identity.AuthenticatedHolders`.
  """

  alias Ezagent.IdentityCaps.Store

  @type io_fn :: (String.t() -> any())

  @doc """
  Run the backfill migration.

  Options:

    * `:dry_run` (boolean, default `false`) — enumerate + classify, write nothing.
    * `:io` (`t:io_fn/0`, default `&IO.puts/1`) — info-level progress/report line sink.
    * `:io_err` (`t:io_fn/0`, default writes to `:stderr`) — error-level line sink.

  Returns `{:ok, results}` where `results` is the per-URI `{uri, outcome}` list
  (outcome is `{:error, reason}` for a failed principal). The caller (the
  cutover Runbook) CONSUMES this result and aborts on any error — a failed
  authority-history adoption must never be followed by `complete: true` +
  epoch activation.
  """
  @spec run(keyword()) :: {:ok, [{String.t(), term()}]}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    io = Keyword.get(opts, :io, &IO.puts/1)
    io_err = Keyword.get(opts, :io_err, &IO.puts(:stderr, &1))

    # Order matters: users + snapshots FIRST (valid principals acquire their
    # `active` rows), THEN authority-history adoption LAST (only genuinely
    # uncovered authority-history URIs remain absent, so they get an explicit
    # `revoked_unprovisioned` ever-created row — never an `active` one).
    results =
      (backfill_users(dry_run?) ++
         backfill_snapshots(dry_run?) ++
         backfill_authority_history(dry_run?))
      |> maybe_inject_forced_error()

    report(results, dry_run?, io, io_err)

    {:ok, results}
  end

  # TEST-ONLY forced-error seam (the p1/p2 seam precedent): compiled IN only for
  # `MIX_ENV=test`. Consulted ONLY when `:ezagent_domain_identity,
  # :backfill_force_error_uri` is set — never outside the ITEM-2 interlock
  # regression — so the "the cutover Runbook aborts + leaves the epoch ABSENT on a
  # failing backfill" test can force a deterministic backfill error (a real
  # adoption/DB failure is not reproducible in the sandbox). Compile-time gated
  # (not runtime), so it is a plain no-op in a compiled release — release-safe.
  @backfill_force_error_seam Mix.env() == :test

  if @backfill_force_error_seam do
    defp maybe_inject_forced_error(results) do
      case Application.get_env(:ezagent_domain_identity, :backfill_force_error_uri) do
        nil -> results
        uri_str -> results ++ [{uri_str, {:error, :forced_backfill_error}}]
      end
    end
  else
    defp maybe_inject_forced_error(results), do: results
  end

  defp backfill_users(dry_run?) do
    Ezagent.Users.list_all()
    |> Enum.map(fn user ->
      uri = to_uri(user.uri)
      caps = Map.get(user, :caps) || []
      run_one(uri, caps, dry_run?)
    end)
  end

  defp backfill_snapshots(dry_run?) do
    Ezagent.Kind.list_durable_instances()
    |> Enum.reject(fn {uri_str, _meta} -> user_uri?(uri_str) end)
    |> Enum.map(fn {uri_str, _meta} ->
      uri = Ezagent.URI.new!(uri_str)

      case read_identity(uri) do
        {:ok, caps} ->
          run_one(uri, caps, dry_run?)

        :no_identity ->
          # The row read cleanly but carries no `:identity` slice
          # (template/session-without-caps/…) — nothing to mirror; not a
          # principal for the identity-caps store.
          {uri_str, :no_identity}

        {:error, reason} ->
          # The legacy source could NOT be read (decode failure, vanished row).
          # Surface it as a FAILED principal — never silently a `:no_identity`
          # skip that would let it disappear from the migration (codex
          # impl-review finding 3).
          {uri_str, {:error, {:read_failed, reason}}}
      end
    end)
  end

  # Split "no `:identity` slice" (legitimate skip) from "the read itself failed"
  # (`read_durable/3` collapses a decode `:error` and an absent row to
  # `{:error, :not_created}`). Raises are caught so one unreadable snapshot never
  # aborts the whole migration silently.
  defp read_identity(uri) do
    case Ezagent.Kind.read_durable(uri, :identity) do
      {:ok, identity, _meta} when is_map(identity) ->
        if Map.has_key?(identity, :caps), do: {:ok, caps_from_slice(identity)}, else: :no_identity

      {:ok, _non_caps_slice, _meta} ->
        :no_identity

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # #189 PR-3 FIX 3 — adopt every AUTHORITY-HISTORY URI (`kind_cap_authorities`
  # rows, active OR retired) that has NO store row as an explicit ever-created
  # `revoked_unprovisioned` row. Runs LAST, so a URI still absent here was NOT
  # covered by the users/snapshots backfill (a pre-cutover ephemeral principal
  # whose durable creation fact survives only in the authority history). Never
  # touches an existing row (`Store.adopt_absent_authority_history/1` is
  # strictly absent-only), so a valid `active` principal is left intact.
  defp backfill_authority_history(dry_run?) do
    Ezagent.Ecto.KindCapAuthority.all_uris()
    |> Enum.map(fn uri_str ->
      uri = to_uri(uri_str)
      adopt_authority_history(uri, dry_run?)
    end)
  end

  defp adopt_authority_history(uri, true) do
    classification =
      if Store.has_row?(uri), do: :present, else: :would_adopt_revoked_unprovisioned

    {URI.to_string(uri), classification}
  end

  defp adopt_authority_history(uri, false) do
    case Store.adopt_absent_authority_history(uri) do
      {:ok, outcome} -> {URI.to_string(uri), outcome}
      {:error, reason} -> {URI.to_string(uri), {:error, {:adopt_failed, reason}}}
    end
  end

  # In `--dry-run` mode compute ONLY the would-be classification (does the
  # legacy source present a current-valid self-license?) without writing.
  defp run_one(uri, caps, true) do
    classification =
      if Store.has_current_self_license?(Enum.to_list(caps), uri),
        do: :would_activate,
        else: :would_revoke_unprovisioned

    {URI.to_string(uri), classification}
  end

  defp run_one(uri, caps, false) do
    case Store.backfill(uri, caps) do
      {:ok, status} -> {URI.to_string(uri), status}
      {:error, reason} -> {URI.to_string(uri), {:error, reason}}
    end
  end

  defp report(results, dry_run?, io, io_err) do
    counts = Enum.frequencies_by(results, fn {_uri, outcome} -> outcome end)

    io.((dry_run? && "DRY RUN — no writes.") || "Backfill complete.")
    io.("#{length(results)} legacy principal(s) processed:")

    counts
    |> Enum.sort_by(fn {outcome, _n} -> inspect(outcome) end)
    |> Enum.each(fn {outcome, n} ->
      io.("  #{String.pad_trailing(inspect(outcome), 28)} #{n}")
    end)

    errors = for {uri, {:error, reason}} <- results, do: {uri, reason}

    if errors != [] do
      io_err.("\n#{length(errors)} principal(s) FAILED to backfill:")
      Enum.each(errors, fn {uri, reason} -> io_err.("  #{uri}: #{inspect(reason)}") end)
    end
  end

  defp caps_from_slice(slice) do
    case Map.get(slice, :caps) do
      %MapSet{} = caps -> MapSet.to_list(caps)
      caps when is_list(caps) -> caps
      _ -> []
    end
  end

  defp user_uri?(uri) when is_binary(uri) do
    case Ezagent.URI.new!(uri) do
      %URI{scheme: "entity"} = parsed -> Ezagent.URI.type?(parsed, :user)
      _ -> false
    end
  rescue
    _ -> false
  end

  defp to_uri(%URI{} = uri), do: uri
  defp to_uri(uri) when is_binary(uri), do: Ezagent.URI.new!(uri)
end
