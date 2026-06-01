# Scenario 34: Sender-locked relay (传话游戏) — full star-cycle via legend + rule-set + prompt-template

**Category**: 3 — Session flows (orchestration, multi-agent routing)
**Status**: 🚧 deterministic tier IMPLEMENTED + green; live tier = Allen runbook
**Author**: Claude, team-routing-unification PR-9 (spec §9, plan PR-9)

> Bilingual lockstep mirror: [`scenario.zh_cn.md`](./scenario.zh_cn.md).

## Intent

The 传话游戏 ("telephone / pass-the-message") relay is the headline worked
example of the **team-routing-unification** cutover (spec §4). A user
`@`-mentions a **legend** and a message relays cc → codex → curl, each agent
appending a line, with the per-hop "you are playing telephone" context injected
by a **prompt template** — expressed PURELY via **legend + rule-set +
prompt-template**, with **NO baton token and NO model-computed routing**. The
routing table IS the chain.

This is the scenario that motivated the whole refactor: pre-cutover the relay's
workers were `agent_slots` (not session members), so `@`-mention silently went
nowhere (spec §1). Post-cutover the relay is three first-class **members** wired
by a named **rule-set** of single-receiver `{:from, X} → Y` rules, fronted by a
**legend** handle.

## The relay topology (spec §4)

```
@传话游戏 ──(legend entry rule: mention(传话游戏))──▶ relay-cc
relay-cc ──(from(relay-cc))──▶ relay-codex
relay-codex ──(from(relay-codex))──▶ relay-curl      (TERMINAL — linear chain)
```

- **Legend** `传话游戏`: `member_set = [relay-cc, relay-codex, relay-curl]` (by
  role_name), `fold: true`, `bound_rule_set: "telephone"`.
- **Rule-set `telephone`** — single-receiver each, shared prompt template
  `telephone_hop`:
  - pos 0 (ENTRY): `mention(传话游戏) → relay-cc`
  - pos 1: `from(relay-cc) → relay-codex`
  - pos 2: `from(relay-codex) → relay-curl`
- **Prompt template** `telephone_hop` =
  `"你在玩传话接龙。目前内容：\n{body}\n请只追加一句简短的话。"` (must contain
  `{body}` — validated at write time).
- **Members** (relay agents): `role_name` set, `in_session_template: true`, so
  the whole team snapshots into a SessionTemplate for reuse.

**Why "full star-cycle" = this linear chain (NOT a closed loop):** the spec §4
worked example terminates at curl — there is no `from(relay-curl)` rule, so the
chain ends and curl's reply mirrors OUT (to humans / Feishu) without looping
back. ("Full star" refers to exercising all three agent flavors — cc + codex +
curl — the same matrix as Scenario 33, here driven by the relay rule-set.)

## The no-baton invariant (the property under test)

Routing advances ONLY by **sender identity**: the only thing that fires the next
hop is `{:from, <previous-member-uri>}` matching the SENDER of whatever the
previous agent emitted. No matcher reads a baton / `next_hop` / token field of
the message body, and no receiver is derived from message content. A model never
computes a route — the rule-set table encodes the chain statically. This is the
`feedback_completion_requires_invariant_test` structural gate.

## How it is built (member + rule-set + legend + prompt-template, NO baton)

Via the orchestrator MCP tools (`Ezagent.Orchestrator.Tools`, spec §3.8) — one
live call at a time, the same way SessionTemplate materialization builds a team
(PR-7):

1. `add_managed_member(<cc-template>, "relay-cc", true)` — spawn + join relay-cc.
2. `add_managed_member(<codex-template>, "relay-codex", true)` — relay-codex.
3. `add_managed_member(<curl-template>, "relay-curl", true)` — relay-curl.
4. `define_prompt_template("telephone_hop", "你在玩传话接龙。目前内容：\n{body}\n请只追加一句简短的话。")`.
5. `define_rule_set_rule(mention(传话游戏), "relay-cc", rule_set: "telephone", position: 0, prompt_template_ref: "telephone_hop")`.
6. `define_rule_set_rule(from(relay-cc-uri), "relay-codex", rule_set: "telephone", position: 1, prompt_template_ref: "telephone_hop")`.
7. `define_rule_set_rule(from(relay-codex-uri), "relay-curl", rule_set: "telephone", position: 2, prompt_template_ref: "telephone_hop")`.
8. `define_legend("传话游戏", ["relay-cc","relay-codex","relay-curl"], "telephone", true)`.

