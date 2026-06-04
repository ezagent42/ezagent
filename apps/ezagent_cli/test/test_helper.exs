ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)

# CLI tests exercise TreeBuilder + Dispatch which depend on plugins
# (chat, echo) having registered their Behaviors at boot. ezagent_cli's
# mix deps don't include those (CLI is supposed to be transport-only),
# so explicitly start them here.
for app <- [:ezagent_domain_instance_message, :ezagent_plugin_echo, :ezagent_plugin_cc, :ezagent_plugin_cc, :ezagent_plugin_feishu] do
  case Application.ensure_all_started(app) do
    {:ok, _} -> :ok
    {:error, _} -> :ok
  end
end
