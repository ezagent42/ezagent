# Socialware Registry & Distribution Plan

**Type:** Research + design (NOT an implementation spec — each phase below earns its own later spec)
**Date:** 2026-07-04
**Author:** Claude Opus 4.8 (1M context), for Allen
**Status:** Draft for lead review

---

## 0. TL;DR — verdict on the lead's proposition

> **Lead's proposition:** "The platform itself should be the socialware **registry**. Flagship
> apps like the 官网 should in the FUTURE live as an **independent repo, seeded into prod at
> deploy time** — because their correct home is the **production runtime database (the
> registry)**; they're only in the code repo now because that registry-as-runtime-DB +
> config-repo + deploy-seed pipeline doesn't exist yet."

**Verdict: CONFIRMED in direction, with one load-bearing correction the plan is built around.**

The correction is the **code-vs-config split**, and it resolves into a precise rule rather than a
flat "flagships can't live in the DB":

> **A flagship = (its custom CODE → a plugin, stays in the code repo) + (its config manifest →
> a socialware Definition, lives in the registry).**
>
> - The **first** flagship of a new kind ships a **plugin** (new flavors, behaviors, views,
>   UI) — that code is irreducibly in the code repo.
> - Every **subsequent** flagship that only **recombines existing** flavors / views / behaviors
>   is **pure-config** and CAN live **entirely in the registry**. There the lead is exactly
>   right.

For **hello specifically the lead over-reaches**: hello was the first flagship of its kind
(#1168 introduced genuinely new code — see §2), so "hello entirely in the runtime DB" is not
achievable. For a **future 官网 that reuses hello's plugin** (its builder/concierge flavors +
`hello_render` view) and adds only config, the lead's "entirely in the registry" is **correct**.

The single **biggest missing piece** to call prod's ConfigStore a real *registry* (rather than a
per-node config table) is a **versioned, environment-independent, promotable artifact identity** —
"this published def in prod is *the same artifact* authored in dev." Storage, governance,
discovery, install, and the admin-gate already exist (§1). What's missing is the artifact identity
+ the transport (deploy-seed/promote) that moves it between environments. Details in §1.4 and §5.

---

## 1. Current-state assessment — is prod's ConfigStore already the registry?

**Largely YES for storage + governance + discovery + install; NO for artifact identity, promotion,
and browse.** Everything below is CONFIRMED in code with citations.

### 1.1 A socialware IS config-only (CONFIRMED)

`Ezagent.Socialware.Definition`
(`apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex`) is a pure config struct:
`name`, `version`, `title`, `description`, `uses`, `bases`, `shape`, `views`, `agents`, `assets`,
`members`, `routing_rules`, `prompt_templates`, `legends`, `orchestrator_template_uri`, `adapters`,
`visibility_policy`. Its `body/1` is a JSON-safe map for persistence. No behavior/code lives in a
Definition — only **references to code** (module names, flavor names, recipe names).

### 1.2 Publish → discover → install already exists (CONFIRMED)

- **Publish** — `Ezagent.Socialware.ConfigGovernance.Socialware`
  (`.../socialware/config_governance/socialware.ex`) is a change-request lifecycle:
  `open_cr → stage_definition → publish_cr` over the shared `ConfigChangeStore`. Public scope is
  **admin-gated**: `publish_cr/2 → authorize_public_scope/2 → authorize_admin/2`, which requires
  `Ezagent.Identity.AdminAuthority.admin?(caller, caps)`.
- **Store** — definitions persist in the per-workspace `ConfigStore` under the structured non-URI
  subject `socialware:<name>`, layer `"workspace"`, key `"socialware"`
  (`DefinitionRegistry.definition_subject_uri/2`, `.../config_store.ex`). Workspace is a **separate
  ConfigStore field**, not embedded in the subject.
- **Discover** — `DefinitionRegistry.list/1` returns installable defs visible to a caller
  workspace (own + system + any `scope: :public`), and `lookup/2` resolves with a caller →
  system → public fallback chain. `scope: :public` defs are cross-workspace discoverable from
  **every** workspace. This list is **already surfaced** in the world UI at
  `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex:704`.
