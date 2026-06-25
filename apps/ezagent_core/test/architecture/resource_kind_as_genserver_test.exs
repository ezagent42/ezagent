Code.require_file("architecture_case.exs", __DIR__)

defmodule EzagentCore.Architecture.ResourceKindAsGenserverTest do
  @moduledoc """
  kanban-as-role K5 — resource-only-files gate (cap 0).

  `resource://` is "not a live Kind — pure data ref, filesystem on disk"
  (`uri-design.md`). The abandoned Plan-B (#964) overloaded it with live spawnable
  Kinds (`resource_kinds/0` plugin callback + a `ResourceKindRegistry` register).
  kanban-as-role re-homes the board onto an `Entity.Agent` (role × native) and
  this AST gate locks the Plan-B pattern out permanently.

  Two halves:

    * the target-zero assertion over the real lib tree (`assert_zero`), and
    * positive + negative AST fixtures (plan K5 MEDIUM): a `resource_kinds/0`
      module IS flagged; a `resource_types/0` FsResolver is NOT.
  """
  use ExUnit.Case, async: true

  import EzagentCore.ArchitectureCase

  alias Mix.Tasks.Ezagent.Arch.Scan

  test "no resource:// → live Kind / ResourceKindRegistry registration in lib code" do
    assert_zero(:resource_kind_as_genserver)
  end

  describe "AST predicate fixtures (plan K5 MEDIUM)" do
    test "POSITIVE: a `resource_kinds/0` plugin callback is flagged" do
      source = """
      defmodule SomePlugin do
        use Ezagent.Plugin

        @impl Ezagent.Plugin
        def resource_kinds, do: [{:kanban, SomePlugin.Kanban}]
      end
      """

      assert Scan.count_resource_kind_as_genserver_in_source(source) == 1
    end

    test "POSITIVE: a `*ResourceKindRegistry.register(...)` call is flagged" do
      source = """
      defmodule SomeApp do
        def boot do
          Ezagent.ResourceKindRegistry.register(:kanban, SomeApp.Kanban)
        end
      end
      """

      assert Scan.count_resource_kind_as_genserver_in_source(source) == 1
    end

    test "NEGATIVE: a `resource_types/0` FsResolver callback is NOT flagged" do
      source = """
      defmodule SomeFsResolver do
        @doc "the SANCTIONED pure-FS resolver shape"
        def resource_types, do: [:uploads, :credentials]

        def path!(uri), do: Ezagent.System.FsResolver.path!(uri)
      end
      """

      assert Scan.count_resource_kind_as_genserver_in_source(source) == 0
    end

    test "NEGATIVE: an unrelated `register/2` (not ResourceKindRegistry) is NOT flagged" do
      source = """
      defmodule SomeApp do
        def boot do
          Ezagent.RoleRegistry.register(%{name: "kanban-manager"})
          Registry.register(MyRegistry, :key, :value)
        end
      end
      """

      assert Scan.count_resource_kind_as_genserver_in_source(source) == 0
    end

    test "`# arch-allow:` suppresses a flagged site" do
      source = """
      defmodule SomePlugin do
        def resource_kinds, do: [] # arch-allow: legacy shim under removal
      end
      """

      assert Scan.count_resource_kind_as_genserver_in_source(source) == 0
    end
  end
end
