# SPEC — Socialware unification: base / socialware / fixture (decoupled model)

> **Status: DESIGN (concepts doc + phased plan, NOT implementation).** Read-only
> basis; no code changed by this SPEC. Skills loaded: `ezagent-developer`,
> `ezagent-socialware`. All code citations verified against `origin/main`
> (`67b49303`). Worktree off `origin/docs/socialware-app-unification`; branch
> `docs/socialware-app-unification`. Codex adversarial-review record in §10.
>
> **COMPLETE REWRITE (2026-06-28).** The prior revision framed the model as
> *"Session (host) / SessionTemplate (composition) / app-definition (installable)"*
> and used the term "socialware app" / "app-def" throughout. The lead reframed
> the model onto a **three-layer taxonomy — base / socialware / fixture** — and
> renamed "app"→"socialware" everywhere. This revision restructures the whole
> doc to that taxonomy, adds a **§0 Concepts** layer (which IS the P0
> deliverable — a definition/authoring guide liftable to `docs/`), and
> re-derives the phases with **P0 = the concepts doc first**. The confirmed
> decisions (C1 `:internal`; operator de-bake with **no named role** P1-P8;
> `supervisor` named **only** in P9; P9's four sub-steps; B1/B2; AnonIngress
> folded; decouple from SessionTemplate; no `socialware://` scheme) carry over
> unchanged from the prior revision's confirmed set.
>
> **Synthesizes** the prior read-only analyses (operator composability,
> template→data→instance, comms PR-3/PR-4), the merged substrate (#1047
> comms-unify, #1060 participation gates), **role-as-data (#1048)**, the
> **role-materialization foundation** (RF-1..RF-8: runtime mount/detach + role
> recipes), **kanban-as-role** (#103-105, the landed config-as-data installable
> precedent), and the recipe/responsibility split (#1059).

---

## 0. Concepts — what a socialware IS (THIS IS P0's deliverable)

> This section is a **concepts / definition doc**. It is the P0 deliverable:
> landed as a standalone doc under `docs/` (the socialware authoring guide),
> not just a SPEC prelude. Everything below is code-verified against
> `origin/main`; citations are inline.

### 0.1 Why "socialware", not "app"

A **socialware** is a **human+program hybrid FLOW**, not a pure software "app."
The name is deliberate: a socialware is *operated* — a human (the operator /
supervisor) and one or more agents collaborate inside a shared, observed turn
surface, where the human can hold, settle, approve, and take over the program's
output before it reaches an external audience. A pure "app" hides its internals
and runs unattended; a socialware **exposes its internals to a responsible human
and makes the human's gating first-class.** That is the whole reason the concept
is named "socialware" and not "app" — the social/human-in-the-loop axis is the
defining property, not an add-on.

Concretely: a socialware composes **capability substrates (bases)** with a
**shape** (a flow recipe + responsibilities + routing), and is **directly
user-operable** — an operator opens it, drives it, and gates its output. A base
is *not* directly user-operable; you do not "open the orchestrator base," you open
a *socialware* that composes it.

### 0.2 The three layers — base / socialware / fixture

```
┌─────────────────────────────────────────────────────────────────────┐
│  FIXTURE  (a seeded instance/use of a socialware for a business)    │
│     e.g. autoservice = chat used for the customer-service business  │
│     (project name only; NOT a concept — must NOT enter the          │
│      concept layer; it is a configured instance of chat)            │
├─────────────────────────────────────────────────────────────────────┤
│  SOCIALWARE  (human+program hybrid FLOW; directly user-operable)    │
│     composes ≥1 BASE + a SHAPE; IS the thing the operator opens     │
│     • chat    = world Conversation surface (generic, NO business     │
│                 semantics); composes orchestrator + surface bases    │
│     • kanban  = board WITH definite business (task) semantics;       │
│                 composes bases + a "board/task" shape                │
├─────────────────────────────────────────────────────────────────────┤
│  BASE (基座, PLURAL)  (capability substrates; NOT user-operated)     │
│     composed INTO socialwares; provide capability, not a product     │
│     • orchestrator  = process/agent+tools base                       │
│                       (Ezagent.Behavior.Template)                    │
│     • hello/surface = render/external-surface base                   │
│                       (Ezagent.Behavior.Surface)                     │
│     • Behavior.Pty, Behavior.Sandbox, Behavior.CcHeadlessAgent       │
│     (orchestrator is ONE base among several — NOT "the" base)        │
└─────────────────────────────────────────────────────────────────────┘
```

**Base (基座).** A capability substrate — a `Behavior` that owns a persistent
state slice + a set of dispatchable actions providing a *general capability*
(turn-taking is NOT general; it is conversation-specific, so `Turn` is part of
chat's *shape*, not a base — see §0.4). A base is composed into one or more
socialwares. Verified bases (all `defmodule`-confirmed on `origin/main`):

| Base | Module | What it provides | Verified |
|---|---|---|---|
| **orchestrator** | `Ezagent.Behavior.Template` | the process/agent+tools substrate — carries the `:template` content slice (team / routing / persona / tool-catalog recipe) with dispatchable `:read`/`:write`/`:instantiate` actions; the orchestrator tool catalog (`add_managed_member`, `define_rule_set_rule`, `define_prompt_template`, `define_legend`, `save_template_as`, `migrate_session`) mutates this content | `behavior/template.ex:1,11-29` (moduledoc: "dispatchable template-CONTENT Behavior"); tools at `orchestrator/tools.ex:135,376,555,661,707,756,760` |
| **hello/surface** | `Ezagent.Behavior.Surface` | the render/external-surface substrate — owns the `:surface` slice; immutable page versions + an `:approved` pointer; `:put_version`/`:approve`/`:commit_settlement` actions | `behavior/surface.ex:1,2-6` (moduledoc: "Immutable socialware page surface") |
| **pty** | `Ezagent.Behavior.Pty` | terminal/PTY substrate | `ezagent_domain_pty/lib/ezagent/behavior/pty.ex:1` |
| **sandbox** | `Ezagent.Behavior.Sandbox` | per-agent config_dir + Kind.Template plugin-extension substrate | `ezagent_core/lib/ezagent/behavior/sandbox.ex:1` |
| **cc-headless-agent** | `Ezagent.Behavior.CcHeadlessAgent` | the cc SDK sync-result-persistence + headless-agent substrate | `ezagent_domain_agent/lib/ezagent/behavior/cc_headless_agent.ex:1` |

**Socialware.** A human+program hybrid flow that composes one or more bases + a
**shape** and is directly user-operable. Two verified instances:

- **chat** = the world Conversation surface. Generic — **NO business semantics**.
  `Ezagent.World.ConversationActions` (`conversation_actions.ex:1`, moduledoc:
  "Socket-side conversation dispatch handlers … pure data shaping lives in
  `ConversationData`") + `Ezagent.World.ConversationData`
  (`conversation_data.ex:1`, moduledoc: "Read-path + message construction …
  derived against `MessageStore`/`EntityPresenter`/`Message` — NOT [retired]
  `SessionContext`") + `Conversation.tsx`
  (`apps/ezagent_plugin_world/assets/src/components/Conversation.tsx`). Composes
  the **orchestrator** base (`Behavior.Template`, the team/routing/persona recipe)
  + the **surface** base (`Behavior.Surface`, the rendered conversation surface) +
  the **conversation shape** (`Behavior.Turn`, the turn state machine — see §0.4).
- **kanban** = a board WITH definite business (task) semantics. Composes bases +
  a "board/task" shape. The task semantics are expressed via **agent
  recipe/responsibility + routing** (the *target* model — see §0.5 for the
  verified *current* status: today kanban is recipe-only, no responsibility
  routing yet). The board/task shape is `Ezagent.Behavior.Kanban`
  (`behavior/kanban.ex`): `add_node`/`rename_node`/`move_node`/`remove_node`/
  `set_stage`/`claim_node`/`unclaim_node`/`set_status`/`attach_artifact`/
  `set_metric`/`sync_github`/`push_pr`/`register_pr`/`sync_miro`/`set_board_config`
  — definite task/board business, not generic chat.

**Fixture.** A seeded instance/use of a socialware for a specific business. **A
fixture is NOT a concept and must NOT enter the concept layer** — it is a
configured instance. **autoservice** = a fixture = **chat used for the
customer-service business** (project name only). The autoservice reframe doc
(`docs/together/2026-06-26/notes/autoservice-flavor-agnostic-reframe.md`)
confirms: autoservice is a fixture/project-name, not a concept — its "tool-loop
is flavor-agnostic shared-domain code; only the cc-coupled runtime is
unimplemented for curl/py." autoservice adds no new concept; it is chat + a
customer-service team/persona/adapter config.

### 0.3 How bases compose into a socialware

A socialware **installs** its bases' behaviors onto a **host** (a session) via
the **declaration-free mount path** (§2.2) — the same path kanban-as-role proved
on `Entity.Agent`. The session's per-instance active behavior set (`:kind_base`)
becomes the **union** of all installed socialwares' bases + shapes. The
socialware definition is a **config-as-data object** (a sibling of the role
recipe, §2.3) naming: which bases/behaviors to mount, the team (members), the
routing rules, the persona (prompt templates / legends), the external-surface
adapters (which `ExternalMirror.Adapter`s), and the visibility policy. Composing
a new socialware = picking bases + defining a shape/recipe/responsibility/routing
+ (optionally) an external-surface base (Surface) with adapters.

### 0.4 The shape concept (and where `Turn` lives)

A socialware's **shape** is the flow-specific behavior + recipe that makes the
composed bases into a *particular* flow. chat's shape is the **conversation
turn protocol** — `Ezagent.Behavior.Turn` (`behavior/turn.ex:1`, moduledoc:
"Socialware orchestration state machine. Owns the `:turns` slice"). `Turn` is
**NOT a base**: it is specific to the conversation flow (a kanban has no turns),
so it is part of **chat's shape**, not a general capability substrate. kanban's
shape is the **board/task protocol** — `Ezagent.Behavior.Kanban` (node/stage/
claim/status/artifact actions). The shape is what distinguishes two socialwares
that compose the *same* bases (chat and a future "board-chat" could both compose
orchestrator+surface but differ in shape).

> **Precision (open for the lead, §9 OQ-1):** `Turn`'s moduledoc calls it
> "Socialware orchestration state machine," which sits between "base" and
> "shape." The clean classification: a **base** is general (reusable across
> unrelated socialwares); a **shape** is flow-specific. `Turn` is flow-specific
> (conversation only) → shape. `Surface` is general (any rendered external
> surface) → base. This SPEC classifies `Turn` as chat's shape. Confirm.

### 0.5 How a developer writes a new socialware

1. **Pick the bases** your flow needs: does it need a process/agent+tools
   substrate (orchestrator/`Behavior.Template`)? a rendered external surface
   (surface/`Behavior.Surface`)? a terminal (`Behavior.Pty`)? a sandbox
   (`Behavior.Sandbox`)? a cc headless agent (`Behavior.CcHeadlessAgent`)?
2. **Define the shape** — the flow-specific behavior(s) + recipe (team,
   routing_rules, prompt_templates, legends, orchestrator_template_uri). If the
   flow is a conversation, reuse `Behavior.Turn`; if a board, reuse
   `Behavior.Kanban`; if novel, author a new flow Behavior.
3. **Declare responsibilities + routing** (axis B, §3) — name each
   responsibility (e.g. `bot`, `reviewer`, `supervisor`), assign `role_name` per
   member (B1 single-holder), and write `{:role, name}` routing rules.
4. **Optionally wire an external-surface base** — add `adapters`
   (`ExternalMirror.Adapter` ids + config) so the socialware speaks to Feishu /
   Slack / a web feed; set `visibility_policy.web_anon_access` if anonymous
   customers should reach the surface base.
5. **Author the definition as config-as-data** — the socialware definition
   object (§2.3), a sibling of the role recipe on the same `ConfigStore`/
   `ConfigObject` substrate. Install it onto sessions via the SessionTemplate
   composition `installs: [...]` field (§2.1).

The developer does NOT touch the host Kind, declare the bases in
`domain_session`, or write new spawn call-sites — the declaration-free mount
(§2.2) installs the bases onto a generic session host.

### 0.6 What is NOT a socialware / NOT a base (anti-patterns)

- **A pure "app"** (unattended, internals hidden, no human gating) is NOT a
  socialware. If a flow has no human-in-the-loop gating axis, it is just a
  session with behaviors — call it that.
- **A fixture is NOT a concept.** autoservice / loom / a named customer-service
  deployment are *configured instances of chat*, not new layers. Do not add
  "autoservice" to the concept taxonomy or the config schema.
- **hello is a BASE (the surface base), NOT a vertical/page.** The hello *plugin*
  (`ezagent_plugin_hello`) contributes the page-builder behavior (`HelloBuilder`
  + `@json-render` Spec validator + `TurnDriver` + renderer island) that runs
  *on* the Surface base; it is not a separate socialware vertical. Per the
  template analysis's *"definition = data; vertical mechanism = code"*: the
  external channel is the generic `:pull` web adapter; hello's page-builder is
  **code** referenced by a `members` entry.
- **orchestrator is ONE base among several**, NOT "the" base. A socialware may
  compose orchestrator + surface, or surface + pty, or orchestrator alone. Do
  not treat orchestrator as the singular foundation.

---

## 1. Current-state — what exists vs what is new

All citations verified against `origin/main` (`67b49303`).

### 1.1 The bases (exist)

All five bases in §0.2 are `defmodule`-confirmed on `origin/main`. The
orchestrator base (`Behavior.Template`) carries the `:template` content slice
(team/routing/persona) on the SessionTemplate Kind; the orchestrator tool
catalog (`orchestrator/tools.ex`) mutates that content. The surface base
(`Behavior.Surface`) owns the `:surface` slice. `Behavior.Pty`, `Sandbox`,
`CcHeadlessAgent` are registered on their respective domain Kinds.

### 1.2 The session hosts undeclared behaviors (exists — the install mechanism)

- `effective_set/2` (the single function every post-load dispatch enumeration
  calls) computes the instance's active set as **`declared_part ++ extra_part`**
  (`behavior_set.ex:160-172`): `extra_part` is exactly the captured `:kind_base`
  behaviors that are **NOT declared** by the host Kind but **are real
  Behaviors**. The comment: *"authz still gates every action, so presence in the
  set grants NO privilege."*
- `Ezagent.Kind.mount/3` + `detach/2` (`kind.ex:535,561`; `mount_detach.ex:72,
  101`) install/remove a behavior on a **live** instance — running slice-init,
  re-validating closure (`resolve_closure`), rewriting `:kind_base`.
  Kind-level `attach_behavior` (the wrong global-registration approach) was
  **retired** (`kind.ex:879`, RF-3).
- **kanban is the proof.** `kanban-manager` is a role recipe (`roles/0`,
  `ezagent_plugin_kanban/application.ex:64`), `passive: true`
  (`application.ex:77`), `behaviors: [Ezagent.Behavior.Kanban]`
  (`application.ex:84`), mounted per-instance onto a generic `Entity.Agent` that
  declares **none** of them (`agent.ex:81,94-104` `base_behaviors` = Identity,
  Sandbox, ApiKeys, CredentialGrant, ConfigEvolve, ConfigGovernance — no Kanban).

### 1.3 kanban's recipe / responsibility / routing status (VERIFIED — the key finding)

> The lead asked: is kanban a role/recipe + routing rules? does it use
> responsibility (B1 `role_name` + `{:role, name}` routing) today, or just
> recipe? **Answer: JUST recipe. kanban uses NEITHER `role_name` NOR
> `{:role, name}` routing today.**

Verified by grep against `origin/main` over `apps/ezagent_plugin_kanban/**`:

| Question | Grep | Result | Verdict |
|---|---|---|---|
| is it a `roles/0` recipe? | `roles\|recipe\|passive:` | `application.ex:64` `def roles, do: [kanban_manager_recipe()]`; `:77` `passive: true`; `:74` `kanban_manager_recipe()` | **YES** — recipe |
| does it use `role_name`? | `role_name` | **(empty)** | **NO** — no B1 responsibility assignment |
| does it use `{:role, name}` routing? | `\{:role,` | **(empty)** | **NO** — no responsibility-based routing |
| does it use `routing_rules`? | `routing_rules\|define_rule` | **(empty)** | **NO** — no routing rules |

So kanban-as-role (#103-105) landed the **recipe + passive + per-instance mount**
substrate, but the **responsibility/routing layer (B1 `role_name` + `{:role,
name}`) is NOT used by kanban today** — kanban is a passive data actor that acts
only on direct `kanban.<action>` dispatch (its moduledoc: "不可被 @ / 不可
`:join` / 不收 chat"). The *target* model (§0.2, §3) says kanban's task semantics
should be expressed via recipe/responsibility + routing; today only the recipe
half exists. **The B1 mechanism exists** (membership `role_name` +
`role_name_conflict/3`, single-resolve `{:role,name}` — `resolver.ex:435,451`,
`members.ex`) **but kanban does not exercise it.** This is the gap §3/P9 closes.

### 1.4 chat = world Conversation (exists, generic)

`Ezagent.World.ConversationActions` + `ConversationData` + `Conversation.tsx`
(§0.2) are the chat socialware's surface. `ConversationData`'s moduledoc is
explicit: derived against `MessageStore`/`EntityPresenter`/`Message`, **NOT** a
session-context/business module — generic, no business semantics. The chat
behaviors (`Behavior.Turn` + `Behavior.Surface`) are mounted via
`Session.socialware_behaviors/0` (`entity/session.ex:86-91`) = base + Turn +
Surface.

### 1.5 The two hardcoded behavior-set sites (exist — the composition gap)

Which bases/behaviors a session gets is **NOT data** — it is hardcoded at two
spawn call-sites: `session_creator.ex:338,430` always threads
`Session.chat_behaviors()`; only `hello/app.ex:35` threads
`Session.socialware_behaviors()`. So a socialware (Turn/Surface) session can be
created **only** via the hello demo path, never via the world "New session" form.
The "session composition" the lead wants (which socialwares installed) has **no
data home** — it is two `if`-by-call-site branches. P3 makes this data.

### 1.6 What is in SessionTemplate that moves out (exists — the decouple target)

SessionTemplate content today carries socialware-specific fields that, under the
decouple, **move into the socialware definition** (`entity/session_template.ex`:
`members` `:47`, `prompt_templates` `:49`, `legends` `:51`,
`orchestrator_template_uri` `:56`, `routing_rules` `:59`; `public_view` `:757`).
The template keeps only generic composition + lineage (`name`, `description`,
`default_workspace_uri`, `parent_template_uri`, version/provenance) + a **NEW**
`installs: [{socialware-ref, seed-overrides}]` composition field. The orchestrator
tool catalog (§1.1) today mutates SessionTemplate content; under the decouple it
re-targets the socialware definition (P5).

### 1.7 The `public_view` magic boolean (exists — the identity marker to replace)

"a socialware" is `public_view: true` buried in SessionTemplate content
(`session_template.ex:757-764`), read by `PublicView.public_view?/1`
(`public_view.ex:38`). The boolean silently does **two unrelated jobs**
(identity + the anon gate) and has hardcoded consequences (both browser routes
always-on for every `public_view` session). P4 splits it (§2.4).

---

## 2. The decoupled model — Session=host; SessionTemplate=composition; socialware=installable

### 2.1 The three concepts

```
Session (HOST)  ── installs ──►  socialware definition(s)
   │  one parameterized Entity.Session                       config-as-data, sibling of Role recipe
   │  per-instance active behaviors = :kind_base union       bases + shape + team + routing + persona
   │  (effective_set/2 admits UNDECLARED — behavior_set.ex:167)   + ADAPTERS + VISIBILITY-POLICY
   │
   └── created from ──►  SessionTemplate (COMPOSITION recipe)
                            installs: [ {socialware-ref, seed-config-overrides}, … ]   ← NEW data home
                            (replaces the hardcoded chat_behaviors/socialware_behaviors call-site choice)
```

| Concept | Role | Status |
|---|---|---|
| **Session host** | the "room" that hosts installed socialwares; active behaviors in `:kind_base` | **EXISTS** — #46 collapse landed; `behaviors/0` superset + `effective_set/2` per-instance subset (`session.ex:56-104`, `behavior_set.ex`) |
| **`effective_set/2` admits undeclared behaviors** | lets a host run a base's behaviors it never declared (authz still gates) | **EXISTS (landed)** — `declared_part ++ extra_part`, `behavior_set.ex:167-172`; kanban runs `Behavior.Kanban` on undeclaring `Entity.Agent` |
| **SessionTemplate** | the recipe a session is created from | **EXISTS** but carries socialware config, not a composition list; behavior-set choice is **hardcoded at call sites** (NEW work to make it data, P3) |
| **socialware definition (installable)** | config-as-data bundle installed onto a host | substrate **EXISTS** (`Ezagent.Role` recipe + `RoleRegistry` ConfigObjects + mount + CapMint); the **socialware shape** (+ adapters + visibility) is **NEW** |
| **install relation** | "session S has socialware W installed" | NEW — built from EXISTING `:kind_base` (behavior union) + `ConfigObject` (per-install config) |

### 2.2 The install mechanism is REUSE — declaration-free mount (kanban proved it)

The load-bearing question: *can a session host a base's behaviors **without
`domain_session` declaring the base**?* If not, "a session installs a socialware"
would force the host to declare every base — a plugin-isolation violation (North
Star). **Answer: yes, it is already landed** (§1.2). "Installing a socialware
onto a session" = mounting the socialware's bases + shape behaviors into the
session's `:kind_base` set (+ recording the install, §2.4). It needs **no new
core mechanism and no new app edge** — it is the kanban mount path applied to the
Session host. *That* is why this is a simplification, not a new layer.

> **Note — role-foundation §4 was RELAXED on landing.** §4/HIGH-1 stated as a
> *hard constraint* that "a role can only mount behaviors the host Kind
> declares." The code that landed **dropped** the strict ∩declared rule in favour
> of `declared_part ++ extra_part` (declaration-free, authz-gated). This SPEC
> builds on the **landed** behavior (code wins). Remaining constraints: a mounted
> behavior must be a real Behavior, the set must stay **closed under required
> sibling reads** (`resolve_closure`), and the session Kind requires an explicit
> non-nil `:kind_base` (`requires_explicit_behavior_set?`, `behavior_set.ex:100-103`).

### 2.3 The socialware definition — a Session-host sibling of the role recipe

`Ezagent.Role` is already config-as-data: `%Role{behaviors, requested_caps,
skills, plugins, prompt, script, passive, session_template}` (`role.ex:46-66`),
the content of a forkable `template://<ws>/role/<name>` Template subtype, stored
as a `ConfigObject` and resolved by `RoleRegistry` read-through over
`ConfigStore` (`role_registry.ex:3-29`, key `"role"`).

A **socialware definition rides the same `ConfigStore`/`ConfigObject` substrate**,
addressed `template://<ws>/socialware/<name>`. **Precision:** it does **not**
reuse `RoleRegistry` verbatim — that resolver is role-specific, fixed to key
`"role"` (`role_registry.ex:55-68`); the socialware resolves through a **sibling
resolver keyed `"socialware"`** over the same `ConfigStore`. Nor is it a
`%Role{}` — that struct has no `adapters`/`visibility_policy` (`role.ex:46-54`);
the socialware definition is a **sibling struct**. What is reused is the
**mechanism** (config-as-data `ConfigObject` + `ConfigStore` cascade + mount +
`CapMint`), not the role-specific shell. **NO new `socialware://` scheme** (which
would violate the 6-scheme allowlist, ezagent-developer invariant #11) — the
socialware definition is a `template://` subtype. The two fields a role recipe
lacks:

```
template://<ws>/socialware/<name>           # installable socialware definition (config-as-data; ConfigObject, key "socialware")
├── bases         : [Ezagent.Behavior.Template, Ezagent.Behavior.Surface, …]   # REUSE: the per-instance set the host mounts
├── shape         : [Ezagent.Behavior.Turn, …]                                 # the flow-specific behaviors (chat's turn; kanban's board/task)
├── members       : [%{uri|source_template_uri, role_name, …}]                 # the socialware's slice of the team (B1 responsibility)
├── routing_rules : [%{matcher, receivers, rule_set, …}]                       # {:role, name} routing
├── prompt_templates / legends / orchestrator_template_uri                    # the orchestration recipe
├── adapters      : [%{adapter_id, role: :customer|:internal, config}]         # NEW: ExternalMirror.Adapter set
│     ├── "web_feed"      :pull   (chat + page disciplines; the SPA shell)
│     ├── "feishu_mirror" :push   (a customer channel)   [optional]
│     └── "slack_mirror"  :push   (a customer channel)   [optional]
└── visibility_policy : %{                                                     # NEW: replaces public_view's jobs
        publish_policy  : :auto | :supervised,                                # C2 — was the hardcoded turn.ex default
        web_anon_access : boolean }                                           # the anon gate (job (b) of old public_view)
```

Content-addressed + versioned exactly like `SessionTemplate`/role recipes
(SHA-256 over deterministic content; editing mints a new version).

### 2.4 The install relation REPLACES `public_view` — parity audit

The install relation has **two physical parts**, mirroring `public_view`'s two
jobs:
- **(identity) a per-install record** — a `ConfigObject` (`subject =
  session_uri`, `key = "install:" <> socialware-ref`, `body = seed/override
  config`) — the #1048 shape (`config_object.ex:14-23`). `:kind_base` alone
  cannot be the record: it holds only the derived behavior **union** and loses
  which-socialware-owns-which-behavior, so a separate per-install row is required.
- **(behavior) the socialware's bases+shape in the session's `:kind_base` union**
  — installed via mount (§2.2).

**Parity audit** — every `public_view` read/write on `origin/main` mapped to its
new home (carried over from the prior revision, 10 sites):

| # | Site (`origin/main`) | Job today | New home |
|---|---|---|---|
| 1 | `session_template.ex:757-764` — `:public_view` in `@config_atom_keys` | (a) identity schema key | **install record**; `:public_view` key removed from template schema |
| 2 | `public_view.ex:38,108` — `PublicView.public_view?/1` gate | (b) anon-access gate | **socialware-def `visibility_policy.web_anon_access`** |
| 3 | `anon_user.ex:120` — `mint_for_public_session` calls `public_view?/1` | (b) gate before minting | re-points to (2) via the same resolver |
| 4 | `anon_user.ex:99-154` — `public_view_granter/1` (= session owner) | cap granter (#154) | **unchanged** — anon's `:join` cap still `granted_by` the session owner |
| 5 | `membership.ex:371,801,818` — `public_view` open-join doc/granter | (b) anon path | re-points to (2) |
| 6 | `app.ex:31,35` (hello) — writes `public_view: true` + `socialware_behaviors()` | (a)+(b) at create | hello installs `template://<ws>/socialware/hello-<n>` (web adapter w/ `web_anon_access: true`) — the **mount path replaces the hardcoded `socialware_behaviors()`** |
| 7 | `workspace_plugin_actions.ex:334` — world toggle writes `public_view` | (a)+(b) authored | the form (§4) authors/installs the socialware-def (web adapter w/ anon) |
| 8 | `chat_feed_controller.ex:108` + `external_feed_controller.ex:131` — public controllers call `public_view?/1` as ingress gate | (b) per-route anon gate | re-point to (2); in P2 these collapse into the `AnonIngress` shim (§8) — ONE chokepoint |
| 9 | `workspace_plugin_data.ex:189,211,256-258` — world read-model `public_view?/1` (renders the badge) | (a) identity, for display | reads the **install record** |
| 10 | `WorkspacePlugin.tsx:190-198` (React) — the form payload still **sends `public_view`** | (a)+(b) authored at the UI | the form sends an **install + adapter** payload — the toggle becomes "install socialware w/ anon web feed" |

Every site → **identity = install record** (rows 1, 6, 7, 9, 10) **or**
**anon-gate = socialware-def `web_anon_access`** (rows 2, 3, 5, 8, +10); row 4
(granter) unchanged. The §7 P4 gate is a test that **no `public_view` boolean is
read anywhere** and both jobs resolve via the new homes.

### 2.5 The two fan-out cases — both first-class

**(a) one socialware → many channel adapters** (Feishu user-a + Slack user-b).
The `adapters` list is a list of `ExternalMirror.Adapter` ids + per-adapter
config. The contract already has the axis (`adapter.ex:167-377`):
`adapter_kind/0 ∈ :push|:pull|:request_scoped`; a `:push` adapter (Feishu/Slack)
has a paired `Binding` GenServer; a `:pull` adapter (the web feed) is served on
demand. #1047 collapsed both browser surfaces onto one `SessionFeedChannel`.

**(b) one session → many *distinct* installed socialwares** (chat + kanban).
Each install is its own record keyed by socialware-ref, and the session's
`:kind_base` is the **union** of all installed socialwares' bases+shapes (mount
is additive, `mount_detach.ex:120-134`). Closure (`resolve_closure`) is checked
over the union at each mount — fail-closed. A chat (Turn/Surface) + a kanban
(Kanban) install compose cleanly because their slices (`:turns`/`:surface` vs
`:kanban`) don't collide.

> **The one limit (OQ-9): two instances of the *same* behavior-owning socialware
> on ONE session is NOT first-class today.** A Behavior owns a **singleton**
> state slice per Kind instance (`behavior.ex:91-97,267-274`): `Turn` owns
> `:turns` (`turn.ex:3-11`), `Surface` owns `:surface` (`surface.ex:3-10`). So a
> `:kind_base` *union* cannot hold two independent `Turn`/`Surface` states.
> Supporting two same-type instances needs app-scoped slice keys + app-scoped
> action routing — genuinely new mechanism, **scoped OUT** (distinct socialwares
> per session is the near-term need and works without it).

### 2.6 Symmetry with kanban — be precise about what's reused vs new

Kanban is the precedent for the **per-socialware installable substrate**, but it
is **not** "a session installs kanban" today — stating otherwise would
over-claim (§1.3: kanban is a recipe on `Entity.Agent`, no session relation).

| Aspect | kanban (landed) | socialware (this SPEC) |
|---|---|---|
| definition shape | `Ezagent.Role` recipe (config-as-data) | **same** substrate + `adapters` + `visibility_policy` |
| storage / resolve | `ConfigObject` via `RoleRegistry`/`ConfigStore` (#1048) | **same** (`template://<ws>/socialware/<name>`, key `"socialware"`) |
| host Kind | generic `Entity.Agent` (one role per agent) | generic `Entity.Session` (**N socialwares per session**) |
| install mechanism | per-instance **mount** of undeclared behaviors (§2.2) | **same** mount path on the Session host |
| caps | `Role.CapMint` fail-closed `requested ∩ policy` | **same** `CapMint` |
| isolation | `passive` flag + mention/join/receive gates (RF-6) | reuses the same gates for passive members |
| **session relation** | **NONE** — workspace-scoped agent, session-independent | **NEW** — the install relation (session ↔ socialware-def) |
| **multi-install host** | N/A (one role per agent) | **NEW** — session as a multi-socialware host (`:kind_base` union) |

So: **per-socialware substrate = REUSE** (kanban proves recipe + mount +
ConfigObject + CapMint end to end); **session-as-multi-socialware-host + the
install relation = genuinely NEW**.

### 2.7 The external channel IS `ExternalMirror.Adapter`; the surface base is the render substrate

No new "vertical" concept. The socialware's `adapters` list =
`ExternalMirror.Adapter` ids + config (§2.5a). The **surface base
(`Behavior.Surface`) is the render substrate**; the hello plugin's page-builder
(`HelloBuilder` + `@json-render` `Spec` validator + `TurnDriver` + renderer
island) is **code** (`ezagent_plugin_hello`), referenced by a `members` entry in
the socialware definition. `PageView.applies_to?/1` render-target dispatch is
unchanged.

### 2.8 What MOVES out of SessionTemplate into the socialware definition

| SessionTemplate content (`origin/main`) | Decoupled home | Why |
|---|---|---|
| `public_view` | **deleted** → install relation (identity) + socialware-def `web_anon_access` (anon) | §2.4 — the magic boolean is replaced |
| `members`, `routing_rules`, `prompt_templates`, `legends`, `orchestrator_template_uri` | **MOVE → socialware definition** | team/routing/persona is the **socialware's own config**; each installable brings its slice; the session = union of installed socialwares' members/routing |
| `name`, `description`, `default_workspace_uri`, `parent_template_uri`, version/provenance | **STAY** on SessionTemplate | generic composition + lineage |
| **`installs: [{socialware-ref, seed-overrides}]`** | **NEW field on SessionTemplate** | the composition itself — *which* socialware-defs to install (replaces the hardcoded behavior-set call-site choice) |

> **Consequence (flag) — the orchestrator tool catalog re-targets.**
> `add_managed_member`, `update_member_template`, `remove_member`,
> `define_rule_set_rule`, `define_prompt_template`, `define_legend`,
> `update_template`/`save_template_as`, and **`migrate_session`** today mutate
> SessionTemplate content. Once those fields live on the socialware definition,
> every tool must target the **socialware definition** instead — for **all**
> orchestrated sessions, not only socialware. That rewire is the bulk of P5.

### 2.9 Where the definition lives (data geography)

`EZAGENT_HOME` holds agent **runtime** state (credentials, per-agent config,
logs). The **socialware definition stays in the data store**: the
content-addressed versioned object is a `ConfigObject`/`template://` subtype
(`config_store.ex`, `config_object.ex:14-23`); its `visibility_policy` is the
role-as-data cascade (workspace > user > session). **Nothing moves to
`EZAGENT_HOME`; this SPEC introduces no new substrate.**

---

## 3. Responsibility & routing layer (B1/B2; takeover loop; supervisor named only in P9)

A socialware is also a set of **principals each serving a responsibility**. This
is the SPEC's second 收口 axis — alongside **recipe (axis A, mostly done via
#1048/#1059)**, **responsibility (axis B)**. The autosvc operator/supervisor
takeover flow IS responsibility-in-action — exactly the **B2** the domain-role
research designed (`docs/domain-role-research:…/role-for-users-domain-role.md`).

**The two axes (#1059):**
- **recipe (A)** = "what an *agent* is built from" — skills/prompt/bases/
  `requested_caps`/`config_dir`. Build-time, agent-only.
- **responsibility (B)** = "what *function a principal* (user OR agent) serves in
  a session" — a `role_name` + routing `{:role, name}` + standing caps. Runtime,
  cross-principal.

A member may be an agent **built from** the `bot` recipe **carrying** the `bot`
responsibility — the two names need not match (#1059,
`recipe_responsibility_lockin_test.exs`). The `supervisor` responsibility is held
by **humans** (no recipe). The editor (§4) **assigns** responsibilities; it never
conflates them with recipes.

### 3.1 How the socialware definition declares responsibilities (data)

```
socialware-def.members : [%{uri, role_name: "orchestrator"|"bot"|"reviewer", …}]   # B1 single-holder
socialware-def.responsibilities : [
  %{name: "bot",        kind: :b1_single},
  %{name: "supervisor", kind: :b2_pool,                   # multi-holder HUMAN takeover pool
    caps: [:claim, :settle, :approve, :read_unfiltered],  # the operator cap-bundle (C3)
    quorum_policy: :any_one | :majority | :n_of_m,
    arbiter: "arbiter" | nil}
]
```

### 3.2 B1 vs B2

| | **B1 (exists)** | **B2 (new — the takeover pool)** |
|---|---|---|
| scope | per **session** | per **workspace** |
| holders | **single** (`role_name` unique per session, `role_name_conflict/3`) | **many** (a pool of N principals share R) |
| `{:role,name}` resolves to | exactly **one** URI | **fan-out** over all current holders |
| use | "the one orchestrator/bot/reviewer of THIS session" | "the **supervisor pool** watching ALL support sessions; any of N can take over; conflicts arbitrated" |
| **used by kanban today?** | **NO** (§1.3 — kanban is recipe-only, no `role_name`/routing) | NO (new) |

### 3.3 The takeover/approval/escalation loop

The verbs exist (`:claim`/`:settle`/`:approve` — `turn.ex:49,320`,
`surface.ex:20`) but have **no product surface** (operator analysis §5). The loop
reuses the generic verbs and adds B2 machinery for pool/quorum/arbiter:

1. **bot escalates** → `{from: bot, on: <signal>} -> {:role, "supervisor"}`
   delivers to the **B2 pool**. **[B2-NEW]** — multi-holder fan-out + assignment
   gate (§3.4); B1 resolves to one URI only.
2. **a human claims** → `:claim` on the `Turn` (`handle_claim`, records claimer as
   owner, `turn.ex:315,320`); turn → `mode: :copilot, status: :awaiting_human`,
   output held `:internal` (C1). **[REUSE]**.
3. **release** → `:settle` (flip held → `:external_visible`) or `:approve` (advance
   the surface page pointer). **[REUSE]**.
4. **conflicting verdicts** → the **B2 quorum Behavior** collects verdicts under
   `quorum_policy`; on conflict escalates to `{:role, "arbiter"}`. **[B2-NEW]**.

### 3.4 Where the B2 machinery lives (dep-DAG, codex-corrected)

Verified edges (`mix.exs`): `domain_session → domain_workspace → {domain_identity,
domain_agent}`; **workspace does NOT dep session**. Forced split (zero new app
edge):

- **Durable principal→responsibility assignment → `domain_workspace`** (a new
  `:assign_role` cap, sibling to role-as-data's role-authoring caps). Workspace
  already deps identity (#154) — **no new edge**.
- **Approval/quorum/arbiter Behavior → `domain_session`** (the only app with
  message replies + membership + routing; reads the assignment over the existing
  session→workspace edge). **No new edge, no cycle.**
- **Assignment-gated fan-out — `{:role,name}` expansion is a `core/routing` SEAM,
  but multi-holder resolution + validation is INJECTED from session/workspace.**
  `ezagent_core` has **no umbrella deps**; `Routing.Resolver` is pure. B1 already
  injects a resolver (`session.ex:514,519`). B2 reuses that seam: session injects
  a **multi-holder resolver** (`{:role,name}` → `[uri]` over the workspace
  assignment) **+ a validation predicate**. **NOT a one-line `expand_receiver`
  change** — a naïve fan-out would hand stale/out-of-scope principals to
  `Delivery`, which mints a narrow `:receive` cap per recipient (`delivery.ex:169,
  259`), because role resolution bypasses the `valid_member?` filter
  (`resolver.ex:373,402`) → a tenant-isolation hole. The injected resolver must
  enforce **same-workspace + current-assignment** before delivery, with a test
  proving no `:receive` cap is minted for unassigned/out-of-scope principals.
- **Assignment↔cap lifecycle is NEW state** — caps are a flat `MapSet` keyed by
  cap identity, not role-bundled (`identity.ex:55,409,421`); assigning
  `supervisor` does not auto-grant `approve`. B2 owns an explicit
  **grant-on-assign / revoke-on-unassign** binding **or** atomically re-checks
  assignment+cap at verdict-acceptance (stale holder's verdict rejected).
- **Accountability:** B2 approval caps are accountable **iff minted via the
  `Ezagent.Identity.Grant` grant path** (overwrites `granted_by`, requires
  `entity://`, `grant.ex:175,191-198`) — not via the runtime
  `granted_by_entity?/1` predicate (`capability.ex:319`, only rejects
  `system://`).
- **No new `domain.role` app** (YAGNI). socialware needs **no new edge**: it only
  *names* responsibilities as data; assignment lives in workspace, the workflow
  runs in session.

---

## 4. The editor (dual-path, one truth)

Both paths mutate **one** socialware definition:

- **Path A — declarative world FORM.** Fills the **full socialware-def**: bases
  (which the install mounts), shape, members / routing_rules / prompt_templates /
  legends (closing the `workspace_plugin_actions.ex:326` hardcoded-empty gap),
  the **adapter picker** (which `ExternalMirror.Adapter`s), and
  `visibility_policy`. Plus the SessionTemplate **composition** (`installs: [...]`).
- **Path B — in-session orchestrator conversation loop.** The orchestrator tools
  (`add_managed_member`, `define_rule_set_rule`, …, `update_template`/
  `save_template_as`, `migrate_session`) — **re-targeted from SessionTemplate
  content to the socialware definition** (§2.8) — mutate the same definition.

**One source of truth:** both terminate at the same content-addressed write on
the socialware definition. The form is a projection of the orchestrator-tool
semantics; neither owns a private copy. The `"current"` tag must publish on
author-save (skill gotcha #3) for deterministic adopt-on-create. The editor
**assigns responsibilities** (§3): **B1** — each member's `role_name`; **B2** —
supervisor-pool holders via the workspace assignment (`:assign_role`).

---

## 5. Operator de-bake (cap-gate, no named role P1-P8)

The operator analysis proved "operator" is already composed — residue = naming +
one default. The de-bake **cap-gates the management (unfiltered) read; introduces
NO named "operator"/"supervisor" role in P1-P8.** "Supervisor" is just whoever
holds the cap bundle (unfiltered-read + `:claim`/`:settle`/`:approve` + `:send`;
NOT `agent.manage` — directing the bot is `:send`, not reconfiguring it).
**"supervisor" becomes a NAMED responsibility ONLY in P9** and ONLY because
routing fan-out + the multi-holder pool need a named target.

- **C1 — rename `:operator_only` → `:internal`** (persisted `Message.visibility`
  enum, `message.ex:73,119`). Pure name finish; the binary is external-vs-internal.
  `:internal` is the **all-info superset** name and stays even if visibility later
  generalizes to a multi-audience set. **Independent of the socialware object.
  Pre-prod-first** (detail §6).
- **C2 — lift the auto-publish-vs-hold default** out of the hardcoded
  `Turn.handle_open` (`turn.ex:246`, `initial_visibility/1:615`) **into the
  socialware-def `visibility_policy.publish_policy`** (`:auto | :supervised`).
  `:auto` preserves today's behavior; `:supervised` holds turn output `:internal`
  until `:settle`. Read at `handle_open`.
- **C3 — cap-gate the operator/management (unfiltered) read.** The unfiltered
  operator projection (`recent_in_session`, includes `:operator_only`/`:internal`)
  behind `/sessions` (`RequireEntity` only, no `require_admin`) **leaks internal
  messages to any authenticated workspace user** unless a concrete
  operator-authz predicate gates it, fail-closed, re-checked on read (PR-4 §4.3a,
  codex HIGH). **C3 IS that predicate:** `render_authorized/2` (or whatever serves
  the operator unfiltered read) checks the **`read_unfiltered` cap** fail-closed.
  **P1-P8 introduces NO named "supervisor" role** — only the cap-gate. The named
  `supervisor` responsibility (which bundles this cap) lands **only in P9** (§3).
  Per-message visibility stays a real revocation primitive (`external_feed.ex:293`),
  rename only.

---

## 6. C1 detail — the persisted-enum rename (pre-prod-first)

`Message.visibility :: :external_visible | :operator_only` → `:internal`
(`message.ex:73,119`, `Ecto.Enum`, default `:external_visible`). It is a
**persisted enum value** stored as a string — doing it *after* prod is a live data
migration over real history; doing it *now* is a dev-only `db.reset`. That
asymmetry is why C1 is **pre-prod-first**.

> The column is a **plain string with a default, NOT a DB enum constraint**
> (`…20260618000400…:6-9`, `pg_baseline.exs:54`) — so C1 is an `Ecto.Enum` value
> rename + a one-shot `UPDATE`, not a type-altering migration. "Pre-prod-now"
> rests on **there being no prod message history yet**; confirm before P1.

- **Touches (~15-18 files):** `message.ex`; `message_store.ex`; `turn.ex`
  (`hold_visibility`, `initial_visibility`); `settlement.ex`; `chat_feed.ex`;
  `external_feed.ex`; the two migrations; ~6-9 test files; the invariant.
- **Data migration:** `UPDATE messages SET visibility='internal' WHERE
  visibility='operator_only'` + fail-closed default. Dev: `db.reset`.
- **Atomically, NOT in parallel** — rename-collisions across parallel branches are
  the top regression source. **Ride the #1059 deferred `Role`→`Recipe` symbol-
  rename window** (one collision-audit).

---

## 7. Phased plan (P0-P9) — dep-DAG, blast radius, per-phase gate

The base/socialware/fixture model **re-derives** the phases. Key changes vs the
prior revision's plan: **P0 is now the concepts/definition doc (§0 itself,
landed as `docs/`)** — the prior P0 (de-hardcode behavior-set) is now **P3**.
**P1 = C1 `:internal` (pre-prod-early).** The **security cap-gate (P8) is NOT
deferred past any unfiltered operator read.** **P9 = supervisor named
responsibility + B2 pool + fan-out + quorum/arbiter + takeover UI** (the 4
sub-steps), last. Each phase is independently landable + verifiable with a named
gate.

```
   P0 (concepts/definition doc — §0, landed as docs/)        foundational; pre-prod
        │
   P1 (C1 :internal enum rename) ────────────┐  (independent; pre-prod CRITICAL)
   P2 (AnonIngress) ──┐                      │  (independent refactor)
        │             │                      │
        ▼             │                      │
   P3 (de-hardcode behavior-set → data: installs field) ◄── foundational; pre-prod
        │
        ▼
   P4 (socialware definition object + install relation + public_view split)   needs P3
        │  └─ re-points P2's anon gate (P2→P4 edge)
        ▼
   P5 (extract socialware config out of SessionTemplate + re-target orchestrator tools + migrate sessions)   needs P4
        ▼
   P6 (publish_policy in socialware-def visibility_policy)   needs P4
        ▼
   P7 (dual-path FORM editor)                                needs P4/P5
        ▼
   P8 (cap-gate the operator/management unfiltered read — the security fix, NO named role)   pre-prod; ride #1059
        ▼
   P9 (supervisor named responsibility + B2 pool + fan-out + quorum/arbiter + takeover UI — 4 sub-steps)   needs P8 + P7; defer (L)
```

| Phase | What | Blast | Pre-prod? | Independent gate (verifiable) |
|---|---|---|---|---|
| **P0 — concepts/definition doc** | land §0 as a standalone doc under `docs/` (the socialware authoring guide: base/socialware/fixture taxonomy, the shape concept, how to write a socialware). **No code change.** | **S** | **NOW** | the doc exists at `docs/socialware-concepts.md` (EN + `.zh_cn`); the taxonomy matches code (5 bases `defmodule`-confirmed; chat=world Conversation; kanban=recipe-only status cited); a reviewer can author a new socialware from the doc alone |
| **P1 — C1** | rename `:operator_only`→`:internal` + data-migrate + invariant | **M** | **NOW (persisted enum)** | extend `no_customer_concept_test` to forbid `:operator_only`; full `mix test` 0 failures |
| **P2 — AnonIngress** | `admit_anonymous_participant` primitive + `AnonIngress` shim; collapse +8 dup groups | **M** | any time | the +8 `cross_file_duplicate_fn_groups` collapse to one primitive + one shim; INV-1/2/2a tests; #1060 Gate 2 green |
| **P3 — de-hardcode behavior-set → data** | `installs: [...]` on SessionTemplate; `create_session` reads it to thread the `:kind_base` set, replacing the hardcoded `chat_behaviors`/`socialware_behaviors` at `session_creator.ex:330-338,424-430` + `hello/app.ex:29-35`. **Ship a TEMPORARY built-in socialware catalog** — a code-level `socialware-ref → behavior-set` map seeding two refs (`"chat"`→`chat_behaviors`, `"socialware"`→`socialware_behaviors`). P4 then **replaces the catalog** with the ConfigStore-backed socialware-def resolver (the catalog is the migration seam, deleted in P4). | **M** | **NOW** (call-site choice today) | a session created from a template whose `installs` names `"socialware"` boots with Turn/Surface in its `:kind_base` **via data + the built-in catalog, not a call-site branch**; a `"chat"` template boots without them; full `mix test` 0 failures — **no dependency on P4** |
| **P4 — socialware definition + install relation + public_view split** | `template://<ws>/socialware/<name>` definition (config-as-data sibling of role recipe); per-install `ConfigObject` record; split `public_view` per §2.4; **delete the P3 built-in catalog** (replace with ConfigStore-backed resolver) | **L** | NOW | a gate that **no `public_view` boolean is read** anywhere; identity resolves via the install record, anon-gate via socialware-def `web_anon_access`; a socialware installed onto a session mounts its bases via `effective_set` `extra_part`; hello rewired |
| **P5 — extract socialware config out of SessionTemplate + re-target orchestrator tools + migrate sessions** | move `members`/`routing_rules`/`prompt_templates`/`legends`/`orchestrator_template_uri` from SessionTemplate content INTO the socialware definition; **re-target the orchestrator tool catalog + `migrate_session` to the socialware definition**; migrate existing sessions | **L** | NOW | the orchestrator tools mutate the socialware-def (not template content); `migrate_session` re-points the socialware-def version; a non-socialware orchestrated session still composes its team (per OQ-2 resolution); round-trips |
| **P6 — C2 publish_policy** | lift auto/hold default into socialware-def `visibility_policy.publish_policy`; `handle_open` reads it | **S** | NOW | `:auto` preserves today; a `:supervised` turn stays `:internal` until `:settle` |
| **P7 — dual-path FORM editor** | world form fills full socialware-def + adapter picker + visibility; SessionTemplate composition picker; converge with orchestrator loop on one def | **M** | NOW | form authors non-empty members/routing/prompt_templates/legends + adapter set + an `installs` composition; round-trips with `save_template_as`; `"current"` tag published on save |
| **P8 — cap-gate the operator/management unfiltered read (the security fix, NO named role)** | `read_unfiltered` cap fail-closed gate on the operator projection (`recent_in_session` / `render_authorized`); re-homes PR-4 authz fix; **NO named "supervisor"/"operator" role introduced** | **S-M** | pre-prod; ride #1059 | operator unfiltered read gated by the `read_unfiltered` cap fail-closed (the PR-4 disclosure gate); a non-holder authenticated workspace user cannot read `:internal` messages; relabel-only elsewhere |
| **P9 — supervisor named responsibility + B2 pool + fan-out + quorum/arbiter + takeover UI (4 sub-steps)** | see §7.1 | **L** | defer (post-prod ok) | per sub-step gates in §7.1 |

**Recommended order:** P0 (concepts doc, pre-prod) → P1 (cheapest, pre-prod-
critical) → P2 (independent) → P3 (foundational) → P4 (foundational L) → P5 → P6
→ P7 → P8 (security, ride #1059) → P9 (last, deferred). P1/P2 land in parallel
(no shared file). **C1 (P1) stays pre-prod-first.** **No named operator role
lands in P1-P8** — P8 introduces only the `read_unfiltered` cap-gate; **`supervisor`
is a NAMED routing responsibility ONLY in P9**, where the fan-out target +
multi-holder pool need a name. **The security cap-gate (P8) is NOT deferred past
any unfiltered operator read** — if a read surfaces before P8, it must be
cap-gated at that point, not left open.

### 7.1 P9 — the four bounded sub-steps

| Sub-step | Host | What | Gate |
|---|---|---|---|
| **P9-a assignment** | `domain_workspace` | principal→responsibility assignment + `:assign_role` cap; **`supervisor` becomes a named responsibility here** | assigning/unassigning a holder is durable + cap-gated; **no new app edge** |
| **P9-b approval workflow** | `domain_session` | approval/quorum/arbiter Behavior (verdict collection, `quorum_policy`, arbiter escalation) | a quorum→arbiter escalation test; stale-holder verdict rejected (assignment↔cap atomicity) |
| **P9-c fan-out seam** | `core/routing` + **session-injected resolver** | `{:role,name}`→`[uri]` multi-holder resolution + **same-ws + current-assignment validation** | a test proving fan-out delivery mints **no `:receive` cap** for unassigned/out-of-scope principals (the load-bearing tenant-isolation gate) |
| **P9-d takeover UI** | the editor (`ezagent_plugin_world`) | claim/approve/escalate **product surface** (live E2E is the coordinator's job, not codex's) | the UI drives `:claim`/`:settle`/`:approve` (no raw `mix ezagent` dispatch) |

### 7.2 Cross-phase couplings

- **P0 → (none):** the concepts doc is standalone; no code dep.
- **P3 → P4 (NOT a hard dep):** P3 lands self-contained on a **temporary built-in
  socialware catalog** (`socialware-ref → behavior-set`), so it needs no
  socialware-def records. P4 then **replaces** the catalog with the
  ConfigStore-backed resolver + per-install record (the catalog is the deletion
  seam). P3 is thus independently landable before P4 exists.
- **P2 → P4 (anon gate):** PR-3 reads the anon gate. If P2 first, it reads
  `public_view?/1` and re-points to `web_anon_access` when P4 lands (one resolver
  swap inside the single primitive). If P4 first, P2 wires straight to it.
- **P5 → P4:** the config-extract needs the socialware definition to exist first.
- **P6/P7 → P4:** `publish_policy` is cleanest in the socialware-def
  `visibility_policy`; the form picks adapters against the socialware-def.
- **P8 → PR-4 fix:** superseding PR-4 is safe only once P8 provides the
  `read_unfiltered` cap-gate (§8.2).
- **P9 → P8 + P7:** B2 needs the `read_unfiltered` cap (P8) to bundle into the
  `supervisor` responsibility + the editor (P7) to assign holders + drive
  takeover. P9 is otherwise additive (new state in workspace + session + routing)
  and shares no file with P0-P7.

### 7.3 Dep-DAG legality (zero new app edge)

Hosting the install-resolver needs the socialware definition (`ConfigStore`,
identity ↓), bases via mount (core ↓), `adapters` (external_mirror ↓). In-umbrella
deps (`origin/main` `mix.exs`): `socialware → core, identity, session,
external_mirror, ui`; **session, identity, external_mirror do NOT dep socialware**
→ **socialware is the only legal host** for the install-resolver. The install
**mechanism** (mount) is in **core** and already declaration-free (§2.2), so **no
app must declare another's bases** — the plugin-isolation property. The acyclic
gate (`im_session_agent_acyclic_test.exs`) + undeclared-dep gate
(`undeclared_umbrella_dep_test.exs`) stay green; #1060 Gate 1/2 untouched by
P0-P7.

**B2 (P9) — also zero new app edge** (`mix.exs`): `domain_session →
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

## 8. Subsumption (comms PR-3 folded / PR-4 superseded; autoservice stays a fixture)

### 8.1 PR-3 (AnonIngress) — FOLDED as the customer's entry to the surface base

The anonymous customer reaching the socialware's external surface **is** comms
PR-3: the `Ezagent.Socialware.AnonAdmission.admit_anonymous_participant/2` domain
primitive (mint→spawn→join-AS-anon→mount-caps; INV-1 no system principal, INV-2
caps best-effort, INV-2a fail-closed reuse) + the thin
`EzagentWeb.Socialware.AnonIngress` web shim. In the model: *"how a customer
reaches the socialware's `:pull` web adapter (the surface base)."*

- The primitive's gate re-points to the **socialware-def
  `visibility_policy.web_anon_access`** (§2.4 row 3) via the
  session→install→socialware-def→web-adapter resolver. **One cross-phase edge:**
  PR-3 reads the anon gate, re-points when the install relation + socialware-def
  land (§7 dep-DAG).
- Placement forced by the DAG: the primitive lives in
  **`ezagent_domain_socialware`** (needs `AnonUser`/`AnonBinding` local +
  `Membership` (session ↓) + `Entity`/`Invocation` (core ↓)).

### 8.2 PR-4 (world Conversation onto contract axis) — SUPERSEDED, fix re-homed

PR-4's world-on-contract convergence is an internal transport cleanup the
operator-debake + editor subsume. But it must not drop its one load-bearing,
security-critical finding:

> **PR-4 §4.3a (codex HIGH):** the unfiltered operator projection
> (`recent_in_session`, includes `:operator_only`/`:internal`) behind `/sessions`
> (`RequireEntity` only, no `require_admin`) **leaks internal messages to any
> authenticated workspace user** unless a concrete operator-authz predicate gates
> it, fail-closed, re-checked on read.

**Re-homes onto P8 (C3):** the **`read_unfiltered` cap-gate IS the operator-authz
predicate.** `render_authorized/2` (or whatever serves the operator unfiltered
read) checks the `read_unfiltered` cap fail-closed. **Superseding PR-4 is safe
only when P8 lands** — not optional cosmetic. The *named* `supervisor`
responsibility that bundles this cap lands only in P9.

### 8.3 autoservice stays a fixture

autoservice is **a fixture = chat used for the customer-service business**
(§0.2). The autoservice reframe doc confirms it is a project name, not a concept.
This SPEC introduces no "autoservice" concept, schema key, or layer; autoservice
is a configured instance of the chat socialware (a customer-service team/persona +
a customer-facing adapter).

---

## 9. Open questions for the lead

1. **`Turn` classification (§0.4).** `Turn`'s moduledoc calls it "Socialware
   orchestration state machine," which sits between "base" and "shape." This SPEC
   classifies `Turn` as **chat's shape** (flow-specific: a kanban has no turns),
   not a base (general: reusable across unrelated socialwares). Confirm — or is
   `Turn` part of the orchestrator base?
2. **Team/routing home for non-socialware orchestrated chat (§2.8 OQ-2).** Move
   `members`/`routing`/`legends` out of SessionTemplate into the socialware
   definition for *all* sessions — making **plain orchestration its own
   installable socialware** (`template://<ws>/socialware/<chat-team>`, fully
   symmetric, recommended) — or keep a generic base composition on the
   SessionTemplate (hedges migration)? This shapes P5's blast radius.
3. **`web_anon_access` granularity.** The split (§2.4) puts the anon gate on the
   web adapter (per-adapter already). Confirm anon is a web-adapter attribute,
   not a socialware-global flag. (Recommend per-adapter.)
4. **Binary visibility horizon.** Multiple external adapters share one
   `external_visible` slice today. If two customer channels ever need *different*
   curations of one session, binary visibility → audience-set is a real M→L
   generalization that should precede prod. The name `:internal` is the
   **all-info superset** and stays even if visibility later goes multi-audience.
   Near-term need? (Recommend: keep binary, YAGNI.)
5. **Install mechanism on the Session host.** §2.2 confirms `effective_set`'s
   `extra_part` admits undeclared behaviors and kanban proves it on
   `Entity.Agent`. Confirm the SAME mount path on the Session host is acceptable
   (it is core + declaration-free, so plugin-isolation holds) — or does the lead
   want the Session host to *declare* socialware bases (tighter, but breaks the
   isolation North Star)? (Recommend: declaration-free mount.)
6. **Editor convergence depth.** Path A (form) + Path B (orchestrator loop, now
   re-targeted to the socialware-def, §2.8) both mutate the def. Confirm the form
   is a thin projection of the orchestrator-tool semantics, not a parallel write
   path.
7. **B2 wanted now, or is B1 + P8 enough?** A single-operator socialware is fully
   served by B1 + the P8 cap-gate. The multi-holder pool + quorum/arbiter (B2,
   P9) is real new work. Confirm the multi-supervisor + conflicting-verdict
   scenario is near-term before building P9. (Recommend: ship P8, defer P9.)
8. **`role_name` uniqueness for the pool.** Relax `role_name_conflict/3` to allow
   many holders, **or** keep B1's unique alias + a separate workspace assignment
   for B2? (Recommend the latter — two facets.)
9. **Two instances of the SAME behavior-owning socialware on one session (codex
   Q5 HIGH).** Supporting e.g. two chat desks on one session needs app-scoped
   slice keys + app-scoped action routing (Behaviors own singleton slices today
   — `Turn`/`:turns`, `Surface`/`:surface`). This SPEC scopes it OUT (distinct
   socialwares per session — chat + kanban — is the near-term need and works
   without it). Confirm two-of-the-same is not near-term.
10. **P0 doc location + bilingual.** Land §0 as `docs/socialware-concepts.md`
    (EN) + `docs/socialware-concepts.zh_cn.md` (中), per the bilingual docs
    convention? (Recommend yes.)

---

## 10. Codex adversarial-review verdict

> *Static-only review (codex/gpt-5.5, no build/mix/tests) against `origin/main`,
> reading the rewritten spec + every cited source. Run 2026-06-28 after the
> complete rewrite to the base/socialware/fixture model. All fixes folded back
> into §0-§9 before push.*

### 10.1 Review questions + verdicts

| Q | Codex verdict | Disposition |
|---|---|---|
| 1 — is the base/socialware/fixture taxonomy code-accurate? (esp. kanban recipe/responsibility/routing status, chat=world Conversation, hello=Surface base) | SEE REVIEW OUTPUT | (folded) |
| 2 — is P0 concepts doc clear + correct? | SEE REVIEW OUTPUT | (folded) |
| 3 — is the decouple a real simplification vs a new layer? | SEE REVIEW OUTPUT | (folded) |
| 4 — does the install-relation cleanly replace public_view? | SEE REVIEW OUTPUT | (folded) |
| 5 — is the phased plan safe + each phase landable + is the security cap-gate correctly not-deferred? | SEE REVIEW OUTPUT | (folded) |
| 6 — any new concept that should reuse an existing one? | SEE REVIEW OUTPUT | (folded) |
| 7 — any base misclassified? | SEE REVIEW OUTPUT | (folded) |

### 10.2 Prior passes (carried forward)

The prior revision's three codex passes (core model; responsibility layer B1/B2;
model-rewrite decouple) are preserved in spirit — their load-bearing findings all
carry into this rewrite:

- The `effective_set` undeclared-admit (`behavior_set.ex:167-172`) + mount
  rewrites `:kind_base` (`kind.ex`) + `ConfigObject` shape
  (`config_object.ex:16-20`) — substrate real (Q1 SOUND).
- kanban is `roles/0` recipe (`application.ex:63-64`) mounted on `Entity.Agent`
  whose base declares no Kanban (`agent.ex:80-84,94-113`) — precedent correctly
  scoped (Q2 SOUND).
- The install relation cleanly replaces `public_view` (Q4 SOUND-WITH-FIXES — the
  10th site `WorkspacePlugin.tsx:190-198` added).
- "Two same-type socialware instances" is a genuine mechanism limit (Q5 HIGH) —
  scoped OUT as OQ-9.
- No `socialware://` scheme on main (six schemes `entity session template
  resource workspace system`, `plugin.ex:88,263-268`) — the rewrite correctly
  avoids it; the socialware-def resolves via a sibling `"socialware"` ConfigStore
  resolver, not a hidden new registry (Q7 FIXED).
- P3 (was P0) lands self-contained on a temporary built-in catalog, not a hard
  dep on P4 (Q6 FIXED).
- The B2 `core/routing reaches assignment` row corrected to the
  **injected-resolver seam** (§3.4, §7.3); accountability reworded to "via the
  `Identity.Grant` grant path."

---

## Method / provenance

- All reads via `git show origin/main:<path>` (`67b49303`) — no working-tree trust.
- **Base/socialware/fixture reframe investigation (2026-06-28):**
  - Bases: `behavior/template.ex:1,11-29` (orchestrator/Template);
    `behavior/surface.ex:1,2-6` (hello/surface); `ezagent_domain_pty/.../pty.ex:1`;
    `ezagent_core/.../sandbox.ex:1`; `ezagent_domain_agent/.../cc_headless_agent.ex:1`.
  - chat = world Conversation: `world/conversation_actions.ex:1` +
    `world/conversation_data.ex:1` (generic, derived vs MessageStore/Message) +
    `assets/src/components/Conversation.tsx`; `entity/session.ex:56-104,86-91`
    (`chat_behaviors`/`socialware_behaviors` = base+Turn+Surface).
  - kanban status: `ezagent_plugin_kanban/application.ex:64,74,77,84` (`roles/0`
    recipe, `passive: true`, `behaviors: [Kanban]`); `agent.ex:81,94-104`
    (Entity.Agent `base_behaviors` declares NO Kanban); **grep `role_name` /
    `{:role,` / `routing_rules` over `apps/ezagent_plugin_kanban/**` = EMPTY**
    (recipe-only, no responsibility/routing today).
  - kanban board/task shape: `behavior/kanban.ex` (`add_node`/`set_stage`/
    `claim_node`/`set_status`/`attach_artifact`/`sync_github`/`push_pr`/
    `set_board_config` — definite business semantics).
  - Turn = shape: `behavior/turn.ex:1,2-6` ("Socialware orchestration state
    machine", `:turns` slice).
- Decouple-reframe (carried from prior revision, re-verified): `entity/session.ex`,
  `behavior_set.ex:160-172`, `runtime.ex:160,301-307`, `kind.ex:535,561,879`,
  `mount_detach.ex:72,101`, `role.ex:46-66`, `role_registry.ex:3-29,55-68`,
  `config_object.ex:14-23`, `config_store.ex`, `session_creator.ex:338,430`,
  `hello/app.ex:35`, `session_template.ex:47-59,757-764`, `public_view.ex:38,108`,
  `anon_user.ex:99-154`, `membership.ex:371,801,818`, `app.ex:31,35`,
  `workspace_plugin_actions.ex:326,334`, `chat_feed_controller.ex:108`,
  `external_feed_controller.ex:131`, `workspace_plugin_data.ex:189,211`.
- Orchestrator tool catalog: `orchestrator/tools.ex:135,376,555,661,707,756,760`.
- Live contract: `adapter.ex:167-377`.
- Synthesized from: `docs/socialware-operator-analysis`,
  `docs/socialware-template-model`, `docs/comms-pr34-spec`,
  `docs/domain-role-research`, `docs/together/2026-06-26/notes/autoservice-flavor-agnostic-reframe.md`.
- Reconciliation: #1047/#1060 (`comms_substrate_elimination_test.exs`), #1048
  (role-as-data), #1059 (`recipe_responsibility_lockin_test.exs`), #103-105
  (kanban-as-role), #46.
