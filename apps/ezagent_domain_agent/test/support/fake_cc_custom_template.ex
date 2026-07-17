defmodule Ezagent.Agent.FakeCcCustomTemplate do
  @moduledoc false

  # Test-only stand-in for the real `Ezagent.PluginCc.Template.CcCustomAgent`
  # credential contract (ezagent_plugin_cc is NOT a domain_agent dependency, so
  # the real class is unavailable here). Mirrors that contract exactly:
  #
  #   * env-backed credential — NO on-disk credential files
  #     (`credential_relpaths/0 == []`, `secret_relpaths/0 == []`), so
  #     `CredentialAdapter.credentialled?/1` is true while
  #     `CredentialPrecondition.check_source/4` routes to the ENVIRONMENT branch;
  #   * `credential_status/2` is profile-driven via the `:backend_profile` opt:
  #     `"kimi"` classifies on `MOONSHOT_API_KEY` (the catalog's kimi env var),
  #     absent/unknown profile → `:unknown` (fail closed, never an alarm).
  #
  # Registered as the `"cc-custom"` flavor by the tests that use it. The
  # registration declaration (`kind` + `template_class`) must stay IDENTICAL at
  # every registration site — `AgentFlavorRegistry.register/1` raises on a
  # divergent re-registration.
  @behaviour Ezagent.Agent.CredentialAdapter

  @kimi_env "MOONSHOT_API_KEY"

  # Mirror the real class's `config_dir_namespace/0` (cc-custom reuses cc's
  # namespace) so `RecipeMaterializer.config_dir_ref/2` resolves.
  def config_dir_namespace, do: "cc"

  @impl Ezagent.Agent.CredentialAdapter
  def credential_env_var, do: @kimi_env

  @impl Ezagent.Agent.CredentialAdapter
  def credential_relpaths, do: []

  @impl Ezagent.Agent.CredentialAdapter
  def secret_relpaths, do: []

  @impl Ezagent.Agent.CredentialAdapter
  def auth_failure_signals, do: []

  @impl Ezagent.Agent.CredentialAdapter
  def credential_status(_home, opts) do
    case Keyword.get(opts, :backend_profile) do
      "kimi" -> kimi_status()
      _ -> %{status: :unknown, detail: nil, expires_at: nil}
    end
  end

  defp kimi_status do
    case System.get_env(@kimi_env) do
      key when is_binary(key) and key != "" ->
        %{status: :authenticated, detail: nil, expires_at: nil}

      _ ->
        %{status: :missing, detail: "#{@kimi_env} not set", expires_at: nil}
    end
  end
end