- **Install** — `/sessions` create flow → `Ezagent.World.SocialwareInstall.prepare_create_template/4`
  (`apps/ezagent_plugin_world/lib/ezagent/world/socialware_install.ex`) validates the ref is
  installable, writes a **local install template** in the caller's workspace pointing at the def
  name, tags it `current`, and hands that template to the normal `session.create` path.
  Materialization of the def's `agents`/`members`/`routing_rules` happens via
  `Ezagent.Socialware.Installation.install_template_installs/4`
  (`.../socialware/installation.ex`).

### 1.3 The load-bearing invariant (CONFIRMED — this is the anchor for the whole plan)

> **A socialware config resolves ONLY in an environment where every code artifact it references is
> already deployed.**

This is mechanical, not a preference. `Definition.new/1` validates `bases`/`shape`/`views` through
`behavior_module/1`, which requires `Code.ensure_loaded?(mod)` and
`Ezagent.ActionSet.new_style?(mod)` (`definition.ex:194-200`); `views` go through the same check
(`definition.ex:67`). So a Definition referencing `hello_render` / the `hello` flavor / an `np`
recipe is **invalid** — it cannot even be rehydrated — in an environment where the hello plugin's
code is not loaded. **This is precisely why config → registry and code → repo is a necessity, not a
style choice**, and it is the CONFIRMED foundation of the code-vs-config split.

### 1.4 What is MISSING to call it a "registry"

| Capability | State | Evidence |
|---|---|---|
| Config storage + per-workspace scoping | **EXISTS** | ConfigStore subject `socialware:<name>` |
| Publish governance (CR lifecycle) | **EXISTS** | `ConfigGovernance.Socialware` |
| Admin gate on public scope | **EXISTS** | `authorize_admin/2` + `admin_genesis_cap` |
| Cross-workspace discovery of public defs | **EXISTS** | `DefinitionRegistry.list/1`, `lookup/2` fallback |
| Install into a session | **EXISTS** | `SocialwareInstall` + `Installation` |
| Basic list surfaced in UI | **EXISTS (thin)** | `world_live.ex:704` |
| **Versioned artifact identity** (a def has a stable identity across envs; pin-to-version on install) | **MISSING** | `Definition.version` is a free-form string; install always takes the `current` pointer (`SocialwareInstall`), never a pinned version |
| **Cross-ENVIRONMENT promotion** (author in dev → promote same artifact to prod) | **MISSING** | Each env's ConfigStore re-derives defs locally from in-code seeds (§3); nothing links a dev def to its prod copy |
| **External source-of-truth for first-party configs** | **MISSING** | First-party manifests live in **Elixir `lib`** (`Demo.Hello.manifest_attrs`, `DefinitionRegistry.builtin_definitions`) |
| **Unpublish / retract / def-level rollback** | **MISSING** | CR-level `reject`/`mark_rolled_back` exist in `ConfigChangeStore`; no def-level unpublish/retract |
| **Catalog browse/search/detail UI** | **MISSING (list only)** | Only the thin `list/1` dropdown exists |

**Assessment:** prod's ConfigStore **is already the registry's storage + governance + discovery +
install substrate**, under-surfaced. It is **not yet a registry** in the sense npm/docker are,
because it lacks the one property that distinguishes a registry from a runtime config table: a
**named, versioned, environment-independent artifact** that can be **promoted** between
environments. See §5.

---

## 2. The code-vs-config decomposition, verified against hello's actual code

**Claim being tested:** hello is NOT pure config — so "hello entirely in the runtime DB"
over-reaches.

**Verified. Hello's irreducibly-CODE artifacts** (all in `apps/ezagent_plugin_hello`, introduced by
#1168, must ship in the code repo as a plugin):

- **`agent_flavors/0`** — the `"hello"` flavor with `EzagentPluginHello.BridgeAdapter`, the
  in-process AgentBridge seam that routes chat into a hello role agent (`application.ex:96-106`).
- **`roles/0`** — `hello.orchestrator` / `hello.builder` / `hello.concierge`, each backed by a
  compiled behavior module: `Ezagent.ActionSet.HelloOrchestrator` / `HelloBuilder` / `HelloConcierge`
  (`application.ex:116-148`, behaviors under `apps/ezagent_plugin_hello/lib/ezagent/behavior/`).
