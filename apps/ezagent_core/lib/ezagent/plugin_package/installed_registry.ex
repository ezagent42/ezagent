defmodule Ezagent.PluginPackage.InstalledRegistry do
  @moduledoc """
  Runtime catalog of installed plugin PACKAGES — the unload bookkeeping
  counterpart to `Ezagent.PluginRegistry` (which tracks plugin MODULES).

  `PluginRegistry` answers "what plugins are booted"; THIS registry
  answers "what packages were hot-loaded, where they unpacked, and what
  must be reversed to unload them". An unload re-reads the recorded
  manifest (NOT the plugin module — which `:code.purge/1` may have
  removed) to drive registry unregister + asset unregister + seed retire.

  ## ETS layout

  `:ezagent_plugin_package_registry` `:set` table owned by
  `EzagentCore.EtsOwner`. Key = `slug`; value = `%{manifest, app,
  ebin, priv_dir, modules, seeded}`.
  """

  alias Ezagent.PluginPackage.Manifest

  @table :ezagent_plugin_package_registry

  @type record :: %{
          manifest: Manifest.t(),
          app: atom(),
          ebin: String.t(),
          priv_dir: String.t(),
          modules: [module()],
          seeded: [%{kind: atom(), name: String.t(), source_turn_id: String.t()}]
        }

  @doc "Return the ETS table name (used by `EzagentCore.EtsOwner`)."
  @spec table() :: atom()
  def table, do: @table

  @doc "Record an installed package. Overwrites a same-slug prior install."
  @spec put(record()) :: :ok
  def put(%{} = rec) do
    :ets.insert(@table, {rec.manifest.slug, rec})
    :ok
  end

  @doc "Look up an installed package by slug."
  @spec lookup(String.t()) :: {:ok, record()} | :error
  def lookup(slug) when is_binary(slug) do
    case :ets.lookup(@table, slug) do
      [{^slug, rec}] -> {:ok, rec}
      [] -> :error
    end
  end

  @doc "Remove an installed-package record (after unload). Idempotent."
  @spec delete(String.t()) :: :ok
  def delete(slug) when is_binary(slug) do
    :ets.delete(@table, slug)
    :ok
  end

  @doc "List every installed package record."
  @spec list_all() :: [record()]
  def list_all do
    @table |> :ets.tab2list() |> Enum.map(fn {_slug, rec} -> rec end)
  end
end
