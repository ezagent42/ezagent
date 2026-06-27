# Socialware as template → data → instance — architectural analysis

**Date:** 2026-06-26  ·  **Status:** research / read-only audit (no implementation)
**Repo basis:** `ezagent42/ezagent` `origin/main` @ `67b49303`
**Skills loaded:** `ezagent-socialware`, `ezagent-developer`

## The lead's mental model (under test)

> 1. **socialware is essentially a TEMPLATE** — a schema a developer fills to define the app.
> 2. **the real socialware = the DATA produced by filling that template** (likely in `EZAGENT_HOME`).
> 3. **a running socialware = a session + a hello bound to that session.**

Verdict in one line: **the model is correct in shape and largely realized in code**, with three
precise corrections — (a) "views" are *code* registrations, not template data; (b) the definition
DATA lives in **PostgreSQL** (`EzagentCore.Repo`), not in `EZAGENT_HOME` files; (c) "hello" is *one*
concrete customer-facing vertical, and the per-instance binding is the session's own `Surface` slice
+ a joined builder member + a session-keyed route — not a global "View registration".

---

## Match / diverge table

| Clause | Verdict | Evidence (file:line) |
|---|---|---|
| **1. socialware = a TEMPLATE** (a fillable schema defining the app) | **MATCH** for behaviors/team/routing/persona/visibility; **PARTIAL** — "views" are not template data | `Ezagent.Entity.SessionTemplate` Kind, `behaviors: [Identity, Template]` (`apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex:156`); content schema = `name, description, members, prompt_templates, legends, orchestrator_template_uri, routing_rules, default_workspace_uri, parent_template_uri, public_view` (`@config_atom_keys` `:761`); `public_view` is the defining socialware flag (`apps/ezagent_domain_socialware/lib/ezagent/socialware/public_view.ex:38`). Views are NOT in the template — they are global code registrations (see below). |
| **2. real socialware = DATA from filling the template, in `EZAGENT_HOME`** | **MATCH** on "it is data"; **DIVERGE** on "in `EZAGENT_HOME`" | The definition is genuinely DATA: content-addressed `compute_version_hash/1` (`session_template.ex:191`), immutable/versioned URIs `template://session/<ws>/<name>@<hash>` (`build_uri/3` `:222`), forkable (`fork/3` `:520`, `create/3` `:609`, `persist_version_as_system/2` `:345`), portable. **BUT** it persists to **PostgreSQL** (`kind_snapshots` table via `{:snapshot, :on_change}` `:159` → `Ezagent.SnapshotStore`), and `EzagentCore.Repo` is Postgres whose own moduledoc says `EZAGENT_HOME` holds **credentials/agent-config/logs, NOT the application tables** (`apps/ezagent_core/lib/ezagent_core/repo.ex:1-13`). So the data lives in the app DB, not in `EZAGENT_HOME`. |
| **3. running socialware = session + a hello bound to it** | **MATCH** (terminology nuance) | A running instance = a live `Ezagent.Entity.Session` spawned with `socialware_behaviors/0` = `[Session, Turn, Surface, Publisher.SessionImpl]` (`apps/ezagent_domain_session/lib/ezagent/entity/session.ex:87`), bound to a template *version* via `template_working_copy.session_template_uri` (set by `ConfigActions.system_set_working_copy/2`, read by `PublicView` `public_view.ex:79-83`). The "hello" customer face = the session's `Behavior.Surface` slice (`apps/ezagent_domain_session/lib/ezagent/behavior/surface.ex` — customers read the `:approved` version, `:6`), produced by a joined `HelloBuilder` member, exposed at the **session-keyed** route `/socialware/chat?session_uri=…` (`apps/ezagent_web/lib/ezagent_web/controllers/socialware/chat_feed_controller.ex:76`, gated by `PublicView.public_view?/1` `:108`). |

---

## Clause 1 — "socialware is essentially a TEMPLATE"

**There is a real template/schema, and it is the `SessionTemplate` Kind.** A socialware app is a
`SessionTemplate` whose content carries `public_view: true`. The schema a developer fills is the
content map enumerated in `@config_atom_keys` (`session_template.ex:761`):

