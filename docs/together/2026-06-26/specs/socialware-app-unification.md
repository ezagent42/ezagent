# SPEC — Socialware 收口: a session INSTALLS app-definitions (decoupled model)

> **Status: DESIGN (design + PHASED plan, NOT implementation).** Read-only basis;
> no code changed by this SPEC. Skills loaded: `ezagent-developer`,
> `ezagent-socialware`. All code citations verified against `origin/main`
> (`67b49303`). Worktree off `origin/docs/socialware-app-unification`; branch
> `docs/socialware-app-unification`. Codex adversarial-review record in §9.
>
> **Model-layer REWRITE (2026-06-28).** The lead reframed the model: the prior
> revision treated *"a socialware app ≈ a `SessionTemplate` with `public_view:
> true`"* — i.e. the app **bundled** a `template_ref` and was essentially the
> whole session recipe. That conflates two things. This revision **decouples**
> them onto a three-concept model — **Session (host) / SessionTemplate
> (plugin-composition recipe) / app-definition (installable)** — and **the marker
> becomes an installation relation** ("session S has socialware-app A installed"),
> replacing the implicit `public_view`. The §2 model + §7 phases are re-derived;
> the confirmed decisions (C1 `:internal`; operator de-bake with **no named
> role** in P1-P6; `supervisor` named **only** in P7; P7's four sub-steps; B1/B2;
> AnonIngress folded) are preserved.
>
> **Synthesizes** three prior read-only analyses (each on its own `docs/*`
> branch): operator composability (`docs/socialware-operator-analysis`),
> template→data→instance (`docs/socialware-template-model`), comms PR-3/PR-4
> (`docs/comms-pr34-spec`); plus the merged substrate (#1047 comms-unify, #1060
> participation gates), **role-as-data (#1048)**, the **role-materialization
> foundation** (RF-1..RF-8: runtime mount/detach + role recipes), **kanban-as-role**
> (the landed config-as-data installable precedent), and the recipe/responsibility
> split (#1059).

---

## 0. TL;DR — the decoupled model in one paragraph

Three concepts, each already half-built, are pulled apart cleanly:

- **Session = the host Kind.** One parameterized `Ezagent.Entity.Session`
  (#46 collapse, *landed*) whose per-instance **active behavior set** is captured
  in its `:kind_base` slice. It can **host N installed plugin-apps** because the
  landed `effective_set/2` now admits **undeclared** real behaviors
  (`behavior_set.ex:167-172`) — the same mount path that lets **kanban** run on a
  generic `Entity.Agent` the host never declared.
- **SessionTemplate = a plugin-composition recipe** — *"a session composed of
  [socialware-app A, kanban-app B] + their seed configs."* It names **which
  app-definitions to install**, NOT the socialware config itself. Today this is a
  gap: which behaviors a session gets is **hardcoded at two spawn call sites**
  (`session_creator.ex:338,430` → `chat_behaviors`; `hello/app.ex:35` →
  `socialware_behaviors`), not data. Making composition **data on the template**
  is the foundational new work.
- **Socialware-app = a separate, installable app-definition** — `template://<ws>/
  app/<name>`, the **same config-as-data substrate as a role recipe**
  (`Ezagent.Role` + `RoleRegistry` ConfigObjects, #1048) **on the Session host**
  instead of the Agent host. Its config — **team / routing / persona / behaviors
  (`Turn`/`Surface`) / adapters / visibility-policy** — is its own, **orthogonal
  to kanban's**. The two genuine additions over a role recipe are **`adapters`**
  (the customer channels) + **`visibility-policy`** (publish + anon access).

The **install relation** — a per-install record (`subject = session`, `key =
app-ref`, `body = config`, the `ConfigObject` shape #1048 already uses) **plus**
the app's behaviors in the session's `:kind_base` union — **replaces the implicit
`public_view: true` boolean** as the "this is a socialware app" identity. **Both
fan-out cases are first-class:** (a) one socialware-app → **many adapters**
(Feishu user-a + Slack user-b) = the `adapters` list; (b) one session → **many
installed apps** (socialware + kanban, even two socialware instances) = many
install records + a `:kind_base` behavior **union**. The operator residue
de-bakes unchanged (C1 `:operator_only`→`:internal`; C2 publish default →
app-def `visibility-policy`; C3 a `supervisor` **responsibility**, named only in
P7). AnonIngress (comms PR-3) folds as the customer's entry to the web adapter;
PR-4 is superseded with its disclosure-bug fix re-homed onto C3.

**Why this is a simplification, not a new layer:** the installable app-definition
**reuses the role-recipe + ConfigStore + mount + CapMint substrate** (kanban
proved it end to end); the install relation **reuses `:kind_base` + ConfigObject**.
The only genuinely NEW concepts are **(1) the SessionTemplate composition field**
(de-hardcoding the behavior-set selection), **(2) the app-definition as a
Session-host sibling of the role recipe** (= existing substrate + `adapters` +
`visibility-policy`), and **(3) the install relation** (session ↔ app-def). It
also **fixes a latent illegality** the prior revision carried: it does **not**
introduce a `socialware://` scheme (which would violate the 6-scheme allowlist,
ezagent-developer invariant #11) — the app-def is a `template://` subtype.

---

## 1. The problem this 收口 closes

Socialware today is **structurally real but conceptually scattered**, and the
scatter is now sharper than the prior revision saw:

1. **There is no app object, and the marker is a magic boolean.** "A socialware
   app" is `public_view: true` buried in `SessionTemplate` content
   (`session_template.ex:757-764`), read by `PublicView.public_view?/1`
   (`public_view.ex:38`). The boolean silently does **two unrelated jobs**
   (identity + the anon gate) and has hardcoded consequences (both browser routes
   always-on for every `public_view` session).

2. **Which plugin-apps a session has is NOT data — it is hardcoded at the spawn
   call site.** `session_creator.ex:338,430` *always* threads
   `Session.chat_behaviors()`; only `hello/app.ex:35` threads
   `Session.socialware_behaviors()`. So a socialware (Turn/Surface) session can be
   created **only** via the hello demo path, never via the world "New session"
   form. The "session composition" the lead wants (which apps installed) has **no
   data home** — it is two `if`-by-call-site branches.

3. **The channel set is hardcoded, not data.** `/socialware/chat` + `/socialware/
   external` are two always-on routes (`router.ex:118,137`). Adding Feishu/Slack
   as a customer channel means more route code. comms-unify (#1047) already proved
   these are **two `ExternalMirror.Adapter`s over one `SessionFeedChannel`** — so
   "which channels" *wants* to be an adapter list, but nothing holds it.

4. **The editor is half-built.** The world form authors only name + description +
   the `public_view` checkbox; it **hardcodes `members: []`, `routing_rules: []`,
   `prompt_templates: %{}`, `legends: %{}`** (`workspace_plugin_actions.ex:326`).
   The rich recipe is authorable only by running a session + driving the
   orchestrator. Two authoring paths, no convergence.

5. **The "operator" naming residue** — already *composed* (no Kind/role/cap); the
   only residue is a persisted enum leak (`:operator_only`) + one hardcoded
   auto-publish default.

6. **The responsibility/takeover layer is implicit + surface-less.** Members carry
   an undocumented `role_name` (B1); the takeover verbs (`:claim`/`:settle`/
   `:approve`) exist but have **no product surface** (raw `mix ezagent` only); a
   *multi-holder* supervisor pool with arbitration is not expressible (B1 is
   unique-per-session). The domain-role research designed this as B2.

The 收口: **separate the three concepts** so (a) identity is an explicit install
relation, (b) "which apps + which channels" is data, (c) one definition both
editors mutate, (d) it carries the de-baked operator policy, and (e) it declares
its responsibilities — **reusing the role-recipe / mount / ConfigObject substrate
that kanban already runs on**, inventing as little as possible.

---

## 2. The decoupled model — a session installs app-definitions

### 2.1 The three concepts (and what already exists)

```
Session (HOST Kind)  ── installs ──►  app-definition(s)   (template://<ws>/app/<name>)
   │  one parameterized Entity.Session                       config-as-data, sibling of Role recipe
   │  per-instance active behaviors = :kind_base union       behaviors + team + routing + persona
   │  (effective_set/2 admits UNDECLARED — behavior_set.ex:167)   + ADAPTERS + VISIBILITY-POLICY
   │
   └── created from ──►  SessionTemplate (COMPOSITION recipe)
                            installs: [ {app-ref, seed-config-overrides}, … ]   ← NEW data home
                            (replaces the hardcoded chat_behaviors/socialware_behaviors call-site choice)
```

| Concept | Role | Status |
|---|---|---|
| **Session host Kind** | the "room" that hosts installed apps; active behaviors in `:kind_base` | **EXISTS** — #46 collapse landed; `behaviors/0` superset + `effective_set/2` per-instance subset (`session.ex:56-104`, `behavior_set.ex`) |
| **`effective_set/2` admits undeclared behaviors** | lets a host run a plugin's behaviors it never declared (authz still gates) | **EXISTS (landed)** — `declared_part ++ extra_part`, `behavior_set.ex:167-172`; kanban runs `Behavior.Kanban` on undeclaring `Entity.Agent` |
| **SessionTemplate** | the recipe a session is created from | **EXISTS** but carries socialware config, not a composition list; behavior-set choice is **hardcoded at call sites** (NEW work to make it data) |
| **app-definition (installable)** | config-as-data bundle installed onto a host | substrate **EXISTS** (`Ezagent.Role` recipe + `RoleRegistry` ConfigObjects + mount + CapMint); the **socialware app-def shape** (+ adapters + visibility) is **NEW** |
| **install relation** | "session S has app A installed" | NEW — built from EXISTING `:kind_base` (behavior union) + `ConfigObject` (per-install config) |

### 2.2 The install mechanism is REUSE — declaration-free mount (kanban proved it)

The load-bearing question for the whole reframe: *can a session host plugin X's
behaviors **without `domain_session` declaring X**?* If not, "a session installs
socialware/kanban" would force the host to declare every plugin — a
plugin-isolation violation (North Star). **Answer: yes, it is already landed.**

- `effective_set/2` (the single function every post-load dispatch enumeration
  calls, `runtime.ex:160,301-307`) computes the instance's active set as
  **`declared_part ++ extra_part`** (`behavior_set.ex:160-172`): `extra_part`
  is exactly the captured `:kind_base` behaviors that are **NOT declared** by the
  host Kind but **are real Behaviors**. The comment is explicit: *"authz still
  gates every action, so presence in the set grants NO privilege."*
- `Ezagent.Kind.mount/3` + `detach/2` (`kind.ex:535,561`; `mount_detach.ex:72,
  101`) install/remove a behavior on a **live** instance — running its slice-init,
  **re-validating closure** (`resolve_closure` on the prospective set,
  `mount_detach.ex`), and rewriting `:kind_base`. The Kind-level `attach_behavior`
  (the wrong, global-registration approach) was **retired** (`kind.ex:879`, RF-3).
- **kanban is the proof.** `kanban-manager` is a role recipe (`roles/0`,
  `ezagent_plugin_kanban/application.ex:64`) whose `behaviors:
  [Behavior.Kanban, Connectors]` are **mounted per-instance onto a generic
  `Entity.Agent`** that declares none of them (`agent.ex:97-112` — no Kanban). It
  dispatches via `?action=kanban.*` and works because `effective_set`'s
  `extra_part` admits the undeclared behavior and authz gates each action.

> **Note — role-foundation §4 was RELAXED on landing.** `role-foundation-design.md`
> §4/HIGH-1 stated as a *hard constraint* that "a role can only mount behaviors the
> host Kind declares." The code that landed **dropped** the strict ∩declared rule
> in favour of `declared_part ++ extra_part` (declaration-free, authz-gated). This
> SPEC builds on the **landed** behavior (code wins — ezagent-developer §"when this
> skill conflicts"). The constraints that DO remain: a mounted behavior must be a
> real Behavior, the set must stay **closed under required sibling reads**
> (`resolve_closure`), and the session Kind requires an explicit non-nil
> `:kind_base` (`requires_explicit_behavior_set?`, `behavior_set.ex:100-103`).

**Consequence for the model:** "installing an app onto a session" = mounting the
app-def's behaviors into the session's `:kind_base` set (+ recording the install,
§2.4). It needs **no new core mechanism and no new app edge** — it is the
kanban mount path applied to the Session host. *That* is why this is a
simplification, not a new layer (codex Q1).

### 2.3 The app-definition — a Session-host sibling of the role recipe

`Ezagent.Role` is already config-as-data: `%Role{behaviors, requested_caps,
skills, plugins, prompt, script, passive, session_template}` (`role.ex:46-66`),
the content of a forkable `template://<ws>/role/<name>` Template subtype, stored
as a `ConfigObject` and resolved by `RoleRegistry` read-through over `ConfigStore`
(`role_registry.ex:3-29`, key `"role"`). A built-in role is **the same data shape**
as a user-authored one.

A **socialware app-definition is the same substrate, addressed `template://<ws>/
app/<name>`**, with two fields a role recipe lacks:

```
template://<ws>/app/<name>                  # installable app-definition (config-as-data; ConfigObject, key "app")
├── behaviors      : [Behavior.Turn, Behavior.Surface, …]   # REUSE: the per-instance set the host mounts
├── members        : [%{uri|source_template_uri, role_name, …}]   # the app's slice of the team
├── routing_rules  : [%{matcher, receivers, rule_set, …}]   # the app's routing
├── prompt_templates / legends / orchestrator_template_uri  # the app's orchestration recipe
├── adapters       : [%{adapter_id, role: :customer|:internal, config}]   # NEW: ExternalMirror.Adapter set
│     ├── "web_feed"      :pull   (chat + page disciplines; the SPA shell)
│     ├── "feishu_mirror" :push   (a customer channel)   [optional]
│     └── "slack_mirror"  :push   (a customer channel)   [optional]
└── visibility_policy : %{                                  # NEW: replaces public_view's jobs
        publish_policy  : :auto | :supervised,             # C2 — was the hardcoded turn.ex default
        web_anon_access : boolean }                        # the anon gate (job (b) of old public_view)
```

Content-addressed + versioned exactly like `SessionTemplate`/role recipes
(SHA-256 over deterministic content; editing mints a new version), inheriting the
immutable/forkable/role-as-data discipline (`compute_version_hash/1`).

**Why a distinct object, not 2-3 keys on `SessionTemplate`?** Because under the
decouple they have different cardinalities and lifetimes, and the *whole point* is
that the app is **orthogonal to other installed apps**:
1. **One app, many sessions / one session, many apps.** `template://support/app/
   helpdesk` is installed onto every helpdesk session; a single session can
   install helpdesk **and** kanban. Neither fits "a key on one template."
2. **The app outlives template versions.** The app-ref is a stable installable;
   the SessionTemplate that composes it is re-edited independently.
3. **It rides an existing registry.** It is a `ConfigObject`/`template://` subtype
   like a role — not a new hierarchy, not a new scheme.

### 2.4 The install relation REPLACES `public_view` — re-targeted parity audit

The install relation has **two physical parts**, mirroring `public_view`'s two
jobs:
- **(identity) a per-install record** — a `ConfigObject` (`subject = session_uri`,
  `key = "install:" <> app-ref`, `body = seed/override config`) — the #1048 shape
  (`config_object.ex:14-23`: `{workspace_uri, subject_uri, key, body}`). This is
  the durable *"session S has app A installed"* fact. `:kind_base` alone cannot be
  the record: it holds only the derived behavior **union** and loses which-app-
  owns-which-behavior, so a separate per-install row is required.
- **(behavior) the app's behaviors in the session's `:kind_base` union** —
  installed via mount (§2.2).

`public_view: true` did two jobs; the split re-homes each. **Parity audit** —
every `public_view` read/write on `origin/main` mapped to its new home:

| # | Site (`origin/main`) | Job today | New home |
|---|---|---|---|
| 1 | `session_template.ex:757-764` — `:public_view` in `@config_atom_keys` | (a) identity schema key | **install record** (a socialware-typed app is installed); `:public_view` key removed from template schema |
| 2 | `public_view.ex:38,108` — `PublicView.public_view?/1` gate | (b) anon-access gate | **app-def `visibility_policy.web_anon_access`** — `public_view?/1` becomes "resolve session→install→app-def→web adapter; anon permitted?" |
| 3 | `anon_user.ex:120` — `mint_for_public_session` calls `public_view?/1` | (b) gate before minting | re-points to (2) via the same resolver |
| 4 | `anon_user.ex:99-154` — `public_view_granter/1` (= session owner) | cap granter (#154) | **unchanged** — anon's `:join` cap still `granted_by` the session owner |
| 5 | `membership.ex:371,801,818` — `public_view` open-join doc/granter | (b) anon path | re-points to (2) |
| 6 | `app.ex:31,35` (hello) — writes `public_view: true` + `socialware_behaviors()` | (a)+(b) at create | hello installs `template://<ws>/app/hello-<n>` (web adapter w/ `web_anon_access: true`) onto the session — the **mount path replaces the hardcoded `socialware_behaviors()`** |
| 7 | `workspace_plugin_actions.ex:334` — world toggle writes `public_view` | (a)+(b) authored | the form (§4) authors/installs the app-def (web adapter w/ anon) |
| 8 | `chat_feed_controller.ex:108` + `external_feed_controller.ex:131` — the two public controllers call `public_view?/1` as ingress gate | (b) per-route anon gate | re-point to (2); in P2 these collapse into the `AnonIngress` shim (§5.1) — the re-point is in ONE chokepoint |
| 9 | `workspace_plugin_data.ex:189,211,256-258` — world read-model `public_view?/1` (renders the badge) | (a) identity, for display | reads the **install record** (is a socialware app installed on the template/session?) |

Every site → **identity = install record** (rows 1, 6, 7, 9) **or** **anon-gate =
app-def `web_anon_access`** (rows 2, 3, 5, 8); row 4 (granter) unchanged. (Non-prod
sites — test fixtures, `router.ex` comments, `autoservice_tier1_seed.exs`,
`hello_session.ex` doc — track the same two homes.) **The anon ingress (§5.1) must
wire its gate to the app-def `web_anon_access`, NOT to the install marker** —
stating it as a flat rename would mis-wire the gate. The §7 P3a gate is a test that
**no `public_view` boolean is read anywhere** and both jobs resolve via the new
homes.

### 2.5 The two fan-out cases — both first-class

**(a) one socialware-app → many channel adapters** (Feishu user-a + Slack user-b).
The `adapters` list (§2.3) is literally a list of `ExternalMirror.Adapter` ids +
per-adapter config. The contract already has the axis (verified against the live
`@callback` block, `adapter.ex:167-377`): `adapter_kind/0 ∈ :push|:pull|
:request_scoped`; a `:push` adapter (Feishu/Slack) has a paired `Binding`
GenServer owning its transport (`binding_module/0`, `cap_subject/0`,
`target_ownership_check/2`, `event_to_payload/1`); a `:pull` adapter (the web feed)
is served on demand (`render_authorized/2`, `live_topics/1`, `delivery_discipline/0
∈ :snapshot_refresh|:cursor_replay`, `participation_profile/0 ∈ :read_only|
:participatory`). #1047 collapsed both browser surfaces onto one
`SessionFeedChannel` parameterized by those callbacks. So *"this app speaks to
Feishu-user-a AND Slack-user-b"* = two `:push` entries in `adapters`, each with its
recipient in `config`. Nothing in the model caps the count.

**(b) one session → many installed plugin-apps** (socialware + kanban, even two
socialware instances). Each install is its own record (§2.4) keyed by app-ref, and
the session's `:kind_base` is the **union** of all installed apps' behaviors
(mount is additive; `effective_set` returns the union). Two socialware instances =
two install records with distinct app-refs (e.g. `app/helpdesk` + `app/sales`),
each with its own adapters + visibility-policy + members. Closure
(`resolve_closure`) is checked over the union at each mount, so an app that
requires a sibling read it doesn't bring is rejected at install — fail-closed.

### 2.6 Symmetry with kanban — be precise about what's reused vs new

Kanban is the precedent for the **per-app installable substrate**, but it is
**not** a "session installs kanban" today — stating otherwise would over-claim.

| Aspect | kanban (landed) | socialware-app (this SPEC) |
|---|---|---|
| definition shape | `Ezagent.Role` recipe (config-as-data) | **same** substrate + `adapters` + `visibility_policy` |
| storage / resolve | `ConfigObject` via `RoleRegistry`/`ConfigStore` (#1048) | **same** (`template://<ws>/app/<name>`, key `"app"`) |
| host Kind | generic `Entity.Agent` (one role per agent) | generic `Entity.Session` (**N apps per session**) |
| install mechanism | per-instance **mount** of undeclared behaviors (§2.2) | **same** mount path on the Session host |
| caps | `Role.CapMint` fail-closed `requested ∩ policy` | **same** `CapMint` |
| isolation | `passive` flag + mention/join/receive gates (RF-6) | reuses the same gates for passive members |
| **session relation** | **NONE** — workspace-scoped agent, session-independent | **NEW** — the install relation (session ↔ app-def, §2.4) |
| **multi-install host** | N/A (one role per agent) | **NEW** — session as a multi-app host (`:kind_base` union, §2.5b) |

So: **per-app substrate = REUSE** (kanban proves recipe + mount + ConfigObject +
CapMint end to end); **session-as-multi-app-host + the install relation =
genuinely NEW**. We are *not* reinventing kanban's mechanism — we are applying it
to a host it has never run on (Session) and adding the multi-install relation that
an agent never needed.

### 2.7 The external channel IS `ExternalMirror.Adapter`; "hello" is the web page-builder

No new "vertical" concept. The app's `adapters` list = `ExternalMirror.Adapter`
ids + config (§2.5a). **"hello" is the page-builder behavior behind the `:pull`
web adapter, NOT a data row.** Per the template analysis's *"definition = data;
vertical mechanism = code"*: the external channel is the generic `:pull` web
adapter; hello's `HelloBuilder` agent + `@json-render` `Spec` validator +
`TurnDriver` + renderer island are **code** (`ezagent_plugin_hello`), referenced by
a `members` entry in the app-def naming the builder. `PageView.applies_to?/1`
render-target dispatch is unchanged.

### 2.8 What MOVES out of SessionTemplate into the app-def (Q4 answer)

Under the decouple, the SessionTemplate stops carrying socialware config and
becomes a **composition recipe**. What was socialware-specific in template content
**moves into the app-def**; the template keeps only generic composition + lineage.

| SessionTemplate content (`origin/main`) | Decoupled home | Why |
|---|---|---|
| `public_view` | **deleted** → install relation (identity) + app-def `web_anon_access` (anon) | §2.4 — the magic boolean is replaced by the relation |
| `members`, `routing_rules`, `prompt_templates`, `legends`, `orchestrator_template_uri` | **MOVE → app-def** | the lead's decision: team/routing/persona is the **app's own config**. Each installable brings its slice of the team; the session = union of installed apps' members/routing |
| `name`, `description`, `default_workspace_uri`, `parent_template_uri`, version/provenance | **STAY** on SessionTemplate | generic composition + lineage |
| **`installs: [{app-ref, seed-overrides}]`** | **NEW field on SessionTemplate** | the composition itself — *which* app-defs to install (replaces the hardcoded behavior-set call-site choice, §1.2) |

> **Consequence (flag, don't bury) — the orchestrator tool catalog re-targets.**
> `add_managed_member`, `update_member_template`, `remove_member`,
> `define_rule_set_rule`, `define_prompt_template`, `define_legend`,
> `update_template`/`save_template_as`, and **`migrate_session`** today mutate /
> re-point **`SessionTemplate` content** (members/routing/legends). Once those
> fields live on the app-def, every one of these tools must target the **app-def**
> version instead — for **all** orchestrated sessions, not only socialware. That
> rewire is the bulk of the extract phase (§7 P3b) and is its own bounded step.
>
> **Open question for the lead (OQ-2):** a *non-socialware* orchestrated chat
> still needs a home for its team/routing. Either (i) plain orchestration becomes
> its own installable app-def (`template://<ws>/app/<chat-team>`) — fully
> symmetric, recommended; or (ii) a base composition on the SessionTemplate
> retains a generic team. (i) keeps the decouple clean (everything is an
> installable); (ii) hedges migration cost. Recommend (i).

### 2.9 Where the definition lives (data geography — confirming #46/EZAGENT_HOME)

`EZAGENT_HOME` holds agent **runtime** state (credentials, per-agent config, logs
— `home.ex`, `repo.ex:6-12`). The **app-def stays in the data store**: the
content-addressed versioned object is a `ConfigObject`/`template://` subtype
(`config_store.ex`, `config_object.ex:14-23`); its `visibility_policy` is the
role-as-data cascade (workspace > user > session). **Nothing moves to
`EZAGENT_HOME`; this SPEC introduces no new substrate** — both data homes exist.

### 2.10 The operator de-bake folded into the model (C1/C2/C3)

The operator analysis proved "operator" is already composed — residue = naming + one default:

- **C1 — rename `:operator_only` → `:internal`** (persisted `Message.visibility`
  enum, `message.ex:73,119`). Pure name finish of the #1037 `:customer_*`→
  `:external_*` symmetry; the binary is external-vs-internal. **Independent of the
  app object.** Detail in §6.
- **C2 — lift the auto-publish-vs-hold default** out of the hardcoded
  `Turn.handle_open` (`turn.ex:246`, `initial_visibility/1:615`) **into the app-def
  `visibility_policy.publish_policy`** (`:auto | :supervised`). `:auto` preserves
  today's behavior; `:supervised` holds turn output `:internal` until `:settle`.
  Read at `handle_open`.
- **C3 — name the operator cap-bundle a `supervisor` responsibility.** The
  `{:claim, :settle, :approve, read-unfiltered}` bundle becomes a first-class
  **axis-B responsibility** (membership `role_name` + cap bundle), per the
  recipe/responsibility split (#1059). **C3 is the entry point to the full
  responsibility & routing layer (§2.11); `supervisor` is a NAMED responsibility
  ONLY in P7** (where routing-fan-out + the multi-holder pool need a named target).
  Keep per-message visibility as a real revocation primitive
  (`external_feed.ex:293`), rename only.

### 2.11 The responsibility & routing layer — B1/B2 and the takeover loop

A socialware app is also a set of **principals each serving a responsibility**.
This is the SPEC's second 收口 axis — alongside recipe (axis A, mostly done via
#1048/#1059), **responsibility (axis B)**. The autosvc operator/supervisor
takeover flow IS responsibility-in-action — exactly the **B2** the domain-role
research designed (`docs/domain-role-research:…/role-for-users-domain-role.md`).

**The two axes (research §1, #1059):**
- **recipe (A)** = "what an *agent* is built from" — skills/prompt/behaviors/
  `requested_caps`/`config_dir`. Build-time, agent-only.
- **responsibility (B)** = "what *function a principal* (user OR agent) serves in
  a session" — a `role_name` + routing `{:role, name}` + standing caps. Runtime,
  cross-principal.

A member may be an agent **built from** the `bot` recipe **carrying** the `bot`
responsibility — the two names need not match (#1059,
`recipe_responsibility_lockin_test.exs`). The `supervisor` responsibility is held
by **humans** (no recipe). The editor (§4) **assigns** responsibilities; it never
conflates them with recipes.

#### 2.11.1 How the app-def declares responsibilities (data)

```
app-def.members : [%{uri, role_name: "orchestrator"|"bot"|"reviewer", …}]   # B1 single-holder
app-def.responsibilities : [
  %{name: "bot",        kind: :b1_single},
  %{name: "supervisor", kind: :b2_pool,                   # multi-holder HUMAN takeover pool
    caps: [:claim, :settle, :approve, :read_unfiltered],  # the operator cap-bundle (C3)
    quorum_policy: :any_one | :majority | :n_of_m,
    arbiter: "arbiter" | nil}
]
```

Names are data; **holders are assigned** — B1 by member `role_name` in the app-def;
B2 by a workspace-scoped assignment (§2.11.4), written by the editor.

#### 2.11.2 B1 vs B2

| | **B1 (exists)** | **B2 (new — the takeover pool)** |
|---|---|---|
| scope | per **session** | per **workspace** |
| holders | **single** (`role_name` unique per session, `role_name_conflict/3`) | **many** (a pool of N principals share R) |
| `{:role,name}` resolves to | exactly **one** URI | **fan-out** over all current holders |
| use | "the one orchestrator/bot/reviewer of THIS session" | "the **supervisor pool** watching ALL support sessions; any of N can take over; conflicts arbitrated" |

Two disagreeing holders cannot exist under B1's unique-per-session invariant
(research §1.2), so B2 is genuinely new state.

#### 2.11.3 The takeover/approval/escalation loop ([REUSE] vs [B2-NEW])

The verbs exist (`:claim`/`:settle`/`:approve` — `turn.ex:49,320`, `surface.ex:20`)
but have **no product surface** (operator analysis §5). The loop reuses the generic
verbs and adds B2 machinery for pool/quorum/arbiter:

1. **bot escalates** → `{from: bot, on: <signal>} -> {:role, "supervisor"}`
   delivers to the **B2 pool**. **[B2-NEW]** — multi-holder fan-out + assignment
   gate (§2.11.4); B1 resolves to one URI only.
2. **a human claims** → `:claim` on the `Turn` (`handle_claim`, records claimer as
   owner, `turn.ex:315,320`); turn → `mode: :copilot, status: :awaiting_human`,
   output held `:internal` (C1). **[REUSE]**.
3. **release** → `:settle` (flip held → `:external_visible`) or `:approve` (advance
   the surface page pointer). **[REUSE]**.
4. **conflicting verdicts** → the **B2 quorum Behavior** collects verdicts under
   `quorum_policy`; on conflict escalates to `{:role, "arbiter"}` (recursion over
   the same fan-out + collect). **[B2-NEW]**.

No `operator` Kind/role/cap is introduced — the "already-composed" verdict holds,
now with the pool + quorum B1 lacked.

#### 2.11.4 Where the B2 machinery lives (dep-DAG, codex-corrected)

Verified edges (`mix.exs`, `origin/main`): `domain_session → domain_workspace →
{domain_identity, domain_agent}`; **workspace does NOT dep session**. Forced split:

- **Durable principal→responsibility assignment → `domain_workspace`** (a new
  `:assign_role` cap, sibling to role-as-data's role-authoring caps). Workspace
  already deps identity (#154) — **no new edge**.
- **Approval/quorum/arbiter Behavior → `domain_session`** (the only app with
  message replies + membership + routing; reads the assignment over the existing
  session→workspace edge). **No new edge, no cycle.**
- **Assignment-gated fan-out — `{:role,name}` expansion is a `core/routing` SEAM,
  but multi-holder resolution + validation is INJECTED from session/workspace.**
  `ezagent_core` has **no umbrella deps**; `Routing.Resolver` is pure
  (`resolver.ex` moduledoc). B1 already injects a resolver (`session.ex:514,519`).
  B2 reuses that seam: session injects a **multi-holder resolver** (`{:role,name}` →
  `[uri]` over the workspace assignment) **+ a validation predicate**. **NOT a
  one-line `expand_receiver` change** — a naïve fan-out would hand stale/out-of-
  scope principals to `Delivery`, which mints a narrow `:receive` cap per recipient
  (`delivery.ex:169,259`), because role resolution bypasses the `valid_member?`
  filter (`resolver.ex:373,402`) → a tenant-isolation hole. The injected resolver
  must enforce **same-workspace + current-assignment** before delivery, with a test
  proving no `:receive` cap is minted for unassigned/out-of-scope principals
  (research §3.2, codex HIGH).
- **Assignment↔cap lifecycle is NEW state** — caps are a flat `MapSet` keyed by
  cap identity, not role-bundled (`identity.ex:55,409,421`); assigning `supervisor`
  does not auto-grant `approve`. B2 owns an explicit **grant-on-assign /
  revoke-on-unassign** binding **or** atomically re-checks assignment+cap at
  verdict-acceptance (stale holder's verdict rejected).
- **Accountability:** B2 approval caps are accountable **iff minted via the
  `Ezagent.Identity.Grant` grant path** (overwrites `granted_by`, requires
  `entity://`, `grant.ex:175,191-198`) — not via the runtime `granted_by_entity?/1`
  predicate (`capability.ex:319`, only rejects `system://`).
- **No new `domain.role` app** (YAGNI). socialware needs **no new edge**: it only
  *names* responsibilities as data; assignment lives in workspace (written by the
  editor), the workflow runs in session (socialware already deps session).

#### 2.11.5 Why this is responsibility, not a socialware special

A `reviewer`-pool gating a code-merge and a `supervisor`-pool gating an autosvc
takeover are the **same B2 machine** with different names. The app-def merely
*declares the names + B2 config*; assignment, routing, workflow are reused domain
primitives. The takeover loop adds no concept only socialware could use.

---

## 3. What is REUSED vs what is genuinely NEW

| Piece | Reused / New | Note |
|---|---|---|
| `Ezagent.Entity.Session` host Kind + `:kind_base` per-instance set | **REUSE** | #46 collapse landed; the multi-app host |
| `effective_set/2` admitting undeclared behaviors (`behavior_set.ex:167-172`) | **REUSE** | the declaration-free install gate; kanban proves it |
| `Ezagent.Kind.mount/3` / `detach/2` (runtime per-instance install) | **REUSE** | RF-1/RF-3 landed; the install action |
| `Ezagent.Role` recipe + `RoleRegistry` + `ConfigStore`/`ConfigObject` (#1048) | **REUSE** | the config-as-data app-def substrate (kanban runs on it) |
| `Role.CapMint` (fail-closed `requested ∩ policy`) | **REUSE** | mints the app-def's `requested_caps` |
| `passive` flag + mention/join/receive gates (RF-6) | **REUSE** | passive app members |
| `Ezagent.ExternalMirror.Adapter` (`:push`/`:pull`) + `SessionFeedChannel` (#1047) | **REUSE** | the `adapters` list / fan-out (a) |
| `App.ensure_app` (hello) | **REUSE (rewired)** | install path replaces the hardcoded `socialware_behaviors()` |
| `AnonUser`/`AnonBinding`/`public_view_granter` | **REUSE** | anon identity + granter (#154) |
| `:claim`/`:settle`/`:approve` verbs + per-message `visibility` enum | **REUSE (rename only)** | takeover machine; `:operator_only`→`:internal` |
| membership `role_name` + `{:role,name}` routing (**B1**) | **REUSE** | single-holder per-session responsibility |
| identity-slice caps + `Ezagent.Identity.Grant` | **REUSE** | the accountable approval primitive (#154) |
| **SessionTemplate `installs: [...]` composition field** | **NEW** | de-hardcodes the behavior-set call-site choice (§1.2) |
| **socialware app-def shape** (`template://<ws>/app/<name>` + `adapters` + `visibility_policy`) | **NEW (thin)** | = role-recipe substrate + 2 fields, on the Session host |
| **the install relation** (per-install `ConfigObject` + `:kind_base` union) | **NEW** | replaces `public_view` (identity, §2.4) |
| **the world FORM editor** (full app-def + adapter picker) | **NEW** | closes the editor gap; one of two paths onto the def |
| `admit_anonymous_participant` primitive + `AnonIngress` shim | **NEW (= comms PR-3)** | folded in (§5.1) |
| `supervisor` responsibility (B1) + cap-bundle | **NEW (= C3)** | names the operator authority; re-homes PR-4 fix |
| **B2 workspace assignment** (`:assign_role`, `domain_workspace`) | **NEW** | many-holder pool |
| **assignment-gated fan-out boundary** (`core/routing` seam + injected resolver) | **NEW** | `{:role,name}`→`[uri]` w/ same-ws + assignment validation (no `:receive` leak) |
| **assignment↔cap lifecycle** | **NEW** | grant-on-assign/revoke-on-unassign |
| **approval/quorum/arbiter Behavior** (`domain_session`) | **NEW** | the B2 takeover workflow |
| **the takeover product surface** (claim/approve/escalate UI) | **NEW** | closes the "no product surface" gap |

**Net new concepts: three** (composition field, app-def shape, install relation) +
the responsibility B2 layer (deferred). Everything else is reused — strictly fewer
new concepts than the prior revision (which invented a `socialware://` scheme + a
`socialware://<name>` Kind-snapshot object distinct from the role/ConfigObject
substrate).

---

## 4. The dual-path editor (one source of truth)

Both paths mutate **one** app-def:

- **Path A — declarative world FORM.** Fills the **full app-def**: behaviors
  (which the install mounts), members / routing_rules / prompt_templates / legends
  (closing the `workspace_plugin_actions.ex:326` hardcoded-empty gap), the
  **adapter picker** (which `ExternalMirror.Adapter`s), and `visibility_policy`.
  Plus the SessionTemplate **composition** (`installs: [...]`). Dispatches to the
  write path that mints a new app-def version.
- **Path B — in-session orchestrator conversation loop.** The orchestrator tools
  (`add_managed_member`, `define_rule_set_rule`, …, `update_template`/
  `save_template_as`, `migrate_session`) — **re-targeted from SessionTemplate
  content to the app-def** (§2.8) — mutate the same definition.

**One source of truth:** both terminate at the same content-addressed write on the
app-def. The form is a projection of the orchestrator-tool semantics; neither owns
a private copy. The `"current"` tag must publish on author-save (skill gotcha #3)
for deterministic adopt-on-create.

**The editor assigns responsibilities (§2.11):** **B1** — each member's `role_name`
in the app-def; **B2** — supervisor-pool holders via the workspace assignment
(`:assign_role`). Assignment is never conflated with the agent recipe (#1059).

---

## 5. Subsuming comms PR-3 (folded) and PR-4 (superseded)

### 5.1 PR-3 (AnonIngress) — FOLDED as the customer's entry to the web adapter

The anonymous customer reaching the app's external surface **is** comms PR-3: the
`Ezagent.Socialware.AnonAdmission.admit_anonymous_participant/2` domain primitive
(mint→spawn→join-AS-anon→mount-caps; INV-1 no system principal, INV-2 caps
best-effort, INV-2a fail-closed reuse) + the thin `EzagentWeb.Socialware.AnonIngress`
web shim. In the model: *"how a customer reaches the app's `:pull` web adapter."*

- The primitive's gate re-points to the **app-def `visibility_policy.web_anon_access`**
  (§2.4 row 3) via the session→install→app-def→web-adapter resolver. **One
  cross-phase edge:** PR-3 reads the anon gate, re-points when the install relation
  + app-def land (§7 dep-DAG).
- Placement forced by the DAG: the primitive lives in **`ezagent_domain_socialware`**
  (needs `AnonUser`/`AnonBinding` local + `Membership` (session ↓) + `Entity`/
  `Invocation` (core ↓)). Same reasoning that forces the install-resolver into
  socialware (§7.2).

### 5.2 PR-4 (world Conversation onto contract axis) — SUPERSEDED, fix re-homed

PR-4's world-on-contract convergence is an internal transport cleanup the
operator-debake + editor subsume (the operator console becomes the editor's
operator surface; the "operator projection" is the `supervisor` responsibility's
unfiltered read). But it must not drop its one load-bearing, security-critical
finding:

> **PR-4 §4.3a (codex HIGH):** the unfiltered operator projection
> (`recent_in_session`, includes `:operator_only`/`:internal`) behind `/sessions`
> (`RequireEntity` only, no `require_admin`) **leaks internal messages to any
> authenticated workspace user** unless a concrete operator-authz predicate gates
> it, fail-closed, re-checked on read.

**Re-homes onto C3:** the **`supervisor` responsibility + cap-bundle IS the
operator-authz predicate.** `render_authorized/2` (or whatever serves the operator
unfiltered read) checks the `supervisor` cap fail-closed. **Superseding PR-4 is
safe only when C3 lands** (§7 P6) — not optional cosmetic.

---

## 6. C1 detail — the persisted-enum rename (the pre-prod-now move)

`Message.visibility :: :external_visible | :operator_only` → `:internal`
(`message.ex:73,119`, `Ecto.Enum`, default `:external_visible`). It is a
**persisted enum value** stored as a string — doing it *after* prod is a live data
migration over real history; doing it *now* is a dev-only `db.reset`. That
asymmetry is why C1 is **pre-prod-now**.

> The column is a **plain string with a default, NOT a DB enum constraint**
> (`…20260618000400…:6-9`, `pg_baseline.exs:54`) — so C1 is an `Ecto.Enum` value
> rename + a one-shot `UPDATE`, not a type-altering migration. "Pre-prod-now"
> rests on **there being no prod message history yet**; confirm before P1.

- **Touches (~15-18 files):** `message.ex` (enum + typespec + default doc);
  `message_store.ex` (`mark_visibility`, `chat_visible_recent`,
  `committed_external_visible*`); `turn.ex` (`hold_visibility`,
  `initial_visibility`); `settlement.ex`; `chat_feed.ex` (`external_visible?/1`),
  `external_feed.ex` (docs); the two migrations; ~6-9 test files; the invariant.
- **Data migration:** `UPDATE messages SET visibility='internal' WHERE
  visibility='operator_only'` + fail-closed default. Dev: `db.reset`.
- **Atomically, NOT in parallel** — rename-collisions across parallel branches are
  the top regression source. **Ride the #1059 deferred `Role`→`Recipe` symbol-
  rename window** (one collision-audit).

`:internal` is the **all-info superset** name and stays even if visibility later
generalizes to a multi-audience set (OQ-5) — the name encodes "everything,
internal view," not "operator-only."

---

## 7. The re-derived phased plan — dep-DAG, blast radius, per-phase gate

The decouple **re-derives** the phases. Two changes vs the prior plan: **(P0) a new
foundational phase de-hardcodes the behavior-set selection** (the composition field),
and **(P3 splits) into the app-def object + the config-extract** (moving
members/routing out of SessionTemplate, re-targeting the orchestrator tools). Each
phase is independently landable + verifiable.

```
   P0 (composition field: de-hardcode behavior-set selection)  foundational; pre-prod
        │
   P1 (C1 enum rename) ───────┐  (independent; pre-prod CRITICAL)
   P2 (PR-3 AnonIngress) ──┐  │  (independent refactor)
        │                  │  │
        ▼                  │  │
   P3a (app-def object: template://app + install relation; split public_view §2.4) ◄── needs P0
        │  └─ re-points P2's anon gate (P2→P3a edge)
        ▼
   P3b (config-extract: move members/routing/persona → app-def; re-target orchestrator tools)  needs P3a
        ▼
   P4 (C2 publish_policy in app-def visibility_policy)   needs P3a
        ▼
   P5 (dual-path FORM editor)                            needs P3a/P3b
        ▼
   P6 (C3 supervisor responsibility B1; re-homes PR-4 fix)   defer; ride #1059
        ▼
   P7 (B2 supervisor pool + takeover surface; 4 sub-steps)   needs P6 + P5; defer (L)
```

| Phase | What | Blast | Pre-prod? | Independent gate (verifiable) |
|---|---|---|---|---|
| **P0 — composition field** | `installs: [...]` on SessionTemplate; `create_session` reads it to thread the `:kind_base` set, replacing the hardcoded `chat_behaviors`/`socialware_behaviors` at `session_creator.ex:338,430` + `hello/app.ex:35` | **M** | **NOW** (call-site choice today) | a session created from a template whose `installs` names a socialware-typed app boots with Turn/Surface in its `:kind_base` **via data, not a call-site branch**; a chat template boots without them; full `mix test` 0 failures |
| **P1 — C1** | rename `:operator_only`→`:internal` + data-migrate + invariant | **M** | **NOW (persisted enum)** | extend `no_customer_concept_test` to forbid `:operator_only`; full `mix test` 0 failures |
| **P2 — PR-3** | `admit_anonymous_participant` primitive + `AnonIngress` shim; collapse +8 dup groups | **M** | any time | the +8 `cross_file_duplicate_fn_groups` collapse to one primitive + one shim; INV-1/2/2a tests; #1060 Gate 2 green |
| **P3a — app-def + install relation** | `template://<ws>/app/<name>` app-def (config-as-data sibling of role recipe); per-install `ConfigObject` record; split `public_view` per §2.4 | **L** | NOW | a gate that **no `public_view` boolean is read** anywhere; identity resolves via the install record, anon-gate via app-def `web_anon_access`; an app installed onto a session mounts its behaviors via `effective_set` `extra_part`; hello rewired |
| **P3b — config-extract** | move `members`/`routing_rules`/`prompt_templates`/`legends`/`orchestrator_template_uri` from SessionTemplate content INTO the app-def; **re-target the orchestrator tool catalog + `migrate_session` to the app-def** | **L** | NOW | the orchestrator tools mutate the app-def (not template content); `migrate_session` re-points the app-def version; a non-socialware orchestrated session still composes its team (per OQ-2 resolution); round-trips |
| **P4 — C2** | lift auto/hold default into app-def `visibility_policy.publish_policy`; `handle_open` reads it | **S** | NOW | `:auto` preserves today; a `:supervised` turn stays `:internal` until `:settle` |
| **P5 — FORM editor** | world form fills full app-def + adapter picker + visibility; SessionTemplate composition picker; converge with orchestrator loop on one def | **M** | NOW | form authors non-empty members/routing/prompt_templates/legends + adapter set + an `installs` composition; round-trips with `save_template_as`; `"current"` tag published on save |
| **P6 — C3 (B1 supervisor)** | `supervisor` as a **single-holder B1** `role_name` + cap-bundle; relabel `operator_tree`/"Operator SessionView"→internal; **re-home PR-4 authz fix** | **S-M** | defer; ride #1059 | operator unfiltered read gated by the `supervisor` cap fail-closed (the PR-4 disclosure gate); relabel-only elsewhere |
| **P7 — B2 pool + takeover surface (4 sub-steps)** | see §7.3 | **L** | defer (post-prod ok) | per sub-step gates in §7.3 |

**Recommended order:** P0 (foundational, pre-prod) → P1 (cheapest, pre-prod-
critical) → P2 (independent) → P3a (foundational L) → P3b → P4 → P5 → P6 → P7
(last, deferred). P1/P2 land in parallel (no shared file). **C1 (P1) stays
pre-prod-first.** **No named operator role lands in P1-P6** — C3/P6 introduces only
the `supervisor` *cap-bundle authz predicate*; **`supervisor` is a NAMED routing
responsibility ONLY in P7**, where the fan-out target + multi-holder pool need a
name.

### 7.3 P7 — the four bounded sub-steps

| Sub-step | Host | What | Gate |
|---|---|---|---|
| **P7-a assignment** | `domain_workspace` | principal→responsibility assignment + `:assign_role` cap | assigning/unassigning a holder is durable + cap-gated; **no new app edge** |
| **P7-b approval workflow** | `domain_session` | approval/quorum/arbiter Behavior (verdict collection, `quorum_policy`, arbiter escalation) | a quorum→arbiter escalation test; stale-holder verdict rejected (assignment↔cap atomicity) |
| **P7-c fan-out seam** | `core/routing` + **session-injected resolver** | `{:role,name}`→`[uri]` multi-holder resolution + **same-ws + current-assignment validation** | a test proving fan-out delivery mints **no `:receive` cap** for unassigned/out-of-scope principals (the load-bearing tenant-isolation gate) |
| **P7-d takeover UI** | the editor (`ezagent_plugin_world`) | claim/approve/escalate **product surface** | the UI drives `:claim`/`:settle`/`:approve` (no raw `mix ezagent` dispatch) |

### 7.4 Cross-phase couplings

- **P0 → P3a:** the install relation (P3a) is the typed form of P0's composition
  entries; P0 ships the field + data-driven selection, P3a gives the entries a
  first-class app-def + per-install record.
- **P2 → P3a (anon gate):** PR-3 reads the anon gate. If P2 first, it reads
  `public_view?/1` and re-points to `web_anon_access` when P3a lands (one resolver
  swap inside the single primitive). If P3a first, P2 wires straight to it.
- **P3b → P3a:** the config-extract needs the app-def to exist first.
- **P4/P5 → P3a:** `publish_policy` is cleanest in the app-def `visibility_policy`;
  the form picks adapters against the app-def.
- **P6 → PR-4 fix:** superseding PR-4 is safe only once C3 provides the
  `supervisor` authz predicate (§5.2).
- **P7 → P6 + P5:** B2 needs the B1 `supervisor` name (P6) to pool against + the
  editor (P5) to assign holders + drive takeover. P7 is otherwise additive (new
  state in workspace + session + routing) and shares no file with P0-P5.

### 7.2 Dep-DAG legality (zero new app edge)

Hosting the install-resolver needs the app-def (`ConfigStore`, identity ↓),
behaviors via mount (core ↓), `adapters` (external_mirror ↓). In-umbrella deps
(`origin/main` `mix.exs`): `socialware → core, identity, session, external_mirror,
ui`; **session, identity, external_mirror do NOT dep socialware** → **socialware is
the only legal host** for the install-resolver (same forced placement PR-3 used).
The install **mechanism** (mount) is in **core** and already declaration-free
(§2.2), so **no app must declare another's behaviors** — the plugin-isolation
property. The acyclic gate (`im_session_agent_acyclic_test.exs`) + undeclared-dep
gate (`undeclared_umbrella_dep_test.exs`) stay green; #1060 Gate 1/2 untouched by
P0-P5.

**B2 (P7) — also zero new app edge** (`mix.exs`): `domain_session →
domain_workspace → {domain_identity, domain_agent}`; workspace not→session.

| B2 piece | Host | Reaches | New edge? |
|---|---|---|---|
| assignment + `:assign_role` cap | `domain_workspace` | `domain_identity` caps (↓) | **No** |
| approval/quorum/arbiter Behavior | `domain_session` | workspace assignment (existing session→workspace edge) | **No** |
| fan-out boundary | `core/routing` seam + **session-injected resolver** | core stays pure (`{:role,name}` callback); resolver injected (mirrors B1 `session.ex:514,519`) | **No** (core has no umbrella deps) |
| takeover surface | `ezagent_plugin_world` | workspace assignment (world deps workspace), session verbs | **No** |

Workflow in session (not workspace) because the quorum Behavior needs message
replies + membership, which only `domain_session` has; hosting in workspace would
**cycle**. **No new `domain.role` app** (YAGNI).

---

## 8. Reconciliation with substrate / role-as-data / recipe-responsibility / kanban / comms-unify

- **role-foundation (RF-1..RF-8) + mount/detach.** The install mechanism IS the
  landed runtime mount path (`kind.ex:535,561`, `mount_detach.ex`), and
  `effective_set`'s `extra_part` (`behavior_set.ex:167-172`) is what makes it
  declaration-free. This SPEC adds **no new install mechanism** — it applies the
  mount path to the Session host.
- **role-as-data (#1048) + kanban-as-role.** The app-def IS config-as-data — same
  `Ezagent.Role`-shaped recipe stored as a `ConfigObject` via `RoleRegistry`/
  `ConfigStore`, the exact substrate kanban runs on. The app-def adds only
  `adapters` + `visibility_policy`. **Kanban is the precedent, precisely scoped
  (§2.6):** per-app substrate reused; session-as-multi-app-host + install relation
  new.
- **recipe/responsibility split (#1059) + domain-role research (B1/B2).** Both
  axes 收口'd. Recipe (A) mostly done (#1048/#1059,
  `recipe_responsibility_lockin_test.exs`); responsibility (B) folded by §2.11 —
  B1 reused, B2 new per the codex-corrected split. C1's enum rename rides #1059's
  symbol-rename window.
- **comms-unify (#1047)/#1060.** `adapters` = the `ExternalMirror.Adapter` set on
  `SessionFeedChannel`; the two browser disciplines are `delivery_discipline/0`
  configs of the `:pull` web adapter. #1060's participation-profile routing
  preserved — the app-def only *names* adapters; it does not re-open channel logic.
- **#46 (one Kind + composable behaviors + 2 view classes).** The Session host IS
  the #46 collapse; the install relation is the data-driven form of its
  `:kind_base` per-instance set (P0 makes the selection data, not call-site).

---

## 9. Codex adversarial-review verdict

> *Model-rewrite codex pass appended at §9.3 after running it. Prior revisions'
> two passes (core model; responsibility layer) are preserved below as §9.1-§9.2 —
> their findings (the §2.4 parity-table completeness, the injected-resolver seam,
> the accountability wording, the C3-gates-PR4 condition) carry forward unchanged.*

### 9.1 Prior pass 1 — core model (gpt-5.5, static, vs `origin/main`)

SOUND-WITH-ONE-OVERCLAIM. Q1 (app object real simplification) SOUND-WITH-FIXES —
confirmed `SessionTemplate` content-addressed (`session_template.ex:190-203`) +
versioned-URI persisted; the redundancy test put to the lead (now answered by the
decouple + the §2.6 kanban substrate reuse — the app-def rides an existing
registry, so it is not redundant). Q2 (marker replaces public_view) **OVERCLAIM —
parity table incomplete; rows 8-9 added** (carried into §2.4). Q3 (phasing/enum/
dep-DAG) SOUND-WITH-FIXES — the "no DB enum constraint; pre-prod = no prod data"
clarification folded into §6. Q4 (AnonIngress fold + PR-4 supersede) SOUND-WITH-
FIXES — the C3-gates-PR4 condition (§5.2) confirmed.

### 9.2 Prior pass 2 — responsibility layer (B1/B2)

SOUND, three fixes folded. Q1 B1-vs-B2 distinction SOUND (`role_name_conflict/3`,
`members.ex`; single-resolve `resolver.ex:435,451`). Q2 takeover-from-generic-verbs
SOUND-WITH-FIXES — each step marked [REUSE]/[B2-NEW] (§2.11.3). Q3 B2 dep-DAG
SOUND-WITH-FIXES — the `core/routing reaches assignment` row corrected to the
**injected-resolver seam** (§2.11.4, §7.2). Q4 B2 new-state honest SOUND-WITH-FIXES
— accountability reworded to "via the `Identity.Grant` grant path."

### 9.3 Model-rewrite pass — the decoupled model

> Appended after the model-rewrite codex pass (see the report). Scope: is the
> decouple a real simplification or a new layer? Does kanban already do this — are
> we reinventing? Does the install relation cleanly replace `public_view`? Are both
> fan-out cases supported? Is the re-derived phasing safe + each phase landable?
> Any new concept that should reuse an existing one?

---

## 10. Open questions for the lead

1. **App-def as a `template://app` ConfigObject vs template content (the §2.3
   redundancy test).** The decouple + the existing role/ConfigObject registry make
   the distinct app-def cheap (it rides a registry kanban already uses). Confirm
   the fan-out cases (§2.5) make it worth a distinct installable rather than a few
   keys on `SessionTemplate`. (Recommend: distinct `template://<ws>/app/<name>`.)
2. **Team/routing home for non-socialware orchestrated chat (§2.8 OQ-2).** Move
   `members`/`routing`/`legends` out of SessionTemplate into the app-def for *all*
   sessions — making **plain orchestration its own installable app-def** (i,
   recommended, fully symmetric) — or keep a generic base composition on the
   SessionTemplate (ii, hedges migration)? This shapes P3b's blast radius.
3. **C1 rename target — `:internal` (CONFIRMED) vs `:backstage`?** Recommend
   `:internal` for the external/internal symmetry. (Confirmed decision; listed for
   record.)
4. **`web_anon_access` granularity.** The split (§2.4) puts the anon gate on the
   web adapter (per-adapter already). Confirm anon is a web-adapter attribute, not
   an app-global flag. (Recommend per-adapter.)
5. **Binary visibility horizon.** Multiple external adapters share one
   `external_visible` slice today. If two customer channels ever need *different*
   curations of one session, binary visibility → audience-set is a real M→L
   generalization that should precede prod. The chosen name `:internal` is the
   **all-info superset** and stays even if visibility later goes multi-audience.
   Near-term need? (Recommend: keep binary, YAGNI; the app-def makes the future a
   per-adapter projection, not a redesign.)
6. **Install mechanism on the Session host.** §2.2 confirms `effective_set`'s
   `extra_part` admits undeclared behaviors and kanban proves it on `Entity.Agent`.
   Confirm the SAME mount path on the Session host is acceptable (it is core +
   declaration-free, so plugin-isolation holds) — or does the lead want the
   Session host to *declare* socialware/kanban behaviors (tighter, but breaks the
   isolation North Star)? (Recommend: declaration-free mount.)
7. **Editor convergence depth.** Path A (form) + Path B (orchestrator loop, now
   re-targeted to the app-def, §2.8) both mutate the def. Confirm the form is a
   thin projection of the orchestrator-tool semantics, not a parallel write path.
8. **B2 wanted now, or is B1 enough? (§2.11 / research OQ-1).** A single-operator
   app is fully served by B1 + C3 (P6). The multi-holder pool + quorum/arbiter (B2,
   P7) is real new work. Confirm the multi-supervisor + conflicting-verdict scenario
   is near-term before building P7. (Recommend: ship P6, defer P7.)
9. **`role_name` uniqueness for the pool (research OQ-2).** Relax
   `role_name_conflict/3` to allow many holders, **or** keep B1's unique alias + a
   separate workspace assignment for B2? (Recommend the latter — two facets.)
10. **Quorum/arbiter policy + vocabulary (research OQ-4/5).** What verdict policy
    (unanimous/majority/any-one/N-of-M); is `arbiter` a tiebreaker or required
    final approver? And adopt "agent recipe" for axis A / "responsibility" for axis
    B in the app-def + editor labels, retiring the `role` homonym? (Recommend yes.)

---

## Method / provenance

- All reads via `git show origin/main:<path>` (`67b49303`) — no working-tree trust.
- **Decouple-reframe investigation (2026-06-28):**
  - Session host: `entity/session.ex:56-104` (`behaviors/0` superset + `chat_/
    socialware_behaviors/0` subsets); `behavior_set.ex:160-172` (`effective_set`
    `declared_part ++ extra_part` — admits undeclared); `runtime.ex:160,301-307`
    (`instance_set_gate` → `effective_set`).
  - Install mechanism: `kind.ex:535,561` (`mount`/`detach`), `mount_detach.ex:72,
    101` (slice-init + closure + teardown), `kind.ex:879` (`attach_behavior`
    retired).
  - Config-as-data substrate: `role.ex:46-66` (`%Role{}` recipe shape +
    `session_template` ref); `role_registry.ex:3-29` (role→recipe via
    `ConfigStore`, key `"role"`); `config_object.ex:14-23`
    (`{workspace_uri,subject_uri,key,body}`); `config_store.ex`.
  - Kanban precedent: `ezagent_plugin_kanban/application.ex:64` (`roles/0` +
    `kanban_manager_recipe`, `passive: true`); `agent.ex:97-112` (Entity.Agent
    declares NO kanban); `behavior/kanban.ex:241`; `kanban-as-role-spec.md` +
    `role-foundation-design.md` (§4 hard-constraint RELAXED on landing).
  - Hardcoded behavior-set choice: `session_creator.ex:338,430`
    (`chat_behaviors`); `hello/app.ex:35` (`socialware_behaviors`).
- Synthesized from: `docs/socialware-operator-analysis`,
  `docs/socialware-template-model`, `docs/comms-pr34-spec`,
  `docs/domain-role-research`.
- Live contract: `adapter.ex:167-377` (`@callback`: `adapter_kind/0`,
  `render_authorized/2`, `live_topics/1`, `delivery_discipline/0`,
  `participation_profile/0`).
- `public_view` parity: `session_template.ex:757-764`, `public_view.ex:38,108`,
  `anon_user.ex:99-154`, `membership.ex:371,801`, `app.ex:31,35`,
  `workspace_plugin_actions.ex:326`, `chat_feed_controller.ex:108`,
  `external_feed_controller.ex:131`, `workspace_plugin_data.ex:189,211`.
- Reconciliation: #1047/#1060 (`comms_substrate_elimination_test.exs`), #1048
  (role-as-data), #1059 (`recipe_responsibility_lockin_test.exs`), #46.
