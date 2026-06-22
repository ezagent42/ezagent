# Handoff: `loom` → `hello` migration onto `main`

> **Date:** 2026-06-22 · **From:** Claude (with Allen) · **To:** a new independent developer (human + cc/codex)
> **Tracking:** task #81 · **Base:** `origin/main` @ `b6818123`
> **Status:** DESIGN-APPROVED (brainstormed with Allen 2026-06-22). This is a build handoff, not a spec to re-litigate. Phase 0 is fully scoped; Phases 1–3 are the roadmap.

---

## 0. Read this first

You are building a **new plugin `ezagent_plugin_hello`**: an app where an **AI agent generates a UI page** (as structured data), the page is **rendered by [Vercel `@json-render`](https://github.com/vercel-labs/json-render)**, and **anonymous external visitors can view it**. `hello` is the modern re-implementation of an old experiment called **`loom`** — but you are **not merging the loom branch** (it is 113 commits behind `main` and architecturally stale). You are building fresh on current `main`, harvesting only loom's prompts/ideas.

**Mandatory reading before you write code** (these encode invariants that gate your PRs):
1. Skill `ezagent-developer` — the Behavior / Kind / URI / CapBAC / dispatch model and its hard invariants. Load it.
2. Skill `ezagent-socialware` (`.claude/skills/ezagent-socialware/SKILL.md`) — the socialware substrate you build ON. Updated 2026-06-22; read it cover to cover. Its local-E2E recipe is your sign-off harness.
3. `ARCHITECTURE.md` and `GLOSSARY.md` — do **not** edit these.
4. The agent-definition-contract specs under `docs/superpowers/specs/2026-06-21-agent-contract-*` — versioned templates, the orchestrator tool catalog, `migrate_session`. Phase 1 depends on these.

**The recursion vision (why this matters).** The end state (Phase 3) is that **`world` — the operator console — itself becomes a `hello` app**, rendered by the same `@json-render` engine, and able to **spawn new `hello` apps**. So `hello` is not a throwaway demo; it is the seed of ezagent's unified front-end. Build Phase 0 so it grows toward that, never blocks it.

---

## 1. TL;DR — the locked decisions

| # | Decision | Value |
|---|----------|-------|
| 1 | **Render model** | **`@json-render`** (Vercel `vercel-labs/json-render`, Apache-2.0). LLM emits a JSON spec constrained to a Zod-defined component+action **catalog**; the library renders it (streaming-capable). Packages: `@json-render/core`, `@json-render/react`, `@json-render/shadcn`. Phase 0 adds this as hello's **own** renderer **alongside** the existing 5-type `json_render.mjs` — that file powers the **shipped** socialware customer SPA, so **do not remove or mutate it**. Converging `json_render.mjs` onto `@json-render` belongs to Phase 3 (unification), not Phase 0. |
| 2 | **Where `@json-render` lives** | **Hello-local, but extraction-ready.** The renderer + catalog physically live in `ezagent_plugin_hello`, with a clean module boundary and **zero hello-specific coupling**, so Phase 3 can *move* it to a shared layer, not rewrite it. |
| 3 | **Orchestration** | **Start with ONE builder agent.** Uses **main's current** agent/orchestrator contract — **do NOT port loom's bespoke DeepSeek multi-agent brain.** Team-growth (Phase 1) is additive via `Behavior.Turn` + `add_managed_member`. |
| 4 | **Storage / delivery** | **Ride the socialware substrate.** Page = a `Behavior.Surface` version produced by a `Behavior.Turn`; visitor delivery = existing `CustomerFeed` + `public_view`. **Invariant: the page is only ever born via `Surface.put_version(tree)`** — no private side-path. That single chokepoint is what lets the team grow in for free. |
| 5 | **Migration method** | **Re-implement on `main`.** The `loom-socialware-vertical` branch is reference-only (harvest the page-gen prompts). **Drop:** Live2D mascots, salesperson/danmaku, `temp_user`, the vendored Next.js+Sandpack SPA, the bespoke orchestrator. |
| 6 | **Naming** | `loom` → `hello`. New app `apps/ezagent_plugin_hello`, modules `EzagentPluginHello.*` / `Ezagent.Hello.*`. |

**Scoping model (layered — this answers "per-session / per-workspace / global"):**
- **The `hello` plugin** = **global** (installed once, like `cc`/`world`). Ships the Kind/behaviors, the `@json-render` renderer, the builder-agent template, the **base component catalog**.
- **A hello app's *definition*** = a **per-workspace `SessionTemplate`** (versioned `@hash`, `public_view: true`, builder as orchestrator, catalog ref).
- **A hello app's *instance*** = **per-session** (one live `Session` = one app = one page Surface + its agent team).
- **The component catalog** = **global base** (plugin-shipped); per-workspace / per-template extension is a later option, not Phase 0.
- **The orchestrator team** = **per-session** (defined by the app's `SessionTemplate`; mutable on the live instance).

---

## 2. Architecture primer (for someone new to `main`)

ezagent is an Elixir/Phoenix umbrella. Three tiers: `ezagent_core` → `ezagent_domain_*` → `ezagent_plugin_*`. Everything is addressed by a `%URI{}` and gated by capability-based access control (CapBAC). The **only** way state changes is `Ezagent.Invocation.dispatch/1` against a target URI with a capability set — there are no back doors, and the invariant gates enforce this. Behaviors are authored exclusively via `use Ezagent.Lifecycle`. (The `ezagent-developer` skill is the real reference; this paragraph is just orientation.)

### 2.1 The socialware substrate (already on `main` — you build ON it, you don't build it)

A **socialware app** = a `Session` whose `SessionTemplate` carries `public_view: true`, making it viewable by anonymous external visitors. The substrate gives you, already merged:

- **`Ezagent.Behavior.Turn`** (`apps/ezagent_domain_session/lib/ezagent/behavior/turn.ex`, `:turns` slice) — a socialware **orchestration state machine**. Actions: `open(trigger, opened_at) → turn_id`; `dispatch(turn_id, subtasks)` (delegates subtasks to worker members **via chat.send**); `deliver(turn_id, subtask_id, card_ref)` (collects a worker deliverable); settle. **The multi-agent seam already exists here.**
- **`Ezagent.Behavior.Surface`** (`apps/ezagent_domain_session/lib/ezagent/behavior/surface.ex`, `:surface` slice) — the **immutable page surface**. Actions: `put_version(turn_id, tree) → version`, `approve(version) → approved`, `commit_settlement(turn_id)`. Slice = `%{versions: %{}, approved: nil, version_seq: 0}`; each version = `%{tree: <page-node-map>, by_turn: turn_id}`. Helpers: `operator_tree/1` (latest), `customer_tree/1` (the `:approved` version — what visitors see), `tree_for_version/2`. **A "tree" is the `%{type, props, children}` page-node map — i.e. your `@json-render` spec.**
- **`EzagentDomainSocialware.PageView`** (`apps/ezagent_domain_socialware/lib/ezagent_domain_socialware/page_view.ex`) — an operator-facing `SessionView` that renders the Surface tree. **Important: it exists but is never registered on `main`** (no `Application.start/2` registers it). It currently renders via a hand-rolled HEEx `render_node` switch (text/container/table/fallback). It declares `external_render?/0 → true` delegating to `Surface.customer_tree/1`.
- **`Ezagent.Socialware.CustomerFeed`** (`apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex`) — the gated customer projection. `snapshot/2` returns `%{messages: [...], page: customer_tree}` — **it already pushes the Surface tree to the visitor.**
- **The customer web surface**: `EzagentWeb.Socialware.ChatFeedController` (`/socialware/chat`, anon-gated by `PublicView.public_view?/1`, mints an `AnonUser`, drops a cookie, issues a token) + `chat_feed_channel.ex` + `chat_feed_socket.ex`, serving the bundle `/assets/js/customer_app.js` (a 1-line re-export of `apps/ezagent_domain_socialware/assets/js/customer_app.js`, which renders `snapshot.page` via `renderJsonNode`).

**Key correction vs. the loom-era docs:** the customer-side JS renderer is **NOT unbuilt** — `apps/ezagent_domain_socialware/assets/js/json_render.mjs` (161 LOC) already renders the Surface tree with a tiny 5-type registry, and it powers the **shipped** socialware customer SPA. **Do not rip it out.** For Phase 0, hello adds its **own** `@json-render`-based renderer **alongside** it (richer, Zod-constrained, streaming); folding the existing `json_render.mjs` onto `@json-render` is Phase 3 (the unification), not Phase 0. You are not inventing a renderer from scratch, and you are not replacing a working one.

### 2.2 The agent-definition-contract (already on `main` — Phase 1 uses it)

Templates are immutable, content-addressed `@hash` versions; a session adopts a version via the `"current"` tag. The session **orchestrator** has an MCP tool catalog (`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server/tool_catalog.ex`): `add_managed_member`, `update_member_template`, `remove_member`, `define_rule_set_rule`, `define_prompt_template`, `define_legend`, `update_template`, `save_template_as`, `migrate_session`, `list_templates`. `migrate_session` re-points a live session to a new template version with a **resumable ledger**. **Phase 1's team-growth and durable team-updates use exactly these — no new framework.**

### 2.3 World's transport substrate (you reuse the *pattern*, you don't edit world)

`world` (`apps/ezagent_plugin_world`) is a LiveView shell that hydrates a React/Vite ES-module island. The reusable transport pattern:
- LV renders `<div phx-hook="WorldRenderer" data-...-module-url=... data-...-state=...>`; the hook (`assets/js/world_renderer.js`) dynamically `import()`s the bundle and calls `mountWorld(el, {layout, state, caller, pushEvent, onServerEvent})`.
- Server→client live updates: `push_event(socket, "world:state", delta)`; client merges (`setState(cur => ({...cur, ...next}))`) — **this whole-map merge IS "re-render on patch."**
- Client→server: `pushEvent("world:dispatch", {action, args})` → routed by allow-list to `*Actions.handle_dispatch/3` → `Ezagent.Invocation.dispatch` (CapBAC-checked).
- Build: `assets/vite.config.ts` lib-builds to `apps/ezagent_web/priv/static/assets/world/main.js`; `config/*.exs` set `world_module_url`.

**hello copies this pattern into its own island** (its own hook, its own bundle, its own `hello_module_url`). It does **not** import world's bundle or edit world's files. (Rationale in §6.)

---

## 3. What `loom` actually was (so you harvest, not resurrect)

On `origin/loom-socialware-vertical` (tip `836549a`, ~113 commits behind `main`):
- ~14,900 LOC in `apps/ezagent_plugin_loom/`. Biggest: `web_plug.ex` (2,635 LOC SDK), `loom_orchestrator.ex` (948 LOC bespoke DeepSeek brain).
- **The render model was files-map + Sandpack**, NOT the spec's "41 components + JSON-Patch." The builder LLM regenerated a whole **files map** (`%{"/App.jsx" => "...", ...}`) emitted as a `page_update` message; the front end (a **compiled Next.js SPA whose source is in a different repo**) ran it in a Sandpack iframe. **No JSON-Patch was ever implemented.**
- It had started a half-finished strangler onto a *stale fork* of the socialware substrate (dual-write, `TempUser` fallback, stubbed generator).

**Harvest:** the page-generation **system prompts** (`apps/ezagent_plugin_loom/lib/ezagent/prompts.ex`, `page_gen.ex`) — adapt them to emit an `@json-render` spec instead of a files-map. The product intent and flows in `docs/loom-port/SOCIALWARE-VERTICAL.md`.
**Drop:** the Sandpack SPA, the bespoke orchestrator, `temp_user`, Live2D, salesperson/danmaku, the 2,635-LOC web_plug SDK.

---

## 4. The central problem & its resolution

Three incompatible render contracts exist: loom's **files-map + Sandpack** (runs arbitrary React — powerful, heavy, unsafe), socialware's **5-type JSON node-tree** (`json_render.mjs` — safe but tiny), and world's **hardcoded `type→TSX` switch** (not data-driven at all). The migration's whole technical risk is reconciling these.

**Resolution = `@json-render`.** It gives a **catalog-constrained** generative-UI model: you declare allowed components + actions as Zod schemas; the LLM can only emit specs within that catalog; the library renders them progressively. This is strictly better than loom's arbitrary-React (the AI can't escape the catalog), aligns with world's shadcn stack (`@json-render/shadcn` ships 36 shadcn components; world's `components.json` is already shadcn config), and slots onto the **Surface tree** seam that already exists. The Surface `tree` becomes the `@json-render` spec. Nothing else in the substrate changes.

