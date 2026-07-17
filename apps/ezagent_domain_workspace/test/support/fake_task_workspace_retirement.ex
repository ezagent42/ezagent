defmodule EzagentDomainWorkspace.TestSupport.FakeTaskWorkspaceRetirement do
  @moduledoc false

  def retire(row) do
    owner = Application.fetch_env!(:ezagent_domain_workspace, :provisioner_test_owner)
    send(owner, {:retire_agent, row.agent_uri, row.creation_attempt_id})

    Application.get_env(:ezagent_domain_workspace, :task_workspace_retirement_hook, fn -> :ok end).()

    Application.get_env(:ezagent_domain_workspace, :task_workspace_retirement_result, :ok)
  end
end
