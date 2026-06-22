# hello Phase 0 — status (2026-06-22)

Branch `hello` (off `main`). Implementer: Claude (autonomous run). This is the
honest done/not-done record for the `ezagent_plugin_hello` Phase 0, per the
handoff `2026-06-22-loom-to-hello-migration-claude-to-dev-handoff.md`.

## What Phase 0 delivers

A new global plugin `ezagent_plugin_hello`: an AI **builder agent** turns a
user's request into a catalog-constrained `@json-render` page that is born only
via `Behavior.Surface.put_version` and is visible to **anonymous** visitors at
`/socialware/chat`, riding the socialware substrate (Session + Turn + Surface +
`public_view` + `CustomerFeed`).

```
user chat ──▶ HelloBuilder (Lifecycle behavior, session member)
                 └─ Generator (supervised Task, off the GenServer)
                      ├─ LLM.ApiClient  (DeepSeek, OpenAI-shape)
                      ├─ Spec.extract + Spec.validate   (catalog gate — fail closed)
                      └─ TurnDriver.drive
                           └─ turn.open → compose([page, chat]) → settle
                                └─ Surface.put_version + approve   ← the chokepoint
                                     └─ CustomerFeed.snapshot → anonymous visitor
                                          └─ customer SPA → catalog_render.mjs
```

## Status by sub-step

| Sub-step | State | Notes |
|---|---|---|
| 0.1 plugin scaffold + 4 allowlists | ✅ | mix.exs, Application/Plugin, root releases, web dep, undeclared-dep test, arch manifest |
| 0.2/0.3 builder agent → page | ✅ | HelloBuilder Kind+behavior, Generator, TurnDriver, Spec, Prompts, App, LLM.ApiClient |
| 0.4 renderer + catalog | ✅ | `catalog.mjs` (Zod) + `catalog_render.mjs` (superset, fail-closed) |
| 0.5 retire json_render.mjs, migrate customer surface | ✅ | json_render.mjs deleted; one renderer; advisor still renders (superset) |
| 0.6 build wiring | ✅ customer / ⏸ operator | customer SPA needs NO fork (renderer in socialware domain). Operator phx-hook island deferred (not the DoD) |
| 0.7 DoD | ✅ substrate + renderer / ⏳ live screenshot | integration test + node renderer test green; `mix ezagent.demo.seed_hello` for the live browser shot |

## Gates (all green)

- `mix ezagent.doc.scan` PASS · `mix ezagent.arch.scan` PASS ·
  `mix ezagent.uri_query.scan` PASS · `mix ezagent.check_invariants` PASS
- `undeclared_umbrella_dep_test` PASS · `mix format --check-formatted` (touched) PASS
- hello compiles **warning-clean**; `:ezagent_plugin_check` PASS
- `mix test apps/ezagent_plugin_hello/test` → **7 passed** (1 integration + 6 unit)
- Customer SPA bundles via esbuild (zod included); `mix tailwind ezagent_web_customer`
  emits the new utility classes; `customer_renderer_test.mjs` (legacy contract) passes
- ⚠️ a project-wide `mix compile --warnings-as-errors` fails ONLY on **pre-existing**
  `main` type-warnings (`ezagent_core/.../sandbox.ex`, `config_dir.ex`,
  `cc/.../seed_cc_sandbox.ex` — none in `main..HEAD`). hello + the migration add zero.

## Documented deviations (need Allen's eye)

1. **Renderer is NOT literal Vercel `@json-render/react`.** Every published
   version (0.0.1…0.19.0) hard-requires **React 19**; this substrate (customer
   SPA, Sandpack 2.20, world) is entirely **React 18**. Adopting the upstream lib
   = a React-19 migration of the shipped customer surface, out of Phase-0 scope.
   Phase 0 ships a **catalog-faithful** renderer (`catalog_render.mjs`) with the
   same contract — a **Zod** catalog (`catalog.mjs`) + fail-closed per-node
   render — behind a clean module boundary. Swapping in literal `@json-render`
   after a React-19 migration is localized. **Follow-up:** decide whether to
   migrate the customer surface to React 19 (then adopt upstream) or keep the
   faithful renderer.

2. **`json_render.mjs` retired now, not in Phase 3.** The handoff said add
   `@json-render` *alongside* `json_render.mjs` and converge in Phase 3. Allen's
   later locked decision overrode this: "@json-render is the sole renderer —
   retire `json_render.mjs`, no parallel". Done: one renderer in the **socialware
   domain** (the tier that owns the customer surface — avoids a domain→plugin
   dependency), rendering a **superset** catalog (legacy `container/text/table/
   code` + hello `page/section/card/heading/text/button/image`) so advisor's
   pages keep rendering. `page_view.ex` (the server-side **operator** HEEx
   renderer) is a separate renderer and was left untouched.

3. **Builder transport is a supervised Task calling the LLM directly**, not
   `AgentBridge` + a registered `:in_process_sync` curl-flavor adapter. A
   Phase-0 reliability simplification; the architecture (a Lifecycle agent → LLM
   → Surface chokepoint) is faithful. **Follow-up:** fold onto
   `Ezagent.Entity.Agent`'s curl-flavor transport.

4. **Turn-driving authority = admin-genesis** (`User.admin_uri` +
   `admin_genesis_cap`), the same system authority the substrate's
   settlement-recovery + the socialware Turn integration test use. **Follow-up:**
   a within-session orchestrator delegation cap.

## How to see it live (DoD screenshot)

```bash
# 1. boot (backend change → ~4.5 min; takes the dev port down — warn Allen)
PORT=10042 iex -S mix phx.server          # or a free port
# 2. seed a public_view hello app + a rendered seed page (no LLM)
mix ezagent.demo.seed_hello
# 3. open the printed URL as an anonymous visitor:
#    http://localhost:10042/socialware/chat?session_uri=session://demo/hello/main
# the customer SPA renders the seed page (page/heading/text) for the anon visitor.
# For an AI-generated page: send a chat message to the session (@builder flow is
# Phase 1; in Phase 0 the builder reacts to any user message) with DEEPSEEK_KEY set.
```

The deterministic substrate proof of this exact path (anon token → approved
spec) is `apps/ezagent_plugin_hello/test/integration/hello_page_e2e_test.exs`.

## Not in Phase 0 (next)

- Operator-side `@json-render` island (HelloRenderer phx-hook + `PageView` +
  `hello_module_url` config) — the operator sees the page inside world's LV shell.
- Phase 1 team growth · Phase 2 world "new hello app" UX · Phase 3 unification
  (world becomes a hello app; literal `@json-render` adoption).
