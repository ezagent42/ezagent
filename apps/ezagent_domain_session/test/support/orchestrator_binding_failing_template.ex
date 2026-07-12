defmodule EzagentDomainInstanceMessage.Test.OrchestratorBindingFailingTemplate do
  @moduledoc false

  @behaviour Ezagent.Kind.Template

  @impl Ezagent.Kind.Template
  def template_name, do: "orchestrator_binding.failing"

  @impl Ezagent.Kind.Template
  def validate(_), do: :ok

  @impl Ezagent.Kind.Template
  def instantiate(_name, _data, _workspace_uri), do: {:error, :synthetic_orchestrator_failure}
end
