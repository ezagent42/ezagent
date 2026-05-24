# ExternalMirror Domain — session-data mirroring to plugin-supplied surfaces

**Status:** r3 (FINAL, supersedes r1 and r2). 2026-05-25.
**Tier:** new Domain app `apps/ezagent_domain_external_mirror/` + amendments to `apps/ezagent_domain_chat/` (Publisher behaviour on Session Kind).
**Trigger:** Allen 2026-05-24 (Feishu) — "请规划 ExternalMirror 的 Domain。注意 game 只是举例方便你理解这个场景, 具体 external 是什么形式 (game, chat, 等等) 由 plugin 来决定, 这个 domain 只负责 session 数据的同步, 具体数据被怎么使用 (网页、ws 通讯等) 应该是透明的". Plus the resolved three-layer mental model (publisher / adapter / binding) Allen articulated 2026-05-24 evening on Feishu.
**Predecessors (all merged on main):**
- `docs/superpowers/specs/2026-05-24-caps-data-ownership-v2.md` (PRs #306 + #307 + #308 + #309 + #310) — the `data_owner/1` framework r3's bind cap is structurally derived from. **`Ezagent.Behavior.Chat.data_owner/1` and `Ezagent.Entity.Session.owner/1` are live** (`apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:846` and `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex:290`). `Ezagent.Behavior.IdentityAdmin.invoke(:grant_cap, ...)` is the single grant entry-point with §5.2 enforcement (`apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:170-220`).
- `docs/superpowers/specs/2026-05-24-notification-architecture-v2.md` (PR-N1 landed; producer migrations PR-N2…N5 in flight). Defines the `Ezagent.SliceChange` primitive r3's Publisher layer sits on top of.
- SKILL P1 (plugin isolation north star); P3 (single source of truth); P9 (reads-what-data → tier); P11 (plugin external integration = Receiver Kind/Behavior on an existing scheme — **never PubSub.subscribe + external write**); P14 (dispatch is the only path between Kinds); P15 (caps narrow by default); P16 (single Kind spawn entry); P18 (no silent drops at user-facing surfaces); P22 (reliability primitives in core; plugin authors cannot bypass); P23 (declare-don't-call plugin contract).
- Existing one-off this Domain retires:
  - `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/behavior/feishu_outbound.ex` (311 LOC; the single-tenant `:notify_external` Behavior on Session)
  - `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/session_binding.ex` (130 LOC; `feishu_session_bindings` table)
  - `Ezagent.Behavior.Chat`'s `maybe_notify_external/3` opportunistic dispatch (`apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:699-720`)
**Companion:** `2026-05-24-external-mirror-domain.zh_cn.md` (Chinese mirror).

---

## 0a. r4 revision notes (what changed vs r3)

r3 was returned `needs-attention` by codex round-3 with 3 HIGH + 1 MEDIUM. Allen's autonomous-mode authorization applied; r4 fixes all four structurally:

1. **HIGH-1 fixed (bind self-deadlock).** r3 §8.2 had the `:bind` action body call `Ezagent.Kind.spawn(Worker)` synchronously, AND the Worker's `init_slice/1` immediately called `Publisher.subscribe_from(...)` (a `GenServer.call` against the same Session). Per existing runtime (`apps/ezagent_core/lib/ezagent/kind.ex` + `kind/server.ex`), `Kind.spawn/2 → DynamicSupervisor.start_child/2` waits for `Kind.Server.init/1` which calls `init_slice/1` synchronously — Session call-chain blocks on Worker init which calls back into Session = deadlock. r4 splits worker startup from worker subscription via `handle_continue`: Worker `init_slice/1` returns minimal state (just binding params, no subscription); Worker's `Kind.Server` then schedules `handle_continue(:subscribe_to_publisher, state)` which runs AFTER init returns; only there does it call `Publisher.subscribe_from`. The Session's `:bind` action body's `Kind.spawn/2` then only waits for the cheap init (no Publisher call); it returns immediately. The subscription happens asynchronously moments later. SliceChange events emitted in that gap are lost (acceptable per §3 latest-wins) — what's PREVENTED is the deadlock. See updated §3 + §8.2 + §6.1.

2. **HIGH-2 fixed (DynamicSupervisor restart intensity is supervisor-wide).** r3 had ONE `Ezagent.ExternalMirror.WorkerSupervisor` `DynamicSupervisor` with `max_restarts: 3, max_seconds: 30` and claimed per-binding isolation. OTP restart intensity is per-supervisor — 4 different bindings each crashing once within 30s cumulatively trips the supervisor and crashes ALL siblings. r4 introduces a **two-tier supervisor topology**: `Ezagent.ExternalMirror.RootSupervisor` (`:one_for_one`) supervises per-binding `PerBindingSupervisor` instances; each per-binding supervisor is itself a `:one_for_one` `Supervisor` that owns exactly ONE Worker child with restart intensity `max_restarts: 3, max_seconds: 30`. Now: a single broken binding's worker crashes → that binding's PerBindingSupervisor counts restarts; if it trips, only that PerBindingSupervisor crashes; the RootSupervisor's `:one_for_one` policy means siblings are untouched. RootSupervisor's own intensity is set very wide (`max_restarts: 100, max_seconds: 60`) since per-binding-supervisor crashes should be rare structural events not workload-driven. See updated §5.3 + new §6.3.

3. **HIGH-3 fixed (persisted bindings have no worker after rehydrate).** r3 had `Behavior.ExternalMirror.init_slice/1` rehydrate bindings from the `external_mirror_bindings` table on Session Kind init, BUT eager-spawn of workers only happened inside the `:bind` action body. After app restart or Session Kind restart, the slice rebuilds (bindings present) but workers don't exist → SliceChange events emitted but no subscriber → silent mirror loss. r4 adds a **reconciliation step** in two places: (a) `Behavior.ExternalMirror.init_slice/1` schedules a `handle_continue(:reconcile_workers, ...)` on the Session Kind that enumerates the rehydrated bindings and idempotently `Kind.spawn/2`s each worker (P16 idempotency guarantees no-op if worker already running); (b) at application start, `Ezagent.ExternalMirror.Application.start/2` (after AdapterRegistry + BindingRegistry are populated) runs `BootReconciler` which queries the `external_mirror_bindings` table directly + idempotently spawns any workers whose Session Kind isn't even hosted on this node yet (multi-node case). Both reconciliation paths are tested in PR-EM-3 acceptance. See new §3.1 + updated §9 PR-EM-3 acceptance test (e).

4. **MEDIUM fixed (`target_ownership_check` is plugin I/O inside Session GenServer with no timeout / no anti-recursion contract).** r3 had `:bind` call `adapter_module.target_ownership_check(...)` synchronously inside the Session GenServer with no timeout and no rule preventing the adapter from re-entering ezagent dispatch. r4: (a) the check runs in a `Task.Supervisor.async_nolink/3` from the `:bind` action body with a bounded timeout (default 5 seconds, adapter-overridable via `target_ownership_check_timeout/0` callback). Timeout → `{:error, :target_check_timeout}`. (b) The Adapter contract @moduledoc explicitly forbids `Ezagent.Invocation.dispatch/1` from inside `target_ownership_check/2` (lays down the rule; new invariant test in PR-EM-FINAL greps for `Ezagent.Invocation.dispatch` inside any adapter module's transitive deps). (c) Adapter contract @moduledoc clarification: `event_to_payload/1` is the pure no-I/O callback; `target_ownership_check/2` is the ONE bind-time-only adapter callback ALLOWED to make external API calls (Lark/Slack/etc need this to verify membership). The two callbacks are deliberately different in side-effect class.

The two-tier supervisor + handle_continue subscription + boot reconciler + bounded target check together preserve the three-layer mental model while closing the lifecycle defects.

---

## 0. r3 revision notes (what changed vs r2)

r2 was returned `needs-attention` by codex round-2 with 1 CRITICAL + 3 HIGH + 1 MEDIUM. Allen 2026-05-24 evening authorized the forced revisions plus committed to the three-layer mental model (publisher / adapter / binding) as the FINAL framing. r3 folds both:

1. **CRITICAL fixed (P11 escape was incomplete).** r2 had the right destination (per-binding worker Kind) but the Session Kind itself was still the PubSub subscriber — `handle_info({:slice_changed, ...}, ...)` clause that then dispatched out. That handler IS a `Phoenix.PubSub` consumer making routing decisions (which bindings to fan out to), even if the leaf is dispatch. Codex called out: "the SESSION Kind is acting as the broker — that is still a P11 anti-pattern, just one layer up". r3 fixes structurally by promoting Session to a **Publisher** (Allen's three-layer model): the Session Kind STORES its slice-change history; subscription is the binding **worker's** responsibility (each worker subscribes from cursor on its OWN init); the Session Kind never knows bindings exist. There is no PubSub subscriber + external write in any module — the worker subscribes to a structured Publisher stream (NOT raw PubSub), and the external write happens inside the worker Kind's `:invoke(:publish, ...)`.

2. **HIGH fixed (per-binding isolation was Task-based, not supervised GenServer).** r2 used `Task.Supervisor.start_child` at the dispatch site. That gives crash containment per-slice-change but each Task is a fresh process — no cursor, no backpressure, no 429 handling, no rate-limit-state-per-target. Allen's three-layer model puts **stateful per-binding GenServers** in the binding tier: one supervised GenServer per binding, owning its publish-loop, retry state, last-cursor, and external-system backpressure. r3 replaces the Task-per-slice-change pattern with a supervised Worker Kind (one process per binding, lifecycle = bind→eager-spawn / crash→restart / unbind→graceful exit).

3. **HIGH fixed (per-adapter cap was inline check; not structurally registered).** r2 declared two caps but the second (`{ExternalAdapter, adapter_id}`) was checked inside the `:bind` action body, not as a structural cap subject in `CapabilityRegistry`. r3 makes it structural: each adapter declares a `cap_subject/0` callback at plugin boot time, registered with `Ezagent.CapabilityRegistry`; the `:bind` action's §5.2 grant check naturally enforces it via `data_owner/1` on the adapter-cap Behavior (which is `:any` = workspace-admin grants). Additionally, r3 introduces a **per-target ownership callback** the adapter implements (`target_ownership_check(caller, target_id) :: :ok | {:error, _}`) that the Domain calls AT BIND TIME — Bob can't bind his session to the CEO's Lark chat_id even if Bob holds both bind caps, because the Lark side knows Bob isn't a member of that chat.

4. **HIGH fixed (Grill 5 — adapter↔binding decoupling structurally enforced).** r2 had `FeishuAdapter.publish/3` and the worker Kind in the same plugin; nothing prevented a plugin author from making them one module. Allen's resolution: option (a) — Domain forces them to be separate modules via the behaviour shape. r3's `Adapter` behaviour requires `binding_module/0` callback returning the matching `Binding` module; the `Binding` behaviour requires `adapter_module/0` returning back. Domain's plugin compiler check (`:ezagent_plugin_check`) rejects modules that implement BOTH behaviours.

5. **OQ-EM-10 resolved (worker lifecycle).** r2 left this open as "implementer decides". r3 commits to: **eager start on bind success / supervised restart on crash / latest-wins semantics on slice changes (no replay of missed events from crash period) / graceful exit on unbind**. The Publisher's structured cursor stream supports replay-from-cursor in principle, but V1 workers reset cursor to `:latest` on restart (operator can manually trigger replay if needed — see OQ-EM-A). Documented in §3.

6. **MEDIUM fixed (atomicity OQ-EM-8 was reasoned but not pinned).** r3 commits to **Session slice is the SoT + `BindingRegistry` ETS is a read-cache** (snapshot writer P22 handles durable persistence). No dual-SoT atomicity question because there is exactly one SoT.

Plus: r3 incorporates Allen's three-layer mental model as the SPEC's primary organizing principle (§2), not just as a footnote. The previous two-section r2 framing ("primitives" + "flow diagram") is replaced with a per-layer §2.1 / §2.2 / §2.3 walk-through.

---

## 1. Problem statement (what breaks today + the architectural insight)

### 1.1 The pain today (concrete: Feishu)

The Feishu plugin mirrors session messages to Lark chats through a one-off path. Four pieces, all plugin-specific:

1. **A side-join table** — `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/session_binding.ex` stores `chat_id ↔ session_uri` rows in the `feishu_session_bindings` SQLite table.
2. **A Session-Kind Behavior** — `apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/behavior/feishu_outbound.ex` registers `:notify_external` against `Ezagent.Entity.Session`. This is the only Behavior in the system that sends bytes to a non-ezagent surface from inside `:invoke`.
3. **An opportunistic dispatch in `Behavior.Chat`** — `apps/ezagent_domain_chat/lib/ezagent/behavior/chat.ex:699-720`'s `maybe_notify_external/3` looks up whether anyone registered `:notify_external` on the Session Kind and dispatches if so.
4. **A plugin-side admin LV** — `/plugins/feishu/bindings` for bind/unbind.

This works for Feishu, exactly once. It doesn't compose. The next plugin (Slack, Discord, a game event stream, a web-view mirror, a WS remote-control surface) faces four structural problems:

- **The `:notify_external` slot on Session Kind is single-tenant.** Only one plugin can register against it; a workspace running BOTH Feishu and Slack must pick one.
- **The "is a plugin registered?" check lives inside Chat Behavior code.** Any Behavior on any Kind that wants its slice changes mirrored out must hand-write the same opportunistic-dispatch dance. The pattern doesn't compose across Behaviors.
- **The contract between Chat and FeishuOutbound is "we both happen to know the action atom is `:notify_external`".** No formal interface; no list of registered surfaces; no per-binding cap; no per-binding lifecycle.
- **Each plugin re-implements its own admin LV, schema, mix tasks, data model.** No cross-plugin operator surface.

Plus a fifth that surfaces when thinking about the next adapter classes: **the mirror frame today is `%Ezagent.Message{}`** (the trigger is a chat send). If a plugin wants to mirror a non-chat slice change (an agent's `:idle → :running` state transition, a session's participant list growing, a working-copy fork happening, a PTY frame burst), there is no path — Chat's `maybe_notify_external/3` only fires on `:send`.

### 1.2 The architectural insight (Allen 2026-05-24 Feishu)

Three layers, separated by responsibility:

- **Publisher** — Session is a structured stream with history / cursor / replay. Sessions don't know who consumes; sessions just publish.
- **Adapter** — Stateless module that knows the wire format (Feishu API, Slack API, game server RPC, in-browser WS). Translates a publisher event into adapter-specific payload. No state, no transport, no backpressure.
- **Binding** — Stateful per-target GenServer that owns the publish loop to ONE target. Subscribes to its publisher from cursor, asks adapter to translate, owns the external transport call, handles 429s / retries / backpressure. One binding = one Lark chat / one Slack channel / one game room / one browser WebSocket. One binding crashing affects only that target.

The Domain owns layer wiring (Publisher behaviour + Binding GenServer skeleton + Adapter contract + cap shapes + invariant tests). Plugins ship one Adapter module + one Binding module per external surface they care about.

### 1.3 Why a Domain (not a plugin, not core)

Per **P9** (reads-what-data → tier):

- The Domain reads `%Ezagent.SliceChange{}` events from any Kind (PR #303 SliceChange primitive). It reads bindings stored as first-class data. It writes nothing external itself.
- A plugin reads its OWN external API (Feishu Open API, Slack Web API, game server's RPC). It is the only module that knows that API exists.
- `core` is wrong because Publisher / BindingRegistry / AdapterRegistry are shared by ≥2 downstream plugins — that is the definition of a Domain.

A Domain — `apps/ezagent_domain_external_mirror/` — owns:

- The `Ezagent.Behavior.Publisher` behaviour (defined here; **first implementer is `Ezagent.Entity.Session` in `apps/ezagent_domain_chat/`** per Allen's option (a)).
- The `Ezagent.Behavior.ExternalMirror` behaviour on Session Kind (`:bind` / `:unbind` / `:list_bindings`).
- The `Ezagent.Behavior.ExternalMirrorWorker` behaviour on the per-binding Worker Kind (`:publish`).
- The `Ezagent.ExternalMirror.AdapterRegistry` and `Ezagent.ExternalMirror.BindingRegistry` (ETS read-caches).
- The adapter / binding behaviour contracts (`Ezagent.ExternalMirror.Adapter`, `Ezagent.ExternalMirror.Binding`).
- The cap subjects (per-session bind cap; per-adapter allow cap) and the invariant tests gating the architectural promises.

Plugins shrink to TWO modules each: one `Adapter` (stateless wire-format translator) + one `Binding` (stateful per-target GenServer). Each module is the minimum required to participate.

### 1.4 Trust model

Same-VM plugins are trusted code (PR #303 round-5 disposition; Allen approved 2026-05-24). The Domain's caps and per-target checks are **user-level authorization** (which user may bind which session to which adapter to which target), NOT plugin-vs-plugin BEAM sandboxing. OS-level isolation (separate VMs) is the relevant boundary if a plugin is untrusted. Non-goal #3 covers this explicitly.

---

## 2. Three-layer mental model

### 2.1 Publisher — Session is a structured stream

A **Publisher** is any Kind that exposes a slice-change history with cursor + replay semantics. Defined as a new behaviour `Ezagent.Behavior.Publisher` in `apps/ezagent_domain_external_mirror/`. Per Allen's option (a), the first implementer lives in the publishing domain (`Ezagent.Entity.Session` in `apps/ezagent_domain_chat/`) — NOT in an external-mirror buffer that copies session events. Sessions ARE publishers.

```elixir
defmodule Ezagent.Behavior.Publisher do
  @moduledoc """
  A Kind that exposes a structured stream of its slice changes with
  history + cursor + replay semantics. Subscribers consume from a
  cursor (an opaque, monotonically increasing per-publisher value);
  the publisher retains a bounded window of recent events so a
  subscriber restarting can resume from a checkpoint.

  Implementing this behaviour on a Kind is HOW that Kind becomes
  mirrorable. The ExternalMirror Domain consumes Publishers; it
  does NOT directly observe raw SliceChange envelopes (that's an
  internal implementation detail of the Publisher).

  The Publisher behaviour is intentionally separated from raw
  Phoenix.PubSub: subscribers see a typed `%Ezagent.Publisher.Event{}`
  stream with cursor, not raw `:slice_changed` PubSub messages.
  This is what closes the P11 escape: every external-mirror worker
  subscribes via the Publisher API, not via PubSub.subscribe.
  """

  @type cursor :: non_neg_integer() | :latest | :earliest
  @type event :: Ezagent.Publisher.Event.t()

  @doc "How many events to retain in-memory (V1 default; see OQ-EM-A)."
  @callback history_retention() :: pos_integer()

  @doc """
  Subscribe `subscriber_pid` to this Publisher starting from `cursor`.
  - `:latest` = subscribe to future events only (skip backlog)
  - `:earliest` = replay entire retained history then continue
  - integer = resume from that exact cursor (raise if no longer retained)

  Returns `{:ok, current_cursor}` — the cursor pointing at the
  most-recent event delivered (subscribers checkpoint this).
  """
  @callback subscribe_from(publisher_uri :: URI.t(),
                           subscriber_pid :: pid(),
                           cursor :: cursor()) ::
              {:ok, cursor()} | {:error, term()}

  @doc "Snapshot current state without subscribing. Used by late-joining UI."
  @callback snapshot(publisher_uri :: URI.t()) ::
              {:ok, %{cursor: cursor(), state: term()}} | {:error, term()}

  @doc """
  History from cursor `from` (exclusive) to `to` (inclusive, or :latest).
  Used by subscribers checkpointing across restart. Raises if `from`
  is older than the retention window.
  """
  @callback history(publisher_uri :: URI.t(),
                    from :: cursor(),
                    to :: cursor()) ::
              {:ok, [event()]} | {:error, :cursor_out_of_window | term()}
end
```

Session Kind implements this by maintaining an `:publisher_history` slice (bounded ring; V1 default 100 events or 1 hour, see OQ-EM-A) and exposing `subscribe_from / snapshot / history` as Kind-level GenServer calls. The slice-change hook (PR #303 §2.1) appends to the ring on every successful invoke that mutated a slice — i.e. the Publisher is mechanically derived from the SliceChange primitive; Behavior authors don't write Publisher logic explicitly.

Why Publisher and not just "subscribe to SliceChange topic":
- **Cursor.** A binding restarting needs to know "from which point should I resume" — raw PubSub has no notion.
- **Replay.** Late-joining UI / catch-up after a network blip needs `history(from, to)`. PR #303's hook is fire-and-forget.
- **Backpressure boundary.** Per-subscriber pacing happens at the Publisher API; PubSub broadcasts to all subscribers unconditionally.
- **Subscribers don't import PubSub.** A binding implementer never writes `Phoenix.PubSub.subscribe`. The Publisher API is the structural boundary.

### 2.2 Adapter — stateless wire-format module

An **Adapter** is a plugin module that knows how to consume Publisher events and serialize them for ONE external system. Stateless: no GenServer, no ETS, no rate-limit state, no auth cache. The adapter is a pure-function module that the matching Binding GenServer calls.

```elixir
defmodule Ezagent.ExternalMirror.Adapter do
  @moduledoc """
  Behaviour for stateless wire-format translators. One adapter
  module per external system shape (Feishu, Slack, Discord, a game
  protocol, a browser-side WS dashboard, ...).

  An adapter does NOT call external APIs directly. It translates a
  Publisher event into adapter-specific payload (a Lark message
  body, a Slack chat.postMessage args map, a game-server RPC frame).
  The matching Binding GenServer calls the adapter, then performs
  the actual transport.

  The split (adapter = stateless translation, binding = stateful
  transport) is enforced structurally: Domain plugin compiler check
  rejects a module that implements both Adapter and Binding
  behaviours (Grill 5 — Allen 2026-05-24).
  """

  @doc "Stable string id for catalog (e.g. `\"feishu\"`)."
  @callback adapter_id() :: String.t()

  @doc "Human-readable name for admin LV / CmdK / docs."
  @callback display_name() :: String.t()

  @doc "One-sentence operator description for cap discovery + admin UI."
  @callback description() :: String.t()

  @doc """
  The per-adapter cap subject (Behavior module + description) that
  authorizes a user to bind to THIS adapter. Registered with
  CapabilityRegistry at plugin boot. The cap is the structural
  per-adapter authorization gate (HIGH #4 forced revision).

  The Behavior module convention is
  `Behavior.ExternalAdapter.<adapter_id>.Allow` (e.g.
  `Behavior.ExternalAdapter.Feishu.Allow`); the adapter declares
  the module so it can be referenced from cap matching code.
  """
  @callback cap_subject() :: %{behavior_module: module(), description: String.t()}

  @doc """
  Check at BIND TIME whether `caller` has access to `target_id` on
  the external system. Examples:
  - Feishu adapter checks "is `caller`'s linked feishu_open_id a
    member of the Lark chat `target_id`?" via the Lark API.
  - Slack adapter checks channel membership.
  - Game adapter checks if `caller`'s game-account owns the room.

  Returns `:ok` if `caller` may bind a session to `target_id`.
  `{:error, :not_a_member}` is the canonical denial atom; adapters
  may return other reasons that the Domain surfaces verbatim
  (per P18 — no silent drops on user-facing dispatch).

  This is the HIGH #4 second gate: Cap 1 says "you may bind on
  this session", Cap 2 says "you may use this adapter at all",
  target_ownership_check says "you actually own / are a member
  of this specific target on the external side".

  **CONTRACT (r4 — closes round-3 MEDIUM):**
  - This callback is the ONE adapter callback ALLOWED to make
    external API calls (Lark/Slack/etc) — the bind-time membership
    check is its purpose. By contrast, `event_to_payload/1` MUST
    be pure (no I/O).
  - This callback MUST NOT call `Ezagent.Invocation.dispatch/1`
    (directly or transitively). Enforced by PR-EM-FINAL grep gate
    invariant test (g). Re-entering ezagent dispatch from inside
    this callback creates dispatch-during-dispatch deadlock risk
    because `:bind` is itself a dispatched action.
  - Domain calls this callback inside a
    `Task.Supervisor.async_nolink/3` with a bounded timeout
    (default 5 seconds; adapter can override via
    `target_ownership_check_timeout/0` callback). Timeout returns
    `{:error, :target_check_timeout}` to the caller; the Session
    Kind GenServer stays responsive (it's just awaiting the task,
    not running adapter code synchronously).
  """
  @callback target_ownership_check(caller :: URI.t(),
                                    target_id :: term()) ::
              :ok | {:error, :not_a_member | :target_check_timeout | term()}

  @doc """
  Maximum time (ms) Domain waits for `target_ownership_check/2`
  to return before timing out. Default 5_000. Adapter authors
  override only if their external system genuinely requires a
  longer membership check.
  """
  @callback target_ownership_check_timeout() :: pos_integer()
  @optional_callbacks [target_ownership_check_timeout: 0]

  @doc """
  Translate a Publisher event into adapter-specific payload.
  Pure function — no I/O. The matching Binding consumes the
  returned term and performs the transport.

  Returning `:skip` tells the Binding to drop this event without
  publishing (e.g. an adapter that only cares about `:chat` slice
  changes returns `:skip` for `:members` slice changes).
  """
  @callback event_to_payload(event :: Ezagent.Publisher.Event.t()) ::
              {:publish, payload :: term()} | :skip

  @doc """
  Declare the matching Binding module for this adapter. Plugin
  compiler check enforces (Grill 5): adapter module and binding
  module MUST be different modules.
  """
  @callback binding_module() :: module()
end
```

Adapter examples (illustrative):
- `EzagentPluginFeishu.FeishuAdapter` — id `"feishu"`, `event_to_payload` translates `:chat` slice changes into Lark `im.v1.messages.create` JSON; returns `:skip` for non-chat slice changes.
- `EzagentPluginGameRoom.RoomEventAdapter` — id `"game_room"`, `event_to_payload` translates `:agent_state` slice changes into game-server RPC frames.

### 2.3 Binding — stateful per-target supervised GenServer

A **Binding** is a stateful GenServer instance — one per (session, adapter, target) triple — that owns the publish loop to ONE target. It subscribes to its publisher from cursor, calls its adapter for translation, performs the transport call, owns retry / backpressure / 429 handling. The crash boundary is per-binding: one Binding crashing doesn't affect siblings.

```elixir
defmodule Ezagent.ExternalMirror.Binding do
  @moduledoc """
  Behaviour for stateful per-target publish-loop modules. The
  Domain provides a GenServer skeleton (Ezagent.Entity.ExternalMirrorWorker
  Kind) that holds the publisher subscription + cursor + retry
  state; the binding module implements the transport callbacks.

  One Binding instance = one supervised process = one external
  target. Crash isolation is per-binding (HIGH #3 forced revision):
  one binding's crash never affects others on the same session.
  """

  @doc """
  Initialize per-binding transport state. Called once when the
  Worker Kind spawns. `target_id` is opaque to the framework
  (string, integer, map — whatever the adapter parses).
  `options` carries `bound_by` (entity URI), `bound_at` timestamp,
  and binding-time `metadata` from the `:bind` action args.

  Returns the binding's runtime state — held by the Worker Kind
  and threaded through publish/2 + terminate/2.
  """
  @callback init({target_id :: term(),
                  adapter :: module(),
                  options :: map()}) ::
              {:ok, state :: term()} | {:error, reason :: term()}

  @doc """
  Publish a translated payload to the external target. Called from
  inside the Worker Kind's `:invoke(:publish, ...)` (P14 — every
  external write happens inside a Kind's invoke).

  Returns `{:ok, new_state}` on success — state may carry rate-limit
  reset times, last-publish cursors, connection handles.
  Returns `{:error, reason, new_state}` on a recoverable failure
  (4xx/5xx, network blip) — the Worker Kind logs + telemetry'd but
  does NOT crash; the binding is structurally healthy. State
  carries forward (e.g. retry counter, backoff deadline).
  Raise on UNrecoverable invariant violations (the BEAM let-it-crash
  path) — the Worker Kind's DynamicSupervisor restarts it.

  THIS callback is where actual external bytes flow. The adapter
  has already translated the event; the binding is the transport.
  """
  @callback publish(payload :: term(), state :: term()) ::
              {:ok, new_state :: term()} | {:error, reason :: term(), new_state :: term()}

  @doc """
  Cleanup on graceful unbind. Adapter may release held resources
  (close WS pid, send goodbye message). Called BEFORE the Worker
  Kind process exits. No-op default.
  """
  @callback terminate(reason :: term(), state :: term()) :: :ok
  @optional_callbacks [terminate: 2]

  @doc "Declare the matching Adapter module (Grill 5 enforcement)."
  @callback adapter_module() :: module()
end
```

Binding examples (illustrative):
- `EzagentPluginFeishu.FeishuChatBinding` — one per `(session_uri, "feishu", chat_id)`; init opens the Feishu HTTP client + caches tenant token; publish posts the Lark message; handles 429s with backoff state stored in the binding's state.
- `EzagentPluginGameRoom.GameRoomBinding` — one per `(session_uri, "game_room", room_id)`; init opens a persistent gRPC stream to the game server; publish sends the RPC frame; reconnects on stream death.

### 2.4 The flow in one diagram

```
A Behavior on Session Kind invokes :send (or any action that mutates a slice).
                       ↓
Ezagent.Kind.Runtime.handle_dispatch/4 step 9 — new_state stored.
                       ↓
Ezagent.SliceChange.emit/1 fires (PR #303 §2.1) on the session URI's topic.
                       ↓
Session Kind's Publisher implementation (own GenServer logic) consumes
its own SliceChange — appends to :publisher_history ring with monotonic cursor.
                       ↓
Each subscribed binding worker (subscribed via Publisher.subscribe_from/3
at its own init/1 time) receives a {:publisher_event, %Event{}} message.
                       ↓
Worker Kind's handle_info translates to a dispatched :publish Invocation
to ITSELF (entity://worker/<workspace>/em_<binding_hash>?action=external_mirror_worker.publish).
                       ↓
ExternalMirrorWorker Kind's Behavior.invoke(:publish, ...) calls:
    1. adapter_module.event_to_payload(event) → {:publish, payload} | :skip
    2. if :skip → return
    3. binding_module.publish(payload, binding_state)
    4. update binding state; record cursor checkpoint
                       ↓
Binding does the actual transport (HTTP/WS/RPC/whatever) inside publish/2.
On crash → DynamicSupervisor restart → init/1 → subscribe_from latest cursor.
```

Why this diagram closes the P11 escape r2 couldn't:
- The only PubSub subscriber is the **Session Kind subscribing to ITS OWN topic** — this is the "Kind observing its own slice" pattern PR #303 already established. Not an external integration; trivially compliant.
- The bindings subscribe via the **Publisher API**, not via `Phoenix.PubSub.subscribe`. Even though Publisher is implemented over PubSub internally, the binding code imports `Ezagent.Behavior.Publisher`, not `Phoenix.PubSub`. The grep gate (Invariant 4) enforces.
- The external write happens inside the **Worker Kind's `:invoke(:publish, ...)`** — a Kind dispatched-to via `Invocation.dispatch/1`. P14 + P11 fully satisfied.

---

## 3. Worker lifecycle (resolves OQ-EM-10; r4 closes HIGH-1 deadlock)

Per Allen 2026-05-24 evening, the worker lifecycle is committed (no longer an OQ):

- **Eager start on bind success (r4: split init from subscribe).** When `:bind` action body succeeds (caps OK + adapter `target_ownership_check` OK + slice written), the Session Kind dispatches `Ezagent.Kind.spawn(Ezagent.Entity.ExternalMirrorWorker, ...)` for the new binding's worker URI. **The Worker's `init_slice/1` returns minimal state (binding params; NO subscription, NO transport open).** Subscription to the Session Publisher and binding-module `init/1` (transport open) happen in `handle_continue(:subscribe_and_init, ...)` which runs AFTER `init_slice/1` returns — this is the HIGH-1 deadlock fix per §6.1. The worker process EXISTS by the time `:bind` returns; it becomes ACTIVELY-SUBSCRIBED moments later (typically <1ms). SliceChange events emitted in that subscription gap are not delivered (latest-wins; acceptable per §3 last bullet).
- **Two-tier supervisor restart on crash (r4: per-binding isolation).** Workers live under a **per-binding** `:one_for_one` `Supervisor` (one supervisor per binding, containing one Worker child) called `Ezagent.ExternalMirror.PerBindingSupervisor`; the per-binding supervisors are all under a top-level `:one_for_one` `DynamicSupervisor` called `Ezagent.ExternalMirror.RootSupervisor`. Restart policies:
  - **Worker child** inside each PerBindingSupervisor: `:permanent`, `max_restarts: 3, max_seconds: 30`. Trip → PerBindingSupervisor crashes.
  - **PerBindingSupervisor** under RootSupervisor: `:permanent`, but RootSupervisor's intensity is set wide (`max_restarts: 100, max_seconds: 60`) because per-binding-supervisor crashes should be rare. A single binding's restart storm trips ONLY its own per-binding supervisor; siblings are untouched.
  This is the HIGH-2 fix per §5.3 + §6.3 — restart intensity is structurally per-binding, not supervisor-wide.
- **Latest-wins semantics on slice changes (no replay of missed events from crash period).** On restart, the worker re-subscribes to its Publisher with cursor `:latest` (via the same handle_continue path). Events emitted during the crash window are NOT replayed. Rationale: V1 adapters are fire-and-forget (chat messages, dashboard updates) — replaying a 5-second-old slice change usually does more harm than good (out-of-order publishes, duplicate notifications). Adapters that genuinely need at-least-once delivery can resume from a checkpointed cursor stored in their `:state` slice — Publisher exposes `subscribe_from(cursor)`. See OQ-EM-7.
- **Binding delete → worker graceful exit.** `:unbind` action body removes the binding from the Session slice AND tells RootSupervisor to terminate the PerBindingSupervisor (`DynamicSupervisor.terminate_child/2`). PerBindingSupervisor's shutdown propagates `:shutdown` to its Worker child; the Worker's `terminate/2` callback runs (calls binding module's `terminate/2` to release transport resources); the Worker Kind exits cleanly. **PR-EM-2 codex round-1 CRIT fix (2026-05-25):** the PerBindingSupervisor child under RootSupervisor is `:permanent` (NOT `:transient` as the earlier r5 wording wrongly said — `:transient` does NOT restart on `:shutdown`, which is the exit reason on inner-budget exhaustion, so the documented "RootSupervisor restarts the PerBindingSupervisor" loop never fires). `DynamicSupervisor.terminate_child/2` bypasses the restart strategy entirely (it removes the child from sup bookkeeping BEFORE propagating shutdown), so explicit unbind doesn't respawn even with `:permanent`.

There is intentionally NO auto-disable / circuit-breaker / health-check sweep. A binding that consistently fails (`{:error, _, new_state}` on every publish) keeps consuming events; the next slice change dispatches a fresh `:publish`; the binding's state accumulates retry counters; operator sees telemetry alerts and unbinds. This is P2 (let-it-crash; no workarounds) at the binding layer — the system surfaces failure rather than hiding it.

The only deferred decision is OQ-EM-7 (delivery semantics — at-most-once V1; cursor-based at-least-once when an adapter needs it). Cursor support is built into the Publisher API today; the worker's "subscribe from :latest on restart" is a policy choice that can change per-adapter without API churn.

### 3.1 Rehydration of persisted bindings (r4 — closes HIGH-3)

Bindings are persisted in the `external_mirror_bindings` table (per §7.1, written via standard P22 snapshot writer). After Session Kind restart OR application restart, bindings rebuild in the Session slice via `init_slice/1` — but per HIGH-3, eager-spawn only happens inside `:bind` action body. Without explicit reconciliation, rehydrated bindings have no worker → silent mirror loss.

r4 reconciliation runs at TWO trigger points:

1. **Session Kind init reconciliation.** `Behavior.ExternalMirror.init_slice/1` reads `external_mirror_bindings` for this session URI (existing behavior — populates the slice). Additionally it schedules `handle_continue({:reconcile_external_mirror_workers, bindings}, ...)` on the Session Kind GenServer. The continuation enumerates the bindings; for each one, idempotently calls `Ezagent.Kind.spawn(Ezagent.Entity.ExternalMirrorWorker, %{uri: worker_uri_for(...), session_uri: self_uri, binding: binding})`. Per **P16** (single Kind spawn entry), `Kind.spawn/2` is idempotent — if the worker is already running, it's a no-op; if not, it spawns + the per-binding supervisor wires up. Subscription happens via §3 handle_continue path AFTER spawn returns. This covers Session Kind restart.

2. **Application boot reconciliation.** `Ezagent.ExternalMirror.Application.start/2` starts a one-shot `Ezagent.ExternalMirror.BootReconciler` GenServer (under RootSupervisor, ordered AFTER AdapterRegistry + BindingRegistry have been populated by plugin boot per P23). BootReconciler queries `external_mirror_bindings` table directly (scoped to the local node's workspace shard if multi-node — V1 single-node so a simple full-table read). For each binding row: idempotently `Ezagent.Kind.spawn(Ezagent.Entity.Session, %{uri: session_uri})` (ensure Session Kind exists; idempotent) THEN `Kind.spawn(ExternalMirrorWorker, ...)` (ensure worker exists). The Session-init reconciliation (trigger 1) handles the common case where the Session Kind is the trigger for rebuild; BootReconciler handles the multi-node case where a binding row exists for a session not hosted on this node yet (deferred — V1 is single-node so this is a no-op safety net). BootReconciler exits cleanly after one pass.

Idempotency rules:
- `Kind.spawn/2` is idempotent: existing → return `{:ok, existing_pid}`; new → spawn under appropriate supervisor.
- The Worker's `handle_continue(:subscribe_and_init, ...)` is idempotent: if already subscribed to Publisher, no-op (Publisher's `subscribe_from` short-circuits on duplicate pid+publisher pairs — implementation detail of PR-EM-0).
- **Idempotency** (r5 codex round-4 HIGH-3 fix): `DynamicSupervisor` does NOT enforce uniqueness via child id; the child spec id is opaque to the supervisor's start logic. The PerBindingSupervisor's child spec uses a `Registry`-backed Via name: `name: {:via, Registry, {Ezagent.ExternalMirror.WorkerRegistry, binding_uri}}` where `WorkerRegistry` is a `:unique` `Registry` started at app boot. Duplicate `start_child/2` attempts hit the Registry-enforced name collision → return `{:error, {:already_started, pid}}` which the reconciler (§3.1) treats as success. `binding_uri` is the full Worker Kind URI `entity://worker/<ws>/em_<hash>` so cross-workspace bindings cannot collide.

Acceptance test in PR-EM-3 (e): bind a Feishu mirror → trigger a chat → assert mirror received; kill the Session Kind process → wait for restart → trigger another chat → assert mirror received WITHOUT manually re-binding. This is the test that fails if reconciliation isn't wired.

---

## 4. Public API — Domain side

### 4.1 The bind/unbind Behavior — `Ezagent.Behavior.ExternalMirror`

Registered against `Ezagent.Entity.Session` (V1; OQ-EM-1 covers extending to other Kinds). Three actions:

| Action | Purpose | Mode |
|---|---|---|
| `:bind` | Add a `(adapter_id, target_id, metadata)` binding to this session | `:call` |
| `:unbind` | Remove a binding by `(adapter_id, target_id)` | `:call` |
| `:list_bindings` | Read all bindings on this session | `:call` |

**Slice** — `:external_mirror` on Session. Shape:

```elixir
%{
  bindings: [
    %{
      binding_id:  "feishu/oc_xxx",          # synthetic, "<adapter_id>/<target_id>"
      adapter_id:  "feishu",
      target_id:   "oc_xxx",
      metadata:    %{},
      bound_by:    %URI{},                    # caller URI
      bound_at:    ~U[...]
    },
    ...
  ]
}
```

Per **P3** (single source of truth), this slice IS the bindings SoT for this session. `BindingRegistry` ETS table (§7) is a read-cache for cross-session queries ("which sessions are bound to chat oc_xxx?") that the slice can't answer without scanning every session.

**cap_subjects** (per CapabilityRegistry SPEC #264 + caps-data-ownership SPEC):

```elixir
def cap_subjects do
  [
    {:bind,         "Bind this session's slice changes to an external adapter target."},
    {:unbind,       "Remove an (adapter_id, target_id) binding from this session."},
    {:list_bindings, "List all external-mirror bindings on this session."}
  ]
end
```

**data_owner/1** (per caps-data-ownership-v2 §3.3):

```elixir
def data_owner(%URI{scheme: "session"} = session_uri) do
  # An external-mirror binding on a session is owned by the session's owner.
  # Session.owner/1 was added by PR-OWN-2 (caps-data-ownership #308).
  case Ezagent.Entity.Session.owner(session_uri) do
    {:ok, owner_uri} -> owner_uri
    :error           -> :no_owner    # mid-spawn race; only bootstrap-admin can grant
  end
end
def data_owner(:any), do: :no_owner   # class-wide ExternalMirror caps are bootstrap-only
def data_owner({:within_session, s_uri}), do: {:scope, :within_session, s_uri}
def data_owner(_), do: :no_owner
```

Effect: the user who created session S is the only principal who can grant `Behavior.ExternalMirror` caps on S to others; non-owners attempting to bind on a session they don't own get `:grant_not_owner` from `Behavior.IdentityAdmin.invoke(:grant_cap, ...)` step 5.2 (caps-data-ownership §5.2).

**Default grant** (per caps-data-ownership §4.1, mechanically derived from `data_owner/1`): when a session spawns, the session's owner automatically receives `%Capability{kind: :session, behavior: Ezagent.Behavior.ExternalMirror, instance: session_uri, workspace_uri: ws}`. No bind cap setup ceremony for the session creator.

### 4.2 §5.2 enforcement walkthrough — bind is gated by THREE checks

`Behavior.ExternalMirror.invoke(:bind, slice, args, ctx)` runs these in order. Cap 1 is enforced by standard CapBAC step 5.5 (`Ezagent.Kind.Runtime.handle_dispatch/4`); Cap 2 and the target-ownership-check are inside the action body.

**Check 1 — session-level bind cap (CapBAC step 5.5; pre-action).** Caller must hold `%Capability{kind: :session, behavior: Ezagent.Behavior.ExternalMirror, instance: session_uri, workspace_uri: ws}`. By caps-data-ownership §4, the session owner holds this by default. Failure → `{:error, :unauthorized}` (standard dispatch denial).

**Check 2 — per-adapter allow cap (inside action body; HIGH #4 fix).** Caller must hold `%Capability{kind: :session, behavior: <adapter.cap_subject().behavior_module>, instance: session_uri, workspace_uri: ws}`. Each adapter declares its own cap-subject Behavior module (e.g. `Behavior.ExternalAdapter.Feishu.Allow`); the Domain registers it at plugin boot via `CapabilityRegistry.register(...)`. Default grant: the workspace admin grants per-adapter caps to users opting in to that adapter (`data_owner` for these caps is `:any` → workspace-admin grants per caps-data-ownership §3.3). Failure → `{:error, :adapter_not_authorized}` (distinct atom for log legibility, per P18 + caps-data-ownership §5.2 error code style).

**Check 3 — adapter target_ownership_check (inside action body).** Domain calls `adapter_module.target_ownership_check(ctx.caller, args.target_id)`. The adapter's plugin code checks "is `caller` actually a member of / authorized on this specific external target?" — e.g. Feishu adapter queries Lark API "is `caller`'s linked feishu_open_id in chat `target_id`?". Failure → `{:error, reason}` where `reason` is whatever the adapter returned (typically `:not_a_member`). Surfaced verbatim to caller per P18.

Only after all three checks pass does the Behavior write the binding to the slice + dispatch `Ezagent.Kind.spawn(Worker)`.

### 4.3 The Worker Behavior — `Ezagent.Behavior.ExternalMirrorWorker`

Registered against the new `Ezagent.Entity.ExternalMirrorWorker` Kind (§7.2). One action:

| Action | Purpose | Mode |
|---|---|---|
| `:publish` | Translate a Publisher event via the adapter; transport via the binding module | `:cast` |

**Slice** — `:state` on Worker. Shape:

```elixir
%{
  binding: %{
    session_uri:     %URI{},
    adapter_id:      "feishu",
    target_id:       "oc_xxx",
    metadata:        %{},
    bound_by:        %URI{},
    bound_at:        ~U[...]
  },
  publisher_cursor:   non_neg_integer() | :latest,
  binding_state:      term(),                   # opaque to Domain; Binding owns
  last_publish_at:    DateTime.t() | nil,
  last_publish_result: :ok | {:error, term()} | nil,
  publish_count:      non_neg_integer(),
  error_count:        non_neg_integer()
}
```

Per **P3**, this slice is the worker's runtime SoT; snapshot persisted via standard P22 machinery for restart restoration of the cursor checkpoint. The binding's own state (`binding_state`) is opaque to the Domain — the binding module reads it back in `publish/2`.

**data_owner/1**: `:no_owner` — workers are framework-internal; only bootstrap admin can grant. Users never hold worker caps directly.

**Cap requirement**: the worker dispatch needs `%Capability{kind: :external_mirror_worker, behavior: Ezagent.Behavior.ExternalMirrorWorker, instance: :any, workspace_uri: worker_workspace}`. Held only by the binding-spawning Session Kind via scope-bounded delegation `{:within_session, session_uri}` (per P15 narrow-by-default — see §7.3).

### 4.4 The Domain facade

Read-side helpers for LV / CLI / admin tooling:

```elixir
defmodule Ezagent.ExternalMirror do
  @doc "List bindings on `session_uri`. Reads the slice (live SoT)."
  @spec list_bindings(URI.t()) :: {:ok, [binding()]} | {:error, term()}

  @doc "List sessions with at least one binding for `adapter_id`. Reads BindingRegistry cache."
  @spec sessions_for_adapter(String.t()) :: {:ok, [URI.t()]}

  @doc "List all registered adapters (for picker / cap discovery)."
  @spec list_adapters() :: [%{id: String.t(), display_name: String.t(), description: String.t()}]
end
```

Mutations go through `:bind` / `:unbind` dispatch (P14). The facade is reads-only.

---

## 5. Adapter contract (`Ezagent.ExternalMirror.Adapter`)

§2.2 defined the behaviour callbacks; §5 lays out the wiring + plugin contract details.

### 5.1 Plugin declaration (declare-don't-call, per P23)

A plugin's `Application` module declares adapter + binding pairs:

```elixir
defmodule EzagentPluginFeishu.Application do
  use Application
  use Ezagent.Plugin

  @impl Ezagent.Plugin
  def adapters do
    [{EzagentPluginFeishu.FeishuAdapter, EzagentPluginFeishu.FeishuChatBinding}]
  end

  # ... other plugin callbacks (behaviors/0, kinds/0, etc.)
end
```

The framework's `Ezagent.Plugin.boot/1` reads `adapters/0` and for each pair:

1. Verifies the adapter module implements `@behaviour Ezagent.ExternalMirror.Adapter`.
2. Verifies the binding module implements `@behaviour Ezagent.ExternalMirror.Binding`.
3. Verifies `adapter.binding_module() == binding_module` AND `binding.adapter_module() == adapter` (Grill 5 — bidirectional declaration).
4. Verifies adapter and binding are DIFFERENT modules (Grill 5 enforcement; structural — `assert adapter != binding`).
5. Calls `Ezagent.ExternalMirror.AdapterRegistry.register(adapter)`.
6. Calls `Ezagent.ExternalMirror.BindingRegistry.register_module(adapter.adapter_id(), binding)`.
7. Calls `Ezagent.CapabilityRegistry.register(...)` for the per-adapter cap subject returned from `adapter.cap_subject()`.

The `:ezagent_plugin_check` Mix compiler enforces (1)-(4) at compile time so a malformed declaration fails the build, not the runtime. (5)-(7) happen at application boot.

### 5.2 AdapterRegistry + BindingRegistry — both are read-only caches

Two ETS tables, owned by `EzagentCore.EtsOwner` (extend the existing `@tables` list; **NOT** lazy-init, per the structural-illegality enforcement of `EzagentCore.EtsOwner`):

- `Ezagent.ExternalMirror.AdapterRegistry` — key `adapter_id` (string), value `adapter_module`. Single source of truth for "which adapters exist". Populated at plugin boot from `adapters/0`. `lookup!/1` raises on missing adapter (binding referenced a not-loaded adapter — structural error, fail loud).
- `Ezagent.ExternalMirror.BindingRegistry` — key `{adapter_id, target_id}`, value `[session_uri]`. Read-cache for cross-session reverse lookups (e.g. "which sessions are bound to Lark chat oc_xxx?"). Populated incrementally as `:bind` / `:unbind` run; rebuilt on application start by reading the Session-slice projection table (§7.1).

Per **P22** (reliability primitives in core/Domain — plugin authors cannot bypass), both registries live in the Domain. Plugin authors call the AdapterRegistry / BindingRegistry NEVER directly — they declare via `adapters/0` and the framework wires them.

### 5.3 Failure semantics (per-binding crash isolation; HIGH #3 r2 + r4 HIGH-2 two-tier fix)

Per **P2** + Allen's "per-binding isolation" answer to OQ-EM-5 + r4's HIGH-2 two-tier supervisor fix:

The structural isolation is the **per-binding Worker Kind process under its own PerBindingSupervisor** (NOT a shared DynamicSupervisor with workers as direct children — that's what r3 had and codex round-3 HIGH-2 flagged). Two-tier supervisor topology:

- **`Ezagent.ExternalMirror.RootSupervisor`** (`DynamicSupervisor`, `:one_for_one`, `max_restarts: 100, max_seconds: 60`) — children are `PerBindingSupervisor` instances. Wide intensity since per-binding-supervisor crashes are rare structural events.
- **`Ezagent.ExternalMirror.PerBindingSupervisor`** (`Supervisor`, `:one_for_one`, `max_restarts: 3, max_seconds: 30`) — child is ONE Worker (an `Ezagent.Entity.ExternalMirrorWorker` Kind process). Tight intensity isolates restart pressure per-binding.

Failure cases:

1. **`binding_module.publish/2` returns `{:error, reason, new_state}`** — recoverable (4xx/5xx/transient). Worker logs + telemetry'd; state updates; next event triggers fresh publish. Binding NOT tombstoned. Operator sees telemetry trend.
2. **`binding_module.publish/2` raises** — UNrecoverable (invariant violation). Worker process crashes; DynamicSupervisor restarts (max 3 restarts in 30s). On restart, `init/2` re-subscribes to Publisher with cursor `:latest` (per §3 lifecycle). State rebuilt from snapshot if available.
3. **`adapter_module.event_to_payload/1` raises** — same as (2); worker crashes; restart; latest-wins. The adapter is supposed to be a pure function — a raise is a plugin bug; the let-it-crash surfaces it.
4. **Restart storm trips THIS binding's PerBindingSupervisor intensity** — ONLY that PerBindingSupervisor crashes; RootSupervisor's `:one_for_one` policy means siblings are completely untouched. Their PerBindingSupervisor + Worker keep running. Telemetry alerts operator about the crashed binding; operator unbinds to recover. (r4 fix: r3 had this on a shared supervisor, so cumulative restart pressure across bindings would crash siblings; that's structurally fixed by the two-tier topology.)

NOT auto-disable. NOT circuit breaker. NOT health-check sweep. Per P2: structural fix (per-binding process boundary + per-binding supervisor) over symptomatic patches.

The per-binding GenServer pattern differs from "pure let-it-crash on the Session Kind" because the failure mode here is **external system 4xx/5xx**, not BEAM invariant violations. A let-it-crash on every 429 from Lark would crash-loop the Session Kind. The supervised GenServer absorbs recoverable external failures in state; truly broken bindings still crash + restart + ultimately trip their per-binding supervisor intensity (the let-it-crash backstop, now properly isolated per r4).

### 5.4 Discovery — how an LV shows "available adapters"

The admin LV (OQ-EM-2 — CLI in PR-EM-5, LV in PR-EM-FINAL) calls `Ezagent.ExternalMirror.list_adapters/0`, which returns `[%{id, display_name, description}]` from AdapterRegistry. The LV filters by which per-adapter allow caps the caller holds (via `Behavior.Identity.invoke(:list_caps, ...)` against the caller's URI), hiding adapters the caller cannot bind to (per P15 narrow-by-default, avoids TOCTOU at submit time).

Per **P1** (plugin-isolation north star): a future plugin author adds Slack mirroring by writing TWO modules (`EzagentPluginSlack.SlackAdapter` + `EzagentPluginSlack.SlackChannelBinding`), declaring them in `adapters/0`, and shipping. No core touch, no domain touch, no LV touch.

---

## 6. Binding contract (`Ezagent.ExternalMirror.Binding`)

§2.3 defined the behaviour callbacks; §6 lays out the GenServer skeleton + per-binding state lifecycle.

### 6.1 Worker Kind owns the GenServer; Binding implements callbacks

`Ezagent.Entity.ExternalMirrorWorker` is a Kind (per P16 — spawned via `Ezagent.Kind.spawn/2` only). Its `init/1` calls the binding module's `init/1`; subsequent dispatched `:publish` actions thread state through `publish/2`; on `Kind.Server` terminate, the binding's `terminate/2` runs.

The Worker Kind's `:invoke(:publish, ...)` body:

```elixir
@impl Ezagent.Behavior
def invoke(:publish, %{event: event} = _args, slice, _ctx) do
  adapter = AdapterRegistry.lookup!(slice.binding.adapter_id)

  case adapter.event_to_payload(event) do
    :skip ->
      {:ok, %{result: :skipped},
       %{slice |
         publisher_cursor: event.cursor,
         publish_count: slice.publish_count + 1}}

    {:publish, payload} ->
      binding_module = BindingRegistry.lookup_module!(slice.binding.adapter_id)

      case binding_module.publish(payload, slice.binding_state) do
        {:ok, new_binding_state} ->
          {:ok, %{result: :ok},
           %{slice |
             binding_state: new_binding_state,
             publisher_cursor: event.cursor,
             last_publish_at: DateTime.utc_now(),
             last_publish_result: :ok,
             publish_count: slice.publish_count + 1}}

        {:error, reason, new_binding_state} ->
          # Recoverable: log + telemetry; do NOT crash.
          Logger.warning("ExternalMirror publish failed",
            binding: slice.binding.binding_id,
            reason: reason
          )
          {:ok, %{result: :error},
           %{slice |
             binding_state: new_binding_state,
             publisher_cursor: event.cursor,
             last_publish_at: DateTime.utc_now(),
             last_publish_result: {:error, reason},
             publish_count: slice.publish_count + 1,
             error_count: slice.error_count + 1}}
      end
  end
end
```

The Worker Kind subscribes to the Session's Publisher AND calls the binding module's `init/1` (transport open) in a **`handle_continue/2` callback that runs AFTER `init_slice/1` returns** — this is the r4 HIGH-1 deadlock fix. The Worker's `init_slice/1` returns minimal state with `subscription_state: :pending` and no transport open; the Worker Kind's `Kind.Server` then enters `handle_continue(:subscribe_and_init, state)` which (a) calls `Ezagent.Behavior.Publisher.subscribe_from(session_uri, self(), :latest)` and (b) calls `binding_module.init({target_id, adapter, opts})`. Only after both succeed does `subscription_state` become `:active`. Until then, any `{:publisher_event, ...}` messages (impossible since not yet subscribed) would be dropped; once subscribed, normal event flow begins.

On receipt of `{:publisher_event, %Event{}}`, the worker dispatches `:publish` to ITSELF via `Ezagent.Invocation.dispatch/1` (`:cast`, idempotency_key = `binding_id <> "/" <> cursor`).

Why dispatch-to-self rather than just calling `invoke` inline: it routes the publish through `Kind.Runtime.handle_dispatch/4` so step 5.5 CapBAC + audit + telemetry + idempotency apply (P14 hygiene). Self-dispatch is a known idiomatic Kind pattern when an external event needs to enter the dispatch flow.

**Why handle_continue (r4 HIGH-1 deadlock fix detail):** If the Worker's `init_slice/1` (which runs synchronously inside `Kind.Server.init/1` which runs inside `DynamicSupervisor.start_child/2` which is called from the Session's `:bind` action body inside the Session GenServer) called `Publisher.subscribe_from/3` directly, AND `Publisher.subscribe_from/3` is a `GenServer.call` against the Session Kind (it is — per PR-EM-0 §8.1), the Session GenServer would be waiting for `start_child` to return WHILE the new Worker is waiting on a GenServer.call back to the same Session = deadlock. The `handle_continue` returns control to the OTP gen_server loop first, THEN runs the subscription — at which point the Session GenServer has returned from `:bind` and can service the subscribe call.

### 6.2 Binding `init/1` and `terminate/2`

`init/1` is called from the Worker Kind's `handle_continue(:subscribe_and_init, ...)` (NOT from `init_slice/1` per r4 HIGH-1 fix above). The binding sets up its transport client (HTTP client, WS connection, RPC stream), validates connection if cheap, returns `binding_state`. Failures here = the Worker process raises in `handle_continue` = PerBindingSupervisor's `:permanent` strategy retries; if init keeps failing, that binding's PerBindingSupervisor intensity trips and stays down (operator sees telemetry; unbinds).

`terminate/2` runs on graceful unbind (per §3 lifecycle). The Session's `:unbind` action body calls `DynamicSupervisor.terminate_child(RootSupervisor, per_binding_sup_pid)` which propagates `:shutdown` to the PerBindingSupervisor which propagates to the Worker. The Worker Kind's `terminate/2` callback calls the binding module's `terminate/2` → exits cleanly.

### 6.3 Two-tier supervisor topology (r4 HIGH-2 fix detail)

The supervision tree under `Ezagent.ExternalMirror.Application`:

```
Ezagent.ExternalMirror.Application
└── Ezagent.ExternalMirror.RootSupervisor    (DynamicSupervisor, one_for_one,
    │                                          max_restarts: 100, max_seconds: 60)
    ├── PerBindingSupervisor[binding_id=A]   (Supervisor, one_for_one,
    │   │                                      max_restarts: 3, max_seconds: 30)
    │   └── Worker[binding_id=A]             (Ezagent.Entity.ExternalMirrorWorker
    │                                          Kind GenServer, permanent)
    ├── PerBindingSupervisor[binding_id=B]
    │   └── Worker[binding_id=B]
    └── ... one per active binding
```

Plus, also under `Application`:

```
├── Ezagent.ExternalMirror.AdapterRegistry  (Registry / ETS owner via EtsOwner)
├── Ezagent.ExternalMirror.BindingRegistry  (Registry / ETS owner via EtsOwner)
└── Ezagent.ExternalMirror.BootReconciler   (one-shot GenServer; exits after one pass)
```

Restart isolation semantics:

| Failure | What restarts | What's untouched |
|---|---|---|
| Worker[A] raises once | Worker[A] (counter inside PerBindingSup[A]: 1/3) | Everything else |
| Worker[A] raises 3 times in 30s | PerBindingSup[A] crashes (counter inside RootSup: 1/100) → RootSup restarts PerBindingSup[A] which restarts Worker[A] | Worker[B], PerBindingSup[B], all other bindings |
| 50 different bindings each have a worker crash once | Each PerBindingSup counter goes to 1/3; siblings untouched; RootSup counter unchanged (no PerBindingSup crashed) | RootSup itself; bindings whose workers didn't crash |
| 50 different bindings each crash 3+ times in 30s | 50 PerBindingSup crashes within RootSup window → RootSup counter 50/100; RootSup restarts each → each PerBindingSup restarts its Worker | RootSup itself stays up (well under 100/60s) |

Compare r3 (HIGH-2 broken): one supervisor with workers as direct children + intensity 3/30s — 4 different bindings crashing once each within 30s trips the supervisor and crashes ALL workers including the 46 that were healthy.

`Kind.spawn(ExternalMirrorWorker, ...)` is the public entry. Internally it: (1) creates a PerBindingSupervisor under RootSupervisor (via `DynamicSupervisor.start_child/2`); (2) the PerBindingSupervisor's child spec spawns the Worker Kind via standard `Kind.Server.start_link/1`. P16 (single Kind spawn entry) is preserved — plugin code never sees PerBindingSupervisor directly.

---

## 7. Storage

### 7.1 Bindings live in Session slice (single SoT); table is projection

Per **P3** + Allen's resolution of OQ-EM-8: the Session's `:external_mirror` slice is THE source of truth for bindings. The persistent table (`external_mirror_bindings`, SQLite) is the snapshot projection written by the standard P22 snapshot writer (`:on_change` strategy) — same machinery as every other Kind slice.

```sql
CREATE TABLE external_mirror_bindings (
  session_uri   TEXT    NOT NULL,
  adapter_id    TEXT    NOT NULL,
  target_id     TEXT    NOT NULL,
  metadata_json TEXT    NOT NULL DEFAULT '{}',
  bound_by      TEXT    NOT NULL,
  bound_at      INTEGER NOT NULL,
  workspace_uri TEXT    NOT NULL,   -- per P21
  PRIMARY KEY (session_uri, adapter_id, target_id)
);
CREATE INDEX idx_emb_workspace ON external_mirror_bindings (workspace_uri);
CREATE INDEX idx_emb_adapter   ON external_mirror_bindings (adapter_id);
```

Per **P21** (per-tenant DB tables carry `workspace_uri NOT NULL`), the table is in the per-tenant tables list (`per_tenant_tables_have_workspace_column_test.exs` invariant test gates a fresh table without the column).

Rehydration on Session Kind init: `Behavior.ExternalMirror.init_slice/1` reads `external_mirror_bindings` scoped by session URI; constructs the slice's `bindings` list. No additional rehydration mechanism — uses the same `:on_change` snapshot flow every other Kind already uses.

No dual-SoT atomicity question because there's exactly one SoT. The table is mechanically derived from the slice via the snapshot writer; a crash mid-snapshot loses one binding write (same semantics as every other slice in the system — caps-data-ownership SPEC accepted this risk class for v1).

### 7.2 ExternalMirrorWorker Kind URI shape

`entity://worker/<workspace>/em_<binding_hash>` where `binding_hash = sha256(session_uri <> adapter_id <> target_id) |> Base.encode16(case: :lower) |> String.slice(0, 12)`. Stable: same binding always maps to same worker URI (so eager-spawn + restart land at the same URI).

The `worker` type segment is a new sub-type on the `entity://` scheme — per SKILL P20 / invariant 11, this is structurally legal (entity types are free-form name prefixes; the `worker` type joins existing `user` and `agent` types in the entity scheme). NOT a new top-level scheme (would violate P11 / SPEC v2 §5.8 — invariant 8).

### 7.3 Cap shape summary

Three caps in play (per §4.2):

| Cap | Shape | Who holds by default | Granted via |
|---|---|---|---|
| 1. Session bind cap | `{kind: :session, behavior: Behavior.ExternalMirror, instance: session_uri, workspace_uri: ws}` | Session owner (caps-data-ownership default grant) | `Behavior.IdentityAdmin.invoke(:grant_cap, ...)` by session owner |
| 2. Per-adapter allow cap | `{kind: :session, behavior: Behavior.ExternalAdapter.<id>.Allow, instance: session_uri, workspace_uri: ws}` | Nobody by default (opt-in) | `Behavior.IdentityAdmin.invoke(:grant_cap, ...)` by workspace admin (`data_owner` returns `:any`) |
| 3. Worker publish cap | `{kind: :external_mirror_worker, behavior: Behavior.ExternalMirrorWorker, instance: :any, workspace_uri: ws}` | Session Kind via scope-bounded `{:within_session, session_uri}` delegation | Auto-granted at Session spawn (caps-data-ownership default grant) |

Cap 3 is what lets the Session Kind dispatch `:publish` to workers. Users never hold this cap directly — it's a framework-internal delegation following the P15 scope-bounded pattern.

### 7.4 Workspace scoping (P17 / P21)

Bindings are tenant-scoped via the session URI's workspace segment. Domain derives `workspace_uri` from `session_uri` at bind time via `Ezagent.Capability.workspace_of/1` (already exists in core, `apps/ezagent_core/lib/ezagent/capability.ex:324`). Stores on the row. Reads scope via `Ezagent.Persistence.scope_by_workspace/2`. Cross-workspace binding (Lark chat in workspace A bound to session in workspace B) is rejected by dispatch step 5.6 (P17 invariant 13) — the `:bind` invocation carries the session's workspace URI; binding to a target out of band requires the adapter to enforce its own cross-tenant logic.

---

## 8. Wiring with SliceChange + caps

This section answers "what concretely changes in core / `domain.chat` / the new Domain to make this work".

### 8.1 Session Kind implements `Ezagent.Behavior.Publisher`

`apps/ezagent_domain_chat/lib/ezagent/entity/session.ex` gains:

- `@behaviour Ezagent.Behavior.Publisher` declaration.
- `:publisher_history` slice (bounded ring; default 100 events or 1 hour — see OQ-EM-A) initialized in `init/1`.
- `handle_info({:slice_changed, event}, state)` clause that appends to `:publisher_history` with monotonic cursor (the cursor IS the ring's monotonic counter; not the wall-clock).
- Implementation of `Publisher.subscribe_from/3`, `Publisher.snapshot/1`, `Publisher.history/3` — each is a `GenServer.call`-targeted Kind action (named `:publisher_subscribe_from`, `:publisher_snapshot`, `:publisher_history` — exposed via a new `Behavior.Publisher` cap-only Behavior so dispatch step 5.5 gates it).

The retention policy is a slice field defaulting to 100 events. PR-EM-0 adds it; the retention is operator-tunable per session via a future `:set_retention` action (not in V1 — OQ-EM-A defers).

### 8.2 Bind action wiring with caps-data-ownership (r6: target check moved out of GenServer)

**r6 codex round-5 HIGH-2 fix**: r4 ran `target_ownership_check` via
`Task.Supervisor.async_nolink/3` + `Task.yield(task, timeout)` INSIDE the
Session GenServer's `:bind` action body — but `Task.yield` blocks the
calling process (the Session GenServer) for the whole timeout window.
While waiting, the Session can't service chat sends, publisher subscribes,
unbinds, or anything else. A slow Lark API takes the Session down for
5 seconds.

r6 splits the bind flow into a **two-step facade pattern**:

1. **`Ezagent.ExternalMirror.bind/3` facade** (lives in
   `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror.ex`,
   NOT inside the Session GenServer) — runs Check 1 (cap shape via
   `Capability.matches?`) + Check 2 (adapter-allow cap) + Check 3
   (target_ownership_check, in a Task with bounded timeout). All checks
   complete BEFORE the dispatch. The Session GenServer is never blocked.

2. **Session's `:bind` action body** (dispatched only after the facade's
   checks return :ok) — assumes pre-validated inputs, does the slice
   mutation + worker spawn synchronously (both fast / pure-Elixir).
   No external I/O inside the GenServer.

```elixir
# Facade (NOT in Session GenServer — runs in caller process)
def bind(session_uri, %{adapter_id: aid, target_id: tid, metadata: md}, caller, ctx) do
  with {:ok, adapter} <- AdapterRegistry.lookup(aid),
       :ok <- check_adapter_allow_cap(ctx.caps, session_uri, aid),                      # Check 2
       :ok <- run_target_ownership_check(adapter, caller, tid) do                        # Check 3
    # Check 1 + slice mutation + worker spawn dispatch ONLY after checks pass.
    inv = %Ezagent.Invocation{
      target: URI.new!("#{URI.to_string(session_uri)}?action=external_mirror.bind"),
      mode: :call,
      args: %{adapter_id: aid, target_id: tid, metadata: md, _facade_checks_ok: true},
      ctx: ctx
    }
    Ezagent.Invocation.dispatch(inv)
  end
end

# Session GenServer's :bind action — short, synchronous, no external I/O
def invoke(:bind, slice, %{adapter_id: aid, target_id: tid, metadata: md,
                          _facade_checks_ok: true}, ctx) do
  binding = %{
      binding_id:  "#{aid}/#{tid}",
      adapter_id:  aid,
      target_id:   tid,
      metadata:    md,
      bound_by:    ctx.caller,
      bound_at:    DateTime.utc_now()
    }
    new_slice = update_in(slice.bindings, &[binding | &1])

    # Eager spawn the worker (§3 lifecycle — bind success → worker exists).
    # Per r4 HIGH-1: worker's init_slice/1 does NOT subscribe; subscription
    # happens in worker's handle_continue AFTER this Kind.spawn returns and
    # AFTER :bind returns. No deadlock.
    # r6 codex round-5 HIGH-1 fix: `Kind.spawn/2` returns
    # `DynamicSupervisor.on_start_child()` = `{:ok, pid}` on fresh
    # spawn OR `{:error, {:already_started, pid}}` on idempotent
    # adoption. Both are SUCCESS for bind purposes. Other errors
    # propagate as a bind failure (slice mutation already done; the
    # caller sees the error + can :unbind to clean up).
    worker_uri = worker_uri_for(ctx.target_uri, binding)

    case Ezagent.Kind.spawn(Ezagent.Entity.ExternalMirrorWorker,
                            %{uri: worker_uri,
                              session_uri: ctx.target_uri,
                              binding: binding}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> throw({:bind_worker_spawn_failed, reason})
    end

    # Update BindingRegistry read-cache.
    :ok = BindingRegistry.add(aid, tid, ctx.target_uri)

  {:ok, %{binding_id: binding.binding_id}, new_slice}
end
```

The Session GenServer's action body is now bounded by slice update + cheap
`Kind.spawn` (the spawn returns once the worker's lightweight `init_slice/1`
returns per HIGH-1 fix; subscription happens later via `handle_continue`).
No external I/O inside the GenServer.

The facade's `run_target_ownership_check/3` (NOW in the facade, NOT the
Session GenServer) — runs in a supervised Task with bounded timeout. Adapter
cannot recurse via dispatch (enforced by PR-EM-FINAL invariant test g).

```elixir
# Facade-side helper (caller-process scope, NOT Session GenServer)
defp run_target_ownership_check(adapter, caller, target_id) do
  timeout =
    if function_exported?(adapter, :target_ownership_check_timeout, 0),
      do: adapter.target_ownership_check_timeout(),
      else: 5_000

  task = Task.Supervisor.async_nolink(
    Ezagent.ExternalMirror.TargetCheckTaskSup,
    fn -> adapter.target_ownership_check(caller, target_id) end
  )

  case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
    {:ok, :ok} -> :ok
    {:ok, {:error, reason}} -> {:error, reason}
    {:exit, reason} -> {:error, {:target_check_crashed, reason}}
    nil -> {:error, :target_check_timeout}
  end
end
```

Check 1 (session bind cap) is enforced by step 5.5 BEFORE this body runs. The new `TargetCheckTaskSup` (a `Task.Supervisor`) is started under `Ezagent.ExternalMirror.Application` alongside RootSupervisor.

### 8.3 Worker subscription to Publisher (r4: handle_continue, no deadlock)

Worker Kind's `init_slice/1` returns minimal state (NO Publisher subscribe, NO binding.init call):

```elixir
def init_slice(%{session_uri: session_uri, binding: binding} = _args) do
  # r4 HIGH-1 fix: minimal state. Subscription + binding init deferred to
  # handle_continue so this init returns quickly and doesn't block the
  # Session's :bind action which is currently inside a Session GenServer call.
  %{
    binding:             binding,
    session_uri:         session_uri,
    publisher_cursor:    nil,                # set in handle_continue
    binding_state:       nil,                # set in handle_continue
    subscription_state:  :pending,           # → :active in handle_continue
    last_publish_at:     nil,
    last_publish_result: nil,
    publish_count:       0,
    error_count:         0
  }
end
```

The Worker Kind's `Kind.Server.init/1` schedules `handle_continue(:subscribe_and_init, ...)` after `init_slice/1` returns. The continuation:

```elixir
# In Ezagent.Entity.ExternalMirrorWorker via the Kind.Server's handle_continue
def handle_continue(:subscribe_and_init, %{slices: %{state: slice}} = state) do
  session_uri = slice.session_uri
  binding     = slice.binding

  # Now safe: this runs AFTER init returned. The Session GenServer has
  # released the :bind action's call; Publisher.subscribe_from won't deadlock.
  {:ok, current_cursor} =
    Ezagent.Behavior.Publisher.subscribe_from(session_uri, self(), :latest)

  binding_module = BindingRegistry.lookup_module!(binding.adapter_id)
  adapter        = AdapterRegistry.lookup!(binding.adapter_id)

  case binding_module.init({binding.target_id, adapter, binding}) do
    {:ok, binding_state} ->
      new_slice = %{slice |
        publisher_cursor:   current_cursor,
        binding_state:      binding_state,
        subscription_state: :active
      }
      {:noreply, put_in(state.slices.state, new_slice)}

    {:error, reason} ->
      # Binding's transport failed to open. Raise to crash the worker —
      # PerBindingSupervisor will restart per §3 lifecycle.
      raise "binding init failed: #{inspect(reason)}"
  end
end
```

On `{:publisher_event, %Event{}}` in `handle_info`, the worker self-dispatches `:publish` (§6.1) — that routes through standard dispatch with cap check 3 (worker publish cap) enforced. If `subscription_state` is still `:pending` (event arrived during the tiny gap between init and handle_continue — impossible since not yet subscribed, but defensively), the worker logs and drops (latest-wins per §3).

---

## 9. Migration plan (PR-EM-0 through PR-EM-FINAL)

Eight PRs. Each independently shippable; tests pass between.

### PR-EM-CORE — `Ezagent.Kind.Server` post-init continuation hook (prerequisite)

**Owner:** `apps/ezagent_core/` — touches core runtime, NOT external_mirror.

Codex round-4 HIGH-1 fix: r4's split-init pattern (Worker
`init_slice/1` returns slice; `handle_continue(:subscribe_and_init, ...)`
does the side-effecting subscribe + binding init) requires
`Ezagent.Kind.Server` to expose a post-init continuation point.
Current `Server.init/1` only returns `{:continue, :announce_ready}`;
Behaviors have no way to plug in.

**Changes:**

- Extend `Ezagent.Behavior` with new OPTIONAL callback:
  `@callback post_init(args :: map(), slice :: map()) :: :ok | {:continue, term()}`
  — returns either `:ok` (no post-init work) or a term that Server
  routes through its own `handle_continue/2`.
- Extend `Ezagent.Kind.Server.init/1` + `handle_continue/2` to chain:
  `{:continue, :announce_ready}` → first; then if ANY Behavior on
  this Kind returned `{:continue, term}` from `post_init`, queue
  those continuations in order via successive `{:noreply, state, {:continue, term}}`.
- Per-Behavior `handle_continue(term, slice, ctx)` callback (also optional)
  receives the continuation term + writes back the slice via the
  standard `Kind.Server` post-update path.

**Acceptance:**
- Add test-only `OwnedBehavior.PostInit` that returns
  `{:continue, :setup_thing}` from `post_init/2` and writes a
  flag in `handle_continue/3`. Assert that after Kind spawn, the
  Server's `announce_ready` AND the Behavior's post-init both ran,
  with announce_ready first (boot order invariant).
- Backwards-compat test: existing Behaviors without
  `post_init/2` declared spawn unchanged (no continuation noise).
- `mix compile --warnings-as-errors` clean.

**Why prerequisite to ExternalMirror PR-EM-2:** the Worker Kind
needs to defer SliceChange subscribe + binding.init until after
`announce_ready` (so dispatch is ready by the time the binding
starts publishing back). Without this extension, the split-init
pattern in §6.1 + §3 fails compile.

**LOC est:** ~150 (core extension + Behavior callback + 3 tests).

### PR-EM-0 — Publisher behaviour + Session Kind implementation + retention policy

**Owner:** `apps/ezagent_domain_chat/`.

- Define `Ezagent.Behavior.Publisher` behaviour in `apps/ezagent_domain_external_mirror/` (the SPEC home; behaviour lives in the new Domain even though Session is in `domain.chat`).
- `Ezagent.Entity.Session` (`apps/ezagent_domain_chat/lib/ezagent/entity/session.ex`) implements `@behaviour Publisher`:
  - `:publisher_history` slice added to `init/1`.
  - `handle_info({:slice_changed, ...})` clause appends to ring with monotonic cursor.
  - `subscribe_from/3`, `snapshot/1`, `history/3` exported as Kind GenServer calls.
- Define `Ezagent.Behavior.Publisher` cap-only Behavior (`dispatchable?: false`) — gates subscribe/snapshot/history actions.
- Retention default: 100 events per session.
- **Depends on:** PR-N1 (SliceChange hook landed). Inert until SliceChange is `:on`.

**Acceptance:** new tests in `apps/ezagent_domain_chat/test/` cover Publisher API on a spawned session — subscribe_from latest receives next mutation's event; subscribe_from earliest replays retained history; history(from, to) returns the right window; cursor out-of-window raises.

**LOC est:** ~250.

### PR-EM-1 — `domain.external_mirror` skeleton + AdapterRegistry + BindingRegistry

**Owner:** new `apps/ezagent_domain_external_mirror/`.

- Create app with standard umbrella shape; deps `:ezagent_core` + `:ezagent_domain_chat` only.
- Define `Ezagent.ExternalMirror.AdapterRegistry` (ETS, owned by `EzagentCore.EtsOwner` — extend the `@tables` list).
- Define `Ezagent.ExternalMirror.BindingRegistry` (ETS; reverse-lookup cache).
- Define `Ezagent.ExternalMirror` facade module (read-only helpers per §4.4).
- Extend `Ezagent.Plugin` contract with optional `adapters/0` callback.
- Extend `Ezagent.Plugin.boot/1` to call `AdapterRegistry.register/1` + `BindingRegistry.register_module/2` + `CapabilityRegistry.register/3` per declared `(adapter, binding)` pair.
- Extend `:ezagent_plugin_check` Mix compiler with Grill-5 validation: (a) adapter/binding implement their respective behaviours; (b) `adapter.binding_module() == binding`; (c) `binding.adapter_module() == adapter`; (d) `adapter != binding` (different modules).

**Acceptance:** new tests cover registry lifecycle, plugin contract integration, Mix compiler rejection of (i) module implementing both behaviours, (ii) adapter/binding cross-reference mismatch.

**LOC est:** ~200.

### PR-EM-2 — Adapter + Binding behaviours + Worker Kind + Worker Behavior + two-tier supervision

**Owner:** `apps/ezagent_domain_external_mirror/`.

- Define `Ezagent.ExternalMirror.Adapter` behaviour (per §2.2 / §5).
- Define `Ezagent.ExternalMirror.Binding` behaviour (per §2.3 / §6).
- Define `Ezagent.Entity.ExternalMirrorWorker` Kind (per §7.2 — URI shape `entity://worker/<ws>/em_<hash>`).
- Define `Ezagent.Behavior.ExternalMirrorWorker` Behavior with `:publish` action (per §4.3 / §6.1).
- Two-tier supervision per §5.3 + §6.3 (r5 codex round-4 HIGH-2 + HIGH-3 fix — DO NOT regress to a single `WorkerSupervisor`):
  - Start `Ezagent.ExternalMirror.RootSupervisor` (`DynamicSupervisor`, `:one_for_one`, `max_restarts: 100, max_seconds: 60`). Children = per-binding supervisors.
  - Implement `Ezagent.ExternalMirror.PerBindingSupervisor` (`Supervisor`, `:one_for_one`, `max_restarts: 3, max_seconds: 30`). Owns ONE Worker child per binding.
  - Worker child is `:permanent`; PerBindingSupervisor under RootSupervisor is `:permanent` (PR-EM-2 codex round-1 CRIT fix — r5 originally said `:transient` but OTP supervisor budget exhaustion exits with `:shutdown` which `:transient` does NOT restart, so a single inner-budget burn would leave the binding permanently down; see §3 for the corrected rationale).
- **Idempotency mechanism (r5 codex round-4 HIGH-3 fix):** `DynamicSupervisor` does NOT use child id for uniqueness — duplicate `start_child/2` would silently spawn a second PerBindingSupervisor + Worker. Use a `Registry` (stdlib) named `Ezagent.ExternalMirror.WorkerRegistry` (`:unique`, `keys: :unique`); the PerBindingSupervisor's child spec uses `{:via, Registry, {WorkerRegistry, binding_uri}}` as its `:name`. Concurrent `start_child` for the same `binding_uri` → second call returns `{:error, {:already_started, pid}}` (Registry-enforced); reconciler treats that as success. The §3 / §3.1 reconciliation guarantees rely on this exact uniqueness contract — `binding_uri` here is the full Worker Kind URI (`entity://worker/<ws>/em_<hash>`) so cross-workspace bindings can't collide.
- `data_owner/1` on `Behavior.ExternalMirrorWorker` returns `:no_owner`.
- Test with mock adapter + mock binding (in test support): worker spawn via `Kind.spawn`, `:publish` dispatch routes through adapter.event_to_payload → binding.publish, slice updates carry cursor/count.

**Acceptance:**
- worker spawn + publish + slice update flow covered in unit tests
- per-binding isolation regression: spawn 3 bindings; kill 1 worker mid-publish 10× to trip its PerBindingSupervisor; assert the OTHER 2 PerBindingSupervisors + Workers are unaffected (RootSupervisor child count = 2 after the crash, not 0)
- **two-tier shape invariant test** (r5 HIGH-2): inspect `Supervisor.which_children(RootSupervisor)` → assert every child is itself a `Supervisor` (NOT an `Ezagent.Kind.Server`); assert each such child's `which_children` returns exactly one `Ezagent.Kind.Server`. Catches accidental regression to shared-supervisor topology
- **idempotency regression test** (r5 HIGH-3): concurrent `start_child` for the same `binding_uri` from 10 tasks → exactly 1 Worker process exists at the Registry-keyed name; 9 calls returned `{:already_started, pid}`

**LOC est:** ~340 (+60 for two-tier topology + Registry wire-up + 2 new acceptance tests).

### PR-EM-3 — `Behavior.ExternalMirror` on Session + bind/unbind/list_bindings + §4.2 wiring

**Owner:** `apps/ezagent_domain_external_mirror/`.

- Define `Ezagent.Behavior.ExternalMirror` with `:bind`, `:unbind`, `:list_bindings` actions (per §4.1).
- **r6 HIGH-2 fix**: bind flow split into facade + GenServer-action two steps. Implement `Ezagent.ExternalMirror.bind/4` facade (NOT inside Session Kind) — runs Check 2 (adapter cap) + Check 3 (`run_target_ownership_check` with Task + timeout) before dispatch. Facade-only adapter I/O; GenServer-action only slice mutation + worker spawn.
- `data_owner/1` per §4.1 (session owner via `Ezagent.Entity.Session.owner/1` — already exists, PR-OWN-2 #308).
- `init_slice/1` rehydrates from `external_mirror_bindings` table (Ecto schema + migration in this PR).
- `:bind` action body assumes `_facade_checks_ok: true` arg; mutates slice + idempotently spawns worker. **r6 HIGH-1 fix**: spawn result handling treats `{:ok, _pid}` AND `{:error, {:already_started, _pid}}` as success.
- `:unbind` action body removes from slice + BindingRegistry + sends graceful shutdown to worker.
- Register the Behavior on `Ezagent.Entity.Session` via Domain's `Application.start/2`.
- Add `external_mirror_bindings` to the `per_tenant_tables_have_workspace_column_test.exs` invariant test's expected list.

**Acceptance:**
- (a) bind/unbind/list roundtrip;
- (b) cap 1 denial (non-owner);
- (c) cap 2 denial (`:adapter_not_authorized`);
- (d) cap 3 not held by user;
- (e) target_ownership_check denial (`{:target_ownership_denied, :not_a_member}`);
- (f) target_ownership_check timeout (mock adapter that sleeps > timeout → `:target_check_timeout`);
- (g) cross-workspace denial;
- (h) **rehydration after Kind restart preserves bindings AND restarts workers** (r4 HIGH-3 fix): bind a probe adapter, send a slice change, assert probe receives; kill the Session Kind process via `Process.exit(session_pid, :kill)`; wait for Kind respawn; send another slice change; assert probe RECEIVES the new event (proving worker was reconciled, NOT just the binding row);
- (i) worker eager-spawned on bind success WITHOUT deadlock (r4 HIGH-1 fix): time the `:bind` action call — must return within 100ms even though worker subscribes to Publisher (which is a `GenServer.call` against the Session Kind that's currently executing `:bind`); test fails (hangs / times out) if r3's synchronous subscribe-in-init pattern is reintroduced;
- (j) **bind idempotency at facade level** (r6 HIGH-1): spawn 10 concurrent `ExternalMirror.bind/4` calls with same `{session, adapter, target}` — assert exactly 1 binding row in slice + exactly 1 Worker process in WorkerRegistry; the 9 losers return `:ok` (treating `{:already_started, _}` from `Kind.spawn` as success), NOT an error. Catches regression to round-5's `:ok = Kind.spawn(...)` hard-match;
- (k) **Session GenServer not blocked during target check** (r6 HIGH-2): mock adapter's `target_ownership_check/2` sleeps 3 seconds. While `bind` is in flight, fire a `Chat.send` action on the SAME session from another process — assert it returns within 50ms (NOT blocked behind the 3s sleep). Confirms target check runs in facade Task, not inside Session GenServer.

**Depends on:** PR-EM-0 (Publisher), PR-EM-1 (registries), PR-EM-2 (worker Kind).

**LOC est:** ~350.

### PR-EM-4 — Admin LV per-session binding management

**Owner:** `apps/ezagent_plugin_liveview/`.

- LV at `/admin/sessions/:id/external_mirror` shows per-session bindings + worker stats (last_publish_at, publish_count, last_publish_result, error_count — read from Worker Kind `:state` slice).
- Bind/unbind buttons gated by caps (filter adapter dropdown to adapters caller holds Cap 2 for, per §5.4 P15 narrow-by-default).
- Drill-down to per-binding recent telemetry events (read from `Ezagent.Audit` stream).

**Depends on:** PR-EM-3 (`:bind` / `:unbind` action wired).

**LOC est:** ~300.

### PR-EM-5 — CLI auto-derivation

**Owner:** core CLI.

- `mix ezagent.external_mirror.list_adapters` — wraps facade.
- `mix ezagent.external_mirror.bind <session_uri> <adapter_id> <target_id> [--metadata k=v]` — wraps `:bind` dispatch.
- `mix ezagent.external_mirror.unbind <session_uri> <adapter_id> <target_id>` — wraps `:unbind`.
- `mix ezagent.external_mirror.list_bindings <session_uri>` — wraps `:list_bindings`.
- All commands check caps client-side AND surface dispatch errors verbatim (P18) — `:adapter_not_authorized`, `:target_ownership_denied {reason}`, `:unauthorized`.

**Depends on:** PR-EM-3.

**LOC est:** ~150.

### PR-EM-6 — Feishu plugin rewrite — FeishuAdapter + FeishuChatBinding; retire one-off

**Owner:** `apps/ezagent_plugin_feishu/`.

- Implement `EzagentPluginFeishu.FeishuAdapter`:
  - `adapter_id/0 → "feishu"`, `display_name/0 → "Feishu (Lark)"`, `description/0`, `cap_subject/0 → %{behavior_module: EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow, description: "..."}`.
  - `target_ownership_check(caller, chat_id)` queries Lark API "is `caller`'s linked feishu_open_id a member of chat `chat_id`?".
  - `event_to_payload(%Event{slice_key: :chat, ...})` translates to Lark `im.v1.messages.create` JSON; returns `:skip` for non-chat slice changes (V1 parity with today's FeishuOutbound).
  - `binding_module/0 → EzagentPluginFeishu.FeishuChatBinding`.
- Implement `EzagentPluginFeishu.FeishuChatBinding`:
  - `adapter_module/0 → EzagentPluginFeishu.FeishuAdapter`.
  - `init({chat_id, _adapter, opts})` opens Feishu HTTP client + caches tenant token; returns `{:ok, %{chat_id: chat_id, client: client, last_retry_at: nil}}`.
  - `publish(payload, state)` posts to Lark; handles 429 with state-tracked backoff; returns `{:ok, state}` on success, `{:error, reason, new_state}` on recoverable HTTP error.
  - `terminate(_reason, state)` closes client.
- Declare `adapters: [{FeishuAdapter, FeishuChatBinding}]` in `EzagentPluginFeishu.Application`.
- One-shot migration script `mix ezagent.external_mirror.migrate_feishu_bindings` reads `feishu_session_bindings` rows + dispatches `:bind` on each. Grants Cap 2 (per-adapter allow) to each binding's `bound_by` user. Idempotent.
- DELETE `EzagentPluginFeishu.Behavior.FeishuOutbound` (311 LOC).
- DELETE `EzagentPluginFeishu.SessionBinding` + `feishu_session_bindings` table (130 LOC + migration).
- DELETE `Behavior.Chat`'s `maybe_notify_external/3` (`chat.ex:699-720`) — chat slice changes now flow through the generic Session Publisher → bound worker path.
- DELETE Feishu-specific mix tasks (`ezagent.feishu.bind` etc.) — replaced by generic `ezagent.external_mirror.*`.
- MIGRATE existing `feishu_session_binding` tests to assert against the new dispatch path. Cap denial tests become "Cap 1 OK + Cap 2 missing → `:adapter_not_authorized`" tests. Bind/unbind roundtrips target generic `:bind` / `:unbind`.
- E2E test: end-to-end Feishu inbound → session → outbound via the new path; behavior parity with old path (same Lark API calls for the same input messages).

**Depends on:** PR-EM-5 (CLI for migration script + operator commands).

**LOC est:** ~400 net (new ~600, deleted ~700).

### PR-EM-FINAL — invariant tests + GLOSSARY + SKILL update

**Owner:** `apps/ezagent_domain_external_mirror/test/invariants/` + meta.

Invariant tests (per **P6** completion-claim-requires-invariant-test):

**(a) Every mirror publish went through `Invocation.dispatch/1` to a Worker Kind.** Grep gate: any module outside `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror_worker.ex` that calls `BindingRegistry.lookup_module!` or directly invokes `*.Binding.publish/2` is an offender. Integration test: spawn session + bind probe adapter + trigger slice change + assert the publish caller pid is a Worker Kind process (not Session Kind, not a Task, not a Phoenix.PubSub consumer).

**(b) Per-binding crash isolation.** Bind `BoomAdapter` (raises on every publish) + `SurvivorAdapter` (records) to the same session; trigger 10 slice changes; assert Survivor received all 10 events; assert Session Kind alive; assert BoomAdapter's worker is restart-looping (telemetry counter > 0); assert other bindings unaffected.

**(c) `target_ownership_check` called before bind succeeds.** Mock adapter whose `target_ownership_check` records the caller URI + target; attempt bind with `caller=Alice, target=bob_only`; assert the check was invoked AND the bind was rejected with `{:target_ownership_denied, :not_a_member}`.

**(d) BindingRegistry never has rows missing from session SoT.** Periodic invariant test: enumerate all BindingRegistry entries; for each `{adapter_id, target_id}` → session_uri, dispatch `:list_bindings` on session and assert the matching binding is present. Catches read-cache drift from the SoT slice.

**(e) Plugin-contract grep gate — no module implements both Adapter and Binding behaviours.** Static check on `:code.all_loaded`: any module having both `@behaviour Ezagent.ExternalMirror.Adapter` AND `@behaviour Ezagent.ExternalMirror.Binding` fails.

**(f) No `Phoenix.PubSub.subscribe` in any module under `apps/ezagent_domain_external_mirror/` or under a plugin-declared binding module's transitive deps.** Grep gate. Bindings use `Ezagent.Behavior.Publisher.subscribe_from/3` — never PubSub directly. This is the structural enforcement that closes the P11 escape.

**(g) No `Ezagent.Invocation.dispatch` (or `Kind.spawn` / `Behavior.invoke` direct) from inside any adapter module's `target_ownership_check/2` callback (r4 round-3 MEDIUM fix).** Grep gate against all modules declared as adapters in any plugin's `adapters/0`. Catches an adapter author who tries to re-enter ezagent from inside the bind-time check — would cause dispatch-during-dispatch deadlock since `:bind` is itself a dispatched action.

**(h) Two-tier supervisor topology preserved (r4 round-3 HIGH-2 fix).** Test asserts `Ezagent.ExternalMirror.RootSupervisor` is a `DynamicSupervisor` whose children are all `Supervisor` modules with one Worker each — NOT a `DynamicSupervisor` with Workers as direct children. Catches an "optimization" that flattens the tree and reintroduces the cumulative-restart-intensity bug.

**(i) Rehydration reconciliation runs on Session Kind init AND application boot (r4 round-3 HIGH-3 fix).** Two sub-tests: (i.1) bind a probe adapter, restart only the Session Kind, send a slice change, assert probe receives. (i.2) bind a probe adapter, restart the entire application (full Application stop + start), assert BootReconciler ran and the worker is spawned + subscribed before any test slice change is sent.

Meta updates:
- `GLOSSARY.md` Decision Log adds the next sequential entry: "ExternalMirror Domain — Publisher behaviour on Session, Adapter (stateless) + Binding (stateful per-target supervised GenServer) contract; bind cap via caps-data-ownership-v2 (session owner grants); per-adapter allow cap + per-target ownership check; worker lifecycle = eager / supervised-restart / latest-wins / graceful-unbind."
- `ezagent-developer` SKILL update: new how-to ("How-to: write an ExternalMirror adapter + binding"); new anti-pattern ("DON'T duplicate the Feishu one-off outbound shape — use the ExternalMirror Domain"); new anti-pattern ("DON'T `Phoenix.PubSub.subscribe` from a binding — use `Publisher.subscribe_from/3`").

**Acceptance:** all six invariant tests pass; gate-verify by temporarily reintroducing each anti-pattern → corresponding test fails.

**LOC est:** ~250.

### Sequencing

Strict order:
- **PR-EM-0** → first (Publisher).
- **PR-EM-1** → after PR-EM-0 (Domain skeleton).
- **PR-EM-2** → after PR-EM-1 (worker Kind needs registries).
- **PR-EM-3** → after PR-EM-2 (`:bind` needs worker spawn + registries).
- **PR-EM-4** + **PR-EM-5** in parallel after PR-EM-3 (LV + CLI both consume `:bind`).
- **PR-EM-6** → after PR-EM-5 (migration script needs CLI).
- **PR-EM-FINAL** → after PR-EM-6 (invariant gates close the architectural promises).

Total estimate ~8 PRs, 3 weeks if shipped sequentially, 2 weeks with PR-EM-4/5 parallel.

---

## 10. Non-goals

The Domain explicitly does NOT:

1. **Implement any specific transport.** No HTTP client, no WS client, no FFI to game servers. Each binding ships its own transport.
2. **Manage external system authentication.** The Feishu binding holds Lark tenant tokens; the Slack binding holds Slack OAuth tokens. The Domain has no notion of external credentials.
3. **Defend against in-VM plugin code.** Same-VM plugins are trusted (PR #303 round-5 threat model, Allen approved 2026-05-24). The per-adapter cap + per-target ownership check are USER-level authorization, not BEAM sandboxing. A malicious plugin author who ships an exfiltration binding can publish anywhere it has credentials for — the controls are about preventing INNOCENT users from binding to a target they don't own, not about containing malicious code.
4. **Replace the Chat Domain.** Chat is entity-to-entity messaging with intentional addressing. ExternalMirror is one-way session-state replication. They share the slice (Chat slice changes are mirror frames) but not a code path.
5. **Replace `Ezagent.Notifications` / `SliceChange`.** This Domain CONSUMES the SliceChange primitive (via the Publisher layer it sits on top of). Does not compete with or override notification-layer cap shape.
6. **Provide a generic inbound path.** Inbound from external systems (Feishu webhook → ESR Chat) stays in the plugin's own `InboundDispatcher` (per P11). This Domain is OUTBOUND-only.
7. **Buffer or persist mirror frames longer than Publisher retention.** V1 retention is 100 events / 1 hour (OQ-EM-A). Adapters needing at-least-once delivery + long-term replay must implement their own external-side dedup / log.
8. **Auto-disable / circuit-break / health-check bindings.** Per **P2** (let-it-crash, no workarounds): broken bindings stay live, surface failure via telemetry, and require operator unbind to remove. No silent degradation paths.

---

## 11. Open questions (3 remaining — narrow technical decisions for Allen at implementation time, NOT SPEC-approval blockers)

### OQ-EM-7 — Delivery semantics: at-most-once vs at-least-once

V1 worker lifecycle (§3) is **latest-wins on restart** (no replay of missed events from crash period). Adapters that need at-least-once can in principle store a cursor checkpoint in their `binding_state` slice + `subscribe_from(cursor)` on restart — Publisher API supports this today.

**Options:**
- (a) **V1 = at-most-once for all adapters**; document loudly in Adapter @moduledoc; defer per-adapter at-least-once until concrete use case.
- (b) **V1 = per-adapter opt-in via `Adapter.delivery_semantics() :: :at_most_once | :at_least_once`**; when `:at_least_once`, worker checkpoints cursor on every successful publish + resumes on restart.

**Recommendation:** **(a)** for V1. Per P8 (less invented, more assembled) — don't add the per-adapter switch until an adapter actually needs it. Feishu is fire-and-forget chat; missed events are recoverable by operator manual re-send. Game-room adapter (the speculative example) would need at-least-once; defer until it's real.

### OQ-EM-A — Publisher retention policy default

**Options:**
- (a) **100 events** (count-based; constant memory cost per session).
- (b) **1 hour wall-clock** (time-based; aligns with operator intuition of "how far back can I catch up?").
- (c) **MIN of both** (whichever evicts first).

**Recommendation:** **(a) 100 events.** Constant-memory is the production-usability win (P4) — operators don't have to reason about per-session memory based on traffic patterns. 100 events is enough for the realistic "binding restart took 30s" recovery; longer outages are operator-driven anyway.

### OQ-EM-B — Publisher history storage: in-memory ring vs SQLite table

**Options:**
- (a) **In-memory ring only.** Lost on Session Kind restart. Workers re-subscribe from `:latest`.
- (b) **In-memory ring + on-demand restore from `kind_snapshots` on Publisher restart.** Adds one snapshot write per slice change to a Publisher-history slice; restores on Session Kind init.
- (c) **In-memory ring + dedicated `publisher_events` SQLite table written async via P22 writer.** Survives Session Kind restart AND application restart.

**Recommendation:** **(a) in-memory + on-demand restore from SQLite on Publisher restart** (effectively option (b), the middle path). The in-memory ring is the hot-path read; the existing `kind_snapshots` machinery (P22) persists the slice asynchronously. On Session Kind restart, the ring rehydrates from the snapshot — workers can resume from cursor if they checkpointed. No new table; matches every other slice in the system.

Defer (c) until an adapter genuinely needs cross-application-restart replay (currently zero use cases).

---

## Appendix A — Cross-references

- **SKILL P1** (plugin isolation north star) — adding a new adapter = 2 modules + 1 declaration. No core / domain / other-plugin touch.
- **SKILL P2** (let-it-crash; no workarounds) — broken bindings stay live, fail loudly, require operator unbind. No silent auto-disable.
- **SKILL P3** (single source of truth) — Session slice IS the bindings SoT; AdapterRegistry / BindingRegistry / `external_mirror_bindings` table are caches / projections.
- **SKILL P9** (reads-what-data → tier ownership) — Domain reads SliceChange + bindings (generic); plugins read external API (specific). Domain placement justified.
- **SKILL P11** (plugin external integration = Behavior on existing Kind) — ExternalMirror Behavior on Session Kind + ExternalMirrorWorker on its own Kind. Every external write happens inside a Kind's `:invoke`. No PubSub-subscriber-then-external-write anywhere.
- **SKILL P14** (dispatch is the only path between Kinds) — bind / unbind / publish all go through `Invocation.dispatch/1`.
- **SKILL P15** (caps narrow by default) — per-adapter allow cap (Cap 2) narrows bind to specific adapters; worker publish cap (Cap 3) held only via `{:within_session, _}` delegation.
- **SKILL P16** (single Kind spawn entry) — ExternalMirrorWorker spawned via `Ezagent.Kind.spawn/2` only; idempotent on already-running.
- **SKILL P18** (no silent drops on user-facing surfaces) — `:bind` returns distinct error atoms (`:unauthorized` / `:adapter_not_authorized` / `:target_ownership_denied`). Inbound transports decompose + surface back.
- **SKILL P22** (reliability primitives in core/Domain; plugin authors cannot bypass) — AdapterRegistry + BindingRegistry + WorkerSupervisor in Domain.
- **SKILL P23** (declare-don't-call plugin contract) — `adapters/0` callback; framework wires registration + cap subjects.
- **caps-data-ownership-v2 §3.3 + §4 + §5.2** — `Behavior.ExternalMirror.data_owner/1` returns session owner; default grant to session owner; `Behavior.IdentityAdmin.invoke(:grant_cap, ...)` enforces grant rules.
- **notification-architecture-v2 §2.1** — SliceChange primitive; Publisher layer sits on top.

## Appendix B — Worked example: Alice mirrors her session to a Lark chat

Setup (already in place after PR-EM-3 + PR-EM-6 ship):
- Alice (`entity://user/team-alpha/alice`) created session `session://default/team-alpha/standup`. By caps-data-ownership default grant, Alice holds `%Capability{kind: :session, behavior: Behavior.ExternalMirror, instance: session_uri, workspace_uri: workspace://team-alpha}` (Cap 1).
- Workspace admin earlier granted Alice `%Capability{kind: :session, behavior: Behavior.ExternalAdapter.Feishu.Allow, instance: session_uri, workspace_uri: workspace://team-alpha}` (Cap 2 — per-adapter allow).

Action: Alice runs `mix ezagent.external_mirror.bind session://default/team-alpha/standup feishu oc_lark_abc123`.

1. CLI parses + builds `%Invocation{target: <session>?action=external_mirror.bind, args: %{adapter_id: "feishu", target_id: "oc_lark_abc123"}, ctx: %{caller: alice_uri, caps: alice_caps, mode: :call}}`.
2. `Invocation.dispatch/1` → `Kind.Runtime.handle_dispatch/4`.
3. Step 5.5 CapBAC: Alice holds Cap 1 → pass.
4. Step 5.6 cross-workspace: same workspace → pass.
5. `Behavior.ExternalMirror.invoke(:bind, slice, args, ctx)` body runs:
   - Check 2 (Cap 2): Alice holds → pass.
   - Check 3 (`target_ownership_check`): Feishu adapter queries Lark "is Alice's linked feishu_open_id a member of `oc_lark_abc123`?". Lark says yes → pass.
6. Slice updated; eager-spawn `Kind.spawn(ExternalMirrorWorker, %{uri: entity://worker/team-alpha/em_<hash>, ...})`.
7. Worker `init_slice/1`: subscribes to Session Publisher with cursor `:latest`; calls `FeishuChatBinding.init({chat_id, FeishuAdapter, opts})`; binding opens Feishu HTTP client.
8. CLI returns `{:ok, %{binding_id: "feishu/oc_lark_abc123"}}`.

Bob (some other user) sends `:send` to `session://default/team-alpha/standup`:

1. Standard Chat flow appends message; `:chat` slice changes.
2. SliceChange hook fires → Session Kind's Publisher appends to ring with cursor N.
3. Worker receives `{:publisher_event, %Event{cursor: N, slice_key: :chat, ...}}`.
4. Worker self-dispatches `:publish` with idempotency_key `"feishu/oc_lark_abc123/N"`.
5. Worker's `:invoke(:publish, ...)`: `FeishuAdapter.event_to_payload(event)` → `{:publish, %{msg_type: "text", content: ...}}`. `FeishuChatBinding.publish(payload, state)` posts to Lark `/open-apis/im/v1/messages?receive_id_type=chat_id`. Returns `:ok`.
6. Worker slice updates: cursor=N, last_publish_at=now, publish_count++.
7. Lark chat shows Bob's message.

Failure example: Lark returns 429.
1. `FeishuChatBinding.publish/2` returns `{:error, :rate_limited, %{state | retry_after: t}}`.
2. Worker logs + telemetry; slice updates error_count++; binding state holds backoff deadline.
3. Next slice change arrives; binding's `publish/2` checks deadline; if still in backoff, returns `{:error, :backoff, state}` again (or queues + delayed re-fire — binding's choice).
4. After deadline, next publish proceeds normally.
5. Operator sees `last_publish_result: {:error, :rate_limited}` in admin LV; can choose to unbind if persistent.

End-to-end: Alice never touches `entity://worker/...`. Bob never knows the mirror exists. Adapter author writes 1 file with 6 callbacks; binding author writes 1 file with 3 callbacks. Domain owns everything else.
