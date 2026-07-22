defmodule Ezagent.PluginRegistry do
  @moduledoc """
  PluginRegistry — runtime catalog of installed plugins (SPEC §4).

  Each plugin self-registers during `Ezagent.Plugin.boot/1` (§5) — at
  runtime, NOT compile time, so there is no compile-order race (codex
  HIGH-3). Answers "what plugins are installed" — the data
  `plugins_live` will render plugin cards from (SPEC §6.2, PR-4).

  Bare ETS, same house style as `Ezagent.BehaviorRegistry` /
  `Ezagent.TemplateRegistry`. The table is owned by
  `EzagentCore.EtsOwner` (in its `@tables` list).

  ## ETS layout

  `:ezagent_plugin_registry` `:set` table. Key is the plugin's `slug`
  (the URL-safe identity from `plugin_info/0`); value is
  `{plugin_module, plugin_info}`. Keying on `slug` (not the module)
  means `info/1` is an O(1) lookup and a duplicate `slug` is caught.
  """

  @table :ezagent_plugin_registry

  @doc "Return the ETS table name (used by `EzagentCore.EtsOwner`)."
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Idempotently ensure the ETS table exists.

  At runtime the table is created by `EzagentCore.EtsOwner` and populated
  when each plugin runs `Ezagent.Plugin.boot/1`. This entry point lets
  build-time tooling that projects the plugin catalog WITHOUT booting the
  umbrella (e.g. `mix world.e2e.fixtures`, which runs under `app.config`)
  create the table and seed it via `register/1`. A no-op when `EtsOwner`
  already created the table. Mirrors `Ezagent.URI.SchemeRegistry.init/0`.
  """
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Register a plugin module. Reads `plugin_info/0` from the module to
  derive the `slug` key (single source of truth).

  Idempotent for the same module. A different module claiming an
  already-registered `slug` is a real bug — raises `ArgumentError`.
  """
  @spec register(module()) :: :ok
  def register(plugin_module) when is_atom(plugin_module) do
    info = plugin_module.plugin_info()
    slug = info.slug

    case :ets.lookup(@table, slug) do
      [{^slug, {^plugin_module, _info}}] ->
        :ok

      [{^slug, {existing_module, _info}}] ->
        raise ArgumentError,
              "PluginRegistry: slug #{inspect(slug)} already registered by " <>
                "#{inspect(existing_module)}; #{inspect(plugin_module)} cannot " <>
                "re-use it. Pick a unique slug in plugin_info/0."

      [] ->
        :ets.insert(@table, {slug, {plugin_module, info}})
        :ok
    end
  end

  @doc "List every registered plugin module."
  @spec list_all() :: [module()]
  def list_all do
    :ets.tab2list(@table)
    |> Enum.map(fn {_slug, {module, _info}} -> module end)
  end

  @doc """
  Look up a plugin's `plugin_info/0` map by `slug`. Returns `nil` if no
  plugin is registered under that slug.
  """
  @spec info(slug :: String.t()) :: Ezagent.Plugin.plugin_info() | nil
  def info(slug) when is_binary(slug) do
    case :ets.lookup(@table, slug) do
      [{^slug, {_module, info}}] -> info
      [] -> nil
    end
  end

  @doc """
  Unregister a plugin by slug — the reverse of `register/1`, used by
  the plugin-package UNLOAD path (handoff piece 4). Idempotent.
  """
  @spec unregister(String.t()) :: :ok
  def unregister(slug) when is_binary(slug) do
    :ets.delete(@table, slug)
    :ok
  end
end