- **team / behaviors** → `members` (each `%{uri, role_name, in_session_template, source_template_uri}`)
- **routing** → `routing_rules` (rule-set matchers → receivers)
- **bot persona** → `prompt_templates` (named, rendered at delivery) + `legends`
- **the orchestrator** → `orchestrator_template_uri` (`nil` = orchestrator-less / "plain")
- **visibility policy** → `public_view: true|false` (the single structural socialware switch)
- **landing workspace** → `default_workspace_uri`; **lineage** → `parent_template_uri`

"Filling it" = supplying that content map and persisting a version (`create/3` / `fork/3` /
`persist_version_as_system/2`). Each distinct content slice mints a new immutable `@hash` version.

**The one PARTIAL.** The lead listed "views" among what the template defines. **Views are NOT template
data** — they are global, *type-level* code registrations in `Ezagent.UI.SessionViewRegistry`
(`apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view_registry.ex`). A view declares
`applies_to?/1` (e.g. hello's `PageView` matches any `:hello`-type session,
`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/page_view.ex`) and the registry dispatches it for
every matching session. The template does not enumerate or carry its views. ("recipe" in the lead's
phrasing maps to the `SessionTemplate` itself — there is no separate "Recipe" type on `main`.)

## Clause 2 — "the real socialware = the DATA produced by filling the template"

**The "it is data, not code" half is a clean MATCH** for the *definition*. The `SessionTemplate` is
not a compiled plugin or a hand-written behavior — it is a content map reduced to a SHA-256 content
hash (`compute_version_hash/1`), addressable, immutable-per-row, forkable, and instantiable. Identical
config ⇒ identical hash; any edit mints a new version. This is the role-as-data / config-as-data
direction realized for the app definition.

There are in fact **two data substrates**, and conflating them is the most common error:

1. **`SessionTemplate` (durable app *definition*)** — the versioned, content-addressed template
   described above. Persisted as a Kind snapshot.
