# Research note: external-adapter migration (OpenAI/Anthropic-compatible inbound APIs)

> **Date:** 2026-06-22 · **Author:** Claude (background research subagent) · **For:** task #82 brainstorm.
> **Base:** `origin/main`. READ-ONLY research; seeds the later brainstorm → handoff. Not a design.

## Bottom line

Feishu is the only general-purpose **bidirectional external chat channel**. Several surfaces speak HTTP/JSON, and two plugins (`curl_agent`, `np`) already speak the **OpenAI wire format OUTBOUND** (ezagent-as-client to DeepSeek/OpenAI). There is **zero** OpenAI/Anthropic-compatible **inbound** endpoint, **zero SSE/streaming** anywhere, and the cc plugin drives the `claude` CLI rather than calling the Anthropic Messages API. The machinery to add inbound OpenAI/Anthropic endpoints largely exists in pieces (generic JSON dispatch controller, bearer+entity auth, a Publisher→Mirror outbound chain, a cursor-based push channel), but the request/response(+SSE) shape of those APIs collides with ezagent's **async, decoupled, atomic-message** reply model — that's the central design tension.

## Q1 — External-facing surfaces (INBOUND = external→ezagent, OUTBOUND = ezagent→external)

| Surface | Direction | What it is |
|---|---|---|
| **Feishu plugin** (`ezagent_plugin_feishu`) | BOTH | Only general-purpose external chat channel. Inbound via WS long-connect (`ws_client.ex`) + HTTP webhook (`webhook_plug.ex`); outbound via ExternalMirror adapter→binding. |
| **`ezagent_plugin_np`** | OUTBOUND (LLM client)/internal | NOT a channel. Agent flavor; numpy/sympy subprocess; result dispatched back into originating session (`np_agent.ex:1-4`). |
| **`ezagent_plugin_curl_agent`** | OUTBOUND (LLM client) | Agent flavor; POSTs to an OpenAI-shaped `/chat/completions` (DeepSeek/OpenAI) — `api_client.ex:1-37`. ezagent-as-client. |
| **Socialware customer feed** (`/socialware/customer`) | OUTBOUND (read projection) | Gated read-only customer projection over a Phoenix Channel w/ replay cursor + live push. |
| **Socialware chat feed** (`/socialware/chat`) | mostly read SPA | External chat SPA; anon users view a `public_view` session. |
| **`/api/v1/:kind/:action`** (`ApiV1Controller`) | INBOUND (sync JSON) | Generic auto-derived JSON dispatch; any registered `{kind, action}` Behavior callable. Bearer-token auth. |
| **`POST /api/cc-events`** | INBOUND (unauth) | cc-hook error reporting; no auth by design. |
| **`/api/feishu/webhook`** | INBOUND | The one webhook route the Feishu plugin registers. |
| **MCP server** (`Ezagent.Orchestrator.McpServer`) | internal | Orchestrator-management transport over WS bridge; "ZERO authority". Not an external chat surface. |
| **World/admin LV, login, uploads, health** | internal/operator | Browser-only operator UI + auth. |

**Answer:** for general-purpose external **chat**, Feishu is the only bidirectional channel. Customer/chat socialware surfaces are outbound projections. `/api/v1` is generic inbound JSON RPC, not a chat protocol.

## Q2 — Current external-integration model (ExternalMirror Domain)

**Correction to the "Receiver Kind" principle: the Receiver Kind was DELETED.** `apps/ezagent_core/lib/ezagent/routing/matcher.ex:99` — the `feishu://` Receiver Kind was deleted (SPEC §5.8); post-PR-EM-6 the binding lives in the generic `external_mirror_bindings` table; the outbound mirror is a per-binding **Worker Kind**, not a routing rule. "Receiver" survives only as a routing-rule target term.

Current model = **ExternalMirror Domain** (`apps/ezagent_domain_external_mirror/`, spec `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`). An integration is an **Adapter** declared by a plugin:
- Plugin contract: `@callback adapters() :: [adapter_decl()]` (`plugin.ex:219`). `{adapter_module, binding_module}` for `:push`, bare module for `:pull`. Registered at boot via `AdapterRegistry`+`BindingRegistry`.
- **Adapter behaviour** (`external_mirror/adapter.ex`):
  - `:push` (default): pure `event_to_payload/1` (Publisher.Event → wire payload, **no I/O**, runs in Worker quantum) + paired **Binding** GenServer owning transport. Required: `adapter_id/0`, `display_name/0`, `description/0`, `binding_module/0`, `cap_subject/0`, `target_ownership_check/2`, `event_to_payload/1`.
  - `:pull`: no transport/Worker; `render/2` (on-demand json projection) served by caller's Phoenix channel.
