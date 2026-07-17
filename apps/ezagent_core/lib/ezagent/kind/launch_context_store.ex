defmodule Ezagent.Kind.LaunchContextStore do
  @moduledoc false

  use GenServer

  @table __MODULE__

  def table, do: @table

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def issue(context), do: GenServer.call(__MODULE__, {:issue, context})
  def take(token), do: GenServer.call(__MODULE__, {:take, token})
  def discard(token), do: GenServer.call(__MODULE__, {:discard, token})

  @impl true
  def init(_state) do
    monitors =
      :ets.foldl(
        fn
          {token, :pending, _context, issuer}, acc -> monitor_issuer(acc, token, issuer)
          _entry, acc -> acc
        end,
        %{},
        @table
      )

    {:ok, monitors}
  end

  @impl true
  def handle_call({:issue, context}, {issuer, _tag}, monitors) do
    token = make_ref()
    true = :ets.insert_new(@table, {token, :pending, context, issuer})
    {:reply, token, monitor_issuer(monitors, token, issuer)}
  end

  def handle_call({:take, token}, _from, monitors) do
    case :ets.lookup(@table, token) do
      [{^token, :pending, context, issuer}] ->
        true = :ets.insert(@table, {token, :consumed})
        {:reply, {:ok, context}, demonitor_token(monitors, token, issuer)}

      [{^token, :consumed}] ->
        {:reply, :consumed, monitors}

      [] ->
        {:reply, {:error, :launch_context_lost}, monitors}
    end
  end

  @impl true
  def handle_call({:discard, token}, _from, monitors) do
    case :ets.lookup(@table, token) do
      [{^token, :pending, _context, issuer}] ->
        true = :ets.delete(@table, token)
        {:reply, :ok, demonitor_token(monitors, token, issuer)}

      _ ->
        {:reply, :ok, monitors}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, monitors) do
    case Map.pop(monitors, ref) do
      {nil, monitors} ->
        {:noreply, monitors}

      {token, monitors} ->
        :ets.select_delete(@table, [{{token, :pending, :_, :_}, [], [true]}])
        {:noreply, Map.delete(monitors, token)}
    end
  end

  @impl true
  def format_status(_status), do: %{state: :redacted}

  defp monitor_issuer(monitors, token, issuer) do
    ref = Process.monitor(issuer)
    monitors |> Map.put(token, ref) |> Map.put(ref, token)
  end

  defp demonitor_token(monitors, token, _issuer) do
    case Map.pop(monitors, token) do
      {nil, monitors} ->
        monitors

      {ref, monitors} ->
        Process.demonitor(ref, [:flush])
        Map.delete(monitors, ref)
    end
  end
end
