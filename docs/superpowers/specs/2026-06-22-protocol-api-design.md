# ezagent_plugin_protocol_api — Design Spec

> **Date:** 2026-06-22 · **Status:** Design (brainstormed → approved → spec written)
> **Handoff:** `docs/superpowers/handoffs/2026-06-22-external-adapter-openai-anthropic-api-handoff.md`
> **Research:** `docs/superpowers/notes/2026-06-22-external-adapter-research.md`

## 1. Goal

Expose OpenAI/Anthropic-compatible inbound HTTP APIs so external tools call an ezagent agent as if it were an OpenAI/Anthropic endpoint. Phase 0: `POST /v1/chat/completions` + durable conversation binding + synchronous non-streaming reply.

## 2. Core insight: it IS a Feishu-equivalent inbound channel + ONE synchronous reply delta

| Step | Feishu | Protocol API |
|------|--------|-------------|
| Parse request | Lark webhook JSON | OpenAI `{model, messages[]}` |
| Auth | `SenderResolver` (open_id → user) | API-key → entity_uri |
| Session resolve | `InboundChatLookup` (chat_id → session via `external_mirror_bindings`) | conversation_id → session via `external_mirror_bindings` |
| Build Message | `Message.new(caller, body, mentions:)` | `Message.new(entity_uri, body, ref_id: request_id)` |
| Dispatch | `session.send`, mode `:call` | SAME |
| Reply | Async (Publisher → Feishu Binding → Lark) | **Sync (Publisher → reply waiter → HTTP response)** |

The inbound half is byte-identical to Feishu. The **only new build** is catching the agent's later async reply, correlating it to the request via `ref_id`, and returning it over HTTP.

## 3. Architecture (Phase 0)

```
POST /v1/chat/completions  (Authorization: Bearer pk_<key_id>_<secret>)
         │
         ▼
┌─ OpenaiChatPlug ─────────────────────────────────────┐
│  1. Parse OpenAI JSON body (model, messages[])        │
│  2. Auth: Bearer token → API-key lookup → entity_uri  │
│  3. Resolve session: conversation_id →                │
│     external_mirror_bindings lookup                   │
│     (not found → spawn new session + bind)            │
│  4. ensure_session_live (Feishu §3.8 pattern)         │
│  5. Build Message: body from messages[],              │
│     ref_id = request_id                               │
│  6. SUBSCRIBE Publisher at :latest (BEFORE dispatch)  │
│  7. Dispatch session.send (mode: :call)               │
│  8. Reply waiter: wait for Publisher event where      │
│     last_message.ref_id == request_id                 │
│  9. Return OpenAI-format JSON response                │
└───────────────────────────────────────────────────────┘
```

### 3.1 P0 scope: Plug inline, not a full request-scoped binding variant

The handoff mandates a request-scoped ExternalAdapter binding variant long-term. P0 implements the reply waiter inline in `OpenaiChatPlug` (the "controller exception" path the handoff acknowledges as valid). The adapter is declared as `:push` with a no-op binding to satisfy the plugin contract; actual transport is the HTTP response. The binding variant is added in P1 once the pattern is proven.

### 3.2 Session model — durable first

Default: **durable** `conversation_id ↔ session` binding via the existing `external_mirror_bindings` table (`adapter_id: "protocol_api"`, `target_id: conversation_id`). Stateless fallback (no conversation_id → ephemeral session from `messages[]` transcript) is P1.

Session creation: `SpawnRegistry.spawn` via `generic_session` template class — identical to Feishu's `ensure_session_live`.

### 3.3 Reply waiter — subscribe-before-dispatch

