defmodule Ezagent.Orchestrator.CcOrchestratorSeedFlavorTest do
  use EzagentCore.DataCase, async: false

  # The orchestrator→cc-custom switch: the cc-orchestrator AgentTemplate seed now
  # populates `flavor: "cc-custom"` + `provider: "deepseek"` (cc-custom-backends
  # PR-5; #1324's vendor-specific cc-deepseek flavor is retired) so orchestrators
  # authenticate via DEEPSEEK_API_KEY — no host `~/.claude` OAuth login, no #161
  # co-tenant credential issue, and they boot authenticated (no exit-256 from a
  # missing login). The profile NAME rides the seeded content into template data
  # (the credential stays the env var the catalog names); cc-custom reuses the cc
  # config namespace, so `.mcp.json` generation is unchanged.
  #
  # It also drops `mcp_config_path` from the seeded content: the orchestrator MCP
  # server now lives in the per-agent `.mcp.json` (`McpConfigWriter`), NOT a
  # separate `orchestrator.mcp.json` threaded as a shadowing additive
  # `--mcp-config` (`operator_mcp_config_path`).

  alias Ezagent.Entity.AgentTemplate
  alias Ezagent.Orchestrator.CcOrchestratorSeed

  defp uniq, do: System.unique_integer([:positive])

  setup do
    base = Path.join(System.tmp_dir!(), "cc-orch-seed-flavor-test-#{uniq()}")
    previous = Application.get_env(:ezagent_plugin_cc, :cc_orchestrator_sandbox_base)
    Application.put_env(:ezagent_plugin_cc, :cc_orchestrator_sandbox_base, base)

    on_exit(fn ->
      if previous do
        Application.put_env(:ezagent_plugin_cc, :cc_orchestrator_sandbox_base, previous)
      else
        Application.delete_env(:ezagent_plugin_cc, :cc_orchestrator_sandbox_base)
      end

      File.rm_rf(base)
    end)

    :ok
  end

  test "seed populates the cc-orchestrator AgentTemplate with flavor cc-custom" do
    assert :ok = CcOrchestratorSeed.seed()

    assert {:ok, %{template_uri: uri, template_content: content}} =
             CcOrchestratorSeed.seed_status()

    assert uri == CcOrchestratorSeed.template_uri()
    assert content.flavor == "cc-custom"
    assert content.provider == "deepseek"
    assert content.role == "orchestrator"

    # `mcp_config_path` is no longer seeded — the orchestrator MCP server is in
    # the per-agent `.mcp.json`, so no second, shadowing `--mcp-config` path.
    refute Map.has_key?(content, :mcp_config_path)
  end

  test "the cc-custom content resolves to the cc_custom Template Class with no shadowing mcp path" do
    assert :ok = CcOrchestratorSeed.seed()
    assert {:ok, %{template_content: content}} = CcOrchestratorSeed.seed_status()

    agent_uri = %{Ezagent.URI.user(:system, "not-used") | path: "/agent/cc_custom_orch_seed"}

    assert {:ok, data} = AgentTemplate.to_template_data(content, agent_uri)

    # flavor "cc-custom" → the provider-configurable cc_custom Template Class;
    # the "deepseek" profile NAME rides template data (never the key itself).
    assert data["class"] == "cc_custom.agent"
    assert data["provider"] == "deepseek"
    assert data["role"] == "orchestrator"

    # No additive `--mcp-config` is threaded (nil extra is dropped) — the
    # generated `.mcp.json` is the single owner of the orchestrator server.
    refute Map.has_key?(data, "operator_mcp_config_path")
  end
end