2. **`Ezagent.Socialware.ConfigStore` / `ConfigObject` (runtime *config cascade*, role-as-data #1048)** —
   append-only immutable config objects keyed `(workspace_uri, subject_uri, key)` with a `body` map,
   updated by repointing a `ConfigPointer`, layered `workspace > user > session`
   (`apps/ezagent_domain_identity/lib/ezagent/socialware/config_store.ex`,
   `config_object.ex:16-20`). This is the *live, evolving* config of a running app, not its birth
   definition.

Both are DATA. Both live in **PostgreSQL** (`EzagentCore.Repo`), so the geography clause **diverges**:

> `EzagentCore.Repo` … "filesystem state under `EZAGENT_HOME` (credentials, agent config, logs) lives
> outside the repo, so backup/restore must cover both PostgreSQL and the profile directory."
> — `apps/ezagent_core/lib/ezagent_core/repo.ex:6-12`

`EZAGENT_HOME` (`apps/ezagent_core/lib/ezagent/home.ex`) resolves credentials, per-agent config, and
logs — **not** the template/config rows. So the lead's "likely in `EZAGENT_HOME`" is the wrong
location: the socialware DATA is in the application DB; `EZAGENT_HOME` holds the *agent* runtime state
that an app's members may use.

**One genuine "data vs code" caveat.** A socialware *app definition* is data, but a socialware
*vertical's behavior* is code. The hello vertical's catalog, its `@json-render` spec validator
(`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/spec.ex`), its `HelloBuilder` agent, its
`TurnDriver`, and its renderer island are a compiled plugin (`ezagent_plugin_hello`). The
`SessionTemplate` *references* and *configures* that code (e.g. `members` naming a builder); it does
not contain it. So: **definition = data; vertical mechanism = code.**

## Clause 3 — "a running socialware = a session + a hello bound to that session"

**MATCH.** The canonical realization is the hello vertical's `App.ensure_app/2`
(`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex:24`), which is literally the lead's
sentence in code:

```
1. SessionTemplate.persist_version_as_system(%{name: "hello-…", public_view: true}, ws)   # the DATA
2. spawn_kind(Session, %{uri: session_uri, behaviors: Session.socialware_behaviors()})    # the SESSION
3. ConfigActions.system_set_working_copy(session_uri, %{session_template_uri: tmpl})       # bind session→template version
4. spawn_kind(HelloBuilder, …) + session.join(role "builder")                              # the "hello" (builder member)
```

The **session↔template binding** is `template_working_copy.session_template_uri` — a durable pointer
on the session's `:session` slice (`public_view.ex:79-83`). That pointer is what makes the session
"a socialware app": `PublicView.public_view?/1` follows it to the Template and returns `true` only for
an explicit `public_view: true` (`public_view.ex:38-49`).

The **session↔hello (external surface) binding** is *not* a route table or a global registration — it
is **the session's own `Behavior.Surface` slice**. The builder generates a json-render tree stored as
a Surface version on the session; customers read the `:approved` version
(`apps/ezagent_domain_session/lib/ezagent/behavior/surface.ex:6`). The external page is served by the
**session-keyed** route `/socialware/chat?session_uri=<session://…>` (`chat_feed_controller.ex:76`),
gated by `public_view?/1` (`:108`). So the hello page is the external surface of **a specific
session**, not a global page — exactly the lead's claim.

**Terminology nuance to keep honest:**
- "hello" is **one** concrete customer-facing vertical (an AI page-builder demo), not the generic
  socialware surface. Generically, the external face of any socialware session is just its `Surface`
  slice rendered through the `SessionView` external-render path; hello is currently the wired example.
- The per-instance binding has three parts (Surface slice + joined builder member + session-keyed
  route), all session-scoped. The `SessionView`/`PageView` registration the lead might call "View
  registration" is **global and type-level** (`applies_to?` filters by `:hello`), so it is the *render
  contract*, not the per-running-instance binding.

---

## The "socialware editor" gap

**What exists** (authoring surfaces, reconciled against the world↔LV parity interface inventory
`docs/superpowers/specs/2026-06-21-world-lv-parity-INVENTORY.md` — the `save_session_template` /
`select_template_class` / `add_template` actions — and the orchestrator MCP tool catalog
`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server/tool_catalog.ex`):

1. **world Session Templates panel** — `WorkspacePlugin.tsx` → dispatch `workspace.template.save` →
   `Ezagent.World.WorkspacePluginActions.save_session_template/2`
   (`apps/ezagent_plugin_world/lib/ezagent/world/workspace_plugin_actions.ex:191`) →
   `SessionTemplate.create/3`. Sets the **"Public socialware app"** toggle.
2. **world New session form** — `session.create` → `Workspace.create_session/3` (in-node; spawns the
   orchestrator + materializes the team).
3. **Template Class seam** — a plugin registers `template_classes/0` (hello:
   `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex:53` →
   `EzagentPluginHello.Template.HelloSession`, `template_name "session.hello"`) so world's *generic*
   `session.create` can instantiate a vertical with no world edit.
4. **Primitives / CLI** — `persist_version_as_system/2`; `mix ezagent.workspace.add_template <ws>
   <name> --json '{…}'`; hello's `mix ezagent.demo.seed_hello`.
5. **In-session orchestrator tools** — `add_managed_member`, `define_rule_set_rule`,
   `define_prompt_template`, `define_legend`, `update_template`, `save_template_as`, `migrate_session`.

**What is missing — the actual gap.** The world UI form **cannot fill the full template**. Its content
builder hardcodes everything but name/description/visibility:

```elixir
# apps/ezagent_plugin_world/lib/ezagent/world/workspace_plugin_actions.ex:326
defp session_template_content(params, workspace_uri) do
  %{
    description: …,            # from form
    members: [],               # ALWAYS empty
    prompt_templates: %{},     # ALWAYS empty
    legends: %{},              # ALWAYS empty
    routing_rules: [],         # ALWAYS empty
    default_workspace_uri: workspace_uri,
    public_view: truthy?(…)    # from form (the checkbox)
  }
end
```

So a developer **cannot, in a UI, author the team / routing / persona / legends** as definition-data.
Those rich parts are authored only by (a) running a session and driving the **orchestrator agent**
tools, then snapshotting back via `update_template`/`save_template_as`, or (b) code, or (c) CLI
`--json`. The "editor" for the full app is therefore the **running session + the orchestrator
conversation**, not a declarative authoring surface — an agent-driven loop, not a form. There is also:

- **No "New socialware app" affordance** that picks a vertical/template-class + flips `public_view` in
  one step (hello relies on the generic `session.create` seam; no dedicated UI button).
- **No customer-surface preview in world** — the customer pages (`/socialware/chat`,
  `/socialware/customer`) are a **separate** `ezagent_web` + `ezagent_domain_socialware` stack on the
  default host; world owns only the operator/author console (per `ezagent-socialware` skill §Future).
- **No auto-`"current"` tag on author-save** — neither `create/3` nor `persist_version_as_system/2`
  publishes the `"current"` tag, so name-based "New session" adopt-on-create is nondeterministic once a
  second version of a name exists (skill gotcha #3).

> Label note: the prompt's "#135 interface inventory" does not resolve to a single artifact — GitHub
> `ezagent42/ezagent#135` is the unrelated `cc.agent` Template PR. The closest real interface
> inventory is the world↔LV parity INVENTORY above; this analysis reconciles against it + the
> orchestrator tool catalog. Flag for the lead if a different "#135" doc was intended.

---

## Is the model realized? Gap → scope (no impl prescribed)

| Sub-goal | Today | Gap | Scope |
|---|---|---|---|
| template exists | `SessionTemplate` Kind, `public_view` content | none | — |
| definition is data | content-addressed, versioned, forkable in Postgres | none (geography is Postgres, not `EZAGENT_HOME`) | — |
| running = session + bound surface | `App.ensure_app` flow; Surface slice + session-keyed route | none for hello; generic external surface is a separate stack | — |
| author **visibility + name** in UI | world template panel checkbox | none | — |
| auto-adopt a freshly-authored template by name | `"current"` tag not auto-published | nondeterministic with >1 version | **S** — publish `"current"` on author-save (or bind by `@hash`) |
| author **full definition** (team/routing/persona/legends) in a UI | only via orchestrator-runtime / code / CLI `--json` | world form hardcodes them empty | **M** — a world template editor that fills `members`/`routing_rules`/`prompt_templates`/`legends` (form ⇄ the same semantics the orchestrator tools express) + a "New socialware app" picker |
| **preview/serve the customer surface from the author console** | separate `ezagent_web`/`ezagent_domain_socialware` stack | world does not own/preview the customer face | **L** — fold the external/customer surface into world with live preview, unifying static template authoring with the in-session orchestrator authoring loop |

**Bottom line.** The template → data → (session + bound surface) model is **structurally real and
wired end-to-end** for the hello vertical: `SessionTemplate` is the fillable template, its content is
genuine content-addressed data, and a running app is a session bound to a template version that exposes
a per-session Surface. Where it **isn't** the lead's model: the definition data lives in PostgreSQL
(not `EZAGENT_HOME`), "views" are code (not template data), and there is **no declarative authoring
tool that fills the full template** — the rich definition is produced by an agent-driven in-session
loop, not a "socialware editor". Closing the authoring gap is the S+M work above; making the customer
face first-class in the author console is the L.

---

## Open questions for the lead

1. **`EZAGENT_HOME` intent.** Did you mean the *agent* runtime state (which IS in `EZAGENT_HOME`), or
   should the socialware definition/config data also live there? Today both substrates are in Postgres.
2. **"#135 interface inventory"** — gh#135 is the `cc.agent` PR. Is the intended inventory the world↔LV
   parity INVENTORY, the orchestrator tool catalog, or a doc I haven't located?
3. **Editor target.** Should the "socialware editor" be a declarative form (M scope) or is the
   agent-driven in-session orchestrator loop the intended authoring UX, with the form staying minimal?
4. **"hello" scope.** Is "hello" meant as *the* canonical socialware surface, or one vertical among
   future ones (the generic external face being any session's Surface slice)?
