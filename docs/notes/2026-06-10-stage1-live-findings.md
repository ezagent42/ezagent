# Stage-1 socialware CS — live-run findings + G1 escalation (2026-06-10)

> Live verification of the AutoService→socialware Stage-1 build on an **isolated
> fresh-seeded stack** (per plan `docs/superpowers/plans/2026-06-09-autoservice-socialware-vertical-e2e-stage1.md`,
> Task 0/8/9). Everything below was found by actually running the stack with a
> real cc bot + a real browser session — none of it is reachable from unit tests.

## TL;DR

The Stage-1 **build is unit-green and the backend provisioning works end-to-end
live** (SocialwareSession + cinnox-soul cc bot + claude launched + web UI + login
+ message send/store). It is blocked from a full customer→bot→reply E2E by **two
runtime-lifecycle issues that live in the cc-runtime / rehydration layer (地基,
Allen's domain)**, not in Stage-1 logic — exactly the boundary the plan's Task-0
says to STOP + escalate at.

## What works live (proven)

1. `mix ezagent.demo.seed_autoservice_socialware` seeds clean: `workspace://cinnox`
   + customer `alice` + **SocialwareSession** `session://cinnox/cs/alice` + the
   cinnox soul as a `ConfigObject` + a **cc bot** `entity://cinnox/agent/cs-bot-alice`.
2. The bot's **claude PTY actually launches** with the OAuth token + proxy:
   `PtyServer spawned claude os_pid=… for agent=entity://cinnox/agent/cs-bot-alice`.
   Its sandbox has the right `.mcp.json` (esr-bridge) + `CLAUDE.md` (the 32 KB
   cinnox soul, written directly — see fix #7).
3. Web: `/autoservice` route + plugin boot wired; React/LiveView assets build;
   **alice logs in → customer chat renders → message sends via phx-submit + stores**.
4. On the first run the customer message **routed to the bot** and engaged
   `deliver_ensuring`'s 15 s heal/retry.

## Live-only bugs found & fixed (committed on `feat/autoservice-cs-stage1`)

| # | Finding | Fix |
|---|---|---|
| 1 | seed user URI used legacy 2-segment shape → `:unknown_entity_host` | `Ezagent.URI.user/2` (SPEC v3) |
| 2 | cc `create_agent` rejects missing `:with_pty` | `with_pty: false` (headless bridge bot) |
| 3 | creator-Manage-cap grant dispatches to the creator's Kind; a `system://` principal has none → `:no_such_actor` | seed `ctx.caller` = bootstrap admin user (spawned in the seed BEAM) |
| 4 | re-seed `{:already_exists}` on a fresh BEAM | treat durable existence as success |
| 5 | `CustomerLive.mount` called legacy `CustomerSession.ensure_joined` → would spawn a **bare Session** shadowing the seeded SocialwareSession | `SocialwareCS.ensure_joined/1` (spawns SocialwareSession) |
| 6 | `bot_uri/1` assumed `create_agent` prefixes the flavor (`cc_…`); `compose_agent_uri/3` uses the name as-is → `{:ok, ^bot_uri}` guard never matched | bot_uri matches create_agent's real output |
| 7 | #17 cascade **projection** of the soul needs a create-time `cascade_resolution` a fresh cc agent lacks → `:no_cascade_resolution` | soul written directly as the bot's `CLAUDE.md`; cascade repoint made non-fatal. **GAP**: wiring the soul ConfigObject through #17's create-time cascade (self-evolve re-projection) is deferred |
| 8 | `ezagent_web` didn't dep on / route `ezagent_plugin_autoservice` → plugin (adapter supervision) never booted + no customer-chat route (origin/autoservice also lacked the route) | add dep + `live "/autoservice", CustomerLive` |
| 9 | dev assets unbuilt; socialware React SPA's npm deps (react/sandpack) not installed → esbuild failed → no `app.js` → LiveView WS never connected (form fell back to native GET) | `pnpm install` + `mix assets.build` (env setup, not code) |

## The two remaining blockers — G1 / 地基 (need Allen)

### G1-a — cc bot esr-bridge does not join → deliver timeout (ROOT CAUSE: #512 EagerBridge not merged)
On the first run the customer message routed to the bot, but:
```
[warning] AgentBridge deliver dropped for entity://cinnox/agent/cs-bot-alice: :timeout
invocation chat.receive → cs-bot-alice  duration_us=15004961   # = deliver_ensuring 15s ready-timeout
```
**Root cause (confirmed — this is the documented G-live / PoC-G1 blocker):** a
freshly-spawned cc agent's claude **does not auto-join the `agent_bridge:cc:<uri>`
WS channel** on startup — it sits idle (historically stuck at claude's first-run
onboarding) and never starts/announces its esr-bridge MCP, so `AgentBridge.deliver`
has nothing to deliver to and times out at the 15 s ready window. See
`docs/notes/2026-06-…demo-script` G-live: *"spawn 的 cc agent 卡 onboarding,不
自动 JOIN esr-bridge … 修复 PR #512 `EagerBridge` 未合并进 main"*.

**The fix exists but is NOT on this line.** `EzagentPluginCc.EagerBridge.ensure_bound!/2`
("programmatic MCP bridge init" — the bridge-kick) lives on branches
`feat/eager-bridge` / `fix/cc-bridge-join-2026-06-01`, NOT on `main`/`autoservice`.
So every fresh stack built on main/autoservice lacks the eager bridge-kick → the
bot's bridge never joins → deliver timeout. **This is why the bug recurs across
sessions: the fix never landed on the tested line.**

**Ruled out (so the diagnosis is precise):**
- Identity is correct: the bot's claude process has `EZAGENT_AGENT_URI` +
  `EZAGENT_AGENT_TOKEN` (via `CcAgent.build_claude_cmd/3` `cmd_env`, the #539 path)
  + `CLAUDE_CODE_OAUTH_TOKEN`; the v2 `AgentBridge.TokenStore` WS-join gate is
  satisfied. `.mcp.json` (shared, ws_url only) + `CLAUDE.md` (soul) are present.
- One env artifact compounded it during testing: the bridge WS URL derives from
  the **public port** (default `10042`); a run on `PORT=10052` dialed a dead
  `10042`. Run on `10042` — but even then, without EagerBridge the join is lazy.

**Fix path:** land #512 `EagerBridge` on `main` → flows to `autoservice`; then
`SocialwareCS` provisioning calls (or relies on) `EagerBridge.ensure_bound!/2`
after `create_agent` so the bot's bridge joins eagerly before the first message.

### G1-b — routing registry not rehydrated on server boot
After a server restart, the seed's `{:from customer, :in_session} → bot` rule is
durable in `RuleStore` (DB) but **not loaded into the live routing registry**, so
the customer message stores but **never routes to the bot** (zero `chat.receive`
on the rehydrated node). The seed installs + `load_into_registry`s the rule in its
own (short-lived) BEAM; the running server does not reload it on boot.

## Ask (for Allen)

1. **G1-a**: should an in-session cc bot created via `Workspace.create_agent`
   reliably join its esr-bridge so `chat.receive` delivers, on the isolated stack
   (port-matched)? If there's a known requirement (e.g. the bot must go through
   the #17 create-time cascade to get bridge wiring, which our minimal create path
   bypasses — see fix #7), that's the missing piece.
2. **G1-b**: where should durable routing rules be reloaded into the live registry
   on node boot / session rehydrate? (A `load_into_registry`-on-mount shim in the
   vertical is possible but feels like it belongs in the routing rehydrate path.)

Both are runtime-rehydration / cc-bridge lifecycle — the domain that has been
Allen's since the E1b exploration. Stage-1 application logic is complete + unit-green.
