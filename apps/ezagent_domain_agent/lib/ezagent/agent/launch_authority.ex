defmodule Ezagent.Agent.LaunchAuthority do
  @moduledoc """
  Registered Agent-domain port for resolving and acknowledging trusted launches.

  Implementations live in an upper domain and are registered once at boot. The
  opaque launch handle is never inspected or persisted by this module.
  """

  use GenServer

  @callback resolve_launch(term(), URI.t()) ::
              {:ok,
               %{
                 attempt_id: String.t(),
                 agent_uri: URI.t(),
                 root_uri: URI.t(),
                 workspace_uri: URI.t(),
                 issuer_ref: term()
               }}
              | {:error, term()}
  @callback acknowledge_launch(term()) :: :ok | {:error, term()}

  @required_callbacks [resolve_launch: 2, acknowledge_launch: 1]

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, nil, Keyword.put_new(opts, :name, __MODULE__))

  @doc "Registers the sole trusted implementation. Re-registering it is idempotent."
  @spec register(module()) :: :ok | {:error, term()}
  def register(module) do
    with :ok <- validate_implementation(module) do
      GenServer.call(__MODULE__, {:register, module})
    end
  end

  @doc "Resolves an opaque handle for the exact Agent URI."
  @spec resolve(reference(), URI.t()) :: {:ok, map()} | {:error, term()}
  def resolve(handle, %URI{} = agent_uri) when is_reference(handle) do
    GenServer.call(__MODULE__, {:resolve, handle, agent_uri})
  end

  def resolve(handle, %URI{}) when not is_reference(handle), do: {:error, :invalid_launch_context}
  def resolve(_handle, _agent_uri), do: {:error, :invalid_agent_uri}

  @doc "Acknowledges successful consumption of the implementation-issued reference."
  @spec acknowledge({reference(), String.t()}) :: :ok | {:error, term()}
  def acknowledge({handle, claim} = issuer_ref) when is_reference(handle) and is_binary(claim) do
    GenServer.call(__MODULE__, {:acknowledge, issuer_ref})
  end

  def acknowledge(_issuer_ref), do: {:error, :invalid_launch_issuer_ref}

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call({:register, module}, _from, nil), do: {:reply, :ok, module}
  def handle_call({:register, module}, _from, module), do: {:reply, :ok, module}

  def handle_call({:register, _module}, _from, registered) do
    {:reply, {:error, {:already_registered, registered}}, registered}
  end

  def handle_call({:resolve, _handle, _uri}, _from, nil) do
    {:reply, {:error, :launch_authority_not_registered}, nil}
  end

  def handle_call({:resolve, handle, uri}, _from, module) do
    {:reply, module.resolve_launch(handle, uri), module}
  end

  def handle_call({:acknowledge, _issuer_ref}, _from, nil) do
    {:reply, {:error, :launch_authority_not_registered}, nil}
  end

  def handle_call({:acknowledge, issuer_ref}, _from, module) do
    {:reply, module.acknowledge_launch(issuer_ref), module}
  end

  defp validate_implementation(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and
         Enum.all?(@required_callbacks, fn {name, arity} ->
           function_exported?(module, name, arity)
         end),
       do: :ok,
       else: {:error, :invalid_launch_authority}
  end

  defp validate_implementation(_module), do: {:error, :invalid_launch_authority}
end
