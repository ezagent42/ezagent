Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.PluginDefinedKindsTest do
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  @moduledoc """
  domain-only-Kinds gate.

  INVARIANT: only domain apps (`apps/ezagent_domain_*`) and core
  (`apps/ezagent_core`) may define concrete Kinds. Plugin apps
  (`apps/ezagent_plugin_*`) may NOT.

  A "concrete Kind" is a module declaring `@behaviour Ezagent.Kind` EXACTLY. It is
  NOT `@behaviour Ezagent.Kind.Template` — a Template Class is a blueprint that
  plugins legitimately define, and the scanner's negative-lookahead excludes it.

  Kinds are a domain concern; plugins compose via Template / Behavior / View. A
  plugin defining `@behaviour Ezagent.Kind` must instead be a domain app, or the
  concept promoted to domain.

  The counter (`plugin_defined_kinds`) is plugin-app concrete-Kind files MINUS a
  sanctioned allowlist (`@plugin_defined_kind_allowlist` in
  `mix/tasks/ezagent.arch.scan.ex`). The allowlist is a visible, must-reach-0 debt
  ledger. The original snapshot named three grandfathered offenders; two had
  already been retired on origin/main, so one remains:

    - echo  → RETIRED: `apps/ezagent_plugin_echo` deleted entirely.
    - np/py → RETIRED: folded to `apps/ezagent_plugin_py/.../template/py_agent.ex`,
              now an `Ezagent.Kind.Template` (correctly NOT a concrete Kind).
    - hello → PENDING (allowlisted): `apps/ezagent_plugin_hello/lib/ezagent/entity/
              hello_builder.ex` — to be promoted to a socialware. Must reach 0.

  Target-zero: any NEW plugin Kind (or any re-add of an allowlisted concept
  elsewhere in a plugin) trips this gate.
  """

  test "no plugin app defines a concrete Kind beyond the grandfathered allowlist" do
    assert_zero(:plugin_defined_kinds)
  end
end
