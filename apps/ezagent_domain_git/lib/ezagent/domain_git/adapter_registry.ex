defmodule Ezagent.DomainGit.AdapterRegistry do
  @moduledoc """
  Domain-owned registry of provider identifiers to Git adapter modules.

  Registration is dependency injection only: it validates module declarations
  without invoking adapter callbacks. The registry stores only provider ids and
  module names; authorization, credentials, and provider effects belong elsewhere.
  """

  use GenServer

  alias Ezagent.DomainGit.Adapter

  @table :ezagent_domain_git_adapter_registry
  @provider_id ~r/^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$/

  @type provider_id :: String.t()
  @type registration_error ::
          {:invalid_provider_id, term()}
          | {:invalid_adapter_module, term()}
          | {:missing_behaviour, module()}
          | {:missing_callbacks, [{atom(), non_neg_integer()}]}
          | {:provider_conflict, provider_id(), module(), module()}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Registers a provider id and its validated adapter module."
  @spec register(term(), term()) ::
          :ok | {:ok, :already_registered} | {:error, registration_error()}
  def register(provider_id, adapter_module) do
    with :ok <- validate_provider_id(provider_id),
         :ok <- validate_adapter(adapter_module) do
      GenServer.call(__MODULE__, {:register, provider_id, adapter_module})
    end
  end

  @doc "Removes a declaration only when it still points at the given module."
  @spec unregister(provider_id(), module()) :: :ok
  def unregister(provider_id, adapter_module)
      when is_binary(provider_id) and is_atom(adapter_module),
      do: GenServer.call(__MODULE__, {:unregister, provider_id, adapter_module})

  @doc false
  @spec lookup_for_action_set(provider_id()) ::
          {:ok, module()} | :error | {:error, :registry_unavailable}
  def lookup_for_action_set(provider_id) when is_binary(provider_id),
    do: safe_read(fn -> lookup_entry(provider_id) end)

  def lookup_for_action_set(_provider_id), do: :error

  @doc false
  @spec list_for_diagnostics() ::
          {:ok, [%{provider_id: provider_id(), module: module()}]}
          | {:error, :registry_unavailable}
  def list_for_diagnostics, do: safe_read(&diagnostic_entries/0)

  @impl true
  def init([]) do
    table =
      :ets.new(@table, [
        :named_table,
        :protected,
        :set,
        read_concurrency: true
      ])

    {:ok, %{table: table}, {:continue, :notify_boot_registration}}
  end

  @impl true
  def handle_continue(:notify_boot_registration, state) do
    if registration = Process.whereis(Ezagent.DomainGit.BootRegistration),
      do: send(registration, :reconcile_adapters)

    {:noreply, state}
  end

  @impl true
  def handle_call({:register, provider_id, adapter_module}, _from, state) do
    reply =
      case :ets.lookup(@table, provider_id) do
        [] ->
          true = :ets.insert(@table, {provider_id, adapter_module})
          :ok

        [{^provider_id, ^adapter_module}] ->
          {:ok, :already_registered}

        [{^provider_id, existing_module}] ->
          {:error, {:provider_conflict, provider_id, existing_module, adapter_module}}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:unregister, provider_id, adapter_module}, _from, state) do
    case :ets.lookup(@table, provider_id) do
      [{^provider_id, ^adapter_module}] -> true = :ets.delete(@table, provider_id)
      _ -> :ok
    end

    {:reply, :ok, state}
  end

  defp validate_provider_id(provider_id) when is_binary(provider_id) do
    if Regex.match?(@provider_id, provider_id) do
      :ok
    else
      {:error, {:invalid_provider_id, provider_id}}
    end
  end

  defp validate_provider_id(provider_id), do: {:error, {:invalid_provider_id, provider_id}}

  defp validate_adapter(adapter_module) when is_atom(adapter_module) do
    with {_file, _load_type} <- :code.is_loaded(adapter_module),
         :ok <- validate_behaviour(adapter_module),
         :ok <- validate_callbacks(adapter_module) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _not_loaded -> {:error, {:invalid_adapter_module, adapter_module}}
    end
  end

  defp validate_adapter(adapter_module),
    do: {:error, {:invalid_adapter_module, adapter_module}}

  defp validate_behaviour(adapter_module) do
    behaviours =
      adapter_module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    if Adapter in behaviours do
      :ok
    else
      {:error, {:missing_behaviour, adapter_module}}
    end
  end

  defp validate_callbacks(adapter_module) do
    missing =
      Adapter.behaviour_info(:callbacks)
      |> Enum.reject(fn {name, arity} -> function_exported?(adapter_module, name, arity) end)
      |> Enum.sort()

    if missing == [] do
      :ok
    else
      {:error, {:missing_callbacks, missing}}
    end
  end

  defp lookup_entry(provider_id) do
    case :ets.lookup(@table, provider_id) do
      [{^provider_id, adapter_module}] -> {:ok, adapter_module}
      [] -> :error
    end
  end

  defp diagnostic_entries do
    entries =
      @table
      |> :ets.tab2list()
      |> Enum.map(fn {provider_id, adapter_module} ->
        %{provider_id: provider_id, module: adapter_module}
      end)
      |> Enum.sort_by(& &1.provider_id)

    {:ok, entries}
  end

  defp safe_read(read) do
    if :ets.whereis(@table) == :undefined do
      {:error, :registry_unavailable}
    else
      read.()
    end
  rescue
    ArgumentError -> {:error, :registry_unavailable}
  end
end
