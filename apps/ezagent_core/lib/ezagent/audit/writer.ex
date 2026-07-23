defmodule Ezagent.Audit.Writer do
  @moduledoc """
  Async batch writer for the `invocations` audit table.

  Per Decision #60: telemetry handlers emit events synchronously into
  this GenServer's mailbox via `GenServer.cast`; the writer accumulates
  events in memory and flushes batches every `@flush_interval_ms` (or
  when the buffer hits `@batch_max`). This keeps the invoke hot path
  under a microsecond — the Postgres write is amortised across many
  invocations.

  ## Backpressure

  If the writer's mailbox exceeds `@backpressure_threshold`, subsequent
  cast becomes a synchronous `call` for the duration of one flush. Phase
  1 implements the simpler version: cast unconditionally and rely on
  100ms flush cycle to drain. Phase 2+ can add the threshold check if
  load measurements show it's needed.

  ## Phase 1 storage

  Writes via `EzagentCore.Repo.insert_all(invocations, batch)` — one round
  trip per flush. ARCHITECTURE.md §10.2 schema; the columns map straight
  from event metadata + measurements.
  """

  use GenServer
  require Logger

  @flush_interval_ms 100
  @batch_max 500

  defstruct buffer: [], timer_ref: nil

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, %__MODULE__{buffer: [], timer_ref: schedule_flush()}}
  end

  @impl true
  def handle_cast({:write, row}, %__MODULE__{buffer: buffer} = state) do
    new_buffer = [row | buffer]

    if length(new_buffer) >= @batch_max do
      flush_now(new_buffer)
      {:noreply, %{state | buffer: []}}
    else
      {:noreply, %{state | buffer: new_buffer}}
    end
  end

  @impl true
  def handle_info(:flush, %__MODULE__{buffer: buffer} = state) do
    if buffer != [] do
      flush_now(buffer)
    end

    {:noreply, %{state | buffer: [], timer_ref: schedule_flush()}}
  end

  @impl true
  def terminate(_reason, %__MODULE__{buffer: buffer}) do
    # Best-effort flush on shutdown so we don't lose the last batch.
    if buffer != [], do: flush_now(buffer)
    :ok
  end

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp flush_now(buffer) do
    rows = Enum.reverse(buffer)

    try do
      EzagentCore.Repo.insert_all("invocations", rows)
    rescue
      e ->
        # Per Appendix A: snapshot/persistence failure emits telemetry,
        # state is left untouched, next batch retries naturally.
        Logger.error("Ezagent.Audit.Writer flush failed: #{Exception.message(e)}")

        :telemetry.execute(
          [:ezagent, :persistence, :failed],
          %{},
          %{component: :audit_writer, reason: Exception.message(e)}
        )
    end
  end
end
