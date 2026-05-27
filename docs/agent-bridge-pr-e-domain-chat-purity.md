# AgentBridge PR-E - domain_chat Layer Purity

This PR removes the remaining `ezagent_domain_chat -> ezagent_plugin_cc`
dependency after PR-D moved Agent chat delivery through AgentBridge.

Scope:
- Removes `{:ezagent_plugin_cc, in_umbrella: true}` from
  `apps/ezagent_domain_chat/mix.exs`.
- Removes the temporary `layer-violation-exempt` marker for that
  dependency.
- Updates `Ezagent.Orchestrator.McpSocket` to use
  `Ezagent.AgentBridge.TokenStore`.
- Strengthens `layer_purity_test` with an AST-based scan over
  `apps/ezagent_domain_*/lib/**/*.ex`.

The new invariant catches real code references such as
`alias EzagentPluginCc.TokenStore` or `EzagentPluginCc.BridgeRegistry`.
It intentionally ignores comments, moduledocs, docstrings, and other
string literals so historical notes can remain in documentation without
forcing fake suppressions.

Out of scope:
- Codex plugin implementation.
- Removing deprecated cc compatibility shims.
- Removing the `/cc_socket` or `cc:bridge:*` deprecation-window aliases.

After this PR, `ezagent_domain_chat` routes bridge-related behavior
through domain abstractions only. That unblocks PR-G from adding a
codex agent flavor without inheriting the cc plugin dependency.
