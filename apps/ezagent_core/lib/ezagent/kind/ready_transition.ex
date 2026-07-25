defmodule Ezagent.Kind.ReadyTransition do
  @moduledoc false

  require Logger

  @doc false
  @spec register_not_ready(String.t(), pid()) ::
          :ok | {:error, {:already_registered, pid()}}
  def register_not_ready(uri_str, pid) when is_binary(uri_str) and is_pid(pid) do
    Ezagent.PendingDelivery.with_lock(uri_str, fn ->
      case Ezagent.KindRegistry.put_new(uri_str, pid) do
        :ok ->
          :ok = Ezagent.ReadyGate.put(uri_str, :not_ready)
          :ok

        {:error, {:already_registered, _other_pid}} = error ->
          error
      end
    end)
  end

  @doc false
  @spec drain_then_mark_ready(String.t(), pid()) :: :ready | :deferred | :failed
  def drain_then_mark_ready(uri_str, parent) when is_binary(uri_str) and is_pid(parent) do
    case Ezagent.ReadyGate.external_gate(uri_str) do
      :ready ->
        drain_pending_then_mark_ready(uri_str, parent)

      {:defer, module, _timeout_ms} ->
        start_external_wait(module, uri_str, parent)
    end
  end

  @doc false
  @spec drain_pending_then_mark_ready(String.t(), pid()) :: :ready | :deferred | :failed
  def drain_pending_then_mark_ready(uri_str, parent) when is_binary(uri_str) and is_pid(parent) do
    {result, stale_entries} =
      Ezagent.PendingDelivery.with_lock(uri_str, fn ->
        # Recheck the external gate while holding the same lock as buffer
        # detach. This closes the check→arm window where a transport generation
        # could set :not_ready after drain_then_mark_ready/2's first check.
        case Ezagent.ReadyGate.external_gate(uri_str) do
          :ready -> drain_pending_then_mark_ready_locked(uri_str, parent)
          {:defer, module, _timeout_ms} -> {{:deferred, module}, []}
        end
      end)

    dead_letter_stale_entries(uri_str, stale_entries)

    final_result =
      case result do
        {:deferred, module} -> start_external_wait(module, uri_str, parent)
        result -> result
      end

    if final_result == :ready and Ezagent.Cap.DeliveryOutbox.pending_target?(uri_str) do
      drain_cap_delivery_outbox(uri_str)
    end

    final_result
  end

  defp start_external_wait(module, uri_str, parent) do
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

  @doc false
  @spec drain_pending_then_mark_ready_locked(String.t(), pid()) ::
          {:ready | :failed, [term()]}
  def drain_pending_then_mark_ready_locked(uri_str, parent)
      when is_binary(uri_str) and is_pid(parent) do
    # Caller holds PendingDelivery.with_lock/2. A definitive failure/teardown
    # wins over a late bridge join; never resurrect that gate.
    if Ezagent.ReadyGate.status(uri_str) == :failed do
      {:failed, []}
    else
      {deliverable, stale_entries} =
        uri_str
        |> Ezagent.PendingDelivery.take_locked()
        |> Ezagent.PendingDelivery.partition_for_incarnation(parent)

      Enum.each(deliverable, fn buffered_inv ->
        GenServer.cast(parent, {:ezagent_dispatch, buffered_inv})
      end)

      :ok = Ezagent.ReadyGate.mark_ready(uri_str)
      {:ready, stale_entries}
    end
  end

  @doc """
  Mark `uri`'s readiness gate `:failed` AND drain any `:cast` invocations still
  buffered in `PendingDelivery` for it.

  Symmetric with `drain_pending_then_mark_ready/2`: on `:ready` the buffer is
  re-dispatched to the now-live Kind; on `:failed` (transport exhausted, the
  Kind will never come up) the buffer is atomically detached and the gate flips
  under the same per-URI lock. The detached entries are then dead-lettered —
  reason `:never_ready`, loud log + telemetry — so a producer can neither race
  in a late artifact nor block behind DLQ I/O (doc §8.1 / Invariant #9).

  Accepts a `%URI{}` or its string form (the transport-readiness timeout path
  passes a `%URI{}`; `Kind.Server` passes the string key).

  Best-effort per entry: a single DLQ-write failure is logged and never blocks
  draining the rest or flipping the gate.
  """
  @spec mark_failed(URI.t() | String.t()) :: :ok
  def mark_failed(uri) do
    uri_str = to_uri_string(uri)

    entries =
      Ezagent.PendingDelivery.with_lock(uri_str, fn ->
        mark_failed_locked(uri_str)
      end)

    dead_letter_failed_entries(uri_str, entries)
    :ok
  end

  @doc false
  @spec mark_failed_locked(String.t()) :: [term()]
  def mark_failed_locked(uri_str) when is_binary(uri_str) do
    entries =
      uri_str
      |> Ezagent.PendingDelivery.take_locked()
      |> Ezagent.PendingDelivery.unwrap_entries()

    :ok = Ezagent.ReadyGate.mark_failed(uri_str)
    entries
  end

  @doc false
  @spec dead_letter_failed_entries(String.t(), [term()]) :: :ok
  def dead_letter_failed_entries(uri_str, entries) do
    case entries do
      [] ->
        :ok

      entries ->
        Logger.error(
          "Ezagent.Kind.ReadyTransition: target #{uri_str} marked :failed with " <>
            "#{length(entries)} buffered :cast invocation(s) still undelivered — " <>
            "dead-lettering (reason=:never_ready) so they are NOT silently dropped"
        )

        Enum.each(entries, &safe_dlq_put(:never_ready, &1))

        :telemetry.execute(
          [:ezagent, :ready_transition, :mark_failed_drained],
          %{count: length(entries)},
          %{uri: uri_str}
        )

        :ok
    end
  end

  @doc false
  @spec dead_letter_stale_entries(String.t(), [term()]) :: :ok
  def dead_letter_stale_entries(_uri_str, []), do: :ok

  def dead_letter_stale_entries(uri_str, entries) do
    Logger.error(
      "Ezagent.Kind.ReadyTransition: rejected #{length(entries)} buffered :cast " <>
        "invocation(s) for #{uri_str} because their Kind incarnation was replaced " <>
        "before delivery (reason=:stale_incarnation)"
    )

    Enum.each(entries, &safe_dlq_put(:stale_incarnation, &1))

    :telemetry.execute(
      [:ezagent, :ready_transition, :stale_incarnation_drained],
      %{count: length(entries)},
      %{uri: uri_str}
    )

    :ok
  end

  # C5 §3.4 DeadLetterPort — DLQ writes go through the config-resolved port,
  # never the literal `Ezagent.DLQ` spine. Wired at core boot
  # (`Ezagent.Kind.Adapters.wire!/0`) to
  # `Ezagent.Kind.Adapters.DeadLetterAdapter`.
  defp dead_letter, do: Application.fetch_env!(:ezagent_actor, :dead_letter)

  defp safe_dlq_put(reason, buffered_inv) do
    _ = dead_letter().put(reason, buffered_inv)
    :ok
  rescue
    e ->
      Logger.error(
        "Ezagent.Kind.ReadyTransition: DLQ write for a #{reason} drop FAILED: " <>
          "#{Exception.message(e)} — the buffered invocation is lost"
      )

      :error
  catch
    kind, caught_reason ->
      Logger.error(
        "Ezagent.Kind.ReadyTransition: DLQ write for a #{reason} drop #{kind}: " <>
          "#{inspect(caught_reason)} — the buffered invocation is lost"
      )

      :error
  end

  defp to_uri_string(%URI{} = uri), do: URI.to_string(uri)
  defp to_uri_string(uri) when is_binary(uri), do: uri

  defp drain_cap_delivery_outbox(uri_str) do
    Ezagent.Cap.DeliveryOutbox.drain_target(uri_str)
  rescue
    error ->
      Logger.error(
        "Ezagent.Kind.ReadyTransition: cap delivery outbox drain failed for #{uri_str}: " <>
          Exception.message(error) <> "; periodic retry remains authoritative"
      )

      :ok
  catch
    kind, reason ->
      Logger.error(
        "Ezagent.Kind.ReadyTransition: cap delivery outbox drain #{kind} for #{uri_str}: " <>
          inspect(reason) <> "; periodic retry remains authoritative"
      )

      :ok
  end
end
