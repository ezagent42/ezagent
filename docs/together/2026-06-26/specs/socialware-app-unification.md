# SPEC — Socialware 收口: a first-class "Socialware app" definition (config-as-data)

> **Status: DESIGN (design + PHASED plan, NOT implementation).** Read-only basis;
> no code changed by this SPEC. Skills loaded: `ezagent-developer`,
> `ezagent-socialware`. All code citations verified against `origin/main`
> (`67b49303`). Worktree off `origin/main`; branch `docs/socialware-app-unification`.
> Codex adversarial-review record in §9.
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
`supervisor` **responsibility**). **The SPEC 收口s BOTH axes of the `role`
homonym:** recipe (axis A — "what an agent is built from", mostly done via #1048
role-as-data, decoupling locked by #1059) AND **responsibility** (axis B — "what
function a principal serves in a session", §2.7): the app's members **carry**
responsibilities (`role_name`s) that the editor **assigns**; the supervisor/takeover
flow IS responsibility-in-action — a B1 single-holder name (C3) that scales to a
**B2 multi-holder pool** with claim/approve/escalate/arbiter routing (the autosvc
human-takeover loop the interface inventory found has *no product surface*). The
anonymous customer entry folds in as comms PR-3's `admit_anonymous_participant`
domain primitive + thin web shim. Comms PR-4 (world-on-contract-axis) is
**superseded** here — its one load-bearing piece (a named operator-authz predicate)
re-homes onto C3's `supervisor` cap.

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

5. **The responsibility/takeover layer is implicit and surface-less.** Members
   carry an undocumented `role_name` (B1); the operator takeover verbs
   (`:claim`/`:settle`/`:approve`) exist but have **no product surface** (reachable
   only by raw `mix ezagent` dispatch — operator analysis §5); and a *multi-holder*
   supervisor pool with conflict arbitration is *not expressible at all* (B1's
   `role_name` is unique per session). The domain-role research designed this as B2;
   the socialware takeover flow is its first real consumer.

The 收口: give socialware **one named definition object** that (a) makes the
identity explicit, (b) makes the channel set data, (c) is the single thing both
editors mutate, (d) carries the config that the de-baked operator policy reads, and
(e) **declares its responsibilities** (members' B1 `role_name`s + B2 supervisor
pool) so the takeover loop becomes first-class responsibility-routing — while
reusing every existing primitive underneath.

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
distinct object, and §10/OQ-1 puts the redundancy question to codex + lead
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
| 7 | `workspace_plugin_actions.ex:334` — world toggle writes `public_view` | (a)+(b) authored | the form (§5) authors the app: marker + `web_feed` adapter w/ anon |
| 8 | `chat_feed_controller.ex:108` + `external_feed_controller.ex:131` — the two public controllers call `PublicView.public_view?/1` as their ingress gate | (b) per-route anon gate | re-point to (2). **In P2 these collapse into the `AnonIngress` shim (§5.1), so the re-point is in ONE chokepoint, not two route bodies** — the reason P2-before-P3 is cheaper |
| 9 | `workspace_plugin_data.ex:189,211,256-258` — world read-model `public_view?/1` helper (renders the "Public socialware app" badge in the template panel) | (a) identity, read for DISPLAY | reads the **marker** (is the template/app bound to a `socialware://<name>`?), not the boolean |

**Codex Q2 fix (was OVERCLAIM):** rows 8-9 were added after codex flagged the
table as incomplete — it missed the two controller gate call sites and the world
read-model display helper. With them, the audit is complete: every `public_view`
read/write on `origin/main` maps to *either* the marker (identity: rows 1, 9; +
the author-writes 6, 7) *or* the web-adapter `web_anon_access` attribute (anon
gate: rows 2, 3, 5, 8). Row 4 (the cap granter) is unchanged. (Non-prod sites —
test fixtures `*_test.exs`, `router.ex` comments, the `autoservice_tier1_seed.exs`
script, `hello/template/hello_session.ex` doc — track the same two homes and are
not load-bearing.)

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
  the recipe/responsibility split (#1059) §C3. **C3 is the entry point to the full
  responsibility & routing layer — the supervisor/takeover flow is
  responsibility-in-action (a B2 multi-holder pool), designed in full in §2.7.**
  Keep per-message visibility as a real revocation primitive
  (`external_feed.ex:293`), rename only.

---

### 2.7 The responsibility & routing layer — B1/B2, and the takeover loop

A socialware app is not only a template + channels: it is a set of **principals
each serving a responsibility** (a function in the session). This is the SPEC's
second 收口 axis — alongside recipe (axis A, mostly done via #1048/#1059),
**responsibility (axis B)** is folded in here as the model's routing layer. The
autosvc **operator/supervisor takeover flow IS responsibility-in-action** — it is
exactly the **B2** the domain-role research designed
(`docs/domain-role-research:…/role-for-users-domain-role.md`). C3 above is its
single-holder entry point; the multi-holder pool + takeover loop is this section.

**The two axes, stated once (research §1, #1059):**
- **recipe (A)** = "what an *agent* is built from" — skills/prompt/behaviors/
  `requested_caps`/`config_dir` contents. **Build-time, agent-only** (the recipe
  shape *cannot* describe a human — research §2).
- **responsibility (B)** = "what *function a principal* (user OR agent) serves in a
  session" — a `role_name` + routing `{:role, name}` + standing caps. **Runtime,
  cross-principal.**

In the app, a member may be an agent **built from** the `bot` recipe **carrying**
the `bot` responsibility — but the two names need not match (#1059: no structural
forcing, `recipe_responsibility_lockin_test.exs`). The `supervisor` responsibility
is held by **humans**, who have no recipe at all. The editor (§4) **assigns
responsibilities**; it never conflates them with recipes.

#### 2.7.1 How a socialware app declares its responsibilities (in the definition)

The definition declares responsibility names as **data** — the members carry B1
`role_name`s, and the `config` names which responsibilities are **B2 pools**:

```
template_ref.members : [%{uri, role_name: "orchestrator" | "bot" | "reviewer", ...}]   # B1 single-holder
config.responsibilities : [
  %{name: "bot",        kind: :b1_single},                # the agent member's session function
  %{name: "supervisor", kind: :b2_pool,                   # multi-holder HUMAN takeover pool
    caps: [:claim, :settle, :approve, :read_unfiltered],  # the operator cap-bundle (C3)
    quorum_policy: :any_one | :majority | :n_of_m,
    arbiter: "arbiter" | nil}
]
```

Names are data; **holders are assigned** — B1 holders by member `role_name` in the
`template_ref`; B2 pool holders by a **workspace-scoped assignment** (§2.7.4),
written by the editor.

#### 2.7.2 B1 vs B2 — when each is needed

| | **B1 (exists today)** | **B2 (new — the takeover pool)** |
|---|---|---|
| scope | per **session** | per **workspace** |
| holders | **single** (`role_name` unique per session, `role_name_conflict/3`) | **many** (a pool of N principals share responsibility R) |
| `{:role,name}` resolves to | exactly **one** URI | **fan-out** over all current holders |
| use in a socialware app | "the one orchestrator / the one bot / the one reviewer of THIS session" | "the **supervisor pool** watching ALL support sessions; any of N humans can take over; conflicting verdicts arbitrated" |

**The operator/supervisor takeover flow = B2.** It needs ≥2 holders of
`supervisor` (a pool) and quorum/arbiter on disagreement — *two disagreeing
holders cannot even exist under B1's unique-per-session invariant* (research §1.2),
so B2 is genuinely new state, not a B1 wrapper. A simple single-operator app can
stop at B1 (C3); a multi-operator autosvc desk needs B2.

#### 2.7.3 The takeover / approval / escalation loop as responsibility-routing

This is the autosvc human-takeover loop the interface inventory (operator analysis
§5) flagged has **NO product surface** today — the `:claim`/`:settle`/`:approve`
verbs are reachable only via raw `mix ezagent` dispatch. The loop **reuses the
existing generic verbs** (operator analysis §1e — already generic; "the human" is a
param, not a baked role) and expresses escalation as routing-by-responsibility:

1. **bot escalates** → a routing rule `{from: bot, on: <signal>} -> {:role,
   "supervisor"}` delivers to the **B2 pool** (fan-out across all current
   supervisors).
2. **a human supervisor claims** → dispatches `:claim` on the `Turn`
   (`turn.ex:49`, `handle_claim(%{by: by})` records the claimer as `owner` —
   `:320`); the turn → `mode: :copilot, status: :awaiting_human` and its output is
   **held `:internal`** (C1) until released.
3. **release** → `:settle` (flip the held messages to `:external_visible`) or
   `:approve` (advance the surface page pointer).
4. **conflicting verdicts** → the **B2 approval/quorum Behavior** (§2.7.4) collects
   verdicts from pool holders under `quorum_policy`; on conflict it **escalates to
   `{:role, "arbiter"}`** — recursion over the *same* fan-out + collect machinery,
   one level up.

So "operator takeover" is fully composed from: per-message visibility (the hold/
release lever, kept), the generic `:claim`/`:settle`/`:approve` verbs (kept), and
B2 responsibility-routing (new). No `operator` Kind/role/cap is introduced — the
operator analysis's "already-composed" verdict holds, now with the pool + quorum
that B1 lacked.

#### 2.7.4 Where the B2 machinery lives (dep-DAG, codex-corrected in the research)

Verified umbrella edges (`mix.exs`, `origin/main`): `domain_session →
domain_workspace → {domain_identity, domain_agent}`; **workspace does NOT dep
session**. That forces a **split** (workspace-hosting the workflow would cycle):

- **Durable principal→responsibility assignment → `domain_workspace`** (a new
  **`:assign_role`** cap, sibling to the role-authoring caps role-as-data already
  puts there). Workspace already deps identity (#154 caps) — **no new edge**.
- **Approval/quorum/arbiter workflow Behavior → `domain_session`** (the only app
  with message replies + membership + routing; it already deps workspace, so it
  *reads* the assignment over the existing session→workspace edge). **No new
  edge, no cycle.**
- **Assignment-gated fan-out receiver boundary → `core/routing`** (`{:role,name}`
  → `[uri]`). **This is NOT a one-line `expand_receiver` change** — a naïve
  workspace-wide fan-out would hand out-of-scope/stale principals to delivery,
  which mints a narrow `:receive` cap per recipient → a tenant-isolation hole
  (research §3.2, codex HIGH). B2 routing must add a **same-workspace +
  current-assignment validation** before delivery, with a test proving delivery
  cannot mint `:receive` caps for unassigned/out-of-scope principals.
- **Assignment↔cap lifecycle is NEW state** — identity caps are a flat `MapSet`,
  not role-bundled; assigning `supervisor` does **not** auto-grant `approve`, and
  unassigning does **not** auto-revoke it (research §3.3, codex MED). B2 must own
  an explicit **grant-on-assign / revoke-on-unassign** binding **or** atomically
  re-check assignment+cap at verdict-acceptance time (so a stale holder's verdict
  is rejected).
- **Accountability:** B2 approval caps are accountable **iff minted via
  `Ezagent.Identity.Grant.prepare/4`** (which enforces `granted_by ==
  %URI{scheme:"entity"}`) — *not* via the runtime `granted_by_entity?/1` predicate,
  which only rejects `system://` (research §3.3/Q4, codex MED, `capability.ex:319`).
- **No new `domain.role` app** (YAGNI; research §4) — the workspace-assignment +
  session-workflow split respects the real edges and buys nothing less than a new
  app would. **socialware needs no new edge:** it only *names* responsibilities as
  data; the assignment lives in workspace (written by the editor / world plugin,
  which already deps workspace) and the workflow runs in session (which socialware
  already deps).

#### 2.7.5 Why this is responsibility, not a socialware special

Every primitive here is cross-principal and generic — none is socialware-specific.
A `reviewer`-pool gating a code-merge (the research's motivating scenario) and a
`supervisor`-pool gating an autosvc takeover are **the same B2 machine** with
different responsibility names. The socialware app merely *declares the names + the
B2 config* in its definition; the assignment, routing, and workflow are reused
domain primitives. This keeps the 收口 honest: the takeover loop adds no concept
that only socialware could use.

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
| membership `role_name` + `{:role,name}` routing (**B1**) | **REUSE** | single-holder per-session responsibility (orchestrator/bot/reviewer) |
| identity-slice caps + `Ezagent.Identity.Grant` | **REUSE** | the approval-authority primitive (accountable, #154) |
| `supervisor` responsibility (single-holder, **B1**) + cap-bundle | **NEW (= C3)** | names the operator authority; re-homes PR-4 §6.6 (§5.2) |
| **B2 workspace assignment** (`:assign_role` cap, `domain_workspace`) | **NEW** | many-holder principal→responsibility pool (the supervisor pool) |
| **assignment-gated fan-out receiver boundary** (`core/routing`) | **NEW** | `{:role,name}`→`[uri]` with same-ws + current-assignment validation (no `:receive`-cap leak) |
| **assignment↔cap lifecycle** | **NEW** | grant-on-assign/revoke-on-unassign (caps are flat, not role-bundled) |
| **approval/quorum/arbiter Behavior** (`domain_session`) | **NEW** | verdict-collection + arbiter escalation (the B2 takeover workflow) |
| **the takeover product surface** (claim/approve/escalate UI) | **NEW** | closes the interface-inventory "no product surface" gap (operator analysis §5) |

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

**The editor is where responsibilities are assigned (§2.7).** Both paths assign on
two axes: **B1** — set each member's `role_name` in the `template_ref` (the
`bot`/`reviewer`/`orchestrator` function); **B2** — assign the supervisor-pool
holders via the workspace assignment (`:assign_role`, `domain_workspace`). The form
exposes a member-responsibility editor + a supervisor-pool roster; the orchestrator
loop expresses the same via `add_managed_member(role_name:)` + a new assign-pool
tool. Assignment is **never** conflated with the agent recipe (axis A): assigning
the `bot` responsibility to a member is independent of which recipe built that
agent (#1059).

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

> **Codex Q3 clarification:** the column is a **plain string with a default, NOT a
> DB enum constraint** (`…20260618000400…:6-9`, `pg_baseline.exs:54`) — so C1 is a
> `Ecto.Enum` value rename + a one-shot data `UPDATE`, not a type-altering
> migration. "Pre-prod-now" therefore rests on the single deployment fact that
> **there is no prod message history yet**; confirm that holds before P1 (it is the
> one external assumption the source cannot prove).

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
        P6 (C3 supervisor responsibility B1 + relabel; re-homes PR-4 fix)  defer; ride #1059
             │
             ▼
        P7 (B2 supervisor pool + takeover surface)  needs P6 (B1 name) + P5 (editor); defer (L)
```

| Phase | What | Blast | Pre-prod? | Independent gate (verifiable) |
|---|---|---|---|---|
| **P1 — C1** | rename `:operator_only`→`:internal` + data-migrate + invariant | **M** | **NOW (persisted enum)** | extend `no_customer_concept_test` to also forbid `:operator_only`; full `mix test` 0 failures |
| **P2 — PR-3** | `admit_anonymous_participant` primitive + `AnonIngress` shim; collapse +8 dup groups | **M** | any time (pure refactor) | the +8 `cross_file_duplicate_fn_groups` collapse to one primitive + one shim; INV-1/2/2a tests; #1060 Gate 2 stays green |
| **P3 — app object + marker** | `socialware://<name>` def object; `belongs_to` marker; split `public_view` per §2.3 parity table | **L** | NOW (no prod data) | a gate that **no `public_view` boolean is read** anywhere; identity resolves via marker, anon-gate via web-adapter attr; hello `App.ensure_app` migrated |
| **P4 — C2** | lift auto/hold default into `config.publish_policy`; `handle_open` reads it | **S** | NOW | `:auto` preserves today; new test: a `:supervised` turn stays `:internal` until `:settle` |
| **P5 — FORM editor** | world form fills full template + adapter picker + config; converge with orchestrator loop on one def | **M** | NOW | form authors a non-empty `members`/`routing_rules`/`prompt_templates`/`legends` + adapter set; round-trips with `save_template_as`; "current" tag published on save |
| **P6 — C3 (B1 supervisor)** | `supervisor` responsibility as a **single-holder B1** `role_name` + cap-bundle; relabel `operator_tree`/"Operator SessionView"→internal; **re-home PR-4 §6.6 authz fix** | **S-M** | defer; ride #1059 | operator unfiltered read gated by the `supervisor` cap fail-closed (the PR-4 disclosure-bug gate); relabel-only elsewhere |
| **P7 — B2 supervisor pool + takeover surface** | many-holder workspace assignment (`:assign_role`, `domain_workspace`) + assignment-gated `{:role,name}` fan-out (`core/routing`) + approval/quorum/arbiter Behavior (`domain_session`) + the claim/approve/escalate **product surface** in the editor's operator console | **L** | defer (post-prod ok) | a test proving fan-out delivery mints **no `:receive` cap** for unassigned/out-of-scope principals; an assignment↔cap atomicity test (stale-holder verdict rejected); a quorum→arbiter escalation test; the takeover UI drives `:claim`/`:settle`/`:approve` (no raw `mix ezagent` dispatch needed) |

**Recommended order:** P1 (cheapest, pre-prod-critical) → P2 (independent, smaller)
→ P3 (foundational L) → P4 → P5 → P6 (B1 takeover authz) → P7 (B2 pool, last/deferred).
P1 and P2 can land in parallel with each other (no shared file); both precede the
rest only by convenience, not dependency. **P6/P7 are the responsibility-layer
phases** (§2.7): P6 lands the minimal named takeover authority + the disclosure-bug
gate (single operator); P7 lands the full multi-holder pool + the missing product
surface (multi-operator autosvc desk). P7 is the largest deferred item; it can land
post-prod since it is additive new state.

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
- **P7 → P6 + P5 (responsibility layer):** B2 needs the **B1 `supervisor` name**
  (P6) to pool against, and the **editor** (P5) to assign pool holders + drive the
  takeover surface. P7 is therefore last. P7 is otherwise additive (new state in
  workspace + session + routing) and shares no file with P1-P5.

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

**The B2 responsibility layer (P7) — also zero new app edge** (verified `mix.exs`,
`origin/main`): `domain_session → domain_workspace → {domain_identity,
domain_agent}`; **workspace does NOT dep session.** So the research's split is
forced and legal:

| B2 piece | Host app | Reaches | New edge? |
|---|---|---|---|
| principal→responsibility **assignment** + `:assign_role` cap | `domain_workspace` | `domain_identity` caps (↓, already dep) | **No** |
| approval/quorum/arbiter **Behavior** | `domain_session` | workspace assignment (via existing session→workspace edge), session routing/membership | **No** |
| assignment-gated **fan-out boundary** | `core/routing` | the assignment (validated), `Delivery` | **No** |
| takeover **product surface** | the editor (`ezagent_plugin_world`) | workspace assignment (world already deps workspace), session verbs | **No** |

**Why the workflow is in session, not workspace:** the quorum Behavior needs
message replies + membership, which only `domain_session` has; workspace does not
dep session, so hosting it in workspace would **cycle** (research §4.2, codex
HIGH-corrected). **socialware needs no workspace edge:** it only *declares*
responsibility names as data; assignment lives in workspace (written by the
editor), the workflow runs in session (socialware already deps session). **No new
`domain.role` app** (YAGNI; research §4). The fan-out boundary's tenant-isolation
gate (no `:receive`-cap leak) is the load-bearing new check (research §3.2).

---

## 8. Reconciliation with role-as-data / recipe-responsibility / comms-unify

- **role-as-data (#1048).** The app definition IS config-as-data — same Kind
  snapshot + `ConfigObject` cascade as roles. `config.publish_policy` /
  `web_anon_access` are `ConfigObject` data (workspace > user > session), not code
  policy. No new substrate; the app object rides the exact mechanism #1048 built.
- **recipe/responsibility split (#1059) + domain-role research (B1/B2).** This
  SPEC now 收口s **both** axes. **Recipe (A)** is mostly done: role-as-data #1048
  makes it a `config://<ws>/role/<name>` ConfigObject, decoupling locked by #1059
  (`recipe_responsibility_lockin_test.exs` — no structural forcing of `role_name ==
  recipe-name`). **Responsibility (B)** is folded in by §2.7: **B1** (single-holder
  per-session `role_name` + `{:role,name}` routing) already exists and is reused
  for the app's `orchestrator`/`bot`/`reviewer` members; **B2** (the multi-holder
  supervisor pool + claim/approve/escalate/takeover) is the NEW design, hosted per
  the research's codex-corrected split (assignment→`domain_workspace`,
  workflow→`domain_session`, no new `domain.role` app). C3's `supervisor` is the B1
  entry; P7 is the B2 pool. The app's members **carry** responsibilities; the
  editor **assigns** them; neither is conflated with the recipe (a `bot`-recipe
  agent need not carry the `bot` responsibility — #1059). C1's enum rename rides
  #1059's deferred symbol-rename window (one collision-audit).
- **comms-unify (#1047) / #1060.** The app's `adapters` list = the
  `ExternalMirror.Adapter` set already unified on `SessionFeedChannel`; the two
  browser disciplines are `delivery_discipline/0` configs of the `:pull` web
  adapter. #1060's participation-profile routing (writes keyed by
  `participation_profile/0`, not `adapter_id`) is preserved — the app object only
  *names* which adapters; it does not re-open the channel logic (PR-4's N1).

---

## 9. Codex adversarial-review verdict

Static-only review (gpt-5.5, no build/tests) against `origin/main`, reading the
spec + every cited source. **Overall: SOUND-WITH-ONE-OVERCLAIM** — one real fix
folded (the §2.3 parity table), everything else confirmed.

| Q | Codex verdict | Disposition |
|---|---|---|
| 1 — app object real simplification? | **SOUND-WITH-FIXES** — a real simplification *iff* §2.2's fan-out / stable-identity cases are real; the spec's own OQ-1 caveat (1:1:1 → redundant) is honest. Confirmed `SessionTemplate` is content-addressed (`session_template.ex:190-203`, `:name` dropped from hash) + versioned-URI persisted (`:343-371`). | No change — OQ-1 already puts the redundancy test to the lead. |
| 2 — marker replaces public_view cleanly? | **OVERCLAIM — §2.3 parity table INCOMPLETE.** Missed the two controller gate call sites (`chat_feed_controller.ex:98-115`, `external_feed_controller.ex:124-138`) and the world read-model display helper (`workspace_plugin_data.ex:189-211,256-258`). The split itself is correct. | **FIXED** — §2.3 rows 8-9 added + a "Codex Q2 fix" note; the audit is now exhaustive (every site → marker OR web-adapter attr). |
| 3 — phasing safe (P1 enum rename + dep-DAG)? | **SOUND-WITH-FIXES** — `Message.visibility` is an `Ecto.Enum` with `:operator_only` (`message.ex:73-74,118-120`); writers/readers cited (`turn.ex:463,616`, `message_store.ex:288-291`). Note: the migration defines only a string column + default, **no DB enum constraint** (`…20260618000400…:6-9`, `pg_baseline.exs:54`) — so the rename is even cheaper, but "pre-prod" safety rests on there being no prod data. Dep-DAG **confirmed**: socialware deps identity/session/external_mirror (`socialware/mix.exs:31-39`); identity does NOT dep socialware (`identity/mix.exs:34-38`); external_mirror deps only core/identity (`external_mirror/mix.exs:59-70`) → socialware is the only legal host. | Folded the "pre-prod = no prod data; the column has no enum constraint so it's a data UPDATE not a type change" clarification into §6/§7. |
| 4 — AnonIngress fold + PR-4 supersede safe? | **SOUND-WITH-FIXES** — anon ingress is already socialware-owned (`anon_user.ex:118-131`) with duplicate web-shim logic in both controllers (`chat_feed_controller.ex:144-154`, `external_feed_controller.ex:162-167`); folds cleanly. Superseding PR-4 is safe **only if C3 is not deferred past any operator unfiltered read** — the spec states exactly this (§5.2, §7.1) and confirmed world reads raw `recent_in_session` (`conversation_data.ex:183-187`) under `RequireEntity` (`router.ex:154-155`), unlike the `:external_visible`-filtered query (`message_store.ex:171-178` vs `:274-278`). | No change — the C3-gates-PR4 condition is already the §5.2 + §7 P6 contract. |

**Net:** the core model survives review. The single substantive correction (Q2,
parity-table completeness) is folded; Q1/Q3/Q4 are sound with clarifications
incorporated. No finding was UNSOUND.

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
7. **B2 wanted now, or is B1 enough? (responsibility layer, §2.7 / research OQ-1).**
   A single-operator socialware app is fully served by B1 + C3 (P6). The
   multi-holder supervisor pool + quorum/arbiter (B2, P7) is real new work
   (workspace assignment + gated fan-out + a Behavior). Confirm the multi-supervisor
   takeover + conflicting-verdict scenario is a near-term need before building P7.
   (Recommend: ship P6 now, defer P7 until a real multi-operator desk exists.)
8. **`role_name` uniqueness for the pool (research OQ-2).** B2 needs ≥2 holders of
   `supervisor`. Relax `role_name_conflict/3` to allow many holders of the same
   responsibility, **or** keep B1's unique per-session alias and add a *separate*
   many-holder workspace assignment for B2? (Recommend the latter — two facets, not
   one overloaded field.)
9. **Quorum/arbiter policy (research OQ-4).** What verdict policy
   (unanimous/majority/any-one/N-of-M) and is `arbiter` a tiebreaker (decides only
   on conflict) or a required final approver? This shapes the P7 Behavior's state
   machine.
10. **Vocabulary (research OQ-5).** Adopt "agent recipe" for axis A and reserve
    "responsibility" for axis B in the app definition + editor labels, to retire the
    `role` homonym? (Recommend yes — the definition uses `role_name` for B today;
    naming the pool a "responsibility" in the UI avoids the recurring confusion.)

---

## Method / provenance

- All reads via `git show origin/main:<path>` (`67b49303`) — no working-tree trust.
- Synthesized from: `docs/socialware-operator-analysis` (operator C1/C2/C3 +
  blast radius), `docs/socialware-template-model` (template→data→instance + editor
  gap), `docs/comms-pr34-spec` (PR-3 AnonIngress + PR-4 world-on-contract),
  `docs/domain-role-research` (`role-for-users-domain-role.md` — the B1/B2
  responsibility model + the workspace-assignment/session-workflow home split).
- Responsibility layer (§2.7): `domain_session → domain_workspace` edge
  (`session/mix.exs:36`), `domain_workspace` does NOT dep session
  (`workspace/mix.exs`); B1 membership `role_name` + `{:role,name}` routing;
  `:claim`/`:settle`/`:approve` verbs (`turn.ex:49,320`, `surface.ex:20`);
  `Identity.Grant.prepare/4` (accountable granter) vs `granted_by_entity?/1`
  backstop (`capability.ex:319`).
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
