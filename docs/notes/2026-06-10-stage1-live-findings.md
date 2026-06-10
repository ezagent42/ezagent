# Stage-1 socialware CS — live-run findings + resolution (2026-06-10)

> Live verification of the AutoService→socialware Stage-1 build on an **isolated
> fresh-seeded stack** (plan `docs/superpowers/plans/2026-06-09-autoservice-socialware-vertical-e2e-stage1.md`,
> Task 0/8/9). Everything below was found by actually running the stack with a real
> cc bot + a real browser (Playwright) — none of it is reachable from unit tests.

## TL;DR

The full **customer → bot → on-brand reply E2E is now PROVEN live** (see the Demo GIF
in PR #715). Reaching it surfaced + fixed issues across two layers:

- **Plugin layer (this PR, `feat/autoservice-cs-stage1`):** the original 9 build
  fixes + 3 more found while driving the browser — customer-message echo, a
  single-bot response gate (biphasic residue), and the "AI 客服" reply label.
- **cc-runtime layer (Allen's domain, NOT in this PR):** the headless cc bot on
  macOS authenticates via an ambient `CLAUDE_CODE_OAUTH_TOKEN`; claude 2.1.170 added
  two startup dialogs that need auto-prompt entries; and per-reply latency is
  dominated by a `high` reasoning-effort default that should be tunable.

**`b03cb4da` (the earlier "bridge never JOINs" fix) is obsolete** — its `EagerBridge`
target was deleted in the arch-deepening refactor, and its OAuth-detection is moot
under the ambient token. The actual blocker on claude 2.1.170 was two NEW dialogs.

## What works live (proven — see Demo GIF)

alice logs in → `/autoservice` → asks "CINNOX 是做什么的?" / "支持哪些渠道?" /
"我想退货…" → the cinnox-soul cc bot replies **on-brand**: a substantive product
intro (+ lead capture), a channel list, and a judicious out-of-scope decline. The
customer sees their own turns interleaved with the AI replies.

Full chain: `chat.send → MentionRouting → chat.receive (delivered) → dev-channel
inject → claude → reply tool → turn.compose → turn.settle → committed
customer_visible → CustomerFeed → CustomerLive`.

## Live-only fixes

### Build fixes (the original 9 — committed earlier on this branch)

| # | Finding | Fix |
|---|---|---|
| 1 | seed user URI used legacy 2-segment shape → `:unknown_entity_host` | `Ezagent.URI.user/2` (SPEC v3) |
| 2 | cc `create_agent` rejects missing `:with_pty` | `with_pty: false` (headless bridge bot) |
| 3 | creator-Manage-cap grant needs a real actor; a `system://` principal has none → `:no_such_actor` | seed `ctx.caller` = bootstrap admin user |
| 4 | re-seed `{:already_exists}` on a fresh BEAM | treat durable existence as success |
| 5 | `CustomerLive.mount` spawned a bare Session shadowing the SocialwareSession | `SocialwareCS.ensure_joined/1` |
| 6 | `bot_uri/1` assumed a flavor prefix `create_agent` doesn't add | bot_uri matches create_agent's real output |
| 7 | #17 cascade projection needs a create-time `cascade_resolution` a fresh cc agent lacks | soul written directly as `CLAUDE.md`; repoint non-fatal. **GAP**: wiring the soul through #17's create-time cascade is deferred |
| 8 | `ezagent_web` didn't dep on / route `ezagent_plugin_autoservice` | add dep + `live "/autoservice", CustomerLive` |
| 9 | dev assets unbuilt; socialware React SPA npm deps missing → no `app.js` → LiveView WS never connected | `pnpm install` + `mix assets.build` (env, not code) |

### Found while driving the browser (this update)

| # | Finding | Fix | File |
|---|---|---|---|
| 10 | The customer's own message never appears — it is the turn TRIGGER, not a settled message, so it is not in the visibility-gated CustomerFeed (DD5-b's "surfaces via the feed once the turn settles" assumption was wrong). | Echo the customer's turn locally in CustomerLive, time-merged with the settled feed (feed stays the source of truth for settled replies). | `customer_live.ex` |
| 11 | Bot stays silent. The soul's `CLAUDE.md` carried a **biphasic** response gate ("ONLY respond when @-mentioned `@cc_slow-alice`"), but the deployed agent is single-bot `cs-bot-alice` (name + URI both stale) → never @-mentioned → never replies. The adapter itself already says "no fast/slow biphasic"; only the soul lagged. | Replace with a role-based single-bot gate (answer the customer; silent on own + operator), **zero hard-coded agent URI** (uses `EZAGENT_AGENT_URI` + the customer's `…/user/…` role) → drift-resistant. | `cinnox_assets.ex` |
| 12 | Bot replies labeled "系统". The settled reply is composed under the turn-driving principal (`entity://system/…`), and `label_for` only matched the legacy host-segmented URI shape. | Label the system-principal / `/agent/` sender as "AI 客服". **Follow-up**: proper per-message authorship (bot vs operator) on the settled surface is a settlement-layer concern. | `chat_ui.ex` |

