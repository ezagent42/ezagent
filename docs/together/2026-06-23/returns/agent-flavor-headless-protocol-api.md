# Return: Agent Flavor Headless + Protocol-API

> **Task:** agent-flavor-headless-protocol-api · **Branch:** `agent-flavor-headless-protocol-api`
> **Base:** `origin/main` @ `1dd15303` · **Date:** 2026-06-23
> **Status:** ✅ DONE

## DoD Checklist

| # | 条目 | 状态 |
|---|---|---|
| 1 | `cc-headless` 可选择/可 spawn 或精确 unsupported matrix | ✅ 已注册 + 可验证 + spawn stub |
| 2 | `codex-remote` 可选择/可 spawn 或精确 unsupported matrix | ✅ 完整实现（AppServer+BridgeSidecar，无 PTY） |
| 3 | 聚焦测试 | ✅ 25 新增 tests, 0 failures |
| 4 | Protocol-api E2E 测试报告 | ✅ Echo+Curl 全链路，CC/Codex 路径验证 |
| 5 | Main SHA + 失败分类 | ✅ `1dd15303`，0 regressions |

## Changes Summary (14 files)

| 文件 | 变更 |
|---|---|
| `apps/ezagent_plugin_protocol_api/.../openai_chat_plug.ex` | `flavor_from_uri/1` + `maybe_register_flavor/1` cherry-pick |
| `apps/ezagent_plugin_protocol_api/.../api_key_store.ex` | `String.split` with `parts: 2` |
| `apps/ezagent_plugin_protocol_api/.../conversation_registry.ex` | `_bound_by` → `bound_by` |
| `apps/ezagent_plugin_codex/.../codex_agent.ex` | **FIX**: add `AgentFlavorAttributes.put_from_template_class` in instantiate |
| `apps/ezagent_plugin_codex/.../codex_remote_agent.ex` | **NEW**: `CodexRemoteAgent` Template Class |
| `apps/ezagent_plugin_codex/.../codex_remote_bridge_adapter.ex` | **NEW**: `CodexRemoteBridgeAdapter` |
| `apps/ezagent_plugin_codex/.../application.ex` | Register `codex-remote` flavor |
| `apps/ezagent_plugin_cc/.../cc_headless_agent.ex` | **NEW**: `CcHeadlessAgent` Template Class (spawn stub) |
| `apps/ezagent_plugin_cc/.../cc_headless_bridge_adapter.ex` | **NEW**: `CcHeadlessBridgeAdapter` |
| `apps/ezagent_plugin_cc/.../application.ex` | Register `cc-headless` flavor |
| `apps/ezagent_domain_workspace/.../agent_create.ex` | `validate_cwd` + `do_create_agent` for new flavors |
| `apps/ezagent_plugin_codex/test/.../codex_remote_agent_test.exs` | **NEW**: 13 tests |
| `apps/ezagent_plugin_cc/test/.../cc_headless_agent_test.exs` | **NEW**: 12 tests |
| `scripts/e2e_init_protocol_api.sh` | Updated: echo + curl + cc + codex seeding |

## Test Results

| Suite | Tests | Failures |
|---|---|---|
| `ezagent_plugin_protocol_api` | 8 | 0 |
| `ezagent_plugin_cc` (full) | 275 | 0 |
| `ezagent_plugin_codex` (full) | 59 | 0 |
| **Total** | **342** | **0** |

## E2E Protocol-API Results

| Agent | Round 1 | Round 2 | Status |
|---|---|---|---|
| Echo | `"Hello"` → `"echo: Hello"` | 2s | ✅ |
| Curl+DeepSeek | `"Say hello in Chinese"` → `"你好！"` | `"2+2=?"` → `"4"` | ✅ |
| CC | ack ✅ / agent.receive ✅ | — | ⚠️ reply correlation |
| Codex | ack ✅ / agent.receive ✅ / bridge reply logged | — | ⚠️ reply correlation |

CC/Codex reply timeout is the same `ref_id` echo contract concern documented in the external-adapter branch's return — not a headless-slice regression.

## Unsupported Matrix

| Path | Status |
|---|---|
| `cc-headless` spawn (claude subprocess) | Stub — requires `claude -p` feasibility or erlexec-without-PTY integration |
| `cc-headless` `--from` | Not supported |
| `codex-remote` `--from` | Not supported |
| CC/Codex protocol-api reply correlation | Known `ref_id` bridge concern |

## E2E Evidence (2026-06-23 15:36 CST)

All 6 agents seeded, protocol-api ACK verified for each:

```
╔══════════════════════════════════════════════════════╗
║  Protocol-API E2E — All 6 Agents + CodexAgent Fix  ║
║  Baseline: origin/main @ 1dd15303                   ║
╠══════════════════════════════════════════════════════╣
║  GROUP 1 — External-Adapter Baseline (4 agents)     ║
║    echo  : ✓ FULL ROUND-TRIP (2s)                   ║
║    curl  : ✓ FULL ROUND-TRIP (2s) "你好！"          ║
║    cc    : ✓ ACK + spawn + agent.receive            ║
║    codex : ✓ ACK + spawn + bridge confirmed reply   ║
╠══════════════════════════════════════════════════════╣
║  GROUP 2 — NEW Headless Flavors (2 agents)          ║
║    cc-headless  : ✓ ACK (flavor_from_uri→"cc")      ║
║    codex-remote : ✓ ACK (flavor_from_uri→"codex")   ║
╚══════════════════════════════════════════════════════╝
```

| Agent | API Key ID | Target URI | flavor_from_uri |
|---|---|---|---|
| echo | echo1 | entity://system/agent/echo_default | `"echo"` |
| curl | curl1 | entity://system/agent/curl_e2e_test | `"curl"` |
| cc | cc1 | entity://system/agent/cc_e2e_test | `"cc"` |
| codex | codex1 | entity://system/agent/codex_e2e_test | `"codex"` |
| cc-headless | cch1 | entity://system/agent/cch_e2e_test | `"cc"` |
| codex-remote | cdr1 | entity://system/agent/cdr_e2e_test | `"codex"` |

E2E output saved: `scripts/e2e_recordings/E2E-FINAL-6-AGENTS-153623.txt`

## Bonus Fixes

1. `CodexAgent.instantiate/3` was missing `AgentFlavorAttributes.put_from_template_class` (parity with `CcAgent`). Caused `no_kind_module_for_agent` on cold-spawn via `mix run`. Fixed in `codex_agent.ex`.

2. `CodexRemoteAgent.instantiate/3` — same fix applied in `codex_remote_agent.ex`.

3. `CodexRemoteBridgeAdapter` + `CcHeadlessBridgeAdapter` — wrapper bridge adapters needed because `AdapterRegistry` enforces one flavor per adapter module.
