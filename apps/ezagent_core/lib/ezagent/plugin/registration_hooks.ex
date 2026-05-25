defmodule Ezagent.Plugin.RegistrationHooks do
  @moduledoc """
  `Ezagent.Plugin.RegistrationHooks` — backing GenServer for
  `Ezagent.Plugin.publish_after_all_registered/2`.

  Per SPEC `docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md`
  §5: the "wait until all registries have entries for the same key before
  firing a hook" pattern, lifted from
  `Ezagent.ExternalMirror.AdapterInstall`'s symmetric `maybe_install*/1`
  pair to a core primitive so future plugin extensions with
  cross-registry dependencies can reuse it without re-inventing.

  ## Why a `:protected` ETS

  The hook table holds zero-arity closures + `{registry_module, key}` lists.
  Only this GenServer's owner pid is permitted to write — public ETS would
  let any caller insert / mutate hooks (auth bypass surface for any future
  consumer whose hook does sensitive work). Reads stay direct via
  `:ets.lookup/2` from `notify_subscribers/2` for the O(1) hot path; the
  fire-and-delete happens through the GenServer for atomicity.

  ## Idempotency contract

  - `publish_after_all_registered/2`: if all `registries` already have
    entries for their keys at call time, the hook fires **synchronously**
    before this function returns. Otherwise the hook is registered for
    later firing. Either way the function returns `:ok`.
  - `notify_subscribers/2`: idempotent. Each `(registry_module, key)`
    notification scans pending hooks; for each whose `registries` list
    now resolves (all entries present), fires once + deletes from table.
    Calling twice on the same key never fires the same hook twice — the
    delete-on-fire serializes through this GenServer's mailbox.
  """

  use GenServer

  @table :ezagent_plugin_registration_hooks
  @hook_id_key :__hook_id_counter__

  # ----- Public API ---------------------------------------------------------

  @doc "Start the RegistrationHooks GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register `hook_fn` to fire ONCE when every `(registry_module, key)`
  in `registries` has a lookup hit.

  If all registries already have entries at call time, fires
  synchronously before returning. Otherwise the hook is stored;
  `notify_subscribers/2` triggers it when the last missing entry lands.
  """
  @spec publish_after_all_registered(
          [{module(), term()}],
          (-> :ok)
        ) :: :ok
  def publish_after_all_registered(registries, hook_fn)
      when is_list(registries) and registries != [] and is_function(hook_fn, 0) do
    GenServer.call(__MODULE__, {:publish_after_all_registered, registries, hook_fn})
  end

  @doc """
  Notify the hooks GenServer that `(registry_module, key)` was just
  inserted. Fires every hook whose `registries` list is now fully
  resolved.

  Called from `*Registry.register*/n` success paths. Fire-and-forget
  (`GenServer.cast`) so the registry's success path is never blocked.
  """
  @spec notify_subscribers(module(), term()) :: :ok
  def notify_subscribers(registry_module, key) when is_atom(registry_module) do
    GenServer.cast(__MODULE__, {:notify, registry_module, key})
  end

  @doc false
  # Test-only — clear all pending hooks. Used by the primitive test
  # to reset between cases.
  @spec __clear_all__() :: :ok
  def __clear_all__ do
    GenServer.call(__MODULE__, :clear_all)
  end

  # ----- GenServer callbacks ------------------------------------------------

  @impl GenServer
  def init(_opts) do
    tid =
      :ets.new(@table, [
        :set,
        :protected,
        :named_table,
        read_concurrency: true
      ])

    :ets.insert(tid, {@hook_id_key, 0})
    {:ok, %{table: tid}}
  end

  @impl GenServer
  def handle_call({:publish_after_all_registered, registries, hook_fn}, _from, state) do
    if all_registered?(registries) do
      # Fire synchronously inside the GenServer so a registry-completion
      # notification arriving concurrently with our caller's call cannot
      # double-fire. The caller's process pays the hook latency; that's
      # the contract.
      _ = safe_fire(hook_fn)
      {:reply, :ok, state}
    else
      hook_id = next_hook_id(state.table)
      :ets.insert(state.table, {hook_id, registries, hook_fn})
      {:reply, :ok, state}
    end
  end

  def handle_call(:clear_all, _from, state) do
    # Preserve the counter row so hook IDs stay monotonic across clears.
    counter = :ets.lookup_element(state.table, @hook_id_key, 2)
    :ets.delete_all_objects(state.table)
    :ets.insert(state.table, {@hook_id_key, counter})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast({:notify, registry_module, key}, state) do
    # Walk every pending hook (non-counter row) and fire those whose
    # registries list is now satisfied. Fire-and-delete is atomic because
    # this GenServer is single-process — no concurrent fire of the same
    # hook is possible.
    pending = :ets.match(state.table, {:"$1", :"$2", :"$3"})

    Enum.each(pending, fn [hook_id, registries, hook_fn] ->
      # Quick filter: only consider hooks that subscribed to this
      # `(registry_module, key)` pair. Avoids re-checking unrelated hooks
      # on every notify.
      if Enum.any?(registries, fn {rm, k} -> rm == registry_module and k == key end) and
           all_registered?(registries) do
        :ets.delete(state.table, hook_id)
        _ = safe_fire(hook_fn)
      end
    end)

    {:noreply, state}
  end

  # ----- internals ----------------------------------------------------------

  defp all_registered?(registries) do
    Enum.all?(registries, fn {registry_module, key} ->
      case registry_module.lookup(key) do
        {:ok, _} -> true
        :error -> false
      end
    end)
  end

  defp next_hook_id(table) do
    :ets.update_counter(table, @hook_id_key, {2, 1})
  end

  # Hook fns are user-supplied; we don't want a buggy hook to bring down
  # the GenServer (which would lose ALL pending hooks). Wrap each fire in
  # try/rescue + log; the SPEC §5.3 contract requires idempotent hooks
  # but enforces nothing — a misbehaving hook is observable via log,
  # not via crash propagation.
  defp safe_fire(hook_fn) do
    hook_fn.()
  rescue
    err ->
      require Logger

      Logger.error(
        "Ezagent.Plugin.RegistrationHooks: hook fn raised — " <>
          "#{inspect(err)}; stacktrace: #{inspect(__STACKTRACE__)}"
      )

      :error
  end
end
