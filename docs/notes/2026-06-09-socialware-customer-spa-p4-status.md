# Socialware customer SPA (§4.4 / P4) — status brief

**Date:** 2026-06-09 · **Context:** task #36 reframe (Allen)

## TL;DR

The original #36 premise ("build the React + json-render customer SPA / replace the
channel-only P4") is **stale**. The P4 customer-frontend foundation **already landed on
`main` in PR #603** (`feat(socialware): add customer React feed`). The loom branches are
**out of scope** as a source (the locked migration directive is rebuild-not-port; loom's
SSE + mutation-op render model is incompatible with json-render).

**#36 is therefore reframed to: VERIFY the P4 foundation + add an agent-browser visual
E2E.** Deeper design decisions are deferred (see "Open questions").

## What already exists on `main` (P4, with tests)

- **Render contract** — `Ezagent.Behavior.Surface.customer_tree/1` returns the approved
  version's `tree`: a recursive `%{type, props, children}` json-render node.
  `operator_tree/1` + `customer_tree/1` render the *same* tree shape from the *same*
  `:surface` slice (frontend-agnostic backend, by design).
  `apps/ezagent_domain_socialware/lib/ezagent/behavior/surface.ex`
- **JS renderer** — `apps/ezagent_domain_socialware/assets/js/json_render.mjs`
  (recursive `renderJsonNode`/`renderTree` + `createBaseRegistry`:
  container/text/table/code(Sandpack)/__unknown).
- **React SPA** — `apps/ezagent_domain_socialware/assets/js/customer_app.js`
  (connects `Socket("/socialware_socket", {session_uri, token})`, joins
  `socialware:customer:<uri>`, renders `snapshot.page` via the registry + a ChatPane,
  live `snapshot` pushes). Re-exported for esbuild via
  `apps/ezagent_web/assets/js/customer_app.js`.
- **Transport + entry + auth** —
  `apps/ezagent_web/lib/ezagent_web/controllers/socialware/customer_controller.ex`
  (`GET /socialware/customer`, `GET /socialware/customer/download`);
  `…/socialware/customer_socket.ex` (mounted `/socialware_socket`) +
  `customer_channel.ex` (`socialware:customer:*`). `Ezagent.Socialware.CustomerAuth`
  issues/verifies a `Phoenix.Token` bound to exactly one `session://` + `workspace://`
  with TTL — enforced at socket connect, channel join, AND every
  `CustomerFeed.snapshot/history` call before visibility-gating.
- **Tests** — `assets/test/customer_renderer_test.mjs`,
  `apps/ezagent_web/test/ezagent_web/socialware/customer_socket_test.exs`,
  `surface_test.exs`.

## Loom: reference only, NOT to port

5 loom branches (`origin/feat/loom`, `loom-stitch`, `spec/plugin-loom-design`,
`docs/loom-socialware-migration`, `spec/loom-strip-historical-narrative`). The SPA there
is a **built Next.js static export** (no source in repo), transport is **SSE** (the
red-lined transport), render model is **ordered mutation-ops** (incompatible with the
declarative json-render tree). Migration manifest (design rev8, locked):
*"rewrite directly, reuse `main`, do NOT base on the loom/autoservice branches."*
The infrastructure half (Turn/Surface/CustomerFeed/CustomerAuth/PageView + the P4 React
foundation) is already migrated into main; loom's *vertical filling* (orchestrator prompts,
page-worker, page-SDK, Sandpack controlled-fetch) is future P5 work.

## #36 scope (reframed by Allen 2026-06-09)

- **Verify** the P4 foundation (render + transport + auth tests green; assets build;
  `/socialware/customer` boots).
- **agent-browser visual E2E** on a fresh disposable seeded stack (own ports, Tailscale
  `100.64.0.27`, NOT shared dev `:10042`): seed a session with an approved surface version
  + customer-visible messages, mint a CustomerAuth token, open `/socialware/customer` →
  screenshot chat + json-render page; + an unauthorized/cross-scope token →
  "Unauthorized" screenshot (§9 feed-authorization acceptance — no visual proof exists yet).

## Open design questions — DEFERRED (discuss after #36)

1. Customer identity model (§10.2) — anonymous/synthetic token vs seeded `entity://user`.
   (recommend: seeded user for the first E2E.)
2. Read-only feed vs customer→session **write-back** — recommend defer to **P5** (fused
   vertical + routing `{:from customer}→orchestrator`).
3. Sandpack `code` node controlled-fetch (loom's `fetch_proxy.ex`) — recommend defer;
   ship declarative tiers + sandboxed `code` node *without* network.
4. `{:within_workspace}` cap shape (§10.3) — only if tokens become cap-derived rather than
   `Phoenix.Token`-signed; otherwise current token is sufficient.
5. SPA standalone vs embedded — recommend keep **standalone** (`/socialware/customer`); a
   customer is an untrusted external viewer with no entity/caps, must not load the operator
   app shell.

## Related

- The "implicit protocol" formalization (Message schema versioning + URI addressing spec +
  envelope-relationship doc) is tracked separately as task #44.
