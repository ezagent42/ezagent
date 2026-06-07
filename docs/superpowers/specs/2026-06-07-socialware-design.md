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

The net-new is exactly **two new components** — `Behavior.Turn` + `:turns` slice (§4.1) and
`:surface` slice + `PageView` (§4.2). §4.3 is not a new component: it is the decision that
auto/copilot/takeover require **no new behavior**, only wiring over the existing
`Behavior.Routing`.

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
    collected:     %{subtask_id => card_ref},
    result:        [card_ref],         # composed deliverables
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
- `turn.deliver(turn_id, subtask_id, card_ref)` — collect one worker deliverable →
  `:aggregating`
- `turn.compose(turn_id, result_refs)` — orchestrator composes → `:composing`
- `turn.claim(turn_id, by: user_uri)` — human takeover: set `owner`, reconfigure routing
  (§4.3) → `:awaiting_human`
- `turn.settle(turn_id)` — finalize, commit, trigger projection → `:settled`
- `turn.cancel(turn_id)` / timeout → `:cancelled`

**State machine:** `open → delegating → aggregating → composing → [awaiting_human] →
settled`; `cancel`/timeout reachable from any non-terminal state. The human-in-the-loop
gate is the **composing → (settle | awaiting_human)** branch, decided by the active routing
configuration (§4.3), not by a mode field.

The degenerate single-bot case (no orchestration) is a turn with zero `expected` subtasks:
open → compose(bot reply) → settle. So the same machinery covers plain chat replies.

### 4.2 `:surface` slice + `PageView` — the live-render surface

The chat log is append-only in `MessageStore`; a **page** is mutable state that evolves over
a conversation, so it is modeled as a durable slice, not a message.

**`:surface` slice** on the session, `{:snapshot, :on_change}`, holding the current
authoritative **UI tree** + a version number:

```
%{ version: integer, tree: ui_node, updated_by: turn_id }
```

**UI tree = an implementation-agnostic, json-render-style declarative node** (Allen cited
`vercel-labs/json-render`): a recursive `%{type, props, children}`. The client renders it via
a **component registry** (`type => component`). A worker's deliverable is a UI-tree fragment;
the orchestrator composes fragments into the surface tree. Two node tiers:
- **declarative nodes** — registered components (bubble, comparison-table, form, …). Safe,
  no codegen, cover the majority of structured UI.
- **`code` node** — an escape hatch rendered in a sandbox (Sandpack/iframe) for arbitrary
  generated JSX/HTML (loom's codegen strength, preserved).

**`PageView`** is a new `Ezagent.UI.SessionView` (registered in the same
`SessionViewRegistry`). Its `render/1` is a **generic interpreter over the `:surface` UI
tree + the component registry**. `applies_to?/1` = "session has a `:surface` slice." The
existing view-switcher then shows **both** `ConversationView` and `PageView` for a socialware
session — *this is the loom+autoservice fusion, expressed as two registered Views on one
session, with zero new top-level abstraction.*

Granularity note: `SessionView` selects the **outer** surface (which panel); the json-render
component registry selects the **inner** node renderer (how one element draws). They compose;
only the inner needs json-render.

### 4.3 Mode = routing configuration + `turn.status` (no `Behavior.Mode`)

auto/copilot/takeover are **not** a behavior and **not** a turn field. They are three
**routing configurations** (expressed with the existing `Behavior.Routing`) plus the turn's
`status`:
- **`:auto`** — orchestrator → customer (default fan-out).
- **`:copilot`** — replace the *agent → customer* edge with *agent → operator*; the operator
  forwards/edits → customer (operator is a mandatory relay). Turn-granular for free, because
  the orchestrator emits exactly one composed result per turn.
- **`:takeover`** — customer → operator direct; the agent is off the delivery path (optionally
  still routed to the operator as a suggestion only).

`turn.claim` inserts the operator-relay rules via `Behavior.Routing` and sets
`owner=operator`, `status=awaiting_human`; `turn.settle`/`release` restores the auto rules.
This matches the AutoService team's own phase-2 decision (`235a2e96`: takeover via
Mode-suppression *now*, copilot via *routing-reconfig later*) — the greenfield rewrite goes
straight to the routing-reconfig end-state and skips the Mode-suppression interim. We do not
port #511.

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
6. **(optional) Mode policy** — the predicate that flips routing to copilot/takeover (e.g.
   "confidence < X → operator copilot"). Default: all-auto, operator may `claim` any time.

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
3. Workers deliver: nl-worker → a `text` node; page-worker → a UI-tree fragment written via
   `turn.deliver`; the composed tree lands in the `:surface` slice (new version).
