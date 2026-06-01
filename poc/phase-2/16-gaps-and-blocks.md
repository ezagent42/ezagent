# PoC Findings — AutoService customer-service → ezagent: Gaps & Blocks

> 2026-06-01. **The PoC's primary deliverable.** Goal was to prove AutoService's
> customer-service capabilities migrate onto ezagent with minimal code + minimal
> core change, and to surface the main gaps/blocks for the core team. This is that
> findings list. Evidence: the minimal `customer_chat` plugin (A) runs on ezagent;
> packaged as reviewable PRs #529 (chat) / #530 (soul-edit) / #532 (operator+takeover),
> all compile-green. Baseline before changes: compile clean, `customer_chat` 28/28
> tests, `Mode` 19/19. Spec: `15-corrected-minimal-poc-plan`.

## Verdict
AutoService's three core CS capabilities **migrate onto ezagent natively** (web chat,
soul-edit, operator takeover). Two genuine blocks were hit (one fixed, one is a
core-team decision), one identity gap and one lifecycle gap are **documented, not
fixed** (out of scope per the minimal-PoC principle), and one capability the
orchestrator was hoped to provide it cannot.

## Findings

### G1 — cc bridge JOIN (claude 2.1.92) — BLOCK, FIXED
Fresh per-agent `CLAUDE_CONFIG_DIR` triggers the 2.1.92 OAuth login screen, and the
dialog-gate timeout was fatal → cc agents never JOINed the esr-bridge (web chat
hung at "connecting…"). Fixed (commits `b03cb4da`/`65a0732f`, in
`poc/phase-2-customer-service`; was PR #524, closed in favor of folding into the
"cc-agent bring-up" block per #510): PtyServer detects the OAuth screen → sets
`oauth_blocked?` (EagerBridge returns `{:error, :oauth_required}` instead of
spinning 15 s); the dialog-gate timeout is now non-fatal so `kick_loop` always runs.
**Operational note for any cc deploy/demo:** use `~/.claude` (no `claude_config_dir`
in the template) or configure `api_key_helper`, else you hit the OAuth screen.
Verify with `grep 'CONNECTED TO Ezagent.AgentBridge.Socket'` + `grep 'JOINED agent_bridge'`.

### G2 — agent lifecycle for anonymous / per-conversation customers — GAP (documented)
A serves a fresh cc agent per conversation. ezagent's boot-restore would re-spawn
all of them on restart, so A added a custom workaround: `create_agent` →
`remove_template` (drop the boot-restore registration) → ephemeral GC. This is the
one spot where the plugin **fights the framework**. The native pattern (a long-lived
agent provisioned as a workspace template that rehydrates at boot) needs a
**persistent/logged-in customer** to anchor it — which A's anonymous-per-chat-open
model doesn't have. **Not fixed** (a native fix needs a customer-identity model
change or a bounded agent pool — beyond a minimal feasibility PoC). For the core
team: does ezagent want a native lifecycle for short-lived / anonymous-scoped agents,
or is the ephemeral-template-dance the blessed pattern?

### G3 — operator takeover requires a core hook OR pure routing — CORE DECISION → Allen
Takeover is implemented via `Ezagent.Behavior.Mode` (#511, PR #532): a native
Behavior + slice, **plus a small suppression hook in core `Chat.handle_send`** (drop
agent-sender messages to the customer while `:takeover`). It works (PR #532:
takeover test 4/0, Mode suite 23/0). **A zero-core-change alternative exists** —
disable the customer→agent routing rule and route customer↔operator via the
Session-level `Ezagent.Behavior.Routing` primitive (full analysis:
`14-takeover-routing-evolution`). Routing is also the only abstraction that
expresses **Copilot** mode. **Decision for Allen:** is the `Chat` suppression hook
acceptable, or should takeover be re-expressed as pure routing (zero core change)?

### G4 — orchestrator cannot provide soul-edit or takeover — FINDING
The orchestrator was floated as a way to get soul-edit/takeover "for free." It
cannot: it's an LLM-driven slot/router engine (7 MCP tools), has no prompt-text edit
(its `prompt_override` is an explicit no-op), and is orthogonal to takeover (that's
the Session `:mode` slice). It isn't even on the customer message path (the
per-session orchestrator `create_session` spawns sits idle). Full analysis:
`12-orchestrator-vs-our-capabilities`. (Side finding: an idle orchestrator PTY per CS
session is wasted — worth a `create_session(orchestrator: false)` opt-out.)

### G5 — soul edit / customer-chat fan-out / capability gating — NO GAP ✅
- **Soul edit** migrates natively: `SoulStore` resolves edited→fixture→nil; the cc
  agent reads it at spawn via the existing template `soul_path` →
  `--append-system-prompt-file`; the editor is gated by the workspace-admin
  **capability** (`ConfigAuth`, `Capability.matches?`). No core change. (PRs #529 storage / #530 editor.)
- **Customer→agent fan-out** rides the native `Routing.Resolver` default rule
  (`$session_users`/`$mentions`) — A synthesizes a `mentions:[cc_uri]` so the
  customer's text reaches the agent. Native, no custom router.
- **Auth** uses the native capability model throughout (operator `Mode.set` cap,
  config workspace-admin cap). No core change.

### G6 — anonymous / unauthenticated customers — GAP / DECISION → Allen
ezagent's Identity/Capability model assumes **identified principals**. A serves
public web chat by **synthesizing anonymous customer URIs**
(`entity://user/<ws>/customer_<id>`); the customer route is public
(`on_mount: :put_locale`, no login) while operator/admin routes correctly require
login. Works, but via a workaround. **Decision for Allen:** is synthetic-customer the
blessed pattern, or should ezagent have a native anonymous/guest principal?

## What this validates (the migration answer)
Customer web chat, editable soul, and operator takeover all run on ezagent using its
native primitives (Session, Chat, Behavior, Capability, Routing, cc agent template)
with the customer_chat plugin staying out of core — **except** the one `Chat`
takeover hook (G3, flagged for Allen). The blocks were either fixed (G1) or are
core-team decisions (G3), and the gaps (G2 lifecycle, G6 anonymous identity) are
documented for ezagent's roadmap. **Migration is feasible.**

## Open coordination
- cc-agent bring-up consolidation PR ownership (theme-picker + OAuth + EagerBridge) —
  with hjj, per #510's 4-track plan (commented on #512).
- Mode (#511) lands first, then PR #532 rebases to drop its bundled Mode copy.
