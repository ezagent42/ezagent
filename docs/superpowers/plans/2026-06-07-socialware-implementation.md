# Socialware Implementation Plan (P1–P6 draft, for Codex handoff)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or
> superpowers:executing-plans to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.
>
> **Draft granularity (deliberate):** this is a **draft for Codex execution under the loose-audit
> handoff model** (see the companion handoff doc). P1–P3 (backend core) are spelled to
> near-TDD-step detail; P4–P6 (frontend, verticals, self-evolve) give file structure + ordered
> tasks + the **invariant tests verbatim** (the acceptance gates), and Codex fills the
> intermediate Red-Green-Refactor steps per TDD discipline. Every phase = one or more PRs;
> Codex self-merges in loose-audit mode (the author owns review + E2E + issue filing).

**Goal:** Build socialware — fused backend-agent + real-time-render sessions — on existing
ezagent primitives, per spec `docs/superpowers/specs/2026-06-07-socialware-design.md` (rev8,
codex-approved-for-planning).

**Architecture:** A new domain app `ezagent_domain_socialware` adds `Behavior.Turn` (a Kind-side
Behavior owning a `:turns` slice — the orchestration state machine) + a `:surface` slice (the
page as immutable versions + an `approved` pointer) + a `Message.visibility` field + a
visibility-aware **external-adapter family** (ExternalMirror = simple trusted mirror; the
customer SPA feed = the rich member: visibility filter + committed-settlement gate + per-request
auth). Mode (auto/copilot/takeover) is `turn.mode` + the approval marker + the external filter —
no `Behavior.Mode`, no routing suppression. Config (self-evolve) = immutable config object +
cascade pointer. Dual-surface: operator/admin = LiveView; customer = React + json-render SPA.