---

## 5. Phase 0 — build plan (your deliverable)

Goal: **an author chats with a hello builder agent; the agent emits an `@json-render` page; an anonymous visitor sees it rendered live at `/socialware/chat`.** Single builder agent. No team yet.

> Use TDD and the `ezagent-developer` invariants throughout. Each step below is a PR-sized unit; run the full gate suite (§8) before each merge.

**0.1 — Scaffold `apps/ezagent_plugin_hello`** (model: `ezagent_plugin_echo`).
- `mix.exs`: `compilers: Mix.compilers() ++ [:ezagent_plugin_check]`; `application: [..., env: [ezagent_plugin: EzagentPluginHello.Application]]`; deps `{:ezagent_core, in_umbrella: true}`, `{:ezagent_domain_session, in_umbrella: true}` (Behavior.Surface/Turn), `{:ezagent_domain_socialware, in_umbrella: true}` (CustomerFeed/public_view), `{:ezagent_domain_ui, in_umbrella: true}` (SessionViewRegistry).
- `lib/ezagent_plugin_hello/application.ex`: `use Application` + `use Ezagent.Plugin`; `start/2 → Ezagent.Plugin.boot(__MODULE__)`; implement `plugin_info/0` (required) + declare `template_classes/0` (the builder agent), `agent_flavors/0` if needed, and **register the hello operator SessionView** here via `Ezagent.UI.SessionViewRegistry.register(EzagentPluginHello.PageView)`.
- **Wire it (the gotchas — see §8):** add `ezagent_plugin_hello: :permanent` to root `mix.exs` releases; add `{:ezagent_plugin_hello, in_umbrella: true}` to `apps/ezagent_web/mix.exs`; declare every umbrella dep you reference (the `undeclared_umbrella_dep_test` allowlist is `[]`).

