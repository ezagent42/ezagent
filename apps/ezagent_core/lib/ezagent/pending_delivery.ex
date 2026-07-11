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

  S7 capability hand-off makes the buffer an authority-bearing boundary. All
  per-URI buffer/flush/readiness transitions therefore share one node-local
  critical section: concurrent appends cannot overwrite each other, and a
  producer rechecks both `ReadyGate` and the target's registered process under
  the same lock used by ready/failed drains. Guarded entries retain that process
  incarnation in the buffer, so an artifact accepted before a crash is rejected
  rather than drained into a replacement Kind at the same URI.
  """

  @table :ezagent_pending_delivery
  @max_per_uri 100

  @incarnation_tag :ezagent_pending_delivery_incarnation

  @type buffer_entry :: term()
  @type stored_entry ::
          {:ezagent_pending_delivery_incarnation, pid(), buffer_entry()} | buffer_entry()

  def table, do: @table
  def max_per_uri, do: @max_per_uri

  @doc """
  Append an entry to the URI's buffer.

  Returns `:ok` if the entry was buffered, or
  `{:error, :buffer_full}` if `@max_per_uri` is already reached.
  """
  @spec buffer(URI.t() | String.t(), buffer_entry()) :: :ok | {:error, :buffer_full}
  def buffer(uri, entry) do
    with_lock(uri, fn -> append_unlocked(key(uri), entry) end)
  end

  @doc """
  Atomically recheck readiness and buffer `entry` only while `uri` is still
  `:not_ready`.

  `{:retry, status}` tells the dispatch chokepoint that readiness changed after
  its optimistic read; it must route again against the new state. A failed gate
  or replaced Kind incarnation rejects the hand-off and can never retain a late
  entry.
  """
  @spec buffer_if_not_ready(URI.t() | String.t(), buffer_entry()) ::
          :ok
          | {:error, :buffer_full | :failed | :incarnation_changed}
          | {:retry, :ready | :unknown}
  def buffer_if_not_ready(uri, entry) do
    buffer_if_not_ready(uri, entry, current_incarnation(uri))
  end

  @doc false
  @spec buffer_if_not_ready(URI.t() | String.t(), buffer_entry(), pid() | :unregistered) ::
          :ok
          | {:error, :buffer_full | :failed | :incarnation_changed}
          | {:retry, :ready | :unknown}
  def buffer_if_not_ready(uri, entry, expected_incarnation)
      when is_pid(expected_incarnation) or expected_incarnation == :unregistered do
    with_lock(uri, fn ->
      buffer_if_not_ready_locked(uri, entry, expected_incarnation)
    end)
  end

  @doc false
  @spec buffer_if_not_ready_locked(
          URI.t() | String.t(),
          buffer_entry(),
          pid() | :unregistered
        ) ::
          :ok
          | {:error, :buffer_full | :failed | :incarnation_changed}
          | {:retry, :ready | :unknown}
  def buffer_if_not_ready_locked(uri, entry, expected_incarnation)
      when is_pid(expected_incarnation) or expected_incarnation == :unregistered do
    current_incarnation = current_incarnation(uri)

    cond do
      not is_pid(expected_incarnation) ->
        # A stale :not_ready row without a live Kind must never become a
        # mailbox for whatever process later claims the same URI.
        {:error, :incarnation_changed}

      current_incarnation != expected_incarnation ->
        # Check incarnation before every readiness branch. Retrying a :ready
        # replacement would otherwise deliver old authority into the new pid.
        {:error, :incarnation_changed}

      true ->
        case Ezagent.ReadyGate.status(uri) do
          :not_ready ->
            append_unlocked(
              key(uri),
              {@incarnation_tag, expected_incarnation, entry}
            )

          :ready ->
            {:retry, :ready}

          :unknown ->
            {:retry, :unknown}

          :failed ->
            {:error, :failed}
        end
    end
  end

  defp append_unlocked(key, entry) do
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
    with_lock(uri, fn ->
      uri
      |> take_locked()
      |> unwrap_entries()
    end)
  end

  @doc "Current buffered count for a URI — for tests/observability."
  @spec buffer_size(URI.t() | String.t()) :: non_neg_integer()
  def buffer_size(uri), do: with_lock(uri, fn -> read(key(uri)) |> length() end)

  @doc false
  @spec with_lock(URI.t() | String.t(), (-> result)) :: result when result: var
  def with_lock(uri, fun) when is_function(fun, 0) do
    lock_id = {{__MODULE__, key(uri)}, self()}
    :global.trans(lock_id, fun, [node()])
  end

  @doc false
  @spec take_locked(URI.t() | String.t()) :: [stored_entry()]
  def take_locked(uri) do
    buffer_key = key(uri)
    entries = read(buffer_key)
    :ets.delete(@table, buffer_key)
    entries
  end

  @doc false
  @spec partition_for_incarnation([stored_entry()], pid()) ::
          {[buffer_entry()], [buffer_entry()]}
  def partition_for_incarnation(entries, incarnation) when is_pid(incarnation) do
    {deliverable, stale} =
      Enum.reduce(entries, {[], []}, fn
        {@incarnation_tag, ^incarnation, entry}, {deliverable, stale} ->
          {[entry | deliverable], stale}

        {@incarnation_tag, _other_incarnation, entry}, {deliverable, stale} ->
          {deliverable, [entry | stale]}

        legacy_entry, {deliverable, stale} ->
          # Rows written by the pre-S7 process were untagged. Preserve their
          # historical delivery semantics across a rolling code upgrade.
          {[legacy_entry | deliverable], stale}
      end)

    {Enum.reverse(deliverable), Enum.reverse(stale)}
  end

  @doc false
  @spec unwrap_entries([stored_entry()]) :: [buffer_entry()]
  def unwrap_entries(entries) do
    Enum.map(entries, fn
      {@incarnation_tag, _incarnation, entry} -> entry
      legacy_entry -> legacy_entry
    end)
  end

  defp read(key) do
    case :ets.lookup(@table, key) do
      [{_, list}] -> list
      [] -> []
    end
  end

  defp current_incarnation(uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} when is_pid(pid) -> pid
      _ -> :unregistered
    end
  end

  defp key(%URI{} = uri), do: URI.to_string(uri)
  defp key(uri) when is_binary(uri), do: uri
end
