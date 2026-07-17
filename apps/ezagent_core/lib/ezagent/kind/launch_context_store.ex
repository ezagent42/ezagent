defmodule Ezagent.Kind.LaunchContextStore do
  @moduledoc false

  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def issue(context), do: GenServer.call(__MODULE__, {:issue, context})
  def take(token), do: GenServer.call(__MODULE__, {:take, token})
  def discard(token), do: GenServer.cast(__MODULE__, {:discard, token})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:issue, context}, _from, contexts) do
    token = make_ref()
    {:reply, token, Map.put(contexts, token, context)}
  end

  def handle_call({:take, token}, _from, contexts) do
    case Map.fetch(contexts, token) do
      :error -> {:reply, :error, contexts}
      {:ok, context} -> {:reply, {:ok, context}, Map.delete(contexts, token)}
    end
  end

  @impl true
  def handle_cast({:discard, token}, contexts), do: {:noreply, Map.delete(contexts, token)}
end