## G1-a (cc bot esr-bridge never JOINed) — RESOLVED at runtime, no Stage-1 code

Root cause was NOT b03cb4da's targets. On claude **2.1.170** + macOS:

1. **Auth.** A headless cc bot's isolated `CLAUDE_CONFIG_DIR` has no creds → OAuth
   screen. **Fix:** set `CLAUDE_CODE_OAUTH_TOKEN` on the `mix phx.server` process —
   `EzagentDomainPty.Server.build_env/1` passes only ezagent's own vars to erlexec
   and relies on OS-process env inheritance, so the spawned claude inherits the
   token. No code change; a launch-env concern (prod sets the same service token the
   same way → no local/prod divergence).
2. **Startup dialogs (NEW on 2.1.170, NOT suppressed by `--dangerously-skip-permissions`):**
   - `New MCP server found … 1. Use this MCP server` (MCP trust)
   - `Bypass Permissions mode … 2. Yes, I accept` (bypass acceptance)

   `default_auto_prompts/0` only had `trust_folder` → the headless PTY hung → the
   bridge never JOINed. **Fix:** two entries in `ezagent_domain_pty/server.ex`
   (`mcp_trust_dialog` send `"\r"` on `❯ 1.`; `bypass_permissions_dialog` send
   `"2\r"` — a bare Enter would pick "No, exit"). → cc-runtime, Allen.

With both, the bot JOINs `agent_bridge` in ~4 s and replies. **`b03cb4da` is obsolete**
(it patched `EagerBridge`, deleted on `main`; its OAuth-detection is moot here).

## Per-reply latency — the real UX issue, and the lever

Measured: bridge JOIN 4 s, but **each reply took 1–4 min** (sometimes >4 min). The
bot process used ~7 s CPU over 4 min → it was **waiting, not computing**: claude was
in **server-side extended thinking** (`high` effort, the inherited default) + reading
skill/flow files per turn. No API errors / rate limits.

**Lever (verified):** adding `--effort low` to the cc spawn cut a substantive,
on-brand reply to **26 s** (≈10×) with no visible quality loss. Effort is deliberately
OUT of the `AgentTemplate` slice (cc-agent-config §"NOT in the slice"), so the proper
fix is **making effort per-template configurable** (or defaulting the cc bot lower) —
cc-runtime, Allen's call. Far lighter than the deferred fast/slow biphasic.

## G1-b (routing not rehydrated on boot) — did NOT recur

In this fresh-seed → restart-server flow the customer message routed to the bot
correctly (`chat.receive` granted, reply settled, `JOINED` in the server log). The
earlier G1-b symptom did not reproduce; no action needed unless it resurfaces.

## cc-runtime items for Allen (separate from this PR)

1. The two new `default_auto_prompts` entries (claude 2.1.170 MCP-trust + bypass).
2. Make reasoning **effort** per-template configurable (or default the cc bot lower).

Both live in `ezagent_domain_pty` / `ezagent_plugin_cc` (cc-runtime). The ambient
`CLAUDE_CODE_OAUTH_TOKEN` is operational (no code). Stage-1 application logic
(this PR) is complete, unit-green, and now live-proven end-to-end.