4. Orchestrator `turn.compose` → `:composing`.
5. Routing-gate at compose→settle:
   - auto → `turn.settle` → projection.
   - copilot/takeover (operator-relay rules active, from a prior `turn.claim`) →
     `:awaiting_human`; the operator approves/edits → `turn.settle`.
6. Projection (the existing View layer):
   - `ConversationView` renders the `text` node as a **chat bubble**.
   - `PageView` interprets the `:surface` UI tree and renders the **live page**.
   - Both surfaces update from the **same turn** — the fusion.

## 7. Self-evolve (SW-UPD) on the #17 cascade

Self-evolve reuses the same turn/UI-tree/projection/copilot machinery, pointed at the
**agent's own config** as the artifact, with the **cascade as the write target**:
1. A config/optimization session's **optimizer agent** reads the service session's traces
   (messages + outcomes + **the operator's takeover edits — the gold supervised signal**).
2. The optimizer emits a **config-delta** as a UI-tree card (a new skill entry / soul
   refinement / kb addition).
3. The operator **copilot-approves** the delta — *the same routing-relay mechanism as SW-USE*
   (operator is the mandatory relay on the optimizer → cascade edge). Human-in-the-loop is the
   safety gate on self-evolve.
4. The approved delta is written to the agent's **high cascade layer** (user/workspace), which
   is **versioned and reversible** (#17 grant/materialize write path).
5. On the next spawn, the cascade **re-materializes** the improved config; a later customer
   turn exhibits the changed behavior.

Reuse highlight: the operator's copilot-approval path is identical in SW-USE (approve a
customer reply) and SW-UPD (approve a config delta) — one routing mechanism serves both the
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
A developer authors a vertical from the template (SessionTemplate `Chat+Turn+surface`;
orchestrator/nl/page AgentTemplates via cascade; register `ConversationView`+`PageView`;
routing rules). Instantiate it.
- **Invariant:** with **zero core-code change**, the new session boots; the view-switcher
  shows both views; the agents are spawned and credential-materialized.
- Artifact: agent-browser screenshot of the new session with both views + agents present.

**SW-USE (user-interaction phase)** — *the fusion + takeover.*
Non-admin customer + operator. Customer asks for "a comparison page + a recommendation."
- **Invariant:** a **single turn drives both surfaces** — fails if only one updates.
  Plus: an operator `turn.claim` (routing-reconfig) reaches the customer with the operator's
  output.
- Artifacts: screenshot ① chat bubble, ② live page (same turn), ③ operator takeover reaching
  the customer; plus a multi-user/cold-restart check (second viewer sees the same `:surface`
  version; restart re-renders).

**SW-UPD (update phase)** — *the self-evolve loop closes.*
Optimizer agent + operator. Optimization session reads SW-USE traces (incl. operator edits)
→ config-delta card → operator copilot-approves → delta written to the agent's cascade high
layer → respawn re-materializes → a later customer turn shows changed behavior.
- **Invariant:** the agent's **resolved config changed via the flow (not hand-edit), is
  versioned/reversible, and is observable in a later turn.**
- Artifact: screenshot of the delta card + approval + the changed behavior.

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

## 11. Phasing

- **P1 — `Behavior.Turn` + `:turns` slice** (the orchestration state machine; TDD; the
  degenerate single-bot turn first, then fan-out/compose).
- **P2 — `:surface` slice + `PageView`** (the UI-tree contract + the generic interpreter View;
  declarative tier first, `code`-node deferred per §10.2).
- **P3 — routing-as-mode** (`turn.claim`/`release` reconfiguring rules via `Behavior.Routing`;
  copilot relay).
- **P4 — first fused vertical + SW-USE E2E** (orchestrator + nl + page workers; both views;
  the fusion invariant test).
- **P5 — self-evolve (SW-UPD)** on the #17 cascade write path + the SW-UPD invariant test.
- **SW-DEV** authoring E2E rides alongside P4 (it proves the template surface that P1–P3
  expose).

## 12. Dependency on #17

socialware's update phase (§7) is the **first major consumer** of the #17 credential/config
cascade write path (config-delta → high layer → re-materialize). The cascade is therefore a
**prerequisite for P5**, not for P1–P4. The two workstreams are parallel and non-conflicting:
socialware adds new files (`Behavior.Turn`, `:surface`, `PageView`) and touches none of the
`credential/`/`materializer`/`resolver`/`grant` files the cascade work owns.
