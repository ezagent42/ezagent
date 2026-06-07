# Design: socialware — fused backend-agent + real-time-render sessions on existing ezagent primitives

> **Status:** buildable design, rev5 (Allen 2026-06-07). Supersedes the synthesis + rev1–rev4.
> Direction: **rewrite directly, reuse `main`, do NOT base on the loom/autoservice branches.**
> Verified against `origin/main` (sha `5661964c`). rev5 reflects Allen's review + two codex
> rounds and converges on a small, unified model:
> - **immutable artifact + pointer** for both **agent config** and the **page (`:surface`)** —
>   update = new immutable version; rollback / approval = move a pointer;
> - **append-only chat + a per-message visibility tag**, with the **customer as a non-member
>   `ExternalMirror`-style external receiver** and a **tag-aware routing rule** delivering only
>   `customer-visible` messages to it;
> - **dual-surface**: operator/admin = LiveView; customer = React + json-render SPA.
>
> The earlier AutoService/loom summary is retained only where it informs a reuse decision; the
> design is greenfield-on-main.

## 1. What socialware is

socialware is the pattern where **one session simultaneously drives a conversational surface
(chat) and a live-rendered surface (a web page), produced by the same agent orchestration, with
a human able to take over.** "AutoService" (customer ↔ bot ↔ operator chat with takeover) and
"loom" (orchestrator → workers → live-rendered page) are not two apps — they are **two
interaction surfaces over one session**.

ezagent is the **backend**; the product is the **external customer page**. The backend holds
everything (all messages, all page versions, including unapproved drafts — operator
transparency); the **customer sees only an approved projection** — for chat, the messages a
routing rule delivers to the customer's external receiver; for the page, the version the
approved pointer points at. A developer builds a vertical by **declaring**, not by writing core
code.

## 2. Design principle: reuse `main`, thin core, one unifying shape

Two constraints:
1. **Reuse `main`; keep net-new minimal** (§3 lists what exists).
2. **One unifying shape:** *immutable artifact + a pointer* (config, page) and *append-only +
   a tag* (chat). The customer's view is defined entirely by **which pointer it follows** and
   **which tagged messages a routing rule delivers to it** — never by mutating or withholding
   backend state.

Net-new: `Behavior.Turn` + `:turns` slice; the `:surface` slice (immutable page versions +
approved pointer); a **routing tag-matcher** (small extension); and the **customer frontend**
(a React + json-render SPA fed by an `ExternalMirror`-style external receiver). The
operator/admin surface reuses the existing LiveView `SessionView`. Agent **config** uses an
immutable-config object + a cascade pointer.

## 3. Reused-from-`main` components (verified on `origin/main` @ `5661964c`)

| Concern | Existing component | Path |
|---|---|---|
| Session as a Kind | `Ezagent.Entity.Session` (+ `:chat` slice, `Behavior.Chat`) | `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex`, `.../behavior/chat.ex` |
| Message persistence (append-only) | `Ezagent.MessageStore` (separate `messages`+`message_routings` DB; PubSub fan-out) | `apps/ezagent_core/lib/ezagent/message_store.ex` |
| **The View abstraction** + view-switcher | `Ezagent.UI.SessionView` (`id/label/icon/applies_to?/render`) + `SessionViewRegistry` — domain tier, render contract is LiveView | `apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex` |
| Shipped views | `ConversationView` (chat), `Pty.TerminalView`, `RoutingView`, `ExternalMirror.View` | `apps/ezagent_plugin_liveview/.../views/conversation_view.ex` et al. |
| **External projection to a non-member receiver** (the customer-surface pattern) | `Behavior.ExternalMirror` + bindings — project a session outward to a receiver that is **not a `$session_user`** | `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex` |
| Routing (runtime-mutable, per-session, cap-checked) | `Ezagent.Behavior.Routing` → `RuleStore.{add,delete,disable,enable}`; matchers in `routing/matcher.ex`; `system_default` (`$session_users`+`$mentions`) is delete-protected | `apps/ezagent_core/lib/ezagent/behavior/routing.ex`, `.../routing/{rule_store,resolver,matcher}.ex` |
| Agent provisioning + per-agent config/credentials | the #17 **credential/config cascade** (flavor-base → workspace → user → session) | `apps/ezagent_core/lib/ezagent/credential/*`, `.../agent/materializer.ex` |
| Session/Agent templates | `Entity.SessionTemplate`, `Entity.AgentTemplate`, `template.read/write` | `apps/ezagent_domain_chat/lib/ezagent/entity/{session_template,agent_template}.ex` |

