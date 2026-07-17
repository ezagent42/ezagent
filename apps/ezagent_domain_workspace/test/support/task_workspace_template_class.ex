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
    fresh? = Application.get_env(:ezagent_domain_workspace, :sidecar_gate_fresh?, true)

    with {:ok, _pid} <- Ezagent.LocalRuntime.ensure_started(agent_uri) do
      {:ok, [agent_uri], %{fresh?: fresh?}}
    end
  end
end
