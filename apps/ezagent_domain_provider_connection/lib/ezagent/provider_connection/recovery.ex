defmodule Ezagent.ProviderConnection.Recovery do
  @moduledoc "Bounded restart recovery for durable provider-connection obligations."

  use GenServer
  import Ecto.Query

  alias Ezagent.ProviderConnection.{
    AuthorizationAttempt,
    Connection,
    CredentialReplacement,
    Operation,
    Store
  }

  alias EzagentCore.Repo

  @batch_size 50
  @max_batches_per_pass 10
  @phases [:callback, :termination, :refresh]

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
      now: Keyword.get(opts, :now, &DateTime.utc_now/0)
    }

    if Keyword.get(opts, :autostart, true),
      do: {:ok, state, {:continue, :start_recovery_pass}},
      else: {:ok, state}
  end

  @impl true
  def handle_continue(:start_recovery_pass, state) do
    send(self(), :start_recovery_pass)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:start_pass, %{running?: false} = state) do
    send(self(), :start_recovery_pass)
    {:noreply, %{state | running?: true}}
  end

  def handle_cast(:start_pass, state), do: {:noreply, state}

  @impl true
  def handle_info(:start_recovery_pass, state) do
    send(self(), :recover_batch)
    {:noreply, %{state | batches: 0, running?: true}}
  end

  def handle_info(:recover_batch, state) do
    now = state.now.()
    rows = fetch_batch(state.phase, state.cursor, now)

    {cursor, failed?} =
      Enum.reduce(rows, {state.cursor, false}, fn operation, {cursor, failed?} ->
        result = safely_recover(state.recoverer, operation, now, state.observer)

        if successful_recovery?(result) and not failed?,
          do: {{operation.inserted_at, operation.id}, false},
          else: {cursor, true}
      end)

    completed_batches = if rows == [], do: 0, else: 1

    state = %{
      state
      | batches: state.batches + completed_batches,
        recovered: state.recovered + length(rows),
        cursor: cursor
    }

    continue(rows, state, failed?)
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

  defp continue(_rows, %{batches: batches} = state, _failed?)
       when batches >= @max_batches_per_pass do
    notify(state, {:recovery_pass_yielded, self(), state.recovered})
    Process.send_after(self(), :start_recovery_pass, 0)
    {:noreply, state}
  end

  defp continue(_rows, state, true) do
    send(self(), :recover_batch)
    {:noreply, state}
  end

  defp continue(rows, state, false) when length(rows) == @batch_size do
    send(self(), :recover_batch)
    {:noreply, state}
  end

  defp continue(_rows, state, false) do
    case next_phase(state.phase) do
      {:ok, phase} ->
        send(self(), :recover_batch)
        {:noreply, %{state | phase: phase, cursor: nil}}

      :done ->
        notify(state, {:recovery_idle, self()})

        {:noreply,
         %{
           state
           | phase: hd(@phases),
             cursor: nil,
             batches: 0,
             recovered: 0,
             running?: false
         }}
    end
  end

  defp fetch_batch(phase, cursor, now) do
    phase
    |> phase_query(now)
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

  defp notify(%{observer: observer}, message) when is_pid(observer), do: send(observer, message)
  defp notify(_state, _message), do: :ok
end
