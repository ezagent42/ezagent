> **Task:** A1 - agent flavor + config unification: template flavor hook
> **Branch:** `feat/agent-flavor-config-unification`
> **PR:** https://github.com/ezagent42/ezagent/pull/980
> **Dev:** allenwoods (Codex)
> **returned_at:** 2026-06-25 15:59 +0800
> **deadline:** 2026-06-25 23:59 +0800
> **deadline_status:** on_time
> **base (current main):** `dde54e1b`
> **code head before return doc:** `fdf007ab`
> **CI:** final PR-head CI required; local `mix precommit` + `mix ezagent.check_invariants` passed before this docs-only return commit

## What's done

A1 is implemented as a narrow ReadyGate-style registration hook:

| area | change |
|---|---|
| core | Added `Ezagent.Kind.Template.FlavorHook` with `:persistent_term` registration, `Code.ensure_loaded?`, `function_exported?`, and safe no-op behavior when no implementation is registered |
| core | Replaced `Ezagent.Kind.Template` direct `Ezagent.AgentFlavorAttributes` writes/deletes with `FlavorHook.store/2` and `FlavorHook.delete/1` |
| domain_agent | Added `Ezagent.Agent.FlavorTemplateHook` and registered it from `EzagentDomainAgent.Application` |
| tests | Added hook store/delete regression coverage and the no-implementation no-op path |

The A1 domain hook intentionally delegates to the existing `Ezagent.AgentFlavorAttributes` store. A2 owns moving the registry/resolver/attributes fully into `domain.agent` and adding the `no_flavor_refs_in_core` ratchet.

## Gate blocker fixed in this PR

While running the required local `mix precommit`, the cc bridge integration tests failed under this machine's ambient proxy environment (`https_proxy=http://127.0.0.1:7896`). The Python `websockets` client inherited proxy settings and failed localhost Phoenix websocket handshakes before reaching `Ezagent.AgentBridge.Socket.connect/3`.

Narrow fix included as a separate commit:

- `apps/ezagent_plugin_cc/python/ezagent_mcp_bridge.py` now passes `proxy=None` to `websockets.connect/3`.
- `apps/ezagent_plugin_cc/priv/orchestrator_bridge.py` now passes `proxy=None`.
- Added `EzagentPluginCc.BridgeProxyTest` to lock both scripts to the explicit localhost proxy bypass.

This is not part of the A flavor architecture design; it is the local gate fix needed to make the required PR-head precommit reliable.

## Validation

Local validation completed in the isolated worktree `.worktrees/agent-flavor-config-unification`:

| command | result |
|---|---|
| `mix test apps/ezagent_core/test/ezagent/kind/template_provision_test.exs apps/ezagent_plugin_cc/test/ezagent/plugin_cc/bridge_proxy_test.exs` | PASS |
| `mix test apps/ezagent_plugin_cc/test/integration/cc_agent_sandbox_credentials_test.exs apps/ezagent_plugin_cc/test/integration/cc_agent_admin_reply_e2e_test.exs apps/ezagent_plugin_cc/test/integration/orchestrator_mcp_bridge_test.exs` | PASS, `11 tests, 0 failures` |
| `mix format --check-formatted` | PASS |
| `git diff --check` | PASS |
| `mix precommit` | PASS |
| `mix ezagent.check_invariants` | PASS, all in-scope invariants clean |

The first full `mix precommit` pass exited 2 after all visible per-app test summaries were green; `mix test --failed` reran the recorded failed test and passed. A second complete `mix precommit` run passed with exit 0.

## DoD reconciliation

| item | status | proof / note |
|---|---|---|
| A1 core flavor coupling inverted | met | `Kind.Template` now calls `Ezagent.Kind.Template.FlavorHook`, not `Ezagent.AgentFlavorAttributes` directly |
| ReadyGate-style registered hook | met | `FlavorHook.register/1` stores modules in `:persistent_term`; hook invocation uses `Code.ensure_loaded?` and `function_exported?`; no registered hook is `:ok` |
| Domain implementation registered outside core | met | `EzagentDomainAgent.Application` registers `Ezagent.Agent.FlavorTemplateHook` |
| No A2/A3 scope creep | met | registry/resolver/attributes remain where they are until A2; behaviors boot barrier and cold restart tests are untouched until A3 |
| Required local gates | met | `mix precommit`, `mix ezagent.check_invariants`, and focused regressions passed locally |
| PR-head CI | pending at return-doc commit time | PR #980 opened as draft; final checks must be read from GitHub after the docs-only return commit lands |

## Merge request

Please review PR #980 as the A1 deliverable only. Do not merge until final PR-head `precommit + check_invariants` is green on GitHub.

A2 should start from the merged A1 head and then move `AgentFlavorAttributes` ownership out of core, add the `no_flavor_refs_in_core` architecture gate, and handle the `arch_baseline_manifest.exs` ratchet after rebasing against any B changes.
