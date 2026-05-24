defmodule Ezagent.Kind.Server do
  @moduledoc """
  Shared GenServer that hosts every Kind instance.

  Per DECISIONS P1-D2 / Decision #84 (path B in ARCHITECTURE.md §5.7.4),
  Phase 1 uses **one** GenServer module for all Kinds. Each instance is
  parameterised by its `{kind_module, args}` pair at `start_link/1`.
  Plugin authors cannot bypass the register → subscribe → announce_ready
  lifecycle because they never write `init/1` themselves — this module
  is the only `def init/1` in the codebase (invariant #2).

  ## State shape

  ```
  %{
    kind: module(),           # the Kind module (e.g. Ezagent.Entity.Echo)
    uri:  URI.t(),            # this instance's URI
    state: %{atom() => map()} # per-Behavior slices, keyed by behavior.state_slice()
  }
  ```

  ## Lifecycle (Appendix A precondition)

  1. `init/1`:
     - build initial per-Behavior slices via `init_slice/1`
     - put_new into `KindRegistry` (crash on duplicate)
     - mark `:not_ready` in `ReadyGate`
     - hand off to `handle_continue(:announce_ready, ...)`
  2. `handle_continue(:announce_ready, ...)`:
     - mark `:ready` in `ReadyGate`
     - flush any buffered `:cast` invocations via `PendingDelivery.flush`
     - both pre-ready writes and the window-leak class of bugs are
       absorbed by ReadyGate + PendingDelivery (see ARCHITECTURE §5.7.4)
  3. `handle_call(:ezagent_dispatch, ...)` / `handle_cast(:ezagent_dispatch, ...)`:
     - delegate to `Ezagent.Kind.Runtime.handle_dispatch/3` which runs
       Appendix A steps 5-10 (BehaviorRegistry → authz stub → invoke →
       slice update → telemetry)

  ## Why `:trap_exit`

  Borrowed from old esr `Ezagent.Entity.Server` (SPEC borrow #4): we want
  graceful `terminate/2` so the GenServer can emit a final telemetry
  event before going down. Phase 4-completion PR 2 wired
  snapshot-on-shutdown for Kinds declaring `:on_terminate` persistence.
  """

  use GenServer

  @doc """
  Start a Kind instance for `{kind_module, args}`.

  `args` MUST include `:uri` (the instance URI). Other keys are
  forwarded to each Behavior's `init_slice/1`.
  """
  @spec start_link({module(), map()}) :: GenServer.on_start()
  def start_link({kind_module, args}) when is_atom(kind_module) and is_map(args) do
    GenServer.start_link(__MODULE__, {kind_module, args})
  end

  @impl true
  def init({kind_module, args}) do
    Process.flag(:trap_exit, true)

    uri = Map.fetch!(args, :uri)
    uri_str = URI.to_string(uri)

    state = %{
      kind: kind_module,
      uri: uri,
      state: Ezagent.Kind.Snapshot.load_or_init(uri, kind_module, args)
    }

    case Ezagent.KindRegistry.put_new(uri_str, self()) do
      :ok ->
        :ok = Ezagent.ReadyGate.put(uri_str, :not_ready)
        schedule_periodic_snapshot(kind_module)
        {:ok, state, {:continue, :announce_ready}}

      {:error, {:already_registered, _other_pid}} ->
        # Let-it-crash — duplicate spawn is a bug at the caller layer.
        {:stop, {:already_registered, uri_str}}
    end
  end

  defp schedule_periodic_snapshot(kind_module) do
    case kind_module.persistence() do
      {:snapshot, :periodic, ms} when is_integer(ms) and ms > 0 ->
        Process.send_after(self(), :snapshot_tick, ms)
        :ok

      _ ->
        :ok
    end
  end

  @impl true
  def handle_continue(:announce_ready, %{uri: uri} = state) do
    uri_str = URI.to_string(uri)
    :ok = Ezagent.ReadyGate.mark_ready(uri_str)

    # Drain any messages that arrived during the register→ready window.
    # They were buffered by `Ezagent.Invocation.dispatch/1` via PendingDelivery.
    uri_str
    |> Ezagent.PendingDelivery.flush()
    |> Enum.each(fn buffered_inv ->
      GenServer.cast(self(), {:ezagent_dispatch, buffered_inv})
    end)

    {:noreply, state}
  end

  # codex round-10 HIGH — `Ezagent.Kind.terminate/1` needs the Kind
  # module of a LIVE process to resolve its owning `DynamicSupervisor`
  # (`kind_module.supervisor/0`). The caller (a Tier-3 plugin Template
  # Class undoing its own partial spawn) only has the URI / pid — it
  # must NOT name a Tier-2 supervisor constant. This synchronous query
  # lets a Tier-1 helper resolve the supervisor without that coupling.
  @impl true
  def handle_call(:ezagent_kind_module, _from, %{kind: kind_module} = state) do
    {:reply, {:ok, kind_module}, state}
  end

  @impl true
  def handle_call({:ezagent_dispatch, %Ezagent.Invocation{} = inv}, _from, state) do
    case Ezagent.Kind.Runtime.handle_dispatch(inv, state.state, state.kind, state.uri) do
      {:ok, new_slice_state, result, slice_change_event} ->
        commit_and_notify(state, new_slice_state, slice_change_event)

        reply = if is_nil(result), do: :ok, else: {:ok, result}
        {:reply, reply, %{state | state: new_slice_state}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_cast({:ezagent_dispatch, %Ezagent.Invocation{} = inv}, state) do
    case Ezagent.Kind.Runtime.handle_dispatch(inv, state.state, state.kind, state.uri) do
      {:ok, new_slice_state, result, slice_change_event} ->
        commit_and_notify(state, new_slice_state, slice_change_event)

        # cast still replies via ctx.reply if set (e.g. caller_inbox).
        Ezagent.Invocation.reply(inv.ctx, {:ok, result})
        {:noreply, %{state | state: new_slice_state}}

      {:error, reason} ->
        Ezagent.Invocation.reply(inv.ctx, {:error, reason})
        {:noreply, state}
    end
  end

  # Commit-then-notify ordering (codex PR-N1 round-2 MEDIUM +
  # round-3 HIGH-1 fix):
  # 1. `Snapshot.commit/4` returns the STRICT outcome:
  #    `:ok` = durably persisted; `:not_durable` = policy doesn't
  #    require a durable write here (ephemeral / unchanged / periodic);
  #    `{:error, _}` = durable policy attempted + failed
  # 2. Emit ONLY on `:ok` or `:not_durable`:
  #    - `:ok` — slice survives restart, subscribers safe to act
  #    - `:not_durable` — by-design no durability promise (e.g. an
  #      `:ephemeral` Kind); in-memory slice IS the truth so notify
  #      is correct
  #    - `{:error, _}` — GenServer holds state that won't survive
  #      crash. Ghost-notify would tell LV "Alice → Bob" but a
  #      restart re-loads "Alice → Carol". Suppress emit. `commit/4`
  #      has already logged + emitted `:failed` telemetry.
  defp commit_and_notify(state, new_slice_state, slice_change_event) do
    commit_result =
      Ezagent.Kind.Snapshot.commit(state.uri, state.kind, state.state, new_slice_state)

    if slice_change_event && commit_result in [:ok, :not_durable] do
      Ezagent.SliceChange.emit(slice_change_event)
    end

    :ok
  end

  # Unified forwarder: any GenServer message a Kind's Behaviors might want
  # to react to (currently only `:DOWN` from Process.monitor; Phase 3+ may
  # add timer ticks etc) routes through `handle_kind_message/3` on each
  # Behavior that exports it. Behaviors that ignore the message return
  # their slice unchanged.
  #
  # The optional hook signature `handle_kind_message(message, slice, ctx)`:
  #  - `message`: the raw GenServer message (e.g. `{:DOWN, ref, ..., reason}`)
  #  - `slice`: this Behavior's slice
  #  - `ctx`: %{kind_module:, self_uri:} so Behaviors can route based on Kind
  #
  # Returns `{:ok, new_slice}` or `:ignore` (slice unchanged). This lets
  # multi-Behavior Kinds share one mailbox without each Behavior shadowing
  # everything (P2-D2 K-path principle: one Behavior, multiple Kinds —
  # not a Kind-wide message bus).
  @impl true
  def handle_info(:snapshot_tick, %{kind: kind_module, uri: uri, state: slice_state} = wrapper) do
    # Phase 4-completion: periodic strategy — write via Writer (async)
    # then re-schedule. If Writer isn't running (e.g. test envs without
    # full sup tree), fall back to sync save_now to remain useful.
    case kind_module.persistence() do
      {:snapshot, :periodic, ms} ->
        if Process.whereis(Ezagent.Snapshot.Writer) do
          Ezagent.Snapshot.Writer.async_save(uri, kind_module, slice_state)
        else
          _ = Ezagent.Kind.Snapshot.save_now(uri, kind_module, slice_state)
        end

        Process.send_after(self(), :snapshot_tick, ms)
        {:noreply, wrapper}

      _ ->
        {:noreply, wrapper}
    end
  end

  def handle_info(message, %{kind: kind_module, uri: self_uri, state: slice_state} = wrapper) do
    new_slice_state =
      kind_module.behaviors()
      |> Enum.reduce(slice_state, fn behavior, acc_state ->
        forward_to_behavior(behavior, message, acc_state, kind_module, self_uri)
      end)

    {:noreply, %{wrapper | state: new_slice_state}}
  end

  defp forward_to_behavior(behavior, message, slice_state, kind_module, self_uri) do
    if function_exported?(behavior, :handle_kind_message, 3) do
      slice_key = behavior.state_slice()
      slice = Map.get(slice_state, slice_key, %{})
      ctx = %{kind_module: kind_module, self_uri: self_uri}

      case behavior.handle_kind_message(message, slice, ctx) do
        {:ok, new_slice} -> Map.put(slice_state, slice_key, new_slice)
        :ignore -> slice_state
      end
    else
      slice_state
    end
  end

  @impl true
  def terminate(_reason, %{kind: kind_module, uri: uri, state: slice_state}) do
    # Phase 4-completion: :on_terminate strategy writes on graceful
    # shutdown. Use try/rescue so a failing save never prevents the
    # Kind from going down.
    case kind_module.persistence() do
      :on_terminate ->
        try do
          _ = Ezagent.Kind.Snapshot.save_now(uri, kind_module, slice_state)
        rescue
          _ -> :ok
        end

        :ok

      _ ->
        :ok
    end
  end

  def terminate(_reason, _state), do: :ok
end