- **`behaviors/0`** — registers the `{Session, :hello_render}` cap subject via
  `Ezagent.ActionSet.HelloRender` (`application.ex:164-173`).
- **`PageView`** — the `SessionView` that emits the `@json-render` island backed by the React UI at
  `/assets/hello/main.js` (`page_view.ex`, plus the JS bundle asset).
- Supporting code: `Template.HelloSession`, `Template.HelloAgent`, `TurnDriver`, `Generator`,
  `Spec`, `Prompts`, `Sanitize`.

**Hello's CONFIG artifact** (currently mis-located in Elixir `lib`):
`Ezagent.Socialware.Demo.Hello.manifest_attrs/1`
(`apps/ezagent_domain_session/lib/ezagent/socialware/demo/hello.ex`) — a plain map:
`name/version/title/uses/bases/shape/views/agents/prompt_templates/legends/routing_rules/visibility_policy`.
It is boot-published via the real governance flow at plugin start
(`application.ex:59 → maybe_publish_hello_demo → Demo.Hello.publish/0`), which dogfoods
`open_cr → stage → publish_cr`.

**The proof-of-concept for "pure-config flagship":** the demo manifest's `agents` uses
`recipe: "np"`, `flavor: "py"` — i.e. **not** hello's own orchestrator/builder roles. It is already
a **thin config veneer** over generic flavors, depending on the hello plugin only for `uses:
["hello"]` and `views: ["hello_render"]` (the render cap + PageView + JS island). This demonstrates
that once a plugin exists, further apps can be authored as **config only**. A real 官网 built on
hello's builder/concierge would be a *deeper* config-only reuse.

**Conclusion (the backbone of this plan):**

- **hello** = **plugin (code repo) + demo manifest (→ registry)**. The manifest is the only part
  that can move to a config repo/registry. Correct the lead: hello does **not** move entirely to
  the runtime DB.
- **官网 reusing hello's plugin** = **pure config → entirely in the registry**. Confirm the lead.
- The rule: **first flagship of a kind ships a plugin; subsequent recombinations are pure config.**

---

## 3. Current distribution is two parallel in-code seeds (the state to migrate FROM)

There are **two** in-code publish/seed paths today — both source manifests from Elixir, and they
have **different idempotency semantics** (a correctness trap the target pipeline must fix):

1. **`DefinitionRegistry.seed_builtin_definitions/0`** — seeds the built-in `chat` + `socialware`
   defs from `builtin_definitions/0` (in-code), called at boot
   (`apps/ezagent_domain_session/lib/ezagent_domain_instance_message/application.ex:160`).
   **Idempotent-on-CONTENT**: `seed_builtin_definition/2` re-applies an edited manifest on redeploy
   via a sha256 content hash (`builtin_upgrade_source_turn_id`, `definition_registry.ex:328-337`).
2. **`Demo.Hello.publish/0`** — publishes the hello demo from `Demo.Hello.manifest_attrs` at plugin
   boot (`hello/application.ex:59`). **Idempotent-on-EXISTENCE**: `already_public?/1` early-returns
   `{:ok, :exists}` (`demo/hello.ex:131,169-174`) — so **an edited hello manifest is NOT re-applied
   on redeploy**.

**Implication for the target pipeline:** a unified deploy-seed must adopt the **content-hash-upgrade**
semantics (path 1), not the existence-check semantics (path 2), or first-party manifest edits will
silently fail to promote.

---

## 4. Part 2 — unify the flagship's install path

### 4.1 The two session-creation paths that must converge

1. **Bespoke `:hello` URI-type path** — `EzagentPluginHello.App.ensure_app/3`
   (`app.ex`) mints `session://<ws>/hello/<name>`, **seeds its own `hello-<name>` definition inline**
   (`seed_hello_definition`), spawns the Session with `owner_uri: User.admin_uri()`, installs the
   template, and auto-joins an orchestrator (`ensure_orchestrator`). The homesite/demo uses this
   path (`mix ezagent.demo.seed_hello`, `HELLO_DEMO_SEED`).
2. **Socialware-install path** — `/sessions` → `SocialwareInstall.prepare_create_template/4` →
   local install template → normal `session.create` → `Installation.install_template_installs/4`.