- Auth (3 caps, SPEC §4.2): session-level `:bind` cap; per-adapter `*.Allow` cap Behavior (`cap_subject/0`, `Behavior.ExternalAdapter.<Id>.Allow`); bind-time `target_ownership_check/2` (the one I/O-allowed callback, supervised Task w/ timeout). Enforced in `Ezagent.ExternalMirror.bind/4`.

**Feishu reference impl:** `adapters → [{FeishuAdapter, FeishuChatBinding}]` (`application.ex:120`); `feishu_adapter.ex` `event_to_payload/1` (chat slice → Lark payloads, `:skip` for self-echo via `body[:_feishu_origin]`); `feishu_chat_binding.ex` transport; `behavior/feishu_allow.ex` cap; bindings in `external_mirror_bindings` table.

## Q3 — Inbound→dispatch→outbound (Feishu trace) + seams

**INBOUND** (`inbound_dispatcher.ex`): WS/HTTP → `dispatch/1` → `SenderResolver.resolve` (Feishu sender → caller_uri+caps; unbound → 👎 drop) → `InboundChatLookup.resolve` (chat_id+mentions → session_uri via `external_mirror_bindings`; fail-closed on ambiguity) → `ensure_session_live` → build `Message`, stamp `body[:_feishu_origin]=true`, dispatch:
```
target = URI.with_action(session_uri, :session, :send)
%Invocation{target:, mode: :call, args: %{message: msg},
            ctx: %{caller: caller_uri, caps:, reply: :sync}}
```
`mode: :call` so cap-denial surfaces synchronously (Decision #134). **The dispatch result is discarded — it is NOT the agent's reply.** (`reply: :sync` is not special-cased; `mode: :call` is what makes dispatch synchronous; the returned result is the behavior result, not the LLM reply.)

**OUTBOUND (keystone — fully decoupled/async):** `Entity.Session` implements `Behavior.Publisher` (typed `%Publisher.Event{}` stream + monotonic cursor + replay; `publisher.ex:1-45`). On `bind`, ExternalMirror spawns a per-(session×adapter×target) **Worker Kind** that subscribes via the Publisher API. When the agent does `chat.send`, slice change → Publisher.Event → Worker → `adapter.event_to_payload/1` → Binding `publish/2` → external bytes. `_feishu_origin` → `:skip` (no echo).

**`Invocation.reply/2`** (`invocation.ex:280-311`): routes the *dispatch result* per `ctx.reply`. Implemented: `{:caller_inbox, pid}`, `{:phoenix_pubsub, topic}`, `:ignore`. **`:plug_conn`, `:stdio_pipe`, `:mcp_response`, `:phoenix_channel` are ENUMERATED but RAISE "not yet implemented … arrives with its adapter"** — a pre-built extension seam for an HTTP/SSE reply target.

**Seams a new protocol adapter implements:** (1) inbound parse → `Message`+caller/caps; (2) dispatch to `session.send` (identical for any channel); (3) outbound: a `:push` Adapter+Binding, OR a `:pull` `render/2`+channel, OR a new `Invocation.reply/2` target (`:plug_conn`/`:mcp_response`).

## Q4 — HTTP/streaming/OpenAI/Anthropic today

- **OpenAI wire format — OUTBOUND only.** `curl_agent` `ApiClient.chat_completion/1` POSTs `{model, messages, stream:false}` + `Authorization: Bearer` to a configurable OpenAI-shaped URL (`api_client.ex:43-54`); UI labels it "OpenAI-compatible /chat/completions". **Explicitly no streaming** (`api_client.ex:34`).
- **No inbound OpenAI/Anthropic endpoint.** No `/v1/chat/completions`, `/v1/responses`, `/v1/messages`. Only generic ezagent-shaped `/api/v1/:kind/:action`.
- **No SSE/streaming anywhere.** Repo-wide `text/event-stream|server-sent` = **0**. Only PTY `push_chunk` over LV socket + LV `phx-update="stream"`.
- **cc/codex do NOT speak Anthropic/OpenAI wire format** — drive `claude`/`codex` CLIs over PTY+MCP. Only Anthropic touch = OAuth token refresh for the CLI.
- **`ApiKeys` Behavior** = per-agent **outbound** provider secrets, not inbound API-key auth.

## Q5 — Where inbound endpoints would plug in (options)

Reusable in all: `Invocation.dispatch` to `session.send`; bearer+entity auth (`ApiV1Controller.resolve_caller/1`); Publisher→Mirror outbound; CustomerChannel cursor/replay streaming.
- **(a) New `ezagent_web` controller** (`/v1/chat/completions`, `/v1/responses`, `/v1/messages`): mirror `ApiV1Controller`; map OpenAI/Anthropic body → `Message`+`session.send`; reply via the reserved `{:plug_conn, conn}` target or subscribe to Publisher → SSE. Smallest footprint; least north-star-aligned.
- **(b) New plugin `ezagent_plugin_openai_api` as ExternalAdapter**: north-star aligned (reuses adapter lifecycle/cap model/`external_mirror_bindings`). Fit-gap: existing Adapter assumes an **operator-bound long-lived transport**; an HTTP request is **caller-initiated, short-lived** — needs request-scoped transport support.
- **(c) Extend customer-feed channel**: already does cursor-based server push of committed messages — closest existing SSE analog.

**Auth:** bearer-PAT → entity+caps exists, but `/api/v1` requires an extra `X-Ezagent-Entity-URI` header (tokens indexed by URI). OpenAI/Anthropic clients send only `Authorization`/`x-api-key` → need an **API-key → entity reverse index**.

## Q6 — Hard parts / open questions

1. **Async session emission vs request/response(+SSE).** `dispatch(session.send)` returns only an **ack**, never the agent's reply. CLI agents generate asynchronously; the reply re-enters as a separate `chat.send` and flows out via Publisher→Mirror. A sync `/v1/chat/completions` must bridge async emission to a sync/SSE response — subscribe to the Publisher, **correlate which event is "the reply to this request,"** hold the conn open. No request↔reply correlation primitive exists for chat content.
2. **Atomic messages, not token deltas.** Publisher/CustomerDelivery commits are discrete whole messages w/ cursor. OpenAI/Anthropic expect token deltas. Options: chunk whole committed messages over SSE (coarse, reuses cursor), or build incremental/token-level emission (large).
3. **Request-shape mapping.** `messages[]`, `system`, `tools`, OpenAI `responses` vs `chat/completions` vs Anthropic `messages` → ezagent's single `Message`+`Invocation`. (Per `feedback_converge_to_uri_list`: check if they converge to one shape first.)
4. **Stateless API vs persistent sessions.** APIs nominally stateless (client resends history); ezagent sessions durable/member-scoped/snapshotted. Each call = new ephemeral session (loses agent identity/caps/cwd) OR durable session keyed by API key/header (then `messages[]` history redundant)? Feishu's "chat_id ↔ durable session via `external_mirror_bindings`" is the natural analog → a key↔session binding table.
5. **Auth + rate-limit.** Need API-key → entity/caps reverse lookup; rate limiter exists (`rate_limiter.ex`) but unwired to these surfaces.
6. **Which agent/flavor handles the request.** Request carries a "model" string, not a target URI. Need model-name → agent/flavor/session mapping (new policy; `ApiV1Controller` requires explicit `target`).

## Options & open questions for the brainstorm

- **Framing:** ezagent already speaks OpenAI **outbound**; the ask is the **inbound mirror image** (ezagent-as-server). Same wire format, opposite direction — but inbound is where the async/streaming/auth hard problems live.
- **Three shapes:** (a) thin controller + new `Invocation.reply/2` target; (b) ExternalAdapter plugin (aligned, but adapter contract assumes operator-bound long-lived transport); (c) extend customer-feed channel (best existing streaming analog).
- **Reserved seam:** `Invocation.reply/2` already names `:plug_conn`/`:mcp_response`/`:stdio_pipe` as future targets that "arrive with their adapter."
- **Biggest unknowns:** (1) request↔reply correlation for async output; (2) atomic-message vs token-delta streaming; (3) ephemeral vs durable session per call; (4) model→agent routing; (5) API-key→entity/caps without a second header.

**Key files:** `plugin.ex:219`; `external_mirror/adapter.ex`; `behavior/publisher.ex`; `feishu/inbound_dispatcher.ex`; `feishu/feishu_adapter.ex`; `api_v1_controller.ex`; `socialware/customer_channel.ex`; `invocation.ex:280-311`; `curl_agent/api_client.ex`; `routing/matcher.ex:99` (Receiver Kind deletion); spec `2026-05-24-external-mirror-domain.md`.
