defmodule Ezagent.Kind.ReadyTransition do
  @moduledoc false

  require Logger

  @doc false
  @spec drain_then_mark_ready(String.t(), pid()) :: :ready | :deferred
  def drain_then_mark_ready(uri_str, parent) when is_binary(uri_str) and is_pid(parent) do
    case Ezagent.ReadyGate.external_gate(uri_str) do
      :ready ->
        drain_pending_then_mark_ready(uri_str, parent)

      {:defer, module, _timeout_ms} ->
        {:ok, _pid} =
          Task.start(fn ->
            result =
              if function_exported?(module, :await_transport_or_fail, 1) do
                module.await_transport_or_fail(uri_str)
              else
                {:error, :timeout}
              end

            send(parent, {:ezagent_external_ready_gate, uri_str, result})
          end)

        :deferred
    end
  end

  @doc false
  @spec drain_pending_then_mark_ready(String.t(), pid()) :: :ready
  def drain_pending_then_mark_ready(uri_str, parent) when is_binary(uri_str) and is_pid(parent) do
    case Ezagent.PendingDelivery.flush(uri_str) do
      [] ->
        :ok = Ezagent.ReadyGate.mark_ready(uri_str)
        :ready

      entries ->
        Enum.each(entries, fn buffered_inv ->
          GenServer.cast(parent, {:ezagent_dispatch, buffered_inv})
        end)

        drain_pending_then_mark_ready(uri_str, parent)
    end
  end

  @doc """
  Mark `uri`'s readiness gate `:failed` AND drain any `:cast` invocations still
  buffered in `PendingDelivery` for it.

  Symmetric with `drain_pending_then_mark_ready/2`: on `:ready` the buffer is
  re-dispatched to the now-live Kind; on `:failed` (transport exhausted, the
  Kind will never come up) the buffer is dead-lettered — reason `:never_ready`,
  loud log + telemetry — BEFORE the gate flips, so a never-ready target never
  silently swallows buffered work (doc §8.1 silent-drop / Invariant #9 /
  Decision #67 "overflow falls to DLQ").

  Accepts a `%URI{}` or its string form (the transport-readiness timeout path
  passes a `%URI{}`; `Kind.Server` passes the string key).

  Best-effort per entry: a single DLQ-write failure is logged and never blocks
  draining the rest or flipping the gate.
  """
  @spec mark_failed(URI.t() | String.t()) :: :ok
  def mark_failed(uri) do
    uri_str = to_uri_string(uri)
    drain_pending_to_dlq(uri_str)
    Ezagent.ReadyGate.mark_failed(uri_str)
  end

  defp drain_pending_to_dlq(uri_str) do
    case Ezagent.PendingDelivery.flush(uri_str) do
      [] ->
        :ok

      entries ->
        Logger.error(
          "Ezagent.Kind.ReadyTransition: target #{uri_str} marked :failed with " <>
            "#{length(entries)} buffered :cast invocation(s) still undelivered — " <>
            "dead-lettering (reason=:never_ready) so they are NOT silently dropped"
        )

        Enum.each(entries, &safe_dlq_put/1)

        :telemetry.execute(
          [:ezagent, :ready_transition, :mark_failed_drained],
          %{count: length(entries)},
          %{uri: uri_str}
        )

        :ok
    end
  end

  defp safe_dlq_put(buffered_inv) do
    _ = Ezagent.DLQ.put(:never_ready, buffered_inv)
    :ok
  rescue
    e ->
      Logger.error(
        "Ezagent.Kind.ReadyTransition: DLQ write for a never_ready drop FAILED: " <>
          "#{Exception.message(e)} — the buffered invocation is lost"
      )

      :error
  end

  defp to_uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp to_uri_string(uri) when is_binary(uri), do: uri
end
