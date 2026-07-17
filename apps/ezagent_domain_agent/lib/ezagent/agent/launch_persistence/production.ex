defmodule Ezagent.Agent.LaunchPersistence.Production do
  @moduledoc false

  @behaviour Ezagent.Agent.LaunchPersistence

  alias Ezagent.Agent.CreationInventory

  @impl true
  def before_transaction(_facts), do: :ok

  @impl true
  def persist(repo, facts) do
    with {:ok, _} <- record_inventory(repo, facts),
         {:ok, _} <- Ezagent.AgentLineage.record_exact(repo, facts.agent_uri, facts.root_uri) do
      {:ok,
       %{
         attempt_id: facts.attempt_id,
         agent_uri: facts.agent_uri,
         root_uri: facts.root_uri,
         workspace_uri: facts.workspace_uri
       }}
    end
  end

  @doc false
  def record_inventory(repo, facts) do
    CreationInventory.record_exact(
      repo,
      facts.attempt_id,
      facts.agent_uri,
      facts.root_uri,
      facts.workspace_uri
    )
  end
end
