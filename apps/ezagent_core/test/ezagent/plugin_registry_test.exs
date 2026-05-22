defmodule Ezagent.PluginRegistryTest do
  @moduledoc "Tests for `Ezagent.PluginRegistry` (SPEC §4)."

  use ExUnit.Case, async: false

  alias Ezagent.PluginRegistry

  # Build a throwaway `use Ezagent.Plugin` module with a given slug.
  defp make_plugin(slug) do
    module = String.to_atom("Elixir.PluginRegistryTest.Plugin_#{slug}")

    Module.create(
      module,
      quote do
        use Ezagent.Plugin
        @impl true
        def plugin_info do
          %{
            slug: unquote(slug),
            name: "P-#{unquote(slug)}",
            description: "d",
            version: "1.0.0"
          }
        end
      end,
      Macro.Env.location(__ENV__)
    )

    module
  end

  describe "register/1 + info/1 + list_all/0" do
    test "registers a plugin and looks it up by slug" do
      slug = "preg-a-#{System.unique_integer([:positive])}"
      module = make_plugin(slug)

      assert :ok = PluginRegistry.register(module)
      assert %{slug: ^slug, name: "P-" <> _} = PluginRegistry.info(slug)
      assert module in PluginRegistry.list_all()
    end

    test "info/1 returns nil for an unregistered slug" do
      assert PluginRegistry.info("preg-never-#{System.unique_integer([:positive])}") == nil
    end

    test "registering the same module twice is idempotent" do
      slug = "preg-dup-#{System.unique_integer([:positive])}"
      module = make_plugin(slug)

      assert :ok = PluginRegistry.register(module)
      assert :ok = PluginRegistry.register(module)
      assert module in PluginRegistry.list_all()
    end

    test "two different modules with the same slug raises" do
      slug = "preg-collide-#{System.unique_integer([:positive])}"

      mod_a = String.to_atom("Elixir.PluginRegistryTest.CollideA_#{slug}")
      mod_b = String.to_atom("Elixir.PluginRegistryTest.CollideB_#{slug}")

      for mod <- [mod_a, mod_b] do
        Module.create(
          mod,
          quote do
            use Ezagent.Plugin
            @impl true
            def plugin_info,
              do: %{slug: unquote(slug), name: "n", description: "d", version: "1.0.0"}
          end,
          Macro.Env.location(__ENV__)
        )
      end

      assert :ok = PluginRegistry.register(mod_a)

      err = assert_raise ArgumentError, fn -> PluginRegistry.register(mod_b) end
      assert err.message =~ slug
    end
  end
end
