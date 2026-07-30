# Chat's mention-routing + agent-flavor tests assume the echo plugin
# is alive so `entity://agent/<ws>/echo_<n>` URIs resolve via
# `Ezagent.AgentFlavorRegistry.lookup("echo")`. When the chat app is
# tested standalone (`mix cmd --app ezagent_domain_session`), only chat's
# direct deps auto-start — echo is a SIBLING umbrella app, not a dep.
#
# Prepend every umbrella sibling's ebin to the BEAM code path then
# Application.ensure_all_started so the .app metadata can be loaded
# and the supervision tree boots. Same pattern as
# `apps/ezagent_domain_external_mirror/test/test_helper.exs`.
umbrella_lib = Path.expand("../../../_build/#{Mix.env()}/lib", __DIR__)

if File.dir?(umbrella_lib) do
  for sibling <- File.ls!(umbrella_lib) do
    ebin = Path.join([umbrella_lib, sibling, "ebin"])
    if File.dir?(ebin), do: Code.prepend_path(ebin)
  end
end

# py and cc plugin startup here is test-boundary setup, not a
# production domain dependency. py registers the "py" flavor + PyAgent
# Kind module; cc registers the "cc" Agent flavor and Template Class
# used by orchestrator integration tests.
for app <- [:ezagent_plugin_py, :ezagent_plugin_cc] do
  {:ok, _} = Application.ensure_all_started(app)
end

Code.require_file("support/agent_bridge_test_adapter.exs", __DIR__)

unless Code.ensure_loaded?(Ezagent.TestSupport.TemplateAgentSpawn) do
  support_root = Path.expand("../../../test/support", __DIR__)
  Code.require_file("ezagent_noop_agent_template.ex", support_root)
  Code.require_file("ezagent_template_agent_spawn.ex", support_root)
end

# `:real_boot_seed_path` tests drive the REAL boot seed and mutate VM-global
# singletons (the genesis admin) — safe standalone, sibling-corrupting in the
# shared suite. Excluded by default; run with `--include real_boot_seed_path`.
ExUnit.start(exclude: [:real_boot_seed_path])
