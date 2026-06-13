# #52 Mode-A fix — standalone-vs-umbrella exclusion (mirrors
# ezagent_core/test/test_helper.exs). Every LiveView suite mounts views
# through the web Endpoint, which lives in `ezagent_web` — an app this app
# DELIBERATELY does not depend on (see its mix.exs `deps/0` NOTE). Run
# `cd apps/ezagent_plugin_liveview && mix test` STANDALONE and the mounts
# fail with `EzagentWeb.Endpoint … is not available` — not a sandbox race,
# just a cross-tier suite outside the umbrella. Those suites carry
# `@moduletag :umbrella_only`; exclude it ONLY standalone. The sentinel is
# `EzagentWeb.Endpoint`'s absence (NOT a domain module like `Ezagent.Users`
# — this app DOES depend on the identity app, so that would false-negative).
standalone? = not Code.ensure_loaded?(EzagentWeb.Endpoint)

exclude = if standalone?, do: [exclude: [:umbrella_only]], else: []

ExUnit.start(exclude)

unless Code.ensure_loaded?(Ezagent.TestSupport.TemplateAgentSpawn) do
  support_root = Path.expand("../../../test/support", __DIR__)
  Code.require_file("ezagent_noop_agent_template.ex", support_root)
  Code.require_file("ezagent_template_agent_spawn.ex", support_root)
end

Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)