**Two facts that shaped this design:** `Behavior.Mode` (#511) is **NOT on `main`** (it is on
`origin/feat/cs-operator`) — not ported. loom (Next.js SPA / Sandpack / SSE bridge) is **not in
esr-ng** — the customer frontend (§4.4) is built here, porting loom's frontend.

## 4. Net-new components

### 4.1 `Behavior.Turn` + the `:turns` slice — the orchestration state machine

A **turn** is one atomic interaction cycle. `Behavior.<noun>` owning `:<noun>` (cf.
`Behavior.Chat`/`:chat`) gives `Behavior.Turn` owning `:turns`:

```
%{
  turn_id   => %{
    trigger:    message_ref,
    owner:      uri,                 # agent_uri (auto) | user_uri (after claim)
    mode:       :auto | :copilot | :takeover,
    expected:   MapSet.t(subtask_id),
    collected:  %{subtask_id => card_ref},
    result:     [card_ref],          # chat message refs + a page version id
    status:     :open | :delegating | :aggregating | :composing
                | :awaiting_human | :settled | :cancelled,
    turn_no:    integer,
    opened_at:  integer              # passed in; no Date.now in core
  }
}
```

**Action set** (cap-checked Behavior actions):
- `turn.open(trigger)` → `:open`
- `turn.dispatch(turn_id, subtasks)` — record `expected`; the `@mention chat.send` fan-out is a
  `Chat` action → `:delegating`
- `turn.deliver(turn_id, subtask_id, card_ref)` — collect a worker deliverable → `:aggregating`
- `turn.compose(turn_id, result_refs)` — orchestrator composes. Chat messages are written to
  `MessageStore` **with a visibility tag** (`:customer_visible` in `:auto`; `:operator_only`
  while a copilot/takeover turn is unapproved). A page deliverable is written as a **new
  immutable `:surface` version** (§4.2). → `:composing`
- `turn.claim(turn_id, by: user_uri)` — human takeover: set `owner`, `mode`; the agent's
  ongoing messages are tagged `:operator_only` → `:awaiting_human`
- `turn.settle(turn_id)` — close the turn and **publish its output to the customer**: advance
  the `:surface` **approved pointer** to this turn's page version, and (for held copilot/takeover
  messages) flip the operator-forwarded message(s) to `:customer_visible`. In
  `:copilot`/`:takeover` this runs **only after the operator approves/edits** → `:settled`
- `turn.cancel(turn_id)` / timeout → `:cancelled` (its page version is never pointed-to; its
  messages stay `:operator_only` — the customer never sees them)

Partial worker failure / timeout: a missing `deliver` leaves `expected ⊅ collected`; the
orchestrator composes degraded or `turn.cancel`s. An un-`settle`d turn never advances the
approved pointer and its messages never become `:customer_visible`, so a failed turn cannot
leak.

**State machine:** `open → delegating → aggregating → composing → [awaiting_human] → settled`;
`cancel`/timeout from any non-terminal state. The human-in-the-loop branch is **composing →
(settle | awaiting_human)**, decided by `mode`. **Customer visibility is governed by the
pointer (page) and the tag/routing (chat) — never by withholding backend writes** (the core
stays thin).

