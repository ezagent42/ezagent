defmodule Ezagent.ExternalMirror.PluginContractTest do
  @moduledoc """
  Plugin contract integration tests (PR-EM-1 acceptance test 3 + 7).

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §5.1 + §9 PR-EM-1.

  Pins:
  - A fixture plugin declaring valid `adapters/0` wires BOTH
    registries on `Ezagent.Plugin.boot/1`'s `publish` phase.
  - The Grill-5 runtime guard (`assert_adapter_decl!`) catches every
    failure mode the compiler gate catches — defense-in-depth for a
    hot-installed plugin that bypassed the build.
  - **Invariant test 7**: every `(adapter, binding)` pair landed in
    BOTH registries — cross-module integrity at boot. Catches a
    future refactor that registers ONE side but not the other.
  """

  use ExUnit.Case, async: false

  alias Ezagent.ExternalMirror.{AdapterRegistry, BindingRegistry}
  alias Ezagent.ExternalMirror.TestSupport.{MockAdapter, MockBinding}

  setup do
    :ets.delete_all_objects(AdapterRegistry.table())
    :ets.delete_all_objects(BindingRegistry.table())
    :ok
  end

  describe "Ezagent.Plugin.boot/1 publishes adapters/0" do
    test "wires AdapterRegistry + BindingRegistry for a valid pair" do
      plugin = define_plugin("conforming_v1", [{MockAdapter, MockBinding}])

      assert {:ok, _sup_pid} = Ezagent.Plugin.boot(plugin)

      # AdapterRegistry: id → module
      assert {:ok, MockAdapter} = AdapterRegistry.lookup("mock_em")

      # BindingRegistry: id → binding_module (Grill-5 1:1 reverse-lookup)
      assert {:ok, MockBinding} = BindingRegistry.lookup("mock_em")
    end

    test "a plugin with no adapters/0 declaration leaves both registries empty" do
      plugin = define_plugin("empty_v1", [])

      assert {:ok, _sup_pid} = Ezagent.Plugin.boot(plugin)

      assert AdapterRegistry.list() == []
      assert BindingRegistry.list_all() == []
    end
  end

  describe "Ezagent.Plugin.boot/1 Grill-5 runtime defense-in-depth" do
    # The :ezagent_plugin_check compiler is the primary gate; runtime
    # `assert_adapter_decl!` is the backstop. These tests exercise the
    # runtime path directly.

    test "rejects a SINGLE module implementing both behaviours (Grill-5 e)" do
      # The Dual module isn't a real adapter — but the runtime guard
      # only needs to detect adapter == binding, so a raw module ref
      # suffices.
      dual = build_dual_module()
      plugin = define_plugin("dual_v1", [{dual, dual}])

      err = assert_raise ArgumentError, fn -> Ezagent.Plugin.boot(plugin) end
      assert err.message =~ "DIFFERENT modules"
      assert err.message =~ "Grill-5"
    end

    test "rejects a (adapter, binding) where adapter.binding_module() != binding (Grill-5 c)" do
      # MockAdapter says its binding_module/0 is MockBinding, but the
      # plugin pairs it with OtherBinding.
      alias Ezagent.ExternalMirror.TestSupport.OtherBinding

      plugin = define_plugin("mismatch_v1", [{MockAdapter, OtherBinding}])

      err = assert_raise ArgumentError, fn -> Ezagent.Plugin.boot(plugin) end
      assert err.message =~ "binding_module"
      assert err.message =~ "Grill-5"
    end

    test "rejects a non-tuple entry as malformed" do
      plugin = define_plugin("malformed_v1", [:not_a_tuple])

      err = assert_raise ArgumentError, fn -> Ezagent.Plugin.boot(plugin) end
      assert err.message =~ "malformed adapters/0 entry"
    end
  end

  describe "invariant 7: cross-module integrity at boot" do
    test "every adapter registered also has its paired binding registered" do
      # The invariant: post-boot, for every entry in AdapterRegistry,
      # BindingRegistry must contain a matching adapter_id key. Catches
      # a future refactor that registers ONE side but not the other.
      plugin = define_plugin("integrity_v1", [{MockAdapter, MockBinding}])

      assert {:ok, _} = Ezagent.Plugin.boot(plugin)

      adapter_ids =
        AdapterRegistry.list()
        |> Enum.map(& &1.id)
        |> MapSet.new()

      binding_ids =
        BindingRegistry.list_all()
        |> Enum.map(fn {id, _mod} -> id end)
        |> MapSet.new()

      assert MapSet.equal?(adapter_ids, binding_ids),
             "adapter_ids #{inspect(adapter_ids)} != binding_ids #{inspect(binding_ids)} — " <>
               "boot wiring registered ONE side but not the other (Grill-5 violation)"
    end
  end

  # --- helpers ------------------------------------------------------

  # Build a throwaway `use Ezagent.Plugin` module that declares the
  # given `adapters/0` payload. Same pattern as plugin_registry_test.
  defp define_plugin(slug, adapters_payload) do
    module = String.to_atom("Elixir.Ezagent.ExternalMirror.PluginContractTest.Plugin_#{slug}")

    Module.create(
      module,
      quote do
        use Ezagent.Plugin

        @impl true
        def plugin_info do
          %{
            slug: unquote(slug),
            name: "P-#{unquote(slug)}",
            description: "test fixture plugin",
            version: "0.1.0"
          }
        end

        @impl true
        def adapters, do: unquote(Macro.escape(adapters_payload))
      end,
      Macro.Env.location(__ENV__)
    )

    module
  end

  # Build a one-off module that implements BOTH Adapter and Binding
  # behaviours — for the Grill-5 (e) runtime-defense test.
  defp build_dual_module do
    name =
      String.to_atom(
        "Elixir.Ezagent.ExternalMirror.PluginContractTest.Dual_#{System.unique_integer([:positive])}"
      )

    Module.create(
      name,
      quote do
        @behaviour Ezagent.ExternalMirror.Adapter
        @behaviour Ezagent.ExternalMirror.Binding

        @impl Ezagent.ExternalMirror.Adapter
        def adapter_id, do: "dual"

        @impl Ezagent.ExternalMirror.Adapter
        def display_name, do: "Dual"

        @impl Ezagent.ExternalMirror.Adapter
        def description, do: "illegal"

        @impl Ezagent.ExternalMirror.Adapter
        def binding_module, do: __MODULE__

        @impl Ezagent.ExternalMirror.Binding
        def adapter_module, do: __MODULE__
      end,
      Macro.Env.location(__ENV__)
    )

    name
  end
end
