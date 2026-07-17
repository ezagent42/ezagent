defmodule Ezagent.Agent.LaunchPostCommitPublisher.Production do
  @moduledoc false

  @behaviour Ezagent.Agent.LaunchPostCommitPublisher

  alias Ezagent.Agent.LaunchAuthority

  @impl true
  def publish(facts) do
    :ok = Ezagent.AgentLineage.publish_cache(facts.agent_uri, facts.root_uri)
    :ok = Ezagent.WorkspaceRegistry.bind(facts.agent_uri, facts.workspace_uri)
    LaunchAuthority.acknowledge(facts.issuer_ref)
  end
end
