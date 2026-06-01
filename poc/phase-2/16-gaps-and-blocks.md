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

## ⭐ Meta-finding M1 — ezagent lacks a first-class "customer-service / simple-service session" profile
**This is the PoC's most important strategic finding for the core team.** Three of
the individual gaps below (G2, G6, G7) are not independent — they are **three facets
of one root**: ezagent's session/template model is built for the
**orchestrated, identified, multi-agent workspace app** shape. Customer service is a
**different shape**: an **anonymous end-user** talks to a **single fixed answering
agent** over a **short, often ephemeral conversation**. The framework has no
first-class support for that shape, so a CS vertical must work around it on three
separate axes:

| Facet | Axis | CS needs | ezagent default | Our workaround |
|---|---|---|---|---|
| **G2** | session **lifecycle** | short / ephemeral per-conversation agent | boot-restore long-lived agents | `create_agent` + `remove_template` + GC (fights the framework) |
| **G6** | customer **identity** | anonymous / guest end-user | identified principal (Identity/Capability) | synthesized `entity://user/<ws>/customer_<id>` URIs |
| **G7** | agent **composition** | one declarative fixed agent | runtime LLM-orchestrator only (static slots removed) | plain orchestrator-less template + plugin-side `Routing.add_rule` |

**Recommendation for Allen — bundle, don't patch.** Rather than four scattered
point-fixes, consider a first-class **"service session" profile** that provides, as
one coherent feature: (i) an **anonymous/guest principal** (G6); (ii) a
**declarative fixed-agent + routing** template — restore static slots or an
equivalent (G7); (iii) a **lightweight lifecycle** — no forced orchestrator, optional
ephemeral cleanup (G2 + the `orchestrator: false` / non-fatal-readiness / per-ws
default-seed items in G7). Then a vertical like customer service composes
**natively** instead of working around three axes. (If a full profile is too big,
each facet's narrower fix is listed under G2/G6/G7.)

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

### G2 — agent lifecycle for anonymous / per-conversation customers — GAP (documented) · *facet of M1 (lifecycle axis)*
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

**This conflicts directly with the plugin's reason for existing — serving many
anonymous users — and gets WORSE with scale, not better:**
- Customer service is **high-cardinality, short-lived, anonymous** agents (one cc per
  anonymous conversation). Boot-restore assumes the opposite: **few, long-lived,
  owned** agents that all rehydrate on restart. The two models are fundamentally
  mismatched.
- The `remove_template`-per-agent dance is a **per-agent opt-out of a default that is
  wrong for this whole vertical**. It is fragile at scale: **any** path that registers
  an agent without reaching `remove_template` (exception, crash mid-flow, a new entry
  point, the manual/test paths) leaves a **permanent** registration that re-spawns on
  every boot. We have **empirical evidence** of exactly this — stray `cc_wait_*` agents
  from earlier experiments kept getting boot-restored on every server start (2026-06-02;
  ops detail in the PoC's leftover-agents investigation note). Even if every path is
  correct, restoring N historical conversations means **O(N) claude-PTY spawns at boot**
  — untenable for a real CS deployment.
- **Therefore the "service session" profile (M1) must own a lifecycle where
  anonymous/ephemeral service agents are NOT boot-restored by default** — not leave
  the plugin to cancel boot-restore one agent at a time. This raises G2 from "a documented
  inconvenience" to "a scaling blocker for the anonymous-multi-user case the plugin is
  built for."

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

### G6 — anonymous / unauthenticated customers — GAP / DECISION → Allen · *facet of M1 (identity axis)*
ezagent's Identity/Capability model assumes **identified principals**. A serves
public web chat by **synthesizing anonymous customer URIs**
(`entity://user/<ws>/customer_<id>`); the customer route is public
(`on_mount: :put_locale`, no login) while operator/admin routes correctly require
login. Works, but via a workaround. **Decision for Allen:** is synthetic-customer the
blessed pattern, or should ezagent have a native anonymous/guest principal?

### G7 — no native "fixed-agent team" / orchestrator-less composition path — GAP / DECISION → Allen · *facet of M1 (composition axis)*
Surfaced while manually testing customer chat (first message got no reply). The
full chain we had to face to get ONE fixed CS agent answering in a session:
1. **A per-tenant workspace has no `"default"` session template** — boot seeds the
   default template only under `workspace://system` (`do_seed_default_session_template`
   hardcodes it). acme had none → `create_session(template_name: "default")` →
   `{:session_template_not_found, "default", "acme"}`.
2. **The system `"default"` template forces a cc-orchestrator.** In the current
   ezagent, **static `agent_slots` / routing-rule reconcile at session-create were
   REMOVED** (`session_template.ex:118`, 2026-05-31 atomicity pass): the *only*
   way the framework composes worker agents into a session is the **runtime LLM
   orchestrator**. A plain session composes nothing.
3. **That orchestrator can't start here.** Its template sets an isolated
   `claude_config_dir` (`cc_orchestrator_seed.ex:228/380`, `api_key_helper: nil`)
   → a fresh CLAUDE_CONFIG_DIR → the **claude 2.1.92 OAuth screen** (same G1 trap)
   → never ready → `create_session` blocks `{:orchestrator_not_ready_within, 90_000}`
   → session never spawns → `chat.send` → `:no_such_actor` → no reply.

**Our fix (no core change):** customer_chat ensures a **plain (orchestrator-less)
`"default"` session template** per workspace (`session_complete?` already treats a
nil-orchestrator template as a complete plain session), and composes the cc agent
+ routing **plugin-side** — an explicit `Routing.add_rule` customer→cc (replacing
the prior mention-synthesis).

**The decision for Allen (the "does it have to be this heavy / this many problems?"
question):** for a *deterministic, fixed-agent* vertical (customer service, fixed
pipelines), the LLM orchestrator is the wrong tool (extra claude PTY/session,
non-deterministic, OAuth-trapped), and there is **no native declarative path**.
Should ezagent offer one or more of:
- **(a)** a declarative **static-agent-slot / fixed-team** session template
  (restore what §3 removed) so a session can be born with a known agent + routing,
  no orchestrator, no plugin-side composition;
- **(b)** a **`create_session(orchestrator: false)`** opt-out (the long-standing
  deferred note) so callers don't need to pre-seed a plain template;
- **(c)** **per-workspace default-template** provisioning at workspace create (so a
  tenant workspace isn't missing `"default"`);
- **(d)** non-fatal / fast-fail **orchestrator readiness** (90 s hard block on a
  dead orchestrator is brutal for any caller).

Until then, customer_chat's orchestrator-less plain-template + plugin-side routing
is the correct fit, but it's more bookkeeping than a first-class framework path
would need.

## What this validates (the migration answer)
Customer web chat, editable soul, and operator takeover all run on ezagent using its
native primitives (Session, Chat, Behavior, Capability, Routing, cc agent template)
with the customer_chat plugin staying out of core — **except** the one `Chat`
takeover hook (G3, flagged for Allen). The blocks were either fixed (G1) or are
core-team decisions (G3), and the gaps (G2 lifecycle, G6 anonymous identity) are
documented for ezagent's roadmap. **Migration is feasible.**

## PR map & recommended review order (2026-06-02)
Six open PRs deliver this PoC: the three-piece PoC stack plus the three framework
changes it depends on. All have a Chinese-first consolidated description (English
folded) + the same review-order block pinned at the top; demos (acme) are embedded
in the PoC three.

**Group 1 — framework basics (mutually independent, all → `main`, mergeable in parallel):**
1. **#515** formatter DSL-macro registration — unblocks the `mix format --check-formatted`
   commit gate (every fresh-checkout commit is blocked otherwise). Merge first; trivial.
   Residual decision for Allen: toolchain version pin (`.tool-versions`/`mise.toml`).
2. **#512** `EagerBridge` — the primitive that binds a cc agent's esr-bridge MCP before
   the first customer message (fixes **G1**). **#529 depends on it.**
3. **#511** `Behavior.Mode` + `Chat.handle_send` takeover gating — the Mode impl.
   **#532 depends on it** (#532 currently bundles its files).

**Group 2 — PoC three-piece stack:**
4. **#529** PR-1 AI customer web chat (base, → `main`; conceptually builds on #512).
5. **#530** PR-2 editable soul (stacked on #529). No core change (**G5**, no decision).
6. **#532** PR-3 operator console + takeover (stacked on #529; after **#511** merges,
   rebase to drop the bundled Mode). Carries the **G3** decision.

Decisions for Allen, by PR: **#529** → whether to offer a first-class "service session"
profile (bundles G2+G6+G7; options (a)–(d) in G7); **#532** → the G3 core `Chat`
hook vs. zero-core pure-routing (pros/cons + the Copilot trade-off, see
`14-takeover-routing-evolution`); **#515** → toolchain pin choice. #511/#512/#530 carry
no independent decision.

## Open coordination
- cc-agent bring-up consolidation PR ownership (theme-picker + OAuth + EagerBridge) —
  with hjj, per #510's 4-track plan (commented on #512).
- Mode (#511) lands first, then PR #532 rebases to drop its bundled Mode copy.
