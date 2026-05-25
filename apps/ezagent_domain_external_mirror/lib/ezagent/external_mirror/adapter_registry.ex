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
  Remove an `adapter_id` entry — used by `Ezagent.Plugin.boot/1`
  rollback when a later registration step fails (codex r1 HIGH-1).

  Idempotent; deleting a non-existent key is a no-op.

  This is intentionally `@doc false`-like — operator tools should
  never call this. The only legitimate caller is the boot-rollback
  path; future hot-uninstall (not in V1) would use it too.
  """
  @spec __delete__(adapter_id :: String.t()) :: :ok
  def __delete__(adapter_id) when is_binary(adapter_id) do
    :ets.delete(@table, adapter_id)
    :ok
  end

  @doc """
  Register an adapter module. Reads `adapter_id/0` from the module to
  derive the key (single source of truth — the module's own answer
  is authoritative).

  Idempotent for the same module re-registering. Raises
  `ArgumentError` on a different module claiming an already-registered
  `adapter_id` (per SPEC §5.2 structural-error rule).

  Also verifies the module implements `@behaviour
  Ezagent.ExternalMirror.Adapter` — moves enough validation into the
  API itself so a direct caller (bypassing `Ezagent.Plugin.boot/1`)
  still cannot install an unverified adapter. This is the
  defense-in-depth backstop to the source-scan compiler gate per
  codex r1 MEDIUM-1.

  ## Atomicity (codex r1 HIGH-2 fix)

  Uses `:ets.insert_new/2` (atomic) instead of `lookup` + `insert` —
  the previous read-then-write sequence let two concurrent plugin
  boots both see an empty table and overwrite each other. The new
  flow: try `insert_new`; if it fails, lookup to distinguish
  idempotent-same-module-re-register from a real duplicate.
  """
  @spec register(module()) :: :ok | {:ok, :already_present}
  def register(adapter_module) when is_atom(adapter_module) do
    assert_behaviour!(adapter_module)
    assert_required_callbacks!(adapter_module)
    adapter_id = adapter_module.adapter_id()

    if :ets.insert_new(@table, {adapter_id, adapter_module}) do
      # codex r2 HIGH-1 + HIGH-3 unified fix (2026-05-25): the moment
      # an adapter becomes observable in the registry, install its
      # cap subject + reconcile its persisted bindings.
      #
      # codex r5 HIGH-A fix (2026-05-25): the install REQUIRES the
      # paired BindingRegistry entry to exist too — `AdapterInstall`
      # uses `BindingRegistry.lookup!/1` indirectly via the Worker's
      # dispatch path, AND production `Plugin.publish_adapters!`
      # registers the binding AFTER the adapter. Pre-fix, firing
      # install/1 here unconditionally meant install ran with the
      # BindingRegistry empty for THIS adapter_id → workers couldn't
      # bind their publish target.
      #
      # The new contract: fire install ONLY when the BindingRegistry
      # also has an entry. If we're the first registry to land,
      # `BindingRegistry.register_module/2` will fire install when it
      # lands second. If we're second (binding registered first
      # somehow), we fire install now.
      :ok = Ezagent.ExternalMirror.AdapterInstall.maybe_install(adapter_module)
      :ok
    else
      # Race-safe second read — the entry exists (insert_new returned
      # false). Same module → idempotent `{:ok, :already_present}` so
      # the caller (Plugin.boot/1 rollback path) can distinguish
      # "we inserted it this attempt" from "it already existed";
      # different module → real duplicate, raise.
      #
      # codex r2 HIGH-2 fix: the prior `:ok` for both cases let the
      # rollback path delete pre-existing rows (the previous reduce
      # accumulator was lost on rescue). Returning a distinguishable
      # value forces the caller to track receipts properly.
      #
      # The `:already_present` branch does NOT re-run install/1 —
      # the prior `:ok` insert already triggered it. install/1 IS
      # idempotent (cap registration is idempotent; spawn is
      # idempotent) but skipping the redundant call keeps registry
      # re-registration cheap.
      case :ets.lookup(@table, adapter_id) do
        [{^adapter_id, ^adapter_module}] ->
          {:ok, :already_present}

        [{^adapter_id, existing_module}] ->
          raise ArgumentError,
                "AdapterRegistry: adapter_id #{inspect(adapter_id)} already " <>
                  "registered by #{inspect(existing_module)}; " <>
                  "#{inspect(adapter_module)} cannot re-use it. Two adapters " <>
                  "must not claim the same adapter_id (per SPEC §5.2)."
      end
    end
  end

  # codex r2 MEDIUM fix: Elixir's `@behaviour` enforces callback
  # presence as a compiler WARNING, not a runtime guarantee. A
  # plugin could ship a module with `@behaviour Adapter`,
  # `adapter_id/0`, and `binding_module/0` but no `display_name/0`
  # or `description/0` — register/1 would accept it, then
  # `list_adapters/0` would crash with UndefinedFunctionError when
  # the facade enumerates.
  #
  # Verify every PR-EM-1 required callback exports at the expected
  # arity BEFORE inserting. (PR-EM-2's added callbacks get checked
  # then.)
  defp assert_required_callbacks!(adapter_module) do
    # PR-EM-2 expands the required-callback set per SPEC §2.2. The
    # PR-EM-2 callbacks (`cap_subject/0`, `target_ownership_check/2`,
    # `event_to_payload/1`) are now required so a plugin that ships
    # only the PR-EM-1 stub set is rejected at registration time —
    # `list_adapters/0` + the Worker dispatch path can rely on the
    # full contract being present.
    required = [
      adapter_id: 0,
      display_name: 0,
      description: 0,
      binding_module: 0,
      # PR-EM-2 additions:
      cap_subject: 0,
      target_ownership_check: 2,
      event_to_payload: 1
    ]

    missing =
      Enum.reject(required, fn {fun, arity} ->
        function_exported?(adapter_module, fun, arity)
      end)

    unless missing == [] do
      missing_str =
        missing
        |> Enum.map(fn {f, a} -> "#{f}/#{a}" end)
        |> Enum.join(", ")

      raise ArgumentError,
            "AdapterRegistry: #{inspect(adapter_module)} declares " <>
              "@behaviour Ezagent.ExternalMirror.Adapter but does not " <>
              "implement: #{missing_str}. Elixir behaviours surface " <>
              "missing callbacks as compiler warnings — the registry " <>
              "checks at insert time so `list_adapters/0` can never crash " <>
              "(codex r2 MEDIUM)."
    end
  end

  # codex r1 MEDIUM-1 — even a direct caller (bypassing the source-
  # scan compiler gate) cannot install an adapter that doesn't
  # implement the contract. The check uses module attributes (loaded
  # at compile time), so it's cheap.
  defp assert_behaviour!(adapter_module) do
    behaviours =
      adapter_module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    unless Ezagent.ExternalMirror.Adapter in behaviours do
      raise ArgumentError,
            "AdapterRegistry: #{inspect(adapter_module)} does not implement " <>
              "@behaviour Ezagent.ExternalMirror.Adapter. Direct registry " <>
              "calls must still satisfy the plugin contract (SPEC §5.1)."
    end
  rescue
    UndefinedFunctionError ->
      reraise ArgumentError,
              [
                message:
                  "AdapterRegistry: #{inspect(adapter_module)} is not a " <>
                    "loadable module (or has no module_info/1)."
              ],
              __STACKTRACE__
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