The degenerate single-bot case is a turn with zero `expected`: open → compose(reply, tagged
`:customer_visible` in auto) → settle.

### 4.2 `:surface` slice — the page as immutable versions + an approved pointer

The chat is append-only in `MessageStore`; a **page** is a mutable, evolving document, modeled
as **immutable versions + a pointer** (the same shape as config, §7):

```
%{
  versions: %{version => %{tree, by_turn}},   # immutable; never mutated/overwritten
  approved: version | nil                      # the pointer the customer follows
}
```

- `turn.compose` appends a **new immutable version**; `turn.settle` advances `approved` to it
  (auto: at compose-time settle; copilot/takeover: at operator approval).
- **customer** renders `versions[approved]`; **operator/admin** renders the latest version
  (drafts included — transparency). Because every version is retained, the approved tree is
  always recoverable after a newer draft, a cold restart, or a second-viewer mount (this is the
  durable contract; a `latest`+pointer-only shape could not do this).

**UI tree = an implementation-agnostic, json-render declarative node** (`vercel-labs/json-render`,
used on the React side, §4.4): recursive `%{type, props, children}`, rendered via a **component
registry** (`type => component`). A worker deliverable is a UI-tree fragment; the orchestrator
composes fragments into a version. Tiers: **declarative nodes** (registry components) and a
**`code` node** (Sandpack-sandboxed arbitrary generated JSX/HTML — in scope, porting loom).

### 4.3 Mode = a per-message visibility tag + the page approved-pointer (no `Behavior.Mode`, no routing suppression)

auto/copilot/takeover are **not** a behavior. They decide two things, both expressed with
existing primitives:

**Chat — a per-message visibility tag + tag-aware routing.** Every chat message carries a
visibility tag (`:customer_visible | :operator_only`), a small attribute on the
`message_routings` side, set by the turn/mode. The **customer is a non-member
`ExternalMirror`-style external receiver** (not a `$session_user`), and a routing rule delivers
**only `:customer_visible`-tagged messages** to it. Because the customer receiver is *not* a
`$session_user`, the delete-protected `system_default` fan-out **never reaches it** — so there
is nothing to suppress (this is why routing now works cleanly for the filter, unlike the
member-model we rejected). Implementation = **a tag matcher added to `routing/matcher.ex`** + a
rule `{tag: :customer_visible} → customer_receiver`. The agent's takeover/copilot drafts are
tagged `:operator_only`, so **no rule routes them to the customer** — they reach the operator
(a member) only.

**Page — the approved pointer (§4.2).** `:auto` advances `approved` at compose; `:copilot`/
`:takeover` advance it only on operator approval. The customer renders `approved`; an unapproved
newer version is simply not pointed-to.

The three modes: **`:auto`** — messages `:customer_visible`, pointer advances at compose;
**`:copilot`** — agent messages/page version held (`:operator_only` / pointer not advanced) and
shown to the operator; on operator approve/edit → settle flips the forwarded message to
`:customer_visible` and advances the pointer; **`:takeover`** — `owner` = operator; agent output
stays `:operator_only` as a suggestion; the operator-authored message is `:customer_visible` and
its page edits become the approved version on settle.

