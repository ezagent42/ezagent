# Return: ezagent_plugin_protocol_api — Phase 0

> **Task:** #82 · **Branch:** `external-adapter` · **Status:** ✅ DONE (Echo + Curl+DeepSeek)
> **Handoff:** `docs/superpowers/handoffs/2026-06-22-external-adapter-openai-anthropic-api-handoff.md`
> **Spec:** `docs/superpowers/specs/2026-06-22-protocol-api-design.md`
> **Plan:** `docs/superpowers/plans/2026-06-22-protocol-api-p0.md`

## DoD Artifacts

| 类型 | 文件 | 说明 |
|------|------|------|
| 📸 截图 | `scripts/e2e_recordings/FINAL-sessions-list.png` (341KB) | ezagent session 列表页 |
| 📸 截图 | `scripts/e2e_recordings/FINAL-echo-conversation.png` (78KB) | Echo 会话 |
| 📸 截图 | `scripts/e2e_recordings/FINAL-curl-conversation.png` (84KB) | Curl+DeepSeek 会话 |
| 📸 截图 | `scripts/e2e_recordings/protocol-api-all-agents-test.png` (162KB) | 全 agent 测试结果 |
| 📹 视频 | `scripts/e2e_recordings/protocol-api-all-agents-*.webm` | 测试录屏 |
| 📜 脚本 | `scripts/e2e_init_protocol_api.sh` | 一键初始化测试数据 |

## Verified (curl E2E)

```
Echo:  "Hello from protocol API!" → "echo: Hello from protocol API!"
Curl:  "Say hello in Chinese"     → "你好！我是DeepSeek，一个AI助手"
       "What is 2+2?"             → "4"
```

## Architecture (Feishu model per handoff)

```
API Key(entity_uri=admin/user) → session.send → $mentions路由
→ target_agent.receive → agent回复 → Publisher → ReplyWaiter → OpenAI JSON
```

## Completed Requirements

- [x] 入站=照搬 Feishu（请求→Message→dispatch session.send）
- [x] 同步回复 via Publisher + ref_id (`ReplyWaiter`)
- [x] 请求级 ExternalAdapter binding 变体 (`:request_scoped` in adapter.ex)
- [x] ack-then-async-reply (POST→ack, GET→poll)
- [x] 无状态 session (no conversation_id → ephemeral)
- [x] 鉴权=API-key 绑定 (`protocol_api_keys` + bcrypt)
- [x] 8/8 tests, arch PASS, invariants clean
- [x] Echo agent E2E (protocol_api + LiveView session UI)
- [x] Curl agent + DeepSeek E2E (真实 AI 回复)

## Pending / Blocked

- [ ] CC agent (sandbox ✅, PTY server ✅, bridge credential timeout ⚠️)
- [ ] Codex agent (sandbox ✅, bridge credential timeout ⚠️)

CC/Codex sandbox root cause: module name `EzagentPluginCc` vs `Ezagent.PluginCc`. Fixed via `mix run` pre-seed. Bridge delivery timeout is credential configuration (API key not reaching CC CLI subprocess).

## Merge Request

Branch `external-adapter` → `main` (lead: Allen). 35 commits. All gates green.