(`{:from, X}` rule's `X` is the member's resolved URI; `define_rule_set_rule`
resolves a receiver `role_name` to the live member URI.)

## Verification — TWO tiers

### Tier 1 — Deterministic resolver-level invariant test (CI, MUST pass)

**File**: `apps/ezagent_core/test/e2e/scenario_34_sender_locked_relay_test.exs`.

Builds the `telephone` rule-set into an isolated `RoutingRegistry` ETS table
(the production load shape) and asserts, at the routing layer
(`Resolver.resolve_with_ctx/4` + `Matcher`, NO live agents, NO DB, NO model):

- **GATE (a)** — the legend entry fires: `@传话游戏` (via the virtual
  `legend_triggers`, NOT `:mentions`) resolves to `relay-cc`, carrying
  `prompt_template_ref: "telephone_hop"`.
- **GATE (b)** — each `{:from, X}` hop routes to the next, carrying the
  `telephone_hop` ctx; `relay-curl` is TERMINAL (resolves to no hop).
- **GATE (c)** — the FULL chain resolves end-to-end driven PURELY by feeding the
  prior recipient as the next sender (no model in the loop), producing the
  ordered topology `[relay-cc, relay-codex, relay-curl]`; AND a structural
  no-baton gate asserting every matcher reads sender/legend only (never body
  content), every receiver is a static member URI, and each hop is
  single-receiver (§3.3).
- **GATE (b-variant)** — the same legend-trigger machinery also drives a
  `$session_members` broadcast (spec §5 semantics B) — no new primitive.

Run:

```bash
cd apps/ezagent_core && MIX_ENV=test mix test \
  test/e2e/scenario_34_sender_locked_relay_test.exs
```

8 tests, 0 failures.

### Tier 2 — LIVE runbook (Allen's environment — the TRUE gate, Standard 3)

**Harness**:
`apps/ezagent_domain_chat/test/e2e/scenario_34_sender_locked_relay_live_test.exs`
— `@moduletag :live`, SKIPPED by default; un-gated only by `SCENARIO_34_LIVE=1`.
It does NOT fake a live pass and it does NOT pass on env-vars-only. After Allen
sends the real `@传话游戏 <word>`, the harness **polls the live session for the
delivered + rendered relay** via the SAME production read path the system uses
(`Ezagent.MessageStore.recent_in_session/2` — the query backing the LV chat
slice `:last_message` and rejoin-replay), looking for a message whose body was
rendered by the `telephone_hop` prompt template (i.e. carries the template's
literal wrapper text — proof that `render_for_delivery/4` injected the template
at the hop, so the chain reached a real templated delivery). If that evidence
does not appear within the poll budget (default 45s, every 1.5s) it
**`flunk/1`s** with what was expected vs. seen — it never `assert true`s. The
agent-browser screenshot remains an inherently manual, agent-side step.

**Programmatically-observable assertion vs. manual step**:

- ASSERTED by the harness (read through the production path): a
  `telephone_hop`-rendered `chat.receive` landed in `SCENARIO_34_SESSION_URI`.
  Optionally tighten the gate to the codex→curl hop by exporting the resolved
  member URIs (the sender of the final hop):
  ```bash
  export SCENARIO_34_RELAY_CODEX_URI=entity://agent/<ws>/<relay-codex>  # sender of final hop
  export SCENARIO_34_RELAY_CURL_URI=entity://agent/<ws>/<relay-curl>    # optional hint
  # override the marker if define_prompt_template used different text:
  export SCENARIO_34_HOP_TEMPLATE_MARKER=你在玩传话接龙
  # override the poll budget/cadence if needed:
  export SCENARIO_34_OBSERVE_TIMEOUT_MS=45000
  export SCENARIO_34_OBSERVE_INTERVAL_MS=1500
  ```
- MANUAL (NOT assertable from inside the test): the agent-browser screenshot of
  the Feishu group thread (step 5 below) — Standard 3 mandatory evidence Allen
  captures agent-side.

**EXACT user-assist steps Allen must do** (these need Allen's environment —
running services, real Feishu group, provider creds, agent-browser):

