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
>
> **REVISE (2026-06-28, same day).** Two lead decisions folded: **(1) OQ-1 closed
> as (a)** — the orchestrator's "base-ness" IS the EXISTING combo (recipe via
> role-as-data + `Orchestrator.Tools` + `SessionManager`), classified conceptually
> as the "orchestration base" with **zero new Behavior / zero new code**;
> `Behavior.Template` stays template-content storage (NOT a session-mounted
> runtime base); no `Behavior.Template` refit; no new `Behavior.Orchestrator`;
> OQ-1 removed from §9. **(2) P10 added** — a **codex-runnable automated** E2E
> suite (not a manual live agent-browser run) covering the full socialware
> lifecycle (author→install→run customer→run supervisor→security→publish_policy)
> as the completion gate; reuses the `autoservice_tier1_seed_test.exs` harness
> pattern; placed after P9 (final phase). Re-review in §10.3.
>
> **REVISE-2 (2026-06-28, same day).** Lead decision resolves **OQ §9 item 11**
> (the P10 "cc-woven-answer soul not automatable" caveat). Instead of P10's
> customer-side assertion #3 proving only routing + `MessageStore` landing via a
> non-cc echo-style flavor, **P10 now uses a codex-orchestrator** — a **codex**
> flavor wired as an **orchestrator** (the `OrchestratorRole` recipe + the shared
> tool-catalog, so codex can call `kb_query` and weave a real LLM reply). This
> makes P10's customer-side assertion test a **REAL LLM orchestrator**, and
> codex's headless/exec mode is **more deterministic/stable for automated E2E**
> than cc's PTY + startup-dialog path (the #505 blockers). **OQ §9 item 11 is
> CLOSED** (removed from the open list); a residual codex auth/test-credential
> setup requirement is stated precisely in §7.4 as a test-setup requirement, not
> an open question. P10 gains a **prerequisite sub-step (P10.0): implement
> codex-orchestrator** — mirror cc's `OrchestratorRole` recipe + seed onto the
> codex flavor; the codex plugin ALREADY has the bridge infra
> (`bridge_adapter.ex`/`bridge_sidecar.ex`/`app_server.ex`/`codex_agent.ex`/
> `codex_remote_agent.ex`); **reuse the shared executor (`SessionManager.run_tool`)
> + bridge-token (`AgentBridge.TokenStore`), both flavor-blind** (autoservice
> reframe Layer A) — do NOT duplicate cc's tool-catalog/executor. Re-review in
> §10.4.

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
│     • orchestrator  = the orchestration base — the EXISTING combo    │
│       (recipe via role-as-data + Orchestrator.Tools +                │
│        SessionManager executor); NO new Behavior, NO                 │
│        Behavior.Template refit (lead decision, OQ-1 closed (a))      │
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
| **orchestrator** (the orchestration base — **lead decision, OQ-1 closed (a)**) | `Ezagent.Behavior.Template` (recipe-content carrier) + `Orchestrator.Tools` + `SessionManager` | the **orchestration base** — conceptually ONE base among several, but its "base-ness" is the **EXISTING combo** with **zero new Behavior/code**: the orchestrator recipe rides `Behavior.Template`'s `:template` content slice (team/routing/persona/tool-catalog recipe, via role-as-data) + `Orchestrator.Tools` (the tool catalog: `add_managed_member`, `define_rule_set_rule`, `define_prompt_template`, `define_legend`, `save_template_as`, `migrate_session`) + `SessionManager` (the executor). **`Behavior.Template` stays exactly what codex found it** — template-CONTENT storage (the `:template` slice on the `SessionTemplate`/`AgentTemplate` Kinds with `:read`/`:write`/`:instantiate`), **NOT a session-mounted runtime base** (Session `behaviors/0` does not include it). **No `Behavior.Template` refit; no new `Behavior.Orchestrator`.** When a socialware "composes the orchestrator base," it means the socialware definition's team/routing/persona ride the `Behavior.Template` content substrate (via SessionTemplate/ConfigStore) and the orchestrator agent + tool catalog execute against it. | `behavior/template.ex:1,11-29` (moduledoc: "dispatchable template-CONTENT Behavior for the AgentTemplate + SessionTemplate Kinds"); tools at `orchestrator/tools.ex:135,376,555,661,707,756,760`; **Session `behaviors/0` does NOT include `Behavior.Template`** (`entity/session.ex:56-93`) |
| **hello/surface** | `Ezagent.Behavior.Surface` | the render/external-surface substrate — owns the `:surface` slice; immutable page versions + an `:approved` pointer; `:put_version`/`:approve`/`:commit_settlement` actions | `behavior/surface.ex:1,2-6` (moduledoc: "Immutable socialware page surface") |
| **pty** | `Ezagent.Behavior.Pty` | terminal/PTY substrate | `ezagent_domain_pty/lib/ezagent/behavior/pty.ex:1` |
| **sandbox** | `Ezagent.Behavior.Sandbox` | per-agent config_dir + Kind.Template plugin-extension substrate | `ezagent_core/lib/ezagent/behavior/sandbox.ex:1` |
| **cc-headless-agent** | `Ezagent.Behavior.CcHeadlessAgent` | the cc SDK sync-result-persistence + headless-agent substrate | `ezagent_domain_agent/lib/ezagent/behavior/cc_headless_agent.ex:1` |

> **DECIDED — OQ-1 closed as (a), no new concept (lead decision, 2026-06-28).**
> The lead's final model mapped "orchestrator = process/agent+tools base
> (`Ezagent.Behavior.Template`)." Code-verification + codex both confirmed
> `Behavior.Template` is **template-CONTENT storage** (the `:template` slice on
> the `SessionTemplate`/`AgentTemplate` Kinds with `:read`/`:write`/`:instantiate`
> actions), **NOT a session-mounted runtime base** — Session behavior sets
> (`entity/session.ex:56-93`) do not include it. **The lead resolved this as
> option (a): the orchestrator's "base-ness" IS the EXISTING combo** — the
> orchestrator recipe via role-as-data + `Orchestrator.Tools` (the catalog) +
> `SessionManager` (the executor) — classified conceptually as the
> "orchestration base" but with **ZERO new Behavior and ZERO new code.**
> `Behavior.Template` stays exactly what codex found it (template-CONTENT
> storage, NOT a session-mounted runtime base). **There is no `Behavior.Template`
> refit and no new `Behavior.Orchestrator`** — anywhere in this SPEC. When a
> socialware "composes the orchestrator base," it means the socialware
> definition's team/routing/persona ride the `Behavior.Template` content substrate
> (via SessionTemplate/ConfigStore) and the orchestrator agent + tool catalog
> execute against it. OQ-1 is removed from the open-questions list (§9).

**Socialware.** A human+program hybrid flow that composes one or more bases + a
**shape** and is directly user-operable. Two verified instances:

