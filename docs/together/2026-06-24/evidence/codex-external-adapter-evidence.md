# Codex External Adapter Evidence

Date: 2026-06-24
Branch: `main`
Base: `94ae55a7 fix(hooks): portable dev-together Stop hook + CI guard on the skill`

## Focused Checks

```bash
mix test \
  apps/ezagent_plugin_codex/test/bridge_adapter_test.exs \
  apps/ezagent_plugin_codex/test/integration/plugin_contract_test.exs \
  apps/ezagent_plugin_codex/test/ezagent/template/codex_remote_agent_test.exs
```

Result: `21 tests, 0 failures`.

Follow-up focused checks after the Codex Remote topic/config-dir fixes:

```bash
mix test \
  apps/ezagent_plugin_codex/test/bridge_adapter_test.exs \
  apps/ezagent_plugin_codex/test/ezagent/template/codex_remote_agent_test.exs \
  apps/ezagent_plugin_codex/test/integration/plugin_contract_test.exs

mix test \
  apps/ezagent_plugin_codex/test \
  apps/ezagent_domain_agent_bridge/test/ezagent/agent_bridge/socket_channel_test.exs \
  apps/ezagent_domain_agent_bridge/test/ezagent/agent_bridge/transport_class_test.exs

mix test \
  apps/ezagent_core/test/ezagent/resource/fs_resolver_test.exs \
  apps/ezagent_core/test/ezagent/sandbox/config_dir_test.exs \
  apps/ezagent_core/test/ezagent/sandbox/config_dir_parity_test.exs
```

Result:

- Codex focused tests: `24 tests, 0 failures`.
- Codex plugin + AgentBridge tests: `62 tests, 0 failures, 1 skipped` and `18 tests, 0 failures`.
- Core config-dir resolver tests: `54 tests, 0 failures`.

```bash
uv run --script apps/ezagent_plugin_codex/test/python/codex_app_server_thread_repro.py
uv run --script apps/ezagent_plugin_codex/test/python/codex_bridge_thread_smoke.py
```

Result:

- `codex_app_server_thread_repro.py` passed and returned a Codex thread id.
- `codex_bridge_thread_smoke.py` wrote a Codex thread id successfully. Its final websocket connect failure is expected because the smoke uses an unreachable Phoenix endpoint.

## Screenshots

- Codex session evidence: `docs/together/2026-06-24/evidence/codex-session-latest-main.png`
- Codex remote session evidence: `docs/together/2026-06-24/evidence/codex-remote-session-latest-main.png`
- Fresh Codex Remote agent detail: `docs/together/2026-06-24/evidence/codex-remote-agent-cdr-live-352718.png`
- Fresh Codex Remote session roundtrip: `docs/together/2026-06-24/evidence/codex-remote-session-codex-remote-live-481996-success.png`

The Codex screenshot shows a successful user-to-agent roundtrip:

- User: `Hello! This is an E2E test from the Codex agent.`
- Agent: `Hello. E2E test received.`

The old Codex remote screenshot shows only the user message:

- User: `Hello! This is an E2E test from the Codex-Remote agent.`

The fresh Codex Remote screenshot proves a latest-main UI session roundtrip:

- User: `@cdr-live-352718 请回复：codex remote 已经联通`
- Agent: `codex remote 已经联通`

## Notes

The latest-main Codex Remote path required two fixes before the live roundtrip:

- Codex Remote must join `agent_bridge:codex-remote:<agent_uri>`, not the plain `codex` topic.
- `codex-remote-agents` must be a registered config-dir namespace so agent materialization can allocate the per-agent `CODEX_HOME`.

During manual live testing, an empty per-agent `CODEX_HOME` produced Codex app-server
`401 Unauthorized: Missing bearer or basic authentication in header` events and an empty
turn. After provisioning the per-agent `CODEX_HOME` from the local `~/.codex`
`auth.json` and `config.toml`, the same session produced the agent reply shown above.
