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
- **cc-runtime layer (Allen's domain, NOT in this PR — see Allen's triage on #715):**
  G1-a's proper fix is **creation-unification (#533, impl pending)** credentialling the
  bot's isolated config dir via the #17 cascade (the `:no_cascade_resolution` gap = fix
  #7); the ambient `CLAUDE_CODE_OAUTH_TOKEN` here is only a **demo workaround (shared
  identity)**. Two findings are ORTHOGONAL to that credential gap: (a) claude 2.1.170
  added two startup dialogs the existing #718 scanner doesn't cover; (b) per-reply
  latency is dominated by a `high` reasoning-effort default. Both → **PR #723**.

**`b03cb4da` is dead** (Allen + this run agree): its credential half is superseded by
#641/#719 (cascade materializes creds into the isolated dir, respawn-durable), its dialog
half by #718, and it patches `EagerBridge` which no longer exists. Do not resurrect.

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

## G1-a (cc bot esr-bridge never JOINed) — proper fix is creation-unification; demo on a workaround

**Allen's #715 triage is the authority.** Two distinct things:

### The credential gap (the actual G1-a) — creation-unification's, NOT this vertical
The vertical creates the bot via the blessed `Workspace.create_agent` correctly, but the
in-session cc bot ends up with `:no_cascade_resolution` (fix #7) → the #17 cascade never
materializes a credential into its isolated `CLAUDE_CONFIG_DIR` → on claude ≥2.1.92
(Keychain isolation) an unseeded dir shows the OAuth screen → the MCP/esr-bridge never
starts. This is the create-path credential-wiring that **creation-unification (#533, spec
merged, impl pending)** owns — it must credential every agent (incl. in-session cc bot) by
construction. **Acceptance criterion to carry into that impl:** *a cc bot created via the
unified chokepoint has its isolated config dir cascade-credentialled so its bridge joins
and `chat.receive` delivers* — and trace WHY current `create_agent` yields
`:no_cascade_resolution` here (missing credential-source/grant? the `with_pty:false`
headless path skipping the cascade step?).

**Our demo sidesteps this** by setting an ambient `CLAUDE_CODE_OAUTH_TOKEN` on the
`mix phx.server` process (the spawned claude inherits it via OS env), so the isolated dir
needn't be credentialled. This is a **workaround with SHARED identity** — fine for a demo,
not per-agent. The durable per-agent fix is creation-unification.

### Two NEW claude 2.1.170 dialogs — orthogonal, and NOT covered by #718
EVEN authenticated, claude 2.1.170 shows two one-shot startup dialogs that
`--dangerously-skip-permissions` does NOT suppress and that **#718's scanner
(theme/login/dev_channels/trust_folder) does not cover**:
- `New MCP server found … 1. Use this MCP server` (MCP trust)
- `Bypass Permissions mode … 2. Yes, I accept` (bypass acceptance)

The headless PTY hangs on them → the bridge never JOINs. Two auto-prompt entries fix it
(`mcp_trust_dialog` → `"\r"` on `❯ 1.`; `bypass_permissions_dialog` → `"2\r"` — bare Enter
picks "No, exit"). → **PR #723**. **Open question for Allen:** does creation-unification's
config materialization also pre-approve the esr-bridge MCP + bypass-accept (subsuming
these), or are these scanner entries still needed as the 2.1.170 extension of #718's
safety-net? With the workaround + these two entries, the bot JOINs in ~4 s and replies.

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

## G1-b (routing not live after restart) — E2E seed ORDERING, not a core gap (Allen)

Per Allen's #715 triage: **boot hydration already exists and works** —
`DefaultRules.bootstrap` → `RuleStore.load_into_registry(MentionRouting)` runs on every
boot and loads ALL enabled rules (regression-pinned by #721, merged). The live symptom was
a **two-process timing** issue: the long-running `mix phx.server` (B) boots + hydrates
BEFORE the short-lived seed task (A) writes the `alice → cs-bot-alice` rule to the DB; A's
own ETS dies with A, and nothing re-reads the DB after B's boot → the message doesn't route
until B restarts. **Fix on the E2E line (core unchanged):** (a) seed BEFORE starting the
server, (b) restart after seeding, or (c) have the seed RPC the running node to
`load_into_registry`. **Our `record-clean.sh` already does (a)** (seed → then start the
server), which is why routing worked in the demo.

## cc-runtime / core items (Allen's domain — NOT this PR)

1. **Credential the in-session cc bot's isolated config dir** (the real G1-a) →
   **creation-unification (#533) implementation**; carry the acceptance criterion above.
2. **Two new `default_auto_prompts`** (claude 2.1.170 MCP-trust + bypass) → **PR #723**;
   open question whether (1) subsumes them.
3. **Make reasoning `effort` per-template configurable** (or default the cc bot lower) →
   **PR #723**; orthogonal to G1-a.

The ambient `CLAUDE_CODE_OAUTH_TOKEN` is an operational demo workaround (no code), not the
durable fix. Stage-1 application logic (this PR) is complete, unit-green, and live-proven
end-to-end on the workaround.
