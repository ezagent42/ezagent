defmodule Ezagent.ExternalMirror.RegistryLock do
  @moduledoc """
  A per-`adapter_id` critical section shared by `AdapterRegistry.register/1` and
  `BindingRegistry.register_module/2` (P3-1 codex r4 HIGH).

  The "a `:pull` adapter NEVER has a BindingRegistry row" invariant spans TWO
  ETS tables. Each register path does an opposite-registry check then an
  `:ets.insert_new/2`, but those two steps are not atomic ACROSS the registries:
  a concurrent interleaving could have the pull-adapter path see no binding and
  the binding path see no adapter, then both insert — landing exactly the
  forbidden state. (Not reachable via the serial `Plugin.boot/1` path, which
  never registers a binding for a pull adapter; this guards direct/concurrent
  registration.)

  `with_lock/2` serializes the check+insert for a given `adapter_id` across BOTH
  register paths via a node-local `:global.trans/3` keyed by the adapter_id, so
  whichever side acquires the lock first commits its insert before the other
  side runs its check — the second side then sees the first's row and rejects.
  """

  @doc """
  Run `fun` while holding the node-local registration lock for `adapter_id`.
  Returns `fun`'s value. Exceptions raised inside `fun` propagate (the lock is
  released either way).
  """
  @spec with_lock(String.t(), (-> result)) :: result when result: var
  def with_lock(adapter_id, fun) when is_binary(adapter_id) and is_function(fun, 0) do
    lock_id = {{:ezagent_external_mirror_registry, adapter_id}, self()}
    :global.trans(lock_id, fun, [node()])
  end
end
