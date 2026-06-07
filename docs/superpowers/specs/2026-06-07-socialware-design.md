# Design: socialware — fused backend-agent + real-time-render sessions on existing ezagent primitives

> **Status:** buildable design (Allen 2026-06-07). Supersedes the earlier "synthesis for
> discussion" revision of this file. Direction set by Allen: **rewrite directly, reuse
> `main` components, do NOT base on the loom/autoservice branches.** Verified against
> `origin/main` (sha `5661964c`). The earlier AutoService/loom branch summary is retained
> only where it informs a reuse decision; the design itself is greenfield-on-main.

## 1. What socialware is

socialware is the pattern where **one session simultaneously drives a conversational
surface (chat) and a live-rendered surface (a web page), produced by the same agent
orchestration, with a human able to take over.** "AutoService" (customer ↔ bot ↔ operator
chat with takeover) and "loom" (orchestrator → workers → live-rendered HTML page) are not
two apps — they are **two interaction surfaces over one session**. A socialware vertical
mounts both.

The design goal (Allen's North Star for this work): a developer builds a new vertical by
**declaring**, not by writing core code. Everything structural is reused from `main`; the
net-new is deliberately tiny.

## 2. Design principle: reuse `main`, minimal net-new

The whole design is organized around one constraint: **maximize reuse of components already
on `main`, and keep net-new surface minimal and well-bounded.** The net-new is exactly two
things (§4); everything else (§3) already exists.

### 3. Reused-from-`main` components (verified on `origin/main` @ `5661964c`)

| Concern | Existing component | Path |
|---|---|---|
| Session as a Kind | `Ezagent.Entity.Session` (+ `:chat` slice, `Behavior.Chat`) | `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex`, `.../behavior/chat.ex` |
| Message persistence | `Ezagent.MessageStore` (separate `messages`+`message_routings` DB; PubSub fan-out) | `apps/ezagent_core/lib/ezagent/message_store.ex` |
| **The View concept** (per-session render surface + view-switcher) | `Ezagent.UI.SessionView` behaviour (`id/label/icon/applies_to?/render`) + `Ezagent.UI.SessionViewRegistry` | `apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex`, `.../session_view_registry.ex` |
| Shipped views | `ConversationView` (chat), `Pty.TerminalView`, `RoutingView`, `ExternalMirror.View` | `apps/ezagent_plugin_liveview/.../views/conversation_view.ex` et al. |
| Routing (runtime, per-session, cap-checked) | `Ezagent.Behavior.Routing` wrapping `RuleStore.add` + `load_into_registry`; additive rules (#41); in-session fan-out is a `system_default` rule `receivers: ["$session_members"]` | `apps/ezagent_core/lib/ezagent/behavior/routing.ex`, `.../routing/{rule_store,resolver,matcher}.ex` |
| Agent provisioning + per-agent config/credentials | the #17 **credential/config cascade** (flavor-base → workspace → user → session; resolver + grant + materializer) | `apps/ezagent_core/lib/ezagent/credential/*`, `.../agent/materializer.ex` |
| Session/Agent templates | `Entity.SessionTemplate`, `Entity.AgentTemplate`, `template.read/write` | `apps/ezagent_domain_chat/lib/ezagent/entity/{session_template,agent_template}.ex` |

**Two facts that shaped this design (corrects the prior revision):**
- `Behavior.Mode` (#511 takeover/copilot) is **NOT on `main`** — it lives on
  `origin/feat/cs-operator`. We do **not** port it (see §4.3: mode dissolves into routing).
- loom (`page_update` / typed-card / `<span type=…>`) is **not in esr-ng at all** — it is
  separate/external code. The render surface (`PageView` + UI tree) is greenfield here.

## 4. Net-new components (the entire delta)

Net-new is two component groups: **`Behavior.Turn` + `:turns` slice** (§4.1, which also owns
the customer-facing commit gate) and **the render stack** (§4.2: `:surface` slice + `PageView`
+ a composite `SocialwareView`). §4.3 adds **no new behavior**: auto/copilot/takeover are the
turn's settle-gate plus *additive* routing over the existing `Behavior.Routing` — see the
correction there. (Codex review 2026-06-07 found the earlier "mode = routing replacement" and
"two registered Views = fusion" claims unsound on main's additive-only routing and
exclusive-tab view-switcher; §4.2/§4.3 reflect the corrected design.)

### 4.1 `Behavior.Turn` + the `:turns` slice — the orchestration state machine

A **turn** is one atomic interaction cycle: a triggering input, the fan-out it caused, the
deliverables collected, the composed result, and its lifecycle status. It is a noun; the
convention `Behavior.<noun>` owning `:<noun>` (matching `Behavior.Chat`/`:chat`) gives us
`Behavior.Turn` owning `:turns`.

**`:turns` slice** — `turn_id => turn record` (small; `{:snapshot, :on_change}` like
`:chat`; bodies stay in `MessageStore`, the slice holds references):

```
%{
  turn_id        => %{
    trigger:       message_ref,        # the input message that opened the turn
    owner:         uri,                # agent_uri (auto) | user_uri (after claim)
    expected:      MapSet.t(subtask_id),
    collected:     %{subtask_id => card_ref},   # staged in-turn, NOT yet on :surface
    result:        [card_ref],         # composed deliverables (still staged)
    draft_surface: ui_node | nil,      # composed page tree, pending; committed only at settle
    mode:          :auto | :copilot | :takeover,
    status:        :open | :delegating | :aggregating | :composing
                   | :awaiting_human | :settled | :cancelled,
    turn_no:       integer,
    opened_at:     integer             # passed in; no Date.now in core
  }
}
```

**Action set** (Behavior actions, cap-checked via the dispatch surface):
- `turn.open(trigger)` → `:open`
- `turn.dispatch(turn_id, subtasks)` — record `expected`; the actual `@mention chat.send`
  fan-out is a `Chat` action → `:delegating`
- `turn.deliver(turn_id, subtask_id, card_ref)` — **stage** one worker deliverable into the
  turn (`collected`/`draft_surface`); **nothing is committed to `:surface` yet** →
  `:aggregating`
- `turn.compose(turn_id, result_refs)` — orchestrator composes the staged result/draft →
  `:composing`
- `turn.claim(turn_id, by: user_uri)` — human takeover: set `owner`, `mode`; route the
  draft to the operator (additive rule, §4.3) and **hold settle** → `:awaiting_human`
- `turn.settle(turn_id)` — **the single customer-facing commit point**: write `draft_surface`
  as a new `:surface` version AND release the chat result to the customer. In
  `:copilot`/`:takeover` this runs **only after the operator approves/edits** → `:settled`
- `turn.cancel(turn_id)` / timeout — discard staged draft, no `:surface` commit → `:cancelled`

Partial worker failure / timeout: a `deliver` that never arrives leaves `expected ⊅ collected`;
on timeout the orchestrator either composes with what arrived (degraded) or `turn.cancel`s —
either way nothing reaches `:surface` or the customer until `settle`, so a failed turn cannot
leak a half-built page.

**State machine:** `open → delegating → aggregating → composing → [awaiting_human] →
settled`; `cancel`/timeout reachable from any non-terminal state. The human-in-the-loop
gate is the **composing → (settle | awaiting_human)** branch, decided by the turn's `mode`
(§4.3). The customer never sees a turn's output — neither the chat bubble nor the `:surface`
page — until `turn.settle`; that single commit point is what makes the human-in-the-loop gate
safe (codex HIGH-1: the page must not become visible/durable before approval).

The degenerate single-bot case (no orchestration) is a turn with zero `expected` subtasks:
open → compose(bot reply) → settle. So the same machinery covers plain chat replies.

### 4.2 `:surface` slice + `PageView` — the live-render surface

The chat log is append-only in `MessageStore`; a **page** is mutable state that evolves over
a conversation, so it is modeled as a durable slice, not a message.

**`:surface` slice** on the session, `{:snapshot, :on_change}`, holding the current
**committed, approved** authoritative **UI tree** + a version number:

```
%{ version: integer, tree: ui_node, updated_by: turn_id }
```

The `:surface` slice only ever holds **committed** state. A turn's in-progress page lives in
the turn's `draft_surface` (§4.1) and is written here **only at `turn.settle`** — so an
unapproved copilot/takeover draft is never in `:surface`, never rendered to the customer, never
persisted across restart (closes codex HIGH-1). The operator, while a turn is `:awaiting_human`,
sees the *pending draft* via an operator-only preview (the draft routed to the operator, §4.3),
not via the customer's `:surface`.

**UI tree = an implementation-agnostic, json-render-style declarative node** (Allen cited
`vercel-labs/json-render`): a recursive `%{type, props, children}`. The client renders it via
a **component registry** (`type => component`). A worker's deliverable is a UI-tree fragment;
the orchestrator composes fragments into the surface tree. Two node tiers:
- **declarative nodes** — registered components (bubble, comparison-table, form, …). Safe,
  no codegen, cover the majority of structured UI.
- **`code` node** — an escape hatch rendered in a sandbox (Sandpack/iframe) for arbitrary
  generated JSX/HTML (loom's codegen strength, preserved).

**`PageView`** is a new `Ezagent.UI.SessionView` (registered in the same
`SessionViewRegistry`). Its `render/1` is a **generic interpreter over the committed
`:surface` UI tree + the component registry**. `applies_to?/1` = "session has a `:surface`
slice."

**`SocialwareView` (the fusion needs a composite, not two tabs).** Codex MEDIUM-3: main's
`AdminLive` resolves a single `current_view` into one `:main_view` slot, so registering
`ConversationView` + `PageView` only yields two *tabs* in the exclusive view-switcher — not one
screen with chat and page simultaneously visible. The fusion therefore needs a **composite
`SocialwareView`** (itself a `SessionView`) whose `render/1` lays out the chat stream and the
`:surface` page **side-by-side in one viewport**, each with its own subscription/state. This is
the one extra render-stack component beyond `PageView`; it is what SW-USE asserts against
(both surfaces visible/updating together, §9), so a passing screenshot cannot be faked by
switching tabs.

Granularity note: a `SessionView` selects the **outer** layout (which panels are mounted);
the json-render component registry selects the **inner** node renderer (how one element draws).
They compose; only the inner needs json-render.

### 4.3 Mode = the `turn.settle` gate + additive operator-draft routing (no `Behavior.Mode`)

Codex HIGH-2 corrected the earlier "mode = routing replacement" claim. Main's routing is
**additive**: `Behavior.Routing` exposes `add/delete/disable/enable` by rule id, the
`system_default` rule always fans out to `$session_users` + `$mentions` and is **protected
from plain delete**. So a session containing both customer and operator still delivers
agent messages to the customer via the default rule — *adding* relay rules cannot *suppress*
that. Routing alone therefore cannot implement copilot/takeover suppression.

The fix: the human gate is **`turn.settle`**, not routing. The turn is the single
customer-facing chokepoint (§4.1, §4.2): nothing — chat bubble or `:surface` page — reaches
the customer until `settle`. Mode is then a small, well-bounded split of responsibility:
- **`turn.settle` decides the customer-facing commit** (the gate). `:auto` settles
  automatically at compose; `:copilot`/`:takeover` hold at `:awaiting_human` until the operator
  approves/edits, then settle.
- **Routing (additive, unchanged) delivers the *pending draft* to the operator** so they can
  see/edit it — an `@mention`-style additive rule to the operator, no suppression of any
  existing rule.
- The three modes:
  - **`:auto`** — compose → settle → project to customer.
  - **`:copilot`** — draft routed to operator (additive); settle held; operator approves/edits
    → settle → project. Turn-granular because the orchestrator emits one composed result/turn.
  - **`:takeover`** — `owner` is the operator (from `turn.claim`); the operator authors the
    result directly; the agents' composed draft is shown as a suggestion (additive route to
    operator). settle commits the operator's content.

So mode adds **no new behavior and no routing-replacement primitive** — it is `turn.mode` +
the `settle` gate + one additive operator-draft route. The protected `system_default` rule
is left intact; correctness comes from the turn withholding the customer commit, not from
deleting/replacing routes. (This supersedes the AutoService phase-2 `235a2e96` framing, which
assumed route-suppression; we do not port `Behavior.Mode`/#511.)

## 5. Developer authoring surface (what a vertical declares)

Building a vertical is declaration over reuse — **zero core code**:
1. **SessionTemplate** — compose `Behavior.Chat + Behavior.Turn` (+ `:surface` if it has a
   page); declare the member roster (orchestrator / N workers / customer-user / operator-user);
   declare the routing rules (`{:from customer} → orchestrator`, `{:from orchestrator @worker}
   → worker`).
2. **AgentTemplate × role** — orchestrator + workers: flavor (cc/codex/curl), soul/skill/kb
   prompt config (resolved through the #17 cascade), credential source.
3. **UI node types + schema** — the declarative node types this vertical emits (base set +
   domain nodes, e.g. `quote_comparison`).
4. **Renderers** — a client component per node type, registered in the component registry;
   mount `ConversationView` and/or `PageView`.
5. **Orchestration policy** — the turn's decompose (which `expected` subtasks) and compose
   (how deliverables merge). Usually prompt-driven in the orchestrator's AgentTemplate; a
   small policy function only when hard logic is required.
6. **(optional) Mode policy** — the predicate that flips the turn to copilot/takeover (e.g.
   "confidence < X → operator copilot"). Default: all-auto, operator may `claim` any time.

**Where the authoring surface physically lives.** A vertical is **its own ezagent plugin app**
(`apps/ezagent_vertical_<name>/`), mirroring how `ezagent_plugin_liveview` already registers
views in its `Application.start/2`. socialware itself ships as a base app
(`apps/ezagent_socialware/`) providing the reusable pieces — `Behavior.Turn`, the `:surface`
slice contract, `PageView` + `SocialwareView`, the json-render component-registry contract, and
a `session.socialware` base SessionTemplate. A vertical plugin then supplies the six slots as
**declarations/assets, not core code**:
- slots 1–2 (SessionTemplate + AgentTemplates) → **template content seeds** the plugin
  installs (the existing `Entity.SessionTemplate`/`Entity.AgentTemplate` + `template.write`),
  with orchestrator/worker prompts as AgentTemplate content;
- slot 3 (node types + schema) → a small Elixir module declaring the vertical's node types;
- slot 4 (renderers) → client components shipped in the plugin's `assets/`, registered into the
  component registry + the view mounted, both from the plugin's `Application.start/2` (same hook
  `SessionViewRegistry.register/1` uses today);
- slot 5 (orchestration policy) → primarily the orchestrator AgentTemplate's prompt; an optional
  small policy module only when hard logic is needed;
- slot 6 (mode policy) → an optional config value / tiny predicate module.

So "the authoring surface" = a plugin app's `Application.start/2` (registrations) + its template
seeds + its `assets/` renderers — no edits to `ezagent_core` or `ezagent_socialware`. This is
the framework-vs-app resolution made concrete (§10).

The two canonical verticals are just different fills of the same slots:
- **AutoService** = node types `{text}`, renderer = chat bubble, orchestration = zero-subtask
  direct answer, one `{:from customer}` rule.
- **loom** = node types `{page_update/code}`, renderer = Sandpack, orchestration = fan-out to
  worker + page-worker.
- **Fused vertical** = declare both node families, register both renderers, fan out to NL +
  page workers → one turn drives both surfaces.

## 6. Runtime data flow (SW-USE, the fused path)

1. Customer message → `Chat` persists to `MessageStore` → routing rule `{:from customer}` →
   orchestrator.
2. Orchestrator `turn.open` + `turn.dispatch([nl, page])` → `:delegating`; `@mention
   chat.send` to each worker.
3. Workers deliver via `turn.deliver`: nl-worker → a `text` node; page-worker → a UI-tree
   fragment. Both are **staged in the turn** (`collected`/`draft_surface`) — **nothing is
   written to `:surface` yet**.
4. Orchestrator `turn.compose` → `:composing` (assembles the staged `result` + `draft_surface`).
5. Mode gate at compose→settle (§4.3):
   - `:auto` → `turn.settle`.
   - `:copilot`/`:takeover` → `:awaiting_human`; the pending draft is shown to the operator
     (additive operator route); the operator approves/edits → `turn.settle`.
6. `turn.settle` is the commit point — it writes `draft_surface` as a new `:surface` version
   **and** releases the chat result to the customer. Projection (the `SocialwareView` composite)
   then renders, in one viewport, from the **same settled turn**:
   - the chat pane renders the `text` node as a **chat bubble**;
   - the page pane interprets the committed `:surface` UI tree as the **live page**.
   Both panes update together — the fusion. Before `settle`, the customer sees neither.

## 7. Self-evolve (SW-UPD) on the #17 cascade

Self-evolve reuses the same turn/UI-tree/projection/copilot machinery, pointed at the
**agent's own config** as the artifact, with the **cascade as the write target**:
1. A config/optimization session's **optimizer agent** reads the service session's traces
   (messages + outcomes + **the operator's takeover edits — the gold supervised signal**).
2. The optimizer emits a **config-delta** as a UI-tree card (a new skill entry / soul
   refinement / kb addition).
3. The operator **copilot-approves** the delta via the **same `turn.settle` gate as SW-USE**
   (the optimizer turn holds at `:awaiting_human`; the delta is the draft; the operator
   approves/edits before settle). Human-in-the-loop is the safety gate on self-evolve.
4. The approved delta is written to the agent's **high cascade layer** (user/workspace).
   **Caveat (codex MEDIUM-4):** #17 V1 does *not* provide a versioned/reversible config layer
   — it writes the user/workspace `AgentTemplate` layer as a **mutable replace** (versioned
   layer references are an explicit #17-V2 non-goal; only the credential *grant epoch* is
   versioned). So self-evolve's write today is a replace, and "rollback" means re-applying the
   prior value (best-effort), not restoring from a version history.
5. On the next spawn, the cascade **re-materializes** the resolved config; a later customer
   turn exhibits the changed behavior.

A **real versioned/reversible config artifact** (config-layer history + a rollback path) is a
named follow-up — owned by either socialware (a versioned config-delta log in P5) or #17-V2.
SW-UPD's acceptance invariant is scoped to current #17 accordingly (§9).

Reuse highlight: the operator's copilot-approval path is identical in SW-USE (approve a
customer reply) and SW-UPD (approve a config delta) — one `turn.settle` gate serves both the
interaction phase and the update phase.

## 8. Multi-user & persistence

- **Page state is durable by construction**: the `:surface` slice persists `{:snapshot,
  :on_change}` (versioned). Cold restart re-renders from the snapshot.
- **Same-session, two users** = one shared page. Concurrency is handled by **`Behavior.Turn`
  serialization**: a turn is the unit that mutates `:surface`, and the state machine orders
  turns, so the second turn observes the first's committed state — **no CRDT for the common
  case**.
- **Separate pages** = fork the SessionTemplate into separate sessions; each owns its own
  `:surface`, diverging independently.
- chat history (`MessageStore`, append-only) and page state (`:surface` slice, mutable
  versioned) are two stores with different semantics under one session.

## 9. Acceptance: three-phase E2E

Each phase locks one architectural invariant; together they are the completion gate (a phase
is not "done" until its invariant test passes — not on merge/tests-pass alone).

**SW-DEV (development phase)** — *the authoring/framework surface works.*
A developer authors a vertical plugin (§5: SessionTemplate `Chat+Turn+surface`;
orchestrator/nl/page AgentTemplates via cascade; register `SocialwareView`; node types +
renderers; routing rules) — all in the plugin, no edits to `ezagent_core`/`ezagent_socialware`.
Instantiate it.
- **Invariant:** with **zero core-code change**, the new session boots; `SocialwareView` mounts
  with both chat + page panes; the agents are spawned and credential-materialized.
- Artifact: agent-browser screenshot of the new session showing the composite view + agents.

**SW-USE (user-interaction phase)** — *the fusion + takeover.*
Non-admin customer + operator. Customer asks for "a comparison page + a recommendation."
- **Invariant:** a single `turn.settle` drives **both panes of `SocialwareView` simultaneously
  in one viewport** — fails if only one updates, and (anti-tab-fake) fails if the two are only
  reachable as separate tabs. Plus: in `:copilot`/`:takeover`, the customer sees **nothing**
  (no bubble, no page) until the operator approves at `settle`, and what arrives is the
  operator's output.
- Artifacts: one screenshot showing ① chat bubble and ② live page side-by-side from the same
  settled turn; ③ a copilot turn where the unapproved draft is visible to the operator but
  absent from the customer view until approval; plus a multi-user/cold-restart check (second
  viewer sees the same committed `:surface` version; restart re-renders; **no pending draft
  survives restart**).

**SW-UPD (update phase)** — *the self-evolve loop closes.*
Optimizer agent + operator. Optimization session reads SW-USE traces (incl. operator edits)
→ config-delta card → operator approves at the `turn.settle` gate → delta written to the
agent's cascade high layer → respawn re-materializes → a later customer turn shows changed
behavior.
- **Invariant (scoped to current #17, per §7):** the agent's **resolved config changed via the
  flow (not hand-edit) and is observable in a later turn**; **rollback** = re-applying the prior
  value reverts the behavior. (Version-history-based reversibility is the named follow-up, not
  asserted here.)
- Artifact: screenshot of the delta card + approval + the changed behavior, then the revert.

**E2E standards (all three):** non-admin customer is the primary caller; granting the operator
its cap is itself a step; **fresh docker seed each run**; faces **production topology** (real
routing/spawn/MessageStore, no test-harness shortcuts); **agent-browser screenshots on the
real ESR UI at `http://100.64.0.27:10042`** (Tailscale IP, not localhost); every distinct
bug found earns a fast regression unit test before the fix lands.

## 10. Open decisions (reduced)

The framework-vs-app question is resolved: socialware is **one substrate (Session + Chat +
Turn + routing + cascade) + pluggable Views**, and loom/autoservice are **View
registrations + template fills**, not separate apps. Remaining:
1. **Component registry location** — does the json-render component registry live in the
   liveview plugin (alongside `SessionViewRegistry`) or in a new `ezagent_domain_ui`
   sub-module? (Lean: `ezagent_domain_ui`, beside the View extension point.)
2. **`code`-node sandbox** — Sandpack/iframe parity with loom's renderer: build now or stub
   to declarative-only for the first verticals? (Lean: stub `code`-node to a follow-up; the
   declarative tier covers SW-USE's comparison page.)
3. **Anonymous/synthetic customer identity** — SW-USE's customer is non-admin; is an
   anon-customer identity model a prerequisite or can a seeded test user stand in for the
   first E2E? (Lean: seeded user for E2E; anon model deferred.)
4. **`{:within_workspace}` cap shape** — needed for tenant-admin/customer isolation; block
   SW-DEV on it or introduce alongside? (Lean: introduce with SW-DEV, since templates are
   workspace-scoped.)
5. **`SocialwareView` layout** — the composite mounts chat + page side-by-side (§4.2). Fixed
   split, or a per-vertical declarable layout (which panes, what ratio)? (Lean: a fixed
   chat|page split for the first vertical; declarable layout is a follow-up.)
6. **Versioned/reversible config artifact** — #17 V1 has no config-layer history (§7). Build a
   versioned config-delta log in socialware P5, or wait for #17-V2? (Lean: a thin append-only
   config-delta log in P5 so rollback has real history, without blocking on #17-V2.)

## 11. Phasing

- **P1 — `Behavior.Turn` + `:turns` slice** (the orchestration state machine; TDD; the
  degenerate single-bot turn first, then fan-out/compose).
- **P2 — `:surface` slice + `PageView` + `SocialwareView`** (the UI-tree contract + the generic
  interpreter View + the composite side-by-side view; declarative tier first, `code`-node
  deferred per §10.2). Draft staging (commit only at settle) lands here.
- **P3 — mode = settle-gate + operator-draft route** (`turn.claim`/approve/`settle`; the
  copilot/takeover hold; the additive operator-draft route — no routing-replacement primitive).
- **P4 — first fused vertical + SW-USE E2E** (orchestrator + nl + page workers; the composite
  view; the simultaneous-surfaces + approval-gate invariant tests).
- **P5 — self-evolve (SW-UPD)** on the #17 cascade write path + a thin versioned config-delta
  log (§10.6) + the SW-UPD invariant test.
- **SW-DEV** authoring E2E rides alongside P4 (it proves the template surface that P1–P3
  expose).

## 12. Dependency on #17

socialware's update phase (§7) is the **first major consumer** of the #17 credential/config
cascade write path (config-delta → high layer → re-materialize). The cascade is therefore a
**prerequisite for P5**, not for P1–P4. The two workstreams are parallel and non-conflicting:
socialware adds new files (`Behavior.Turn`, `:surface`, `PageView`) and touches none of the
`credential/`/`materializer`/`resolver`/`grant` files the cascade work owns.