**Tech Stack:** Elixir/OTP umbrella; `Ezagent.Lifecycle` Behavior macro; Ecto (`ezagent_core`
`messages`/`message_routings` + a `:surface`/`:turns` snapshot slice); Phoenix LiveView
(operator); React + `vercel-labs/json-render` + Sandpack (customer SPA, porting loom #480);
`Ezagent.Invocation.dispatch` (action via `?action=turn.<x>`); `EzagentCore.DataCase` +
`Ezagent.LifecycleCase` tests.

---

## Locked contracts (do not re-litigate — codex-approved rev8)

1. **`Behavior.Turn` / `:turns`** — `use Ezagent.Lifecycle, state_slice: :turns` (with the
   `# lifecycle:state_slice_override` marker comment, since `:turns` ≠ the derived `:turn`).
2. **Visibility** is a field on `Ezagent.Message` (`:customer_visible | :operator_only`, default
   `:customer_visible`) — the single authoritative gate (matcher- and stream-readable).
3. **Settlement** — a record keyed by `turn_id` goes `:committed` LAST (after the MessageStore
   visibility flip + the `:surface` pointer advance). **Customer reads + the outbox derive from
   `:committed`.** No cross-DB transaction; the committed-gate is the atomicity.
4. **`:surface`** = `%{versions: %{version => %{tree, by_turn}}, approved: version | nil}`;
   customer renders `versions[approved]`, operator renders latest.
5. **Customer feed** = the rich external-adapter: committed-`:customer_visible` gated query
   (snapshot/history) + transactional-outbox signal (ids only, after commit, endpoint refetches
   filtered) + **per-request session-binding authz** (token → (session, workspace); denial
   tests). Never the raw Publisher / unfiltered ExternalMirror.
6. **Config** = immutable config object + the #17 high-cascade-layer holds a pointer; rollback =
   repoint.

## Repo facts (verified on `origin/main`, avoid these traps)

- Chat domain app is **`ezagent_domain_instance_message`** (NOT `ezagent_domain_chat`). Session
  Kind: `apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex`; Chat behavior:
  `.../lib/ezagent/behavior/chat.ex` (reference impl).
- New Behaviors **`use Ezagent.Lifecycle`** (`apps/ezagent_core/lib/ezagent/lifecycle.ex`), NOT
  bare `use Ezagent.Behavior`. Handlers are **`handle_<action>(args, ctx)` — arity 2 only**.
  Return `{:ok, result, [effect]}` | `{:ok, result}` | `{:error, reason}`. Effects:
  `{:set, k, v}` (persistent), `{:set_transient, k, v}`, `{:emit, k, map}`, `{:dispatch, %Cmd{}}`,
  `{:notify, topic, term}`, `{:terminate, target}` (full list in `behavior.ex:904-918`).
- Slice is `%{state, transients}`: `create/1` returns `{:ok, state_map}` (run once); `activate/2`
  rebuilds transients each start. Read persistent state via `ctx[:read].(:key, default)`; mutate
  via `{:set, :key, v}` effects.
- Action declared via `action(:name, args: %{...}, returns: %{...}, caps: [...], modes: [:call|:cast], description: "...")`.
- Dispatch: `Ezagent.Invocation.dispatch(%Invocation{target: URI "?action=turn.open", mode: :call,
  args: %{...}, ctx: %{caller, caps, reply}})`. In-handler downstream: `{:dispatch, %Ezagent.Cmd{}}`.
- Behavior wiring is TWO things, both required: list the Behavior in the Kind's `behaviors/0`
  (slice init) AND `Ezagent.CapabilityRegistry.register(KindModule, action, BehaviorModule)` per
  action in the app's `Application.start/2` (makes actions dispatchable).
- Tests: `use EzagentCore.DataCase`; per-domain `BehaviorInvoker` test helper for unit handler
  tests; `use Ezagent.LifecycleCase` + `assert_transients_rebuilt/2` for cold-restart; seed
  member Kinds via `Ezagent.Kind.spawn(KindModule, %{uri: ..., initial_caps: ...})`.
- **Codex companion review caveat:** the codex-companion runs in an isolated MIX_HOME with no
  deps — any Elixir review handed to codex MUST say "static only, skip mix/build/tests" or the
  round terminates with no findings.

## File structure (created across phases)

```
apps/ezagent_domain_socialware/
  mix.exs                                              # P1
  lib/ezagent_domain_socialware/application.ex         # P1 (registers behaviors)
  lib/ezagent/behavior/turn.ex                         # P1  Ezagent.Behavior.Turn (:turns slice)
  lib/ezagent/entity/socialware_session.ex             # P1  the session.socialware base Kind
  lib/ezagent/socialware/surface.ex                    # P2  :surface slice contract + helpers
  lib/ezagent/behavior/page_view.ex (or under domain_ui) # P2  operator HEEx PageView (SessionView)
  lib/ezagent/socialware/settlement.ex                 # P3  settlement record + outbox
  lib/ezagent/socialware/customer_feed.ex              # P3  the gated query + delivery topic
  lib/ezagent/socialware/customer_auth.ex              # P3/P4 session-binding token + scope check
  assets/ (React SPA, json-render registry, Sandpack)  # P4
  lib/ezagent/socialware/config_store.ex               # P6  immutable config objects + pointer
  test/support/behavior_invoker.ex                     # P1
  test/...                                             # per phase

apps/ezagent_core/   (the ONE core touch — P3 core-schema PR)
  lib/ezagent/message.ex                               # +visibility field
  lib/ezagent/message_store.ex                         # +filtered/visibility-aware read/write APIs
  priv/repo/migrations/<ts>_add_message_visibility.exs # migration (default :customer_visible)

apps/ezagent_plugin_<vertical>/                        # P5 first fused vertical (a plugin app)
```

---

## P1 — `Behavior.Turn` + `:turns` slice (the orchestration state machine)

**Goal:** a new `ezagent_domain_socialware` app with `Behavior.Turn` owning `:turns`, the full
state machine (open→delegating→aggregating→composing→[awaiting_human]→settled/cancelled), on a
`session.socialware` base Kind. No surface/visibility/feed yet (those are P2/P3) — `turn.settle`
in P1 just marks `:settled` (the page-pointer/visibility effects are layered in P2/P3).

**Files:** Create `apps/ezagent_domain_socialware/{mix.exs, lib/ezagent_domain_socialware/application.ex,
lib/ezagent/behavior/turn.ex, lib/ezagent/entity/socialware_session.ex, test/support/behavior_invoker.ex}`;
Test `apps/ezagent_domain_socialware/test/ezagent/behavior/turn_test.exs` + `.../test/integration/turn_survives_restart_test.exs`.

### Task P1.1: Scaffold the umbrella app
- [ ] Create `mix.exs` (model `apps/ezagent_domain_instance_message/mix.exs`): `app:
  :ezagent_domain_socialware`, umbrella build/config/deps paths, `mod:
  {EzagentDomainSocialware.Application, []}`, deps `{:ezagent_core, in_umbrella: true}` +
  `{:ezagent_domain_instance_message, in_umbrella: true}` (for the Session Kind / Chat) +
  `{:ezagent_domain_identity, in_umbrella: true}`, `elixirc_paths(:test) = ["lib","test/support"]`.
- [ ] Create `lib/ezagent_domain_socialware/application.ex` with `use Application`, a
  `DynamicSupervisor` child, and a `register_behaviors/0` that calls
  `Ezagent.CapabilityRegistry.register(Ezagent.Entity.SocialwareSession, action, Ezagent.Behavior.Turn)`
  for each Turn action (added as actions land).
- [ ] Run `cd /private/tmp/<worktree> && MIX_ENV=test mix compile` — expect clean compile of the new app.
- [ ] Commit: `feat(socialware): scaffold ezagent_domain_socialware app`.

### Task P1.2: `:turns` slice + `Behavior.Turn` create/activate (TDD)
**The slice record (per spec §4.1):**
```elixir
# turns: %{turn_id => %{trigger, owner, mode, expected (MapSet), collected (map),
#                       result (list), status, turn_no, opened_at}}
```
- [ ] **Failing test** (`turn_test.exs`, using a `EzagentDomainSocialware.Test.BehaviorInvoker`
  modeled on the instance_message one):
```elixir
test "create initializes an empty :turns slice" do
  assert {:ok, state} = Ezagent.Behavior.Turn.create(%{})
  assert state.turns == %{}
  assert state.turn_seq == 0
end
```
- [ ] Run it → FAIL (module/function missing).
- [ ] Implement `lib/ezagent/behavior/turn.ex`:
```elixir
defmodule Ezagent.Behavior.Turn do
  @moduledoc "Socialware orchestration state machine. Owns the :turns slice."
  # lifecycle:state_slice_override
  use Ezagent.Lifecycle, state_slice: :turns

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{turns: %{}, turn_seq: 0}}

  @impl Ezagent.Lifecycle
  def activate(_state, _ctx), do: {:ok, %{}}
end
```
- [ ] Run → PASS. Commit: `feat(socialware): Behavior.Turn :turns slice create/activate`.

### Task P1.3: `turn.open` (TDD)
- [ ] **Failing test:**
```elixir
test "turn.open creates an :open turn with a monotonic turn_no" do
  slice = %{turns: %{}, turn_seq: 0}
  ctx = invoker_ctx(caller: agent_uri())
  {:ok, slice2, %{turn_id: tid}, _eff} =
    Invoker.invoke_with_effects(Turn, :open, slice, %{trigger: msg_ref(), opened_at: 1}, ctx)
  t = slice2.turns[tid]
  assert t.status == :open and t.turn_no == 1 and t.owner == agent_uri()
end
```
- [ ] Run → FAIL.
- [ ] Implement: `action(:open, args: %{trigger: :map, opened_at: :integer}, returns: %{turn_id: :string},
  caps: [:open], modes: [:call])` + `handle_open(%{trigger: tr, opened_at: at}, ctx)` that mints a
  `turn_id` (e.g. `"#{session}#turn-#{seq+1}"`), builds the record (`status: :open, owner:
  ctx.caller, mode: :auto, expected: MapSet.new(), collected: %{}, result: [], turn_no: seq+1`),
  returns `{:ok, %{turn_id: tid}, [{:set, :turns, put}, {:set, :turn_seq, seq+1}]}`. (No
  `Date.now` — `opened_at` is passed in.) Register the action in `application.ex`.
- [ ] Run → PASS. Commit: `feat(socialware): turn.open`.

### Task P1.4: `turn.dispatch` (record expected + emit @mention chat.send) (TDD)
- [ ] **Failing test:** dispatch with `[%{id: :nl, mention: worker_a}, %{id: :page, mention: worker_b}]`
  → turn status `:delegating`, `expected == MapSet.new([:nl, :page])`, and **two `{:dispatch, %Cmd{}}`
  effects targeting `chat.send` with the worker mentions** (assert via `invoke_with_effects` effect list).
- [ ] Run → FAIL.
- [ ] Implement `action(:dispatch, args: %{subtasks: {:list, :map}}, ...)` +
  `handle_dispatch/2`: set `expected`, status `:delegating`, and for each subtask emit
  `{:dispatch, %Ezagent.Cmd{target: session_uri, action: :send, args: %{message: %Ezagent.Message{
  sender: orchestrator_uri, mentions: [subtask.mention], body: subtask.prompt, ...}}, ctx: ...}}`
  (Chat's existing `:send` fan-out + Resolver deliver `chat.receive` to each worker — do NOT
  re-implement fan-out). Correlate via a `ref_id`/subtask id stamped on the message (read
  `apps/ezagent_core/lib/ezagent/message.ex` for the exact correlation field; use `msg.id` keyed
  to subtask id in the turn's `collected` map).
- [ ] Run → PASS. Commit: `feat(socialware): turn.dispatch (record expected + @mention fan-out)`.

### Task P1.5: `turn.deliver` + auto-advance to `:composing` (TDD)
- [ ] **Failing tests:** (a) `deliver(:nl, card)` with `expected={:nl,:page}` → `collected[:nl]=card`,
  status `:aggregating`; (b) delivering the LAST expected subtask → status auto-advances to
  `:aggregating` (compose is a separate explicit action) and `collected` is complete; (c) a
  `deliver` for an unknown subtask id → `{:error, :unexpected_subtask}`.
- [ ] Run → FAIL.
- [ ] Implement `action(:deliver, args: %{subtask_id: :atom, card_ref: :map}, ...)` +
  `handle_deliver/2`: reject if `subtask_id ∉ expected`; put into `collected`; status `:aggregating`.
- [ ] Run → PASS. Commit: `feat(socialware): turn.deliver`.

### Task P1.6: `turn.compose` / `turn.settle` / `turn.cancel` + state-machine guards (TDD)
- [ ] **Failing tests:** (a) `compose` only legal from `:aggregating` (or `:open` for the
  degenerate zero-expected single-bot turn) → status `:composing`, `result` set; illegal-state
  compose → `{:error, {:illegal_transition, from}}`; (b) `settle` from `:composing` (mode `:auto`)
  → status `:settled`; (c) `cancel` from any non-terminal → `:cancelled`; (d) `settle`/`compose`
  on a `:settled` or `:cancelled` turn → `{:error, {:illegal_transition, _}}` (idempotency guard).
- [ ] Run → FAIL.
- [ ] Implement the three actions + a private `transition(from, to)` guard table matching spec
  §4.1. P1 `settle` only sets `:settled` (the surface-pointer + visibility-flip + outbox effects
  are layered in P2/P3 — leave a clearly-marked extension seam, not a stub that silently no-ops).
  The degenerate path (zero `expected`): `open → compose → settle`.
- [ ] Run → PASS. Commit: `feat(socialware): turn compose/settle/cancel + transition guards`.

### Task P1.7: `session.socialware` base Kind + restart survival (TDD)
- [ ] Create `lib/ezagent/entity/socialware_session.ex`: `@behaviour Ezagent.Kind`, `type_name,
  do: :session`, `behaviors, do: [Ezagent.Behavior.Chat, Ezagent.Behavior.Turn,
  Ezagent.Behavior.Publisher.SessionImpl]`, `persistence, do: {:snapshot, :on_change}`.
- [ ] **Failing cold-restart test** (`turn_survives_restart_test.exs`, `use Ezagent.LifecycleCase`):
  spawn a SocialwareSession, `turn.open` + `turn.dispatch` via `Invocation.dispatch`
  (`?action=turn.open`), kill the process, respawn, assert the `:turns` slice (the open turn +
  `expected`) is restored from snapshot, and `assert_transients_rebuilt/2` passes.
- [ ] Run → FAIL; implement registration in `application.ex` (`CapabilityRegistry.register` for
  every Turn action against `SocialwareSession`) + ensure the Kind composes Chat+Turn slices.
- [ ] Run → PASS. Commit: `feat(socialware): session.socialware base Kind + turn restart survival`.

**P1 acceptance gate:** `MIX_ENV=test mix test apps/ezagent_domain_socialware/test` green; the
state machine rejects every illegal transition; the degenerate single-bot turn works; a turn
survives cold restart (snapshot). No core-schema change yet.

**Dependencies:** none beyond `ezagent_core` + `ezagent_domain_instance_message` (Chat/Session).

---

## P2 — `:surface` slice + operator LiveView render

**Goal:** the page as **immutable versions + an `approved` pointer**, mutated by the turn, and a
thin **operator** HEEx render so backend E2E can run before the React SPA exists.

**Files:** Create `lib/ezagent/socialware/surface.ex` (slice contract + helpers), a `PageView`
(`@behaviour Ezagent.UI.SessionView`, registered in the liveview admin like `ConversationView`);
add `:surface` to the SocialwareSession; Test `surface_test.exs` + `page_view_test.exs`.

### Tasks (TDD)
- [ ] **P2.1 `:surface` slice shape** — add `:surface` as a Turn-owned (or a sibling Behavior)
  slice: `%{versions: %{}, approved: nil}`. Test: `create` → empty; `put_version(tree, turn_id)`
  appends an immutable version with a monotonic id and returns it; versions are never mutated.
- [ ] **P2.2 compose writes a version** — extend `turn.compose` so a page deliverable appends a
  `:surface` version (`{:set, :surface, ...}` via the surface helper) tagged `by_turn`. Test: a
  turn with a page card → a new `:surface` version exists, `approved` still `nil` (auto advances
  at settle in P3-wired form; in P2 wire auto-advance-at-settle directly).
- [ ] **P2.3 settle advances `approved` (auto)** — `turn.settle` sets `approved = this turn's
  version`. Test: after auto settle, `approved` points at the composed version; **operator read
  returns latest, customer-side read (helper) returns `versions[approved]`** (the read split,
  even though the customer feed proper lands in P3).
- [ ] **P2.4 operator `PageView`** — implement `@impl Ezagent.UI.SessionView` (`id: :page`,
  `applies_to?(session)` = "has a `:surface` slice", `render/1` = a recursive HEEx interpreter
  over `versions[latest]` using a small server-side component registry: a `text`/`container`/
  `table` node set is enough for the first vertical; the `code` node is deferred to P4 Sandpack).
  Register it in the liveview admin app's `Application.start/2` next to `ConversationView`. Test:
  `render/1` over a sample tree produces the expected HEEx; `applies_to?` true only with a
  `:surface` slice.

**P2 acceptance gate:** `:surface` versions are immutable + retained; `approved` recoverable
after a newer version (cold-restart test: render `versions[approved]`, not latest); operator
PageView renders latest. `mix test apps/ezagent_domain_socialware/test` green.

**Dependencies:** P1. Touches `ezagent_plugin_liveview` (register PageView) — domain-tier
`SessionView` contract is reused, no core change.

---

## P3 — core-schema PR: `Message.visibility` + visibility-gated customer feed + atomic settle

> **This is the ONE `ezagent_core` core-schema PR.** It is the only socialware phase touching
> core. Coordinate migration ordering with the #17 cascade work (different tables; both add
> `ezagent_core` migrations). This is also the privacy/consistency-critical phase — its invariant
> tests are the leak-safety gate.

**Files:** Modify `apps/ezagent_core/lib/ezagent/message.ex` (+`visibility` field),
`apps/ezagent_core/lib/ezagent/message_store.ex` (+visibility-aware write + a
`committed_customer_visible/2` query), add migration
`apps/ezagent_core/priv/repo/migrations/<ts>_add_message_visibility.exs`; Create
`apps/ezagent_domain_socialware/lib/ezagent/socialware/{settlement.ex, customer_feed.ex,
customer_auth.ex}`; Tests incl. `customer_leak_test.exs` (the CRITICAL regression),
`settle_crash_matrix_test.exs`, `customer_auth_test.exs`.

### Tasks (TDD — invariant tests verbatim)
- [ ] **P3.1 `Message.visibility` migration + field** — add `field :visibility, Ecto.Enum,
  values: [:customer_visible, :operator_only], default: :customer_visible` to `Ezagent.Message`;
  migration adds the column with default `:customer_visible` (so **legacy rows stay
  customer-visible** — backward compat). Test: an existing-style message defaults
  `:customer_visible`; `MessageStore.write` round-trips an `:operator_only` message.
- [ ] **P3.2 settlement record + `:committed`-last** — `Settlement` (keyed by `turn_id`) with a
  `status` set `:committed` only after the visibility flip(s) + the `:surface` pointer advance.
  `turn.settle` writes the settlement and (auto) commits. Test: a partial settle (visibility
  flipped, pointer NOT advanced — simulate a crash) leaves `status != :committed`.
- [ ] **P3.3 committed-gated customer read** — `CustomerFeed.snapshot(session, token)` returns a
  message ONLY when `visibility == :customer_visible AND its turn's settlement is :committed`;
  same gate for history. The page read returns `versions[approved]`. **Invariant test (HIGH-2 /
  crash matrix):**
```elixir
test "customer never sees chat without its page, or an uncommitted turn (crash matrix)" do
  # arrange a turn whose visibility flip committed but whose pointer write 'crashed' (settlement != :committed)
  assert CustomerFeed.snapshot(session, customer_token).messages == []
  assert CustomerFeed.snapshot(session, customer_token).page == nil  # or the prior committed version
  # now complete the settlement -> committed
  complete_settlement(turn_id)
  snap = CustomerFeed.snapshot(session, customer_token)
  assert snap.messages != [] and snap.page != nil  # both appear together, atomically
end
```
- [ ] **P3.4 operator-only never reaches the customer (CRITICAL regression)** —
```elixir
test "an :operator_only takeover-assist message never reaches the customer feed via ANY path" do
  send_operator_only_message(session, agent_uri(), "draft suggestion")
  # the customer feed gated query
  refute_any_message(CustomerFeed.snapshot(session, customer_token), "draft suggestion")
  refute_any_message(CustomerFeed.history(session, customer_token), "draft suggestion")
  # raw-feed denial: the customer route must NOT expose recent_in_session / session PubSub / Publisher / unfiltered ExternalMirror
  assert CustomerFeed.snapshot(session, customer_token) == filtered_only(session)
  # operator surface DOES see it (full Publisher stream)
  assert operator_sees?(session, "draft suggestion")
end
```
- [ ] **P3.5 transactional outbox** — on settle-commit, emit a customer-delivery signal carrying
  **message ids only** (a dedicated PubSub topic the customer feed subscribes to), AFTER the
  settlement commits; the feed **refetches via the gated query** before sending payloads. Test:
  no signal is emitted before `:committed`; the signal carries ids only; a refetch returns only
  committed-customer-visible rows.
- [ ] **P3.6 customer-feed authorization** — `CustomerAuth`: a session-binding token bound to one
  `session://` + `workspace://`; `authorize(token, session, workspace)` on EVERY feed request,
  BEFORE visibility-gating. **Denial tests (verbatim):**
```elixir
test "a token scoped to session A / workspace A is denied B and when expired" do
  assert {:error, :unauthorized} = CustomerFeed.snapshot(session_b, token_for_a())
  assert {:error, :unauthorized} = CustomerFeed.snapshot(session_a, token_for_other_workspace())
  assert {:error, :unauthorized} = CustomerFeed.snapshot(session_a, expired_token())
  assert {:ok, _} = CustomerFeed.snapshot(session_a, token_for_a())
end
```
- [ ] **P3.7 mode wiring** — `turn.claim(by: operator)` sets `owner`, `mode`, holds settle
  (`:awaiting_human`); agent messages while held are written `:operator_only`; on operator
  approve → settle flips the forwarded message to `:customer_visible` + advances the pointer +
  commits the settlement + fires the outbox. Tests: copilot (customer sees nothing until
  approve), takeover (operator-authored message is `:customer_visible`, agent draft stays
  `:operator_only`).

**P3 acceptance gate (the leak-safety gate):** all of P3.3–P3.7 green; **the operator-only
message never appears on the customer feed via any path (live, history, raw-feed)**; the crash
matrix shows no partial; cross-session/cross-workspace/expired tokens denied; backward-compat
migration (legacy rows customer-visible); `MIX_ENV=test mix test apps/ezagent_core/test` +
`apps/ezagent_domain_socialware/test` green; **migration-ordering checked vs #17**.

**Dependencies:** P1, P2. The core-schema change.

---

## P4 — customer frontend foundation (React + json-render SPA + the rich external-adapter)

**Goal:** the one-time React frontend foundation — the rich external-adapter member: a streaming
endpoint over the gated feed, a React SPA rendering json-render trees via a component registry,
Sandpack for the `code` node, external/anon auth. Ports loom #480's rendering half (NOT its
SSE-from-Publisher transport — read the gated feed instead).

