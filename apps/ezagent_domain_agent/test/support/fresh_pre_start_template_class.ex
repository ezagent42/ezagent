defmodule EzagentDomainAgent.TestSupport.FreshPreStartTemplateClass do
  @moduledoc false
  @behaviour Ezagent.Kind.Template

  @impl true
  def template_name, do: "test.fresh_pre_start_agent"

  @impl true
  def instantiate(_name, data, _workspace_uri) do
    owner = Application.fetch_env!(:ezagent_domain_agent, :fresh_pre_start_owner)
    worker = Ezagent.URI.new!(Map.fetch!(data, "agent_uri"))
    send(owner, {:instantiate_called, worker})

    with {:ok, _pid} <- Ezagent.LocalRuntime.ensure_started(worker) do
      {:ok, [worker], %{fresh?: true}}
    end
  end
end
