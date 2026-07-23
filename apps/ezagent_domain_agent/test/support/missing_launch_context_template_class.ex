defmodule EzagentDomainAgent.TestSupport.MissingLaunchContextTemplateClass do
  @moduledoc false
  @behaviour Ezagent.Kind.Template

  @impl true
  def template_name, do: "test.missing_launch_context"

  @impl true
  def instantiate(_name, _data, _workspace_uri) do
    send(
      Application.fetch_env!(:ezagent_domain_agent, :pre_start_test_owner),
      :missing_arity_effect
    )

    {:error, :must_not_run}
  end
end
