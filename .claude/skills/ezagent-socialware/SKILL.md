---
name: ezagent-socialware
description: >-
  Use when creating, configuring, or reasoning about ezagent socialware: a
  public_view SessionTemplate/session that anonymous external users can watch or
  join. Trigger on socialware apps, public_view, /socialware/chat,
  /socialware/customer, customer React SPA, anonymous access, ChatFeed,
  CustomerFeed, AnonUser, AnonBinding, anon-to-login takeover, the world UI
  "Public socialware app" toggle, versioned templates, current tags,
  migrate_session, or author publishing flow. Pair with ezagent-developer for
  dispatch, CapBAC, Behavior, and Kind invariants.
---

# ezagent-socialware

## Invocation details

Use whenever creating, configuring, or reasoning about a SOCIALWARE app in the
ezagent codebase: a session made publicly viewable so external / anonymous users
(not registered operators) can watch and join it.

Trigger on any of:
- "socialware app"
- `public_view` session/template
- the `/socialware/chat` or `/socialware/customer` surfaces
- the customer React SPA
- anonymous-visitor access
- `ChatFeed` / `CustomerFeed`
- `AnonUser` / `AnonBinding`
- the anon-to-login takeover
- the "Public socialware app" toggle in the world UI
- versioned templates / the "current" tag / `migrate_session`
- the orchestrator member/rule/legend tools
- "how does an author publish a socialware experience"

A socialware app is not a normal operator session. Its defining property
(`public_view`) lives on a `SessionTemplate` and unlocks a whole
anonymous-access lifecycle most contributors do not know exists. Load this skill
before touching any of that so you build on the real author flow (now: world UI
+ versioned templates) instead of inventing one. Pair this with the
ezagent-developer skill for the underlying dispatch/CapBAC/Behavior rules.

You are authoring or modifying a **socialware app** in the ezagent repo. This
skill captures the *real* author flow as it exists in `main` (`515fcc99`,
2026-06-22). Two validation levels apply: the **Path-B primitive flow** is
agent-browser-proven end to end (anonymous visitor sees the rendered customer
page — recipe dated 2026-06-21 in `references/local-e2e-recipe.md`); the
**Path-A world UI flow** below is **documented from the merged code, not yet
re-run through the UI in a browser**. Treat Path A as code-accurate; if you
change it, screenshot-validate (the world author flow is exactly the kind of UI
work that earns an agent-browser sign-off).

