defmodule Ezagent.PluginTest do
  @moduledoc """
  Tests for the `Ezagent.Plugin` behaviour + `use Ezagent.Plugin` macro
  (SPEC §2, §3.1) — the contract surface itself.

  `boot/1` is exercised in `Ezagent.Plugin.BootTest`; the registries in
  their own test files.
  """

  use ExUnit.Case, async: false

  alias Ezagent.Test.FixturePlugin

  describe "use Ezagent.Plugin — behaviour + defaults (SPEC §3.1)" do
    test "a correct fixture implements the behaviour" do
      behaviours =
        FixturePlugin.module_info(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Ezagent.Plugin in behaviours
    end

    test "plugin_info/0 returns a well-formed map" do
      info = FixturePlugin.plugin_info()
      assert info.slug == "fixture"
      assert info.name == "Fixture Plugin"
      assert is_binary(info.description) and info.description != ""
      assert info.version == "0.1.0"
    end

    test "every optional callback has a default via defoverridable" do
      assert FixturePlugin.kinds() == []
      assert FixturePlugin.behaviors() == []
      assert FixturePlugin.spawns() == []
      assert FixturePlugin.template_classes() == []
      assert FixturePlugin.agent_flavors() == []
      assert FixturePlugin.routing_tables() == []
      assert FixturePlugin.config_surface() == nil
      assert FixturePlugin.children() == []
      assert FixturePlugin.after_boot() == :ok
    end

    test "a plugin can override an optional callback" do
      defmodule OverridingPlugin do
        use Ezagent.Plugin

        @impl Ezagent.Plugin
        def plugin_info do
          %{slug: "ovr", name: "Overrider", description: "d", version: "1.0.0"}
        end

        @impl Ezagent.Plugin
        def config_surface, do: %{kind: :route, path: "/x", label: "X"}
      end

      assert OverridingPlugin.config_surface() == %{kind: :route, path: "/x", label: "X"}
      # untouched optionals still carry defaults
      assert OverridingPlugin.kinds() == []
    end
  end

  describe "core_schemes/0" do
    test "is exactly the six SPEC v3 schemes" do
      assert Enum.sort(Ezagent.Plugin.core_schemes()) ==
               Enum.sort(~w(entity session template resource workspace system))
    end
  end

  describe "@after_compile plugin-LOCAL validation (SPEC §3.1 / verification §9 item 1)" do
    # The broken fixtures are compiled via `Code.eval_string/1` so the
    # deliberate failure does NOT break this suite's own compilation.
    # `@after_compile` raises `CompileError` once the module body
    # finishes compiling — `Code.eval_string` surfaces that.

    test "a plugin missing plugin_info/0 raises CompileError" do
      source = """
      defmodule BrokenPluginNoInfo#{unique()} do
        use Ezagent.Plugin
        # plugin_info/0 deliberately omitted — must fail the @after_compile.
      end
      """

      err = assert_raise CompileError, fn -> Code.eval_string(source) end
      assert err.description =~ "plugin_info/0"
    end

    test "a plugin whose plugin_info/0 returns a non-map raises CompileError" do
      source = """
      defmodule BrokenPluginBadShape#{unique()} do
        use Ezagent.Plugin
        @impl Ezagent.Plugin
        def plugin_info, do: :not_a_map
      end
      """

      err = assert_raise CompileError, fn -> Code.eval_string(source) end
      assert err.description =~ "plugin_info/0"
    end

    test "a plugin with an empty slug raises CompileError" do
      source = """
      defmodule BrokenPluginEmptySlug#{unique()} do
        use Ezagent.Plugin
        @impl Ezagent.Plugin
        def plugin_info do
          %{slug: "", name: "n", description: "d", version: "1.0.0"}
        end
      end
      """

      err = assert_raise CompileError, fn -> Code.eval_string(source) end
      assert err.description =~ "slug"
    end

    test "a plugin with a non-URL-safe slug raises CompileError" do
      source = """
      defmodule BrokenPluginBadSlug#{unique()} do
        use Ezagent.Plugin
        @impl Ezagent.Plugin
        def plugin_info do
          %{slug: "Has Spaces", name: "n", description: "d", version: "1.0.0"}
        end
      end
      """

      err = assert_raise CompileError, fn -> Code.eval_string(source) end
      assert err.description =~ "slug"
    end

    test "a plugin with a blank name raises CompileError" do
      source = """
      defmodule BrokenPluginBlankName#{unique()} do
        use Ezagent.Plugin
        @impl Ezagent.Plugin
        def plugin_info do
          %{slug: "ok", name: "", description: "d", version: "1.0.0"}
        end
      end
      """

      err = assert_raise CompileError, fn -> Code.eval_string(source) end
      assert err.description =~ "name"
    end

    test "a well-formed plugin compiled at runtime does NOT raise" do
      source = """
      defmodule GoodRuntimePlugin#{unique()} do
        use Ezagent.Plugin
        @impl Ezagent.Plugin
        def plugin_info do
          %{slug: "good", name: "Good", description: "d", version: "1.0.0"}
        end
      end
      """

      assert {{:module, _mod, _bin, _}, _binding} = Code.eval_string(source)
    end
  end

  defp unique, do: System.unique_integer([:positive])
end