### Tasks
- [ ] **P4.1 streaming endpoint** — a Phoenix endpoint/channel that authenticates the
  session-binding token (P3.6), then serves the gated snapshot/history + subscribes to the
  customer-delivery topic (refetch-on-signal). Test (Elixir): the endpoint rejects an
  unauthorized token; emits only committed-customer-visible content.
- [ ] **P4.2 React SPA + json-render runtime + component registry** — port loom's SPA shell;
  a `registry: {type -> ReactComponent}`; render a UI tree (`{type, props, children}`) recursively.
  Ship a base node set (text bubble, container, table). Test (JS): registry renders a sample tree;
  an unknown node type renders a safe fallback (no crash).
- [ ] **P4.3 Sandpack `code` node** — the `code` node renders in a Sandpack iframe sandbox. Test:
  a `code` node renders sandboxed; a declarative tree never invokes Sandpack.
- [ ] **P4.4 external/anon customer identity** — back the session-binding token with the chosen
  identity model (open decision §10.2 — default: a seeded user for the first E2E; anon model can
  follow). Test: token issuance + binding to (session, workspace).

**P4 acceptance gate:** the customer SPA renders chat + page from the gated feed over the
authenticated endpoint; unauthorized/cross-scope tokens are rejected at the endpoint; declarative
tier works without Sandpack; the `code` node is sandboxed. (Visual proof is part of SW-USE E2E.)

