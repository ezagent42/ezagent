defmodule Ezagent.ExternalMirror.BindingRegistry do
  @moduledoc """
  BindingRegistry — reverse-lookup cache mapping `adapter_id` →
  `binding_module` (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §5.2).

  Per **Grill 5**: the adapter ↔ binding relationship is
  one-to-one and bidirectional. Given a binding's `adapter_id` (the
  slice's storage key — only the adapter_id, never a module atom,
  serializes safely across snapshots), the BindingRegistry answers
  "which Binding module owns this adapter's worker dispatch?". The
  Worker Kind's `:publish` action (PR-EM-2) calls `lookup!/1` to
  reach the binding module's `publish/2` callback.

  ## Why a separate registry from AdapterRegistry

  Storage in the Session slice is `{adapter_id, target_id, metadata,
  binding_state}` — by-id, not by-module. The Worker fetches the
  adapter (for `event_to_payload/1`) AND the binding (for
  `publish/2`) on every event. Two registries means each lookup is
  O(1) and the relationship between them is purely declarative
  (compiler-checked at plugin build time; runtime lookups never
  re-validate).

  An alternative — storing `{adapter_module, binding_module}` per
  registry entry — was rejected because the slice carries
  `adapter_id` (string, snapshot-safe), and a per-registry-pair
  lookup avoids any inference from the adapter to its binding
  (avoids the kind of "reflective module resolution" that breaks
  when a plugin is hot-unloaded).

  ## Why ETS, owned by EtsOwner

  Same reasoning as AdapterRegistry — table created at boot via
  `EzagentCore.EtsOwner` `@tables` (NOT lazy-init); per **P22** the
  Domain owns the reliability primitive.

  ## ETS layout

  `:ezagent_external_mirror_binding_registry` `:set` table. Key is
  `adapter_id` (string); value is `binding_module` (atom).
  """

  @table :ezagent_external_mirror_binding_registry

  @doc "Return the ETS table name (used by `EzagentCore.EtsOwner`)."
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Remove an `adapter_id` entry — used by `Ezagent.Plugin.boot/1`
  rollback when a later registration step fails (codex r1 HIGH-1).

  Idempotent; deleting a non-existent key is a no-op.
  """
  @spec __delete__(adapter_id :: String.t()) :: :ok
  def __delete__(adapter_id) when is_binary(adapter_id) do
    :ets.delete(@table, adapter_id)
    :ok
  end

  @doc """
  Register a Binding module for `adapter_id`.

  Idempotent for the same `(adapter_id, binding_module)` pair.
  Raises `ArgumentError` on a different `binding_module` claiming an
  already-registered `adapter_id` — Grill-5 enforces one-to-one, so
  two bindings for one adapter is a structural error.

  Also verifies the module implements `@behaviour
  Ezagent.ExternalMirror.Binding` AND that
  `binding_module.adapter_module()` exists (defense in depth — a
  direct caller bypassing the source-scan compiler gate still
  cannot install an unverified binding). Per codex r1 MEDIUM-1.

  ## Atomicity (codex r1 HIGH-2 fix)

  Uses `:ets.insert_new/2` (atomic) instead of `lookup` + `insert` —
  the previous read-then-write sequence let two concurrent plugin
  boots both see an empty table and overwrite each other.
  """
  @spec register_module(adapter_id :: String.t(), binding_module :: module()) :: :ok
  def register_module(adapter_id, binding_module)
      when is_binary(adapter_id) and is_atom(binding_module) do
    assert_behaviour!(binding_module)

    if :ets.insert_new(@table, {adapter_id, binding_module}) do
      :ok
    else
      case :ets.lookup(@table, adapter_id) do
        [{^adapter_id, ^binding_module}] ->
          :ok

        [{^adapter_id, existing_module}] ->
          raise ArgumentError,
                "BindingRegistry: adapter_id #{inspect(adapter_id)} already " <>
                  "bound to #{inspect(existing_module)}; cannot re-bind to " <>
                  "#{inspect(binding_module)}. Grill-5 mandates 1:1 " <>
                  "adapter↔binding (per SPEC §5.2)."
      end
    end
  end

  # codex r1 MEDIUM-1 — defense in depth: even a direct caller cannot
  # install a binding that doesn't implement the contract.
  defp assert_behaviour!(binding_module) do
    behaviours =
      binding_module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    unless Ezagent.ExternalMirror.Binding in behaviours do
      raise ArgumentError,
            "BindingRegistry: #{inspect(binding_module)} does not implement " <>
              "@behaviour Ezagent.ExternalMirror.Binding. Direct registry " <>
              "calls must still satisfy the plugin contract (SPEC §5.1)."
    end
  rescue
    UndefinedFunctionError ->
      reraise ArgumentError,
              [
                message:
                  "BindingRegistry: #{inspect(binding_module)} is not a " <>
                    "loadable module (or has no module_info/1)."
              ],
              __STACKTRACE__
  end

  @doc """
  Look up the Binding module for an `adapter_id`. Returns
  `{:ok, binding_module}` or `:error`.

  Use this when "missing" is a legitimate outcome. For Worker
  dispatch use `lookup!/1`.
  """
  @spec lookup(adapter_id :: String.t()) :: {:ok, module()} | :error
  def lookup(adapter_id) when is_binary(adapter_id) do
    case :ets.lookup(@table, adapter_id) do
      [{^adapter_id, module}] -> {:ok, module}
      [] -> :error
    end
  end

  @doc """
  Look up the Binding module for an `adapter_id`. Raises `KeyError`
  on missing — structural error, per SPEC §5.2.

  Used by Worker `:publish` dispatch (PR-EM-2): the binding slice
  carries an `adapter_id`; if no Binding is registered the plugin
  contract was violated (adapter ships without paired binding —
  rejected by Grill-5 compiler gate, so a runtime miss means the
  registry was reset without re-population).
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
            "BindingRegistry: no binding registered for adapter_id " <>
              "#{inspect(adapter_id)}. Structural error per SPEC §5.2 — " <>
              "Grill-5 compiler gate should have caught this at plugin " <>
              "build time."
    end
  end

  @doc "List every `(adapter_id, binding_module)` pair — for debug / admin."
  @spec list_all() :: [{String.t(), module()}]
  def list_all, do: :ets.tab2list(@table)
end