To eliminate the snapshot-before-subscribe race (same pattern as P3-2's lower-bound cursor protocol):

1. Generate `request_id = Message.generate_id()` (8-byte random hex, same as `Message.id`)
2. `subscribe` Publisher at `:latest` via `Router.dispatch` → SessionImpl's `subscribe_from` action
3. Build inbound `Message` with `id: request_id` so the dispatched message carries this id
4. `dispatch` session.send with this Message
5. `receive` loop (deadline: 120s): wait for `{:publisher_event, %Event{slice_key: :session, ...}}` where the session slice's `last_message.ref_id == request_id`
   - The **reply** message (from the agent) has `ref_id` set to the inbound message's `id` (= `request_id`) — this is the standard bridge pattern (codex `bridge_adapter.ex:141`, echo `echo.ex:174`, np agent)
   - Also verify `last_message.sender` is the target agent URI

**Why `Message.id` as `request_id` (not a separate field):** The inbound Message already has a unique `id`. All bridge adapters echo the received message's `id` as the reply's `ref_id`. So the waiter matches `reply.ref_id == inbound_message.id` — no new field needed.

### 3.4 model → agent mapping (P0)

In P0, the `model` field in the OpenAI request is validated against the API key's `allowed_models` whitelist, but the **target agent is fixed per API key**: the key's `entity_uri` IS the agent that handles the request. The caller does NOT control which agent runs — the API key does. Model→agent routing (allowing one key to target multiple agents by model name) is deferred to P2.

### 3.5 API-key auth

### 3.5 API-key auth

New table `protocol_api_keys`:

| Column | Type | Purpose |
|--------|------|---------|
| `key_id` | string, unique index | Public identifier for indexed lookup |
| `secret_hash` | string | bcrypt hash |
| `entity_uri` | string | Entity this key acts as |
| `workspace_uri` | string | Scoped to one workspace |
| `label` | string | Human label |
| `allowed_models` | `{:array, :string}` | Optional model whitelist |
| `revoked_at` | utc_datetime | Soft-revoke |

Token format: `pk_<key_id>_<secret>` — `key_id` prefix enables indexed lookup without full-table bcrypt scan.

## 4. Files

### New (10 files)

| # | File | Purpose |
|---|------|---------|
| 1 | `apps/ezagent_plugin_protocol_api/mix.exs` | OTP app; deps: `ezagent_core`, `ezagent_domain_external_mirror`, `ezagent_domain_session` |
| 2 | `apps/ezagent_plugin_protocol_api/lib/ezagent_plugin_protocol_api/application.ex` | `use Application` + `use Ezagent.Plugin` contract |
| 3 | `apps/ezagent_plugin_protocol_api/lib/ezagent_plugin_protocol_api/openai_chat_plug.ex` | `POST /v1/chat/completions` handler (Plug) |
| 4 | `apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/api_key_store.ex` | Ecto schema + verify/lookup |
| 5 | `apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/conversation_registry.ex` | conversation_id ↔ session via `external_mirror_bindings` |
| 6 | `apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/adapter.ex` | `@behaviour ExternalMirror.Adapter`, `:push`, `adapter_id: "protocol_api"` |
| 7 | `apps/ezagent_plugin_protocol_api/lib/ezagent/protocol_api/reply_waiter.ex` | Subscribe → wait → match ref_id → return |
| 8 | `apps/ezagent_plugin_protocol_api/priv/repo/migrations/20260622000000_create_protocol_api_keys.exs` | Migration |
| 9 | `apps/ezagent_plugin_protocol_api/test/test_helper.exs` | ExUnit config |
| 10 | `apps/ezagent_plugin_protocol_api/test/ezagent/protocol_api/reply_waiter_test.exs` | Core unit test |

### Modified (2 files)

| # | File | Change |
|---|------|--------|
| 1 | `apps/ezagent_web/lib/ezagent_web/router.ex` | + `forward "/v1/chat/completions", EzagentPluginProtocolApi.OpenaiChatPlug` |
| 2 | Root `mix.exs` | + `ezagent_plugin_protocol_api: :permanent` in releases |

### May need updating

- `apps/ezagent_core/test/architecture/arch_baseline_manifest.exs` — if LOC/module counters exceed baseline
- `apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex` — if plugin calls `SpawnRegistry.spawn` (likely, for session creation)

## 5. Phasing

| Phase | Scope |
|-------|-------|
| **P0** (this spec) | `/v1/chat/completions`, durable conversation binding, sync non-streaming |
| P1 | SSE streaming (whole-message chunks, honest about non-delta semantics) + stateless fallback |
| P2 | Anthropic `/v1/messages` + OpenAI `/v1/responses` |
| P3 | Token-level streaming + inbound tool-calling (deferred, large) |

## 6. P0 verification

1. `mix compile --force` in plugin + full umbrella
2. `mix test` in plugin app (unit: api_key_store, reply_waiter, conversation_registry, plug)
3. Full umbrella `mix test` (no regressions)
4. `mix ezagent.arch.scan` green
5. `mix format --check-formatted` green
6. Manual E2E: `curl -X POST http://localhost:10044/v1/chat/completions -H "Authorization: Bearer pk_<id>_<secret>" -H "Content-Type: application/json" -d '{"model":"echo","messages":[{"role":"user","content":"hello"}]}'` → receives echo reply

## 7. Out of scope for v1

- Inbound tool-calling
- Token-level streaming
- World UI for API-key management (separate task)
