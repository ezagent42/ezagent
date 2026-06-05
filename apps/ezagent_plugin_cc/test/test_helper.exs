ExUnit.start()

unless Code.ensure_loaded?(Ezagent.TestSupport.TemplateAgentSpawn) do
  support_root = Path.expand("../../../test/support", __DIR__)
  Code.require_file("ezagent_noop_agent_template.ex", support_root)
  Code.require_file("ezagent_template_agent_spawn.ex", support_root)
end

# PR #146: enable Sandbox manual mode so tests that spawn Kinds with
# `persistence :on_terminate` (e.g. `Ezagent.Entity.Agent` in
# pty_input_dispatch_test) can check out a DB connection via
# `EzagentCore.DataCase`.
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)
