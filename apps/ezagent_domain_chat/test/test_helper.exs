# Chat's mention-routing + agent-flavor tests assume the echo plugin
# is alive so `entity://agent/<ws>/echo_<n>` URIs resolve via
# `Ezagent.AgentFlavorRegistry.lookup("echo")`. When the chat app is
# tested standalone (`mix cmd --app ezagent_domain_chat`), only chat's
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

# Echo plugin registers the "echo" flavor + Echo Kind module — chat
# tests dispatch `entity://agent/<ws>/echo_<name>` URIs whose resolution
# walks `Ezagent.AgentFlavorRegistry`. Without this start, every echo
# spawn returns `{:error, {:no_kind_module_for_agent, ...}}`.
for app <- [:ezagent_plugin_echo] do
  {:ok, _} = Application.ensure_all_started(app)
end

ExUnit.start()
