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

  @doc false
  @spec mark_failed(String.t()) :: :ok
  def mark_failed(uri_str) when is_binary(uri_str) do
    Ezagent.ReadyGate.mark_failed(uri_str)
  end
end
