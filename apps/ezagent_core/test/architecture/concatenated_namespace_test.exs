Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.ConcatenatedNamespaceTest do
  @moduledoc """
  Namespace-dot convention gate (2026-07-08, GLOSSARY Decision #161 follow-up).

  A module that lives inside an existing parent namespace must use the DOTTED
  child form (`Ezagent.Agent.RecipeResolver`), never parent-name concatenation
  (`Ezagent.AgentRecipeResolver`). The `concatenated_namespace_modules` counter
  flags a single-segment `defmodule Ezagent.XyzAbc` when `Ezagent.Xyz` is a
  namespace with dotted children in the SAME app, minus the sanctioned allowlist.

  Two halves:

    * the target-zero assertion over the real lib tree (`assert_zero`), and
    * positive + negative fixtures over the pure `concatenated_namespace_module?/3`
      classifier (the cross-file counter's classification core), proving a glued
      parent+child IS flagged, the dotted form and allowlisted / non-namespace
      compounds are NOT.
  """
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  alias Mix.Tasks.Ezagent.Arch.Scan

  # `Agent` is a namespace with dotted children in the app; `Kind` is not.
  @namespaces MapSet.new(["Agent", "Capability", "Entity"])
  @allowlist MapSet.new(["Ezagent.AgentFlavorRegistry", "Ezagent.AgentPassiveAttributes"])

  test "no concatenated-namespace modules in lib code (after the Recipe* renames)" do
    assert_zero(:concatenated_namespace_modules)
  end

  describe "classifier fixtures (concatenated_namespace_module?/3)" do
    test "POSITIVE: `Ezagent.AgentRecipeResolver` glues the `Agent` namespace" do
      assert Scan.concatenated_namespace_module?(
               @namespaces,
               "Ezagent.AgentRecipeResolver",
               @allowlist
             )
    end

    test "POSITIVE: `Ezagent.EntityPresenter` glues the `Entity` namespace" do
      assert Scan.concatenated_namespace_module?(
               @namespaces,
               "Ezagent.EntityPresenter",
               MapSet.new()
             )
    end

    test "NEGATIVE: the DOTTED `Ezagent.Agent.RecipeResolver` child is NOT flagged" do
      refute Scan.concatenated_namespace_module?(
               @namespaces,
               "Ezagent.Agent.RecipeResolver",
               @allowlist
             )
    end

    test "NEGATIVE: an allowlisted compound (`Ezagent.AgentFlavorRegistry`) is NOT flagged" do
      assert MapSet.member?(@allowlist, "Ezagent.AgentFlavorRegistry")

      refute Scan.concatenated_namespace_module?(
               @namespaces,
               "Ezagent.AgentFlavorRegistry",
               @allowlist
             )
    end

    test "NEGATIVE: `Ezagent.KindSupervisor` when `Kind` is NOT a namespace is NOT flagged" do
      refute Scan.concatenated_namespace_module?(
               @namespaces,
               "Ezagent.KindSupervisor",
               @allowlist
             )
    end

    test "NEGATIVE: a plain namespace root (`Ezagent.Agent`) with no compound is NOT flagged" do
      refute Scan.concatenated_namespace_module?(@namespaces, "Ezagent.Agent", @allowlist)
    end
  end
end
