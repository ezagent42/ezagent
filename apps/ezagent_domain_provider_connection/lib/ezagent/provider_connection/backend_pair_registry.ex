defmodule Ezagent.ProviderConnection.BackendPairRegistry do
  @moduledoc """
  Supervised runtime index for immutable, conformance-tested backend pairs.

  Registration is owner-aware. An identical fingerprint is idempotent; a
  different fingerprint for the same stable pair id is declaration drift.
  """

  use GenServer

  alias Ezagent.ProviderConnection.BackendPair
  alias Ezagent.ProviderConnection.RegistryReadiness

  @table :ezagent_provider_connection_backend_pairs

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Registers one pair under a declaration owner."
  @spec register(term(), BackendPair.t()) ::
          :acquired | :existing_identical | {:error, {:declaration_drift, String.t(), String.t()}}
  def register(owner, %BackendPair{} = pair),
    do: GenServer.call(__MODULE__, {:register, owner, pair})

  @doc "Registers a batch, rolling back ownership acquired by a failed batch."
  @spec register_all(term(), [BackendPair.t()]) ::
          :ok | {:error, {:declaration_drift, String.t(), String.t()}}
  def register_all(owner, pairs) when is_list(pairs),
    do: GenServer.call(__MODULE__, {:register_all, owner, pairs})

  @doc "Drops only the registrations held by `owner`."
  @spec unregister_owner(term()) :: :ok
  def unregister_owner(owner) do
    GenServer.call(__MODULE__, {:unregister_owner, owner})
  catch
    :exit, _reason -> :ok
  end

  @doc "Looks up a pair by its exact stable pair id."
  @spec lookup(String.t()) :: {:ok, BackendPair.t()} | :error
  def lookup(pair_id) when is_binary(pair_id) do
    case :ets.lookup(@table, pair_id) do
      [{^pair_id, pair, _owners}] -> {:ok, pair}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "Accepts only the exact authorization/credential combination tested by a pair."
  @spec ensure_compatible(String.t(), String.t(), String.t()) ::
          :ok | {:error, :untested_backend_pair}
  def ensure_compatible(pair_id, authorization_backend_id, credential_backend_id) do
    with {:ok, pair} <- lookup(pair_id),
         true <- pair.authorization_backend.id == authorization_backend_id,
         true <- pair.credential_backend.id == credential_backend_id do
      :ok
    else
      _ -> {:error, :untested_backend_pair}
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    :ok = RegistryReadiness.ready(:backend_pair, self())
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, owner, pair}, _from, state) do
    {result, _owner_added?} = put_pair(owner, pair)
    {:reply, result, state}
  end

  def handle_call({:register_all, owner, pairs}, _from, state) do
    case register_batch(owner, pairs, []) do
      :ok ->
        {:reply, :ok, state}

      {:error, reason, acquired_ids} ->
        Enum.each(acquired_ids, &remove_owner_from_id(owner, &1))
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unregister_owner, owner}, _from, state) do
    @table
    |> :ets.tab2list()
    |> Enum.each(fn {pair_id, _pair, _owners} -> remove_owner_from_id(owner, pair_id) end)

    {:reply, :ok, state}
  end

  defp register_batch(_owner, [], _acquired_ids), do: :ok

  defp register_batch(owner, [%BackendPair{} = pair | rest], acquired_ids) do
    case put_pair(owner, pair) do
      {_result, true} -> register_batch(owner, rest, [pair.pair_id | acquired_ids])
      {{:error, reason}, false} -> {:error, reason, acquired_ids}
      {_result, false} -> register_batch(owner, rest, acquired_ids)
    end
  end

  defp put_pair(owner, pair) do
    with :ok <- BackendPair.verify_fingerprint(pair) do
      put_verified_pair(owner, pair)
    else
      {:error, reason} -> {{:error, reason}, false}
    end
  end

  defp put_verified_pair(owner, pair) do
    case :ets.lookup(@table, pair.pair_id) do
      [] ->
        true = :ets.insert(@table, {pair.pair_id, pair, MapSet.new([owner])})
        {:acquired, true}

      [{_pair_id, existing, owners}] when existing == pair ->
        owner_added? = not MapSet.member?(owners, owner)
        true = :ets.insert(@table, {pair.pair_id, existing, MapSet.put(owners, owner)})
        {:existing_identical, owner_added?}

      [{_pair_id, existing, _owners}] ->
        {{:error, {:declaration_drift, existing.fingerprint, pair.fingerprint}}, false}
    end
  end

  defp remove_owner_from_id(owner, pair_id) do
    case :ets.lookup(@table, pair_id) do
      [{^pair_id, pair, owners}] ->
        updated = MapSet.delete(owners, owner)

        if MapSet.size(updated) == 0 do
          :ets.delete(@table, pair_id)
        else
          :ets.insert(@table, {pair_id, pair, updated})
        end

      [] ->
        true
    end
  end
end
