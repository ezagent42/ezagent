defmodule EzagentDomainWorkspace.TestSupport.TaskWorkspaceTemplateClass do
  @moduledoc false

  @behaviour Ezagent.Kind.Template

  @impl true
  def template_name, do: "test.task_workspace_agent"

  @impl true
  def validate(_data), do: :ok

  @impl true
  def template_data_extra(_content), do: %{}

  @impl true
  def instantiate(_name, data, _workspace_uri) do
    send(Application.fetch_env!(:ezagent_domain_workspace, :sidecar_gate_test_owner), {
      :instantiate_called,
      data
    })

    agent_uri = Ezagent.URI.new!(Map.fetch!(data, "agent_uri"))
    owner_uri = Application.fetch_env!(:ezagent_domain_workspace, :sidecar_gate_test_provenance)
    workspace_uri = Ezagent.URI.workspace_of(agent_uri)
    attempt_id = Ezagent.Agent.CreationInventory.new_attempt_id()
    :ok = Ezagent.AgentLineage.record(agent_uri, owner_uri)
    :ok = Ezagent.WorkspaceRegistry.bind(agent_uri, workspace_uri)
    :ok = Ezagent.Agent.CreationInventory.record(attempt_id, agent_uri, owner_uri, workspace_uri)

    {:ok, [agent_uri], %{fresh?: false}}
  end
end
