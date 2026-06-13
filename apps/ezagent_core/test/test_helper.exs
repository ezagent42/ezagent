# #52 Mode-A fix — standalone-vs-umbrella exclusion.
#
# Many `ezagent_core` test suites are CROSS-TIER: they reference modules
# defined in SIBLING umbrella apps (e.g. `Ezagent.Users` in
# ezagent_domain_identity, `Ezagent.Workspace.Store` in
# ezagent_domain_workspace, `Ezagent.Entity.Session` in
# ezagent_domain_instance_message). `ezagent_core`'s `mix.exs` does NOT —
# and per the three-tier rule MUST NOT — depend on those apps, so when you
# run `cd apps/ezagent_core && mix test` (STANDALONE) those modules are not
# on the BEAM code path and the suites fail with
# `UndefinedFunctionError … is not available`. That is NOT a sandbox race;
# it is "running a cross-tier suite outside the only context (the umbrella
# root) that can satisfy its deps." The supported test command is
# `mix test` from the umbrella root.
#
# Those suites carry `@moduletag :umbrella_only`. Here we EXCLUDE that tag
# ONLY in standalone mode — detected by the absence of a sentinel sibling
# module (`Ezagent.Users`). In the umbrella run every sibling app's `ebin`
# is loaded, so the module resolves and the tag is NOT excluded (the
# cross-tier suites run, as they must). This mirrors the existing
# `:uv`-exclusion precedent in ezagent_domain_python/test/test_helper.exs.
standalone? = not Code.ensure_loaded?(Ezagent.Users)

exclude = if standalone?, do: [exclude: [:umbrella_only]], else: []

ExUnit.start(exclude)
Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, :manual)
