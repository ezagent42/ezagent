defmodule EzagentActor.Signal.Monitor do
  @moduledoc """
  V5 use-side B1 — the monitor RELAY behind `EzagentActor.Signal.monitor/1`.

  A BEAM `Process.monitor/1` delivers its death notice as a raw
  `{:DOWN, ref, :process, pid, reason}` tuple to the monitoring process;
  the VM gives the caller no way to change that shape. So Kind code never
  monitors directly: this framework process owns every raw monitor and
  re-delivers each death to the requesting caller as the sanctioned
  `%EzagentActor.Signal{kind: :down}` envelope.

  ## Ownership + cleanup

    * one raw monitor per `monitor/2` request (`targets` index);
    * one EXTRA raw monitor per distinct caller (`callers` index) so a
      caller's death drops all of its outstanding target monitors — a
      crashed/restarted Kind cannot leak relay entries;
    * a target DOWN re-delivers the envelope and removes the entry; a
      caller DOWN demonitors + removes every target entry of that caller;
    * an unknown DOWN (e.g. a raced demonitor) is ignored.

  The re-delivery `Kernel.send/2` here is the transport's OWN envelope
  send — it appears in the D2 producer census by design (empty allowlist,
  report-only) and is the sanctioned shape, not a migration target.

  Supervised as a child of `EzagentActor.Application`. A relay crash loses
  in-flight monitors: the relay stays `:permanent` (default) so the
  supervisor restarts it immediately; callers whose monitored target dies
  during the restart window simply never get that DOWN — the same
  semantics as any monitor held by a process that restarts, and
  acceptable for B1 (monitor-holding Behaviors re-establish on their own
  restart/reconcile paths).
  """

  use GenServer

  alias EzagentActor.Signal

  # State:
  #   targets:     %{target_ref => {caller_pid, target_pid}}
  #   by_caller:   %{caller_pid => MapSet.t(target_ref)}
  #   callers:     %{caller_ref => caller_pid}   (one watcher per caller)
  #   caller_refs: %{caller_pid => caller_ref}

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc """
  Ask the relay to monitor `pid` on behalf of the calling process.
  Returns `{:ok, ref}`; the death arrives at the caller as
  `%EzagentActor.Signal{kind: :down, payload: %{ref: ref, ...}}`.
  """
  @spec monitor(pid()) :: {:ok, reference()}
  def monitor(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:monitor, self(), pid})
  end

  @impl true
  def init(:ok) do
    {:ok, %{targets: %{}, by_caller: %{}, callers: %{}, caller_refs: %{}}}
  end

  @impl true
  def handle_call({:monitor, caller, target}, _from, state) do
    ref = Process.monitor(target)
    state = ensure_caller_watched(state, caller)

    state = %{
      state
      | targets: Map.put(state.targets, ref, {caller, target}),
        by_caller: Map.update(state.by_caller, caller, MapSet.new([ref]), &MapSet.put(&1, ref))
    }

    {:reply, {:ok, ref}, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      Map.has_key?(state.targets, ref) ->
        {{caller, target}, state} = pop_target(state, ref)

        Kernel.send(caller, %Signal{
          kind: :down,
          from: target,
          payload: %{ref: ref, pid: target, reason: reason}
        })

        {:noreply, state}

      Map.has_key?(state.callers, ref) ->
        {:noreply, drop_caller(state, Map.fetch!(state.callers, ref))}

      true ->
        {:noreply, state}
    end
  end

  # Watch each distinct caller once, so its death cleans up its entries.
  defp ensure_caller_watched(state, caller) do
    if Map.has_key?(state.caller_refs, caller) do
      state
    else
      ref = Process.monitor(caller)

      %{
        state
        | callers: Map.put(state.callers, ref, caller),
          caller_refs: Map.put(state.caller_refs, caller, ref)
      }
    end
  end

  defp pop_target(state, ref) do
    {{caller, _target} = entry, targets} = Map.pop(state.targets, ref)

    by_caller =
      case Map.get(state.by_caller, caller) do
        nil -> state.by_caller
        refs -> drop_from_set_map(state.by_caller, caller, refs, ref)
      end

    {entry, %{state | targets: targets, by_caller: by_caller}}
  end

  # The caller died: demonitor + drop every target it was watching, and
  # forget the caller watcher itself (already fired).
  defp drop_caller(state, caller) do
    refs = Map.get(state.by_caller, caller, MapSet.new())
    Enum.each(refs, &Process.demonitor(&1, [:flush]))

    {caller_ref, caller_refs} = Map.pop(state.caller_refs, caller)

    %{
      state
      | targets: Map.drop(state.targets, MapSet.to_list(refs)),
        by_caller: Map.delete(state.by_caller, caller),
        callers: Map.delete(state.callers, caller_ref),
        caller_refs: caller_refs
    }
  end

  defp drop_from_set_map(map, key, set, elem) do
    set = MapSet.delete(set, elem)
    if MapSet.size(set) == 0, do: Map.delete(map, key), else: Map.put(map, key, set)
  end
end