- **chat** = the world Conversation surface. Generic — **NO business semantics**.
  `Ezagent.World.ConversationActions` (`conversation_actions.ex:1`, moduledoc:
  "Socket-side conversation dispatch handlers … pure data shaping lives in
  `ConversationData`") + `Ezagent.World.ConversationData`
  (`conversation_data.ex:1`, moduledoc: "Read-path + message construction …
  derived against `MessageStore`/`EntityPresenter`/`Message` — NOT [retired]
  `SessionContext`") + `Conversation.tsx`
  (`apps/ezagent_plugin_world/assets/src/components/Conversation.tsx`). The chat
  **socialware** composes the **orchestrator base** (the existing recipe+tools+executor
  combo — `Behavior.Template` recipe content + `Orchestrator.Tools` + `SessionManager`,
  no new Behavior) + the **surface** base (`Behavior.Surface`, the
  rendered conversation surface) + the **conversation shape** (`Behavior.Turn`, the
  turn state machine — see §0.4). **Current-state precision (codex Q1 fix):** today
  the *plain* chat path (`Session.chat_behaviors/0`, `entity/session.ex:71-93`)
  does **NOT** mount Turn/Surface — only the *socialware/hello* path
  (`Session.socialware_behaviors/0`, `session.ex:86-91`) mounts base+Turn+Surface.
  So "chat composes Turn+Surface" describes the **target socialware** model + the
  hello/socialware session path, not today's plain chat session (which is just the
  base). P3 unifies this via the `installs` data field.
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

> **Precision (open for the lead, §9 item 1):** `Turn`'s moduledoc calls it
> "Socialware orchestration state machine," which sits between "base" and
> "shape." The clean classification: a **base** is general (reusable across
> unrelated socialwares); a **shape** is flow-specific. `Turn` is flow-specific
> (conversation only) → shape. `Surface` is general (any rendered external
> surface) → base. This SPEC classifies `Turn` as chat's shape. Confirm.

### 0.5 How a developer writes a new socialware

> **Scope note (codex Q2 fix).** This describes the **target authoring model**
> once P3-P7 land. P0 (this doc) teaches the *concepts*; the concrete `installs`
> schema + socialware-definition resolver land in P3/P4. Responsibilities are
> **B1 only** (`bot`/`reviewer`/`orchestrator`) through P8; the named
> `supervisor` responsibility + B2 pool authoring is **P9-target** (§3, §7.1) —
> do not author `supervisor` before P9.

1. **Pick the bases** your flow needs: does it need the orchestration base
   (orchestrator = the existing recipe+tools+executor combo, no new Behavior)?
   a rendered external surface
   (surface/`Behavior.Surface`)? a terminal (`Behavior.Pty`)? a sandbox
   (`Behavior.Sandbox`)? a cc headless agent (`Behavior.CcHeadlessAgent`)?
2. **Define the shape** — the flow-specific behavior(s) + recipe (team,
   routing_rules, prompt_templates, legends, orchestrator_template_uri). If the
   flow is a conversation, reuse `Behavior.Turn`; if a board, reuse
   `Behavior.Kanban`; if novel, author a new flow Behavior.
3. **Declare B1 responsibilities + routing** (axis B, §3) — name each
   responsibility (e.g. `bot`, `reviewer`, `orchestrator`), assign `role_name`
   per member (B1 single-holder), and write `{:role, name}` routing rules.
   (Supervisor/B2 pool authoring is P9-target — see §3, §7.1.)
4. **Optionally wire an external-surface base** — add `adapters`
   (`ExternalMirror.Adapter` ids + config) so the socialware speaks to Feishu /
   Slack / a web feed; set `visibility_policy.web_anon_access` if anonymous
   customers should reach the surface base.
5. **Author the definition as config-as-data** — the socialware definition
   object (§2.3), a sibling of the role recipe on the same `ConfigStore`/
   `ConfigObject` substrate, addressed `config://<ws>/socialware/<name>` (§2.3
   fix). Install it onto sessions via the SessionTemplate composition
   `installs: [...]` field (§2.1).

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
  not treat orchestrator as the singular foundation. (And note: the orchestrator
  "base" is the **existing recipe+tools+executor combo** — `Behavior.Template`
  recipe content + `Orchestrator.Tools` + `SessionManager` — with **no new
  Behavior and no `Behavior.Template` refit**; `Behavior.Template` stays
  template-content storage, not a session-mounted runtime — §0.2 DECIDED.)

---

## 1. Current-state — what exists vs what is new

All citations verified against `origin/main` (`67b49303`).

### 1.1 The bases (exist)

All five bases in §0.2 are `defmodule`-confirmed on `origin/main`. The
orchestrator base is the **existing combo** (lead decision, OQ-1 closed (a)):
`Behavior.Template` carries the `:template` content slice (team/routing/persona)
on the SessionTemplate Kind (template-content storage, NOT a session-mounted
runtime base — unchanged), and the orchestrator tool catalog
(`orchestrator/tools.ex`) + `SessionManager` execute against it. **No new
Behavior, no `Behavior.Template` refit.** The surface base
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
session-context/business module — generic, no business semantics. **Current-state
precision (codex Q1 fix):** the *plain* chat path (`Session.chat_behaviors/0`,
`entity/session.ex:71-78`) does **NOT** mount Turn/Surface — it is base-only.
Only the *socialware/hello* path (`Session.socialware_behaviors/0`,
`session.ex:86-91`) mounts base+Turn+Surface. So the chat **socialware** (with
Turn/Surface) is reachable today only via the hello spawn path (§1.5), not the
world "New session" form. P3 unifies both paths onto the `installs` data field.

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
addressed `config://<ws>/socialware/<name>` — an **opaque ConfigStore subject**
(exactly how `RoleRegistry` addresses role recipes at `config://<ws>/role/<name>`,
`role_registry.ex:78-88`), **NOT a spawnable Template Kind** (codex Q3 fix:
current template spawn supports only `agent` and `session` types,
`application.ex:773-786`; using `template://.../socialware` here would imply a
hidden Template Kind that does not exist). **Precision:** it does **not** reuse
`RoleRegistry` verbatim — that resolver is role-specific, fixed to key `"role"`
(`role_registry.ex:55-68`); the socialware resolves through a **sibling resolver
keyed `"socialware"`** over the same `ConfigStore`. Nor is it a `%Role{}` — that
struct has no `adapters`/`visibility_policy` (`role.ex:46-54`); the socialware
definition is a **sibling struct**. What is reused is the **mechanism**
(config-as-data `ConfigObject` + `ConfigStore` cascade + mount + `CapMint`), not
the role-specific shell. **NO new scheme** — `config://` is the existing
ConfigStore subject namespace role already uses (it is NOT one of the 6 Kind URI
schemes `entity session template resource workspace system`, `plugin.ex:88,263-268`;
it is a ConfigStore-internal subject, not a Kind). The two fields a role recipe
lacks:

```
config://<ws>/socialware/<name>             # installable socialware definition (config-as-data; ConfigObject, key "socialware"; opaque subject, NOT a Kind)
├── bases         : [Ezagent.Behavior.Surface, Ezagent.Behavior.Pty, …]        # REUSE: the per-instance SESSION-MOUNTED set the host mounts via :kind_base (Surface/Pty/Sandbox/CcHeadlessAgent — Behaviors that own a session slice). NOTE: the orchestrator base is NOT in this list — it is NOT session-mounted; its recipe rides Behavior.Template on the SessionTemplate Kind (see orchestrator_template_uri below) + Orchestrator.Tools + SessionManager (the existing combo, no new Behavior).
├── shape         : [Ezagent.Behavior.Turn, …]                                 # the flow-specific behaviors (chat's turn; kanban's board/task)
├── members       : [%{uri|source_template_uri, role_name, …}]                 # the socialware's slice of the team (B1 responsibility)
├── routing_rules : [%{matcher, receivers, rule_set, …}]                       # {:role, name} routing
├── prompt_templates / legends / orchestrator_template_uri                    # the orchestration recipe (Behavior.Template content substrate — NOT session-mounted; OQ-1 closed (a))
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
| 6 | `app.ex:31,35` (hello) — writes `public_view: true` + `socialware_behaviors()` | (a)+(b) at create | hello installs `config://<ws>/socialware/hello-<n>` (web adapter w/ `web_anon_access: true`) — the **mount path replaces the hardcoded `socialware_behaviors()`** |
| 7 | `workspace_plugin_actions.ex:334` — world toggle writes `public_view` | (a)+(b) authored | the form (§4) authors/installs the socialware-def (web adapter w/ anon) |
| 8 | `chat_feed_controller.ex:108` + `external_feed_controller.ex:131` — public controllers call `public_view?/1` as ingress gate | (b) per-route anon gate | re-point to (2); in P2 these collapse into the `AnonIngress` shim (§8) — ONE chokepoint |
| 9 | `workspace_plugin_data.ex:189,211,256-258` — world read-model `public_view?/1` (renders the badge) | (a) identity, for display | reads the **install record** |
| 10 | `WorkspacePlugin.tsx:190-198` (React) — the form payload still **sends `public_view`** | (a)+(b) authored at the UI | the form sends an **install + adapter** payload — the toggle becomes "install socialware w/ anon web feed" |

Every site → **identity = install record** (rows 1, 6, 7, 9, 10) **or**
**anon-gate = socialware-def `web_anon_access`** (rows 2, 3, 5, 8, +10); row 4
(granter) unchanged. The §7 P4 gate is a test that **no `public_view` boolean is
read anywhere** and both jobs resolve via the new homes.

> **Codex Q4 fix — non-production `public_view` sites.** The 10-row audit above
> covers the production runtime sites. `public_view` also appears in
> non-production surfaces: `scripts/autoservice_tier1_seed.exs:413-427` (seed),
> `apps/ezagent_web/priv/static/agent-console-demo/index.html:258-270,731`
> (static demo). The P4 gate ("no `public_view` read anywhere") must either
> migrate/delete these or **explicitly mark them non-production exclusion** in the
> gate's allowlist — do not claim global elimination while they remain.

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
| storage / resolve | `ConfigObject` via `RoleRegistry`/`ConfigStore` (#1048) | **same** (`config://<ws>/socialware/<name>`, key `"socialware"`) |
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
deferred past any unfiltered operator read — and the unfiltered `/sessions` read
exists TODAY** (codex Q5 fix: `router.ex:32-38` is `RequireEntity`-only;
`ConversationData.state_for/2` → `MessageStore.recent_in_session/2`
(`conversation_data.ex:183-187`) has **no visibility filter**
(`message_store.ex:141-152`) while messages carry `:operator_only`
(`message.ex:118-120`)). **So P8 lands BEFORE P7** (the editor expansion that
would widen exposure), not after. **P9 = supervisor named responsibility + B2
pool + fan-out + quorum/arbiter + takeover UI** (the 4 sub-steps), last. Each
phase is independently landable + verifiable with a named gate.

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
   P8 (cap-gate the operator/management unfiltered read — the security fix, NO named role)   ◄── BEFORE P7; the /sessions leak exists today
        ▼
   P7 (dual-path FORM editor)                                needs P4/P5; gated behind P8
        ▼
   P9 (supervisor named responsibility + B2 pool + fan-out + quorum/arbiter + takeover UI — 4 sub-steps)   needs P8 + P7; defer (L)
        │
        ▼
   P10 (whole-implementation lifecycle E2E — COD-RUNNABLE automated suite; gates completion)   needs P4-P9; FINAL
        └─ P10.0 prerequisite: implement codex-orchestrator (mirror cc OrchestratorRole; reuse shared executor/bridge-token)
```

> **P8 split (codex Q5 fix).** P8 has a **minimal-first subset (P8a)** — cap-gate
> the *existing* `/sessions` unfiltered `recent_in_session` read with a
> `read_unfiltered` cap, fail-closed — which is **pre-prod-now** and lands before
> P7. The remainder (relabel `operator_tree`/"Operator SessionView"→internal,
> ride #1059's symbol-rename window) is P8b, still before P9. P8a is the
> load-bearing security gate; it must not wait for the editor.

| Phase | What | Blast | Pre-prod? | Independent gate (verifiable) |
|---|---|---|---|---|
| **P0 — concepts/definition doc** | land §0 as a standalone doc under `docs/` (the socialware authoring guide: base/socialware/fixture taxonomy, the shape concept, how to write a socialware). **No code change.** | **S** | **NOW** | the doc exists at `docs/socialware-concepts.md` (EN + `.zh_cn`); the taxonomy matches code (5 bases `defmodule`-confirmed; chat=world Conversation; kanban=recipe-only status cited); a reviewer can author a new socialware from the doc alone |
| **P1 — C1** | rename `:operator_only`→`:internal` + data-migrate + invariant | **M** | **NOW (persisted enum)** | extend `no_customer_concept_test` to forbid `:operator_only`; full `mix test` 0 failures |
| **P2 — AnonIngress** | `admit_anonymous_participant` primitive + `AnonIngress` shim; collapse +8 dup groups | **M** | any time | the +8 `cross_file_duplicate_fn_groups` collapse to one primitive + one shim; INV-1/2/2a tests; #1060 Gate 2 green |
| **P3 — de-hardcode behavior-set → data** | `installs: [...]` on SessionTemplate; `create_session` reads it to thread the `:kind_base` set, replacing the hardcoded `chat_behaviors`/`socialware_behaviors` at `session_creator.ex:330-338,424-430` + `hello/app.ex:29-35`. **Ship a TEMPORARY built-in socialware catalog** — a code-level `socialware-ref → behavior-set` map seeding two refs (`"chat"`→`chat_behaviors`, `"socialware"`→`socialware_behaviors`). P4 then **replaces the catalog** with the ConfigStore-backed socialware-def resolver (the catalog is the migration seam, deleted in P4). | **M** | **NOW** (call-site choice today) | a session created from a template whose `installs` names `"socialware"` boots with Turn/Surface in its `:kind_base` **via data + the built-in catalog, not a call-site branch**; a `"chat"` template boots without them; full `mix test` 0 failures — **no dependency on P4** |
| **P4 — socialware definition + install relation + public_view split** | `config://<ws>/socialware/<name>` definition (config-as-data sibling of role recipe); per-install `ConfigObject` record; split `public_view` per §2.4; **delete the P3 built-in catalog** (replace with ConfigStore-backed resolver) | **L** | NOW | a gate that **no `public_view` boolean is read** anywhere; identity resolves via the install record, anon-gate via socialware-def `web_anon_access`; a socialware installed onto a session mounts its bases via `effective_set` `extra_part`; hello rewired |
| **P5 — extract socialware config out of SessionTemplate + re-target orchestrator tools + migrate sessions** | move `members`/`routing_rules`/`prompt_templates`/`legends`/`orchestrator_template_uri` from SessionTemplate content INTO the socialware definition; **re-target the orchestrator tool catalog + `migrate_session` to the socialware definition**; migrate existing sessions | **L** | NOW | the orchestrator tools mutate the socialware-def (not template content); `migrate_session` re-points the socialware-def version; a non-socialware orchestrated session still composes its team (per OQ-2 resolution); round-trips |
| **P6 — C2 publish_policy** | lift auto/hold default into socialware-def `visibility_policy.publish_policy`; `handle_open` reads it | **S** | NOW | `:auto` preserves today; a `:supervised` turn stays `:internal` until `:settle` |
| **P7 — dual-path FORM editor** | world form fills full socialware-def + adapter picker + visibility; SessionTemplate composition picker; converge with orchestrator loop on one def | **M** | NOW | form authors non-empty members/routing/prompt_templates/legends + adapter set + an `installs` composition; round-trips with `save_template_as`; `"current"` tag published on save |
| **P8 — cap-gate the operator/management unfiltered read (the security fix, NO named role)** | **P8a (pre-prod-now, before P7):** `read_unfiltered` cap fail-closed gate on the *existing* `/sessions` unfiltered `recent_in_session` read (`router.ex:32-38` RequireEntity-only → add the cap gate; `MessageStore.recent_in_session/2` has no visibility filter today). **P8b (ride #1059):** relabel `operator_tree`/"Operator SessionView"→internal. Re-homes PR-4 authz fix. **NO named "supervisor"/"operator" role introduced.** | **S-M** | **P8a NOW (leak exists today); P8b ride #1059** | P8a: a non-holder authenticated workspace user cannot read `:internal`/`:operator_only` messages via `/sessions` (the PR-4 disclosure gate, fail-closed); P8b: relabel-only elsewhere |
| **P9 — supervisor named responsibility + B2 pool + fan-out + quorum/arbiter + takeover UI (4 sub-steps)** | see §7.1 | **L** | defer (post-prod ok) | per sub-step gates in §7.1 |
| **P10 — whole-implementation lifecycle E2E (codex-runnable automated suite; gates completion)** | **P10.0 prerequisite:** implement **codex-orchestrator** (mirror cc's `OrchestratorRole` recipe + `CcOrchestratorSeed` onto the codex flavor; codex already has the bridge infra — `bridge_adapter.ex`/`bridge_sidecar.ex`/`app_server.ex`/`codex_agent.ex`; wire the orchestrator recipe + shared tool-catalog so codex can call `kb_query` + weave a reply; **reuse the shared executor `SessionManager.run_tool` + bridge-token `AgentBridge.TokenStore`, both flavor-blind** — do NOT duplicate cc's tool-catalog/executor). Then an **automated** E2E test suite (codex-runnable, NOT a manual live agent-browser run) covering the FULL socialware lifecycle as assertions, reusing the existing e2e harness pattern (`apps/ezagent_plugin_kb/test/e2e/autoservice_tier1_seed_test.exs` — `Code.require_file` + `EzagentCore.DataCase` + `skip_if_no_entity_spawn` + in-process dispatch-then-assert; `scripts/autoservice_tier1_seed.exs` + `scripts/world_e2e_seed.exs` seed modules; the in-process dispatch entry `apps/ezagent_cli/lib/ezagent_cli/exec.ex` (`EzagentCli.Exec.exec/1`) — NOT the `mix ezagent` RPC shell; `apps/ezagent_plugin_kb/test/e2e/kb_role_native_test.exs` mount/role assertions). The customer-side assertion (#3) uses the **codex-orchestrator** (a REAL LLM orchestrator), NOT a non-cc echo flavor. See §7.4 for the lifecycle assertions + the codex test-credential setup. | **M-L** | **NOW (gates completion)** | the automated lifecycle E2E suite is green — author→install→run customer (codex-orchestrator reply)→run supervisor→security→publish_policy (§7.4); the invariant test FAILS if any lifecycle step is unmet |

**Recommended order:** P0 (concepts doc, pre-prod) → P1 (cheapest, pre-prod-
critical) → P2 (independent) → P3 (foundational) → P4 (foundational L) → P5 → P6
→ **P8a (security, pre-prod-now — the `/sessions` leak exists today)** → P7
(editor, gated behind P8a) → P8b (relabel, ride #1059) → P9 (last, deferred)
→ **P10 (codex-runnable lifecycle E2E — gates completion; lands after every
phase it asserts; P10.0 prerequisite = implement codex-orchestrator).** P1/P2 land in parallel (no shared file). **C1 (P1) stays pre-prod-first.** **No
named operator role lands in P1-P8** — P8 introduces only the `read_unfiltered`
cap-gate; **`supervisor` is a NAMED routing responsibility ONLY in P9**, where
the fan-out target + multi-holder pool need a name. **The security cap-gate (P8a)
is NOT deferred past any unfiltered operator read** — the read exists today, so
P8a is pre-prod-now, before the editor (P7) widens exposure.

### 7.1 P9 — the four bounded sub-steps

| Sub-step | Host | What | Gate |
|---|---|---|---|
| **P9-a assignment** | `domain_workspace` | principal→responsibility assignment + `:assign_role` cap; **`supervisor` becomes a named responsibility here** | assigning/unassigning a holder is durable + cap-gated; **no new app edge** |
| **P9-b approval workflow** | `domain_session` | approval/quorum/arbiter Behavior (verdict collection, `quorum_policy`, arbiter escalation) | a quorum→arbiter escalation test; stale-holder verdict rejected (assignment↔cap atomicity) |
| **P9-c fan-out seam** | `core/routing` + **session-injected resolver** | `{:role,name}`→`[uri]` multi-holder resolution + **same-ws + current-assignment validation** | a test proving fan-out delivery mints **no `:receive` cap** for unassigned/out-of-scope principals (the load-bearing tenant-isolation gate) |
| **P9-d takeover UI** | the editor (`ezagent_plugin_world`) | claim/approve/escalate **product surface** | the UI drives `:claim`/`:settle`/`:approve` (no raw `mix ezagent` dispatch); the lifecycle verbs are ALSO asserted automatedly by P10 |

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
- **P7 → P8a (security gates the editor, codex Q5 fix):** the unfiltered
  `/sessions` read exists today; P7 (the editor) widens exposure. So **P8a (the
  minimal cap-gate) lands BEFORE P7** — the editor must not ship before the
  operator read is cap-gated.
- **P8 → PR-4 fix:** superseding PR-4 is safe only once P8 provides the
  `read_unfiltered` cap-gate (§8.2).
- **P9 → P8 + P7:** B2 needs the `read_unfiltered` cap (P8) to bundle into the
  `supervisor` responsibility + the editor (P7) to assign holders + drive
  takeover. P9 is otherwise additive (new state in workspace + session + routing)
  and shares no file with P0-P8.
- **P10 → P4-P9 (FINAL, gates completion):** P10 is the codex-runnable lifecycle
  E2E suite. It lands AFTER every phase whose behavior it asserts (P4 install
  relation, P5 orchestrator re-target, P6 publish_policy, P8a security cap-gate,
  P7 dual-path editor, P9 supervisor/B2 if in scope). **P10.0 prerequisite —
  codex-orchestrator:** the customer-side assertion (#3) needs a REAL LLM
  orchestrator on the codex flavor (mirrors cc's `OrchestratorRole` recipe +
  seed; reuses the shared executor `SessionManager.run_tool` + bridge-token
  `AgentBridge.TokenStore`; the codex bridge infra already exists). P10.0 is
  moderate work (a recipe + seed + tool-catalog wiring), NOT from-scratch, and
  rides the same flavor-agnostic substrate the autoservice reframe Layer A
  proved. P10 is not a hard dep for any earlier phase to *land* — it is the
  **completion gate**: the implementation is "done" when the P10 suite is green.
  A subset of P10 (author→install→run customer→security→publish_policy) is
  runnable once P4-P8 + P10.0 land; the supervisor/B2-quorum assertions are
  added once P9 lands (P10 is placed after P9 in the DAG so the full lifecycle
  is asserted).

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

### 7.4 P10 — the codex-runnable lifecycle E2E (completion gate)

> **Lead decision (2026-06-28):** the whole-implementation E2E (P10) MUST be an
> **automated test suite codex can run itself**, not a manual live agent-browser
> run by the coordinator. Per the *completion-requires-invariant-test* discipline,
> the gate is a test that **FAILS when the socialware-lifecycle goal is unmet.**
> A live agent-browser screenshot by the coordinator may remain as a SECONDARY
> visual confirmation; the GATE is the codex-runnable automated suite below.
>
> **Lead decision REVISE-2 (2026-06-28):** the customer-side assertion (#3) uses a
> **codex-orchestrator** — a REAL LLM orchestrator on the codex flavor — NOT a
> non-cc echo-style flavor that proves only routing + `MessageStore` landing.
> This resolves the prior "cc-woven-answer soul not automatable" caveat (old OQ
> §9 item 11): codex's headless/exec mode is **more deterministic/stable for
> automated E2E** than cc's PTY + startup-dialog path (the #505 blockers), so a
> real LLM-woven reply IS now automatable in the suite. P10 gains a prerequisite
> sub-step **P10.0** (implement codex-orchestrator) below.

P10 is a single e2e test module (sibling of
`apps/ezagent_plugin_kb/test/e2e/autoservice_tier1_seed_test.exs`) that
`Code.require_file`s a lifecycle seed and asserts the full socialware lifecycle
end to end through dispatch — no browser, no live cc PTY. Each step is a
distinct `assert` so a missing/broken phase fails the suite by name. Reused
harnesses (all `origin/main`-confirmed):

- **`apps/ezagent_plugin_kb/test/e2e/autoservice_tier1_seed_test.exs`** — the
  `use EzagentCore.DataCase, async: false` + `Code.require_file(@seed)` +
  `skip_if_no_entity_spawn` + dispatch-then-assert pattern; its moduledoc
  separates the *deterministic routing/retrieval half* (provable here) from the
  *woven-answer half* — P10 **upgrades** the woven-answer half from "non-cc echo
  flavor + live-stack caveat" to a **real codex-orchestrator reply** (P10.0),
  so the reply is now asserted in-suite, not deferred to a live visual.
- **`scripts/autoservice_tier1_seed.exs`** + **`scripts/world_e2e_seed.exs`** —
  the seed modules that wire the chain; P10's lifecycle seed is a sibling.
- **`apps/ezagent_cli/lib/ezagent_cli/exec.ex`** (`EzagentCli.Exec.exec/1`) — the
  **in-process** dispatch entry point the e2e tests call directly (the `mix
  ezagent` task at `apps/ezagent_cli/lib/mix/tasks/ezagent.ex` is only a
  distributed-Erlang RPC shell around `:rpc.call(..., EzagentCli.Exec, :exec, ...)`
  that needs a running runtime node — NOT codex-runnable in a DataCase; the test
  calls `EzagentCli.Exec.exec/1` or `Ezagent.Invocation.dispatch/1` in-process
  instead, exactly as `autoservice_tier1_seed_test.exs` dispatches through the
  Resolver in-process).
- **`apps/ezagent_plugin_kb/test/e2e/kb_role_native_test.exs`** — the
  per-instance mount + `role_name` assertion pattern (reused for the install +
  B1 responsibility assertions).

#### 7.4.0 P10.0 prerequisite — implement codex-orchestrator

> **Scope: moderate (a recipe + a seed + tool-catalog wiring), NOT from-scratch.**
> Verified against `origin/main` (`67b49303`): `codex_orchestrator` /
> `CodexOrchestrator` grep is **empty** today (does not exist); the codex plugin
> ALREADY has the bridge infrastructure; cc's `OrchestratorRole` is the pattern
> to mirror; the executor + bridge-token are SHARED/flavor-blind.

P10.0 wires the **codex** flavor as an **orchestrator** so the customer-side
assertion (#3) drives a real LLM reply, not an echo. Concretely:

1. **Mirror cc's `OrchestratorRole` recipe onto codex.** cc's
   `Ezagent.Orchestrator.OrchestratorRole` (`apps/ezagent_plugin_cc/lib/ezagent/
   orchestrator/orchestrator_role.ex`) is already a **flavor-agnostic recipe**
   (`@skill_ref "ezagent-session-orchestrator"` + persona prompt +
   `requested_caps`) registered via the cc plugin's `roles/0` callback, keyed by
   name `"orchestrator"` in `Ezagent.Agent.RoleRegistry`. Its moduledoc is
   explicit: *"the same role recipe would compose identically against a future
   `codex` / `curl` flavor."* P10.0 makes that future real: the **codex**
   plugin's `roles/0` callback returns the same recipe (or a codex-composed
   sibling) so a codex-flavored orchestrator agent materializes from the SAME
   role-as-data substrate.
2. **Mirror cc's `CcOrchestratorSeed` onto codex.** cc's
   `Ezagent.Orchestrator.CcOrchestratorSeed` (`cc_orchestrator_seed.ex`) seeds
   the `cc-orchestrator` AgentTemplate's `:template` slice (`flavor`, sandbox
   `config_dir`, `settings_path`, `mcp_config_path`, system prompt). A
   `CodexOrchestratorSeed` sibling seeds a `codex-orchestrator` AgentTemplate:
   `flavor: "codex"`, an isolated `CODEX_HOME` sandbox (codex's per-agent
   credential adapter — `codex_agent.ex` already declares
   `credential_env_var "CODEX_HOME"` + `credential_relpaths ["auth.json",
   "config.toml"]`, see `[[reference_codex_codex_home_per_agent_auth]]`), and the
   orchestrator system prompt. **No new Behavior** — the `:template` slice rides
   `Behavior.Template` content storage (unchanged, per OQ-1=(a)).
3. **Wire the shared tool-catalog so codex can call `kb_query` + weave a reply.**
   cc's MCP bridge (`orchestrator/mcp_server.ex` + `mcp_channel.ex` +
   `mcp_socket.ex` + `priv/orchestrator_bridge.py` + `mcp_server/tool_catalog.ex`)
   forwards `{:run_tool, tool, arguments, bridge_token}` to the session-domain
   `SessionManager` *by URI*; the bridge token is verified via
   `Ezagent.AgentBridge.TokenStore.verify_token/2`. The autoservice reframe
   (Layer A) confirms this path is **flavor-agnostic shared-domain code**: the
   executor (`SessionManager.run_tool_op(:kb_query, …)`) and the bridge-token
   are identical regardless of flavor; **only Layer C (the tool-loop runtime) is
   per-flavor**, and codex already has its own (`codex_agent.ex` starts a
   per-agent app-server sidecar + Python bridge sidecar; `bridge_adapter.ex` /
   `bridge_sidecar.ex` / `app_server.ex` / `codex_remote_agent.ex` exist).
   P10.0 wires the codex sidecar's tool-loop onto the SAME `{:run_tool,
   bridge_token}` forwarding seam, so codex reaches `kb_query` and weaves the
   reply through the shared executor — **do NOT duplicate cc's tool-catalog or
   `SessionManager`**.

> **What is NOT in P10.0 (anti-scope-creep):** no new `Behavior.Orchestrator`
> (OQ-1=(a) closed); no `Behavior.Template` refit; no new `domain.role` app; no
> duplication of `Orchestrator.Tools` or `SessionManager`; no cc PTY path. The
> codex-orchestrator runs as the codex flavor runs (a sidecar subprocess); the
> E2E asserts via the same in-process dispatch + `MessageStore` landing, NOT by
> parsing codex's stdout.

**Codex test-credential / auth setup (test-setup requirement, NOT an open
question).** codex isolates per-agent creds via `CODEX_HOME` (relocates config
AND auth, `codex_agent.ex` `CredentialAdapter`). The E2E MUST provision a test
codex credential itself (per the *self-generate-test-credentials* discipline —
never ask Allen for creds): either (a) a deterministic test-mode codex (a
fake/stub codex sidecar that returns a canned woven reply, sibling of cc's
`apps/ezagent_plugin_cc/test/fixtures/fake_orchestrator_claude.py` — asserts the
orchestrator recipe + tool-catalog + bridge wiring end-to-end without a real
LLM call), or (b) a real codex exec with a self-minted test `auth.json` + a
network-allowed test env (for an end-to-end real-LLM run). The GATE (P10 suite
green) is satisfied by (a) — the deterministic stub proves the codex-orchestrator
wiring (recipe + seed + tool-catalog + bridge-token + `kb_query` dispatch +
woven reply landing in `MessageStore`) without a flaky live LLM; (b) remains a
SECONDARY real-LLM confirmation. This keeps P10 deterministic and codex-runnable
in a `DataCase` while still exercising a real orchestrator flavor — the residual
"codex needs auth/network" caveat is a test-setup choice between (a) and (b),
stated here, not an open question.

**The lifecycle assertions (each automated; the suite FAILS if any is unmet):**

1. **Author (dual-path editor → one definition).** Dispatch the Path A form save
   (`workspace.template.save` / the §4 form payload) AND the Path B orchestrator
   loop (`add_managed_member` + `define_rule_set_rule` + `save_template_as`).
   Assert BOTH terminate at the **same content-addressed** `config://<ws>/socialware/<name>@<hash>`
   `ConfigObject` (key `"socialware"`) with the expected `bases`/`shape`/`members`/
   `routing_rules`/`adapters`/`visibility_policy` fields, and that the `"current"`
   tag is published on save. **Gates P4 + P5 + P7.**
2. **Install (install relation).** Install the socialware onto a session via the
   `installs` composition. Assert the per-install `ConfigObject` record exists
   (`subject = session_uri`, `key = "install:" <> socialware-ref`) AND the
   session's `effective_set/2` `:kind_base` union includes the socialware's
   session-mounted bases+shape (Surface/Turn) via `extra_part` — fail-closed
   `resolve_closure`. **Gates P3 + P4.**
3. **Run customer-side (codex-orchestrator replies — a REAL LLM orchestrator).**
   A customer reaches the external-surface base via the `AnonIngress` primitive
   (`admit_anonymous_participant/2` → mint → join-as-anon → mount `:join` cap).
   Assert a dispatched bare customer message routes to the **`bot`**
   responsibility (B1 `{:role, "bot"}` single-resolve), the **codex-orchestrator**
   (P10.0) picks it up via its tool-loop, calls `kb_query` through the shared
   `SessionManager.run_tool` + bridge-token seam, and a **real LLM-woven reply**
   lands in `MessageStore` for the session. The reply is asserted via the
   in-process dispatch + `MessageStore` landing, NOT by parsing codex's stdout.
   **Gates P2 + P4 (anon) + P5 (B1 routing) + P10.0 (codex-orchestrator).**
   *(This RESOLVES the prior "cc-woven-answer soul not automatable" caveat — old
   OQ §9 item 11, now CLOSED: codex's headless/exec mode avoids cc's PTY/startup
   blockers, so a real orchestrator-woven reply is asserted in-suite. The
   deterministic test-mode codex stub (§7.4.0 (a)) makes the gate non-flaky; a
   real-LLM codex run (b) is a SECONDARY confirmation.)*
4. **Run supervisor-side (claim/approve/escalate).** A principal holding the
   `read_unfiltered` cap sees the full conversation including `:internal`
   messages. Assert `:claim` flips the turn to `mode: :copilot, status:
   :awaiting_human` and holds output `:internal`; `:settle` flips the held
   message to `:external_visible`; `:approve` advances the surface page
   pointer. **If P9 is in scope:** assert B2 pool fan-out — `{:role,
   "supervisor"}` resolves to the N current holders (same-workspace +
   current-assignment validation), a quorum verdict is collected under
   `quorum_policy`, and a conflicting-verdict case escalates to
   `{:role, "arbiter"}`; a stale-holder verdict is rejected. **Gates P6 + P8a +
   P9 (when in scope).**
5. **Security gate (non-supervisor cannot see `:internal`).** An authenticated
   workspace user **without** the `read_unfiltered` cap calls
   `recent_in_session/2` (the `/sessions` unfiltered read) and the result
   **excludes** `:internal`/`:operator_only` messages — fail-closed. Assert no
   `:internal` message is returned to the non-holder. **Gates P8a (the load-bearing
   security cap-gate).**
6. **publish_policy (review-first holds then publishes).** A socialware
   configured `visibility_policy.publish_policy = :supervised` holds a turn's
   output `:internal` on `handle_open` until `:settle`/`:approve`, then flips it
   to `:external_visible`. A socialware configured `:auto` publishes immediately
   (today's behavior). Assert both branches. **Gates P6.**

**The invariant:** the suite is green iff the full lifecycle
(author→install→run customer (codex-orchestrator reply)→run supervisor→security→publish_policy)
holds. It FAILS by name if any phase is missing or broken — e.g. if P8a's
cap-gate is absent, assertion 5 fails (non-holder sees `:internal`); if P4's
install relation is absent, assertion 2 fails (no install record / `extra_part`);
if P6's `publish_policy` is unwired, assertion 6 fails (a `:supervised` turn
publishes without approval); **if P10.0's codex-orchestrator is absent,
assertion 3 fails (no real LLM-woven reply — only an echo at best)**. That is
the completion gate.

> **Anti-stub rule (codex re-review).** The lifecycle seed + assertions MUST
> exercise the **public author/install/dispatch entrypoints** — the form-save
> dispatch, the orchestrator-tool dispatch, `create_session` with `installs`,
> `admit_anonymous_participant/2`, the **codex-orchestrator tool-loop + `kb_query`
> dispatch via the shared `SessionManager.run_tool` + bridge-token seam (P10.0)**,
> `EzagentCli.Exec.exec/1` / `Ezagent.Invocation.dispatch/1`,
> `:claim`/`:settle`/`:approve` verbs, and the `recent_in_session/2` read — and
> then **observe** the resulting `ConfigObject`/`:kind_base`/message-store state.
> They MUST NOT hand-insert the expected `ConfigObject` install record, write
> `:kind_base` directly, or **hand-write the codex-orchestrator's reply into
> `MessageStore`** and then assert on the stub. (The deterministic test-mode
> codex stub in §7.4.0 (a) is NOT a hand-stub: it exercises the real
> orchestrator recipe + seed + tool-catalog + bridge-token + `kb_query`
> dispatch wiring end-to-end — only the final LLM token generation is canned.)
> A phase that only satisfies the assertion via a hand-stub is not "landed" —
> the test fails by design if the public entrypoint doesn't produce the state.

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

> **OQ-1 (orchestrator base reclassification) — CLOSED as (a) by lead decision,
> 2026-06-28.** Resolved: the orchestrator's "base-ness" IS the existing combo
> (recipe via role-as-data + `Orchestrator.Tools` + `SessionManager` executor),
> classified conceptually as the "orchestration base" with **zero new Behavior /
> zero new code**; `Behavior.Template` stays template-content storage (not a
> session-mounted runtime base); no `Behavior.Template` refit; no new
> `Behavior.Orchestrator`. Removed from the open list; recorded in §0.2 + §10.
>
> **OQ item 11 (P10 non-automatable customer-side step) — CLOSED by lead
> decision REVISE-2, 2026-06-28.** Resolved: P10's customer-side assertion (#3)
> now uses a **codex-orchestrator** (a real LLM orchestrator on the codex flavor,
> P10.0 prerequisite). codex's headless/exec mode avoids cc's PTY + startup-dialog
> blockers (#505), so a real LLM-woven reply IS automatable in the e2e suite —
> the "cc-woven-answer soul not automatable" caveat no longer holds. Removed
> from the open list; the residual codex auth/test-credential setup is stated as
> a test-setup requirement in §7.4.0, not an open question. Recorded in §7.4 +
> §10.4. The open questions below are renumbered 1-10.

1. **`Turn` classification (§0.4).** `Turn`'s moduledoc calls it "Socialware
   orchestration state machine," which sits between "base" and "shape." This SPEC
   classifies `Turn` as **chat's shape** (flow-specific: a kanban has no turns),
   not a base (general: reusable across unrelated socialwares). Confirm — or is
   `Turn` part of the orchestrator base?
2. **Team/routing home for non-socialware orchestrated chat (§2.8).** Move
   `members`/`routing`/`legends` out of SessionTemplate into the socialware
   definition for *all* sessions — making **plain orchestration its own
   installable socialware** (`config://<ws>/socialware/<chat-team>`, fully
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

> **Item 11 (P10 non-automatable customer-side step) — CLOSED REVISE-2
> (2026-06-28).** See the closure note at the top of §9. The customer-side
> assertion now drives a **codex-orchestrator** real LLM reply (P10.0), so the
> step IS automatable; the residual codex auth/test-credential setup is a
> test-setup requirement (§7.4.0), not an open question. Removed from the open
> list.

---

## 10. Codex adversarial-review verdict

> *Static-only review (codex/gpt-5.5, no build/mix/tests) against `origin/main`,
> reading the rewritten spec + every cited source. Run 2026-06-28 after the
> complete rewrite to the base/socialware/fixture model. All fixes folded back
> into §0-§9 before push.*

### 10.1 Review questions + verdicts

**NET: SOUND-WITH-FIXES — no UNSOUND finding overall; one base misclassification
(orchestrator=`Behavior.Template`) folded as a reclassification, then **closed as
OQ-1=(a) by lead decision** (no new Behavior; the orchestrator base IS the existing
recipe+tools+executor combo).** All six codex fixes folded into §0-§9 before push;
OQ-1 closed and removed from §9; P10 (codex-runnable lifecycle E2E) added per lead
decision. Re-review in §10.3.

| Q | Codex verdict | Disposition |
|---|---|---|
| 1 — taxonomy code-accurate? (kanban recipe/responsibility/routing; chat=Conversation; hello=Surface) | **SOUND-WITH-FIXES** — kanban recipe-only claim SOUND (greps empty: `role_name`, `{:role,`, `routing_rules` over `apps/ezagent_plugin_kanban/**`); chat=Conversation generic SOUND; hello=Surface SOUND. **Fix:** §1.4 overstated chat composition — plain `chat_behaviors/0` excludes Turn/Surface; only `socialware_behaviors/0` includes them. | **FOLDED** — §1.4 + §0.2 chat description rewritten to distinguish plain chat from socialware/hello paths. |
| 2 — P0 concepts doc clear + correct? | **SOUND-WITH-FIXES** — usable conceptually but not authoring-complete; §0.5 teaches `supervisor` responsibility while the plan forbids it before P9. | **FOLDED** — §0.5 marked "target authoring model"; supervisor/B2 reserved for P9; P0 authors B1 only. |
| 3 — decouple a real simplification vs a new layer? | **SOUND-WITH-FIXES** — substrate real (`effective_set` `declared_part ++ extra_part` `behavior_set.ex:153-172`; mount rewrites `:kind_base` `kind.ex:520-535,546-561`; ConfigStore/ConfigObject real; CapMint fail-closed). **Fix:** `template://<ws>/socialware/<name>` is wrong — template spawn supports only `agent`/`session` (`application.ex:773-786`); role uses opaque `config://<ws>/role/<name>` (`role_registry.ex:78-88`). | **FOLDED** — §2.3 + all refs changed to `config://<ws>/socialware/<name>` (opaque ConfigStore subject, like role; NOT a Kind). |
| 4 — install-relation cleanly replaces public_view? | **SOUND-WITH-FIXES** — 10 runtime sites right. **Fix:** `public_view` also in non-production surfaces (`scripts/autoservice_tier1_seed.exs:413-427`, `agent-console-demo/index.html:258-270,731`); the P4 "no public_view read anywhere" gate must migrate/delete or explicitly exclude these. | **FOLDED** — §2.4 non-production-sites note added. |
| 5 — phased plan safe + each landable + security cap-gate not-deferred? | **SOUND-WITH-FIXES** — P3 independently landable (catalog seam) SOUND; dep-DAG SOUND. **Fix:** the unfiltered `/sessions` read **exists today** (`router.ex:32-38` RequireEntity-only; `recent_in_session/2` `message_store.ex:141-152` has no visibility filter; messages carry `:operator_only` `message.ex:118-120`) → P8 must land **before P7**, not after. | **FOLDED** — §7 DAG reordered P8 before P7; P8 split into P8a (pre-prod-now, gate existing read) + P8b (relabel, ride #1059); recommended order + couplings updated. |
| 6 — any new concept that should reuse an existing one? | **SOUND-WITH-FIXES** — socialware-def as sibling of Role (not `%Role{}`, which lacks adapters/visibility) is right; reuse ConfigStore/role seed/read-through pattern. **Fix:** correct the "template subtype" language (folded into Q3's `config://` fix). | **FOLDED** — §2.3 reworded. |
| 7 — any base misclassified? | **UNSOUND for orchestrator; SOUND for Turn/Surface.** `Behavior.Template` is template-content storage (`:read`/`:write`/`:instantiate` on AgentTemplate/SessionTemplate Kinds), NOT a session-mounted "process/agent+tools base" — Session `behaviors/0` does not include it. Turn=shape SOUND; Surface=base SOUND. | **FOLDED + CLOSED (a)** — §0.2 orchestrator reclassified as the "orchestration base" = the existing recipe+tools+executor combo (`Behavior.Template` recipe content + `Orchestrator.Tools` + `SessionManager`); **lead closed OQ-1 as (a): no new Behavior, no `Behavior.Template` refit, no new `Behavior.Orchestrator`**; OQ-1 removed from §9. |

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
- No new Kind URI scheme — the rewrite avoids both `socialware://` AND
  `template://.../socialware` (codex Q3 fix: template spawn supports only
  `agent`/`session`); the socialware-def is addressed `config://<ws>/socialware/
  <name>` (opaque ConfigStore subject, like role's `config://<ws>/role/<name>`,
  NOT a Kind, NOT one of the 6 Kind schemes `entity session template resource
  workspace system`, `plugin.ex:88,263-268`); resolves via a sibling
  `"socialware"` ConfigStore resolver, not a hidden new registry (Q7 FIXED).
- P3 (was P0) lands self-contained on a temporary built-in catalog, not a hard
  dep on P4 (Q6 FIXED).
- The B2 `core/routing reaches assignment` row corrected to the
  **injected-resolver seam** (§3.4, §7.3); accountability reworded to "via the
  `Identity.Grant` grant path."
- **(This revision's pass)** orchestrator base reclassification (Q7 UNSOUND)
  → **closed as OQ-1=(a)** (lead decision: the orchestrator base IS the existing
  recipe+tools+executor combo; no new Behavior), `config://` address (Q3),
  P8-before-P7 security ordering (Q5), non-prod `public_view` sites (Q4), §0.5
  supervisor/P9 reservation (Q2), §1.4 chat composition precision (Q1) — all
  folded above; **P10 (codex-runnable lifecycle E2E) added per lead decision**
  (§7.4).

### 10.3 Re-review (2026-06-28, after folding the two lead decisions)

> *Static-only re-review (codex/gpt-5.5, no build/mix/tests) against the REVISED
> spec on the `docs/socialware-app-unification` branch. Verified harness +
> dispatch claims against `origin/main` (`67b49303`).*

**NET: SOUND-WITH-FIXES — no UNSOUND.** OQ-1=(a) cleanly closed; P10 lifecycle
coverage complete; harnesses + the deterministic-vs-live-cc split verified real.
Four narrow fixes folded before push (numbering/cross-refs + a runtime-RPC
dispatch-path correction + an anti-stub rule).

| RQ | Codex verdict | Disposition |
|---|---|---|
| RQ-1 — OQ-1=(a) cleanly closed, no residual "new Behavior"? | **SOUND-WITH-FIXES** — substantively closed (§0.2 `:105,111-128`; §2.3 `bases` excludes orchestrator from session-mounted set `:445,449`). **Fix:** §0.4 still said "§9 OQ-1" for Turn after OQ-1 was closed → ambiguous. | **FOLDED** — §0.4 reworded to "§9 item 1". |
| RQ-2 — P10 actually codex-runnable + non-gameable + gates completion? | **SOUND-WITH-FIXES** — harnesses exist; `autoservice_tier1_seed_test.exs:7-32,58-219` has the exact deterministic-vs-live-cc split P10 reuses; install/security assertions non-gameable if via public flow (`message_store.ex:141-152`, `message.ex:118-120` ⇒ absent P8a leaks). **Fix:** P10 cited `mix ezagent` as the dispatch path, but that task is a `:rpc.call` shell needing a running runtime (`mix/tasks/ezagent.ex:52-78`) — not codex-runnable in a DataCase. | **FOLDED** — §7.4 + P10 table row re-pointed to the in-process `EzagentCli.Exec.exec/1` (`apps/ezagent_cli/lib/ezagent_cli/exec.ex`) / `Ezagent.Invocation.dispatch/1`; anti-stub rule added (assertions observe state produced by public entrypoints, never hand-inserted `ConfigObject`/`:kind_base` stubs). |
| RQ-3 — lifecycle coverage complete? | **SOUND** — author/install/customer/supervisor/security/publish_policy all enumerated (`:947-999`); B2/quorum correctly conditional on P9 (`:879-887,975-980`). | none. |
| RQ-4 — any non-automatable step needing flagging? | **SOUND-WITH-FIXES** — the cc-woven-answer flag is honest (`autoservice_tier1_seed_test.exs:28-32`; SPEC `:965-969,1108-1119`); no hidden browser/Feishu-WS dependency. **Fix:** same `mix ezagent` runtime-RPC issue as RQ-2. | **FOLDED** (with RQ-2). |
| RQ-5 — new revision issues? | **SOUND-WITH-FIXES** — numbering drift only: §9 said "renumbered 1-10" but lists 11 (P10 flag added); §0.4 "OQ-1" ambiguity. No model breakage. | **FOLDED** — §9 header note corrected to "1-11"; §0.4 → "item 1". |

**Codex fixes folded (4):** §0.4 Turn cross-ref (`OQ-1`→`item 1`); §9 count
(`1-10`→`1-11`); P10 dispatch path (`mix ezagent` RPC shell → in-process
`EzagentCli.Exec.exec/1`); §7.4 anti-stub rule. *(At this pass, §9 item 11 — the
P10 non-automatable-step flag — remained open; it is CLOSED by REVISE-2 /
§10.4 below.)*

### 10.4 Re-review (2026-06-28, after the codex-orchestrator amendment REVISE-2)

> *Static-only re-review (codex/gpt-5.5, no build/mix/tests) against the REVISE-2
> spec on the `docs/socialware-app-unification` branch. Verified the
> codex-orchestrator scope claims against `origin/main` (`67b49303`):
> `codex_orchestrator`/`CodexOrchestrator` grep empty (does not exist today);
> cc `OrchestratorRole` (`apps/ezagent_plugin_cc/lib/ezagent/orchestrator/
> orchestrator_role.ex`) + `CcOrchestratorSeed` (`cc_orchestrator_seed.ex`) +
> `orchestrator_bootstrap.ex` are the pattern to mirror; the codex plugin has the
> bridge infra (`bridge_adapter.ex`/`bridge_sidecar.ex`/`app_server.ex`/
> `codex_agent.ex`/`codex_remote_agent.ex`/`codex_remote_bridge_adapter.ex`);
> the autoservice reframe Layer A confirms `SessionManager.run_tool_op` +
> `AgentBridge.TokenStore` are flavor-agnostic shared-domain code.*

**NET: SOUND-WITH-FIXES — no UNSOUND.** The codex-orchestrator addition is
correctly scoped (mirror cc, reuse shared executor/bridge-token, no
duplication); it IS more automatable/stable than cc for E2E (codex headless vs
cc PTY); P10 still gates completion via state observed through public
entrypoints (not codex stdout); the codex auth/test-credential setup is sound
(no asking Allen for creds). Two narrow fixes folded before push (a stub-vs-
hand-stub clarity fix in the anti-stub rule + a §10.3 closing-line staleness
fix). OQ §9 item 11 cleanly closed.

| R2Q | Codex verdict | Disposition |
|---|---|---|
| R2Q-1 — codex-orchestrator scope right (mirror cc; reuse shared executor/bridge-token; no duplication)? | **SOUND-WITH-FIXES** — the scope is correct and minimal. cc's `OrchestratorRole` moduledoc (`orchestrator_role.ex:7-12`) is explicit that "the same role recipe would compose identically against a future `codex`/`curl` flavor" — P10.0 realizes exactly that. The codex plugin's `BridgeAdapter` (`bridge_adapter.ex:1-6`, `@behaviour Ezagent.AgentBridge.Adapter`, `flavor "codex"`) + `codex_agent.ex` (`CredentialAdapter` with `CODEX_HOME`) + `app_server.ex`/`bridge_sidecar.ex` exist, so the bridge infra claim is real. The autoservice reframe Layer A confirms `run_tool_op(:kb_query, …)` (`session_manager.ex:474-479`) + `AgentBridge.TokenStore.verify_token/2` are flavor-agnostic — so "reuse, do not duplicate" is the right call. **Fix:** the anti-stub rule must distinguish the *deterministic test-mode codex stub* (a real wiring exercise — sibling of cc's `test/fixtures/fake_orchestrator_claude.py`) from a forbidden *hand-stub* (writing the reply straight into `MessageStore`). | **FOLDED** — §7.4 anti-stub rule clarified: the test-mode stub exercises the real recipe+seed+tool-catalog+bridge-token+`kb_query` dispatch wiring (only the final LLM token generation is canned); hand-writing the reply into `MessageStore` remains forbidden. |
| R2Q-2 — actually more automatable/stable than cc for E2E (codex headless vs cc PTY)? | **SOUND** — codex's app-server/sidecar exec model (`codex_agent.ex` "starts a per-agent Codex app-server sidecar, starts a user-visible Codex TUI in Domain.Pty, and starts a Python bridge sidecar") is a subprocess bridge, not cc's interactive `claude` PTY with startup-dialog approvals (the #505 blockers: `hasClaudeMdExternalIncludesApproved` etc.). codex's `CODEX_HOME` per-agent auth (`codex_agent.ex` `CredentialAdapter`) is also cleaner for test provisioning than cc's `~/.claude` shared-config pitfall. The claim is sound. | none. |
| R2Q-3 — P10 still gates completion (assertion observes state via public entrypoints, NOT codex stdout)? | **SOUND-WITH-FIXES** — assertion #3 asserts the reply lands in `MessageStore` via in-process dispatch (`EzagentCli.Exec.exec/1` / `Ezagent.Invocation.dispatch/1`), not by parsing codex stdout — correct, and consistent with the anti-stub rule. The invariant now fails if P10.0 is absent (no real LLM-woven reply). **Fix:** the invariant's "no real LLM-woven reply — only an echo at best" wording must be precise about what "echo" means (a non-codex flavor that returns the input verbatim) so the failure mode is unambiguous. | **FOLDED** — invariant wording kept ("only an echo at best") with the parenthetical that an echo = a non-codex flavor returning input verbatim; the gate is the absence of a codex-orchestrator-driven reply in `MessageStore`. |
| R2Q-4 — codex auth/test-credential setup sound (no asking Allen for creds)? | **SOUND** — the §7.4.0 setup offers (a) a deterministic test-mode codex stub (sibling of cc's `fake_orchestrator_claude.py`) as the GATE — no real creds, no network — and (b) a self-minted test `auth.json` + network-allowed env as SECONDARY. This satisfies the *self-generate-test-credentials* discipline (never ask Allen) and the *let-it-crash/no-workarounds* discipline (the stub is a real wiring exercise, not a degrade path). The residual "codex needs auth/network" caveat is correctly stated as a test-setup choice, not an OQ. | none. |
| R2Q-5 — OQ §9 item 11 cleanly closed; any residual open question? | **SOUND** — the closure is precise: the caveat ("cc-woven-answer soul not automatable") no longer holds because codex-orchestrator's headless mode IS automatable. The §9 header note + the in-list closure note + §7.4.0 all agree. No new open question introduced; the open list is now 1-10. | none. |

**Codex fixes folded (2):** §7.4 anti-stub rule stub-vs-hand-stub clarity
(R2Q-1); §10.3 closing-line staleness (note that item 11 was still open at
that pass, now closed by REVISE-2). No new open questions; OQ §9 item 11
closed.

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
- **codex-orchestrator verification (REVISE-2, 2026-06-28):**
  - `codex_orchestrator` / `CodexOrchestrator` grep over `apps/**` on
    `origin/main` = **EMPTY** (does not exist today).
  - cc pattern to mirror: `apps/ezagent_plugin_cc/lib/ezagent/orchestrator/
    orchestrator_role.ex` (flavor-agnostic `OrchestratorRole` recipe,
    `@skill_ref "ezagent-session-orchestrator"`, registered via `roles/0` in
    `RoleRegistry` by name `"orchestrator"`; moduledoc: "would compose
    identically against a future `codex`/`curl` flavor");
    `cc_orchestrator_seed.ex` (seeds the `cc-orchestrator` AgentTemplate
    `:template` slice: `flavor`/`config_dir`/`settings_path`/`mcp_config_path`/
    system prompt); `template/orchestrator_bootstrap.ex`; the cc MCP bridge
    (`orchestrator/mcp_server.ex` + `mcp_channel.ex` + `mcp_socket.ex` +
    `priv/orchestrator_bridge.py` + `mcp_server/tool_catalog.ex`); cc test
    stub `apps/ezagent_plugin_cc/test/fixtures/fake_orchestrator_claude.py`.
  - codex bridge infra (exists): `apps/ezagent_plugin_codex/lib/ezagent/
    plugin_codex/bridge_adapter.ex` (`@behaviour Ezagent.AgentBridge.Adapter`,
    `flavor "codex"`, `transport_class :subprocess_ws`);
    `bridge_sidecar.ex`; `app_server.ex`; `codex_remote_bridge_adapter.ex`
    (`flavor "codex-remote"`); `apps/ezagent_plugin_codex/lib/ezagent/template/
    codex_agent.ex` (`@behaviour Ezagent.Agent.CredentialAdapter`,
    `credential_env_var "CODEX_HOME"`, `credential_relpaths ["auth.json",
    "config.toml"]` — per-agent auth, `[[reference_codex_codex_home_per_agent_auth]]`);
    `codex_remote_agent.ex`.
  - shared/flavor-blind substrate (autoservice reframe Layer A): executor
    `Ezagent.Session.SessionManager.run_tool_op(:kb_query, …)`
    (`session_manager.ex:474-479`, structurally identical to every other
    `run_tool_op`); bridge-token `Ezagent.AgentBridge.TokenStore.verify_token/2`
    (`session_manager.ex` step 0); only Layer C (the tool-loop runtime) is
    per-flavor, and codex has its own.
- Synthesized from: `docs/socialware-operator-analysis`,
  `docs/socialware-template-model`, `docs/comms-pr34-spec`,
  `docs/domain-role-research`, `docs/together/2026-06-26/notes/autoservice-flavor-agnostic-reframe.md`.
- Reconciliation: #1047/#1060 (`comms_substrate_elimination_test.exs`), #1048
  (role-as-data), #1059 (`recipe_responsibility_lockin_test.exs`), #103-105
  (kanban-as-role), #46.
