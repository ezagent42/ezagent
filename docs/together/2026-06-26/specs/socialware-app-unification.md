# SPEC — Socialware 收口: a first-class "Socialware app" definition (config-as-data)

> **Status: DESIGN (design + PHASED plan, NOT implementation).** Read-only basis;
> no code changed by this SPEC. Skills loaded: `ezagent-developer`,
> `ezagent-socialware`. All code citations verified against `origin/main`
> (`67b49303`). Worktree off `origin/main`; branch `docs/socialware-app-unification`.
> Codex adversarial-review record in §10.
>
> **This SPEC synthesizes three prior read-only analyses** (all on their own
> `docs/*` branches) into ONE coherent model + a landable phased plan:
> - operator composability — `docs/socialware-operator-analysis` (C1/C2/C3 de-bake)
> - template→data→instance — `docs/socialware-template-model` (the editor gap)
> - comms PR-3/PR-4 — `docs/comms-pr34-spec` (AnonIngress + world-on-contract)
>
> Plus the merged substrate (#1047 comms-unify, #1060 participation gates), the
> role-as-data direction (#1048), and the recipe/responsibility split (#1059).

---

## 0. TL;DR — the lead-decided model in one paragraph

A **socialware app is a named, first-class definition** `socialware://<name>`,
stored as **config-as-data** (the same substrate role-as-data #1048 uses — a Kind
snapshot / `ConfigObject`, NOT a new Kind hierarchy). It **bundles three things
that already exist** — a `template_ref` (a `SessionTemplate` version: the team /
routing / persona / legends recipe), the set of **`ExternalMirror.Adapter`s it
exposes** (the customer channels: a `:pull` web feed, a `:push` Feishu/Slack
mirror), and a small **config** block (publish policy, anon access). Two genuinely
**new** things make this a simplification rather than a new layer: (1) an
**explicit `belongs_to: socialware://<name>` marker** on the bound template /
session / surface that **replaces the implicit `public_view: true` boolean** as
the "this is a socialware app" identity; and (2) **"which external channels" becomes
DATA** (the adapter set) instead of today's hardcoded route proliferation
(`/socialware/chat` + `/socialware/external` are always-on, by code, for every
`public_view` session). The same definition is editable by **two paths that mutate
one source of truth** — a declarative world **form** and the in-session
**orchestrator conversation loop**. The autoservice "operator" residue de-bakes in
three moves (C1 rename the persisted `:operator_only` enum → `:internal`; C2 lift
the auto-publish default into the app's config; C3 name the operator cap-bundle a
`supervisor` **responsibility**). The anonymous customer entry folds in as comms
PR-3's `admit_anonymous_participant` domain primitive + thin web shim. Comms PR-4
(world-on-contract-axis) is **superseded** here — its one load-bearing piece (a
named operator-authz predicate) re-homes onto C3's `supervisor` cap.

**Zero new redundant concepts.** The only genuinely NEW objects are the
`socialware://<name>` definition, the `belongs_to` marker, and the world form
editor. Everything else is REUSED: `SessionTemplate`, `ExternalMirror.Adapter`
(`:push`/`:pull`), `ConfigStore`/`ConfigObject`, `App.ensure_app`, `AnonUser`/
`AnonBinding`, the `SessionFeedChannel` substrate, the `:claim`/`:settle`/`:approve`
behavior verbs.

---

## 1. The problem this 收口 closes

Socialware today is **structurally real but conceptually scattered**. Three
independent analyses each found the same shape from a different angle:

1. **There is no app object.** "A socialware app" is encoded as a magic boolean
   `public_view: true` buried in `SessionTemplate` content
   (`session_template.ex:757-764`), read back by `PublicView.public_view?/1`
   (`public_view.ex:38`). That boolean silently does **two unrelated jobs**
   (identity + the anon gate) and has **hardcoded consequences**: every
   `public_view` session auto-serves *both* the chat feed and the external page,
   by route code, with no data saying "this app exposes these channels."

2. **The channel set is hardcoded, not data.** `/socialware/chat`
   (`ChatFeedController`) and `/socialware/external` (`ExternalFeedController`)
   are two always-on routes (`router.ex:118,137`). Adding Slack/Feishu as a
   customer channel means adding more route code. The merged comms-unify (#1047)
   already proved these surfaces are **two `ExternalMirror.Adapter`s over one
   `SessionFeedChannel`** — so "which channels" *wants* to be an adapter list,
   but nothing holds that list.

3. **The editor is half-built.** The world form can only author name +
   description + the `public_view` checkbox; it **hardcodes `members: []`,
   `routing_rules: []`, `prompt_templates: %{}`, `legends: %{}`**
   (`workspace_plugin_actions.ex:326`). The rich definition is authorable ONLY by
   running a session and driving the orchestrator agent. There are two authoring
   paths but they do not converge on one definition.

4. **The "operator" naming residue.** The operator analysis proved "operator" is
   already *composed* (no Kind/role/cap) — the only residue is a persisted enum
   name leak (`:operator_only`) and one hardcoded default (auto-publish).

The 收口: give socialware **one named definition object** that (a) makes the
identity explicit, (b) makes the channel set data, (c) is the single thing both
editors mutate, and (d) carries the config that the de-baked operator policy
reads — while reusing every existing primitive underneath.

---

## 2. The unified model — the Socialware-app definition

### 2.1 Shape

```
socialware://<name>                         # first-class named definition (config-as-data)
├── template_ref : template://session/<ws>/<name>@<hash>   # REUSE: SessionTemplate version
│     └── (team / members / routing_rules / prompt_templates / legends / orchestrator_template_uri)
├── adapters : [%{adapter_id, role: :customer|:operator, config}]   # REUSE: ExternalMirror.Adapter set
│     ├── "web_feed"     :pull   (chat discipline + page discipline; the SPA shell — "hello" renders here)
│     ├── "feishu_mirror":push   (a customer channel via Feishu)   [optional]
│     └── "slack_mirror" :push   (a customer channel via Slack)    [optional]
└── config : %{
      publish_policy : :auto | :supervised,   # C2 — lifts the hardcoded turn.ex default
      web_anon_access : boolean,              # the anon gate (job (b) of old public_view)
      supervisor_responsibility : "supervisor" | nil   # C3 — names the operator cap-bundle
    }
```

The definition is **content-addressed and versioned** exactly like
`SessionTemplate` (SHA-256 over the deterministic content; editing mints a new
version), so it inherits the immutable/forkable/role-as-data discipline already
proven in `compute_version_hash/1`.

### 2.2 Why this is a simplification, not another layer (codex Q1)

The obvious attack: *"you already have `SessionTemplate` — just put `name` +
`adapters[]` on its content and skip the new object."* That collapse is **wrong**
because the app and the template are **genuinely different cardinalities and
lifetimes** — three concrete divergences, not hand-waving:

1. **One template, many apps (channel/policy fan-out).** The team+routing recipe
   ("a customer-support room with an orchestrator + a knowledge-base member") is
   one `SessionTemplate`. It can back a **web-only auto-publish app** AND a
   **Feishu-mirrored supervised app** simultaneously — same room recipe, different
   `adapters` + `publish_policy`. If `adapters`/`policy` lived on the template,
   you'd fork the *whole* team recipe just to change a channel — a content-hash
   churn that loses the "same room" identity.

2. **The app outlives template versions.** `socialware://support` is a stable
   customer-facing identity; its `template_ref` is re-pointed across template
   `@hash` versions as the room recipe evolves (exactly the `template_working_copy`
   re-point that already exists). A name on the template content would be reborn
   with every version hash — the app identity would not survive its own edits.

3. **The marker is a pointer, not duplicated data.** `belongs_to:
   socialware://<name>` is a *reference* set on the session/template/surface (like
   `template_working_copy.session_template_uri` already is), so the app object is
   referenced, never copied. Folding it into template content would re-duplicate
   it per version.

**Honest caveat (raised as OQ-1, not buried):** if in practice every app maps
1:1:1 to a single template version with one fixed channel set forever, the object
*is* redundant with template content and should instead be 2-3 new content keys on
`SessionTemplate`. The divergences above are the test; the lead's decision is the
distinct object, and §11/OQ-1 puts the redundancy question to codex + lead
explicitly rather than asserting it settled.

### 2.3 The marker REPLACES `public_view` — and it is a SPLIT, not a flat rename

`public_view: true` does **two jobs** today; the unification splits them onto two
different homes. This split (not a 1:1 rename) is the load-bearing correctness
claim, so here is the **parity audit** — every `public_view` read/write site on
`origin/main` mapped to its new home:

| # | Site (`origin/main`) | Job today | New home |
|---|---|---|---|
| 1 | `session_template.ex:757-764` — `:public_view` in `@config_atom_keys` | (a) identity schema key | **marker** `belongs_to: socialware://<name>` on the template/session (pointer); `:public_view` key removed from template schema |
| 2 | `public_view.ex:38,108` — `PublicView.public_view?/1` gate | (b) anon-access gate | **web adapter attribute** `web_anon_access` — `public_view?/1` becomes "resolve session→marker→app→web adapter; does it permit anon?" |
| 3 | `anon_user.ex:120` — `mint_for_public_session` calls `public_view?/1` | (b) gate before minting | re-points to (2): the web-adapter anon attribute via the same resolver |
| 4 | `anon_user.ex:99-154` — `public_view_granter/1` (= session owner) | cap granter (#154) | **unchanged** — anon's `:join` cap is still `granted_by` the session owner |
| 5 | `membership.ex:371,801,818` — `public_view` open-join doc/granter | (b) anon path | re-points to (2) — same resolver |
| 6 | `app.ex:31` (hello) — writes `public_view: true` | (a)+(b) at create | hello's `App.ensure_app` declares `socialware://hello-<n>` with the `web_feed` adapter (`web_anon_access: true`) + sets the marker |
| 7 | `workspace_plugin_actions.ex:326` — world toggle writes `public_view` | (a)+(b) authored | the form (§5) authors the app: marker + `web_feed` adapter w/ anon |

**Therefore `public_view?/1` does NOT become "is there a marker?".** Identity =
marker; anon-gate = web-adapter attribute. PR-3's anon ingress (§5.1) must wire its
gate to the **web-adapter attribute**, not the marker — stating it as a flat
rename would mis-wire the gate. The enforcement gate for this phase (§7 P3) is a
test that **no `public_view` boolean is read anywhere** and both jobs resolve via
the new homes.

### 2.4 The external-channel unification — `ExternalMirror.Adapter`, and "hello"

The **external channel IS `Ezagent.ExternalMirror.Adapter`** — there is **no new
"vertical" concept**. The contract on `origin/main` (verified against the live
`@callback` block, `adapter.ex:167-377`, not the stale moduledoc prose) already
has the exact axis we need:

- **`adapter_kind/0`** ∈ `:push | :pull | :request_scoped` (optional, default
  `:push`).
- A **`:push`** adapter (Feishu mirror today; Slack future) has a paired
  `Binding` GenServer owning the external transport — `binding_module/0`,
  `cap_subject/0`, `target_ownership_check/2`, `event_to_payload/1`.
- A **`:pull`** adapter (the socialware customer feed) is served on demand by the
  caller's Phoenix channel — `render_authorized/2` + `live_topics/1` +
  `delivery_discipline/0` (`:snapshot_refresh | :cursor_replay`) +
  `participation_profile/0` (`:read_only | :participatory`), with optional
  `join_with_cursor/2`, `replay/3`, and `post/3`/`join/2`/`history/2` for
  participatory writes (legacy `render/2` still accepted).

So the app's `adapters` list is **literally a list of `ExternalMirror.Adapter`
ids + per-adapter config**. The merged comms-unify (#1047) already collapsed the
two browser surfaces onto one `SessionFeedChannel` parameterized by
`delivery_discipline/0` + `participation_profile/0`, and
`comms_substrate_elimination_test.exs` asserts only `SessionFeedChannel` survives.
The unification is therefore: **the channel set the app exposes = its
`ExternalMirror.Adapter` set; the two browser disciplines (chat = visibility-only
live; page = visibility + settlement-committed) are two configs of one `:pull`
web adapter; Feishu/Slack customer channels are `:push` adapters in the same
list.**

**"hello" is the web adapter's page shell, NOT a new concept — kept precise.**
Per the template analysis's own conclusion *"definition = data; vertical mechanism
= code."* The **external channel** is the `:pull` web adapter (the customer feed).
**hello** is the **page-builder behavior** behind one such surface — its
`HelloBuilder` agent, `@json-render` `Spec` validator, `TurnDriver`, and renderer
island are **code** (`ezagent_plugin_hello`), referenced/configured by the app
definition (a `members` entry naming the builder), not dissolved into data. So
"hello-as-web-adapter-shell" means: the **SPA shell the `:pull` web adapter
renders** is the page; hello is the agent that *fills* that page. hello does not
become a data row; it remains the wired example of a page-builder member behind
the generic web adapter. (`PageView.applies_to?/1` filtering on `:hello` +
readable `:surface` is the render-target dispatch, unchanged.)

### 2.5 Where the definition lives (data geography — confirming #46/EZAGENT_HOME)

The lead's split is correct and this SPEC keeps it: **`EZAGENT_HOME` holds agent
RUNTIME state** (credentials, per-agent config, logs — `home.ex`, `repo.ex:6-12`);
the **socialware DEFINITION data stays in its data store** — Postgres
`kind_snapshots` (the content-addressed versioned object) + `ConfigStore`/
`ConfigObject` for the live config cascade (`config_store.ex`,
`config_object.ex:16-20`). The `socialware://<name>` object is a Kind snapshot like
`SessionTemplate`; its `config` block (publish_policy, web_anon_access) is the
role-as-data `ConfigObject` cascade (workspace > user > session). **Nothing moves
to `EZAGENT_HOME`.** This SPEC introduces no new substrate — both data homes
already exist.

### 2.6 The operator de-bake folded into the definition (C1/C2/C3)

The operator analysis proved "operator" is already composed — the residue is
naming + one default. The unification gives each residue a home in the new model:

- **C1 — rename `:operator_only` → `:internal`** (the persisted `Message.visibility`
  enum, `message.ex:73,119`). Pure name finish of the #1037 `:customer_*`→
  `:external_*` symmetry; the binary is external-vs-internal. **Independent of the
  app object** — it is just a value rename + data migration. (Detail in §6.)
- **C2 — lift the auto-publish-vs-hold default** out of the hardcoded
  `Turn.handle_open` (`turn.ex:246`, `initial_visibility/1` `:615`) **into the
  app's `config.publish_policy`** (`:auto | :supervised`). `:auto` preserves
  today's behavior; `:supervised` holds turn output `:internal` until `:settle`.
  This is the natural home the analysis said was missing — the app config is read
  at `handle_open`.
- **C3 — name the operator cap-bundle a `supervisor` responsibility.** The
  `{:claim, :settle, :approve, read-unfiltered}` bundle becomes a first-class
  **axis-B responsibility** (session membership `role_name` + cap bundle), exactly
  the recipe/responsibility split (#1059) §C3. Defer until a consumer needs the
  named handle — and the natural consumer is **the editor's operator surface +
  the superseded PR-4 authz predicate** (§5.2). Keep per-message visibility as a
  real revocation primitive (`external_feed.ex:293`), rename only.

---

## 3. What is REUSED vs what is genuinely NEW

| Piece | Reused / New | Note |
|---|---|---|
| `Ezagent.Entity.SessionTemplate` | **REUSE** | the `template_ref` — team/routing/persona/legends recipe |
| `Ezagent.ExternalMirror.Adapter` (`:push`/`:pull`) | **REUSE** | the `adapters` list = adapter ids + config |
| `SessionFeedChannel` substrate (#1047) | **REUSE** | the live transport for `:pull` adapters |
| `ConfigStore` / `ConfigObject` (#1048) | **REUSE** | the `config` cascade (publish_policy, anon) |
| `App.ensure_app` (hello) | **REUSE** | the instantiate flow; gains an app-def step |
| `AnonUser` / `AnonBinding` / `public_view_granter` | **REUSE** | anon identity + cap granter (#154), unchanged |
| `:claim` / `:settle` / `:approve` verbs + caps | **REUSE** | the takeover machine, already generic |
| per-message `visibility` enum | **REUSE (rename only)** | revocation lever; `:operator_only`→`:internal` |
| **`socialware://<name>` definition object** | **NEW** | the named bundle (template_ref + adapters + config) |
| **`belongs_to: socialware://<name>` marker** | **NEW** | explicit identity, replaces `public_view` boolean (job a) |
| **the world form editor** (full-template + adapter picker) | **NEW** | closes the editor gap; one of two paths onto the def |
| `admit_anonymous_participant` primitive + `AnonIngress` shim | **NEW (= comms PR-3)** | folded in (§5.1) |
| `supervisor` responsibility + cap-bundle | **NEW (= C3, deferred)** | names the operator authority; re-homes PR-4 §6.6 |

---

## 4. The dual-path editor (one source of truth)

The lead decided **both** paths, mutating **one** definition:

- **Path A — declarative world FORM.** The form fills the **full** definition:
  the `template_ref` content (members / routing_rules / prompt_templates /
  legends — closing the `workspace_plugin_actions.ex:326` hardcoded-empty gap)
  **plus** the adapter picker (which `ExternalMirror.Adapter`s the app exposes)
  **plus** the config block (publish_policy, web_anon_access). Dispatches to the
  same write path that mints a new app-def version.
- **Path B — in-session orchestrator conversation loop.** The orchestrator tools
  (`add_managed_member`, `define_rule_set_rule`, `define_prompt_template`,
  `define_legend`, `update_template`/`save_template_as`) already mutate the
  template content; the unification extends `save_template_as`/`update_template`
  to also re-point the `socialware://<name>` `template_ref` and (new) set adapters
  / config, so the conversational edits land on the **same** definition the form
  edits.

**One source of truth:** both paths terminate at the same content-addressed
write (`persist_version_as_system`-style) on `socialware://<name>` and its
`template_ref`. The form is a projection of the same semantics the orchestrator
tools express; neither owns a private copy. The "current" tag must be published
on author-save (the skill gotcha #3 / template analysis S-item) so name-based
adopt-on-create is deterministic.

---

## 5. Subsuming comms PR-3 (folded) and PR-4 (superseded)

### 5.1 PR-3 (AnonIngress) — FOLDED IN as the customer's entry to the web adapter

The anonymous customer reaching a socialware app's external surface **is** comms
PR-3: the `Ezagent.Socialware.AnonAdmission.admit_anonymous_participant/2` domain
primitive (owns mint→spawn→join-AS-anon→mount-caps; INV-1 no system principal,
INV-2 caps best-effort, INV-2a fail-closed reuse) + the thin
`EzagentWeb.Socialware.AnonIngress` web shim (cookie/token/conn only). In the
unified model this is *"how a customer reaches the app's `:pull` web adapter."*
Two adjustments fold cleanly:

- The primitive's `public_view?/1` gate (§3.2 of PR-3 spec) re-points to the
  **web-adapter `web_anon_access` attribute** (§2.3 site #3), via the same
  session→marker→app→adapter resolver. **This is the one cross-phase edge:** PR-3
  reads the anon gate, so it re-points when the marker/web-adapter-attribute lands
  (§7 dep-DAG).
- Placement is unchanged and still forced by the DAG: the primitive lives in
  **`ezagent_domain_socialware`** (it needs `AnonUser`/`AnonBinding` local +
  `Membership` (session ↓) + `Entity`/`Invocation` (core ↓); session does not dep
  socialware, so it cannot host it). **This is the same reasoning that forces the
  app-object resolver into socialware** (§7).

### 5.2 PR-4 (world Conversation onto contract axis) — SUPERSEDED, with its fix re-homed

PR-4's world-on-contract-axis convergence (rebuild `WorldLive`'s read as a
`ConversationFeedAdapter` `:pull` impl) is an **internal transport cleanup** that
the operator-debake + editor **reframe and largely subsume**: the world operator
console becomes the editor's operator/author surface, and the "operator
projection" is just the `supervisor` responsibility's unfiltered read. So PR-4 as
a standalone work item is **superseded** — BUT it must not silently drop its one
load-bearing, security-critical finding:

> **PR-4 §4.3a / OQ §6.6 (codex HIGH):** the unfiltered operator projection
> (`recent_in_session`, includes `:operator_only`/`:internal`) behind
> `/sessions` (`RequireEntity` only, no `require_admin`) **leaks internal
> messages to any authenticated workspace user** unless a concrete operator-authz
> predicate gates it, fail-closed, re-checked on read.

**This fix re-homes onto C3:** the **`supervisor` responsibility + cap-bundle IS
the operator-authz predicate PR-4 could not name.** `ConversationFeedAdapter.
render_authorized/2` (or whatever serves the operator unfiltered read) checks the
`supervisor` cap fail-closed. Thus superseding PR-4 is **safe only when C3
lands** — C3 is the migration target for PR-4's disclosure-bug fix, not an
optional cosmetic. This linkage is recorded in the phase plan (§7 P6) and is a
gate on calling the operator surface done.

---

## 6. C1 detail — the persisted-enum rename (the pre-prod-now move)

`Message.visibility :: :external_visible | :operator_only` → `:internal`
(`message.ex:73,119`, Ecto.Enum, default `:external_visible`). It is a **persisted
enum value** stored as a string in the DB — doing it *after* prod is a live data
migration over real message history; doing it *now* is a dev-only `db.reset`. That
asymmetry is the entire reason C1 is **pre-prod-now**.

- **Touches (~15-18 files, from the operator analysis §3):** `message.ex` (enum +
  typespec + default doc); `message_store.ex` (`mark_visibility`,
  `chat_visible_recent`, `committed_external_visible*`); `turn.ex`
  (`hold_visibility`, `initial_visibility`); `settlement.ex` (`flip_visibility`/
  `hold_visibility`); `chat_feed.ex` (`external_visible?/1`), `external_feed.ex`
  (docs); the two migrations carrying the stored string
  (`…20260618000400_…visibility…` + `…pg_baseline`); ~6-9 test files; and the
  invariant.
- **Data migration:** `UPDATE messages SET visibility='internal' WHERE
  visibility='operator_only'` + a fail-closed default. Dev: `db.reset`.
- **Do it atomically, NOT in parallel** — the weekend log shows rename-collisions
  across parallel branches are the top regression source.
- **Ride the #1059 deferred `Role`→`Recipe` symbol-rename window** (one
  collision-audit, one rename PR) per the recipe/responsibility split — both are
  "deferred symbol renames."

---

## 7. The phased plan — dep-DAG, blast radius, per-phase gate

Each phase is **independently landable + verifiable**. Blast radius S/M/L. The
DAG edges (which phase must precede which) are stated; "independent" phases share
no file.

```
        P1 (C1 enum rename) ──────────────┐  (independent; pre-prod critical)
                                          │
        P2 (PR-3 AnonIngress) ──┐         │  (independent refactor)
                                │         │
        P3 (app-object + marker)│◄────────┘  needs nothing; foundational
             │  └─ re-points P2's anon gate (edge: P2→P3 if P2 first, else P3 ships gate)
             ▼
        P4 (C2 publish_policy in app config)   needs P3 (config home)
             │
             ▼
        P5 (dual-path FORM editor)             needs P3 (picks adapters vs the app object)
             │
             ▼
        P6 (C3 supervisor responsibility + relabel; re-homes PR-4 fix)  defer; ride #1059
```

| Phase | What | Blast | Pre-prod? | Independent gate (verifiable) |
|---|---|---|---|---|
| **P1 — C1** | rename `:operator_only`→`:internal` + data-migrate + invariant | **M** | **NOW (persisted enum)** | extend `no_customer_concept_test` to also forbid `:operator_only`; full `mix test` 0 failures |
| **P2 — PR-3** | `admit_anonymous_participant` primitive + `AnonIngress` shim; collapse +8 dup groups | **M** | any time (pure refactor) | the +8 `cross_file_duplicate_fn_groups` collapse to one primitive + one shim; INV-1/2/2a tests; #1060 Gate 2 stays green |
| **P3 — app object + marker** | `socialware://<name>` def object; `belongs_to` marker; split `public_view` per §2.3 parity table | **L** | NOW (no prod data) | a gate that **no `public_view` boolean is read** anywhere; identity resolves via marker, anon-gate via web-adapter attr; hello `App.ensure_app` migrated |
| **P4 — C2** | lift auto/hold default into `config.publish_policy`; `handle_open` reads it | **S** | NOW | `:auto` preserves today; new test: a `:supervised` turn stays `:internal` until `:settle` |
| **P5 — FORM editor** | world form fills full template + adapter picker + config; converge with orchestrator loop on one def | **M** | NOW | form authors a non-empty `members`/`routing_rules`/`prompt_templates`/`legends` + adapter set; round-trips with `save_template_as`; "current" tag published on save |
| **P6 — C3 (defer)** | `supervisor` responsibility + cap-bundle; relabel `operator_tree`/"Operator SessionView"→internal; **re-home PR-4 §6.6 authz fix** | **S-M** | defer; ride #1059 | operator unfiltered read gated by `supervisor` cap fail-closed (the PR-4 disclosure-bug gate); relabel-only elsewhere |

**Recommended order:** P1 (cheapest, pre-prod-critical) → P2 (independent, smaller)
→ P3 (foundational L) → P4 → P5 → P6. P1 and P2 can land in parallel with each
other (no shared file); both precede the rest only by convenience, not dependency.

### 7.1 Cross-phase couplings (the edges that break "fully independent")

- **P2 → P3 (anon gate):** PR-3's `admit_anonymous_participant` reads the anon
  gate. If P2 lands first, it reads `public_view?/1` as-is and **re-points to the
  web-adapter `web_anon_access` attribute when P3 lands** (a one-line resolver
  swap inside the primitive — the primitive is the single chokepoint, which is
  *why* PR-3 is worth doing first). If P3 lands first, P2 wires straight to the
  attribute.
- **P4 → P3 (config home):** C2's `publish_policy` is cleanest as the app
  `config` block, so P4 follows P3. It *could* ship earlier as a bare
  session-content key, but that would be throwaway — not recommended.
- **P5 → P3 (adapter picker):** the form picks adapters *against* the app object's
  adapter list, so P5 needs P3.
- **P6 → PR-4 fix:** superseding PR-4 is safe only once C3 provides the
  `supervisor` authz predicate (§5.2).

### 7.2 Dep-DAG legality (zero new app edge)

Hosting `socialware://<name>` resolution needs `template_ref` (session ↓),
`adapters` (external_mirror ↓), and `config` (`ConfigStore` in identity ↓).
Reading the in-umbrella deps (`origin/main` `mix.exs`):
`socialware → core, identity, session, external_mirror, ui`. **session, identity,
external_mirror do NOT dep socialware.** Therefore **socialware is the only legal
host** for the app-object resolver — the same forced placement PR-3 used for the
anon primitive. No new app edge: socialware already deps every app the resolver
reaches. The acyclic gate (`im_session_agent_acyclic_test.exs`) and the
undeclared-dep gate (`undeclared_umbrella_dep_test.exs`) stay green; #1060 Gate 1
(participation writes) and Gate 2 (web→external_mirror IoC) are untouched by P1-P5
(P6's operator read honors them as PR-4 specified).

---

## 8. Reconciliation with role-as-data / recipe-responsibility / comms-unify

- **role-as-data (#1048).** The app definition IS config-as-data — same Kind
  snapshot + `ConfigObject` cascade as roles. `config.publish_policy` /
  `web_anon_access` are `ConfigObject` data (workspace > user > session), not code
  policy. No new substrate; the app object rides the exact mechanism #1048 built.
- **recipe/responsibility split (#1059).** C3's `supervisor` is **axis B — a
  responsibility** (session membership `role_name` + a cap bundle), never an axis-A
  recipe; the split proved the axes are independent and unforced
  (`recipe_responsibility_lockin_test.exs`). C1's enum rename rides #1059's
  deferred symbol-rename window (one collision-audit). The `template_ref` carries
  recipe-side config (members may name agents with recipes); the app object adds
  no recipe concept.
- **comms-unify (#1047) / #1060.** The app's `adapters` list = the
  `ExternalMirror.Adapter` set already unified on `SessionFeedChannel`; the two
  browser disciplines are `delivery_discipline/0` configs of the `:pull` web
  adapter. #1060's participation-profile routing (writes keyed by
  `participation_profile/0`, not `adapter_id`) is preserved — the app object only
  *names* which adapters; it does not re-open the channel logic (PR-4's N1).

---

## 9. Codex adversarial-review verdict

> _(To be filled by the codex companion run; this SPEC ships with the static
> review folded. Codex prompt: is the `socialware://<name>` object a real
> simplification or another layer? does the marker cleanly replace `public_view`
> without breakage — given the §2.3 split? is the phasing safe, esp P1's
> persisted-enum rename pre-prod? does it reuse existing concepts or sneak in new
> ones? does AnonIngress fold cleanly, and is superseding PR-4 safe (the §5.2
> disclosure-fix re-home)?)_

---

## 10. Open questions for the lead

1. **App object vs template content (the §2.2 redundancy test).** The three
   divergences (one-template-many-apps, app-outlives-template-versions,
   marker-as-pointer) justify the distinct object. **If the lead's intent is
   strictly 1:1:1 (one app = one template version = one fixed channel set),** the
   object is redundant and should instead be 2-3 new content keys on
   `SessionTemplate`. Confirm the fan-out cases are real (recommend: distinct
   object, as decided).
2. **C1 rename target — `:internal` vs `:backstage`?** Recommend `:internal` for
   the external/internal symmetry (operator analysis OQ-1).
3. **`web_anon_access` granularity.** The split (§2.3) puts the anon gate on the
   web adapter. If a future app wants *some* `:pull` surfaces anon and others
   login-only, this is per-adapter already — confirm anon is a web-adapter
   attribute (recommended) not an app-global flag.
4. **Binary visibility horizon (operator analysis §1d).** Multiple external
   adapters share one `external_visible` slice today. If two customer channels
   ever need *different* curations of the same session, binary visibility →
   audience-set is a real generalization (M→L) that should precede prod. Near-term
   need? (Recommend: keep binary, YAGNI; the app object makes the future
   generalization a per-adapter projection, not a redesign.)
5. **C3 timing.** P6 is deferred — but it re-homes PR-4's disclosure-bug fix
   (§5.2). Is the operator/author surface (and thus the `supervisor` authz
   predicate) in scope pre-prod, or is raw-dispatch + route-guard acceptable until
   then? (Recommend: land C3 with the editor's operator surface P5/P6, since the
   unfiltered operator read otherwise leaks `:internal` content.)
6. **Editor convergence depth.** Path A (form) and Path B (orchestrator loop) both
   mutate the def. Confirm the form is a thin projection of the orchestrator-tool
   semantics (recommended) rather than a parallel write path that could drift.

---

## Method / provenance

- All reads via `git show origin/main:<path>` (`67b49303`) — no working-tree trust.
- Synthesized from: `docs/socialware-operator-analysis` (operator C1/C2/C3 +
  blast radius), `docs/socialware-template-model` (template→data→instance + editor
  gap), `docs/comms-pr34-spec` (PR-3 AnonIngress + PR-4 world-on-contract).
- Live contract: `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/
  adapter.ex:167-377` (the `@callback` block: `adapter_kind/0`,
  `render_authorized/2`, `live_topics/1`, `delivery_discipline/0`,
  `participation_profile/0`).
- `public_view` parity audit: `session_template.ex:757-764`, `public_view.ex:38,108`,
  `anon_user.ex:99-154`, `membership.ex:371,801`, `app.ex:31`,
  `workspace_plugin_actions.ex:326`.
- Reconciliation: role-foundation-design (`docs/together/2026-06-25/specs/`),
  recipe-responsibility-split (`docs/recipe-responsibility-split`),
  comms substrate (`comms_substrate_elimination_test.exs`, #1047/#1060).
</content>
</invoke>
