# Design: socialware — fused backend-agent + real-time-render sessions on existing ezagent primitives

> **Status:** buildable design, rev3 (Allen 2026-06-07). Supersedes the synthesis revision and
> rev1/rev2. Direction: **rewrite directly, reuse `main`, do NOT base on the loom/autoservice
> branches.** Verified against `origin/main` (sha `5661964c`). rev3 incorporates Allen's
> review + two rounds of codex adversarial review: the customer-visibility **filter lives in
> the external View, not the core** (the core stays thin); the customer surface is a **React +
> json-render SPA** (the loom frontend half), with **LiveView kept for the admin/operator
> surface** (dual-surface). The earlier AutoService/loom summary is retained only where it
> informs a reuse decision; the design is greenfield-on-main.

## 1. What socialware is

socialware is the pattern where **one session simultaneously drives a conversational surface
(chat) and a live-rendered surface (a web page), produced by the same agent orchestration,
with a human able to take over.** "AutoService" (customer ↔ bot ↔ operator chat with takeover)
and "loom" (orchestrator → workers → live-rendered page) are not two apps — they are **two
interaction surfaces over one session**.

ezagent is the **backend**; the product is the **external customer page**. The backend holds
everything (all messages, all page versions, including unapproved drafts — operator
transparency); the **customer-facing external view is a filtered projection** that shows only
approved content. A developer builds a new vertical by **declaring**, not by writing core code.

## 2. Design principle: reuse `main`, thin core, filter at the edge

Two constraints organize the design:
1. **Reuse `main`; keep net-new minimal and well-bounded** (§3 lists what already exists).
2. **The core is transparent; the customer filter lives in the external View** (Allen's
   correction, §4.3). ezagent showing all messages/page-states in the backend is correct; the
   approved-only filter is a property of the customer-facing projection, like `ExternalMirror`.

Net-new is two groups: the **backend** (`Behavior.Turn` + `:turns` slice; `:surface` slice;
§4.1–4.2) and the **customer frontend** (a React + json-render SPA + a streaming endpoint;
§4.4). The admin/operator surface reuses the existing LiveView `SessionView` (§4.2).

## 3. Reused-from-`main` components (verified on `origin/main` @ `5661964c`)

| Concern | Existing component | Path |
|---|---|---|
| Session as a Kind | `Ezagent.Entity.Session` (+ `:chat` slice, `Behavior.Chat`) | `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex`, `.../behavior/chat.ex` |
| Message persistence | `Ezagent.MessageStore` (separate `messages`+`message_routings` DB; PubSub fan-out) | `apps/ezagent_core/lib/ezagent/message_store.ex` |
| **The View abstraction** (per-session render surface + view-switcher) | `Ezagent.UI.SessionView` behaviour (`id/label/icon/applies_to?/render`) + `Ezagent.UI.SessionViewRegistry` — lives in the domain tier (`ezagent_domain_ui`), reusable by any plugin; render contract is LiveView (`render/1 :: Phoenix.LiveView.Rendered.t()`) | `apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex`, `.../session_view_registry.ex` |
| Shipped views | `ConversationView` (chat), `Pty.TerminalView`, `RoutingView`, `ExternalMirror.View` | `apps/ezagent_plugin_liveview/.../views/conversation_view.ex` et al. |
| **Selective external projection** (the filter pattern) | `Behavior.ExternalMirror` + `ExternalMirror.View` — projecting a session outward with a per-binding filter | `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex` |
| Routing (runtime-mutable, per-session, cap-checked) | `Ezagent.Behavior.Routing` → `RuleStore.{add,delete,disable,enable}` by rule id; `system_default` rule (`$session_users`+`$mentions`) is delete-protected but **disable-able** | `apps/ezagent_core/lib/ezagent/behavior/routing.ex`, `.../routing/{rule_store,resolver,matcher}.ex` |
| Agent provisioning + per-agent config/credentials | the #17 **credential/config cascade** (flavor-base → workspace → user → session; resolver + grant + materializer) | `apps/ezagent_core/lib/ezagent/credential/*`, `.../agent/materializer.ex` |
| Session/Agent templates | `Entity.SessionTemplate`, `Entity.AgentTemplate`, `template.read/write` | `apps/ezagent_domain_chat/lib/ezagent/entity/{session_template,agent_template}.ex` |

