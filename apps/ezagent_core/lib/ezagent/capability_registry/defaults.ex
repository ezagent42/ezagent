defmodule Ezagent.CapabilityRegistry.Defaults do
  @moduledoc """
  ETS table holder for `Ezagent.CapabilityRegistry`'s default-grants
  table. Schema: `{kind, grant_fn}` where `grant_fn` is
  `(URI.t() | :any) -> [Ezagent.Capability.t()]`.

  Thin module per `EzagentCore.EtsOwner` convention. See SPEC §4.
  """

  @table :ezagent_capability_default_grants

  def table, do: @table
end
