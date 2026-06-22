# Handoff (codex-reviewed + Allen-reframed — pending final confirm): external adapter — inbound OpenAI/Anthropic-compatible APIs

> **Date:** 2026-06-22 · **From:** Claude (with Allen) · **To:** an independent developer (human + cc/codex)
> **Tracking:** task #82 · **Base:** `origin/main` @ `469f107b`
> **Status:** Allen-confirmed 2026-06-22 (codex-reviewed; reframed as Feishu-equivalent inbound + synchronous reply; structure = request-scoped binding variant). Research: `docs/superpowers/notes/2026-06-22-external-adapter-research.md`. The small operator UI follows `docs/guide/world-coordination.md`.

## 0. Mission

Make ezagent speak the **inbound** OpenAI/Anthropic wire protocols so external tools call an ezagent agent as if it were an OpenAI/Anthropic endpoint: `POST /v1/chat/completions`, `POST /v1/responses` (OpenAI), `POST /v1/messages` (Anthropic). ezagent already speaks OpenAI **outbound** (`curl_agent`/`np`); this is the server side.

## 1. The one idea: it IS a Feishu-equivalent inbound channel + a synchronous reply

This is **not** a new architecture. It is **another inbound channel, structurally identical to Feishu** — with exactly ONE difference.

- **Inbound half = identical to Feishu.** A request → an `Ezagent.Message` → `Ezagent.Invocation.dispatch(session.send)`. Same as `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/inbound_dispatcher.ex` (resolve caller, resolve session, dispatch). Nothing new.
- **The ONLY difference = the reply is synchronous.** Feishu's reply is **async** — the agent answers later and the answer is pushed out to the chat via `Behavior.Publisher` → the Feishu binding; the original sender doesn't wait. An OpenAI/Anthropic call is a **synchronous HTTP request/response** — the client POSTs and must receive the agent's answer **in the same HTTP response (or an SSE stream)**. So the whole extra job is: catch the agent's later async reply, correlate it to this request, and return it over HTTP. Without that, the HTTP client gets only an ack and never sees the answer.

Mental model: **a Feishu-like inbound adapter whose "outbound binding" writes the reply into the HTTP response/SSE instead of pushing it to Lark.** Everything codex flagged (reply correlation, HTTP lifecycle, auth) is just the implementation of that one synchronous-reply delta.

## 2. Design