**Two facts that shaped this design (correct the synthesis revision):**
- `Behavior.Mode` (#511 takeover/copilot) is **NOT on `main`** — it lives on
  `origin/feat/cs-operator`. We do **not** port it; mode is a turn property + the external
  filter (§4.3).
- loom (`page_update` / typed-card / Next.js SPA / Sandpack / SSE bridge) is **not in esr-ng**
  — it is separate/external code. The customer frontend (§4.4) is built here, **porting loom's
  frontend** where useful.

## 4. Net-new components

### 4.1 `Behavior.Turn` + the `:turns` slice — the orchestration state machine

A **turn** is one atomic interaction cycle: a triggering input, the fan-out it caused, the
deliverables collected, the composed result, and its lifecycle status. It is a noun;
`Behavior.<noun>` owning `:<noun>` (matching `Behavior.Chat`/`:chat`) gives `Behavior.Turn`
owning `:turns`.

**`:turns` slice** — `turn_id => turn record` (small; `{:snapshot, :on_change}`; message
bodies stay in `MessageStore`, page trees in `:surface`, the slice holds references + status):

```
%{
  turn_id     => %{
    trigger:     message_ref,        # the input message that opened the turn
    owner:       uri,                # agent_uri (auto) | user_uri (after claim)
    mode:        :auto | :copilot | :takeover,
    expected:    MapSet.t(subtask_id),
    collected:   %{subtask_id => card_ref},
    result:      [card_ref],         # composed deliverables (chat refs + surface version)
    status:      :open | :delegating | :aggregating | :composing
                 | :awaiting_human | :settled | :cancelled,
    approved:    boolean,            # auto ⇒ true at compose; copilot/takeover ⇒ on operator approve
    turn_no:     integer,
    opened_at:   integer             # passed in; no Date.now in core
  }
}
```

**Action set** (Behavior actions, cap-checked via the dispatch surface):
- `turn.open(trigger)` → `:open`
- `turn.dispatch(turn_id, subtasks)` — record `expected`; the `@mention chat.send` fan-out is
  a `Chat` action → `:delegating`
- `turn.deliver(turn_id, subtask_id, card_ref)` — collect one worker deliverable → `:aggregating`
- `turn.compose(turn_id, result_refs)` — orchestrator composes; writes the chat result to
  `MessageStore` and the page tree as a new `:surface` version. **Writes happen freely (the
  backend is transparent); they carry `approved = mode == :auto`.** → `:composing`
- `turn.claim(turn_id, by: user_uri)` — human takeover: set `owner`, `mode`; an additive route
  delivers the draft to the operator (§4.3) → `:awaiting_human`
- `turn.settle(turn_id)` — close the turn and **mark its output approved** (auto: at compose;
  copilot/takeover: when the operator approves/edits). This is *not* a write-gate — it flips
  the approval marker the external view filters on (§4.3) → `:settled`
- `turn.cancel(turn_id)` / timeout → `:cancelled` (its unapproved output is never approved, so
  the customer never sees it)

Partial worker failure / timeout: a missing `deliver` leaves `expected ⊅ collected`; the
orchestrator composes degraded or `turn.cancel`s. An un-`settle`d turn's output stays
`approved = false`, so the customer never sees a half-built result regardless.

**State machine:** `open → delegating → aggregating → composing → [awaiting_human] → settled`;
`cancel`/timeout from any non-terminal state. The human-in-the-loop branch is **composing →
(settle | awaiting_human)**, decided by `mode`. **Customer visibility is governed downstream
by the external view's approved-only filter (§4.3), not by withholding backend writes** — the
core stays thin.

The degenerate single-bot case (no orchestration) is a turn with zero `expected`: open →
compose(bot reply) → settle. Same machinery covers plain chat replies.

### 4.2 `:surface` slice — the page state (rendered by two surfaces)

The chat log is append-only in `MessageStore`; a **page** is mutable, evolving state, so it is
a durable slice:

```
%{ latest: %{version, tree, by_turn}, approved_version: integer }
```

`:surface` holds the **full** version stream (transparent backend). `approved_version` tracks
the highest version whose turn is `settled`/approved. Rendering splits by audience:
- **operator/admin** renders `latest` (sees unapproved drafts — transparency);
- **customer** renders `tree @ approved_version` (the filter, §4.3).

**UI tree = an implementation-agnostic, json-render declarative node** (`vercel-labs/json-render`,
used directly on the React side, §4.4): recursive `%{type, props, children}`, rendered via a
**component registry** (`type => component`). A worker deliverable is a UI-tree fragment; the
orchestrator composes fragments into the page tree. Tiers:
- **declarative nodes** — registry components (bubble, comparison-table, form, …);
- **`code` node** — sandboxed arbitrary generated JSX/HTML (Sandpack) — in scope now that the
  customer frontend is React (§4.4), porting loom's renderer.

**Two render surfaces (dual-surface, Allen-approved):**
- **operator/admin = LiveView.** Reuse the existing `Ezagent.UI.SessionView` — a `PageView`
  (`SessionView` rendering `:surface.latest` via a server-side HEEx interpretation of the tree)
  alongside the existing `ConversationView`. Admin tabs may stay exclusive (acceptable for the
  backend); a small operator composite is optional. This surface shows drafts for review.
- **customer = React + json-render SPA** (§4.4). This is the rich product surface and the home
  of genuine same-screen multi-view (chat pane + page pane in one React layout) and of the
  approved-only filter.

### 4.3 Mode = turn approval status + the external view's filter (no `Behavior.Mode`, no routing replacement)

Two codex findings drove this: (HIGH) main routing is runtime-mutable but *additive in
practice* — the delete-protected `system_default` rule keeps delivering agent messages to the
customer, so routing cannot cleanly suppress customer delivery; and (Allen) the suppression
**belongs in the external view**, not the core. So:

- **The customer filter is the external view's job.** The customer SPA's streaming endpoint
  (§4.4) is an `ExternalMirror`-style projection that emits only **approved** content: chat
  messages whose turn is settled/forwarded, and `:surface` at `approved_version`. Unapproved
  drafts exist in the backend but are never projected to the customer.
- **`turn.mode` + the approval marker** drive that filter: `:auto` approves at compose (customer
  sees immediately); `:copilot`/`:takeover` hold approval until the operator acts.
- **Routing (unchanged) does internal fan-out + delivering the draft to the operator** (an
  additive `@mention`-style rule). It is *not* the gate; the `system_default` rule is left
  intact.
- The three modes: **`:auto`** compose→settle→approved→customer sees it; **`:copilot`** draft
  visible to operator only; operator approves/edits → approved → customer sees it; **`:takeover`**
  `owner` = operator (from `claim`); operator authors the result; the agents' draft is a
  suggestion to the operator; operator's content is approved on settle.

So mode adds **no new behavior, no routing-replacement primitive, and no core write-gate** — it
is `turn.mode` + the approval marker + the external view filtering on it. (Supersedes the
AutoService `235a2e96` route-suppression framing; we do not port `Behavior.Mode`/#511.)

### 4.4 Customer frontend — React + json-render SPA + a streaming endpoint (the loom frontend half)

The customer-facing surface is a **React SPA** that renders the session via **json-render** (UI
tree → React component registry) plus a **streaming endpoint** on the backend. This is a real,
one-time frontend foundation: once built, frontend devs extend a **React component registry**
and the backend emits json-render trees — a standard, scalable frontend story (LiveView's UI
ecosystem is comparatively limited; this unlocks arbitrary generated UI). loom (#480) already
implements much of this (Next.js SPA + Sandpack + SSE bridge) and is **ported/adapted**, not
built from zero.

Pieces:
- **streaming endpoint** — a backend WS/SSE endpoint exposing a session's approved chat +
  `:surface @ approved_version` to external clients (the `ExternalMirror`-style filter, §4.3);
- **React SPA + json-render runtime + component registry** — the reusable extension point;
- **Sandpack** — the `code`-node sandbox for arbitrary generated UI;
- **external/anonymous customer auth + session binding** — gates external access (overlaps the
  known anon-customer-identity prerequisite).

The backend (§4.1–4.3) is **frontend-agnostic**: it can be driven by the LiveView operator
surface and the React customer SPA at once. This lets backend E2E run against a thin LiveView
render first, with the React SPA landing as its own phase (§11).

## 5. Developer authoring surface (what a vertical declares)

A vertical declares over reuse — **zero core code**. The six slots:
1. **SessionTemplate** — compose `Behavior.Chat + Behavior.Turn` (+ `:surface` if it has a
   page); member roster (orchestrator / N workers / customer-user / operator-user); routing
   rules (`{:from customer} → orchestrator`, `{:from orchestrator @worker} → worker`).
2. **AgentTemplate × role** — orchestrator + workers: flavor (cc/codex/curl), soul/skill/kb
   prompt config (resolved through the #17 cascade), credential source.
3. **UI node types + schema** — the declarative node types this vertical emits (base + domain
   nodes, e.g. `quote_comparison`).
4. **Renderers** — a **React component** per node type registered in the json-render registry
   (customer surface); optionally a HEEx component for the operator `PageView`.
5. **Orchestration policy** — the turn's decompose/compose; usually prompt-driven in the
   orchestrator AgentTemplate; a small policy module only when hard logic is needed.
6. **(optional) Mode policy** — the predicate that flips a turn to copilot/takeover. Default:
   all-auto; operator may `claim` any time.

**Where it physically lives (naming locked).** The base ships as the domain app
**`ezagent_domain_socialware`** (introducing `Behavior.Turn` + the `:surface` contract; beside
`ezagent_domain_chat`/`ezagent_domain_ui`), plus the customer-frontend foundation (§4.4). Each
vertical is its **own plugin app `ezagent_plugin_<name>`** (consistent with `ezagent_plugin_cc`/
`ezagent_plugin_feishu`), registering via `Application.start/2`. The six slots land as
declarations/assets:
- slots 1–2 → **template content seeds** (`Entity.SessionTemplate`/`AgentTemplate` +
  `template.write`), with orchestrator/worker prompts as AgentTemplate content;
- slot 3 → a small Elixir module declaring node types;
- slot 4 → React components in the plugin's `assets/`, registered into the json-render registry
  (+ optional HEEx for the operator view), from `Application.start/2`;
- slots 5–6 → prompts + optional tiny policy modules.

So "the authoring surface" = a plugin app's `Application.start/2` + its template seeds + its
`assets/` React components — **no edits to `ezagent_core`/`ezagent_domain_socialware`**.

> A "plugin **bundle**" (VS-Code-style one-shot install of several plugins together) is a
> possible future convenience; there is no use case yet and it is not implemented. A vertical
> is just a normal plugin app for now.

The canonical verticals are different fills of the same slots: **AutoService** = `{text}` node
+ bubble renderer + zero-subtask direct answer; **loom** = `{page_update/code}` node + Sandpack
renderer + page-worker fan-out; **fused vertical** = both node families + both renderers + NL +
page workers → one turn drives both customer panes.

## 6. Runtime data flow (SW-USE, the fused path)

1. Customer message → `Chat` persists to `MessageStore` → routing `{:from customer}` →
   orchestrator.
2. `turn.open` + `turn.dispatch([nl, page])` → `:delegating`; `@mention chat.send` to workers.
3. Workers `turn.deliver`: nl-worker → a `text` node; page-worker → a UI-tree fragment →
   `:aggregating`.
4. `turn.compose` → writes the chat result to `MessageStore` and a new `:surface` version;
   both marked `approved = (mode == :auto)` → `:composing`.
5. Mode (§4.3): `:auto` → `turn.settle` (approved). `:copilot`/`:takeover` → `:awaiting_human`;
   the draft is visible to the operator only; operator approves/edits → `turn.settle`.
6. The customer React SPA's streaming endpoint emits only approved content; on approval it
   renders, **in one viewport**, the `text` node as a **chat bubble** and `:surface @
   approved_version` as the **live page** — both from the same turn (the fusion). Before
   approval the customer sees neither; the operator LiveView surface saw the draft throughout.

## 7. Self-evolve (SW-UPD) on the #17 cascade

Self-evolve reuses the turn/UI-tree/projection/approval machinery, pointed at the **agent's
own config**, writing to the cascade:
1. An optimization session's **optimizer agent** reads service-session traces (messages +
   outcomes + **the operator's takeover edits — the gold supervised signal**).
2. It emits a **config-delta** as a UI-tree card.
3. The operator approves it via the **same approval gate as SW-USE** (the optimizer turn holds
   at `:awaiting_human`; operator approves/edits before settle).
4. The approved delta is written to the agent's **high cascade layer** (user/workspace) as a
   **mutable overwrite** — matching current #17 (config-layer versioning is out of scope now;
   "rollback" = re-applying the prior value, best-effort). Versioned/reversible config is a
   future item to do together with #17, **not built here**.
5. Next spawn re-materializes the config; a later customer turn shows the changed behavior.

Reuse highlight: the operator's approval path is identical in SW-USE and SW-UPD — one gate for
both the interaction and the update phase.

## 8. Multi-user & persistence

- **Durable by construction**: `:surface` persists `{:snapshot, :on_change}` (versioned, with
  `approved_version`). Cold restart re-renders; the customer always sees `approved_version`.
- **Same-session, two users** = one shared page. Concurrency: **`Behavior.Turn` serializes**
  surface mutation (a turn is the unit; the state machine orders turns), so a later turn sees
  the earlier's committed state — **no CRDT for the common case**.
- **Separate pages** = fork the SessionTemplate into separate sessions; each owns its `:surface`.
- chat (`MessageStore`, append-only) and page (`:surface`, mutable versioned) are two stores
  with different semantics under one session; both are filtered to approved for the customer.

## 9. Acceptance: three-phase E2E

Each phase locks one architectural invariant; together they are the completion gate (a phase is
not "done" until its invariant test passes — not on merge/tests-pass alone).

**SW-DEV (development)** — *the authoring/framework surface works.*
A developer authors a vertical plugin (§5) — all in the plugin, no edits to
`ezagent_core`/`ezagent_domain_socialware`. Instantiate it.
- **Invariant:** with **zero core-code change**, the session boots; the operator LiveView
  surface mounts; the customer SPA mounts with both panes; agents spawned + credential-materialized.
- Artifact: agent-browser screenshot of the operator surface + the customer page + agents present.

**SW-USE (user-interaction)** — *the fusion + takeover.*
Non-admin customer + operator. Customer asks for "a comparison page + a recommendation."
- **Invariant:** a single approved turn drives **both panes of the customer React SPA
  simultaneously in one viewport** (fails if only one updates, or if they are only separate
  tabs). Plus: in `:copilot`/`:takeover` the **customer sees nothing** (no bubble, no page)
  until the operator approves — while the **operator LiveView surface shows the draft** — and
  what reaches the customer is the operator's output.
- Artifacts: one customer-page screenshot showing ① chat bubble + ② live page side-by-side from
  the same turn; ③ a copilot turn where the draft is visible on the operator surface but absent
  from the customer page until approval; plus multi-user/cold-restart (second viewer sees the
  same `approved_version`; restart re-renders; **no unapproved draft is ever shown to the
  customer**).

**SW-UPD (update)** — *the self-evolve loop closes.*
Optimizer + operator. Optimization session reads SW-USE traces → config-delta card → operator
approves → overwrite the agent's cascade high layer → respawn re-materializes → a later customer
turn shows changed behavior.
- **Invariant (scoped to current #17, §7):** the agent's **resolved config changed via the flow
  (not hand-edit) and is observable in a later turn**; **rollback** = re-applying the prior value
  reverts the behavior. (Version-history reversibility is a future item, not asserted here.)
- Artifact: screenshot of the delta card + approval + the changed behavior, then the revert.

**E2E standards (all three):** non-admin customer is the primary caller; granting the operator
its cap is itself a step; **fresh docker seed each run**; faces **production topology** (real
routing/spawn/MessageStore, no test-harness shortcuts); **agent-browser screenshots on the real
ESR UI at `http://100.64.0.27:10042`** (operator LiveView) and the customer SPA's external route
(Tailscale IP, not localhost); every distinct bug earns a fast regression test before the fix.

## 10. Open decisions (reduced)

Resolved: framework-vs-app (one substrate + plugins; verticals are `ezagent_plugin_<name>`);
mode (turn approval + external filter, no `Behavior.Mode`); filter placement (external view);
frontend (React + json-render, dual-surface with LiveView for operator); config versioning
(out of scope now, overwrite). Remaining:
1. **Streaming endpoint transport** — WS vs SSE for the customer SPA; reuse/port loom's bridge
   shape. (Lean: match loom's to minimize port risk.)
2. **Anonymous/synthetic customer identity** — needed for the external customer page; build the
   anon model in the frontend phase, or seed a test user for the first E2E? (Lean: seeded user
   for the first SW-USE E2E; anon model in/after the frontend phase.)
3. **`{:within_workspace}` cap shape** — for tenant-admin/customer isolation; introduce with
   SW-DEV (templates are workspace-scoped). (Lean: yes, with SW-DEV.)
4. **Operator surface composition** — keep exclusive admin tabs (chat / page), or add a small
   operator composite? (Lean: exclusive tabs first; the real same-screen is the customer SPA.)

## 11. Phasing

Backend first (frontend-agnostic), then the React customer frontend as its own phase.
- **P1 — `Behavior.Turn` + `:turns` slice** (state machine; TDD; degenerate single-bot turn
  first, then fan-out/compose).
- **P2 — `:surface` slice + operator LiveView render** (`approved_version`; a thin `PageView`
  HEEx interpreter so backend E2E can run before the SPA exists).
- **P3 — mode = approval + external filter** (`turn.claim`/approve/`settle`; the additive
  operator-draft route; the approved-only projection logic — no routing-replacement primitive).
- **P4 — customer frontend foundation** (streaming endpoint + React SPA + json-render runtime +
  component registry + Sandpack + external/anon auth) — porting loom's frontend; the one-time
  React foundation.
- **P5 — first fused vertical + SW-USE E2E** (orchestrator + nl + page workers; the
  simultaneous-surfaces + approval-filter invariant tests on the customer SPA).
- **P6 — self-evolve (SW-UPD)** on the #17 cascade write path + the SW-UPD invariant test.
- **SW-DEV** authoring E2E rides alongside P5 (it proves the template surface P1–P4 expose).

## 12. Dependency on #17

socialware's update phase (§7) is the **first major consumer** of the #17 cascade write path
(config-delta → high layer → re-materialize), so #17 is a **prerequisite for P6**, not P1–P5.
The two workstreams are parallel and non-conflicting: socialware adds new files
(`ezagent_domain_socialware`, the vertical plugins, the React frontend) and touches none of the
`credential/`/`materializer`/`resolver`/`grant` files the cascade work owns.