The bridge between them today is the `OR` at
`apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/page_view.ex:52`:
```elixir
Ezagent.URI.type?(session_uri, :hello) or manifest_installed_hello?(session_uri)
```
i.e. the PageView applies to a session that is *either* a bespoke `:hello`-typed session *or* one
that installed the hello manifest. That `OR` is the smell: **two ways to be a hello session.**

### 4.2 Target: one path — the homesite creates its session BY installing the hello socialware

The homesite/官网 creates its public session by **installing the hello socialware Definition from
the registry** — the same path a user's `/sessions` install takes. Then:

- Retire the bespoke `:hello` URI-type creation (`App.ensure_app`'s inline `seed_hello_definition`
  + direct spawn).
- `PageView.applies_to?` drops the `Ezagent.URI.type?(:hello)` branch and keys purely on
  `manifest_installed_hello?` (installed-def evidence). One way to be a hello session.
- The flagship then **fully dogfoods** the registry it ships.

### 4.3 Every bespoke session-creation path to converge

- `EzagentPluginHello.App.ensure_app/3` (the `:hello` URI-type creator + inline def seed).
- `mix ezagent.demo.seed_hello` and the `HELLO_DEMO_SEED`/`HELLO_DEMO_*` boot task in
  `hello/application.ex:221-294`.
- `EzagentPluginHello.Migrate` (the `HELLO_MIGRATE_ORCHESTRATOR` back-fill) — becomes moot once
  there is one creation path.

### 4.4 The discriminating risk — does the Definition schema express a full homesite?

`App.ensure_app` does three things a Definition install may not reproduce:
`owner_uri: User.admin_uri()`, orchestrator **auto-join** (`ensure_orchestrator`), and working-copy
set. The Definition schema **already carries** `agents`, `members`, `orchestrator_template_uri`, and
`routing_rules` — so agent materialization and orchestrator wiring are **plausibly** expressible.
**But there is no `owner` field on `Definition`** — and an anonymous public homesite needs a
designated owner (today hard-coded to `User.admin_uri()`), or every visitor message falls to the
concierge (per the `App.ensure_app` comment).

**This is the tie-breaker between "Part 2 is wiring" and "Part 2 needs a schema extension":**
- If installing a Definition carrying `orchestrator_template_uri` + `members` + an owner policy
  reproduces `App.ensure_app`'s owner + orchestrator auto-join → **Part 2 is wiring only.**
- If not → **Part 2 depends on a `Definition` owner/orchestrator-policy schema extension that
  belongs in Part 1 (registry-schema work).** (PROPOSED — see open question O-1.)

### 4.5 Other risks

- **Anon-visitor flow** — the homesite relies on `public_view` + `ExternalFeed` + anon-User minting
  (`ezagent_domain_socialware/.../anon_*`). The install path must preserve `web_anon_access: true`
  and the anon admission chain. The demo manifest already sets `web_anon_access: true`, so this is
  likely preserved, but must be an E2E gate.
- **Homesite UX / trigger** — a homesite is a **singleton, headless, public** page, not a
  user-initiated `/sessions` install. The unified path needs a **headless/idempotent install
  trigger** (a deploy step or a first-visit bootstrap) that installs the def without a logged-in
  installer.
- **Performance** — the install path does template write + tag + resolve per creation vs the
  `App.ensure_app` direct spawn. For a singleton homesite this is once-per-deploy, so negligible;
  worth a note only if homesites become per-tenant.

---

## 5. Part 3 — flagship as independent config source + deploy-seed pipeline

### 5.1 Two distribution channels (make this explicit)

| Channel | Artifact | Home | Deployment |
|---|---|---|---|
| **Code** | Plugin (flavors, behaviors, views, UI) | Code repo (compiled app under `apps/`, or its own repo — O-2) | Release-deployed (compiled into the BEAM release) |
| **Config** | Socialware `Definition` manifest | **Config source-of-truth** (git repo / config tree) → **registry (ConfigStore)** | Registry-seeded at deploy via governance flow |

The lead's "independent repo, seeded at deploy" maps cleanly onto the **config** channel. The
**code** channel is unaffected — plugins keep shipping in the release.

### 5.2 Target design

