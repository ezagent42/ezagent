defmodule EzagentDomainAgent.TestSupport.FreshPreStartTemplateClass do
  @moduledoc false
  @behaviour Ezagent.Kind.Template

  @impl true
  def template_name, do: "test.fresh_pre_start_agent"

  @impl true
  def instantiate(_name, data, _workspace_uri) do
    instantiate_with_opts(data, [])
  end

  @impl true
  def instantiate(_name, data, _workspace_uri, launch_context: launch_context) do
    instantiate_with_opts(data, launch_context: launch_context)
  end

  defp instantiate_with_opts(data, opts) do
    owner = Application.fetch_env!(:ezagent_domain_agent, :fresh_pre_start_owner)
    worker = Ezagent.URI.new!(Map.fetch!(data, "agent_uri"))
    send(owner, {:instantiate_called, worker})

    case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: worker}, opts) do
      {:ok, _pid} -> {:ok, [worker], %{fresh?: true}}
      {:error, reason} -> {:error, reason}
    end
  end
end
