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
    instantiate_with_opts(data, [])
  end

  @impl true
  def instantiate(_name, data, _workspace_uri, launch_context: launch_context) do
    instantiate_with_opts(data, launch_context: launch_context)
  end

  defp instantiate_with_opts(data, opts) do
    send(Application.fetch_env!(:ezagent_domain_workspace, :sidecar_gate_test_owner), {
      :instantiate_called,
      data
    })

    agent_uri = Ezagent.URI.new!(Map.fetch!(data, "agent_uri"))

    with {:ok, status, _pid} <- Ezagent.LocalRuntime.ensure_started_detailed(agent_uri, opts) do
      {:ok, [agent_uri], %{fresh?: status == :started}}
    end
  end
end