1. **First-party socialware CONFIGS move out of Elixir `lib` into an external source-of-truth** — a
   git repo (or a versioned `config/socialware/*.json` tree) of manifest documents. This replaces
   `Demo.Hello.manifest_attrs` and `DefinitionRegistry.builtin_definitions` as the *authoring*
   home. The manifests are the **same shape** `ManifestResolver.resolve/1` already consumes.
2. **A deploy-time seed/promote pipeline** — a mix task
   (e.g. `mix ezagent.socialware.publish --from <dir>`) reads each manifest and publishes it via the
   **existing** `ConfigGovernance.Socialware` flow (`open_cr → stage → publish_cr`) with the
   bootstrap-admin authority — **generalizing the two in-code seeds of §3 into one external-sourced
   pipeline.** It MUST use the **content-hash-upgrade** idempotency (§3 path 1) so edited manifests
   promote, and be **per-env** (runs against each environment's ConfigStore/DB at that env's
   deploy).
3. **Versioned, promotable artifact identity** (the biggest missing piece) — a published def gets a
   stable identity `(name, version, content-hash)` so "this def in prod is the same artifact
   authored in dev" is *checkable*, and installs can optionally **pin** a version instead of always
   taking `current`. Promotion dev→prod = publish the *same* artifact bytes to prod's registry (via
   the pipeline or an export/import), not re-derive from code.
4. **Coexistence with third-party socialwares** — third-party socialwares are **UI/API-authored →
   published**, never in any repo. They already flow through `ConfigGovernance.Socialware` from a
   workspace. Both first-party (deploy-seeded) and third-party (UI-authored) land in the **same**
   registry; the only difference is the *authoring surface* and the *authority* (first-party =
   deploy admin; third-party = workspace owner, public scope still admin-gated).
5. **Code-vs-config split for hello** — hello's flavor/behaviors/PageView/React-UI **stay** in
   `ezagent_plugin_hello` (code repo, release-deployed). `Demo.Hello.manifest_attrs` **moves** to
   the config source-of-truth and is published by the deploy-seed pipeline. The in-code
   `Demo.Hello.publish/0` boot-publish is the **transitional state to migrate FROM** — delete it
   once the pipeline owns publishing.

### 5.3 Ordering constraint (from the §1.3 invariant)

Because a manifest only *resolves* where its referenced code is loaded, the deploy-seed of a
first-party config MUST run **after** the plugin providing its `uses`/`views` is booted — exactly
the ordering `hello/application.ex:50-59` documents today (publish in the hello plugin's `start/2`,
after its PageView + `hello_render` cap are registered). The pipeline preserves this: **seed
first-party configs after the release's plugins have registered**, or fail loud.

---

## 6. Proposed phase breakdown (each earns its own later spec)

Ordered by dependency. **P0/P1 are the registry primitive; P2 is dogfooding; P3 is distribution.**

- **P0 — Registry hardening: versioned promotable artifact identity.**
  Give a published Definition a stable `(name, version, content-hash)` identity; add version
  listing and **pin-to-version** on install (`SocialwareInstall` currently always takes `current`).
  Add def-level **unpublish/retract** (today only CR-level `reject`/`mark_rolled_back` exist). This
  is the primitive that turns the config table into a registry. *(Depends on: nothing.)*

- **P1 — Registry surface: catalog browse/search/detail UI + API.**
  Promote the thin `list/1` dropdown (`world_live.ex:704`) into a real catalog: search, detail
  view, version history, install-from-catalog. Secondary/surfacing — depends on P0's version model.
  *(Depends on: P0.)*

- **P2 — Unify the flagship install path (Part 2).**
  Retire the bespoke `:hello` URI-type creation; the homesite creates its session by installing the
  hello Definition; drop the `URI.type?(:hello)` branch in `PageView`. **Gated by O-1** (§4.4): if
  the Definition schema can't express owner + orchestrator auto-join for an anon homesite, this
  phase carries a small `Definition` schema extension (which properly belongs in P0). *(Depends on:
  O-1 resolution; possibly P0.)*

