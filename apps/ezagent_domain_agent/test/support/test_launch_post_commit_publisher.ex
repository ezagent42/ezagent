defmodule Ezagent.Agent.TestLaunchPostCommitPublisher do
  @behaviour Ezagent.Agent.LaunchPostCommitPublisher

  alias Ezagent.Agent.LaunchPostCommitPublisher.Production

  def inject(agent_uri, instruction, owner) do
    ensure_started()
    Agent.update(__MODULE__, &Map.put(&1, URI.to_string(agent_uri), {instruction, owner}))
  end

  def clear(agent_uri) do
    ensure_started()
    Agent.update(__MODULE__, &Map.delete(&1, URI.to_string(agent_uri)))
  end

  @impl true
  def publish(facts) do
    ensure_started()

    case Agent.get(__MODULE__, &Map.get(&1, URI.to_string(facts.agent_uri))) do
      {:raise_lineage_cache, owner} ->
        send(owner, {:lineage_cache_failed, facts.agent_uri})
        raise "injected lineage cache publication failure"

      nil ->
        Production.publish(facts)
    end
  end

  defp ensure_started do
    case Agent.start(fn -> %{} end, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
