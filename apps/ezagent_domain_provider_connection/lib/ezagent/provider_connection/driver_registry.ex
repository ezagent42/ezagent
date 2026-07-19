defmodule Ezagent.ProviderConnection.DriverRegistry do
  @moduledoc """
  Supervised runtime index for immutable provider driver declarations.

  This registry does not claim atomicity with Domain Git. `availability/4`
  therefore reports partial declarations explicitly and validates the stable
  provider declaration fingerprint supplied by the Domain Git side.
  """

  use GenServer

  alias Ezagent.ProviderConnection.BackendPairRegistry
  alias Ezagent.ProviderConnection.Driver
  alias Ezagent.ProviderConnection.RegistryReadiness

  @table :ezagent_provider_connection_drivers

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Registers one driver declaration under an owner."
  @spec register(term(), Driver.t()) ::
          :acquired | :existing_identical | {:error, {:declaration_drift, String.t(), String.t()}}
  def register(owner, %Driver{} = driver),
    do: GenServer.call(__MODULE__, {:register, owner, driver})

  @doc "Registers a batch, rolling back ownership acquired by a failed batch."
  @spec register_all(term(), [Driver.t()]) ::
          :ok | {:error, {:declaration_drift, String.t(), String.t()}}
  def register_all(owner, drivers) when is_list(drivers),
    do: GenServer.call(__MODULE__, {:register_all, owner, drivers})

  @doc "Drops only registrations held by `owner`."
  @spec unregister_owner(term()) :: :ok
  def unregister_owner(owner) do
    GenServer.call(__MODULE__, {:unregister_owner, owner})
  catch
    :exit, _reason -> :ok
  end

  @doc "Looks up a driver by exact provider and acquisition-method strings."
  @spec lookup(String.t(), String.t()) :: {:ok, Driver.t()} | :error
  def lookup(provider_id, acquisition_method)
      when is_binary(provider_id) and is_binary(acquisition_method) do
    key = {provider_id, acquisition_method}

    case :ets.lookup(@table, key) do
      [{^key, driver, _owners}] -> {:ok, driver}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "Returns an explicit available, partial-unavailable, drift, or untested-pair result."
  @spec availability(String.t(), String.t(), String.t(), map() | :unavailable) ::
          {:available, map()}
          | {:unavailable, map()}
          | {:error, :provider_declaration_drift | :untested_backend_pair}
  def availability(provider_id, acquisition_method, pair_id, git_declaration)
      when is_binary(provider_id) and is_binary(acquisition_method) and is_binary(pair_id) do
    driver = lookup(provider_id, acquisition_method)
    pair = BackendPairRegistry.lookup(pair_id)

    with :ok <- validate_git_declaration(git_declaration),
         :ok <- validate_pair_membership(driver, pair_id),
         :ok <- validate_git_parity(driver, git_declaration) do
      availability_result(driver, pair, git_status(git_declaration))
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    :ok = RegistryReadiness.ready(:driver, self())
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, owner, driver}, _from, state) do
    {result, _owner_added?} = put_driver(owner, driver)
    {:reply, result, state}
  end

  def handle_call({:register_all, owner, drivers}, _from, state) do
    case register_batch(owner, drivers, []) do
      :ok ->
        {:reply, :ok, state}

      {:error, reason, acquired_keys} ->
        Enum.each(acquired_keys, &remove_owner_from_key(owner, &1))
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unregister_owner, owner}, _from, state) do
    @table
    |> :ets.tab2list()
    |> Enum.each(fn {key, _driver, _owners} -> remove_owner_from_key(owner, key) end)

    {:reply, :ok, state}
  end

  defp register_batch(_owner, [], _acquired_keys), do: :ok

  defp register_batch(owner, [%Driver{} = driver | rest], acquired_keys) do
    key = {driver.provider_id, driver.acquisition_method}

    case put_driver(owner, driver) do
      {_result, true} -> register_batch(owner, rest, [key | acquired_keys])
      {{:error, reason}, false} -> {:error, reason, acquired_keys}
      {_result, false} -> register_batch(owner, rest, acquired_keys)
    end
  end

  defp put_driver(owner, driver) do
    with :ok <- Driver.verify_fingerprint(driver) do
      put_verified_driver(owner, driver)
    else
      {:error, reason} -> {{:error, reason}, false}
    end
  end

  defp put_verified_driver(owner, driver) do
    key = {driver.provider_id, driver.acquisition_method}

    case :ets.lookup(@table, key) do
      [] ->
        true = :ets.insert(@table, {key, driver, MapSet.new([owner])})
        {:acquired, true}

      [{^key, existing, owners}] when existing == driver ->
        owner_added? = not MapSet.member?(owners, owner)
        true = :ets.insert(@table, {key, existing, MapSet.put(owners, owner)})
        {:existing_identical, owner_added?}

      [{^key, existing, _owners}] ->
        {{:error, {:declaration_drift, existing.fingerprint, driver.fingerprint}}, false}
    end
  end

  defp remove_owner_from_key(owner, key) do
    case :ets.lookup(@table, key) do
      [{^key, driver, owners}] ->
        updated = MapSet.delete(owners, owner)

        if MapSet.size(updated) == 0 do
          :ets.delete(@table, key)
        else
          :ets.insert(@table, {key, driver, updated})
        end

      [] ->
        true
    end
  end

  defp validate_pair_membership(:error, _pair_id), do: :ok

  defp validate_pair_membership({:ok, driver}, pair_id) do
    if pair_id in driver.backend_pair_ids, do: :ok, else: {:error, :untested_backend_pair}
  end

  defp validate_git_declaration(:unavailable), do: :ok

  defp validate_git_declaration(%{
         provider_id: provider_id,
         provider_fingerprint: provider_fingerprint
       })
       when is_binary(provider_id) and byte_size(provider_id) > 0 and
              is_binary(provider_fingerprint) and byte_size(provider_fingerprint) > 0,
       do: :ok

  defp validate_git_declaration(_declaration), do: {:error, :provider_declaration_drift}

  defp validate_git_parity(:error, _git_declaration), do: :ok
  defp validate_git_parity(_driver, :unavailable), do: :ok

  defp validate_git_parity({:ok, driver}, %{
         provider_id: provider_id,
         provider_fingerprint: provider_fingerprint
       }) do
    if provider_id == driver.provider_id and provider_fingerprint == driver.provider_fingerprint do
      :ok
    else
      {:error, :provider_declaration_drift}
    end
  end

  defp validate_git_parity({:ok, _driver}, _declaration),
    do: {:error, :provider_declaration_drift}

  defp git_status(:unavailable), do: :missing
  defp git_status(%{}), do: :available

  defp availability_result({:ok, driver}, {:ok, pair}, :available),
    do: {:available, %{driver: driver, backend_pair: pair}}

  defp availability_result(driver, pair, git_status) do
    {:unavailable,
     %{
       driver: present?(driver),
       backend_pair: present?(pair),
       git_adapter: git_status
     }}
  end

  defp present?({:ok, _value}), do: :available
  defp present?(:error), do: :missing
end