**0.2 — The builder agent** (model: `apps/ezagent_plugin_echo/lib/ezagent/template/echo_agent.ex`, 349 LOC).
- A Template Class for the hello builder. On a user turn, it produces a **`@json-render` JSON spec** (constrained to the hello catalog). Adapt loom's page-gen prompt to emit the spec.
- It uses **main's agent model** (an agent flavor driving an LLM). It is the session's **orchestrator** from day one (so Phase 1 can delegate). Keep its reply→spec extraction behind a small, named function (the future team will feed the same `put_version` step).

**0.3 — Wire generation to Turn/Surface** (the invariant chokepoint).
- On a user message: `Turn.open` → builder emits spec → **`Surface.put_version(turn_id, spec)`** → `Surface.approve(version)`. The visitor's `customer_tree/1` now returns the approved spec.
- **Do not** write the page anywhere except through `Surface.put_version`. This is decision #4's invariant.

**0.4 — The `@json-render` renderer + catalog** (decisions #1, #2).
- New `apps/ezagent_plugin_hello/assets/` Vite project: `@json-render/core` + `@json-render/react` (+ `@json-render/shadcn`). Define the **hello component catalog** (Zod) + a small action set mapped onto the `{action, args}` dispatch.
- The **customer renderer**: hello ships its **own** `@json-render` bundle and renders the approved spec for the visitor, **alongside** the existing `json_render.mjs` (leave that one in place — it serves the current socialware SPA). Keep hello's renderer a clean, hello-agnostic module (decision #2 — extraction-ready).
- The **operator renderer (resolved — not a free choice):** `EzagentPluginHello.PageView`'s `render/1` emits `<div phx-hook="HelloRenderer" data-hello-module-url={…} data-spec={…}>` that hydrates **hello's own** `@json-render` island **inside world's LiveView shell**. World renders any registered `SessionView` generically, so this needs **no edit to world** (decision #6 isolation holds) and reuses the **same** `@json-render` bundle as the customer side. **Server-side HEEx is NOT an option for hello's page** — it cannot execute the `@json-render` JS library; the existing socialware `PageView` renders HEEx only because its tree is the tiny 5-type set, which is exactly what hello supersedes. Verify only that world's SessionView host passes registered views' `phx-hook`/`data-*` attributes through untouched.

**0.5 — Customer delivery** (reuse, don't rebuild).
- A hello `SessionTemplate` with `public_view: true`. Instantiate a live session. Visitor opens `/socialware/chat?session_uri=…` → existing anon flow → `CustomerFeed.snapshot` pushes `page` (your approved spec) → your `@json-render` bundle renders it.
- If `/socialware/chat`'s shell must load the hello bundle (vs the socialware one), prefer **selecting the renderer by the session's plugin/flavor** rather than forking the controller.

**0.6 — Island build wiring** (parallel to world's, §6 for isolation).
- `apps/ezagent_plugin_hello/assets/{vite.config.ts → outDir ../../ezagent_web/priv/static/assets/hello, package.json}`; add `config/config.exs` `hello_module_url`/`hello_css_url`; add `config/dev.exs` dev URL + a Vite **watcher on a distinct port**; a `HelloRenderer` JS hook mirroring `world_renderer.js`.

**0.7 — Tests + E2E (sign-off bar).**
- Unit: builder emits a valid catalog-constrained spec; `Surface.put_version`/`approve` round-trip; the `plugin_contract_test` analogue.
- Doc every public module/def (`doc.scan` gate).
- **E2E sign-off (non-negotiable, per `ezagent-socialware` recipe + `feedback_esr_e2e_standards`):** an **agent-browser screenshot** of an anonymous visitor viewing an **agent-generated** hello page on an isolated local stack. That screenshot is the definition of done for Phase 0.

---

## 6. Conflict-avoidance management (world is being updated in parallel)

World is under active development (UI polish, logic completion) by another developer at the same time. To prevent collisions:

**Hard rule — Phase 0–2 hello touches ONLY its own app + a small, enumerated set of shared files. It does NOT edit `apps/ezagent_plugin_world/` internals.**

- **Reuse world's transport by *copying the pattern*, not its files.** hello ships its own `HelloRenderer` hook, its own `mountHello` bundle, its own `hello_module_url`. World's `world_renderer.js` / `main.tsx` / vite churn cannot break hello, because hello shares none of it. (This is also decision #2 — the renderer is hello-local.)
- **The operator page view plugs in via the registry, not via world.** `SessionViewRegistry.register/1` in hello's own `Application.start/2` is the sanctioned path (confirmed: `register` is not in the plugin-check forbidden-registry grep, and the host LV iterates registered views generically). **No edit to world is required to add hello's page view.**
- **Enumerated shared files hello WILL touch (all additive, low collision):** `config/config.exs`, `config/dev.exs`, root `mix.exs` (releases list), `apps/ezagent_web/mix.exs` (deps), `apps/ezagent_core/test/architecture/arch_baseline_manifest.exs` (cap bumps for the new app). Each is an *append* of a new entry/key — coordinate by keeping these edits minimal and rebasing often.
- **Possible shared-surface edit:** if 0.4 swaps the socialware customer renderer registry, that touches `apps/ezagent_domain_socialware/assets/js/`. The world dev does **not** own socialware, so collision risk with *world* is low — but coordinate with whoever owns socialware. Prefer adding a hello-specific registry over mutating the shared one.
- **Rebase discipline:** world PRs land fast. Branch hello off the latest `main` and rebase frequently; never let hello drift far (loom's 113-commit drift is the cautionary tale).
- **Phase 3 is the only place hello and world converge** (world adopts hello's renderer). That is an explicit, *coordinated, separate* effort — **do not attempt it while world's UI work is in flight.**

---

## 7. Phases 1–3 (roadmap — build Phase 0 to enable these, don't block them)

- **Phase 1 — hello team growth.** The single builder becomes an orchestrator that, on complex turns, uses `Turn.dispatch(subtasks)` to delegate to member workers spawned via `add_managed_member`; workers `Turn.deliver`; the orchestrator composes → `Surface.put_version`. Durable team changes = edit the hello `SessionTemplate` → `migrate_session` (resumable ledger). **The Surface, approval, renderer, and delivery are unchanged** — only how the tree is sourced changes. Nothing new to invent; it's all in the agent-contract.
- **Phase 2 — world produces hello apps.** world gains a "New hello app" UX (largely its existing `create_session` flow + hello templates) + the hello operator/customer views. world becomes the **factory**.
- **Phase 3 — world *becomes* a hello app (the recursion endpoint, B2).** world's admin UI is re-expressed as `@json-render` specs rendered by the (now-extracted) hello renderer; world's hardcoded `type→TSX` switch is retired; the hello catalog absorbs world's admin components. **This is a separate large spec and requires coordination with the world dev** — it is the payoff of decision #2's extraction-readiness.

---

## 8. Gates & invariants (every PR must pass)

Run from the umbrella root:
- `mix compile --warnings-as-errors --force` (the `precommit` alias bundles this + `deps.unlock --unused` + `format` + `test`).
- `mix ezagent.arch.scan` — manifest-cap ratchet (`apps/ezagent_core/test/architecture/arch_baseline_manifest.exs`). Keep modules < 1000 LOC; route any spawn through the sanctioned chokepoint; don't push any counter over cap.
- `mix ezagent.doc.scan` — **every public module/def needs `@moduledoc`/`@doc`** (or an explicit `false`), or bump the counter cap with a `# arch-cap-bump:` justification.
- `mix ezagent.uri_query.scan` — use `Ezagent.URI.*` builders; never assemble URI strings or parse flavor prefixes by hand.
- `mix ezagent.check_invariants` — the 8 hard invariants (inbound-via-dispatch, lifecycle, cap checks, audit-async…).
- `mix format --check-formatted`, `mix test`.
- The `:ezagent_plugin_check` compiler gate (automatic for any `ezagent_plugin_*` app) — requires the `env: [ezagent_plugin: <Mod>]` key and a valid `Ezagent.Plugin` module.

**Allowlist / manifest files a NEW app must be added to (skipping these = silent breakage):**
1. Root `mix.exs` `releases:` list → `ezagent_plugin_hello: :permanent` (else it won't boot in a release).
2. `apps/ezagent_web/mix.exs` deps → `{:ezagent_plugin_hello, in_umbrella: true}` (enforced by `all_plugin_apps_wired_to_web_test.exs`).
3. `undeclared_umbrella_dep_test.exs` `@allowlist` is `[]` → **declare every umbrella dep you reference** in your `mix.exs`; add to the allowlist only as a last resort.
4. `arch_baseline_manifest.exs` → bump `undocumented_*` / module-count caps only if hello legitimately adds to them (with `# arch-cap-bump:` comment).
Also satisfied automatically if you stay clean: `layer_purity_test.exs`, `im_session_agent_acyclic_test.exs`.

**Non-negotiable invariants:** never bypass CapBAC; never write inbound state except via `Ezagent.Invocation.dispatch`; author behaviors only via `use Ezagent.Lifecycle`; the page is born only via `Surface.put_version`.

---

## 9. Code volume & file-scope estimate

**Phase 0 — new files (in `apps/ezagent_plugin_hello/`), rough LOC:**

| File | ~LOC | Note |
|------|------|------|
| `mix.exs` | 60 | model echo (58) |
| `lib/ezagent_plugin_hello/application.ex` | 150–200 | plugin contract + SessionView register + island URL reader |
| `lib/ezagent/template/hello_builder_agent.ex` | 250–350 | model echo_agent (349); the builder Template Class |
| `lib/ezagent_plugin_hello/page_view.ex` | 150 | operator SessionView; model socialware PageView (191) |
| `lib/ezagent_plugin_hello/page_gen.ex` (+ prompts) | 150–250 | harvested/adapted from loom; emits `@json-render` spec |
| `assets/src/main.tsx` + renderer + catalog (Zod) | 250–400 | `@json-render` setup + hello component catalog |
| `assets/js/hello_renderer.js` (phx hook) | 40–60 | mirror `world_renderer.js` |
| `assets/{package.json, vite.config.ts}` | 60 | mirror world |
| customer renderer wiring (registry/bundle) | 100–200 | reuse/replace `json_render.mjs` path |
| tests (behavior/template/integration/contract) | 600–1000 | echo's test set is 1255; hello is simpler |

→ **Phase 0 ≈ 12–15 new files, ~1,800–2,800 LOC** (roughly half tests + JS/TS).

**Phase 0 — modified shared files (all additive, low collision):** `config/config.exs`, `config/dev.exs`, root `mix.exs`, `apps/ezagent_web/mix.exs`, `arch_baseline_manifest.exs`, possibly `apps/ezagent_domain_socialware/assets/js/*` (renderer registry). → **~5–6 files, ~10–40 LOC of additions total.**

**Phases 1–3 (rough):** Phase 1 ≈ 300–600 LOC (team orchestration on existing tools + tests). Phase 2 ≈ 400–800 LOC (world "new hello app" UX + hello templates). Phase 3 = large, separate spec (world's renderer swap + catalog absorption) — not estimated here.

---

## 10. Open questions to resolve at implementation time

1. **Bundle selection at `/socialware/chat`:** select the hello renderer by session plugin/flavor vs. forking the controller — prefer the former; confirm the cleanest hook so the customer shell loads hello's bundle without disturbing the existing socialware SPA.
2. **Catalog v0 contents:** which `@json-render/shadcn` components + ezagent-specific nodes ship in the global base catalog. Start minimal (text/container/layout/form/table); expand by demand.
3. **Streaming:** `@json-render`'s SpecStream over the `CustomerFeed`/`world:state` channel — Phase 0 can land non-streaming (whole-spec per turn) and add streaming later; confirm with Allen.
4. **`@json-render` version pin + license/vendoring** for the self-host story (mind the CF/storage constraints if hello must run on the future CF deploy).
5. **Pull the exact `@json-render` API when building.** The library is confirmed real (context7 `/vercel-labs/json-render`, High reputation, 2268 snippets — "AI generates type-safe native interfaces from JSON specs constrained to predefined component catalogs"). Nail down the package versions, the Zod catalog-registration API, and `SpecStream` from those docs at build time rather than from this handoff.

---

*Brainstormed and authored by Claude with Allen on 2026-06-22. Questions: this handoff's decisions are settled; implementation-detail questions go to Allen via Feishu.*