- **P3 — External config source-of-truth + deploy-seed/promote pipeline (Part 3).**
  Move first-party manifests out of Elixir `lib` into a config source-of-truth; build
  `mix ezagent.socialware.publish --from <dir>` over the existing governance flow with
  content-hash-upgrade idempotency; wire it into deploy (per-env, after plugins boot); delete the
  in-code `Demo.Hello.publish/0` boot-publish and `builtin_definitions` in-code seed. *(Depends on:
  P0 for artifact identity/promotion; independent of P1/P2 for the seed mechanics.)*

- **P4 (separate decision, not required) — extract `ezagent_plugin_hello` to its own repo.**
  Whether the hello *plugin code* becomes its own git repo is an axis **independent** of the
  config-repo. The config-repo (P3) delivers the lead's "independent repo seeded at deploy" for the
  *config*; extracting the plugin code is a separate release-engineering decision. *(Depends on:
  nothing; optional.)*

---

## 7. Risks

- **R-1 (schema gap, §4.4/O-1)** — an anon public homesite needs a designated owner; `Definition`
  has no `owner` field. If unaddressed, unified install produces an ownerless homesite where every
  message falls to the concierge.
- **R-2 (idempotency trap, §3)** — the deploy-seed must NOT inherit `Demo.Hello.publish/0`'s
  existence-check idempotency, or edited first-party manifests silently fail to promote. Use the
  content-hash-upgrade path.
- **R-3 (boot-ordering, §5.3)** — seeding a config before its plugin's code is loaded fails the
  `Code.ensure_loaded?` validation (§1.3). The pipeline must seed after plugins register, and fail
  loud.
- **R-4 (anon flow regression, §4.5)** — unifying onto install must preserve `web_anon_access` +
  the anon-User admission chain; needs an E2E gate (anon visitor sees the rendered page with no
  login).
- **R-5 (public-scope authority)** — first-party deploy-seed publishes at `scope: :public`, which is
  admin-gated (`authorize_admin`). The pipeline's bootstrap-admin authority must be genuine
  (`admin_genesis_cap`), not a bypass — keep it inside the governance flow, not a direct ConfigStore
  write.

---

## 8. Open questions for the lead

- **O-1 (tie-breaker for P2 scope):** Does installing a `Definition` carrying
  `orchestrator_template_uri` + `members` + an owner policy reproduce what `App.ensure_app` does for
  **owner assignment** and **orchestrator auto-join** on an anonymous public homesite? If not, we
  add an `owner`/orchestrator-policy field to `Definition` (P0 work) and P2 grows. *(PROPOSED —
  needs a focused code/E2E check.)*
- **O-2 (P4 axis):** Should `ezagent_plugin_hello`'s **code** become its own git repo, or stay an
  `apps/` app in the umbrella? Independent of the config-repo decision.
- **O-3 (promotion mechanism):** For dev→prod promotion, do we (a) re-run the deploy-seed task
  against prod from the same config repo, or (b) build export/import of a *published* def's bytes?
  (a) is simpler and matches "seeded at deploy"; (b) is closer to a true registry promote.
- **O-4 (version semantics):** Is `Definition.version` semver with an enforced monotonic bump on
  publish, or just an opaque tag alongside the content-hash? Affects P0's pin-to-version.
- **O-5 (third-party trust):** Do public third-party socialwares stay admin-gated forever, or is
  there a future self-serve public-publish with moderation? Affects the catalog (P1) trust model.

---

## Appendix — CONFIRMED-in-code vs PROPOSED

**CONFIRMED in code:**
- Socialware = config-only Definition (§1.1); publish/discover/install/admin-gate all exist (§1.2).
- The `Code.ensure_loaded?` resolve-only-where-code-deployed invariant (§1.3).
- Hello's code-vs-config decomposition and the `np`/`py` thin-veneer proof (§2).
- Two parallel in-code seeds with divergent idempotency (§3).
- The two session-creation paths + the `page_view.ex:52` `OR` (§4.1).
- `Definition` carries agents/members/orchestrator_template_uri/routing but has **no** owner field
  (§4.4).

**PROPOSED (design, not yet built):**
- Versioned promotable artifact identity + pin/unpublish (P0).
- Catalog UI (P1).
- Unified install path for the flagship (P2).
- External config source-of-truth + deploy-seed/promote pipeline (P3).
- Plugin-repo extraction (P4).
- Everything in §8 (open questions).
