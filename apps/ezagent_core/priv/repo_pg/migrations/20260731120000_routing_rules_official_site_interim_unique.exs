defmodule EzagentCore.Repo.Migrations.RoutingRulesOfficialSiteInterimUnique do
  use Ecto.Migration

  @moduledoc """
  INTERIM (removed by the #1667 structural fix): the hello official-site
  seed (`EzagentPluginHello.OfficialSiteSeed`) installs EXACTLY ONE
  session-scoped delivery rule carrying `rule_set = 'official-site-interim'`
  (the seed-owned marker; keep in sync with `@delivery_rule_set` in
  `official_site_seed.ex`).

  `routing_rules` has NO semantic unique constraint (pg baseline
  20260622000000), so two deploy nodes boot-seeding concurrently could both
  observe absence and both insert. This partial unique index is the
  DB-level duplicate guard: the loser's insert violates the index, the seed
  adopts the winner's identical row, and the reconcile converges to one row.
  """

  def change do
    create(
      unique_index(:routing_rules, [:table_name],
        name: :routing_rules_official_site_interim_unique,
        where: "rule_set = 'official-site-interim'"
      )
    )
  end
end
