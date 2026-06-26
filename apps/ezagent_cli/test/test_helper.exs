ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)

unless Code.ensure_loaded?(Ezagent.TestSupport.TemplateAgentSpawn) do
  support_root = Path.expand("../../../test/support", __DIR__)
  Code.require_file("ezagent_noop_agent_template.ex", support_root)
  Code.require_file("ezagent_template_agent_spawn.ex", support_root)
end

# CLI tests exercise TreeBuilder + Dispatch which depend on plugins
# (chat, py) having registered their Behaviors at boot. ezagent_cli's
# mix deps don't include those (CLI is supposed to be transport-only),
# so explicitly start them here.
for app <- [
      :ezagent_domain_session,
      :ezagent_plugin_py,
      :ezagent_plugin_cc,
      :ezagent_plugin_cc,
      :ezagent_plugin_feishu
    ] do
  case Application.ensure_all_started(app) do
    {:ok, _} -> :ok
    {:error, _} -> :ok
  end
end