**Dependencies:** P3 (the gated feed + auth). This is the frontend workstream — its own
PR(s); the React/JS code lives in `apps/ezagent_domain_socialware/assets/` (+ a Phoenix endpoint
in the appropriate web app).

---

## P5 — first fused vertical + SW-USE E2E (the fusion + leak-safety, end-to-end)

**Goal:** a vertical plugin `apps/ezagent_plugin_<name>` (e.g. `ezagent_plugin_advisor`) that
declares the six slots, and the SW-USE E2E proving one turn drives both customer panes + takeover
+ leak-safety. **SW-DEV** (the zero-core authoring proof) rides here.

### Tasks
- [ ] **P5.1 vertical plugin scaffold** — `apps/ezagent_plugin_advisor/` with `Application.start/2`
  registering: a `session.advisor` SessionTemplate seed (compose Chat+Turn+surface; roster
  orchestrator/nl-worker/page-worker/operator; routing `{:from customer}→orchestrator`,
  `{:from orchestrator @worker}→worker`); AgentTemplate seeds (cc orchestrator + nl + page
  workers, config via #17 cascade); a node-type module; React components in `assets/`. **SW-DEV
  invariant test:** instantiating the template boots the session with **zero edits to
  `ezagent_core`/`ezagent_domain_socialware`**, both views mount, agents spawn + credential-materialize.
- [ ] **P5.2 SW-USE E2E (the fusion invariant)** — non-admin customer + operator; customer asks
  "compare your two plans + recommend". Assert (agent-browser, real ESR UI at
  `http://100.64.0.27:10042` operator + the customer SPA route):
  - ① a single settled turn → chat bubble AND ② live page **side-by-side in one customer
    viewport** (fails if only one updates, or if they're only separate tabs);
  - ③ a copilot turn: the draft shows on the **operator** surface but is **absent from the
    customer page** until the operator approves; the agent's `:operator_only` assist never reaches
    the customer;
  - multi-user/cold-restart: a second customer viewer sees the same `versions[approved]`; restart
    re-renders; no unapproved draft ever shown.
- [ ] **P5.3 E2E regression harness** — each distinct bug found earns a fast regression unit test
  before the fix (per ESR E2E standards). Fresh docker seed each run; production topology.

**P5 acceptance gate:** the SW-USE invariants pass with agent-browser screenshots (①②③ + restart
+ cross-scope denial); SW-DEV proves zero-core authoring. This is the architectural completion
gate for the interaction surface.

**Dependencies:** P1–P4.

---

## P6 — self-evolve (SW-UPD): immutable config + cascade pointer

**Goal:** the optimization loop — an optimizer agent proposes config-deltas, the operator
approves via the same turn gate, the approved delta becomes a **new immutable config object** the
agent's #17 high cascade layer **points at**; rollback = repoint. Consumes the #17 write path
(now merged on main).

### Tasks
- [ ] **P6.1 immutable config store** — `ConfigStore`: write a new immutable config object
  (content-addressed or versioned id), never mutate. Test: two writes → two distinct retained
  objects.
- [ ] **P6.2 cascade pointer** — the #17 high layer (user/workspace) holds a config-id pointer;
  materialize resolves through it. Test: repointing changes the resolved config on next spawn;
  the old object is still retained.
- [ ] **P6.3 optimizer turn + operator approval** — an optimization session: optimizer agent
  reads service-session traces (incl. operator takeover edits), emits a config-delta card; the
  optimizer turn holds `:awaiting_human`; operator approves → write new config object + repoint.
  Reuses the P1/P3 turn+approval machinery.
- [ ] **P6.4 SW-UPD invariant test:**
```elixir
test "config changes via the flow, is observable, and rollback (repoint) reverts it" do
  before = resolved_config(agent)
  approve_config_delta(opt_session, operator_token(), delta())   # writes new immutable object + repoints
  respawn(agent)
  assert resolved_config(agent) != before
  assert later_turn_shows_changed_behavior(agent)
  repoint_to_prior(agent)                                        # rollback
  respawn(agent)
  assert resolved_config(agent) == before                        # deterministic revert, survives restart
end
```

**P6 acceptance gate:** config changes via the flow + observable in a later turn; rollback =
repoint reverts deterministically (configs immutable + retained), surviving restart. `mix test`
green.

**Dependencies:** P1–P3 (turn+approval) + the #17 cascade (prerequisite, now merged).

---

## Cross-cutting (all phases)

- **TDD always:** Red → verify-fail → Green → verify-pass → Refactor → commit. No production code
  without a failing test first.
- **Test DB only** (`MIX_ENV=test`). NEVER `mix ecto.migrate` against dev/prod. NEVER touch
  running dev/prod docker.
- **ESR E2E standards** (P5): non-admin customer primary caller; operator-cap-grant is itself a
  step; fresh docker seed each run; production topology; agent-browser screenshots on the real
  ESR UI at `http://100.64.0.27:10042` (operator) + the customer SPA route (Tailscale IP, not
  localhost); every distinct E2E bug earns a fast regression test before the fix.
- **No silent defaults / shims / whitelists.** Let-it-crash; structural fixes.
- **Migration ordering:** P3's `Message` migration must not collide with the #17 cascade
  migrations — coordinate the sequence at PR time.

## Self-review (against spec rev8)

- §4.1 Turn → P1 (state machine), P3 (settle/claim mode wiring). ✓
- §4.2 :surface immutable versions + approved pointer → P2. ✓
- §4.3 visibility field + gated customer feed + external-adapter family → P3 (+ ExternalMirror
  optional visibility filter is a P3 sub-task if a customer-facing mirror is needed; otherwise
  the rich feed covers SW-USE). ✓
- §4.4 React + json-render SPA + auth → P4. ✓
- §7 self-evolve immutable config + pointer → P6. ✓
- §8 persistence (snapshot, committed-gated reads, restart) → P1/P2/P3 restart + crash tests. ✓
- §9 SW-DEV/USE/UPD acceptance → P5 (DEV+USE), P6 (UPD), with the leak/crash/auth invariants in
  P3. ✓
- §10 open decisions (transport, identity model, cap shape, config store location) → resolved as
  plan-time choices in P3/P4/P6 (not architecture blockers). ✓
- §12 #17 dependency → P6; migration-ordering coordination flagged in P3. ✓
