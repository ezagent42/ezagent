defmodule Mix.Tasks.Ezagent.Identity.Backfill do
  @shortdoc "#189 PR-2 — backfill the unified identity-caps store from the legacy sources"
  @moduledoc """
  #189 PR-2 D1 — the EXPLICIT, operator-triggered, idempotent migration that
  populates `Ezagent.EntityCaps.Store` from the LEGACY authoritative sources
  for every existing durable principal, so PR-3 can atomically cut reads over
  to the store.

  > Reads stay LEGACY-authoritative in PR-2. This task ONLY writes the store
  > (a complete, parity-verified mirror). It changes no authorization outcome.

  ## What it does (the resurrection guard — codex spec-review F1)

  For each legacy principal it calls the DEDICATED, row-locked
  `Ezagent.EntityCaps.Store.backfill/2` transition (NOT the generic shadow
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

  ## Usage

      mix ezagent.identity.backfill          # run the migration
      mix ezagent.identity.backfill --dry-run # enumerate + classify, write nothing
  """

  use Mix.Task

  alias Ezagent.EntityCaps.Store

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_identity)

    dry_run? = "--dry-run" in args

    results =
      backfill_users(dry_run?) ++ backfill_snapshots(dry_run?)

    report(results, dry_run?)
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
    Ezagent.Ecto.KindSnapshot.list_all()
    |> Enum.reject(fn row -> user_uri?(row.uri) end)
    |> Enum.map(fn row ->
      uri = Ezagent.URI.new!(row.uri)

      case Ezagent.Kind.read_durable(uri, :identity) do
        {:ok, identity, _meta} when is_map(identity) ->
          run_one(uri, caps_from_slice(identity), dry_run?)

        _ ->
          # No `:identity` slice (template/session-without-caps/…) — nothing
          # to mirror; not a principal for the identity-caps store.
          {row.uri, :no_identity}
      end
    end)
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

  defp report(results, dry_run?) do
    counts = Enum.frequencies_by(results, fn {_uri, outcome} -> outcome end)

    Mix.shell().info((dry_run? && "DRY RUN — no writes.") || "Backfill complete.")
    Mix.shell().info("#{length(results)} legacy principal(s) processed:")

    counts
    |> Enum.sort_by(fn {outcome, _n} -> inspect(outcome) end)
    |> Enum.each(fn {outcome, n} ->
      Mix.shell().info("  #{String.pad_trailing(inspect(outcome), 28)} #{n}")
    end)

    errors = for {uri, {:error, reason}} <- results, do: {uri, reason}

    if errors != [] do
      Mix.shell().error("\n#{length(errors)} principal(s) FAILED to backfill:")
      Enum.each(errors, fn {uri, reason} -> Mix.shell().error("  #{uri}: #{inspect(reason)}") end)
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
