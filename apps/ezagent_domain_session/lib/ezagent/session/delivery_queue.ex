defmodule Ezagent.Session.DeliveryQueue do
  @moduledoc """
  Per-recipient-key serialized executor for session message deliveries
  (send-echo-decouple, codex HIGH-1 rework, 2026-07-08).

  ## Why this exists

  `Ezagent.ActionSet.Session.handle_send/2` fans deliveries OFF its hot path so
  the sender's feed echo never waits on a dead/slow member. The first cut ran
  one UNSERIALIZED Task per delivery — but two rapid sends to the SAME recipient
  are then two racing Task pids, and BEAM gives no cross-pid cast ordering:
  msg2's delivery can overtake msg1's, inverting the recipient's
  `last_received`/`recent_messages` order, making ReadMarker's monotonic cursor
  discard msg1's marker as stale, and reordering agent-bridge pushes (codex
  HIGH-1). This queue restores per-recipient ordering WITHOUT giving back the
  hot path:

    * `enqueue/2` is a `:cast` — the Session Kind never blocks (Prong A intact).
    * ONE in-flight job per key, FIFO per key — a recipient observes deliveries
      in exactly the order the Session Kind enqueued them (send order, because
      the Session Kind processes sends serially).
    * Keys are independent — a dead/slow member's key backs up ALONE; every
      other recipient's deliveries proceed (Prong B intact). This is why the
      shape is per-KEY serialization and NOT a hash-partitioned pool (a dead
      member would block unrelated recipients sharing its partition).

  The key is the recipient's instance URI string — for a cross-session forward
  the recipient IS the target session URI, so the same derivation covers both
  fan-out shapes. Keying by recipient (not `{session, recipient}`) additionally
  serializes deliveries to one recipient across sessions: strictly stronger than
  required, and the right call for a single mailbox-owning Kind.

  ## Shape choice

  Codex suggested a per-key dynamic worker (Registry + DynamicSupervisor, or a
  keyed GenServer that drains and exits when idle). This central dispatcher +
  per-key FIFO over the existing `Task.Supervisor`
  (`Ezagent.Session.DeliverySupervisor`) has the SAME serialization semantics
  with none of the idle-exit races (a keyed worker that exits while a late
  enqueue is in flight drops the job or needs careful re-spawn handshakes).
  This GenServer does O(1) bookkeeping ONLY — the delivery work always runs in
  an unlinked supervised Task, so the queue itself can never become the
  bottleneck and a crashing delivery can never take the queue down.

  ## Delivery contract (at-most-once)

  Jobs are held in queue memory, not durably: a node restart or a crash of this
  GenServer drops queued jobs. That matches the pre-existing contract — the
  in-handler fan-out this replaced was equally lost on a mid-loop crash, and
  message DURABILITY is `MessageStore` (a member that missed a live delivery
  reads history / replay-on-join). A job whose Task crashes is logged with full
  attribution by the job wrapper in `Delivery.deliver_async/5` and NOT retried.
  """

  use GenServer

  require Logger

  @name __MODULE__

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, @name))
  end

  @doc false
  def child_spec(opts) do
    %{id: @name, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Enqueue `fun` for serialized execution under `key`. Fire-and-forget; never
  blocks the caller. Jobs with the same key run one-at-a-time in enqueue order;
  jobs with different keys run concurrently (each in its own unlinked Task
  under `Ezagent.Session.DeliverySupervisor`).
  """
  @spec enqueue(String.t(), (-> term())) :: :ok
  def enqueue(key, fun) when is_binary(key) and is_function(fun, 0) do
    GenServer.cast(@name, {:enqueue, key, fun})
  end

  @doc """
  True when no job is running or queued. Test/diagnostics support — production
  code never needs to observe the queue.
  """
  @spec idle?() :: boolean()
  def idle? do
    GenServer.call(@name, :idle?)
  end

  # --- GenServer ---------------------------------------------------------

  @impl GenServer
  def init(:ok) do
    # running:     key => task ref (exactly one in-flight job per key)
    # keys_by_ref: task ref => key (reverse index for completion handling)
    # queues:      key => :queue.queue(fun) of waiting jobs (absent when empty)
    {:ok, %{running: %{}, keys_by_ref: %{}, queues: %{}}}
  end

  @impl GenServer
  def handle_cast({:enqueue, key, fun}, state) do
    if Map.has_key?(state.running, key) do
      queues = Map.update(state.queues, key, :queue.from_list([fun]), &:queue.in(fun, &1))
      {:noreply, %{state | queues: queues}}
    else
      {:noreply, start_job(state, key, fun)}
    end
  end

  @impl GenServer
  def handle_call(:idle?, _from, state) do
    {:reply, state.running == %{} and state.queues == %{}, state}
  end

  # Task success — `async_nolink` sends `{ref, result}` before the :DOWN.
  # Demonitor with flush so the :DOWN is not processed as a second completion.
  @impl GenServer
  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, job_finished(state, ref)}
  end

  # Task crash/exit — the job wrapper already logged the failure with full
  # attribution (Delivery.deliver_async/5); here we only advance the key's
  # queue so one crashing delivery never wedges its recipient.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, job_finished(state, ref)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- internals ---------------------------------------------------------

  defp start_job(state, key, fun) do
    %Task{ref: ref} = Task.Supervisor.async_nolink(Ezagent.Session.DeliverySupervisor, fun)

    %{
      state
      | running: Map.put(state.running, key, ref),
        keys_by_ref: Map.put(state.keys_by_ref, ref, key)
    }
  end

  defp job_finished(state, ref) do
    case Map.pop(state.keys_by_ref, ref) do
      {nil, _} ->
        # Not one of ours (stale ref after a restart) — ignore.
        state

      {key, keys_by_ref} ->
        state = %{state | running: Map.delete(state.running, key), keys_by_ref: keys_by_ref}

        case Map.get(state.queues, key) do
          nil ->
            state

          q ->
            {{:value, fun}, rest} = :queue.out(q)

            state =
              if :queue.is_empty(rest) do
                %{state | queues: Map.delete(state.queues, key)}
              else
                %{state | queues: Map.put(state.queues, key, rest)}
              end

            start_job(state, key, fun)
        end
    end
  end
end
