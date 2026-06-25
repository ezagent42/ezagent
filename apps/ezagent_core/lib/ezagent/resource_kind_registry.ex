defmodule Ezagent.ResourceKindRegistry do
  @moduledoc """
  ResourceKindRegistry — declarative `resource type → kind_module` map.

  ## Why this exists

  `resource://<ws>/<type>/<name>` is a per-tenant scheme owned by
  core/domain (invariant 8 — a plugin may NEVER own a scheme-level
  `SpawnRegistry` dispatcher). A plugin that ships a *spawnable*
  resource Kind (e.g. the kanban board, `resource://<ws>/kanban/<name>`)
  therefore cannot register the `resource` scheme's spawn fn itself.

  Instead it **declares** its type → kind_module pair via
  `Ezagent.Plugin.resource_kinds/0`; `Ezagent.Plugin.boot/1` registers
  the pair here. A single domain-owned `resource` spawn dispatcher (in
  `EzagentDomainWorkspace.Application`) consults this table, switching on
  `Ezagent.URI.type/1` to find the backing Kind — exactly mirroring how
  the session domain's `entity` dispatcher resolves user/agent Kinds and
  consults `Ezagent.AgentFlavorRegistry` for agent flavors.

  This is the direct analogue of `Ezagent.AgentFlavorRegistry` for the
  `resource` scheme: the registry holds the type→Kind wiring, a
  domain dispatcher reads it, and the plugin only declares.

  Bare ETS, same house style as `Ezagent.AgentFlavorRegistry`. The table
  is owned by `EzagentCore.EtsOwner` (in its `@tables` list, P22 — a
  plugin author can't bypass it by lazy-init).

  ## ETS layout

  `:ezagent_resource_kind_registry` `:set` table. Key is the resource
  `type` string (the per-tenant URI's type segment — `"kanban"`); value
  is the backing Kind `module()`.
  """

  @table :ezagent_resource_kind_registry

  @doc "Return the ETS table name (used by `EzagentCore.EtsOwner`)."
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Register a `resource type → kind_module` mapping.

  Idempotent for an identical declaration. A different `kind_module`
  under an already-registered `type` is a real bug (two plugins
  claiming the same resource type) — raises `ArgumentError`.
  """
  @spec register(type :: String.t(), kind_module :: module()) :: :ok
  def register(type, kind_module) when is_binary(type) and is_atom(kind_module) do
    case :ets.lookup(@table, type) do
      [{^type, ^kind_module}] ->
        :ok

      [{^type, existing}] ->
        raise ArgumentError,
              "ResourceKindRegistry: resource type #{inspect(type)} already " <>
                "registered to #{inspect(existing)}; cannot re-register as " <>
                "#{inspect(kind_module)}. Two plugins must not claim the same " <>
                "resource type."

      [] ->
        :ets.insert(@table, {type, kind_module})
        :ok
    end
  end

  @doc """
  Look up the backing Kind module for a resource `type`.

  Returns `{:ok, kind_module}` or `:error`.
  """
  @spec lookup(type :: String.t()) :: {:ok, module()} | :error
  def lookup(type) when is_binary(type) do
    case :ets.lookup(@table, type) do
      [{^type, kind_module}] -> {:ok, kind_module}
      [] -> :error
    end
  end

  @doc "List every registered `{type, kind_module}` pair — for debug / admin."
  @spec list_all() :: [{String.t(), module()}]
  def list_all, do: :ets.tab2list(@table)
end
