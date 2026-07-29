defmodule Mix.Tasks.Ezagent.Session.SelfLicenseMigration do
  @shortdoc "#189 PR-3 FIX 4 — migrate already-persisted Session instances into principals"
  @moduledoc """
  #189 PR-3 FIX 4 — run `Ezagent.Socialware.SessionSelfLicenseMigration`.

  Augments every already-persisted, REAL, non-revoked Session snapshot's
  `:kind_base` with `Ezagent.ActionSet.SelfLicense`, mints one current
  self-license into its `:identity` slice, and persists the snapshot + the
  durable identity-caps store row. A destroyed (marker-only) session is left
  buried; a previously-revoked session is recorded `revoked_unprovisioned`,
  never resurrected. Idempotent — a session already carrying a current
  self-license is skipped.

  Run it UNDER the write-quiescence fence, BEFORE the fleet-parity barrier — the
  `mix ezagent.identity.cutover` task invokes it automatically.

      mix ezagent.session.self_license_migration
      mix ezagent.session.self_license_migration --dry-run
  """

  use Mix.Task

  alias Ezagent.Socialware.SessionSelfLicenseMigration

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_session)

    dry_run? = "--dry-run" in args

    {:ok, result} = SessionSelfLicenseMigration.run(dry_run: dry_run?)

    Mix.shell().info(
      (dry_run? && "DRY RUN — session self-license migration (no writes).") ||
        "Session self-license migration complete."
    )

    for key <- [:migrated, :already_principal, :destroyed, :not_session, :revoked_adopted] do
      Mix.shell().info("  #{String.pad_trailing(to_string(key), 20)} #{Map.get(result, key, 0)}")
    end

    case result.errors do
      [] ->
        :ok

      errors ->
        Mix.shell().error("\n#{length(errors)} session(s) FAILED to migrate:")
        Enum.each(errors, fn {uri, reason} -> Mix.shell().error("  #{uri}: #{inspect(reason)}") end)
        exit({:shutdown, 1})
    end
  end
end
