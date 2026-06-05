# curl-agent plugin walkthrough — DeepSeek backend, per-user API keys

> PR #126, 2026-05-19. Adds a new agent type that proxies chat
> messages to a remote OpenAI-compatible chat-completion API
> (DeepSeek default; OpenAI / Anthropic / etc. via per-instance
> config). All API keys are **per-user** — the system itself
> stores no keys.

## Evidence

- `evidence/pr126-curl-agent-deepseek-e2e.webm` — agent-browser
  recording of the end-to-end flow (210 KB)
- `evidence/pr126-01-api-keys-page.png` — `/admin/users/.../api-keys`
  showing the saved DeepSeek key (masked as `sk-06a5...0a7c`)
- `evidence/pr126-02-workspace-template.png` — workspace detail
  with the `curl.agent` Template Class auto-derived form + the
  registered `deepseek-chat-bot` instance
- `evidence/pr126-03-routing-rule.png` — `/admin/routing` showing
  the `{:always} → curl-agent://my-deepseek` rule active
- `evidence/pr126-04-deepseek-reply.png` — `/admin` chat showing
  the real DeepSeek round-trip (admin says "DeepSeek say hello in
  one sentence please" → curl-agent://my-deepseek replies "Hello
  from the depths of attentive stillness.")

## Architecture

Three pieces:

1. **`Ezagent.Behavior.ApiKeys`** (in `ezagent_domain_identity`) —
   new Behavior on `User` Kind storing `%{provider => key}` in slice
   `:api_keys`. Actions: `:list_api_keys` (masked), `:put_api_key`,
   `:delete_api_key`, `:get_api_key` (plaintext, for callers like
   CurlAgent). User Kind's `{:snapshot, :on_change}` persistence
   carries the slice durably.

2. **`Ezagent.Entity.CurlAgent` Kind + `Ezagent.Behavior.CurlAgent`**
   (in `ezagent_plugin_curl_agent`) — new agent type. URI scheme
   `curl-agent://<name>` distinct from `agent://` so it routes via
   its own (Kind, action) registry entry rather than the cc-bridge
   path. `:receive` action:
   - reads `owner_uri` from slice
   - dispatches `identity/get_api_key` against the owner to fetch
     the plaintext key
   - POSTs `messages` + `model` to the configured `api_url` via
     `Ezagent.PluginCurlAgent.ApiClient` (`:httpc` based — zero
     new deps; matches Feishu plugin's stdlib-only choice)
   - appends the assistant reply to `conversation` slice
   - dispatches `chat/send` back into the originating session

3. **`Ezagent.PluginCurlAgent.Template`** — `curl.agent` Template
   Class with `form_fields/0` driving the UI: agent_uri / provider
   / api_url / model / system_prompt / max_history / owner_uri.

## Per-user key model (Allen 2026-05-19 directive)

> 系统本身不提供 api-key

Every user supplies their own key via `/admin/users/<uri>/api-keys`.
The CurlAgent at dispatch time:

1. Looks up the configured `owner_uri` (set when the template was
   instantiated)
2. Dispatches `identity/get_api_key` to that user's Kind with the
   provider name
3. Uses the returned plaintext for the outbound POST

If the owner hasn't configured a key for the provider, the
agent replies to the session with a `⚠️  no API key for provider
\`<x>\` — owner please add one at /admin/users/.../api-keys`
message so the operator sees the failure inside the chat.

## Loop prevention (caught during demo recording)

The first demo attempt used an `{:always}` routing rule pointing
at the curl-agent. Worked one way (admin → curl-agent → DeepSeek
→ session). Failed the other way: the curl-agent's reply hit the
same `{:always}` rule and fed back into curl-agent → infinite loop
(33 iterations before I killed phx).

Two-layer fix (PR #126):

1. **`Ezagent.Behavior.CurlAgent.invoke(:receive, ...)`** — if
   `msg.sender == ctx.self_uri`, ignore + return
   `{:ok, slice, %{ignored: :self_message}}`. Defense in depth at
   the Behavior layer.
2. **Operator best practice** — use `{:from, user://x}` matcher
   instead of `{:always}` so only user-originated messages trigger
   the agent. Documented in the walkthrough doc.

The Behavior-layer guard is in the test suite as a regression
gate.

## Pre-existing bug surfaced (worth a separate fix later)

`Ezagent.RoutingRegistry.put/3` requires the calling process to
**own** the table (via `declare_table`). The chat plugin's
`EzagentDomainInstanceMessage.Application` is the owner. Rules added via
`/admin/routing` (from the LV process) call `RuleStore.add` →
inserts into DB → `RuleStore.load_into_registry` → `RoutingRegistry.put`
**fails silently** with `{:error, {:not_owner, ...}}` because the LV
isn't the table owner. The rule lives in DB but doesn't take effect
until phx restart (which boots from DB into the owner process).

This is **not introduced by PR #126** — it's a pre-existing bug in
the routing UI. Workaround during the demo: restarted phx after
adding the rule, then the curl-agent rule fired correctly. A
future PR should route the put through the owner process via a
GenServer call.

## Demo walkthrough (5 steps captured)

1. **Add key**: `/admin/users/user://admin/api-keys` → type
   provider `deepseek` + the test key → Save → key shows masked
2. **Create workspace**: `/admin/workspaces` → name
   `curl-agent-demo` → Create
3. **Add curl.agent template**: workspace detail → click
   `curl.agent` Class button → form auto-renders with 7 fields
   (agent_uri / provider / api_url / model / system_prompt /
   max_history / owner_uri) → fill + Add → instance spawns at
   `curl-agent://my-deepseek` immediately
4. **Add routing rule**: `/admin/routing` → MentionRouting →
   matcher `always` (or `from user://admin` for production-safe)
   → receiver `curl-agent://my-deepseek` → Add → rule appears in
   the table (effective on next phx restart due to the pre-existing
   bug above)
5. **Chat**: `/admin` → type a prompt → DeepSeek responds in the
   session as `[curl-agent://my-deepseek]`

## Tests

- `mix test apps/ezagent_domain_identity/test/ezagent/behavior/api_keys_test.exs`
  — 12/12 pass (init, put, list-masked, delete, get-plaintext, mask
  edge cases)
- `mix test apps/ezagent_plugin_curl_agent/test/` — 14/14 pass
  (Behavior init/configure/reset; Template validate + form_fields)
- `mix test apps/ezagent_domain_identity/test/ezagent/entity/user_test.exs`
  — 7/7 pass (updated User.behaviors/0 expectation to include
  ApiKeys)
- Live verification: real DeepSeek round-trip via UI on the
  ezagent_runtime3 node, recorded.

## Out of scope (deferred)

- Streaming (`stream: true`) — chunked response decoding adds
  complexity; current implementation is unary request/response
- Per-instance retry on 429/5xx — relies on user re-sending
- Provider-specific schema branching (Anthropic's `messages` shape
  differs slightly) — DeepSeek is OpenAI-compatible so works
  as-is; for Anthropic backend add a switch in `ApiClient` on
  `:provider`
- Per-instance owner_uri rotation — design lock: owner is fixed
  at instantiate (avoid orphan-conversation-with-new-key
  confusion). To change owner: delete + re-instantiate.
- LV chat-history view of CurlAgent slice (`conversation`) — slice
  is persisted but not yet exposed in UI