1. **Start services** — `make run-server` with the orchestrator + relay worker
   services up, reachable at `http://100.64.0.27:10042` (Tailscale IP — Allen is
   remote, `feedback_remote_browser_ip`).
2. **Seed + bind the relay team** in the ESR Feishu group (exactly ONE binding
   per chat): build the team via the 8 orchestrator-tool calls above (or
   materialize a saved SessionTemplate), then export the bindings:
   ```bash
   export SCENARIO_34_FEISHU_CHAT_ID=oc_xxxxxxxxxxxxxxxx   # the bound group chat_id
   export SCENARIO_34_SESSION_URI=session://generic/<ws>/<relay-session>
   ```
3. **Provider creds — ALL three flavors live**: Anthropic (cc, via proxy),
   `codex login` (codex), DeepSeek key (curl). A missing cred is a user-assist
   step, NOT a silently-stubbed pass (`feedback_esr_e2e_standards`).
4. **Send a REAL Feishu message** from the bound group: `@传话游戏 苹果`. (A
   programmatic dispatch / `send_cursor` read is NOT sufficient — Standard 3
   requires a real inbound Feishu message.)
5. **Run the gated harness** — it polls the live session and ASSERTS the
   delivered + `telephone_hop`-rendered relay round-trip (flunks if it never
   arrives within the budget):
   ```bash
   SCENARIO_34_LIVE=1 MIX_ENV=test mix test \
     apps/ezagent_domain_chat/test/e2e/scenario_34_sender_locked_relay_live_test.exs
   ```
   It reads `MessageStore.recent_in_session/2` (production path) and watches for
   a `telephone_hop`-rendered message. Optionally tighten the gate with
   `SCENARIO_34_RELAY_CODEX_URI` (sender of the final codex→curl hop). Also
   confirm in the phx log: relay-cc → relay-codex → relay-curl each emit a
   `chat.receive` rendered with `telephone_hop`, and each reply mirrors OUT
   (`FeishuClient.send_text OK (code=0)`).
6. **agent-browser screenshot** of the group thread showing the full relay
   round-trip — MANUAL, agent-side (Standard 3 mandatory evidence; the harness
   cannot capture this from inside the test process):
   ```bash
   agent-browser open  http://100.64.0.27:10042     # or the Feishu web group
   agent-browser screenshot  /tmp/scenario34-relay-roundtrip.png
   ```

## Failure modes

- **Slot mechanism regression** — if `add_agent_slot` / `write_matcher`
  reappears, the relay would route by slot-name not member, breaking the
  `@`-mention. Covered by `orchestrator_slot_retirement_test.exs` (PR-8) +
  Tier-1 GATE (c) no-baton structural check.
- **Body-derived routing** — if a hop matcher were changed to
  `text_contains(<token>)`, the model would be computing the route. Tier-1 GATE
  (c) Property 1 fails on any content-reading matcher.
- **Missing `{body}` in `telephone_hop`** — the renderer would drop the original
  message. `define_prompt_template` rejects it at the tool boundary
  (`:body_placeholder_required`).
- **Legend mis-routes through URI path** — a CJK legend name reaching `:mentions`
  crashes the `[URI.t()]` cast; the legend rides the virtual `legend_triggers`
  instead (Tier-1 GATE a).

## Cross-references

- Spec: `docs/superpowers/specs/2026-06-01-team-routing-unification.md` §4
  (worked example), §3.3 (rule-set), §3.4 (prompt-template/path-A), §3.6
  (legend), §9 (testing). Plan PR-9.
- Composes the routing primitives from PR-2..PR-8: Resolver `resolve_with_ctx`,
  `Ezagent.Routing.Legend`, `Ezagent.Routing.Matcher` `{:from,_}`/`{:mention,_}`,
  `Ezagent.Routing.PromptTemplate`, the `Ezagent.Orchestrator.Tools`
  member/rule-set tools.
- Mirrors Scenario 33 (full-star, all flavors) but driven by the relay rule-set
  + legend instead of per-flavor orchestrator @-mentions.
- Standards: `feedback_esr_e2e_standards` (live Feishu-group sync, Standard 3),
  `feedback_completion_requires_invariant_test` (the no-baton structural gate),
  `feedback_remote_browser_ip` (Tailscale IP for agent-browser).
