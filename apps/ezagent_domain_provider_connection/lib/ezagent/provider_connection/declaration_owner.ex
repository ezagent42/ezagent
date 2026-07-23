defmodule Ezagent.ProviderConnection.DeclarationOwner do
  @moduledoc """
  Lifecycle owner for one immutable driver/backend-pair declaration batch.

  The owner subscribes to registry generations and restores its exact rows
  after either supervised runtime index restarts. It makes no cross-registry
  atomicity claim: a missing side remains explicitly unavailable to lookups.
  Drift stops the owner loudly after removing only this owner's rows.
  """

  use GenServer

  alias Ezagent.ProviderConnection.BackendPairRegistry
  alias Ezagent.ProviderConnection.DriverRegistry
  alias Ezagent.ProviderConnection.RegistryReadiness

  @type generations :: %{driver: non_neg_integer(), backend_pair: non_neg_integer()}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    owner = Keyword.fetch!(opts, :owner)

    %{
      id: {__MODULE__, owner},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Returns the registry generations last reconciled by this owner."
  @spec generation(GenServer.server()) :: generations()
  def generation(server), do: GenServer.call(server, :generation)

  @doc "Waits without polling until both requested generations are reconciled."
  @spec await_generation(GenServer.server(), generations()) :: :ok
  def await_generation(server, generations),
    do: GenServer.call(server, {:await_generation, generations}, :infinity)

  @impl true
  def init(opts) do
    {:ok, generations} = RegistryReadiness.subscribe()

    state = %{
      owner: Keyword.fetch!(opts, :owner),
      drivers: Keyword.get(opts, :drivers, []),
      backend_pairs: Keyword.get(opts, :backend_pairs, []),
      generations: generations,
      reconciled: %{driver: 0, backend_pair: 0},
      waiters: []
    }

    case reconcile(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    unregister_owned(state.owner)
    :ok
  end

  @impl true
  def handle_call(:generation, _from, state), do: {:reply, state.reconciled, state}

  def handle_call({:await_generation, requested}, from, state) do
    if reached?(state.reconciled, requested) do
      {:reply, :ok, state}
    else
      {:noreply, %{state | waiters: [{requested, from} | state.waiters]}}
    end
  end

  @impl true
  def handle_info({:provider_registry_ready, kind, _pid, generation}, state) do
    state = put_in(state.generations[kind], generation)

    case reconcile(state) do
      {:ok, state} -> {:noreply, reply_waiters(state)}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  defp reconcile(state) do
    with :ok <- DriverRegistry.register_all(state.owner, state.drivers),
         :ok <- BackendPairRegistry.register_all(state.owner, state.backend_pairs) do
      {:ok, %{state | reconciled: state.generations}}
    else
      {:error, reason} ->
        unregister_owned(state.owner)
        {:error, {:provider_declaration_drift, reason}}
    end
  catch
    :exit, reason -> {:error, {:provider_registry_unavailable, reason}}
  end

  defp unregister_owned(owner) do
    DriverRegistry.unregister_owner(owner)
    BackendPairRegistry.unregister_owner(owner)
  end

  defp reached?(actual, requested) do
    actual.driver >= requested.driver and actual.backend_pair >= requested.backend_pair
  end

  defp reply_waiters(state) do
    {ready, waiting} =
      Enum.split_with(state.waiters, fn {requested, _from} ->
        reached?(state.reconciled, requested)
      end)

    Enum.each(ready, fn {_requested, from} -> GenServer.reply(from, :ok) end)
    %{state | waiters: waiting}
  end
end