Two efforts that this skill used to list as "future" have now **landed on
main**: **world** (the new unified frontend) and the **agent-definition-contract**
(a.k.a. agent-schema — versioned templates + the orchestrator tool catalog +
`migrate_session`). So the author flow is no longer raw-primitive-only: there is
now a real UI path *and* a content-addressed versioning model. What is still
*not* merged is the named "autoservice"/"loom" orchestration-contract layer —
that remains design vocabulary, not code (see [§Future](#future-still-not-in-main)).

Pair this with the **ezagent-developer** skill — socialware sits on top of the
same Behavior + Kind + URI + CapBAC machinery, and its invariants still apply.

## The socialware Definition is the publishable unit (T2 — fattened)

> **2026-07-02 (T2 app-package).** The **publishable unit is the socialware
> `Definition`** (`Ezagent.Socialware.Definition`), NOT the SessionTemplate and
> NOT a new "app" concept. Three layers (emacs analogy): the **Definition** =
> publishable deliverable (a major/minor mode); the **SessionTemplate** = which
> socialwares a session installs (`installs: [name]`); the **session** = the
> running instance (a named left-rail conversation). The user面 never sees the
> word "app" — always a named conversation (AutoService / website / kanban).

A `Definition` now carries, besides `bases`/`shape`/`members`/`routing_rules`/
`prompt_templates`/`legends`/`orchestrator_template_uri`/`adapters`/
`visibility_policy`, **two more fields**:

- **`agents: [%{recipe: name, role_name: name}]`** — the agents this socialware
  brings into a session. `recipe` (config义) = a `RecipeRegistry` name (agent能干
  什么 + `requested_caps` live in the recipe; the Definition never
  overrides/appends caps — caps' sole source is the recipe). `role_name`
  (routing义) = the per-session-unique routing identifier (`{:role, name}`
  receiver). `Definition.new/1` does SHAPE-ONLY validation; recipe existence +
  role_name uniqueness are checked by the gate + at materialize/join time.
  **Materialization** (`SessionCreator.DefinitionAgents`): resolve recipe by
  workspace → spawn a per-session agent → JOIN as a member with the `role_name`
  facet (reusing the `add_managed_member` safe spawn/join/cleanup envelope) →
  `GrantRecipeCaps` lands the recipe's `requested_caps`. Runs on create + repair
  (idempotent).
- **`views: [view_actionset]`** — **views-as-behavior**. A view is a render
  ActionSet; declaring it puts it into `Definition.behaviors/1`
  (`[Session] ++ views ++ shape ++ bases`) so it enters the spawned Session
  behavior set. Each view declares a **UNIQUE `<sw>_render` action** (e.g.
  `:hello_render`) — NOT a shared `:render` (which would collide in the
  `CapabilityRegistry` `{kind, action}` uniqueness the moment two views
  register). A view read ActionSet is **cap-only** (`dispatchable? false`,
  `required_caps` only, no dispatch interface — the `ExternalFeedAdapter.Allow`
  precedent).

### View visibility = a view-cap, checked at ONE authorization point

Old model (**retired**): a session was visible/invisible as a WHOLE
(membership-only authorization). New model: **per-view visibility via a
capability**, sunk into the `Ezagent.UI.SessionView` contract:

- `SessionView.authorize_view(view, caller, session_uri)` is the single gate
  every render entry routes through. A view declares its backing render ActionSet
  via `view_behavior/0`; `authorize_view` checks the caller holds that ActionSet's
  `<sw>_render` cap on the session. `SessionViewRegistry.applicable_views/2` +
  `external_renderers/2` are the caller-aware, gated arities. An arch gate
  (`view_authorize_gate_test`) asserts no renderer reads the `:surface` slice
  while bypassing `authorize_view`.
- **Anonymous visibility** = the anon is minted a real read-only User born with
  the view read-caps of the session's **public** installed definitions only
  (`Installation.anon_view_caps/1`, appended to the `session.join` cap in
  `AnonUser.mint_for_public_session`). A view of a NON-public installed
  definition (kanban-private in a hello-public session) contributes no cap → the
  anon cannot render it.
- **Two orthogonal gates.** Coarse: openness
  (`Definition.visibility_policy.web_anon_access`) decides whether an anon is
  minted at all (can it enter the session). Fine: the view-cap (`authorize_view`)
  decides which views a caller sees. hello对外 / kanban对内 can coexist in one
  session.

### Conformance gate

`mix ezagent.socialware.check [<name>]` runs `Ezagent.Socialware.Conformance` —
the one rule "every declared reference resolves" as the SPEC §4 assertions
(bases/shape/views load, view render-caps registered, agents' recipes resolve
with registered caps + unique role_names, adapters registered, orchestrator URI
parses, definition installable, routing receivers + every `prompt_template_ref`
resolve). Wired into `ci.local`; a bad recipe / view / adapter / prompt_ref goes
RED.

## The one idea: a socialware app IS a (versioned) SessionTemplate

Hold this mental model first; the code is just its expression.

- A **socialware app** = a `SessionTemplate` whose content carries
  **`public_view: true`**. That template is the durable, **immutable,
  content-addressed, forkable** *definition* of the app (Behavior.Identity +
  Behavior.Template).
- Templates are now **versioned**: every persisted version lives at
  `template://session/<workspace>/<name>@<hash>`, where `<hash>` is a SHA-256
  over the deterministic-serialized content slice. Identical config ⇒ identical
  hash; any config edit mints a NEW immutable version (it never mutates in
  place). See `Ezagent.Entity.SessionTemplate.compute_version_hash/1` +
  `build_uri/3`.
- A **session** = a *live instance* of that app, created bound to one template
  **version** (`template_working_copy.session_template_uri`, the `@hash` URI).
  It is what users actually connect to, and where the conversation + membership
  + state live.
- The customer link addresses a **`session_uri`**, but what makes that session
  "a socialware app" is the **template** behind it.

So the author's real job is: **(1) define the app = author a `public_view`
SessionTemplate; (2) instantiate a live session from it; (3) share the link.**

`public_view` is the structural authorization for the whole anonymous-access
lifecycle (anon minting, read-only join, customer SPA, anon→login merge). It is
read back by `Ezagent.Socialware.PublicView.public_view?/1`, which is checked at
the public ingress before any anon is minted. It is a SessionTemplate-level flag
set ONCE on the template (not per session); sessions inherit it.

## Two surfaces a socialware app exposes

| Route | Controller | Audience | Render |
|-------|-----------|----------|--------|
| `/socialware/chat?session_uri=…` | `EzagentWeb.Socialware.ChatFeedController` | anonymous visitor to a `public_view` session | server-rendered shell + the customer React SPA (`/assets/js/customer_app.js`) |
| `/socialware/customer?…` | `EzagentWeb.Socialware.CustomerController` | token-bound customer | the same React + json-render customer SPA |

The customer UI is **agent-generated** (composed turn-by-turn by the session's
orchestrator agent) — React + json-render, not hand-authored HEEx. These public
routes live in `ezagent_web` + `ezagent_domain_socialware` and are served on the
**default host** (a public `:browser` scope, no `RequireEntity`). **world does
not touch them** — world owns the *operator/author* surface only (on the
`world.` host). The customer surface is on world's eventual roadmap but is a
separate stack today.

## The operator/author surface is now `world` (LiveView retired)

The old `ezagent_plugin_liveview` admin plugin is **fully removed** — its
absence is enforced by invariant tests (`lv_cli_parity_test.exs`,
`workspace_lv_cli_parity_test.exs` `refute File.dir?(.../ezagent_plugin_liveview)`).
The operator console is now **`ezagent_plugin_world`**: a LiveView SSR/comms
shell (`WorldLive`) that hydrates React/TSX islands (`phx-hook="WorldRenderer"`)
and routes dispatched actions back to the server. It owns `/admin/*`,
`/identities/*`, `/workspaces/*`, `/sessions`, `/profile`, etc. on `host:
"world."` (see `apps/ezagent_web/lib/ezagent_web/router.ex`).

## The author flow

There are now two equivalent author paths. Path A (world UI) is the productized
one; Path B (primitives) is what you use in code, tests, and the local E2E
recipe.

### Path A — world UI (the productized path)

1. **Author the app**: world `/workspaces/<name>` → the **Session templates**
   panel (`SessionTemplatePanel`, `WorkspacePlugin.tsx`) → check the
   **"Public socialware app"** checkbox → Save. This dispatches
   `workspace.template.save` → `Ezagent.World.WorkspacePluginActions.save_session_template/2`
   → `Ezagent.Entity.SessionTemplate.create/3` with content `%{…, public_view:
   true}`. The atom key `:public_view` it writes is exactly the key
   `PublicView.public_view?/1` reads (`Map.fetch(content, :public_view)`, with a
   `"public_view"` string fallback) — author-toggle → anon-gate is wired end to
   end.
2. **Instantiate a live session**: world `/sessions` → the **"New session"** form
   (`SessionsTable.tsx`) → name + pick the template → dispatches `session.create`
   → `Ezagent.Workspace.create_session/3` (the in-node create path; if the bound
   template configures an orchestrator, this ALSO spawns it).
3. **Share** `/socialware/chat?session_uri=<session_uri>`.

> ⚠️ **Versioning gotcha — the world "New session" form picks a template by
> *name*, and name→version resolution uses the `"current"` tag.** But neither
> `SessionTemplate.create/3` (the world save path) nor
> `persist_version_as_system/2` (the primitive) publishes a `"current"` tag —
> only the orchestrator tools `update_template` / `save_template_as` do (via
> `publish_current/4`). So a freshly-authored template has NO `"current"` tag,
> and name-based instantiation falls through to the prefix-scan fallback in
> `template_resolver.ex` (it scans live Kinds / snapshots for a matching
> `name@…`). That is fine — *deterministic* — when only one version of that name
> exists, but becomes **nondeterministic once a second version exists**. For
> guaranteed adopt-on-create, either publish the tag explicitly
> (`Ezagent.TemplateTags.put(ws, name, "current", hash, by)`) or instantiate
> against the exact `@hash` URI (what the local E2E recipe does).

### Path B — primitives (code / tests / CLI)

```elixir
# 1. Author the app: a public_view SessionTemplate version (@hash URI)
{:ok, template_uri} =
  Ezagent.Entity.SessionTemplate.persist_version_as_system(
    %{name: "my-app", public_view: true},
    "team-alpha"            # workspace name
  )

# 2. Instantiate a LIVE session and bind it to that exact version
session_uri = Ezagent.URI.new!("session://team-alpha/default/my-app-1")

{:ok, _pid} =
  Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
    uri: session_uri,
    behaviors: Ezagent.Entity.Session.socialware_behaviors()
  })

:ok = Ezagent.WorkspaceRegistry.bind(session_uri, Ezagent.Capability.workspace_of(session_uri))
{:ok, _} = Ezagent.Behavior.Session.ConfigActions.system_set_working_copy(
  session_uri,
  %{session_template_uri: template_uri}    # the @hash URI — no name resolution
)
```

`public_view` is a recognized content key (`normalize_config_keys/1`); only a
literal boolean `true` opens it (`"true"`, `false`, or absent = private,
fail-closed). Binding the exact `@hash` `template_uri` sidesteps the
`"current"`-tag caveat entirely. The CLI equivalent for step 1 is `mix
ezagent.workspace.add_template <ws> <name> --json '{…}'` (note: that path
additionally needs a `class` field — the orchestrator agent class, e.g. `cc`).

## The orchestration model (agent-definition-contract, merged)

Once a session is live, its **orchestrator agent** shapes the experience using
the MCP tool catalog (`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server/tool_catalog.ex`).
The merged model is: **orchestrator agent + managed members + routing
rules/rule-sets + prompt templates + legends, all content-addressed into a
versioned SessionTemplate.** The 10 wire-exposed tools:

| Tool | Purpose |
|------|---------|
| `add_managed_member` | spawn a worker from an AgentTemplate, join it as a member with a stable `role_name` |
| `update_member_template` | swap a member's source AgentTemplate and regenerate the worker at the same `role_name` |
| `remove_member` | terminate a member and prune rules naming it |
| `define_rule_set_rule` | add a single-receiver routing rule to a named rule-set (static `{from:X}->Y`, no model-computed baton) |
| `define_prompt_template` | install a named prompt template (rendered at delivery) |
| `define_legend` | front a rule-set with an `@legend` handle that collapses a member set |
| `update_template` | snapshot the session as a NEW VERSION of its parent SessionTemplate (publishes `"current"`) |
| `save_template_as` | snapshot the session as the FIRST VERSION of a NEW template family (publishes `"current"`) |
| `migrate_session` | re-point this live session onto a new immutable template version |
| `list_templates` | list Agent/Session templates visible by caps |

`migrate_session` (`Ezagent.Orchestrator.Tools.Migration`) re-points a *live*
session to a new immutable SessionTemplate version: it diffs members by
`role_name`/`source_template_uri`, regenerates only changed/new ones via
`update_member_template`, replaces the session's rule-sets / prompt templates /
legends, and finalizes by re-pinning the working copy — all tracked in a
**resumable `migration_ledger`** (`{role => :pending|:done|:failed}`) so a
partial failure can resume without redoing completed roles.

## Load-bearing gotchas (learned the hard way)

These are the traps that will waste your time if you don't know them:

1. **`public_view?/1` reads the LIVE session Kind slice** (`Kind.get_slice`).
   A `public_view` session that is **not currently live** in the serving node
   fails the gate and the visitor is bounced to `/login` (302). In the product
   flow the session is created in-node (world UI) so it is live. If you seed a
   session in a *separate* BEAM and then start the server, the server sees it
   cold → 302. Make the session live in the serving node (create it in-node, or
   see the E2E recipe for the `iex --dot-iex` trick). This intersects the known
   cold-restart respawn gap — a persisted-but-not-respawned session is invisible
   to the public gate.
2. **`public_view` is set at the TEMPLATE level, via the world toggle (or
   content/CLI) — there is no per-session toggle.** world's "New session" form
   does not expose `public_view`; the flag comes from the chosen template. The
   checkbox lives on the *Session templates* panel, not the session creator.
3. **The `"current"` tag is not auto-published on author save** — see the
   versioning gotcha under Path A. Bind by exact `@hash` URI, or publish the tag,
   for deterministic adopt-on-create when multiple versions of a name exist.
4. **The customer SPA bundle must be built.** `/socialware/chat` loads
   `/assets/js/customer_app.js` + `/assets/css/customer.css`. These come from
   the React app whose deps live in `apps/ezagent_web/assets/package.json`
   (react / react-dom / @codesandbox/sandpack-react). If `node_modules` isn't
   installed the bundle 404s and the page renders **blank** (HTTP 200 but empty
   DOM). Fix: `cd apps/ezagent_web/assets && pnpm install`, then
   `mix assets.build`, then reload.
5. **The anon lifecycle is automatic.** First public open mints
   `Ezagent.Socialware.AnonUser` (read-only, narrowly cap'd), records an
   `AnonBinding` (one-anon ⇄ one-session for life), sets the cookie. Abandoned
   anons are reaped at 48h by `AnonUser.GC`. On login, the anon's footprint is
   physically relabelled to the confirmed user via
   `EzagentWeb.Socialware.AnonTakeover` (the anon-user epic, #68). You rarely
   touch this — but know it exists before "fixing" anything anon-shaped.

## Verifying a socialware app (local E2E)

The proven recipe to stand one up on an isolated stack and confirm an anonymous
visitor can view it (agent-browser screenshot is the sign-off bar) is in
[`references/local-e2e-recipe.md`](references/local-e2e-recipe.md). It uses the
Path-B primitives + exact-`@hash` binding (so it is immune to the `"current"`-tag
caveat). Read it when you need to validate author-flow changes end to end.

## Key modules (pointer index)

- `Ezagent.Entity.SessionTemplate` — the app definition; `public_view` content key, `compute_version_hash/1`, `build_uri/3`, `create/3`, `persist_version_as_system/2`.
- `Ezagent.Entity.AgentTemplate` — member sources; versioned `@hash` URIs (`compute_version_hash/1`, `build_versioned_uri/3`).
- `Ezagent.TemplateTags` — git-style mutable refs over immutable hashes; `put/5`, `move/5`, `resolve/3`; the `"current"` tag = adopt-on-create pointer.
- `Ezagent.Socialware.PublicView` — `public_view?/1`, the public ingress gate (live-slice based, fail-closed).
- `Ezagent.Entity.Session` — `socialware_behaviors/0`; the session Kind.
- `Ezagent.Behavior.Session.ConfigActions` — `system_set_working_copy/2` (bind session→template version).
- `Ezagent.Orchestrator.Tools.Migration` — `migrate_session/2` (resumable re-pin) and its `migration_ledger`.
- `Ezagent.Orchestrator.Tools.Templates` — `update_template` / `save_template_as` / `publish_current/4`.
- `EzagentWeb.Socialware.ChatFeedController` / `CustomerController` — the two public surfaces.
- `Ezagent.Socialware.{AnonUser, AnonBinding, ChatFeed, CustomerFeed}` — anon lifecycle + feed projections.
- `EzagentWeb.Socialware.{AnonCookie, AnonTakeover}` — signed cookie + anon→login merge.
- `Ezagent.Workspace.create_session/3` — the in-node create path (spawns orchestrator).
- `EzagentPluginWorld.WorldLive` + `Ezagent.World.WorkspacePluginActions` — the world operator/author surface (`save_session_template/2` writes `public_view`).

## Future (still NOT in main)

What world + the agent-definition-contract have **already landed** is described
above as current reality. What remains genuinely future:

- **The named orchestration-contract layer** — "autoservice" and "loom" are
  still **reference-only design vocabulary**, NOT merged code (grep finds them
  only in `docs/` and one stray comment). The actual merged orchestration is the
  tool catalog above; there is no separate schema layer governing customer-UI
  generation. Do not cite autoservice/loom as existing implementation.
- **world subsuming the customer surface** — today world owns only the
  operator/author console; the anonymous/customer viewing pages
  (`/socialware/chat`, `/socialware/customer`) remain the separate
  `ezagent_web` + `ezagent_domain_socialware` stack. Folding them into world is
  on the roadmap, not done.
- **Auto-`"current"` on author save** — a usability gap: neither the world save
  path nor the persist primitive tags the new version `"current"`, so
  deterministic name-based adopt-on-create currently depends on the orchestrator
  tool path or an explicit tag write (gotcha #3). A future improvement may
  publish the tag at author time.

When these land, update this skill (and revisit the gotchas above).
