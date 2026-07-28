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
    send(Application.fetch_env!(:ezagent_domain_workspace, :sidecar_gate_test_owner), {
      :launch_context_received,
      launch_context
    })

    instantiate_with_opts(data, launch_context: launch_context)
  end

  defp instantiate_with_opts(data, opts) do
    send(Application.fetch_env!(:ezagent_domain_workspace, :sidecar_gate_test_owner), {
      :instantiate_called,
      data
    })

    agent_uri = Ezagent.URI.new!(Map.fetch!(data, "agent_uri"))

    case Ezagent.KindRegistry.lookup(agent_uri) do
      {:ok, _pid} ->
        {:ok, [agent_uri], %{fresh?: false}}

      :error ->
        case Ezagent.Kind.spawn_receipt(Ezagent.Entity.Agent, %{uri: agent_uri}, opts) do
          {:ok, :started, _pid, %{created?: created?}} ->
            if Application.get_env(:ezagent_domain_workspace, :atomic_sidecar_failure, false) do
              send(Application.fetch_env!(:ezagent_domain_workspace, :sidecar_gate_test_owner), {
                :sidecar_failed_after_receipt,
                agent_uri
              })

              {:error, :injected_sidecar_failure}
            else
              {:ok, [agent_uri], %{fresh?: true, created?: created?}}
            end

          {:ok, :already_started, _pid, _receipt} ->
            {:ok, [agent_uri], %{fresh?: false}}

          {:error, {:already_registered, _pid}} ->
            {:ok, [agent_uri], %{fresh?: false}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end
end
