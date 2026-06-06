# Design synthesis: socialware — the fused backend-agent + real-time-render app pattern

> **Status:** design synthesis for discussion (Allen 2026-06-07). Built from a 3-track
> read of the AutoService + loom branches (#529/#511/#514/#525/#526/#543/#538 service
> side; #530/#532/#572/#510/#427 config/soul side; #480 loom). Not yet a buildable spec —
> the goal here is to (1) summarize what AutoService's backend actually did, (2) assess
> migration form, (3) refine Allen's mental model against the code, (4) state
> implementability, and (5) propose the socialware abstraction + the open decisions.

## 1. What AutoService's backend actually built (ignoring its frontend)

Two parallel concerns, both **plugin-tier** (the only domain touch is `Behavior.Mode`):

**Service side (customer ↔ bot ↔ operator).** A CS conversation is a **plain
`Ezagent.Entity.Session` Kind spawned directly** (NOT a SessionTemplate — the
LLM-orchestrator generator is bypassed because a fixed CS crew needs no team-composition
reasoning). Members: a **customer-user** (synthetic/anon in the PoC), a **fast bot** =
`curl.agent` Kind (HTTP→DeepSeek, no PTY), an optional **slow bot** = `cc` Kind, and an
**operator-user** who joins lazily. The "bot" is **an Agent Kind + one routing rule +
content** — not a Behavior or a "ruleset" object. Inbound routing is a single
`RuleStore` rule `{:and, [{:in_session, s}, {:from, customer}]} → [fast | slow]`; the
bot→customer reply is the default Chat fan-out. The bot's persona ("soul") is injected as
the agent template's `system_prompt`.

**Takeover** = `Ezagent.Behavior.Mode` (#511): a session-level slice `%{mode: :auto |
:takeover}` + a gate in `Chat.handle_send` — under `:takeover`, an **agent-sender**
message is **suppressed at the customer surface but still persisted + shown to operator
subscribers**; the customer→bot route is untouched so the **bot keeps receiving + still
generates**; the **operator** (user-sender) is not suppressed, so they reply instead.
23 tests green; the most production-ready piece.

**Config side.** The bot's soul is edited via a **LiveView editor + file store**
(`SoulStore`: `souls/<role>.md` + one-step `.prev` + immutable fixture), gated on the
**workspace-admin cap**; a new conversation's agent picks up the soul **at spawn**. The
richer **soul/skill/kb 3-layer slot model** (#572) and the **cross-session
auto-optimization** ("Dream" / a Template Authoring Agent that reviews transcripts) are
**spec/design only — zero code**.

**Implemented vs not:** Mode/takeover + the file-based soul editor + the provision
reconciler (curl fast-bot path) are real. The closed PRs (#514/#525/#526/#543) are
**superseded, not rejected** (re-homed/decomposed). NOT built: the copilot/suggestion
half of takeover, the slot model, cross-session optimization, Pipeline-v2 orchestration
(filler/timeout/circuit-breaker), branded SSE customer channel, KB-as-entity.

## 2. Migration: can it move to ezagent, and in what form?

**The service-side pattern already runs on current ezagent** — it *is* the
`autoservice`/`customer_chat` plugins. The form is **a plugin** (the vertical) **+ one
small domain Behavior** (`Mode`) **+ existing primitives** (Session/Agent Kinds, RuleStore
routing, CapBAC bundles, MCP sidecar for KB). No SessionTemplate is required by the current
code. The standing recommendation in the #427 eval was **hybrid** (keep the AutoService
Python pipeline, port its 12 session-flow optimizations into `ezagent_domain_chat`) — but
that is about migrating the *existing product*. For **socialware** (the generalized,
native pattern) we build the orchestration core in ezagent directly.

So the migration form for socialware = **a new ezagent app/framework** (a base
SessionTemplate class + the orchestration/card/render/mode/config machinery) that
verticals specialize — not a port of the Python pipeline.

## 3. Allen's mental model — refined against the code

**Session 1 (service) — accurate in spirit; two corrections:**
- Your "customer-user → ruleset (autoservice-bot) → reply" is, in code, *customer-user →
  routing rule `{:from customer}` → bot **Agent Kind** → default fan-out reply*. The
  "ruleset" = (the routing rule) + (the bot agent's soul/skill/kb). Fine to think of it as
  a ruleset; just note the bot is a first-class Agent, and the "rule" is one RuleStore row.
- Takeover is **NOT route-removal**. It's `Behavior.Mode` + a Chat gate that **suppresses
  the bot's reply at the customer surface** (still persisted + shown to the operator) while
  the customer→bot route stays and the **bot keeps receiving + generating**. So your "bot
  still receives all and gives suggestions, operator replies instead" is *exactly the
  intended design* — but only two of its three parts are built: ✅ bot keeps receiving, ✅
  operator replies; ❌ **"bot gives the operator suggestions" (copilot) is NOT built** —
  only the suppress-but-persist substrate exists; `:copilot` is a stubbed future mode.

**Session 2 (config/optimization) — partially exists, and NOT as a session today:**
- "A session to **configure** the bot" → in code this is a **LiveView editor + files**, not
  a session. The *session-shaped* version of it is the #572 **Template Authoring Agent** (a
  cc agent, in the system workspace, that edits templates via `template.read`/`template.write`
  + bash) — which is **spec-only, zero code**. So your "config session" = that authoring
  agent, not yet built.
- "...and **scrapes other sessions for auto-optimization**" → **not implemented at all.**
  The design intent exists ("Dream" self-evolution; cold-start transcript review), but there
  is **no runtime substrate** to harvest other sessions' transcripts/telemetry and feed them
  back. This is the single biggest missing capability.

**Net:** your model is right; the deltas are (a) takeover is a Mode-gate not a route-removal,
(b) copilot-suggestions is unbuilt, (c) the "config/optimization session" is a spec-only
authoring agent + a genuinely-missing cross-session harvesting loop.

## 4. Implementability on current ezagent (per capability)

| Capability | Now? | Form |
|---|---|---|
| Service session (customer/bot/operator) | ✅ runs | plugin + Session/Agent Kinds + 1 routing rule + cap bundles |
| Takeover (auto ↔ operator) | ✅ runs | `Behavior.Mode` + Chat gate (#511) |
| Copilot (bot suggests to operator) | ⚠️ substrate only | needs a `:copilot` mode + an operator "draft/suggestion" projection |
| Soul editing | ✅ runs (crude) | LiveView + file `SoulStore`; richer slot model = #572 spec (~380 LOC, 0 core) |
| soul/skill/kb 3-layer | ⚠️ spec only | slot values as a flavor-owned `AgentTemplate` content key; **this is a credential/config-cascade use case** (workspace provides the soul/skill/kb layers; the agent materializes them — see #17 cascade) |
| Cross-session auto-optimization | ❌ greenfield | needs a transcript/telemetry harvest substrate + the authoring agent feedback loop |
| loom-style HTML/render output | ✅ runs (loom) | typed `<span type=page_update>` card + SSE bridge + Sandpack iframe |
| Interim "soothe while waiting" (Pipeline-v2 filler) | ❌ | no interim-streaming primitive in dispatch |

**Cross-cutting prerequisites (from the research):** `{:within_workspace, _}` CapBAC shape
(HIGH — for tenant-admin + customer isolation), an `Ezagent.CircuitBreaker` primitive,
template-update-without-full-respawn, an anon/synthetic-customer identity model, and an
interim-streaming primitive (for filler loops). loom's behaviors also use the **legacy
`use Ezagent.Behavior`** surface — socialware should re-express on the **`use
Ezagent.Lifecycle`** macro.

## 5. The socialware abstraction

The loom + AutoService reads converge on one structure. **socialware = an
output-format-agnostic orchestration core + a pluggable typed-card output contract + a
generic render/projection layer + a human-in-the-loop mode plane + a config/optimization
plane.** AutoService and loom are the *same machine* with different card-type sets +
renderers.

### 5.1 Orchestration core (shared, output-agnostic) — generalize loom, on the Lifecycle macro
- A **socialware session** = a session with a fixed, mention-gated crew:
  - **orchestrator** — classify the user turn → fan-out subtasks (`@mention` `chat.send`,
    `ref_id` correlation, **no baton tokens**) → event-driven aggregate → compose a reply;
  - **workers** — each produces a typed-card deliverable for one subtask;
  - **team-manager** — NL "add/remove/list worker" → `spawn`/`chat.join`·`leave`/`terminate`,
    **zero new caps** (loom's `loommeta`);
  - **human roles** — customer / operator / admin, as **cap bundles** (not a new primitive).
- Lifecycle: **template-class spawn** + **cleanup propagation** (duck-typed `cleanup/3` +
  ghost-filter, generalized into a real callback contract).

### 5.2 Typed-card output contract (the pluggable seam) — generalize loom's `<span type=…>`
- A **closed, per-vertical card-type set** on the chat stream, plus a base set. Two
  families: **NL/data cards** (`text/notice/services/…`) → chat bubble (AutoService); and
  **render cards** (`page_update`/`html`/…) → a render layer (loom). Workers emit cards;
  the orchestrator composes; the card contract IS the agent↔frontend interface.

### 5.3 Render/projection layer (the "frontend real-time rendering" fusion) — generalize loom's WebPlug SSE
- A **generic projector** subscribes to the session chat stream (SSE/Channel) and
  dispatches per card type: NL → bubble; render-card → live-render (HTML→Sandpack/iframe
  today; pluggable renderers later). **This is the loom+autoservice fusion**: one session
  stream drives BOTH a conversational surface AND a live-rendered surface, selected by card
  type. (loom's projector is loom-specific today; socialware makes it reusable + card-routed.)

### 5.4 Mode plane (human-in-the-loop) — generalize `Behavior.Mode`
- A socialware-core Behavior with `:auto` (bot replies) / `:takeover` (operator replies,
  bot suppressed-but-receiving) / **`:copilot`** (bot's output is shown to the operator as a
  *draft/suggestion*, not sent to the customer until the operator approves/edits). Copilot is
  the unbuilt third state; it reuses the existing suppress-but-persist substrate + a projected
  "suggestion" card to the operator surface.

### 5.5 Config + self-optimization plane — generalize soul/skill/kb + the authoring agent, on the cascade
- Each worker's behavior = **soul (inline slots) + reference (on-disk) + kb (queryable)**
  (#572). Editing = a slot editor surface. **This sits directly on the #17 credential/config
  cascade**: the cascade's layered resolution (workspace provides the soul/skill/kb template
  layer; user/session overlay; the agent materializes at spawn) is exactly the substrate the
  soul/skill/kb model needs — socialware's per-agent config is a cascade *config layer*.
- **Self-optimization** = a config/authoring **session** where an authoring agent harvests
  session transcripts (the missing telemetry substrate) and proposes slot-value / reference
  updates (human-reviewed). This is the greenfield piece.

### 5.6 The two verticals as specializations
- **AutoService** = socialware with NL card types + the `auto/takeover/copilot` modes + the
  service crew (customer/bot/operator).
- **loom** = socialware with render card types (`page_update`) + the Sandpack render layer.
- "Future systems use the same pattern" = declare a crew + a card-type set + a renderer + a
  mode set + a soul/skill/kb config — and you have a new socialware vertical.

## 6. Open architectural decisions (need Allen)
1. **Is socialware a FRAMEWORK or an app?** Recommendation: a **base SessionTemplate class
   `session.socialware`** + the core machinery (orchestrator/card/render/mode/config), which
   verticals (`session.autoservice`, `session.loom`) specialize by declaring crew + card-types
   + renderer + modes + config. (Matches "future systems use the same pattern.")
2. **Card-type contract shape** — a base set + per-vertical closed extension; how the
   projector registers renderers per card type. (Loom's `@known_types` closed list → a
   registry.)
3. **Re-express loom on the Lifecycle macro** (it uses the legacy Behavior surface) as part
   of folding it into socialware — or wrap, not rewrite? (Recommend rewrite onto Lifecycle for
   invariant-cleanliness, since socialware is the durable home.)
4. **Build order of the missing pieces:** `:copilot` mode, the reusable card-routed projector,
   the soul/skill/kb slot model (#572) on the cascade, the self-optimization harvest substrate.
5. **Prerequisites:** schedule `{:within_workspace}` cap, CircuitBreaker, interim-streaming
   primitive, anon-customer identity — which are socialware-blocking vs deferrable?

## 7. Proposed phasing (after the decisions)
- **P0 (prereqs):** `{:within_workspace}` cap; re-express the orchestration core on the
  Lifecycle macro; the card-type contract + a card-routed projector (extract loom's SSE bridge).
- **P1 (core framework):** `session.socialware` base class — orchestrator + workers +
  team-manager + cleanup contract; the mode plane (`auto/takeover/copilot`).
- **P2 (config plane):** soul/skill/kb slot model on the #17 cascade; the slot editor.
- **P3 (verticals):** re-home AutoService (NL cards) + loom (render cards) as `session.*`
  specializations of `session.socialware`.
- **P4 (self-optimization):** transcript/telemetry harvest + the authoring-agent feedback loop.
- Cross-cutting deferred: Pipeline-v2 filler/circuit-breaker (interim-streaming primitive),
  branded customer channel.

This depends on the #17 credential/config cascade (the config plane sits on it) — socialware
is, in effect, the first big *consumer* of that cascade.
