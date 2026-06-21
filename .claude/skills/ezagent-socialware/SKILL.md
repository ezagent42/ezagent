---
name: ezagent-socialware
description: >-
  Use whenever creating, configuring, or reasoning about a SOCIALWARE app in
  the ezagent codebase — i.e. a session made publicly viewable so external /
  anonymous users (not registered operators) can watch and join it. Trigger on
  any of: "socialware app", "public_view" session/template, the
  /socialware/chat or /socialware/customer surfaces, the customer React SPA,
  anonymous-visitor access, ChatFeed / CustomerFeed, AnonUser / AnonBinding,
  the anon→login takeover, or "how does an author publish a socialware
  experience". A socialware app is NOT a normal operator session — its
  defining property (public_view) lives on a SessionTemplate and unlocks a
  whole anonymous-access lifecycle most contributors don't know exists. Load
  this skill before touching any of that so you build on the real (currently
  primitive-based) author flow instead of inventing one. Pairs with the
  ezagent-developer skill for the underlying dispatch/CapBAC/Behavior rules.
---

# ezagent-socialware

You are authoring or modifying a **socialware app** in the ezagent repo. This
skill captures the *real* author flow as it exists in `main` today
(2026-06-21), validated end-to-end with agent-browser. It is deliberately
honest about the rough edges: the flow is **primitive-based, not yet
productized** — that is exactly why **world** (new UI) and **agent-schema**
(orchestration spec) are being built. See [§Future](#future-not-yet-in-main).

Pair this with the **ezagent-developer** skill — socialware sits on top of the
same Behavior + Kind + URI + CapBAC machinery, and its invariants still apply.

## The one idea: a socialware app IS a SessionTemplate

Hold this mental model first; the code is just its expression.

- A **socialware app** = a `SessionTemplate` whose content carries
  **`public_view: true`**. That template is the durable, versioned, forkable
  *definition* of the app (Behavior.Identity + Behavior.Template).
- A **session** = a *live instance* of that app, created bound to the template
  (`template_working_copy.session_template_uri`). It is what users actually
  connect to, and where the conversation + membership + state live.
- The customer link addresses a **`session_uri`**, but what makes that session
  "a socialware app" is the **template** behind it.

So the author's real job is: **(1) define the app = author a `public_view`
SessionTemplate; (2) instantiate a live session from it; (3) share the link.**

`public_view` is the structural authorization for the whole anonymous-access
lifecycle (anon minting, read-only join, customer SPA, anon→login merge). It is
read back by `Ezagent.Socialware.PublicView.public_view?/1`, which is checked at
the public ingress before any anon is minted.

## Two surfaces a socialware app exposes

| Route | Controller | Audience | Render |
|-------|-----------|----------|--------|
| `/socialware/chat?session_uri=…` | `EzagentWeb.Socialware.ChatFeedController` | anonymous visitor to a `public_view` session | server-rendered shell + the customer React SPA (`customer_app.js`) |
| `/socialware/customer?…` | `EzagentWeb.Socialware.CustomerController` | token-bound customer | the same React + json-render customer SPA |

The customer UI is **agent-generated** (composed turn-by-turn by the session's
orchestrator agent) — React + json-render, not hand-authored HEEx. The operator
admin UI is the separate hand-authored surface (today LiveView; world replaces
it — see Future).

## The author flow on `main` today (primitive-based)

> ⚠️ There is **no single "create socialware app" command or UI** yet. You
> assemble it from primitives. There is also **no UI toggle for `public_view`**
> — it is set only via template content / CLI JSON. (world will add the toggle;
> a world-dev task exists for it.)

### Step 1 — Author the app: a `public_view` SessionTemplate

```elixir
{:ok, template_uri} =
  Ezagent.Entity.SessionTemplate.persist_version_as_system(
    %{name: "my-app", public_view: true},
    "team-alpha"            # workspace name
  )
```

`public_view` is a **content key** declared on `Ezagent.Entity.SessionTemplate`
and read by `PublicView.public_view?/1`. Note the fail-closed semantics: only a
literal boolean `true` opens it; `"true"`, `false`, or absent = private.

The CLI equivalent is `mix ezagent.workspace.add_template <ws> <name> --json
'{…}'` — but note that path additionally requires a `class` field (the
orchestrator agent class, e.g. `cc`), because it registers a *workspace*
session-template that knows which orchestrator to spawn. For a minimal
public-view definition, the `persist_version_as_system/2` primitive above is the
lower-friction path.

### Step 2 — Instantiate a LIVE socialware session bound to the template

```elixir
session_uri = Ezagent.URI.new!("session://team-alpha/default/my-app-1")

{:ok, _pid} =
  Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
    uri: session_uri,
    behaviors: Ezagent.Entity.Session.socialware_behaviors()
  })

:ok = Ezagent.WorkspaceRegistry.bind(session_uri, Ezagent.Capability.workspace_of(session_uri))
{:ok, _} = Ezagent.Behavior.Session.ConfigActions.system_set_working_copy(
  session_uri,
  %{session_template_uri: template_uri}
)
```

In the real product flow the operator creates the session through the admin UI
(`Ezagent.Workspace.create_session/3`). If the bound template configures an
orchestrator, this ALSO spawns it — a cc-orchestrator agent is the thing that
generates the customer UI. (A *plain* template with no
`orchestrator_template_uri` takes the no-orchestrator arm and spawns none.) The
orchestrator is heavy and needs cc credentials; it can time out, **but the
session is still persisted** — assert on the session, not the orchestrator (see
ezagent-developer / project notes).

### Step 3 — Share the link; users view it

Open `/socialware/chat?session_uri=<session_uri>` as an anonymous visitor. The
controller `public_view?`-gates, mints a read-only `AnonUser`, drops a signed
`socialware_anon` cookie, joins the anon to the session, and serves the customer
SPA with a `data-token`.

## Load-bearing gotchas (learned the hard way)

These are the traps that will waste your time if you don't know them:

1. **`public_view?/1` reads the LIVE session Kind slice** (`Kind.get_slice`).
   A `public_view` session that is **not currently live** in the serving node
   fails the gate and the visitor is bounced to `/login` (302). In the product
   flow the session is created in-node (admin UI) so it is live. If you seed a
   session in a *separate* BEAM and then start the server, the server sees it
   cold → 302. Make the session live in the serving node (create it in-node, or
   see the E2E recipe for the `iex --dot-iex` trick). This intersects the known
   cold-restart respawn gap — a persisted-but-not-respawned session is invisible
   to the public gate.
2. **`public_view` has no UI toggle yet** — content/CLI only. Don't go looking
   for a checkbox in LV admin or world; it isn't there yet.
3. **The customer SPA bundle must be built.** `/socialware/chat` loads
   `/assets/js/customer_app.js` + `/assets/css/customer.css`. These come from
   the React app whose deps live in `apps/ezagent_web/assets/package.json`
   (react / react-dom / @codesandbox/sandpack-react). If `node_modules` isn't
   installed the bundle 404s and the page renders **blank** (HTTP 200 but empty
   DOM). Fix: `cd apps/ezagent_web/assets && pnpm install`, then
   `mix assets.build`, then reload.
4. **The anon lifecycle is automatic.** First public open mints
   `Ezagent.Socialware.AnonUser` (read-only, narrowly cap'd), records an
   `AnonBinding` (one-anon ⇄ one-session for life), sets the cookie. Abandoned
   anons are reaped at 48h by `AnonUser.GC`. On login, the anon's footprint is
   physically relabelled to the confirmed user via
   `EzagentWeb.Socialware.AnonTakeover` (the anon-user epic, #68). You rarely
   touch this — but know it exists before "fixing" anything anon-shaped.

## Verifying a socialware app (local E2E)

The proven recipe to stand one up on an isolated stack and confirm an anonymous
visitor can view it (agent-browser screenshot is the sign-off bar) is in
[`references/local-e2e-recipe.md`](references/local-e2e-recipe.md). Read it when
you need to validate author-flow changes end to end.

## Key modules (pointer index)

- `Ezagent.Entity.SessionTemplate` — the app definition; `public_view` content key, `persist_version_as_system/2`.
- `Ezagent.Socialware.PublicView` — `public_view?/1`, the public ingress gate (live-slice based, fail-closed).
- `Ezagent.Entity.Session` — `socialware_behaviors/0`; the session Kind.
- `Ezagent.Behavior.Session.ConfigActions` — `system_set_working_copy/2` (bind session→template).
- `EzagentWeb.Socialware.ChatFeedController` / `CustomerController` — the two public surfaces.
- `Ezagent.Socialware.{AnonUser, AnonBinding, ChatFeed, CustomerFeed}` — anon lifecycle + feed projections.
- `EzagentWeb.Socialware.{AnonCookie, AnonTakeover}` — signed cookie + anon→login merge.
- `Ezagent.Workspace.create_session/3` — the in-node create path (spawns orchestrator).

## Future (NOT yet in main)

Two in-flight efforts will productize this flow; **do not assume they exist when
working against current `main`**:

- **world** — the new unified ezagent frontend. Its first goal is to reproduce
  and fully retire the admin **LiveView** plugin (the operator/author surface) —
  that is where the `public_view` toggle and a real "create socialware app"
  author UX will land. But world's scope is broader than the admin UI: it is
  intended to **also subsume the external/customer-facing pages** (the
  anonymous/customer viewing surface). So today's React customer SPA at
  `/socialware/chat` + `/socialware/customer` is a transitional form — expect it
  to be folded into world over time, not to remain a permanently separate stack.
  (What world retires *immediately* is `ezagent_plugin_liveview`; the customer
  routes live in `ezagent_web`/`ezagent_domain_socialware` and are untouched by
  that first cut — but they are on world's eventual roadmap.)
- **agent-schema** — a spec for how autoservice-like backend services are
  orchestrated (how the orchestrator agent composes the customer experience).

Together with what's in `main` today, world + agent-schema are intended to form
the complete socialware product — world as the one frontend for both the author
and the customer, agent-schema as the orchestration contract behind it. The concepts **loom** and **autoservice** are
reference-only design vocabulary — they are NOT merged into code; do not cite
them as existing implementation. When these land, this skill must be updated
(tracked task: "Update ezagent-socialware skill when world + agent-schema land").
