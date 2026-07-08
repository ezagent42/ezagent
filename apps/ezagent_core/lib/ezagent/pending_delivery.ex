defmodule Ezagent.PendingDelivery do
  @moduledoc """
  PendingDelivery — ETS-backed bounded buffer of `:cast` invocations
  waiting for their target URI to leave `:not_ready` state.

  Per Decision #67, each URI gets a buffer with `@max_per_uri` slots
  (default 100). Overflow falls to DLQ (Phase 1 step 3 wires this).
  `flush/1` drains a URI's buffer in arrival order — called by
  `Ezagent.Kind.Server.handle_continue(:announce_ready, ...)` after the
  Kind transitions to `:ready`.

  Owned by `EzagentCore.EtsOwner` shared lifecycle.

  ## Phase 1 scope

  Step 1 ships buffer/flush. Overflow returns `{:error, :buffer_full}` to the
  caller; the dispatch-layer caller (`Ezagent.Invocation`) records the dropped
  invocation to `Ezagent.DLQ` reason `:buffer_full` and surfaces the error
  (PR #1259 — the Decision #67 "overflow falls to DLQ" wiring).
  """

  @table :ezagent_pending_delivery
  @max_per_uri 100

  @type buffer_entry :: term()

  def table, do: @table
  def max_per_uri, do: @max_per_uri

  @doc """
  Append an entry to the URI's buffer.

  Returns `:ok` if the entry was buffered, or
  `{:error, :buffer_full}` if `@max_per_uri` is already reached.
  """
  @spec buffer(URI.t() | String.t(), buffer_entry()) :: :ok | {:error, :buffer_full}
  def buffer(uri, entry) do
    key = key(uri)
    current = read(key)

    if length(current) >= @max_per_uri do
      {:error, :buffer_full}
    else
      :ets.insert(@table, {key, current ++ [entry]})
      :ok
    end
  end

  @doc """
  Drain and return all buffered entries for a URI in arrival order.

  Atomically clears the URI's slot. Returns `[]` if nothing buffered.
  """
  @spec flush(URI.t() | String.t()) :: [buffer_entry()]
  def flush(uri) do
    key = key(uri)
    entries = read(key)
    :ets.delete(@table, key)
    entries
  end

  @doc "Current buffered count for a URI — for tests/observability."
  @spec buffer_size(URI.t() | String.t()) :: non_neg_integer()
  def buffer_size(uri), do: read(key(uri)) |> length()

  defp read(key) do
    case :ets.lookup(@table, key) do
      [{_, list}] -> list
      [] -> []
    end
  end

  defp key(%URI{} = uri), do: URI.to_string(uri)
  defp key(uri) when is_binary(uri), do: uri
end
