defmodule Ezagent.DomainGit.WorkspaceProvisionRegistry do
  @moduledoc """
  Owns the single workspace provision implementation registration.

  Registration validates the implementation contract without executing any
  implementation callback. Authorization belongs to the calling action set.
  """

  use GenServer

  alias Ezagent.DomainGit.WorkspaceProvisionPort

  @type registration_error ::
          :conflicting_workspace_provisioner
          | {:invalid_workspace_provisioner, term()}
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

  @doc "Returns the registered implementation for the authorized action set."
  @spec implementation() :: {:ok, module()} | {:error, :workspace_provisioner_not_registered}
  def implementation, do: GenServer.call(__MODULE__, :implementation)

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
    do: {:reply, {:error, :conflicting_workspace_provisioner}, registered}

  def handle_call(:implementation, _from, nil),
    do: {:reply, {:error, :workspace_provisioner_not_registered}, nil}

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
        {:error, {:invalid_workspace_provisioner, implementation}}
    end
  end

  defp validate_implementation(implementation),
    do: {:error, {:invalid_workspace_provisioner, implementation}}

  defp validate_behaviour(implementation) do
    behaviours =
      implementation.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    if WorkspaceProvisionPort in behaviours do
      :ok
    else
      {:error, {:missing_behaviour, implementation}}
    end
  end

  defp validate_callbacks(implementation) do
    missing =
      WorkspaceProvisionPort.behaviour_info(:callbacks)
      |> Enum.reject(fn {name, arity} -> function_exported?(implementation, name, arity) end)
      |> Enum.sort()

    if missing == [], do: :ok, else: {:error, {:missing_callbacks, missing}}
  end
end
