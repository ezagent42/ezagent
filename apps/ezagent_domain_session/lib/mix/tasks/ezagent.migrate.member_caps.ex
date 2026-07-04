defmodule Mix.Tasks.Ezagent.Migrate.MemberCaps do
  @shortdoc "Backfill the universal member-cap onto existing session members"

  @moduledoc """
  Membership-cap unification A1.4 — backfill `cap(:session, Session, :receive, S)`
  onto every existing session member (sessions that pre-date the at-join grant).

  Enumerates sessions via a repo-only keyset-paginated READ; writes via the LIVE
  grant path (`grant_cap_via_router/4`) so the member's in-memory `:identity`
  slice AND its snapshot stay consistent. Idempotent (skip-already-held by exact
  member-cap identity) ⇒ **safe on a running node** (R2.2). The DECISION to run is
  an operator action — dry-run first, then live, per environment.

  ## Usage

      mix ezagent.migrate.member_caps            # apply
      mix ezagent.migrate.member_caps --dry-run  # report counts, no grants
      mix ezagent.migrate.member_caps --gate     # go/no-go: nonzero exit if any member lacks its cap

  The core logic lives in `Ezagent.Session.MemberCapMigration` (pure + testable);
  this task is the operator front door.
  """

  use Mix.Task

  alias Ezagent.Session.MemberCapMigration

  @impl Mix.Task
  def run(argv) do
    {opts, _positional, _} =
      OptionParser.parse(argv,
        switches: [dry_run: :boolean, gate: :boolean, help: :boolean],
        aliases: [h: :help]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      opts[:gate] ->
        Mix.Task.run("app.start")
        run_gate()

      true ->
        Mix.Task.run("app.start")
        run_migrate(!!opts[:dry_run])
    end
  end

  defp run_migrate(dry_run?) do
    report = MemberCapMigration.migrate(dry_run?)

    Mix.shell().info(
      "member-cap migration: sessions_scanned=#{report.sessions_scanned} " <>
        "members_granted=#{report.members_granted} " <>
        "skipped_already_held=#{report.skipped_already_held} " <>
        "ownerless_fallback=#{report.ownerless_fallback} dry_run=#{report.dry_run}"
    )

    if dry_run? do
      Mix.shell().info("(no caps written — re-run without --dry-run to apply)")
    end
  end

  defp run_gate do
    case MemberCapMigration.gate() do
      :ok ->
        Mix.shell().info("Gate: every session member holds its member-cap — OK.")

      {:error, {:uncovered_member_caps, count}} ->
        Mix.raise(
          "Gate: #{count} session member(s) still lack the member-cap — NO-GO " <>
            "(run `mix ezagent.migrate.member_caps`)."
        )
    end
  end
end
