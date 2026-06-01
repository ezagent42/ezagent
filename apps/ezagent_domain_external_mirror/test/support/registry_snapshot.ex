defmodule Ezagent.ExternalMirror.TestSupport.RegistrySnapshot do
  @moduledoc """
  Snapshot + restore for the GLOBAL `AdapterRegistry` / `BindingRegistry`
  ETS tables.

  These registries are umbrella-wide named ETS singletons populated at
  plugin boot (the production `feishu` adapter, etc. land there). Several
  registry tests wipe them with `:ets.delete_all_objects/1` to assert on
  a clean slate — but if they don't put the production rows back, every
  subsequent test (including `async: true` ones running concurrently)
  sees an empty registry. That manifested as
  `EzagentPluginFeishu.Integration.PluginContractTest` getting `:error`
  from `AdapterRegistry.lookup("feishu")` under cross-app concurrency.

  `with_clean_registries/0` is a `setup`-friendly helper: it snapshots
  the current rows, wipes the tables for the test body, and registers an
  `on_exit` that restores the snapshot — returning the global singletons
  to their pre-test (production-boot) state.
  """

  alias Ezagent.ExternalMirror.{AdapterRegistry, BindingRegistry}

  @doc """
  Snapshot both registries, wipe them for the test body, and restore the
  snapshot on test exit. Call from a `setup` block.
  """
  @spec with_clean_registries() :: :ok
  def with_clean_registries do
    adapters = :ets.tab2list(AdapterRegistry.table())
    bindings = :ets.tab2list(BindingRegistry.table())

    :ets.delete_all_objects(AdapterRegistry.table())
    :ets.delete_all_objects(BindingRegistry.table())

    ExUnit.Callbacks.on_exit(fn ->
      # Restore to exactly the pre-test contents — drop anything the test
      # added, re-add anything it removed.
      :ets.delete_all_objects(AdapterRegistry.table())
      :ets.delete_all_objects(BindingRegistry.table())
      :ets.insert(AdapterRegistry.table(), adapters)
      :ets.insert(BindingRegistry.table(), bindings)
    end)

    :ok
  end
end