### 2.1 Inbound (copy Feishu)
Request → converge the three shapes (`messages[]`, `system`, `tools`) to one internal form → build `Message` → `dispatch(session.send, mode: :call)` (acceptance/cap-denial surfaces synchronously, like Feishu's `mode: :call`).

### 2.2 Session model — durable conversation↔session binding (Feishu-equivalent)
Since we're "equivalent to Feishu," reuse Feishu's model: a **durable `conversation_id ↔ session` binding** (Feishu uses `chat_id ↔ session` via `external_mirror_bindings`). A conversation id (an ezagent-specific request field/header, or derived per API key) maps to a durable session — preserving agent identity/caps/cwd/history across calls. **Additionally** support pure-stateless clients that resend full `messages[]` (seed a fresh/ephemeral session from the transcript). Default = durable-by-conversation; stateless = the fallback when no conversation id is given. *(This reverses the earlier codex-driven "stateless default" — Allen's Feishu-equivalence makes durable the natural primary; we keep both.)*

### 2.3 The synchronous reply (the one real build)
- **Correlate the reply:** stamp the inbound `Message` with the request id as **`ref_id`** (the field that propagates), and require the targeted agent's reply to **echo it** (the bridge preserves a supplied `ref` → `ref_id`, `bridge_adapter.ex:141,148`). A **per-request worker** (the "outbound binding" for this request) subscribes to the session Publisher at `:latest`, then returns the first later `:chat.last_message` whose `sender ∈ target agents` AND `ref_id == request id`. (This is what a Feishu binding does for outbound, just terminating in the HTTP response.)
- **Own the HTTP/SSE lifecycle** in that worker/controller, **not** via the reserved `{:plug_conn}` core reply target (it only raises today — `invocation.ex:290,306`). Enforce a deadline (dispatch default call timeout is 5s — `invocation.ex:256` — far shorter than real agent latency, so set `ctx[:deadline_ms]` + an API-level deadline), emit SSE heartbeats, handle client-close. Model the long-lived transport on `CustomerChannel` (cursor + replay — `customer_channel.ex:40,69`).
- **Async reality → the "virtual request" pattern (Allen — the load-bearing design decision):** session replies are fundamentally async, so a pure block-until-reply may not be robust for slow models / long tasks. Design an **ack-then-async-reply** path: return an immediate ack with an `id`, then deliver the completion over the SSE stream OR a follow-up retrieval — *in addition to* the simple synchronous block-with-deadline case. **Research the relevant docs/code first** (the agent reply flow, `Behavior.Publisher`, the bridge reply paths) before fixing this mechanism. The synchronous block is the easy case; the virtual-request (ack + later delivery) is the robust case Phase 0 must get right.

### 2.4 Structural fit — a request-scoped binding variant of the ExternalAdapter model
Because the inbound is Feishu-shaped, model this **as an ExternalAdapter** (consistent with "external integration = Adapter"), but the binding is **request-scoped** (lives for one HTTP request) rather than operator-bound/long-lived like Feishu's. **Decision (Allen): build it as a request-scoped binding variant** — add the small request-scoped binding variant to the Adapter/Binding contract (`adapter.ex`) to express "the transport is this HTTP response/SSE," rather than a bare plugin controller. (This binding is what implements the virtual-request ack-then-async-reply path in 2.3.)

### 2.5 Auth — first-class API-key binding
Don't reuse `/api/v1`'s `Bearer + X-Ezagent-Entity-URI` scheme (tokens indexed by URI — `api_v1_controller.ex:131`). Build an inbound **API credential/binding** `{key_id, hashed_secret, entity_uri, workspace_uri, allowed_models, conversation/session policy, cap_policy}`. Gate dispatch with normal `session.send` caps + a binding-scoped allow check; no over-broad entity impersonation. Reuse `rate_limiter.ex`.

## 3. The world-UI touch
Issue/revoke API keys; view/edit `key → binding` rows; `model → agent` map. New additive `world` surface per `docs/guide/world-coordination.md` (declare it, additive files + route clause, registry row, shadcn shape, PRs into the task branch). Minimal in v1.

## 4. Phasing
- **Phase 0 — `/v1/chat/completions`, durable conversation binding, synchronous non-streaming:** inbound=Feishu; the ref_id reply-waiter; block-with-deadline → one completion. Proves the one delta.
- **Phase 1 — SSE (honest):** `stream: true` emits whole-message chunks/one-final-event over the cursor pattern; **document non-delta semantics** (true token deltas need new incremental emission — Publisher events are whole slice changes; the outbound OpenAI client itself sets `stream:false`, `api_client.ex:32`). Or reject `stream:true` in Phase 1.
- **Phase 2 — Anthropic `/v1/messages` + OpenAI `/v1/responses`** onto the converged internal shape.
- **Phase 3 — token-level streaming + inbound tool-calling** (large; deferred).

## 5. Out of scope for v1 (flag, don't drop)
Inbound tool-calling; token-level streaming.

## 6. Residual risks
1. The `ref_id` echo contract must hold for every targeted flavor (verify cc/codex/curl all preserve `ref`).
2. SSE lifecycle (Bandit/proxy idle timeouts, heartbeats, conn ownership, client-close).
3. The request-scoped binding variant (or controller exception) — the one structural decision.
4. The API-key binding + binding-scoped cap (security review; no broad impersonation).

## 7. Merge model & gates
- **Merge model:** split into PRs as needed; all PRs merge into this task's branch (e.g. `protocol-api`), never `main`; keep rebased on `main`; Allen merges the task branch → `main`.
- Standard gates (`arch.scan`/`doc.scan`/`uri_query.scan`/`check_invariants`/`format`/`test`/`:ezagent_plugin_check`); wire the new plugin into the 4 allowlist/manifest files (hello handoff §8). Never bypass CapBAC; behaviors via `use Ezagent.Lifecycle`; world surface per `world-coordination.md`. Load skill `ezagent-developer`.

---
*Allen-confirmed 2026-06-22. Inbound = Feishu; the only delta = the synchronous HTTP reply, implemented via a request-scoped ExternalAdapter binding + the virtual-request (ack-then-async-reply) path. Codex catches are the implementation of that delta. Ready for an independent dev.*
