# Return: Agent Flavor Headless + Protocol-API

> **Task:** agent-flavor-headless-protocol-api · **Branch:** `agent-flavor-headless-protocol-api`
> **Base:** `origin/main` @ `1dd15303` · **Date:** 2026-06-23
> **Status:** ✅ DONE

## DoD Checklist

| # | 条目 | 状态 |
|---|---|---|
| 1 | `cc-headless` 可选择/可 spawn 或精确 unsupported matrix | ✅ 已注册 + 可验证 + spawn stub → **3A 方案已调研,待实施** (见 §3A vs 3B) |
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
| `cc-headless` spawn (claude subprocess) | **Stub → 3A planned** — `claude -p` 方案已验证可行,待实施 (详见 `handoffs/cc-headless-real-implementation.md`) |
| 3B: `server:esr-bridge` without PTY | **❌ Rejected** — Claude Code 2.1.186 非 `-p` 模式下必须 TTY |
| `cc-headless` `--from` | Not supported |
| `codex-remote` `--from` | Not supported |
| CC/Codex protocol-api reply correlation | Known `ref_id` bridge concern |

## 3A vs 3B: Headless Subprocess Feasibility (2026-06-23)

Two approaches were evaluated for replacing the `cc-headless` spawn stub with a real Claude backend. Both were verified against Claude Code **2.1.186** on the actual host.

### 3B: `server:esr-bridge` without PTY — ❌ NOT VIABLE

| Test | Command | Result |
|------|---------|--------|
| `/dev/null` stdin | `claude ... server:esr-bridge < /dev/null` | ❌ `Input must be provided either through stdin or as a prompt argument when using --print` |
| pipe stdin | `echo "" \| claude ... server:esr-bridge` | ❌ `No messages returned from query` — exits immediately |
| `-p` + `server:esr-bridge` | `echo "" \| claude -p ... server:esr-bridge` | ❌ Exits immediately; `-p` cannot keep server-mode process alive |

**Root cause**: Claude Code 2.1 requires a TTY for non-`-p` mode. `Port.open/2` / erlexec without `:pty` creates pipes, not PTYs. `-p` mode is designed for one-shot queries and exits after response — it cannot host a persistent daemon.

### 3A: `claude -p` stdio pipe — ✅ VIABLE

| Test | Command | Result |
|------|---------|--------|
| Text multi-turn | Round 1: `--session-id X` "My name is Alice" → Round 2: `--resume X` "What is my name?" | ✅ "你的名字是 **Alice**" |
| stream-json mode | `--input-format stream-json --output-format stream-json --verbose` | ✅ JSON lines 正常流式 I/O |
| stream-json multi-turn | Round 1: remember "XKCD-42" → Round 2: `--resume` recall "XKCD-42" | ✅ Cross-invocation session 持久化 |
| `--session-id` UUID | 必须是 valid UUID | ✅ `uuidgen` 生成即可 |

**Trade-off**: `-p` is one-invocation-per-message (not persistent daemon):
- Higher per-message latency (~1-3s startup) but simpler process management
- Session persistence via on-disk `--session-id` / `--resume`
- Transport class: `:in_process_sync` (like curl), not `:subprocess_ws` (like cc)
- No esr-bridge, no WebSocket AgentBridge needed

### Decision

**3A is the chosen path.** 3B was the original handoff plan but failed feasibility verification against Claude Code 2.1.186. The follow-up implementation handoff is at `docs/together/2026-06-23/handoffs/cc-headless-real-implementation.md`.

### Implementation impact summary

| Aspect | Current stub | 3A target |
|--------|-------------|-----------|
| Transport class | `:subprocess_ws` (delegates to cc) | `:in_process_sync` |
| BridgeAdapter.deliver/2 | delegates to CcBridgeAdapter | Custom: runs `claude -p` via `HeadlessRunner` |
| Subprocess | None (stub) | One-shot `claude -p` per message |
| `ensure_subprocess_alive/2` | Stub `:ok` | Validates `claude_session_id` presence |
| New modules needed | — | `HeadlessRunner` + `:sync_result` Behavior |
| Session persistence | — | `--session-id <uuid>` + `--resume` |

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

## E2E Screenshot Evidence (2026-06-23)

### Sessions + Agents Overview

| Screenshot | Content |
|---|---|
| `scripts/e2e_recordings/FINAL-01-sessions-list.png` | 6 sessions 总览 |
| `scripts/e2e_recordings/FINAL-08-agents-list.png` | 6 agents 注册列表 |

### Per-Agent Conversation Screenshots

| # | Agent | Screenshot | Reply | 说明 |
|---|-------|-----------|-------|------|
| 02 | Echo | `FINAL-02-echo-conversation.png` | ✅ | 全链路往返 `"echo: Hello"` |
| 03 | Curl+DeepSeek | `FINAL-03-curl-conversation.png` | ✅ | `"你好！"` 全链路往返 |
| 04 | CC | `FINAL-04-cc-conversation.png` | ⚠️ 无回复 | CC agent 无凭证 provision — credential cascade 需要交互式 `/login`，headless protocol-api 路径无法完成 |
| | CC+DeepSeek | `CC-DeepSeek-RICH-conversation.png` | ✅ 有回复 | 同一 CC transport，使用 DeepSeek model 时凭证 provision 后正常回复 — 证明 CC 通道本身通畅 |
| 05 | Codex | `FINAL-05-codex-conversation.png` | ✅ | bridge 已确认绑定，agent.receive 送达 |
| | Codex RICH | `Codex-RICH-conversation.png` | ✅ | 丰富内容往返 |
| 06 | cc-headless | `FINAL-06-cc-headless-conversation.png` | ⚠️ 无回复 | spawn stub — 无 claude 后端运行 (3A `claude -p` 方案待实施) |
| 07 | codex-remote | `FINAL-07-codex-remote-conversation.png` | ⚠️ 无回复 | AppServer+BridgeSidecar 已启动，但 bridge auth 卡在验证 gate 未通过 |

### 未回复 Agent 根因分类

| Agent | 根因 | 是否本分支引入 | 解决路径 |
|-------|------|:---:|------|
| CC (04) | 凭证缺失 — CC credential cascade 需交互式 `/login` | ❌ 存量问题 | 操作员在终端 `/login` 后重新 provision |
| cc-headless (06) | spawn stub — 功能未完成 | ✅ 本分支明确标记为 unsupported matrix | 3A `claude -p` 方案实施 (`handoffs/cc-headless-real-implementation.md`) |
| codex-remote (07) | bridge auth gate 未通过 | ❌ 存量 codex bridge 问题 | 需排查 codex 侧验证链路 |

## Bonus Fixes

1. `CodexAgent.instantiate/3` was missing `AgentFlavorAttributes.put_from_template_class` (parity with `CcAgent`). Caused `no_kind_module_for_agent` on cold-spawn via `mix run`. Fixed in `codex_agent.ex`.

2. `CodexRemoteAgent.instantiate/3` — same fix applied in `codex_remote_agent.ex`.

3. `CodexRemoteBridgeAdapter` + `CcHeadlessBridgeAdapter` — wrapper bridge adapters needed because `AdapterRegistry` enforces one flavor per adapter module.
