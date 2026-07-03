Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.PluginDefinedKindsTest do
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  alias Mix.Tasks.Ezagent.Arch.Scan

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

  # --- teeth-tests for the 2026-07 batch-1 AST conversion --------------------
  #
  # `plugin_defined_kinds` is target-zero, so a measured 0 does NOT prove the AST
  # matcher has teeth (it would read 0 even if it matched nothing). These tests
  # prove it fires — on the REAL allowlisted offender AND on the aliased form a
  # raw `@behaviour Ezagent.Kind` grep would miss.

  test "the AST matcher has teeth on real code: hello_builder IS a pre-allowlist offender" do
    # Proves the matcher actually recognizes the grandfathered concrete Kind (the
    # only reason the post-allowlist count is 0 is the allowlist, not a toothless
    # matcher). This is the "names the offender" check.
    offenders = Scan.plugin_defined_kind_offender_files()

    assert "apps/ezagent_plugin_hello/lib/ezagent/entity/hello_builder.ex" in offenders,
           "expected hello_builder (the grandfathered concrete Kind) among offenders, got: #{inspect(offenders)}"

    # …and every offender is in fact sanctioned, so the gate nets zero.
    assert Scan.count(:plugin_defined_kinds) == 0
  end

  describe "AST @behaviour predicate (teeth)" do
    test "POSITIVE: a plain `@behaviour Ezagent.Kind` is flagged" do
      source = """
      defmodule SomePlugin.MyKind do
        @behaviour Ezagent.Kind
      end
      """

      assert Scan.count_plugin_defined_kinds_in_source(source) == 1
    end

    test "POSITIVE: an ALIASED `@behaviour Kind` a raw grep would miss is flagged" do
      source = """
      defmodule SomePlugin.MyKind do
        alias Ezagent.Kind
        @behaviour Kind
      end
      """

      # a raw `@behaviour Ezagent.Kind` regex does NOT see the aliased form…
      refute Enum.any?(String.split(source, "\n"), &Regex.match?(~r/@behaviour\s+Ezagent\.Kind/, &1))
      # …but the alias-resolving AST matcher does.
      assert Scan.count_plugin_defined_kinds_in_source(source) == 1
    end

    test "POSITIVE: an `alias Ezagent.Kind, as: K` + `@behaviour K` is flagged" do
      source = """
      defmodule SomePlugin.MyKind do
        alias Ezagent.Kind, as: K
        @behaviour K
      end
      """

      assert Scan.count_plugin_defined_kinds_in_source(source) == 1
    end

    test "NEGATIVE: `@behaviour Ezagent.Kind.Template` (a Template Class) is NOT flagged" do
      source = """
      defmodule SomePlugin.MyTemplate do
        @behaviour Ezagent.Kind.Template
      end
      """

      assert Scan.count_plugin_defined_kinds_in_source(source) == 0
    end

    test "NEGATIVE: an alias of `Ezagent.Kind.Template` used as @behaviour is NOT flagged" do
      source = """
      defmodule SomePlugin.MyTemplate do
        alias Ezagent.Kind.Template, as: T
        @behaviour T
      end
      """

      assert Scan.count_plugin_defined_kinds_in_source(source) == 0
    end

    test "`# arch-allow:` suppresses a flagged @behaviour" do
      source = """
      defmodule SomePlugin.MyKind do
        @behaviour Ezagent.Kind # arch-allow: legacy under removal
      end
      """

      assert Scan.count_plugin_defined_kinds_in_source(source) == 0
    end
  end
end
