defmodule Ezagent.BehaviorRegistry do
  @moduledoc """
  BehaviorRegistry — `{kind_module, action_atom}` → behavior_module.

  Resolves which `Ezagent.ActionSet` implementation handles a given Kind +
  action pair during `Ezagent.Invocation.dispatch/1`. Bare ETS (not stdlib
  Registry) because the key shape is a tuple and we don't need
  process monitoring.

  Owned by `EzagentActor.EtsOwner`. A flavor plugin's boot wires its
  Behaviors here — e.g. the py plugin registers
  `{Ezagent.Entity.Agent, :py_sync_result} → Ezagent.ActionSet.PyAgent`.

  ## Phase 1 scope

  Registration is one-shot at app boot. Phase 2+ may add dynamic
  registration paths (hot-loading plugins) — defer until needed.
  """

  @table :ezagent_behavior_registry

  def table, do: @table

  @doc false
  # WARN: direct calls FORBIDDEN in production code outside
  # `Ezagent.CapabilityRegistry`. Use `Ezagent.CapabilityRegistry.register/3`
  # — it ALSO updates the cap-subject discovery layer and detects
  # `{kind, action}` conflicts (raise vs silent last-writer-wins).
  #
  # Enforced by
  # `apps/ezagent_core/test/invariants/single_capability_registration_entry_test.exs`
  # — any production call site outside this allowlist will fail CI.
  # See SPEC `docs/superpowers/specs/2026-05-23-capability-registry.md` §2.
  @spec register(kind :: module(), action :: atom(), behavior :: module()) :: :ok
  def register(kind, action, behavior)
      when is_atom(kind) and is_atom(action) and is_atom(behavior) do
    :ets.insert(@table, {{kind, action}, behavior})
    :ok
  end

  @doc """
  Look up the behavior module for `{kind, action}`.

  Returns `{:ok, behavior_module}` or `:error`. Dispatch treats
  `:error` as "zero-match" → DLQ unroutable per invariant #7.
  """
  @spec lookup(kind :: module(), action :: atom()) :: {:ok, module()} | :error
  def lookup(kind, action) when is_atom(kind) and is_atom(action) do
    case :ets.lookup(@table, {kind, action}) do
      [{_, behavior}] ->
        {:ok, behavior}

      [] ->
        # #533 §3.4 — universal behaviors (e.g. Ezagent.ActionSet.Manage)
        # resolve for EVERY Kind by construction, with no per-Kind
        # registration. A per-Kind entry above always wins; this fallback
        # only fires on a miss.
        case Ezagent.UniversalBehaviors.behavior_for_action(action) do
          nil -> :error
          behavior -> {:ok, behavior}
        end
    end
  end

  @doc "List all `{{kind, action}, behavior}` triples — for debug/admin."
  @spec list_all() :: [{{module(), atom()}, module()}]
  def list_all, do: :ets.tab2list(@table)

  @doc false
  # WARN: direct calls FORBIDDEN in production code outside
  # `Ezagent.CapabilityRegistry.unregister/3`. Same allowlist as
  # `register/3` (enforced by the single_capability_registration_entry
  # invariant test). A plugin-package UNLOAD routes through
  # `CapabilityRegistry.unregister/3`, which calls this AND removes the
  # cap-subject row — keeping the two tables consistent on the reverse
  # path the way `register/3` does on the forward path.
  @spec unregister(kind :: module(), action :: atom()) :: :ok
  def unregister(kind, action) when is_atom(kind) and is_atom(action) do
    :ets.delete(@table, {kind, action})
    :ok
  end
end
