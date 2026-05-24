defmodule Ezagent.ExternalMirror.AdapterRegistry do
  @moduledoc """
  AdapterRegistry — single source of truth for "which adapters exist"
  (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §5.2).

  Populated at plugin boot from each plugin's `adapters/0`. Read by:

  - `Ezagent.ExternalMirror.list_adapters/0` (admin LV picker)
  - the Worker Kind's `:publish` dispatch — `lookup!/1` against the
    `adapter_id` carried in the binding slice (PR-EM-2 wires this)

  ## Why ETS, owned by EtsOwner

  Per **P22** (core/Domain owns reliability primitives, plugin
  authors cannot bypass): the table is created BEFORE any plugin
  boots, via `EzagentCore.EtsOwner`'s `@tables` list (NOT lazy-init).
  Same house style as `Ezagent.PluginRegistry` /
  `Ezagent.AgentFlavorRegistry` / `Ezagent.TemplateRegistry`.

  ## Failure semantics (SPEC §5.2)

  - `lookup!/1` raises on missing — structural error, fail loud. A
    binding referring to an unloaded adapter is a plugin bug; the
    Worker crashes + restarts + ultimately surfaces the broken
    plugin (no silent "degrade to nil" path, per the let-it-crash
    + no-defaults rule).
  - `register/1` raises on duplicate `adapter_id` from a different
    module — two plugins claiming the same `adapter_id` is a
    structural error (operators cannot tell which adapter would
    handle `bind`). Idempotent for the SAME module re-registering.

  ## ETS layout

  `:ezagent_external_mirror_adapter_registry` `:set` table. Key is
  the `adapter_id` string from `adapter_module.adapter_id()`; value
  is `adapter_module`.
  """

  @table :ezagent_external_mirror_adapter_registry

  @doc "Return the ETS table name (used by `EzagentCore.EtsOwner`)."
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Register an adapter module. Reads `adapter_id/0` from the module to
  derive the key (single source of truth — the module's own answer
  is authoritative).

  Idempotent for the same module re-registering. Raises
  `ArgumentError` on a different module claiming an already-registered
  `adapter_id` (per SPEC §5.2 structural-error rule).
  """
  @spec register(module()) :: :ok
  def register(adapter_module) when is_atom(adapter_module) do
    adapter_id = adapter_module.adapter_id()

    case :ets.lookup(@table, adapter_id) do
      [{^adapter_id, ^adapter_module}] ->
        :ok

      [{^adapter_id, existing_module}] ->
        raise ArgumentError,
              "AdapterRegistry: adapter_id #{inspect(adapter_id)} already " <>
                "registered by #{inspect(existing_module)}; " <>
                "#{inspect(adapter_module)} cannot re-use it. Two adapters " <>
                "must not claim the same adapter_id (per SPEC §5.2)."

      [] ->
        :ets.insert(@table, {adapter_id, adapter_module})
        :ok
    end
  end

  @doc """
  Look up an adapter module by `adapter_id`. Returns `{:ok, module}`
  or `:error`.

  Use this when "missing" is a legitimate outcome (e.g. admin LV
  rendering a list and filtering by caller cap). For the Worker
  dispatch path use `lookup!/1` — a missing adapter there is a
  structural bug.
  """
  @spec lookup(adapter_id :: String.t()) :: {:ok, module()} | :error
  def lookup(adapter_id) when is_binary(adapter_id) do
    case :ets.lookup(@table, adapter_id) do
      [{^adapter_id, module}] -> {:ok, module}
      [] -> :error
    end
  end

  @doc """
  Look up an adapter module by `adapter_id`. Raises `KeyError` on
  missing — structural error, per SPEC §5.2.

  Used by Worker `:publish` dispatch (PR-EM-2): the binding slice
  carries an `adapter_id` that must resolve, or the system has a
  plugin contract violation (binding outlived adapter — impossible
  if PluginRegistry is sane).
  """
  @spec lookup!(adapter_id :: String.t()) :: module()
  def lookup!(adapter_id) when is_binary(adapter_id) do
    case :ets.lookup(@table, adapter_id) do
      [{^adapter_id, module}] ->
        module

      [] ->
        raise KeyError,
          key: adapter_id,
          term: __MODULE__,
          message:
            "AdapterRegistry: no adapter registered with id #{inspect(adapter_id)}. " <>
              "This is a structural error per SPEC §5.2 — a binding referenced " <>
              "an adapter that never loaded (plugin contract violation)."
    end
  end

  @doc """
  List every registered adapter as the operator-facing shape returned
  by `Ezagent.ExternalMirror.list_adapters/0` (per SPEC §4.4):

      [%{id: String.t(), module: module(),
         display_name: String.t(), description: String.t()}]

  The `module` field is included so callers (Worker dispatch, admin
  tooling) can avoid a second `lookup!/1` round-trip; the facade's
  public `list_adapters/0` strips it to match the SPEC §4.4 shape.
  """
  @spec list() :: [
          %{
            id: String.t(),
            module: module(),
            display_name: String.t(),
            description: String.t()
          }
        ]
  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {id, module} ->
      %{
        id: id,
        module: module,
        display_name: module.display_name(),
        description: module.description()
      }
    end)
  end
end
