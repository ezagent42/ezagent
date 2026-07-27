defmodule Ezagent.Snapshot.Writer do
  @moduledoc """
  Async batch writer for `:periodic` snapshot strategy.

  Mirrors `Ezagent.Audit.Writer` (Decision #60): per-Kind `:snapshot_tick`
  fires a `cast/3` into this Writer's mailbox; Writer batches and
  flushes via `Ezagent.Kind.Snapshot.save_now/3` every
  `@flush_interval_ms` or when the buffer hits `@batch_max`.

  Per Spec 04 Q2: only `:periodic` strategy goes through here.
  `:on_change` and `:on_terminate` write synchronously via
  `Snapshot.save_now/3` directly.

  ## Backpressure

  Phase 4 v1: cast unconditionally; relies on 100ms flush cycle to
  drain. If backpressure becomes an issue (>1000 backed-up casts),
  Phase 5+ can add the `cast → call` threshold pattern.

  ## Failure mode

  Each `save_now` failure is logged + telemetry (handled in
  `Snapshot.save_now`); the batch continues. A poison-pill snapshot
  doesn't lose subsequent writes.
  """

  use GenServer
  require Logger

  @flush_interval_ms 100
  @batch_max 100

  defstruct buffer: %{}, timer_ref: nil

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Schedule an async snapshot write. Latest pending write per URI wins
  (older buffered states for same URI are discarded — periodic strategy
  cares about the latest snapshot, not the history).
  """
  @spec async_save(URI.t() | String.t(), module(), map()) :: :ok
  def async_save(uri, kind_module, state) do
    GenServer.cast(__MODULE__, {:save, uri, kind_module, state})
  end

  @impl true
  def init(_) do
    {:ok, %__MODULE__{buffer: %{}, timer_ref: schedule_flush()}}
  end

  @impl true
  def handle_cast({:save, uri, kind_module, state}, %__MODULE__{buffer: buffer} = wrapper) do
    uri_str = uri_to_str(uri)
    # Latest write per URI wins — older buffered entries shadowed.
    new_buffer = Map.put(buffer, uri_str, {uri, kind_module, state})

    if map_size(new_buffer) >= @batch_max do
      flush_now(new_buffer)
      {:noreply, %{wrapper | buffer: %{}}}
    else
      {:noreply, %{wrapper | buffer: new_buffer}}
    end
  end

  @impl true
  def handle_info(:flush, %__MODULE__{buffer: buffer} = wrapper) do
    if map_size(buffer) > 0 do
      flush_now(buffer)
    end

    {:noreply, %{wrapper | buffer: %{}, timer_ref: schedule_flush()}}
  end

  defp flush_now(buffer) do
    # Issue #342 (Allen 2026-05-25 — let-it-crash): `save_now/3` is
    # now strict — it raises on infra failures and returns
    # `{:error, _}` on changeset failures, so callers MUST decide what
    # to do at their boundary. The Writer is the canonical
    # best-effort caller: this is the async batched flush path
    # (`@flush_interval_ms` between attempts), and one poison-pill
    # snapshot row should not crash the Writer and drop the whole
    # buffer. Rescue here, log + continue with the next entry.
    Enum.each(buffer, fn {_uri_str, {uri, kind_module, state}} ->
      try do
        _ = Ezagent.Kind.Snapshot.save_now(uri, kind_module, state)
      rescue
        e ->
          require Logger

          Logger.warning(
            "Ezagent.Snapshot.Writer.flush_now: save_now raised for " <>
              "#{inspect(uri)}: #{inspect(e)} — continuing batch"
          )
      catch
        # Issue #342 — also catch :exit so a linked DB connection
        # process death (sandbox owner exit in tests, DBConnection
        # crash in prod) doesn't drop the entire batch.
        :exit, reason ->
          require Logger

          Logger.warning(
            "Ezagent.Snapshot.Writer.flush_now: save_now exited for " <>
              "#{inspect(uri)}: #{inspect(reason)} — continuing batch"
          )
      end
    end)
  end

  defp schedule_flush, do: Process.send_after(self(), :flush, @flush_interval_ms)

  defp uri_to_str(%URI{} = u), do: URI.to_string(u)
  defp uri_to_str(s) when is_binary(s), do: s
end
