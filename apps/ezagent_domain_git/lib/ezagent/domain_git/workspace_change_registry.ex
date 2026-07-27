defmodule Ezagent.DomainGit.WorkspaceChangeRegistry do
  @moduledoc """
  Owns the single workspace-change collection implementation registration.

  Registration validates the implementation contract without executing any
  implementation callback. Structurally mirrors
  `Ezagent.DomainGit.WorkspaceProvisionRegistry` for the orthogonal
  `WorkspaceChangePort` contract — collection is a separate concern from
  provisioning `prepare`/`cleanup` (design §4.2/§4.3), so it gets its own
  port and its own single-implementation registry rather than a third
  callback bolted onto `WorkspaceProvisionPort`.
  """

  use GenServer

  alias Ezagent.DomainGit.WorkspaceChangePort

  @type registration_error ::
          :conflicting_workspace_change_collector
          | {:invalid_workspace_change_collector, term()}
          | {:missing_behaviour, module()}
          | {:missing_callbacks, [{atom(), non_neg_integer()}]}

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Registers the sole conforming implementation, idempotently."
  @spec register(term()) :: :ok | {:error, registration_error()}
  def register(implementation) do
    GenServer.call(__MODULE__, {:register, implementation})
  end

  @doc "Returns the registered implementation."
  @spec implementation() :: {:ok, module()} | {:error, :workspace_change_collector_not_registered}
  def implementation, do: GenServer.call(__MODULE__, :implementation)

  if Mix.env() == :test do
    @doc false
    def replace_for_test(implementation) do
      GenServer.call(__MODULE__, {:replace_for_test, implementation})
    end
  end

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call({:register, implementation}, _from, nil) do
    case validate_implementation(implementation) do
      :ok -> {:reply, :ok, implementation}
      {:error, _reason} = error -> {:reply, error, nil}
    end
  end

  def handle_call({:register, implementation}, _from, implementation),
    do: {:reply, :ok, implementation}

  def handle_call({:register, _implementation}, _from, registered),
    do: {:reply, {:error, :conflicting_workspace_change_collector}, registered}

  if Mix.env() == :test do
    def handle_call({:replace_for_test, nil}, _from, _registered),
      do: {:reply, :ok, nil}

    def handle_call({:replace_for_test, implementation}, _from, registered) do
      case validate_implementation(implementation) do
        :ok -> {:reply, :ok, implementation}
        {:error, _reason} = error -> {:reply, error, registered}
      end
    end
  end

  def handle_call(:implementation, _from, nil),
    do: {:reply, {:error, :workspace_change_collector_not_registered}, nil}

  def handle_call(:implementation, _from, implementation),
    do: {:reply, {:ok, implementation}, implementation}

  defp validate_implementation(implementation) when is_atom(implementation) do
    case Code.ensure_loaded(implementation) do
      {:module, ^implementation} ->
        with :ok <- validate_behaviour(implementation),
             :ok <- validate_callbacks(implementation) do
          :ok
        end

      {:error, _reason} ->
        {:error, {:invalid_workspace_change_collector, implementation}}
    end
  end

  defp validate_implementation(implementation),
    do: {:error, {:invalid_workspace_change_collector, implementation}}

  defp validate_behaviour(implementation) do
    behaviours =
      implementation.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    if WorkspaceChangePort in behaviours do
      :ok
    else
      {:error, {:missing_behaviour, implementation}}
    end
  end

  defp validate_callbacks(implementation) do
    missing =
      WorkspaceChangePort.behaviour_info(:callbacks)
      |> Enum.reject(fn {name, arity} -> function_exported?(implementation, name, arity) end)
      |> Enum.sort()

    if missing == [], do: :ok, else: {:error, {:missing_callbacks, missing}}
  end
end
