defmodule EzagentDomainInstanceMessage.Test.OrchestratorBindingMissingCredentialTemplate do
  @moduledoc false

  @behaviour Ezagent.Kind.Template

  @impl Ezagent.Kind.Template
  def template_name, do: "orchestrator_binding.missing_credential"

  @impl Ezagent.Kind.Template
  def validate(_), do: :ok

  @impl Ezagent.Kind.Template
  def instantiate(_name, _data, _workspace_uri), do: {:error, :must_not_spawn_without_credentials}

  def credential_relpaths, do: ["credentials.json"]
  def credential_env_var, do: "ORCHESTRATOR_BINDING_TEST_HOME"
  def secret_relpaths, do: ["credentials.json"]
  def auth_failure_signals, do: []
end
