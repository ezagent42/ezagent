defmodule EzagentPluginCodex.Orchestrator.CodexOrchestratorSeedTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.AgentTemplate
  alias Ezagent.Orchestrator.CodexOrchestratorSeed

  defp uniq, do: System.unique_integer([:positive])

  setup do
    base = Path.join(System.tmp_dir!(), "codex-orch-seed-test-#{uniq()}")
    previous = Application.get_env(:ezagent_plugin_codex, :codex_orchestrator_sandbox_base)
    Application.put_env(:ezagent_plugin_codex, :codex_orchestrator_sandbox_base, base)

    on_exit(fn ->
      if previous do
        Application.put_env(:ezagent_plugin_codex, :codex_orchestrator_sandbox_base, previous)
      else
        Application.delete_env(:ezagent_plugin_codex, :codex_orchestrator_sandbox_base)
      end

      File.rm_rf(base)
    end)

    :ok
  end

  test "seed writes a codex-native orchestrator AgentTemplate" do
    assert :ok = CodexOrchestratorSeed.seed()

    assert {:ok, %{template_uri: uri, template_content: content}} =
             CodexOrchestratorSeed.seed_status()

    assert uri == CodexOrchestratorSeed.template_uri()
    assert content.flavor == "codex"
    assert content.role == "orchestrator"
    assert content.project_cwd =~ "codex-orch-seed-test"
    assert File.exists?(Path.join(content.project_cwd, "AGENTS.md"))

    agent_uri = Ezagent.URI.user(:system, "not-used")
    agent_uri = %{agent_uri | path: "/agent/codex_orch_seed"}

    assert {:ok, data} = AgentTemplate.to_template_data(content, agent_uri)
    assert data["class"] == "codex.agent"
    assert data["role"] == "orchestrator"
    assert data["cwd"] == content.project_cwd
  end
end
