# Extending agents without violating the architecture

The pre-flight checklist + the two principles live inline in `SKILL.md`
(§"Extending agents without violating the architecture") — read those first.
This file is the depth: the two worked examples and the concrete levers.

Background: two recent PRs were **complete, working, and well-tested** yet had to
be re-shaped because they crossed two architectural lines — both invisible to
"tests pass" (**P6**: a passing suite doesn't prove an invariant is held). The
checklist makes them catchable *before* code.

## The two cases, worked through

### A. `Entity.Salesperson` → role × flavor (or: just the mechanism)

- **What happened:** a new own-Kind `Ezagent.Entity.Salesperson` for a chat agent.
- **Why it's the anti-pattern:** identical to the `Entity.PyAgent` Kind retired in
  P4b; a salesperson is a chat participant like any other agent — no new core
  concept (P9), and a new Kind breaks P1/P24 and gives unwanted principal
  semantics (`entity://agent/*` is @-mentionable / joinable "for free").
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
  ship the render mechanism (case B) and let any existing agent produce into it
  (P8: one fewer concept).

> **When IS a new Kind actually justified?** For an agent *type* — essentially
> never; it is always a role × flavor. A new Kind is justified only for a
> genuinely new **non-agent primitive**: a scope-owning concept that ≥2 unrelated
> tiers read (P10 "shared referent needs identity") and whose ownership is decided
> by "reads what data" (P9) — e.g. a new Resource/Template-shaped concept, not
> "another kind of chat actor". That is a core/domain decision, needs lead
> sign-off (台账 P0) + an invariant test (P6). Note `entity://`'s axis is the
> near-closed set `{user, agent}`; adding a sub-kind is a rare parser-allowlist
> change (`how-to-recipes.md` §"add a Kind"), not a flavor.

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
    has a `render` tree. No `:salesperson` cap; if a render *capability* is needed
    at all, it's a **generic** "may emit render fragments" cap, not a
    persona-named one.
  - The render catalog also documents the intended producer-agnostic shape — its
    comment keeps node types *"so existing producers, e.g. advisor, render"*
    (`apps/ezagent_domain_socialware/assets/js/catalog.mjs:52`); the advisor
    vertical was itself retired in #1034, so treat that as a historical
    illustration, not a live exemplar. #1035 is the live proof.
- **The tell you can apply next time:** ask "would the *advisor* (or any other
  agent) be able to render a card through this path without changing it?" If no,
  the mechanism is entangled with the producer — split them.

## The concrete levers

**Skills to load** (mandatory for any `apps/**.ex` work):
- `ezagent-developer` — `references/design-principles.md` (**P1, P8, P9, P11,
  P24** are the ones these two cases touch), `references/anti-patterns.md` (the
  two refusals "Entity.<Type> for a chat agent" + "route a generic mechanism
  behind a business persona/cap"), `references/how-to-recipes.md` (§"add a new
  plugin", §"add a Kind").
- `ezagent-socialware` — anything touching the customer/render/feed surfaces.
- `elixir-phoenix-helper` — always paired with `ezagent-developer`.

**Arch docs to read before drafting** (台账 P0 design-alignment):
- `docs/together/contributing/README.md` — the 台账 red lines (**P0–P3** are the
  same kanban incident this guidance expands). Re-read before every handoff.
- `docs/together/2026-06-25/specs/role-foundation-design.md` +
  `…/role-foundation-plan.md` — "agent = role × flavor" in code (#54).
- `docs/together/2026-06-25/specs/kanban-as-role-spec.md` (own-Kind → role ×
  `native`, the exact move salesperson should have made) +
  `…/py-agent-flavor-plan.md` (P4b unification of own-Kind agent types).
- `ARCHITECTURE.md` Decision Log + `GLOSSARY.md` for the primitives.

**The review gate that catches both early — use it:** the dev-together flow is
**SPEC → codex adversarial-review → plan → implement**, *not* implement-then-PR.
Both violations are design-level: a one-paragraph SPEC ("I'll add
`Entity.Salesperson` and render cards through it") would have failed adversarial
review on P1/P3/P9 *before any code was written*. For any **core-touching** task
(new Kind / Behavior / agent type / render-or-feed mechanism / routing /
lifecycle):

1. Write a short SPEC (the *why* + the primitives you'll touch + a `/goal`).
2. Run a codex adversarial-review of the SPEC, loading `ezagent-developer`
   (+ `ezagent-socialware` if UI/render) — static review, no `mix`.
3. Confirm the design with the lead (台账 P0), then plan, then implement.
4. Completion is gated by an invariant test (P6), not a feature list.

The role-foundation work (RF-1..9) is the positive example — spec → 2 rounds of
review → plan → implement, near-zero rework (台账 P2).
