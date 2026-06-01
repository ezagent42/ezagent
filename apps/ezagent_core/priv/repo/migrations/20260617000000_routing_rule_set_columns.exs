defmodule EzagentCore.Repo.Migrations.RoutingRuleSetColumns do
  @moduledoc """
  Team-routing-unification (spec `docs/superpowers/specs/2026-06-01-team-routing-unification.md`
  §3.3) — rule-set columns on `routing_rules`.

  Adds three nullable columns so a routing rule can belong to a named
  **rule-set** (an ordered group forming one flow) and carry a
  **prompt-template reference** that the delivery transform (a later PR)
  renders onto the message for that rule's receiver:

  - `rule_set` — the rule-set name this rule belongs to (nil = a plain
    standalone rule; unchanged behaviour).
  - `position` — ordering within the set (default 0).
  - `prompt_template_ref` — the named prompt template applied at delivery
    to this rule's receiver (nil = no injection; unchanged behaviour).

  All nullable / defaulted so existing rows are unaffected (backward
  compatible). `RuleStore.load_into_registry/1` threads `rule_id` +
  `prompt_template_ref` into the RoutingRegistry value so the Resolver
  can carry them as matched-rule context (next PR).
  """

  use Ecto.Migration

  def up do
    alter table(:routing_rules) do
      add :rule_set, :string
      add :position, :integer, null: false, default: 0
      add :prompt_template_ref, :string
    end
  end

  def down do
    alter table(:routing_rules) do
      remove :prompt_template_ref
      remove :position
      remove :rule_set
    end
  end
end
