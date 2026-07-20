defmodule Ezagent.ProviderConnection.Recovery do
  @moduledoc "Bounded restart recovery for durable provider-connection obligations."

  use GenServer
  import Ecto.Query

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    Connection,
    CredentialReplacement,
    Operation,
    Store,
    Types
  }

  alias EzagentCore.Repo

  @batch_size 50
  @max_batches_per_pass 10
  @phases [:callback, :termination, :refresh]
  @default_retry_base_ms 1_000
  @default_retry_cap_ms 300_000
  @default_idle_min_ms 100
  @default_idle_max_ms 60_000
  @default_yield_delay_ms 1
  @test_build Mix.env() == :test
  @scheduled_statuses ~w(prepared backend_committed connection_committed cleanup_pending)

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  def start_pass(server \\ __MODULE__) do
    GenServer.cast(server, :start_pass)
  end

  @doc false
  def batch_size, do: @batch_size

  @doc false
  def max_batches_per_pass, do: @max_batches_per_pass

  @impl true
  def init(opts) do
    state = %{
      phase: hd(@phases),
      cursor: nil,
      batches: 0,
      recovered: 0,
      running?: false,
      recoverer: Keyword.get(opts, :recoverer, __MODULE__),
      observer: Keyword.get(opts, :observer),
      now: clock(opts),
      timer: timer(opts),
      timer_ref: nil,
      timer_token: nil,
      retry_base_ms: positive_option!(opts, :retry_base_ms, @default_retry_base_ms),
      retry_cap_ms: positive_option!(opts, :retry_cap_ms, @default_retry_cap_ms),
      idle_min_ms: positive_option!(opts, :idle_min_ms, @default_idle_min_ms),
      idle_max_ms: positive_option!(opts, :idle_max_ms, @default_idle_max_ms),
      yield_delay_ms: positive_option!(opts, :yield_delay_ms, @default_yield_delay_ms)
    }

    validate_bounds!(state)

    if Keyword.get(opts, :autostart, true),
      do: {:ok, state, {:continue, :start_recovery_pass}},
      else: {:ok, state}
  end

  @impl true
  def handle_continue(:start_recovery_pass, state) do
    {:noreply, begin_pass(state)}
  end

  @impl true
  def handle_cast(:start_pass, %{running?: false} = state) do
    {:noreply, state |> cancel_scheduled_pass() |> begin_pass()}
  end

  def handle_cast(:start_pass, state), do: {:noreply, state}

  @impl true
  def handle_info({:scheduled_recovery_pass, _kind, token}, %{timer_token: token} = state) do
    {:noreply, begin_pass(state)}
  end

  def handle_info({:scheduled_recovery_pass, _kind, _stale_token}, state),
    do: {:noreply, state}

  def handle_info(:recover_batch, state) do
    rows = fetch_batch(state.phase, state.cursor, state.now.())

    cursor =
      Enum.reduce(rows, state.cursor, fn operation, _cursor ->
        result = safely_recover(state.recoverer, operation, state.now.(), state.observer)
        record_outcome(operation, result, state.now.(), state)

        {operation.inserted_at, operation.id}
      end)

    completed_batches = if rows == [], do: 0, else: 1

    state = %{
      state
      | batches: state.batches + completed_batches,
        recovered: state.recovered + length(rows),
        cursor: cursor
    }

    continue(rows, state)
  end

  @doc false
  def recover(%Operation{operation_class: "store", status: status} = operation, _now, _observer)
      when status in ["backend_committed", "connection_committed"] do
    CredentialReplacement.commit(operation.id)
  end

  def recover(
        %Operation{operation_class: "store", status: "cleanup_pending"} = operation,
        _now,
        _observer
      ),
      do: CredentialReplacement.cleanup(operation.id)

  def recover(
        %Operation{operation_class: "store", status: "prepared"} = operation,
        now,
        _observer
      ) do
    with %Connection{} = connection <- Repo.get(Connection, operation.connection_id),
         %AuthorizationAttempt{} = attempt <-
           Repo.get(AuthorizationAttempt, operation.attempt_ref) do
      if connection.status in ["revoking", "disconnecting"] do
        CredentialReplacement.reconcile(operation.id)
      else
        Store.execute(
          :consume_callback,
          %{attempt_ref: attempt.attempt_ref, correlation_id: attempt.correlation_id},
          %{self_uri: Ezagent.URI.new!(connection.owner_uri), now: now}
        )
      end
    else
      _missing -> {:error, :stale_version}
    end
  end

  def recover(%Operation{operation_class: action} = operation, _now, _observer)
      when action in ["revoke", "disconnect"] do
    with %Connection{} = connection <- Repo.get(Connection, operation.connection_id) do
      Store.execute(
        String.to_existing_atom(action),
        %{
          connection_id: connection.connection_id,
          expected_version: operation.expected_connection_version
        },
        %{self_uri: Ezagent.URI.new!(connection.owner_uri)}
      )
    else
      _missing -> {:error, :stale_version}
    end
  end

  def recover(%Operation{operation_class: "refresh"} = operation, now, _observer) do
    with %Connection{} = connection <- Repo.get(Connection, operation.connection_id) do
      Store.execute(
        :refresh,
        %{
          connection_id: connection.connection_id,
          expected_version: operation.expected_connection_version,
          correlation_id: operation.correlation_id
        },
        %{self_uri: Ezagent.URI.new!(connection.owner_uri), now: now}
      )
    else
      _missing -> {:error, :stale_version}
    end
  end

  defp continue(_rows, %{batches: batches} = state)
       when batches >= @max_batches_per_pass do
    notify(state, {:recovery_pass_yielded, self(), state.recovered})
    {:noreply, schedule_pass(state, :yield, state.yield_delay_ms)}
  end

  defp continue(rows, state) when length(rows) == @batch_size do
    send(self(), :recover_batch)
    {:noreply, state}
  end

  defp continue(_rows, state) do
    case next_phase(state.phase) do
      {:ok, phase} ->
        send(self(), :recover_batch)
        {:noreply, %{state | phase: phase, cursor: nil}}

      :done ->
        notify(state, {:recovery_idle, self()})

        idle_state = %{
          state
          | phase: hd(@phases),
            cursor: nil,
            batches: 0,
            recovered: 0,
            running?: false
        }

        {:noreply, schedule_earliest_due(idle_state, state.now.())}
    end
  end

  defp fetch_batch(phase, cursor, now) do
    phase
    |> phase_query(now)
    |> where([operation, ...], operation.next_recovery_at <= ^now)
    |> after_cursor(cursor)
    |> order_by([operation, ...], asc: operation.inserted_at, asc: operation.id)
    |> limit(@batch_size)
    |> Repo.all()
  end

  defp phase_query(:callback, now) do
    from(operation in Operation,
      left_join: connection in Connection,
      on: connection.connection_id == operation.connection_id,
      left_join: attempt in AuthorizationAttempt,
      on: attempt.attempt_ref == operation.attempt_ref,
      where:
        operation.operation_class == "store" and
          (operation.status in ["backend_committed", "connection_committed", "cleanup_pending"] or
             (operation.status == "prepared" and
                ((connection.status in ["revoking", "disconnecting"] and
                    attempt.status in ["cancelled", "expired"]) or
                   (connection.status in [
                      "pending_authorization",
                      "active",
                      "refresh_required",
                      "degraded",
                      "revoking",
                      "disconnecting"
                    ] and
                      attempt.status == "consuming" and attempt.claim_until <= ^now)))),
      select: operation
    )
  end

  defp phase_query(:termination, _now) do
    from(operation in Operation,
      where:
        operation.operation_class in ["revoke", "disconnect"] and
          operation.status in ["prepared", "backend_committed"],
      select: operation
    )
  end

  defp phase_query(:refresh, now) do
    from(operation in Operation,
      where:
        operation.operation_class == "refresh" and
          (operation.status in ["backend_committed", "connection_committed"] or
             (operation.status == "prepared" and operation.lease_until <= ^now)),
      select: operation
    )
  end

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {inserted_at, id}) do
    where(
      query,
      [operation, ...],
      operation.inserted_at > ^inserted_at or
        (operation.inserted_at == ^inserted_at and operation.id > ^id)
    )
  end

  defp next_phase(:callback), do: {:ok, :termination}
  defp next_phase(:termination), do: {:ok, :refresh}
  defp next_phase(:refresh), do: :done

  defp safely_recover(recoverer, operation, now, observer) do
    apply(recoverer, :recover, [operation, now, observer])
  rescue
    _error -> {:error, :recovery_failed}
  catch
    _kind, _reason -> {:error, :recovery_failed}
  end

  defp successful_recovery?(:ok), do: true
  defp successful_recovery?({:ok, _result}), do: true
  defp successful_recovery?(_result), do: false

  defp record_outcome(operation, result, now, state) do
    if successful_recovery?(result) do
      clear_terminal_schedule(operation)
    else
      record_failure(operation, normalize_error_code(result), now, state)
    end
  end

  defp clear_terminal_schedule(operation) do
    Operation
    |> where(
      [row],
      row.id == ^operation.id and row.status == "finalized" and
        (not is_nil(row.next_recovery_at) or not is_nil(row.last_recovery_error_code))
    )
    |> Repo.update_all(set: [next_recovery_at: nil, last_recovery_error_code: nil])

    :ok
  end

  defp record_failure(operation, error_code, now, state) do
    attempts = operation.recovery_attempts + 1
    delay_ms = retry_delay_ms(attempts, state.retry_base_ms, state.retry_cap_ms)
    next_recovery_at = DateTime.add(now, delay_ms, :millisecond)

    result =
      Operation
      |> where(
        [row],
        row.id == ^operation.id and row.status == ^operation.status and
          row.status in ^@scheduled_statuses and
          row.recovery_attempts == ^operation.recovery_attempts and
          row.next_recovery_at == ^operation.next_recovery_at
      )
      |> Repo.update_all(
        set: [
          recovery_attempts: attempts,
          last_recovery_error_code: error_code,
          next_recovery_at: next_recovery_at,
          updated_at: now
        ]
      )

    if match?({0, _rows}, result), do: clear_terminal_schedule(operation)

    :ok
  end

  defp normalize_error_code({:error, reason}), do: normalize_reason(reason)
  defp normalize_error_code(_other), do: "backend_unavailable"

  defp normalize_reason(reason) when is_atom(reason),
    do: if(reason in Types.errors(), do: Atom.to_string(reason), else: "backend_unavailable")

  defp normalize_reason(reason) when is_binary(reason) do
    if Enum.any?(Types.errors(), &(Atom.to_string(&1) == reason)),
      do: reason,
      else: "backend_unavailable"
  end

  defp normalize_reason(_unknown), do: "backend_unavailable"

  defp retry_delay_ms(1, base_ms, cap_ms), do: min(base_ms, cap_ms)

  defp retry_delay_ms(attempts, base_ms, cap_ms) do
    Enum.reduce_while(2..attempts//1, base_ms, fn _attempt, delay ->
      if delay >= cap_ms,
        do: {:halt, cap_ms},
        else: {:cont, min(delay * 2, cap_ms)}
    end)
  end

  defp schedule_earliest_due(state, now) do
    case earliest_due(now) do
      nil ->
        schedule_pass(state, :poll, state.idle_max_ms)

      due_at ->
        until_due_ms = max(DateTime.diff(due_at, now, :millisecond), 0)
        delay_ms = until_due_ms |> max(state.idle_min_ms) |> min(state.idle_max_ms)
        schedule_pass(state, :due, delay_ms)
    end
  end

  defp earliest_due(_now) do
    [earliest_callback_due(), earliest_termination_due(), earliest_refresh_due()]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&normalize_due_at/1)
    |> Enum.min_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp normalize_due_at(%DateTime{} = due_at), do: due_at

  defp normalize_due_at(%NaiveDateTime{} = due_at),
    do: DateTime.from_naive!(due_at, "Etc/UTC")

  defp earliest_callback_due do
    from(operation in Operation,
      left_join: connection in Connection,
      on: connection.connection_id == operation.connection_id,
      left_join: attempt in AuthorizationAttempt,
      on: attempt.attempt_ref == operation.attempt_ref,
      where:
        operation.operation_class == "store" and
          (operation.status in ["backend_committed", "connection_committed", "cleanup_pending"] or
             (operation.status == "prepared" and
                ((connection.status in ["revoking", "disconnecting"] and
                    attempt.status in ["cancelled", "expired"]) or
                   (connection.status in [
                      "pending_authorization",
                      "active",
                      "refresh_required",
                      "degraded",
                      "revoking",
                      "disconnecting"
                    ] and attempt.status == "consuming")))),
      select:
        min(
          type(
            fragment(
              "CASE WHEN ? = 'prepared' AND ? = 'consuming' THEN GREATEST(?, ?) ELSE ? END",
              operation.status,
              attempt.status,
              operation.next_recovery_at,
              attempt.claim_until,
              operation.next_recovery_at
            ),
            :utc_datetime_usec
          )
        )
    )
    |> Repo.one()
  end

  defp earliest_termination_due do
    from(operation in Operation,
      where:
        operation.operation_class in ["revoke", "disconnect"] and
          operation.status in ["prepared", "backend_committed"],
      select: min(operation.next_recovery_at)
    )
    |> Repo.one()
  end

  defp earliest_refresh_due do
    from(operation in Operation,
      where:
        operation.operation_class == "refresh" and
          operation.status in ["prepared", "backend_committed", "connection_committed"],
      select:
        min(
          type(
            fragment(
              "CASE WHEN ? = 'prepared' THEN GREATEST(?, ?) ELSE ? END",
              operation.status,
              operation.next_recovery_at,
              operation.lease_until,
              operation.next_recovery_at
            ),
            :utc_datetime_usec
          )
        )
    )
    |> Repo.one()
  end

  defp schedule_pass(state, kind, delay_ms) when delay_ms > 0 do
    token = make_ref()
    message = {:scheduled_recovery_pass, kind, token}
    timer_ref = state.timer.(self(), message, delay_ms)
    notify(state, {:recovery_scheduled, self(), kind, delay_ms})
    %{state | timer_ref: timer_ref, timer_token: token}
  end

  defp begin_pass(state) do
    send(self(), :recover_batch)
    %{state | batches: 0, running?: true, timer_ref: nil, timer_token: nil}
  end

  defp cancel_scheduled_pass(%{timer_ref: nil} = state), do: state

  defp cancel_scheduled_pass(state) do
    Process.cancel_timer(state.timer_ref)
    %{state | timer_ref: nil, timer_token: nil}
  end

  defp clock(opts) do
    if @test_build,
      do: Keyword.get(opts, :now, &DateTime.utc_now/0),
      else: &DateTime.utc_now/0
  end

  defp timer(opts) do
    if @test_build,
      do: Keyword.get(opts, :timer, &Process.send_after/3),
      else: &Process.send_after/3
  end

  defp positive_option!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> raise ArgumentError, "#{key} must be a positive integer"
    end
  end

  defp validate_bounds!(state) do
    if state.retry_base_ms > state.retry_cap_ms,
      do: raise(ArgumentError, "retry_base_ms must not exceed retry_cap_ms")

    if state.idle_min_ms > state.idle_max_ms,
      do: raise(ArgumentError, "idle_min_ms must not exceed idle_max_ms")

    :ok
  end

  defp notify(%{observer: observer}, message) when is_pid(observer), do: send(observer, message)
  defp notify(_state, _message), do: :ok
end
