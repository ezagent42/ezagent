defmodule EzagentCore.Repo.Migrations.Pr146DissolveSyntheticSingletons do
  @moduledoc """
  PR #146 (SPEC v2 §5.7) — marker migration for the dissolution of
  the `routing-admin://default` and `pty-input://default` synthetic
  singleton Kinds.

  Per SPEC §5.11 "no backward compatibility, clean rebuild" the
  authoritative path is `mix ezagent.db.reset` (drops + recreates DB
  from scratch). This migration intentionally does NOT rewrite any
  legacy rows because:

  - Both Kinds had `persistence/0 :ephemeral` — they never wrote
    to `kind_snapshots` in the first place.
  - Any Capability rows with `kind = :routing_admin` or
    `kind = :pty_input` are wiped along with the rest of dev DB by
    `mix ezagent.db.reset`; admin's structural `:any/:any/:any` cap
    is rebuilt by the seed path and continues to satisfy all
    post-PR-146 cap shapes (`kind: :workspace|:session|:system|:agent`).

  ## Why a marker migration at all

  Ecto's schema_migrations table is the durable record of which
  migrations have been applied. Having PR #146 in that list documents
  the cutover for future devs reading the migration log. The
  alternative — no migration — is indistinguishable from "PR #146
  forgot to migrate" in a year.

  ## What changed

  - `routing-admin://default` synthetic Kind deleted
  - `pty-input://default` synthetic Kind deleted
  - `Ezagent.ActionSet.RoutingAdmin` renamed/generalized →
    `Ezagent.ActionSet.Routing`, registered on Workspace + Session +
    new `Ezagent.Entity.System` Kind
  - `Ezagent.ActionSet.Pty` registered on `Ezagent.Entity.Agent`;
    dispatch target is the agent URI itself
  - `routing-admin` + `pty-input` removed from
    `Ezagent.URI.@known_schemes`
  """

  use Ecto.Migration
  require Logger

  def up do
    Logger.info(
      "PR146 marker migration applied — synthetic singletons dissolved. " <>
        "Routing rule mutations now dispatch to scope-owning Kinds (Workspace / " <>
        "Session / System); PTY input dispatches directly to the agent URI. " <>
        "If this DB contains any legacy :routing_admin / :pty_input Capability " <>
        "rows, run `mix ezagent.db.reset` to wipe + rebuild."
    )

    :ok
  end

  def down do
    Logger.warning(
      "PR146 migration is not reversible — the routing-admin:// and pty-input:// " <>
        "schemes are removed from Ezagent.URI.@known_schemes; rolling back would " <>
        "leave dispatch targets unparseable."
    )

    :ok
  end
end
