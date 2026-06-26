# Extending agents without violating the architecture

> A short, reference-able checklist for adding a new agent type or a new
> rendering/feed capability — so two easy-to-miss architecture violations don't
> recur. This is the constructive "how to align" companion to the red lines
> already in `docs/together/contributing/README.md` (台账 P0–P3) and the
> principles in `.claude/skills/ezagent-developer/references/design-principles.md`.
> Chinese: [`extending-agents-without-violating-the-architecture.zh_cn.md`](extending-agents-without-violating-the-architecture.zh_cn.md).

Two recent PRs were **complete, working, and well-tested** — yet had to be
re-shaped because they crossed two architectural lines. Both are honest mistakes
that are invisible to "tests pass" (design-principle **P6**: a passing test suite
doesn't prove an invariant is held). This guide makes them catchable *before* you
write code.

---

## Pre-flight checklist (read this BEFORE writing code)

Run these four checks against any agent/feed/render task. Any "yes" in the STOP
column means: pause and re-align with the lead (台账 **P0**) before implementing.

| Check | If yes → |
| --- | --- |
| **1. Am I adding a new `Ezagent.Entity.*` Kind** (e.g. `Entity.Salesperson`, `Entity.Advisor`) for an agent type? | **STOP.** A new agent type is almost always a **role × flavor** on the unified `Entity.Agent`, *not* a new Kind. See §1 + worked example A. |
| **2. Am I bundling business logic into a platform path** — a generic mechanism (render/feed/transport/dispatch) gated by, or routed through, a specific business persona/producer/cap (`:salesperson`, "the salesperson renders the card")? | **STOP.** Separate the **mechanism** (generic, producer-agnostic) from the **producer** (your business agent, which merely *consumes* it). See §2 + worked example B. |
| **3. Does a generic mechanism for this already exist?** Grep the transport/registry before building one: `git grep -n "render\|json-render\|feed_encoding\|RoleRegistry\|agent_flavors" -- apps/`. | If yes → **consume it**, don't fork a parallel one (台账 **P2**: foundations first). |
| **4. Does my new thing make a plugin author learn *one more* concept, or *one fewer*?** (design-principle **P8**) | One more → reject the design. One fewer → good. New Kind = one more; role-on-existing-flavor = one fewer. |

If checks 1–2 are clean, you're extending the architecture *with* the grain.

---

## The two principles, in plain terms

### Principle 1 — A new agent type is a **role × flavor**, never its own Kind

**The rule (ezagent-specific):** `agent = role (what it does) × flavor (how it
executes)`. The flavor is an existing host — `cc` / `codex` / `py` / `curl` /
`native` — whose Kind is the unified `Ezagent.Entity.Agent`. The role is a
*recipe* (behaviors + caps + skills + prompt) loaded **per-instance** at create
via the role-foundation machinery (#54). You add an agent type by registering a
recipe through the `roles/0` plugin callback — you do **not** write an
`Entity.<Type>` module.

**Why own-Kind-per-type was retired:** the codebase did exactly this once
(`Entity.PyAgent` and friends) and unified it away in P4b → one `Entity.Agent`.
A per-type Kind violates the **plugin-isolation north star** (P1) and **P24**
(plugins extend existing schemes, they don't mint new core primitives): every new
Kind drags create-path branches, its own snapshot/cap wiring, and a routing
identity (`entity://agent/*` gives chat-principal semantics — @-mentionable,
joinable — "for free", which a passive data agent must *not* have). It also fails
**P9** ("reads what data decides the tier") — a salesperson reads chat like every
other agent, so it is not a new core concept. The canonical fix already shipped:
**kanban-as-role** retired the standalone Kanban Kind and re-homed its 24
behaviors into a `kanban-manager` role on the `native` flavor.

> 台账 **P3** states this red line directly: `agent = 角色×风味`.

### Principle 2 — Platform **mechanism** must be separable from **business** logic

**The rule:** a generic platform capability (a render transport, a feed encoder,
a dispatch path) is **producer-agnostic**. Any agent can produce into it; it
neither names nor depends on a specific business persona, and it is **not** gated
by a business-specific capability. The business agent is a *fixture/role* that
**consumes** the generic capability — it does not bake the capability into
itself.

**Why mechanism ≠ business:** if the render path only works "through the
salesperson" (and behind a `:salesperson` cap), then the next producer
(advisor, support bot, dashboard) must either re-implement the transport or
impersonate a salesperson — both are P1/P3 violations (parallel SoTs, plugin
authors carving private worlds). Coupling also makes the generic capability
untestable in isolation (P12: "can this be reproduced via `dispatch/1` without
the persona?"). The render catalog already proves the intended shape — its
comment explicitly keeps node types *"so existing producers, **e.g. advisor**,
render"* (`apps/ezagent_domain_socialware/assets/js/catalog.mjs:52`): the render
path serves whichever producer emits a conforming tree.

> This is the one lesson not yet its own 台账 entry — internalize it: **build the
> mechanism standalone (transport-only); let business agents consume it.**

---

## The two cases, worked through

### A. `Entity.Salesperson` → role × flavor (or: just the mechanism)

- **What happened:** a new own-Kind `Ezagent.Entity.Salesperson` for a chat agent.
- **Why it's the anti-pattern:** identical to the `Entity.PyAgent` Kind retired in
  P4b; a salesperson is a chat participant like any other agent — no new core
  concept (P9), and a new Kind breaks P1/P24 and gives unwanted principal
  semantics.
- **The aligned shape:** define a **`salesperson` role recipe** and register it
  via `roles/0`; host it on an existing flavor (`cc`/`codex`/`native`). Copy the
  precedent verbatim:
  - `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex` —
    `roles/0` returns `[kanban_manager_recipe()]`; `kanban_manager_recipe/0` is
    `%{name:, behaviors:, requested_caps:, passive:}`. The plugin declares **no
    `kinds/0`**.
  - `apps/ezagent_plugin_native/lib/ezagent_plugin_native/application.ex` — the
    `native` flavor: `agent_flavors/0` maps `"native"` → `{Ezagent.Entity.Agent,
    …}` (the **unified** host Kind, declares **nothing** role-specific) + a
    `:cap_policy` so caps are minted per-recipe, fail-closed.
- **If the agent was only ever a vehicle for the render card** (no real persona),
  the honest answer is even smaller: **you didn't need an agent type at all** —
  ship the render mechanism (case B) and let any existing agent produce into it.
  (P8: one fewer concept.)

### B. "render json-render cards in a session" → mechanism vs producer split

- **What happened:** the json-render card feature was built *through* the
  salesperson business persona + a `:salesperson` cap — entangling a generic
  transport with one producer.
- **The aligned shape (this is exactly what merged, transport-only, in #1035):**
  the render path is a **producer-agnostic transport**. A message carries an
  optional json-render tree in its **body** (`body["render"]` /
  `body["render_css"]`); the feed encoder lifts it to the SPA with **no producer
  coupling and no business cap**:
  - `apps/ezagent_web/lib/ezagent_web/socialware/feed_encoding.ex` —
    `encode_messages/1` reads `body["render"]` / `body["render_css"]` for *every*
    message. Moduledoc: *"Same spec format as the Surface page, so a fragment
    generated for the page can be reused verbatim in a message."*
  - `apps/ezagent_plugin_world/assets/src/components/JsonRenderBubble.tsx` +
    `apps/ezagent_domain_socialware/assets/js/catalog_jsonrender.mjs` — one
    renderer, the same `@json-render` catalog the preview page uses.
  - The producer (salesperson, advisor, anyone) just emits a message whose body
    has a `render` tree. No `:salesperson` cap; if a render *capability* is
    needed at all, it's a **generic** "may emit render fragments" cap, not a
    persona-named one.
- **The tell you can apply next time:** ask "would the *advisor* (or any other
  agent) be able to render a card through this path without changing it?" If no,
  the mechanism is entangled with the producer — split them.

---

## The concrete ezagent levers

**Skills to load** (mandatory for any `apps/**.ex` work — without them a subagent
writes stale Elixir and ignores invariants, 台账/feedback):
- `ezagent-developer` — read `references/design-principles.md` (**P1, P8, P9,
  P11, P24** are the ones these two cases touch), `references/anti-patterns.md`,
  and `references/how-to-recipes.md` (§"add a new plugin", §"add a Kind").
- `ezagent-socialware` — for anything touching the customer/render/feed surfaces
  (`public_view` templates, ChatFeed/CustomerFeed, the json-render SPA).
- `elixir-phoenix-helper` — always paired with `ezagent-developer`.

**Arch docs to read before drafting** (台账 P0 design-alignment):
- `docs/together/contributing/README.md` — the 台账 red lines (**P0–P3** are the
  same kanban incident this guide expands). Re-read before every handoff.
- The role-foundation spec/plan: `docs/together/2026-06-25/specs/role-foundation-design.md`,
  `…/role-foundation-plan.md` — what "agent = role × flavor" means in code (#54).
- The precedent specs: `docs/together/2026-06-25/specs/kanban-as-role-spec.md`
  (own-Kind → role × `native`, the exact move salesperson should have made) and
  `…/py-agent-flavor-plan.md` (P4b unification of own-Kind agent types).
- `ARCHITECTURE.md` Decision Log + `GLOSSARY.md` for the primitives (Kind /
  Behavior / Role / flavor / URI).

**The review gate that catches both early — use it:** the dev-together flow is
**SPEC → codex adversarial-review → plan → implement**, *not* implement-then-PR.
Both violations here are design-level: a one-paragraph SPEC stating "I'll add
`Entity.Salesperson` and render cards through it" would have failed an adversarial
review on P1/P3/P9 *before any code was written* (cost: minutes vs a working PR
that has to be re-architected). Concretely, for any **core-touching** task (new
Kind / Behavior / agent type / render-or-feed mechanism / routing / lifecycle):

1. Write a short SPEC (the *why* + the primitives you'll touch + a `/goal`).
2. Run a codex adversarial-review of the SPEC, loading `ezagent-developer`
   (+ `ezagent-socialware` if UI/render) — static review, no `mix`.
3. Confirm the design with the lead (台账 P0), then plan, then implement.
4. Completion is gated by an invariant test (P6), not a feature list.

The role-foundation work (RF-1..9) is the positive example of this flow — spec →
2 rounds of review → plan → implement, near-zero rework (台账 P2).
