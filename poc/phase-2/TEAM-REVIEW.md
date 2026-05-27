# Phase 2 — Team Review (1-page)

**Audience**: ezagent team
**Goal**: confirm scope/shape before Phase 3 + identify which new code belongs in ezagent core vs stays AutoService-specific plugin.

## What we built

| Capability | Where it lives | New ezagent primitive candidate? |
|---|---|---|
| Customer HTTP+SSE channel (`POST /api/customer/:workspace/chat`) | `apps/ezagent_web/.../customer_chat_controller.ex` | **No** — AutoService-shaped. Belongs in a future `ezagent_plugin_customer_chat` once cleaned up. |
| `EzagentPluginCc.EagerBridge.ensure_bound!/2` | `apps/ezagent_plugin_cc/.../eager_bridge.ex` | **Yes (likely)** — generic answer to "how does a non-operator inbound flow wake a cc agent's MCP". Phase 0.5 questions resolved by code. |
| Soul as `cc.agent` Template `soul_path` arg | `apps/ezagent_plugin_cc/.../cc_agent.ex` (extends existing `@optional_sandbox_keys`) | **Yes (mild)** — slots into existing concept; could be left as-is in cc plugin since soul-injection is cc-specific. |
| `Ezagent.Behavior.Mode` + session-level `:mode` field + AI-side gating + takeover notice | `apps/ezagent_domain_chat/.../behavior/mode.ex` (new Behavior on Session Kind) | **Yes** — `auto/takeover/copilot` mode model is generic to any chat-with-human-fallback business. Auto + takeover implemented; copilot wired for future. |
| Operator dashboard — live customer session list + take-over button | `apps/ezagent_plugin_liveview/.../customer_sessions_dashboard_live.ex` + `customer_session_view_live.ex` | **No** — customer-shaped UI surface. Belongs in a future customer-chat plugin. |
| `EntityCapsLive` pre-spawn + grant (closes ezagent#395 manifestation in admin caps page) | `apps/ezagent_plugin_liveview/.../entity_caps_live.ex` | **Yes** — same-pattern as ezagent#419, applied to a sibling chokepoint. Suggest folding into ezagent core. |

## What's working end-to-end (proof)

`curl POST /api/customer/acme/chat` returns SSE with a real cc-generated
reply within ~10s. Per-conv session URIs (`session://default/<ws>/<conv-id>`)
keep concurrent customers isolated — verified.

## What's NOT working (known follow-up, NOT blocking architecture)

When `cc.agent` spawns with `--append-system-prompt <soul>`, claude's
reply via the `reply` tool gets handled by the bridge but doesn't reach
the session topic. Hypothesis: soul preamble lacks the channel-protocol
instructions claude needs to construct `session_uris` in the reply tool
call. Fix is a soul-file edit (~3 lines of preamble) OR a meta→session_uris
fallback in `EzagentPluginCc.BridgeAdapter.handle_client_event("reply", ...)`.

## Architectural questions for the team

1. **`EzagentPluginCc.EagerBridge.ensure_bound!/2` — adopt or refuse?**
   It empirically resolves Phase 0.5's 4 questions: bare `\r` to PTY (gated
   on PtyServer.auto_prompts having all fired) triggers MCP init reliably
   in ~500ms-2s. Customer-channel plugins opt in. Doesn't touch
   operator-bound cc agents at all. Architecturally aligned with PR #408's
   "session-create auto-spawns required actor" pattern.

2. **`Ezagent.Behavior.Mode` — core or domain_chat?**
   Currently lives in `ezagent_domain_chat` because it gates chat fan-out.
   But `auto/takeover/copilot` semantics are generic enough that any
   future business with human-fallback would want them. Worth promoting to
   ezagent_core?

3. **Default routing rule — should agents ever receive un-@-mentioned messages?**
   Today's `EzagentDomainChat.DefaultRules` receivers =
   `[session_users, mentions]`. Agent recipients are mention-gated.
   Customer-channel works around this by synthesizing `mentions:
   [cc_agent_uri]` server-side. Is there a "this session is an agent
   workflow, always fan out to all members" rule shape worth adding?

4. **Per-customer cc agent — pool primitive needed?**
   Each new `conv_id` spawns a fresh cc agent (per "no pool" decision).
   Per-agent memory ~100-500MB. Fine for pilot (10s of concurrent
   customers). At scale this needs an ezagent `CcPool` primitive matching
   AutoService's `cc_pool.py`. Not blocking Phase 3; design-track for
   Phase 4.

## Filed during Phase 2

- [ezagent#435](https://github.com/ezagent42/ezagent/issues/435) —
  `EZAGENT_BRIDGE_WS_URL` defaults to hardcoded port 10042. Same shape as
  #412. Workaround applied throughout Phase 2 setup scripts.

## Suggested next phase (Phase 3 candidates, NOT this PR)

- **Resolve soul-reply gap** (~1h): trace cc claude-prompt construction, add
  channel-protocol preamble to soul fixture OR fix BridgeAdapter to derive
  `session_uris` from `meta.session` when missing
- **CINNOX as second tenant** — validate template-ability by provisioning
  cinnox alongside acme using the same channel + dashboard infra. Confirms
  the tenant-parameterization (constraint §1) actually holds in practice.
- **Modify-AI-flow surface** (per user's "下一阶段加入修改AI客服流程或话术等功能") —
  start designing the CR-style workflow that lets tenants edit their soul
  files with review + rollback. Touches AutoService's CR/scope/lock concepts.

## Carry-forward to Phase 3

- Build the "soul preamble" (channel-protocol hints all tenant souls need)
  as part of the soul-loader pipeline, so individual tenants don't have
  to repeat boilerplate
- Validate `cc_pool` discussion against ezagent team — see questions §4
- Once soul-reply gap closed: full e2e test with CINNOX soul + actual
  warranty / customer-service Q&A
