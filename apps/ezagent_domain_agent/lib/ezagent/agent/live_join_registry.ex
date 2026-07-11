defmodule Ezagent.Agent.LiveJoinRegistry do
  @moduledoc """
  Durable live transport-join state for bridge-backed agents.

  The key is the concrete `agent_uri`, not an orchestrator-specific URI. A row
  means the agent's live transport bridge has joined end-to-end in this BEAM.

  Every new row also casts a node-local edge to the transport-readiness
  listener. The durable ETS row remains the race-closing source of truth when
  the join lands before or during gate arming; PubSub is not used as an inbound
  control path.
  """

  @table :ezagent_agent_live_join_registry

  @doc false
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  @doc false
  @spec table() :: atom()
  def table, do: @table

  @doc false
  @spec mark_joined(URI.t()) :: :ok
  def mark_joined(%URI{} = agent_uri) do
    init()
    true = :ets.insert(@table, {URI.to_string(agent_uri), true})

    case Process.whereis(Ezagent.Agent.TransportReadinessListener) do
      pid when is_pid(pid) -> GenServer.cast(pid, {:live_joined, agent_uri})
      nil -> :ok
    end

    :ok
  end

  @doc false
  @spec joined?(URI.t()) :: boolean()
  def joined?(%URI{} = agent_uri) do
    init()

    case :ets.lookup(@table, URI.to_string(agent_uri)) do
      [{_, true}] -> true
      [] -> false
    end
  end

  @doc false
  @spec clear(URI.t()) :: :ok
  def clear(%URI{} = agent_uri) do
    init()
    :ets.delete(@table, URI.to_string(agent_uri))
    :ok
  end
end
