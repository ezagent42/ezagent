defmodule Ezagent.CapabilityRegistry.Subjects do
  @moduledoc """
  ETS table holder for `Ezagent.CapabilityRegistry`'s subjects table.

  Thin module per `EzagentCore.EtsOwner` convention — owner reads
  `mod.table()` to get the table atom. The cap-subject `:ets.insert/2`
  + `:ets.lookup/2` + `:ets.tab2list/1` calls all live in
  `Ezagent.CapabilityRegistry`; this module only exists for EtsOwner
  to call `Ezagent.CapabilityRegistry.Subjects.table()` at boot.

  Schema: `{{kind, behavior, action}, %{description, dispatchable?}}`.
  See SPEC `docs/superpowers/specs/2026-05-23-capability-registry.md` §4.
  """

  @table :ezagent_capability_subjects

  def table, do: @table
end