**Enforceable, not a convention.** The customer receiver's **only inbound is the tag rule** —
customer routes must **not** be wired to the raw `MessageStore.recent_in_session`, the session
PubSub topic, or the generic `Publisher` feed (those are operator/internal). Raw-feed denial is
an acceptance invariant (§9). So mode adds **no new behavior, no routing suppression, no core
write-gate** — a tag attribute + a tag matcher + the approved pointer. (We do not port
`Behavior.Mode`/#511.)

### 4.4 Customer frontend — React + json-render SPA fed by the external receiver (the loom frontend half)

The customer surface is a **React SPA** rendering the session via **json-render** (UI tree →
React component registry) over a **streaming endpoint**. The streaming endpoint **is** the
`ExternalMirror`-style external receiver of §4.3: it carries the customer's
`:customer_visible` chat stream + `:surface.versions[approved]`, and **nothing else** (no raw
feed). This is a one-time frontend foundation: once built, frontend devs extend a React
component registry and the backend emits json-render trees (a standard, scalable frontend story;
unlocks arbitrary generated UI, which LiveView cannot). loom (#480) implements much of this
(Next.js SPA + Sandpack + SSE bridge) and is **ported/adapted**, not built from zero.

Pieces: the external-receiver streaming endpoint (tag-filtered chat + approved page); the React
SPA + json-render runtime + component registry; Sandpack for the `code` node; external/anonymous
customer auth + session binding.

The backend (§4.1–4.3) is **frontend-agnostic**: the LiveView operator surface and the React
customer SPA can both drive it. Backend E2E can run against a thin LiveView render before the
SPA lands (§11).

## 5. Developer authoring surface (what a vertical declares)

A vertical declares over reuse — **zero core code**. Six slots:
1. **SessionTemplate** — compose `Behavior.Chat + Behavior.Turn` (+ `:surface` if it has a
   page); roster (orchestrator / N workers / operator-user; the customer is the external
   receiver, not a roster member); routing rules (`{:from customer} → orchestrator`,
   `{:from orchestrator @worker} → worker`, `{tag: :customer_visible} → customer_receiver`).
2. **AgentTemplate × role** — orchestrator + workers: flavor (cc/codex/curl), soul/skill/kb
   config (resolved through the #17 cascade), credential source.
3. **UI node types + schema** — the declarative node types this vertical emits.
4. **Renderers** — a **React component** per node type in the json-render registry (customer);
   optionally a HEEx component for the operator `PageView`.
5. **Orchestration policy** — the turn's decompose/compose; usually prompt-driven in the
   orchestrator AgentTemplate; a small policy module only for hard logic.
6. **(optional) Mode policy** — the predicate that flips a turn to copilot/takeover. Default:
   all-auto; operator may `claim` any time.

**Where it lives (naming locked).** Base = domain app **`ezagent_domain_socialware`** (ships
`Behavior.Turn`, the `:surface` contract, the routing tag-matcher, the customer-frontend
foundation, the customer external-receiver wiring, and a base `session.socialware`
SessionTemplate). Each vertical = its **own plugin app `ezagent_plugin_<name>`** (consistent
with `ezagent_plugin_cc`/`_feishu`), registering via `Application.start/2`: template-content
seeds (slots 1–2, prompts as AgentTemplate content), a node-type module (slot 3), React
components in `assets/` (slot 4), prompts + optional tiny policy modules (slots 5–6) — **no
edits to `ezagent_core`/`ezagent_domain_socialware`**.

> A "plugin **bundle**" (VS-Code-style one-shot multi-plugin install) is a possible future
> convenience; no use case yet, not implemented. A vertical is just a normal plugin app.

Canonical verticals are different fills: **AutoService** = `{text}` node + bubble + zero-subtask
answer; **loom** = `{page_update/code}` node + Sandpack + page-worker fan-out; **fused** = both
node families + both renderers + NL + page workers → one turn drives both customer surfaces.

## 6. Runtime data flow (SW-USE, the fused path)

1. Customer message (from the external SPA) enters the session → `Chat` persists to
   `MessageStore` → routing `{:from customer} → orchestrator`.
2. `turn.open` + `turn.dispatch([nl, page])` → `:delegating`; `@mention chat.send` to workers.
3. Workers `turn.deliver`: nl-worker → a `text` message; page-worker → a UI-tree fragment →
   `:aggregating`.
4. `turn.compose` → writes the chat reply (tagged by mode) + a **new immutable `:surface`
   version** → `:composing`.
5. Mode (§4.3): `:auto` → `turn.settle` (message `:customer_visible`, pointer advances).
   `:copilot`/`:takeover` → `:awaiting_human`; agent output is `:operator_only` / pointer not
   advanced; operator approves/edits → `turn.settle`.
6. On settle: the `:customer_visible` chat message routes to the customer external receiver, and
   `:surface.approved` points at this version. The customer React SPA — fed only by that
   receiver — renders, **in one viewport**, the **chat bubble** and the **live page** from the
   same turn (the fusion). Before settle the customer sees neither; the operator LiveView saw
   the draft throughout.

## 7. Self-evolve (SW-UPD) — immutable config + a cascade pointer

Self-evolve reuses the turn/approval machinery, pointed at the **agent's own config**, using the
**immutable-artifact-+-pointer** shape (the same as the page):
1. An optimization session's **optimizer agent** reads service-session traces (messages +
   outcomes + **the operator's takeover edits — the gold supervised signal**).
2. It emits a **config-delta** as a UI-tree card.
3. The operator approves via the **same `turn.settle` gate** (the optimizer turn holds at
   `:awaiting_human`; operator approves/edits before settle).
4. Approval writes a **new immutable config object** and **repoints** the agent's #17 high
   cascade layer at it (the layer value is a pointer/id, not inline content — no #17 change
   needed). **Rollback = repoint to the prior config object** (it is immutable and retained), so
   rollback is real and deterministic with no overwrite, no CAS, no version-diffing.
5. Next spawn re-materializes the pointed-at config; a later customer turn shows the change.

Reuse highlight: one approval gate (SW-USE reply / SW-UPD config) and one immutable+pointer shape
(page / config).

## 8. Multi-user & persistence

- **Durable by construction**: `:surface` persists `{:snapshot, :on_change}` — all versions +
  the `approved` pointer. Cold restart re-renders; the customer always reads `versions[approved]`,
  never an unapproved newer version, even if a draft was in flight at crash time.
- **Same-session, two users** = one shared page; `Behavior.Turn` serializes surface mutation, so
  a later turn sees the earlier's approved state — **no CRDT for the common case**.
- **Separate pages** = fork the SessionTemplate into separate sessions.
- chat (`MessageStore`, append-only + visibility tag) and page (`:surface`, immutable versions +
  pointer) are two stores; both project to the customer only what the tag-rule / pointer allow.

## 9. Acceptance: three-phase E2E

Each phase locks one invariant; together they are the completion gate (not "done" on
merge/tests-pass alone).

**SW-DEV (development)** — *the authoring surface works.*
A developer authors a vertical plugin (§5) — all in the plugin, no edits to
`ezagent_core`/`ezagent_domain_socialware`. Instantiate it.
- **Invariant:** **zero core-code change**; the session boots; the operator LiveView surface
  mounts; the customer SPA mounts with both panes; agents spawned + credential-materialized.
- Artifact: agent-browser screenshot of operator surface + customer page + agents.

**SW-USE (user-interaction)** — *the fusion + takeover, leak-safe.*
Non-admin customer (external) + operator. Customer asks for "a comparison page + a recommendation."
- **Invariants:** (a) a single settled turn drives **both customer panes simultaneously in one
  viewport**; (b) in `:copilot`/`:takeover` the **customer sees nothing** until the operator
  approves, and the agent's `:operator_only` takeover-assist messages **never reach the customer
  receiver** (only the operator sees them); (c) **raw-feed denial** — a customer route reading
  `MessageStore.recent_in_session` / session PubSub / `Publisher` returns nothing (only the
  tag-rule + approved pointer feed the customer); (d) **cold restart / second viewer** — the
  customer renders `versions[approved]`, never an in-flight unapproved version.
- Artifacts: customer-page screenshot with ① bubble + ② live page side-by-side from one turn;
  ③ a copilot turn where the draft shows on the operator surface but is absent from the customer
  page until approval; restart + second-viewer checks.

**SW-UPD (update)** — *self-evolve, with real rollback.*
Optimizer + operator. Traces → config-delta → operator approves → new immutable config + repoint
→ respawn re-materializes → later customer turn shows changed behavior.
- **Invariant:** the agent's resolved config changed via the flow (not hand-edit), observable in
  a later turn; **rollback = repoint to the prior config object reverts the behavior** (real and
  deterministic, surviving restart, because configs are immutable + retained).
- Artifact: screenshot of the delta card + approval + changed behavior, then the repoint-revert.

**E2E standards (all three):** non-admin customer is the primary caller; granting the operator
its cap is itself a step; **fresh docker seed each run**; **production topology** (real
routing/spawn/MessageStore, no test-harness shortcuts); **agent-browser screenshots on the real
ESR UI at `http://100.64.0.27:10042`** (operator LiveView) and the customer SPA route (Tailscale
IP, not localhost); every distinct bug earns a fast regression test before the fix.

## 10. Open decisions (reduced)

Resolved: framework-vs-app (substrate + `ezagent_plugin_<name>` verticals); mode (tag + pointer,
no `Behavior.Mode`); customer = external `ExternalMirror`-style receiver (so routing needs no
suppression); frontend (React + json-render, dual-surface); config (immutable + pointer, real
rollback). Remaining:
1. **Tag-matcher shape** — how the visibility tag is stored (a `message_routings` column vs a
   message attribute) and matched in `routing/matcher.ex`. (Lean: a `message_routings` field +
   a `{tag: _}` matcher.)
2. **Streaming-endpoint transport** — WS vs SSE for the customer receiver; reuse loom's shape.
   (Lean: match loom's to minimize port risk.)
3. **Anonymous/synthetic customer identity** — for the external customer receiver; build the
   anon model in the frontend phase, or seed a test user for the first E2E? (Lean: seeded user
   for the first SW-USE E2E; anon model in/after the frontend phase.)
4. **`{:within_workspace}` cap shape** — for tenant-admin/customer isolation; introduce with
   SW-DEV (templates are workspace-scoped). (Lean: yes, with SW-DEV.)
5. **Immutable-config store location** — config objects in `ezagent_domain_socialware` vs a #17
   sub-store; the cascade high layer holds the pointer either way. (Lean: a small socialware
   config store now; converge with #17-V2 later.)

## 11. Phasing

Backend first (frontend-agnostic), then the React customer frontend as its own phase.
- **P1 — `Behavior.Turn` + `:turns` slice** (state machine; TDD; degenerate single-bot turn
  first, then fan-out/compose).
- **P2 — `:surface` slice + operator LiveView render** (immutable versions + approved pointer;
  a thin HEEx `PageView` so backend E2E runs before the SPA exists).
- **P3 — chat visibility tag + routing tag-matcher + customer external receiver** (the
  `{tag: :customer_visible} → customer_receiver` rule; `turn.settle` advancing the pointer +
  flipping tags; operator-only takeover-assist).
- **P4 — customer frontend foundation** (external-receiver streaming endpoint + React SPA +
  json-render runtime + component registry + Sandpack + external/anon auth) — porting loom; the
  one-time React foundation.
- **P5 — first fused vertical + SW-USE E2E** (orchestrator + nl + page workers; the
  simultaneous-surfaces + leak-safety invariants on the customer SPA).
- **P6 — self-evolve (SW-UPD)** — immutable-config store + cascade pointer + repoint-rollback +
  the SW-UPD invariant; consumes the #17 write path.
- **SW-DEV** authoring E2E rides alongside P5.

## 12. Dependency on #17

socialware's update phase (§7) consumes the #17 cascade (it repoints the high layer at an
immutable config object), so #17 is a **prerequisite for P6**, not P1–P5. The two workstreams
are parallel and non-conflicting: socialware adds new files (`ezagent_domain_socialware`, the
vertical plugins, the React frontend, the routing tag-matcher) and touches none of the
`credential/`/`materializer`/`resolver`/`grant` files the cascade work owns.
