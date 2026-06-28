# SPEC — Ezagent taxonomy & carrier-layer boundaries (anti-leak design doc)

> **Status: DESIGN (taxonomy/boundary doc, NOT implementation).** Read-only basis;
> no code changed by this SPEC. Skills loaded: `ezagent-developer`,
> `ezagent-socialware`. All code citations verified against `origin/main`
> (`c37f2008`, "refactor(agent): rename recipe storage key + subject path
> role→recipe (#1071)"). Worktree off `origin/main`; branch
> `docs/ezagent-taxonomy`. Codex adversarial-review record in §8.
>
> **Companion to, NOT a replacement for, `docs/socialware-concepts.md`** (the
> P0 authoring guide, already on `main`). The concepts doc defines *what a
> base/socialware/fixture IS*. This SPEC defines a second, orthogonal axis —
> **the 4 carrier layers: WHERE each artifact physically lives, and the red
> lines that keep vertical/business concepts out of generic layers.** The two
> docs compose: a contributor reads `socialware-concepts.md` for the concept
> taxonomy and this SPEC for the carrier-layer + anti-leak boundary rules.
>
> **Synthesizes** the lead-decided model in
> `docs/together/2026-06-26/specs/socialware-unification.md` (on
> `origin/implement/socialware-unification-p1-p10`) — base/socialware/fixture +
> recipe(responsibility) axes — and projects it onto a 4-layer carrier map so
> the "where does X go" question has one answer.

---

## 0. The four carrier layers

Every artifact in ezagent lives in exactly one of four carrier layers. The
layers are about **what kind of artifact** it is (code / config-data /
runtime-state / host-file), which is **orthogonal to the three code tiers**
(core / domain / plugin — see `references/three-tier-structure.md`). The
three tiers govern **code dependency direction**; the four carrier layers
govern **artifact kind + storage home + anti-leak rules**. A single code
module can emit artifacts into several carrier layers (e.g. a plugin ships
code in layer 1 AND seed definitions in layer 2).

```
┌─────────────────────────────────────────────────────────────────────────────┐
│ LAYER 4 — EZAGENT_HOME files        (host-side runtime files)                │
│   creds, kanban-boards.json mapping, logs, PTY pid-files, upload bytes      │
│   NOTHING queryable by the BEAM as typed state; files the host OS owns      │
├─────────────────────────────────────────────────────────────────────────────┤
│ LAYER 3 — Runtime state data        (Postgres `kind_snapshots` slice + blobs)│
│   per-agent/session DYNAMIC instance state: kanban task list, messages,     │
│   turn state, membership, settlement. The live slice.                      │
│   ► Blob sub-rule: binary bytes (video/attachments) → object-storage/fs     │
│     (EZAGENT_HOME or S3); Postgres stores ONLY a URI ref + signed download  │
│     token. Blob NEVER inline in Postgres.                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│ LAYER 2 — Definition data           (Postgres ConfigObject; static/reusable) │
│   config-as-data: recipe, socialware-definition, responsibility role_name,  │
│   shape config, persona, adapters, visibility_policy.                       │
│   ► Business semantics LIVE HERE and ONLY here.                             │
├─────────────────────────────────────────────────────────────────────────────┤
│ LAYER 1 — Code plugin               (apps/ezagent_plugin_*; compiled in)     │
│   Behavior.Kanban etc. shape MECHANISM; Orchestrator.Tools; Surface render. │
│   NO business words. Generic, reusable.                                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 0.1 Layer 1 — Code plugin (`apps/ezagent_plugin_*`, compiled into release)

**Holds:** generic, reusable mechanism code — Behaviors that own a state slice
+ dispatchable actions providing a *general capability* (`Behavior.Surface`,
`Behavior.Pty`, `Behavior.Kanban` the board/task *mechanism*, `Behavior.Turn`
the conversation *mechanism*), tool catalogs (`Orchestrator.Tools`), adapter
plumbing, Template Classes. Each plugin is a separate OTP app compiled into the
release.

**Cannot hold:** business semantics. `Behavior.Kanban` is *intended* as the
generic board/task *mechanism* (nodes/stages/claims/status) — the *specific*
board definition (which columns a "sales pipeline" has) is layer-2 data, not
layer-1 code. A plugin may ship **seed definitions** (layer-2 data) alongside
its code, but the code itself stays generic. **Known current violation (flagged
by codex):** the landed `Behavior.Kanban` is NOT yet purely generic — it
hardcodes a 9-stage product chain at `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex:37-38`
(`@stages [:positioning, :metric, :pain, :anchor, :ux, :feature, :issue, :test, :pr]`)
+ validates that chain at `:415-443`, and the world UI duplicates `@stages` at
`apps/ezagent_plugin_world/lib/ezagent/world/kanban_data.ex:33`. The target is
to move stage/CI labels to layer-2 definition data; today they are layer-1
code, so kanban is a **partial leak** (anti-pattern 4.1 is "Kind-fixed" but the
plugin still carries business semantics in code).

**Current state:** plugins are compile-time umbrella apps (`apps/ezagent_plugin_*`
in `mix.exs`). There is no upload-and-install concept yet — see §2 (Q1).

### 0.2 Layer 2 — Definition data (Postgres `ConfigObject`; static/reusable config-as-data)

**Holds:** config-as-data — the **reusable, forkable, content-addressed
definitions** that carry business semantics. Concretely:

- **Recipe** (axis A) — `Ezagent.Agent.Recipe` stored as a `ConfigObject`:
  `subject_uri = config://<ws>/recipe/<name>`, `key = "recipe"`, body = the
  recipe map. Verified: `apps/ezagent_domain_agent/lib/ezagent/agent/recipe_registry.ex:8-9`
  (`"stored UNIFORMLY as a ConfigObject: subject_uri = config://<ws>/recipe/<name>,
  key = \"recipe\""`). The recipe carries team/persona/tool-catalog/prompt —
  **business semantics live here**.
- **Socialware definition** — `Ezagent.Socialware.DefinitionRegistry`, stored at
  `config://<ws>/socialware/<name>`, `key = "socialware"`. Verified:
  `apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex:6-7`
  (`"Definitions live at config://<workspace>/socialware/<name> with ConfigObject
  key \"socialware\""`). Carries bases/shape/members/routing_rules/adapters/
  visibility_policy — **business shape lives here**.
- **Responsibility `role_name`** (axis B) — the responsibility slot a member
  fills (`bot`/`reviewer`/`orchestrator`/`supervisor`), routed via `{:role, name}`.
  The assignment is data on the membership/socialware definition, not code.
- **Shape config** — which Behaviors a socialware mounts, which adapters, which
  visibility policy.

**Cannot hold:** runtime instance state (that is layer 3); executable code (that
is layer 1). A definition is *data* — editing it mints a new content-addressed
version, it does not mutate a running instance.

**This is the ONLY layer where business words may appear.** "autoservice",
"customer-service persona", "sales pipeline board config" belong here as
*data values*, never as layer-1 module names or layer-3 state schemas.

### 0.3 Layer 3 — Runtime state data (Postgres `kind_snapshots` slice + blob store)

**Holds:** the **per-agent/per-session DYNAMIC instance state** — the live slice.
Kanban task list contents, conversation messages, turn state, membership, board
node positions, settlement state. This is the `kind_snapshots` table's
per-instance slice, rehydrated on restart. Verified substrate:
`apps/ezagent_core/lib/ezagent/behavior/kind_base.ex` (`:kind_base` slice),
`apps/ezagent_core/lib/ezagent/message_store.ex` (messages + settlement),
`apps/ezagent_core/lib/ezagent/kind/snapshot.ex`.

**Cannot hold:** reusable definitions (a recipe is not duplicated per instance —
it is referenced by URI from layer 2); business semantics in schema form (the
schema is generic — `kind_snapshots` is one table for all Kinds; a kanban task
is a slice value, not a `kanban_tasks` table).

**Blob sub-rule (red line).** Binary blobs (video, attachments, generated
assets) NEVER go inline in Postgres. Bytes live on the host filesystem
(`EZAGENT_HOME/uploads/<ws>/<name>`) or S3-compatible object storage; Postgres
stores ONLY a `resource://<ws>/uploads/<name>` URI ref + a MAC-signed
`DownloadToken` (S3-presigned-URL style). Verified:
`apps/ezagent_core/lib/ezagent/uploads.ex:3-11` (`"Attachments are addressed as
resource://<ws>/uploads/<name> ... their bytes live at Home.path(\"uploads\")/
<ws>/<name>"`) + `apps/ezagent_core/lib/ezagent/uploads/download_token.ex:3-7`
(`"S3-presigned-URL style: a MAC-signed bearer token"`). Consumers mint a token
for the stored URI, never for bytes (`conversation_data.ex:341`).

### 0.4 Layer 4 — EZAGENT_HOME files (host-side runtime files)

**Holds:** host-OS-owned files the BEAM reads/writes but does not treat as typed
queryable state: credentials (`auth.json`, api keys), the
`kanban-boards.json` workspace→board mapping, logs, PTY pid-files
(`<EZAGENT_HOME>/<profile>/pty-pids/...`), and **upload bytes** (the blob
sub-rule's physical home). Verified: `Ezagent.Home` (`apps/ezagent_core/lib/ezagent/home.ex`)
+ `Ezagent.Runtime.PidFile` (Decision #127).

**Cannot hold:** Postgres-quality state (no transactions, no snapshot
rehydration); business definitions (a cred file is a secret, not a recipe);
code. A mapping file here (e.g. `kanban-boards.json`) is a **cache/index**, not
authority — authority for board state is the layer-3 slice.

---

## 1. Concept definitions (aligned with GLOSSARY)

These definitions extend the existing `docs/socialware-concepts.md` and are
**proposed additions to `GLOSSARY.md` §2** (see §7 for the delta list). Where a
term already has a GLOSSARY entry, this SPEC uses that meaning; where it does
not, the entry below is the proposed glossary text.

- **Base (基座, plural).** A capability substrate — a Behavior owning a
  persistent state slice + dispatchable actions providing a *general,
  reusable* capability. A base is composed INTO one or more socialwares; it is
  NOT directly user-operable. Verified bases (all `defmodule`-confirmed on
  `origin/main`): **orchestrator** (the existing combo — `Behavior.Template`
  recipe content + `Orchestrator.Tools` + `SessionManager`; no new Behavior,
  per lead decision OQ-1=(a)), **surface** (`Ezagent.Behavior.Surface`,
  `apps/ezagent_plugin_hello` contributes the page-builder that runs *on* it),
  **pty** (`Ezagent.Behavior.Pty`), **sandbox** (`Ezagent.Behavior.Sandbox`),
  **cc-headless-agent** (`Ezagent.Behavior.CcHeadlessAgent`). *Proposed GLOSSARY
  addition — no existing entry.*

- **Socialware.** A human+program hybrid FLOW that composes ≥1 base + a shape
  and is directly user-operable. Two verified instances: **chat** (world
  Conversation surface; generic, NO business semantics) and **kanban** (board
  WITH task semantics; the semantics are layer-2 data, the mechanism is
  `Behavior.Kanban` layer-1 code). *Proposed GLOSSARY addition — no existing
  entry; the word "socialware" appears in GLOSSARY only inside Decision #122
  (ExternalMirror) prose, not as a defined term.*

- **Fixture.** A seeded instance/use of a socialware for a specific business.
  **A fixture is NOT a concept and must NOT enter the concept/schema layer.**
  `autoservice` = chat configured for the customer-service business (project
  name only). *Proposed GLOSSARY addition — no existing entry.*

- **Recipe (axis A).** The flavor-agnostic sandbox-content recipe — the
  config-as-data a role runs. Module `Ezagent.Agent.Recipe`
  (`apps/ezagent_core/lib/ezagent/agent/recipe.ex:1`), stored as a ConfigObject
  at `config://<ws>/recipe/<name>`, key `"recipe"`, resolved read-through by
  `Ezagent.Agent.RecipeRegistry` (`recipe_registry.ex:1`). *Proposed GLOSSARY
  addition — GLOSSARY has no "Recipe" entry; the rename `Ezagent.Role →
  Ezagent.Agent.Recipe` landed in #1071 but GLOSSARY still references the old
  `Role` vocabulary in Decision #153 prose.*

- **Responsibility (axis B; `role_name`).** The responsibility slot a team
  member fills (`bot`/`reviewer`/`orchestrator`/`supervisor`), routed via
  `{:role, name}`. The **word "role" stays ONLY in this responsibility sense**
  — `role_name` is the responsibility identifier; the recipe is the *content*
  that role runs (looked up by `lookup_role_recipe/1`,
  `apps/ezagent_domain_workspace/.../role_step.ex:209`). The lingering helper
  name `lookup_role_recipe` is "look up the recipe for this role name" —
  consistent, but a future cleanup could rename to `lookup_recipe_for_responsibility`
  to remove even the surface-level overlap. *Proposed GLOSSARY addition — no
  "Responsibility" entry; "role" is not in the §3 disambiguation table.*

- **Definition (config-as-data).** A layer-2 ConfigObject — a reusable,
  forkable, content-addressed config bundle (recipe or socialware definition).
  Addressed `config://<ws>/{recipe|socialware}/<name>`. NOT a Kind URI (one of
  the 6 Kind schemes `entity session template resource workspace system`,
  `plugin.ex:88,263-268`); `config://` is a ConfigStore-internal opaque subject.

- **Runtime state (slice).** A layer-3 per-instance dynamic slice of a Kind's
  Behavior state, persisted in `kind_snapshots`, rehydrated on restart. The
  live, mutable, instance-specific state.

- **Blob.** A binary artifact (video/attachment/generated asset) whose bytes
  live in layer 4 (fs/object-storage) and whose Postgres representation is a
  URI ref + signed `DownloadToken` only. Never inline in Postgres.

- **Shape.** The flow-specific behavior(s) + recipe that make composed bases
  into a *particular* flow. chat's shape = `Behavior.Turn` (conversation turn
  protocol — specific to conversation, so a shape, not a base). kanban's shape
  = `Behavior.Kanban` (board/task protocol). A base is general; a shape is
  flow-specific. *From `socialware-concepts.md` "Shape" section.*

- **Install.** The relation "session S has socialware W installed" = (a) a
  per-install `ConfigObject` record (`subject = session_uri`, `key =
  "install:" <> socialware-ref`) + (b) the socialware's bases+shape mounted
  into the session's `:kind_base` union via the declaration-free mount path.
  *From the socialware-unification SPEC §2.4; substrate landed
  (`Ezagent.Socialware.DefinitionRegistry`).*

---

## 2. Q1 — Plugin-package target form vs current state (open)

**The lead's ask:** a developer's deliverable should be a **plugin package** — a
manifest + code + assets + seed definitions, installable as a unit. The SPEC
records this as the **target form**.

**Current state (verified on `origin/main`):** a plugin is a **compile-time
umbrella app** — `apps/ezagent_plugin_*` listed in the umbrella `mix.exs`,
compiled into the release at build time. There is **no upload-and-install
concept**: adding a plugin means adding an app to the umbrella, recompiling, and
restarting the release. A plugin *does* ship seed definitions alongside its
code (e.g. `ezagent_plugin_kanban/application.ex:64` `def roles, do:
[kanban_manager_recipe()]` seeds a layer-2 recipe at boot), but the "package"
boundary is the OTP app + its `mix.exs`, not an installable bundle.

**The gap:** the target form (upload-and-install / hot-load) does not exist.
The current form (compile-time app) cannot accept a plugin package at runtime.

**Open question (NOT decided by this SPEC).** Whether to build upload-and-
hot-load now vs restart-to-load is **the lead's separate brainstorm** — this
SPEC only records the target form + the gap and defers the load-mechanism
decision. The red lines in §5 hold **regardless** of which load mechanism is
chosen: a plugin package's code stays generic (layer 1), its seed definitions
are data (layer 2), and business words never enter core.

---

## 3. Judgment rule — "new thing goes in which layer?"

A decision flowchart. Walk it top-down; the first match wins.

```
1. Is it a BINARY BLOB (video/attachment/generated asset bytes)?
   → Layer 4 (fs/object-storage) for bytes; Layer 3 for the URI ref + token.
     NEVER inline in Postgres. (Blob sub-rule.)

2. Is it RUNTIME INSTANCE STATE — the live, per-agent/per-session, mutable
   value of a Behavior slice (kanban task list contents, messages, turn state,
   membership, board node positions)?
   → Layer 3 (kind_snapshots slice).

3. Is it a REUSABLE, FORKABLE, CONTENT-ADDRESSED DEFINITION carrying business
   semantics — a recipe (team/persona/tools), a socialware definition
   (bases/shape/adapters/visibility), a responsibility assignment?
   → Layer 2 (ConfigObject; config://<ws>/{recipe|socialware}/<name>).

4. Is it a HOST-OS FILE the BEAM reads/writes but does not treat as typed
   queryable state — a credential, a pid-file, a log, an index/mapping cache,
   upload bytes?
   → Layer 4 (EZAGENT_HOME).

5. Is it GENERIC, REUSABLE MECHANISM CODE with ZERO business semantics — a
   Behavior providing a general capability, a tool catalog, an adapter, a
   Template Class?
   → Layer 1 (apps/ezagent_plugin_* code; or apps/ezagent_domain_* for
     load-bearing vocabulary; or apps/ezagent_core for primitives — per the
     three-tier rules in references/three-tier-structure.md).

6. NONE of the above — is it a specific business instantiation (a configured
   instance of a socialware for a real customer, e.g. "the autoservice for
   Acme Corp")?
   → It is a FIXTURE: a layer-2 definition (seed) + a layer-3 running instance.
     It is NOT a new concept and must NOT enter layer 1 or the schema.
```

**Ambiguity guard.** A compound deliverable decomposes first: code, seed
definition, running instance, and bytes are **separate artifacts** each with
their own layer home. A plugin package is layer-1 code + layer-2 seed
definitions; a fixture is a layer-2 seed + a layer-3 running instance; a blob
is layer-4 bytes + a layer-3 URI ref. "Every artifact has exactly one home"
applies to each **atomic** artifact after decomposition — not to the compound
deliverable as a whole. Within an atomic artifact: for reusable/business
semantics, choose layer 2 (data) over layer 1 (code); for mutable per-instance
values, choose layer 3 (slice) over layer 2 (definition); for blob bytes, rule
1 always splits bytes to layer 4 and the URI/token to layer 3 (never inline in
Postgres).

**Unambiguous landing.** The two historically-ambiguous cases are settled:
(a) a kanban board definition (which stages/columns) is layer-2 data, not
layer-1 code — the mechanism (`Behavior.Kanban`) is layer-1, the instance task
list is layer-3; (b) a persona/prompt is layer-2 recipe data, not layer-1
code. (Note: the *landed* `Behavior.Kanban` currently hardcodes stages in
layer-1 code — §4.1 partial leak — but the target model is layer-2 data.)

---

## 4. Anti-patterns — verified against `origin/main`

Each anti-pattern is verified against current code with a verdict:
**FIXED** / **VIOLATED** / **RISK** / **NOT-PRESENT**.

### 4.1 Kanban-as-new-Kind — **FIXED (Kind); PARTIAL LEAK (business semantics in code)**

**Claim:** kanban is NOT a standalone Kind; it is a `Behavior` mounted on a
generic `Entity.Agent` via a role recipe.

**Verified (Kind-fixed):** `Ezagent.Behavior.Kanban` is a Behavior at
`apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`. It is mounted via
a role recipe: `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:78`
— `behaviors: [Ezagent.Behavior.Kanban]`, `:77` `passive: true`, `:64`
`def roles, do: [kanban_manager_recipe()]`. There is **no**
`defmodule Ezagent.Entity.Kanban` (grep empty). The standalone Kanban Kind
(K5) was deleted; kanban rides the generic Agent host. **FIXED (Kind axis).**

**Partial leak (codex finding):** the landed `Behavior.Kanban` is NOT purely
generic mechanism — it hardcodes a 9-stage product-development chain
(`@stages [:positioning, :metric, :pain, :anchor, :ux, :feature, :issue, :test, :pr]`,
`kanban.ex:37-38`) + a `stage_fits?` ordering validator (`:415-443`), and the
world UI duplicates `@stages` (`kanban_data.ex:33`). These stage names are
business semantics that belong in layer-2 definition data, not layer-1 code.
**Verdict: FIXED for the Kind axis; PARTIAL LEAK for the business-semantics-in-
code axis.** The target (move stages to layer-2 data) is open; see §5 red line 2.

### 4.2 hello → salesperson (business role in the Surface base) — **NOT-PRESENT**

**Claim:** the hello base has no business-role leak.

**Verified:** `grep -rni "salesperson|customer_service|customer-service|customer_service_flow|sales_rep"`
over `apps/ezagent_plugin_hello`, `apps/ezagent_core`, `apps/ezagent_domain_agent`
→ **zero hits**. The hello plugin contributes the page-builder
(`HelloBuilder` + `TurnDriver`) that runs *on* the generic `Behavior.Surface`
base; it carries no salesperson/customer-service business role. **NOT-PRESENT
(claim holds).**

### 4.3 autoservice → business-logic code — **FIXED**

**Claim:** autoservice is a fixture/seed, not business-logic code.

**Verified:** there is **no** `defmodule.*Autoservice` in `apps/` (grep empty).
`autoservice_tier1_seed.exs` is a pure-module seed script at
`scripts/autoservice_tier1_seed.exs:36` (self-described at `:8-15`: "a PURE
MODULE (no top-level side effects) so it can be loaded by BOTH the live
in-node serve-seed AND the deterministic regression test"). On `main`,
autoservice is **data** — a `soul_md` markdown body projected verbatim by the
generic `Ezagent.Socialware.ConfigProjection.render_soul/1`
(`apps/ezagent_domain_identity/lib/ezagent/socialware/config_projection.ex:217-221`:
"An autoservice cinnox soul is one authored markdown document; emit it verbatim
as CLAUDE.md"). autoservice adds no new concept and no business-logic module.
**FIXED.**

### 4.4 Business words in core — **RISK (partial; red line needs refining)**

**Claim:** core has NO business words.

**Verified:** `grep` over `apps/ezagent_core/lib/` **production modules** for
`kanban`, `board`, `sales`, `autoservice` → the words DO appear in
**comment-level references** (not business-logic code): e.g.
`apps/ezagent_core/lib/ezagent/plugin/role_seed_hook.ex:16` ("Every plugin that
declares `roles/0` (cc, py, kanban, kb)…"), `apps/ezagent_core/lib/ezagent/agent/recipe.ex:137`,
`apps/ezagent_core/lib/ezagent/behavior/sandbox.ex:57-58` (kanban-manager class
mention), `apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex:335-340`. There
are **no** `defmodule`-level business concepts in core (no `Ezagent.Kanban`,
no `Ezagent.Sales`), but the comment-level mentions are real and need either an
allowlist or a cleanup. The visibility type itself was renamed:
`:external_visible | :internal` (`message.ex:20,39,73,118-120`), so
`:customer_visible`/`:operator_only` are gone from code (migration
`20260628001000_rename_operator_only_visibility_to_internal.exs`).

- `socialware` appears in core — as the **substrate name** (table names like
  `socialware_settlement_messages`, `message_store.ex:195`; comments in
  `kind_base.ex`, `kind_base_backfill.ex`). This is legitimate: core hosts the
  durable settlement/message tables for the socialware substrate, and
  `Ezagent.Socialware.*` modules live in `domain_socialware`/`domain_identity`,
  not core (no `defmodule Ezagent.Socialware` in core — grep empty).
- `customer` appears in core **only in comments now** (`customer feed`,
  `customer-delivery`).

**Verdict: RISK.** The SPEC's literal claim ("no business words in core") is
too strong — comment-level `kanban` mentions exist. The **refined red line**
(§5): core production modules may not OWN business-app concepts (no
`defmodule Ezagent.Kanban`, no sales/customer-service logic), but
comment-level references naming downstream plugins (e.g. "kanban plugin
declares roles/0") are legitimate cross-layer documentation and need an
allowlist, not a ban. The NP-2 layer-vocabulary lint (§6) already enforces
module-NAME hygiene; the residual risk is comment/table-name level, not
code-level. Recommend scrubbing the lingering `customer` comments in core to
`external`/`audience` for consistency with the visibility rename, and adding
the comment-level `kanban` mentions to the NP-2 allowlist (or a separate
content-grep allowlist per §6.1).

### 4.5 Blob inline in Postgres — **FIXED (code); STALE-DOC (ARCHITECTURE §10.5)**

**Claim:** blobs are NOT inline in Postgres; Postgres stores only a URI ref +
signed token.

**Verified (code):** `Ezagent.Uploads` (`apps/ezagent_core/lib/ezagent/uploads.ex:3-11`)
+ `Ezagent.Uploads.DownloadToken` (`download_token.ex:3-7`, "S3-presigned-URL
style") + `Ezagent.Resource.FsResolver` (`resource/fs_resolver.ex`). Bytes live
at `Home.path("uploads")/<ws>/<name>` (disk); Postgres holds the
`resource://<ws>/uploads/<name>` URI ref. Consumers mint a token for the URI,
not bytes (`conversation_data.ex:259`). **FIXED in code.**

**STALE DOC:** `ARCHITECTURE.md` §10.5 ("G — 文件附件") documents a design where
`<10MB → SQLite BLOB` in an `attachments` table with a `data BLOB` column
(`ARCHITECTURE.md:1889-1927`). That design was **never the landed
implementation** (or was superseded): the landed code stores bytes on disk
regardless of size and keeps only a URI ref in Postgres. §10.5 is stale AND
describes a design that would **violate** the blob red line. See §7.

### 4.6 New-socialware-requires-core-edit (the "6th anti-pattern") — **FIXED**

**Claim:** adding a new socialware does NOT require editing `ezagent_core`.

**Verified:** a socialware definition is installed via ConfigStore data writes
at `config://<ws>/socialware/<name>`, resolved by
`Ezagent.Socialware.DefinitionRegistry`
(`apps/ezagent_domain_session/lib/ezagent/socialware/definition_registry.ex:1-7`)
+ `Ezagent.Socialware.ConfigStore`/`ConfigObject` (in `domain_identity`). Core
defines **no** `Ezagent.Socialware` module (grep `defmodule.*Socialware` over
`apps/ezagent_core/lib` → empty). Adding the autoservice socialware was a
`soul_md` data write (§4.3), not a core edit. **FIXED.**

### 4.7 Recipe (axis A) vs responsibility (axis B) — **LANDED (with helper-naming residue)**

**Claim:** recipe is axis A (`Ezagent.Agent.Recipe`, key `"recipe"`,
`config://<ws>/recipe/<name>`); responsibility is axis B (`role_name` +
`{:role, name}` routing); the word "role" stays only in the responsibility sense.

**Verified:** `Ezagent.Agent.Recipe` exists (`apps/ezagent_core/lib/ezagent/agent/recipe.ex:1`)
+ `Ezagent.Agent.RecipeRegistry` (`recipe_registry.ex:1`, key `"recipe"`,
subject `config://<ws>/recipe/<name>` — the rename landed in #1071).
Responsibility routing uses `{:role, name}` (`receiver.ex:11,15`;
`resolver.ex:397`). `role_name` is the responsibility identifier on membership
(`agent.ex:379-382`, `role_name_conflict/3`). The word "role" still appears in
recipe-lookup helpers (`lookup_role_recipe/1`, `list_by_role/2`) because the
recipe is keyed by the responsibility role-name — **consistent** (role =
responsibility name; recipe = content) but a future cleanup could rename the
helpers. **LANDED; the symbol-level split is done.**

---

## 5. Red lines (the anti-leak rules)

1. **Business concepts → layer 2 (definition DATA) ONLY.** Salesperson,
   customer-service-flow, board-semantics, specific persona/prompt, autoservice
   — these live as *data values* in ConfigObjects. NEVER in layer-1 code, never
   in base/core/agent modules, never in layer-3 schema.

2. **Business mechanism ≠ business semantics.** If a business concept needs a
   code mechanism, the *mechanism* is a layer-1 plugin (like `Behavior.Kanban`
   the board/task mechanism), but its business *semantics* (which columns, which
   stages) are layer-2 data. Only the generic mechanism is code.

3. **Adding a new socialware must NOT require editing `ezagent_core`.** A new
   socialware = a layer-2 definition + (optionally) a layer-1 plugin for any
   novel mechanism. Core stays untouched. (Anti-pattern 4.6.)

4. **Blob NEVER inline in Postgres.** Bytes → layer 4 (fs/object-storage);
   Postgres → URI ref + signed `DownloadToken` only. (Anti-pattern 4.5; the
   one design that violates this — ARCHITECTURE §10.5 — is stale doc, not
   landed code.)

5. **`socialware` is a substrate name, not a business concept.** Core may name
   the socialware substrate (its tables, its registry seam) but must not name
   business-app concepts. The NP-2 lint (§6) is the enforcement seam.

6. **A fixture is NOT a concept.** autoservice/loom/a named deployment is a
   configured instance (layer-2 seed + layer-3 instance), not a new layer-1
   type or schema. Do not add "autoservice" to the concept taxonomy or config
   schema.

---

## 6. Optional arch-gate ideas (enforce the red lines)

The codebase already has one enforcement seam; the proposals below extend it.

### 6.1 Existing gate — NP-2 layer-vocabulary lint (EXTEND)

`apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.lifecycle.ex:64-89`
already enforces: *"a module under `apps/ezagent_core/` must not name an
upper-layer composition concept"* (`@layer_vocab_words ~w(Agent Session
Orchestrator Workspace Worker Feishu Cc Codex Np Curl)`, with an allowlist of
legitimate registries/indexes). This **already catches** anti-pattern 4.4 at
the module-NAME level — e.g. a `defmodule Ezagent.Entity.Kanban` in core would
fail NP-2.

**Proposed extension (would catch more of 4.4):**
- Add business-app words to `@layer_vocab_words`: `Kanban`, `Board`, `Task`
  (kanban-task sense), `Sales`, `Customer`, `Autoservice`. (Currently absent —
  the lint would not flag a hypothetical `Ezagent.SalesPipeline` module in
  core.) This extends the **module-name** lint only.
- Add a **content-level** grep gate (NP-2 is name-level only — verified:
`@layer_vocab_words` scans `defmodule` names, not source lines) that fails if
  `apps/ezagent_core/lib/**/*.ex` source contains business-app words
  (`salesperson`, `customer_service`, `autoservice`, `board_config`) outside a
  **comment allowlist**. The allowlist is required because current core has
  legitimate comment-level references to downstream plugins (e.g. "kanban
  plugin declares roles/0" in `role_seed_hook.ex:16`, the `kanban-manager`
  class in `sandbox.ex:57-58` — see §4.4). This catches the lingering `customer`
  comments (§4.4) the name-level lint misses.

### 6.2 New-Kind gate (catch anti-pattern 4.1 regression)

A gate that fails if a new `defmodule Ezagent.Entity.<X>` (or
`Ezagent.Resource.<X>`) Kind is added outside the sanctioned domain apps
(`domain_session`, `domain_agent`, `domain_identity`, `domain_workspace`,
`domain_socialware`, `domain_external_mirror`) without an accompanying
invariant test justifying why the concept cannot ride a generic host. Kanban
riding `Entity.Agent` is the precedent; a new `Entity.Kanban` would fail this
gate. **Note (codex):** the existing resource-kind gate in
`ezagent.arch.scan.ex:335-352` catches `resource_kinds/0` +
`ResourceKindRegistry.register`, NOT a plain `defmodule Ezagent.Entity.Kanban`
— so the new gate needs an explicit `defmodule Ezagent.Entity.<X>` predicate;
the existing resource-kind gate alone is insufficient.

### 6.3 Blob-inline gate (catch anti-pattern 4.5 regression)

A gate that fails if any Ecto migration in `apps/**/priv/repo/migrations/`
introduces a `:binary`/`BLOB` column on an `attachments`/`uploads` table
intended to hold attachment bytes (column named `data`/`bytes`/`blob`/`content`).
**Scope note (codex):** the gate must NOT ban all `:binary` columns — legitimate
binary columns exist (`state_binary` in
`20260519000000_phase4_kind_snapshot_binary.exs:7-11`, token hashes in
`20260531000000_magic_link_tokens.exs:7-16`). Scope to attachment/upload tables
+ content-bearing column names only. The landed `uploads` store has no such
column (bytes are on disk); this gate makes the red line structural. Also:
assert `Ezagent.Uploads` is the sole upload chokepoint (grep for
`File.read!`/`File.write!` of attachment bytes outside `uploads.ex` +
`fs_resolver.ex`).

### 6.4 Plugin-package manifest gate (future, contingent on §2)

If/when the plugin-package target form (§2) lands, a gate that asserts every
plugin package's manifest separates `code` (layer 1) from `seed_definitions`
(layer 2 data) — a package cannot inline business definitions into code files.

**Would these catch the anti-patterns?** 6.1 → 4.4 (business words in core);
6.2 → 4.1 (kanban-as-Kind); 6.3 → 4.5 (blob inline); 4.2/4.3/4.6 are
structural-property anti-patterns (no business-role in hello, no autoservice
module, no core edit for new socialware) that 6.1's content-level grep +
6.2's new-Kind gate collectively cover.

---

## 7. Glossary deltas + architecture-doc staleness inventory

### 7.1 GLOSSARY.md deltas

`GLOSSARY.md` is the single source of truth for the Decision Log (§1), terms
(§2), and disambiguation (§3). It is **stale relative to the unified socialware
model**: the terms table has no entries for the socialware taxonomy, and the
Decision Log ends at #154 with no entry for the carrier-layer model.

**Terms (§2) MISSING — propose adding (text in §1 above):**
`Base`, `Socialware`, `Fixture`, `Recipe` (axis A), `Responsibility` (axis B;
`role_name`), `Definition` (config-as-data), `Runtime state` (slice), `Blob`,
`Shape`, `Install`.

**Terms (§2) STALE:**
- No entry mentions that `:customer_visible`/`:operator_only` was renamed to
  `:external_visible | :internal` (the `Message` entry should note this;
  verified: `apps/ezagent_core/lib/ezagent/message.ex:20,118-120`).
- No `Recipe` entry — the rename `Ezagent.Role → Ezagent.Agent.Recipe` (#1071)
  is not reflected. (Note: codex grep found no `Ezagent.Role` reference inside
  the GLOSSARY `Behavior` entry itself — the prior draft's "references old
  `Ezagent.Role` vocabulary" claim was inaccurate and is removed.)

**Decision Log (§1) STALE:**
- The Decision table reaches #154 (`GLOSSARY.md:165`) but the footer/status
  metadata still says `#87` (`GLOSSARY.md:1151-1152`) — the footer is stale and
  must be updated when new decisions land.

**Disambiguation (§3) MISSING — propose adding:**
- `base` (Ezagent capability substrate vs Elixir/Behaviour callback vs OO base-class).
- `socialware` (Ezagent human+program hybrid flow vs generic "software").
- `recipe` (Ezagent config-as-data recipe vs cooking/general usage).
- `role` / `responsibility` (Ezagent `role_name` responsibility slot vs Elixir
  `@behaviour` role vs generic auth "role").
- `fixture` (Ezagent seeded business instance vs ExUnit test fixture — **high
  collision risk**, must be disambiguated).
- `definition` (Ezagent ConfigObject vs generic "definition").

**Decision Log (§1) — propose adding #155:** "4-carrier-layer taxonomy +
anti-leak red lines" (this SPEC). Records: the 4 layers, the blob-never-inline
red line, the business-concepts-layer-2-only rule, and the carrier-layer axis
as orthogonal to the three code tiers.

**Recommendation:** do NOT edit GLOSSARY.md in this PR (it is owned across
Allen + engineers and a Decision Log entry deserves its own review). Flag the
deltas here; land them in a follow-up `docs(glossary): add socialware taxonomy
terms + #155` PR. This SPEC is the authority the follow-up references.

### 7.2 ARCHITECTURE.md staleness inventory

`ARCHITECTURE.md` is "Last updated 2026-05-15" — predates the socialware
unification (2026-06-26/28) and the recipe rename (#1071). Stale sections:

| Section | Staleness | What it needs |
|---|---|---|
| §1 项目定位 | Frames ezagent as "Event-Sourcing Router Kind Runtime"; no mention of base/socialware/fixture or the human+program hybrid flow model. | Add a paragraph (or cross-ref to `socialware-concepts.md` + this SPEC) framing ezagent as a socialware platform whose runtime is a router. |
| §3 核心抽象 | Lists Kind/Behavior/Plugin/Capability/Message. No base/socialware/fixture/recipe/responsibility abstractions. | Add cross-ref to §1 of this SPEC for the carrier-layer + concept taxonomy. |
| §9 Templates (双层模型) | Frames everything as Template Class/Instance. The socialware definition is **NOT** a Template Kind — it is an opaque `config://` ConfigStore subject (`definition_registry.ex:6-7`). §9's Template framing does not cover this. | Add a note: socialware definitions are ConfigStore data, not Template Kinds; cross-ref socialware-unification SPEC §2.3. |
| §10.5 文件附件 (G) | **STALE + red-line-violating-by-doc.** Documents `<10MB → SQLite BLOB` with an `attachments` table `data BLOB` column. The landed code (`Uploads` + `FsResolver` + `DownloadToken`) stores bytes on disk regardless of size; Postgres holds only a URI ref. | **Rewrite §10.5** to describe the landed Uploads/FsResolver/DownloadToken design + the blob-never-inline red line. The current text describes a design that would fail the §6.3 gate. |
| §10.6 Plugin runtime config | Describes plugin config via plugin-owned Ecto tables. Still accurate, but should cross-ref the layer-2 ConfigObject model (recipe/socialware definitions) which is the preferred config-as-data home for reusable definitions. | Minor cross-ref addition. |
| §10.4 F Message stream | Predates the `:external_visible | :internal` visibility rename (was `:customer_visible | :operator_only`). | Update visibility vocabulary. |

### 7.3 `references/three-tier-structure.md` staleness

`.claude/skills/ezagent-developer/references/three-tier-structure.md` (the
authoritative three-tier code model) is stale on app names and silent on the
socialware taxonomy:

- Lists `ezagent_domain_chat` — the actual app is `ezagent_domain_session`
  (chat Behavior moved; `Ezagent.World.ConversationActions` lives in
  `ezagent_plugin_world`).
- Lists `ezagent_plugin_liveview` — **removed** (invariant tests
  `lv_cli_parity_test.exs` enforce its absence); the operator console is now
  `ezagent_plugin_world`.
- Does not list `ezagent_domain_socialware`, `ezagent_domain_agent`,
`ezagent_domain_agent_bridge`, `ezagent_domain_pty`, `ezagent_domain_python`,
  `ezagent_plugin_kanban`, `ezagent_plugin_codex`, `ezagent_plugin_world`,
  `ezagent_plugin_advisor`, `ezagent_plugin_np`, `ezagent_plugin_protocol_api`,
  `ezagent_plugin_email`.
- No mention of base/socialware/fixture/recipe/responsibility; no mention of
  the 4-carrier-layer axis. The three tiers (core/domain/plugin) are the
  **code-dependency** axis; this SPEC's 4 carrier layers are the
  **artifact-kind** axis. The reference should state they are orthogonal and
  cross-reference this SPEC.

**Recommendation:** the three-tier reference + ARCHITECTURE sections are
flagged-for-follow-up, not rewritten in this PR. This SPEC enumerates the gap;
a separate `docs(architecture): align to socialware unification` PR should
land the rewrites referencing this SPEC.

---

## 8. Codex adversarial-review verdict

> *Static-only review (codex/gpt-5.5, no build/mix/tests) against the SPEC on
> the `docs/ezagent-taxonomy` branch. Verified all claims against the worktree
> at `3d3b98d` (off `origin/main` `c37f2008`).*

**NET: SOUND-WITH-FIXES — no UNSOUND overall.** The carrier taxonomy is
directionally sound and most staleness claims are real. One §3 internal
contradiction (Q2 UNSOUND) rewritten; §4.1/§4.4/§6 overclaims about how clean
current code is / how much existing gates cover corrected. All 8 fixes folded
before push.

| Q | Codex verdict | Disposition |
|---|---|---|
| 1 — 4-layer taxonomy + §4 anti-patterns code-accurate? | **SOUND-WITH-FIXES** — 4.1 Kind-fixed verified BUT landed `Behavior.Kanban` hardcodes 9-stage product chain (`kanban.ex:37-38,415-443` + `kanban_data.ex:33`); 4.3 wording (seed at `scripts/autoservice_tier1_seed.exs:36`, pure module `:8-15`); 4.4 "kanban/board/sales/autoservice empty" false for core comments (`role_seed_hook.ex:16`, `recipe.ex:137`, `sandbox.ex:57-58`, `arch.scan.ex:335-340`); 4.5/4.6/4.7 accurate. | **FOLDED** — §0.1 + §4.1 (partial-leak caveat), §4.3 (precise seed path), §4.4 (comment-level mentions + allowlist recommendation). |
| 2 — §3 judgment rule unambiguous? | **UNSOUND** — internal contradiction: "first match wins" vs "higher-numbered loses to lower" vs example "prefer layer 2 over layer 1"; "every artifact has exactly one home" contradicts "plugin ships layer-1 code + layer-2 seeds." | **FOLDED** — §3 ambiguity guard rewritten: decompose compound deliverables first; each atomic artifact has one home; choose data over code, slice over definition, split blob bytes from URI. |
| 3 — glossary-alignment correct? | **SOUND-WITH-FIXES** — GLOSSARY exists; missing terms verified; Decision table reaches #154 (`:165`) BUT footer/status stale says #87 (`:1151-1152`); the SPEC's "Behavior entry references old `Ezagent.Role`" claim is NOT supported by grep — removed. | **FOLDED** — §7.1 removed the inaccurate `Ezagent.Role`-in-Behavior-entry claim; added footer #87 staleness. |
| 4 — arch-doc-staleness inventory real? | **SOUND** — ARCH §10.5 inline-BLOB verified (`ARCHITECTURE.md:1897-1912`, `data BLOB` column); landed code = disk + URI + token (verified); three-tier ref stale on `ezagent_domain_chat` (`:28`) + `ezagent_plugin_liveview` (`:32,48`); current apps in `mix.exs:30-31,44`. | none. |
| 5 — red lines enforceable? | **SOUND-WITH-FIXES** — NP-2 is module-name only (verified `lifecycle.ex:64-69,310-338`); content grep needs allowlists; existing resource-kind gate (`arch.scan.ex:335-352`) catches `resource_kinds/0`/`ResourceKindRegistry.register`, NOT plain `defmodule Ezagent.Entity.Kanban`; blob-binary gate must NOT ban all `:binary` (legitimate `state_binary` `20260519000000_phase4_kind_snapshot_binary.exs:7-11` + token hashes `20260531000000_magic_link_tokens.exs:7-16`). | **FOLDED** — §6.1 (NP-2 name-only + allowlist), §6.2 (explicit defmodule predicate), §6.3 (scope to attachment/upload tables + content column names). |

**Codex fixes folded (8):** §0.1 + §4.1 partial-leak caveat (kanban hardcoded
stages); §4.3 precise seed path; §4.4 comment-level mentions + allowlist; §3
ambiguity guard rewrite (decompose-first); §7.1 removed inaccurate
`Ezagent.Role`-in-Behavior claim + added footer #87 staleness; §6.1 NP-2
name-only + allowlist; §6.2 explicit defmodule predicate; §6.3 scope binary
gate to attachment/upload tables. No new open questions.
