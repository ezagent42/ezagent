# SPEC — Unify session comms surfaces on the ExternalMirror `:pull` substrate

**Status:** DESIGN (not implementation). Read-only basis; no code changed by this SPEC.
**Basis:** `docs/together/2026-06-27/notes/comms-on-external-adapter.md`
(research + dep-feasibility, branch `docs/comms-adapter-research`).
**Read against:** `origin/main` (`3f68b502`) and `origin/refactor/retire-customer`
(external surface post-retirement, PR #1037).
**Skills:** `ezagent-developer`, `ezagent-socialware`.

---

## 0. Problem in one paragraph

A session has ONE committed message stream (`Ezagent.MessageStore`, in
`ezagent_core`). Today **four** independent browser-facing stacks read+deliver
that stream by hand: chat (`ChatFeed*` + `chat_feed_channel`), external/public
(`ExternalFeed*` + `external_feed_channel`), the operator Conversation
(`WorldLive`), and — post-#1037 — external is no longer even nominally on the
substrate. All four converge by accretion onto one PubSub advisory topic
(`esr:session:<uri>:events`), the tell that they want to be one substrate. The
substrate that should own this — `Ezagent.ExternalMirror` with its `:pull`
adapter kind — exists, was used once (the P3-2 customer feed), and is now dead
or bypassed on every surface. This SPEC designs the unification: one
committed-stream-projection + live-delivery substrate that chat and external
both ride, parameterized so chat's windowed snapshot-refresh AND external's
zero-loss cursor-replay both survive.

This SPEC does NOT change the dependency graph, does NOT move any app, and does
NOT touch hello's write path (Turn/Surface dispatch). It is consolidation +
reviving the adapter framing.

---

## 1. Goals / Non-goals

### Goals (G)

- **G1.** One projection contract (`render/2` over the committed stream) that
  chat and external both implement as registered `:pull` `ExternalMirror.Adapter`
  modules — reviving, not bypassing, the registration.
- **G2.** One **live-delivery contract** that PARAMETERIZES delivery discipline
  per adapter, so chat keeps windowed snapshot-refresh and external keeps
  zero-loss cursor-replay (§4). Neither discipline is lost; neither is forced on
  the other.
- **G3.** ONE adapter-parameterized Phoenix channel (`SessionFeedChannel`) that
  replaces `chat_feed_channel` + `external_feed_channel`, branching on the
  adapter's declared discipline + participation profile (§5).
- **G4.** Re-establish external on the substrate as a real `:pull`/live adapter
  (`ExternalFeedAdapter`), undoing #1037's adapter-drop the right way (§6).
- **G5.** Fold in `AnonIngress` — the shared anon-lifecycle web helper — as the
  web-layer sub-step of this unification's controller/Socket pass, NOT a separate
  PR (§7).
- **G6.** An elimination criterion: no hand-rolled session-feed *channel* remains;
  every browser feed channel rides the substrate (§9).

### Non-goals (N)

- **N1.** hello's **write** path (`TurnDriver` → `Behavior.Surface.put_version/2`).
  It is a write/dispatch, not a feed; it is correctly modeled and stays as-is.
- **N2.** Any app relocation or new app-level `in_umbrella` dep (§8 proves none
  is needed).
- **N3.** History paging UX. The live view is "current window / replayed deltas";
  older history is a separate paging concern, untouched.
- **N4.** Changing the advisory topic mechanism (`esr:session:<uri>:events` and
  the external-delivery outbox topic stay; we consolidate the CONSUMERS, not the
  producers).

---

## 2. Current footing (the four stacks) — what we are collapsing

| Surface | Read | Live deliver | On substrate? |
|---|---|---|---|
| chat | `ChatFeed.snapshot/2` → `MessageStore.chat_visible_recent/2` (windowed, **no cursor**) | subscribe `session_events_topic`; any event → re-read snapshot | `:pull` adapter **declared but bypassed** (registered by nobody; channel calls `ChatFeed` directly) |
| external (main) | `CustomerFeed.snapshot/2` → `committed_customer_visible/2` + `Surface` | subscribe `{:customer_delivery}`; replay lower-bound cursor (zero-loss) | **Yes** — `CustomerFeedAdapter`, `:pull` |
| external (retire #1037) | `ExternalFeed.snapshot/replay` → `committed_external_visible/2` + `Surface` | subscribe `{:external_delivery}` **and** `session_events_topic`; cursor replay | **No** — `CustomerFeedAdapter` DELETED, no `ExternalFeedAdapter` created |
| world Conversation (operator) | `ConversationData.load_messages` → `MessageStore.recent_in_session/2` (SSR) | `WorldLive` subscribes per-session; `handle_info {:chat_message,…}` on `session_events_topic` | **No** — hand-rolled LiveView, a fourth consumer |

Two delivery disciplines exist in production and BOTH are correct for their
surface:

- **chat = windowed snapshot-refresh.** No settlement, latest-N, re-read on any
  event. Cheap, self-healing, *not* zero-loss-guaranteed because it doesn't need
  to be — it always shows the current latest-N. Chat **deliberately deleted** the
  keyset cursor (`ChatFeed` moduledoc: "P4 drops the lower-bound
  `{routed_at, message_id}` keyset cursor … entirely … DELETES a whole class of
  fragility").
- **external = cursor-replay.** Durable settlement outbox, `committed_seq`
  lower-bound cursor, **zero-loss guaranteed** — an external viewer must never
  miss a committed delivery.

A unification that papers over this either over-engineers chat (re-adds the
machinery it deleted) or under-delivers external. **Delivery discipline must be
an adapter-chosen parameter.** This is the bulk of the real design work.

---

## 3. Substrate design — one projection + live-delivery foundation

### 3.1 Where each piece lives (the layered resolution of OQ3)

The substrate is **layered**: the *contract* lives low (in `external_mirror`,
deps only core+identity); the *implementations* live where they can reach the
committed stream + membership + outbox (in `ezagent_domain_socialware` /
`ezagent_domain_session`); the *generic transport* lives in `ezagent_web`.

This mirrors the EXISTING pattern: `render/2` is declared in `external_mirror`'s
`Adapter` behaviour but IMPLEMENTED in socialware (`ChatFeedAdapter`,
`ExternalFeed`), which reach `MessageStore`/`Membership`. The behaviour sits low;
the impl sits where it can reach session.

**Decisive dep finding (§8):** the concrete live-delivery helper needs the
settlement outbox (`Ezagent.Socialware.DeliveryOutbox.committed_deliveries_since/2`)
and the external-delivery topic builder (`Ezagent.Session.ExternalDelivery.topic/1`)
— **both in `ezagent_domain_session`**. `external_mirror` deps ONLY on
`ezagent_core` and **cannot** dep on `session` (session deps UP onto
external_mirror; adding the reverse edge is a documented Mix cycle — see the
explicit WARNING in `external_mirror/mix.exs`). Therefore **a concrete live
helper CANNOT live in `external_mirror`.** Only abstract callback *signatures*
(which reference no session/socialware module) can.

| Layer | App | Holds |
|---|---|---|
| Contract (kind axis + callbacks) | `ezagent_domain_external_mirror` | the `:pull` adapter behaviour, EXTENDED with the live-delivery callbacks (§3.2). Pure signatures only — no session refs. |
| Projection + delivery impls | `ezagent_domain_socialware` (chat) / `ezagent_domain_session` (outbox primitives it already owns) | `ChatFeedAdapter`, `ExternalFeedAdapter` — implement `render/2` + the discipline callbacks; reach `MessageStore`/`Membership`/`DeliveryOutbox`. |
| Generic transport (live) | `ezagent_web` | ONE `SessionFeedChannel` + ONE `SessionFeedSocket` that consume the contract; branch on `delivery_discipline/0` + `participation_profile/0`. |
| Committed stream (data) | `ezagent_core` | `MessageStore` (unchanged; already below everything). |

**No app moves. No new app-level dep is added** (§8).

### 3.2 OQ3 resolution — extend the `:pull` kind, do NOT add a separate `:pull_live` kind

The research's OQ3 asks: new first-class `:pull_live` kind vs. a shared web
channel consuming `:pull`'s `render/2`?

**Resolution: keep ONE `:pull` kind; extend it with optional live-delivery
callbacks.** A separate `:pull_live` kind would (a) fork the registry's
required-callback enforcement a third way for no semantic gain — every `:pull`
adapter we have IS browser-facing and live — and (b) leave the existing `render/2`
"on-demand render" framing orphaned (no caller wants render-without-live). The
two adapters differ on *discipline within `:pull`*, not on *kind*. So we add to
the `Adapter` behaviour, gated as optional-with-default so existing adapters
(Feishu `:push`, test adapters) are untouched:

```elixir
# in Ezagent.ExternalMirror.Adapter — pure signatures, no session refs (legal in external_mirror)

@type delivery_discipline :: :snapshot_refresh | :cursor_replay
@type participation_profile :: :read_only | :participatory

@doc "Live-delivery discipline for this :pull adapter. Default :snapshot_refresh."
@callback delivery_discipline() :: delivery_discipline()

@doc """
Advisory topic(s) the caller's transport subscribes to on join, BEFORE the first
read (subscribe-first invariant). Returns one or more PubSub topic strings.
"""
@callback live_topics(session_uri :: URI.t()) :: [String.t()]

@doc """
:cursor_replay only. Capture the lower-bound cursor BEFORE the content read,
returning {snapshot_map, cursor}. The substrate's generic channel stores the
cursor. (chat / :snapshot_refresh adapters do not implement this.)
"""
@callback join_with_cursor(session_uri :: URI.t(), caller :: URI.t()) ::
            {:ok, %{snapshot: map(), cursor: integer()}} | {:error, term()}

@doc ":cursor_replay only. Replay committed deltas since `cursor`; returns the new max cursor."
@callback replay(session_uri :: URI.t(), caller :: URI.t(), cursor :: integer()) ::
            {:ok, %{snapshot: map(), cursor: integer()}} | {:error, term()}

@doc "Participation surface this feed exposes (read_only chat-viewer vs participatory poster)."
@callback participation_profile() :: participation_profile()

@optional_callbacks [
  delivery_discipline: 0, live_topics: 1,
  join_with_cursor: 2, replay: 3, participation_profile: 0
]
```

`AdapterRegistry.assert_required_callbacks!/1` gains a `:pull`-specific rule: if
`delivery_discipline/0` resolves to `:cursor_replay`, then `join_with_cursor/2`
+ `replay/3` are REQUIRED; for `:snapshot_refresh` they MUST be absent (the
existing kind-branching machinery — `kind_specific_required/1` — is extended,
not rewritten). `live_topics/1` + `participation_profile/0` are required for all
`:pull` adapters (with `kind_of`-style back-compat defaults
`:snapshot_refresh` / `:read_only` resolved via `function_exported?/3` so a
not-yet-migrated adapter still boots).

Legality check (per advisor): does any callback SIGNATURE above reference a
session/socialware module? **No** — only `URI.t()`, `integer()`, `map()`,
atoms. So they are legal in `external_mirror`. The CONCRETE topic strings,
cursor reads, and outbox calls live in the socialware/session implementations.

---

## 4. The live-delivery contract (the core design work)

The contract the generic channel obeys, expressed as the join + advisory
protocols, parameterized by `delivery_discipline/0`. This MERGES the two existing
channel moduledocs (chat `chat_feed_channel.ex`, external `external_feed_channel.ex`)
into one branch — the merge IS the proof that neither chat's windowing nor
external's zero-loss is lost.

### 4.1 Invariant shared by BOTH disciplines

**Subscribe-FIRST.** On join the channel subscribes to `adapter.live_topics(session_uri)`
BEFORE the first content read. This guarantees no event arriving during the read
window is missed: an event landing after subscribe triggers an advisory whose
handling re-reads/replays current state; an event present before the read is
already captured by the read. Both existing channels rely on this; it is
non-negotiable and lifted into the generic channel.

**Advisory-only.** Every PubSub message on a subscribed topic is treated as a
WAKE-UP, never as the payload. The channel re-derives state from the committed
store. Losing an advisory cannot lose a message — the next advisory / reconnect
re-derives. (Self-healing — verbatim from both moduledocs.)

**Re-authorize-on-read.** Every read/replay re-runs the LIVE, fail-closed
membership check (`Ezagent.Session.Membership.authorize/2`). A member who LEFT
stops receiving pushes immediately; on `{:error, :unauthorized}` the channel
pushes `"unauthorized"` and `{:stop, :shutdown}` (fail-closed at the transport,
not just the read). Lifted from chat's `refresh_snapshot/1`.

### 4.2 `:snapshot_refresh` discipline (chat)

```
join(session_uri, caller):
  subscribe(adapter.live_topics(session_uri))          # subscribe-first
  {:ok, snapshot} = ExternalMirror.render(adapter, session_uri, %{caller: caller})
  reply {:ok, %{snapshot: encode(snapshot)}}            # NO cursor stored in assigns

handle_info(_advisory, socket):                          # ANY event on the topic
  case ExternalMirror.render(adapter, session_uri, caller) ...
    {:ok, snapshot} -> push("snapshot", encode(snapshot))   # re-read CURRENT latest-N
    {:error, :unauthorized} -> push("unauthorized"); stop   # live revocation
```

- **No cursor.** `socket.assigns` holds NO cursor — exactly chat's current
  invariant ("There is NO cursor in `socket.assigns`"). The machinery chat
  deleted is NOT reintroduced.
- **Window source** = `MessageStore.chat_visible_recent/2` via `ChatFeed.snapshot/2`
  (latest-N, `routed_at desc`). Windowing is preserved byte-for-byte.
- **Correctness = self-healing latest-N**, not zero-loss-by-replay. This is the
  correct guarantee for chat (always shows current state).

### 4.3 `:cursor_replay` discipline (external)

```
join(session_uri, caller):
  subscribe(adapter.live_topics(session_uri))          # subscribe-first
  {:ok, %{snapshot, cursor}} = adapter.join_with_cursor(session_uri, caller)
       # impl: capture lower = latest_cursor BEFORE content read;
       #       snapshot; replay committed_deliveries_since(lower); cursor = max replayed seq
  reply {:ok, %{snapshot: encode(snapshot)}}; store cursor in assigns

handle_info(_advisory, socket):                          # {:external_delivery} OR session event
  case adapter.replay(session_uri, caller, socket.assigns.cursor) ...
    {:ok, %{snapshot, cursor}} -> push("snapshot", encode(snapshot)); store new cursor
    {:error, :unauthorized}    -> push("unauthorized"); stop
```

- **Lower-bound captured BEFORE the content read** (existing
  `ExternalFeed.join/3` invariant) → a commit landing in the window between the
  content read and the replay — even with its advisory dropped — is re-included.
- **Replay idempotent by `committed_seq`** → a row may be re-delivered (harmless)
  but is NEVER skipped. **Zero-loss preserved.**
- **Cursor only advances over rows the snapshot ACTUALLY rendered** (the
  `ExternalFeed` "no skip / no infinite re-replay" invariant) — preserved
  unchanged because `replay/3` is the same socialware impl, now reached through
  the contract instead of the bespoke channel.
- `live_topics/1` returns BOTH `ExternalDelivery.topic(session_uri)` AND
  `Delivery.session_events_topic(session_uri)` — the retire branch's
  "collaborative-whiteboard chat" requirement (a new chat message from any
  participant re-pushes), expressed as the adapter's declared topic set rather
  than hard-coded in the channel.

### 4.4 Why a single branch loses nothing (the proof obligation)

The generic channel is literally:

```
def join(...), do: dispatch on adapter.delivery_discipline()
def handle_info(advisory, socket), do: dispatch on socket.assigns.discipline
```

with the two bodies above. Because each body is the verbatim protocol of its
current channel, the unified channel is behaviorally a superset, not a merge that
averages. The codex-review obligation (§10) is to confirm: (a) the `:snapshot_refresh`
body stores no cursor and re-reads (chat windowing intact); (b) the `:cursor_replay`
body captures-before-read + replays idempotently (external zero-loss intact);
(c) no shared field couples the two (e.g. the cursor assign exists only on the
`:cursor_replay` branch).

---

## 5. The generic transport — `SessionFeedChannel` + `SessionFeedSocket`

Collapses `chat_feed_channel.ex` + `external_feed_channel.ex` into one
adapter-parameterized channel in `ezagent_web`. Topic shape:
`"socialware:feed:<adapter_id>:<session_uri>"` (one route family; `adapter_id`
selects the adapter via `AdapterRegistry.lookup/1`). The Socket resolves the
adapter + caller (via `AnonIngress`, §7) into `socket.assigns`:
`%{adapter: module, session_uri: %URI{}, caller: %URI{}, discipline: …}`.

### 5.1 Participation is ALSO parameterized (advisor wrinkle #1)

The external channel carries write affordances (`handle_in "join"/"post"/"history"`)
that chat's read-only channel lacks. Collapsing channels MUST parameterize
participation, not only delivery. `participation_profile/0`:

- `:read_only` (chat) — only the read/advisory path; `handle_in("post", …)`
  replies `{:error, %{reason: "read_only"}}` (honest affordance; CapBAC would
  deny anyway).
- `:participatory` (external) — enables `handle_in("join"/"post"/"history")` with
  the EXISTING external semantics verbatim: `join` provisions a narrow per-session
  `Session.:join` cap via `Membership.provision_invited_join_authority/3` and
  dispatches `session.join` AS the viewer through `Ezagent.Invocation.dispatch/1`
  (P14 — never a PubSub broadcast to an inbound topic); `post` dispatches
  `:cast` AS the member (CapBAC authorizes from the member's own `:caps`);
  `history` returns the older window.

The participation handlers move into the generic channel guarded by
`participation_profile/0`; their bodies are lifted from the retire-branch
`external_feed_channel.ex` unchanged. **No participation surface is lost.**

### 5.2 What the channel no longer hard-codes

Topic subscription (now `adapter.live_topics/1`), discipline (now
`adapter.delivery_discipline/0`), and the projection call (now
`ExternalMirror.render/3` + the discipline callbacks). The channel becomes a
thin dispatcher over the contract — the duplicated subscribe/re-read/replay code
exists ONCE.

---

## 6. Re-establish external on the substrate (undo #1037 the right way)

**OQ1 resolution: REVIVE (task-mandated, point 3).** #1037 deleted
`CustomerFeedAdapter` (the `:pull` registration) and renamed
`CustomerFeed → ExternalFeed` WITHOUT re-declaring the behaviour — regressing the
external surface to a fully hand-rolled stack. This SPEC reverses that, but NOT
by reverting the rename (the customer→external rename stays). Instead:

- **Create `Ezagent.Socialware.ExternalFeedAdapter`** (+ `.Allow` cap subject,
  mirroring `ChatFeedAdapter.Allow`), a registered `:pull`
  `ExternalMirror.Adapter` with `adapter_id: "external_feed"`,
  `delivery_discipline: :cursor_replay`, `participation_profile: :participatory`,
  `live_topics/1` = `[ExternalDelivery.topic, Delivery.session_events_topic]`.
- `render/2` delegates to `ExternalFeed.snapshot/2`; `join_with_cursor/2` →
  `ExternalFeed.join/3`; `replay/3` → `ExternalFeed.replay/3`. The `ExternalFeed`
  projection module (its read/snapshot/replay/cursor logic) is REUSED unchanged
  — only the adapter wrapper + registration are new. This is the inverse of
  #1037's delete: the projection survived the retirement; the adapter framing did
  not — we re-add the framing.
- **Register both adapters at boot.** Today neither `ChatFeedAdapter` nor any
  external adapter is registered (the advisor vertical that used to declare
  `ChatFeedAdapter` was retired). Socialware (or a thin socialware plugin
  `adapters/0`) declares both via the existing bare-module pull-declaration
  shape, so `AdapterRegistry` actually holds them and their `allow_*` cap
  subjects are published at boot. The generic channel resolves the adapter FROM
  the registry — so the registration becomes load-bearing (the cure for the
  "declared but bypassed" drift).

**OQ2 resolution: REVIVE chat's `:pull` registration (task-mandated, point 1).**
`ChatFeedAdapter` is currently declared-but-registered-by-nobody. Under this SPEC
the generic channel CONSUMES the registration (resolves adapter via
`AdapterRegistry.lookup("chat_feed")`), so the registration stops being
vestigial — it is the seed of the unification, not cruft. `ChatFeedAdapter` gains
`delivery_discipline: :snapshot_refresh`, `participation_profile: :read_only`,
`live_topics/1 = [Delivery.session_events_topic]`.

---

## 7. AnonIngress — the web-layer sub-step (advisor + research: NOT a separate PR)

The research is explicit: AnonIngress is the INGRESS/auth half of the SAME
per-surface web stacks the channel-collapse rewrites; doing it in the same pass
avoids touching `ChatFeedController/Socket` + `ExternalFeedController/Socket`
twice. It is a SUB-STEP of this unification's web pass, not a prior/separate PR,
and not superseded (the anon-mint/cookie logic must live somewhere after
unification).

### 7.1 What it factors

The retire-branch baseline manifest flags +8 byte-identical
`cross_file_duplicate_fn_groups` across the two controllers + two sockets. The
shared lifecycle (confirmed identical by signature in §method): `show/2` →
`resolve_caller/2` → (signed-in) `render_spa` OR `resolve_anonymous/2` →
`reuse_or_mint/2` → `read_valid_cookie/2` → (`mint_fresh/2`:
`AnonUser.mint` → `join_anon/2` → `put_anon_cookie/2`) → `render_spa/3`; plus
`Socket.connect/3` (parse session + resolve caller).

### 7.2 Design

```
EzagentWeb.Socialware.AnonIngress     # ezagent_web, web-layer only

  @callback resolve(conn_or_socket, session_uri) :: {:ok, caller_uri, conn} | {:error, term}
  # one entry the controller/socket call to get a caller (signed-in member OR
  # minted/reused anon), handling cookie reuse, fresh mint, anon join, cookie set.
```

The two controllers shrink to: parse session → `AnonIngress.resolve/2` →
`render_spa` (the SPA shell differs only by `adapter_id` + asset bundle, which
become params). The two Sockets shrink to: parse session →
`AnonIngress.resolve/2` → assign. Net: the +8 duplicate groups collapse to one
helper, and after the §5 channel-collapse there is ONE controller + ONE socket
(parameterized by `adapter_id`) calling ONE `AnonIngress`.

### 7.3 Placement

`ezagent_web` (web-layer, alongside the channel). It deps on `socialware`
(for `AnonUser.mint` + membership join) and `session` (for `Membership`) — both
already declared. No new dep. AnonIngress is orthogonal to the DOMAIN-layer
substrate work (§3–§6); both are web-layer concerns on the identical files, so
they ship in the same web pass.

---

## 8. Dep-DAG legality — re-confirmed, ZERO new app edges

In-umbrella deps (read from each `mix.exs`, `origin/main`; unchanged on the
retire branch — #1037 is renames+deletes only, no dep changes):

```
ezagent_core                   → (bottom; holds MessageStore = committed stream)
ezagent_domain_identity        → core
ezagent_domain_external_mirror → core, identity        ← SUBSTRATE CONTRACT (low)
ezagent_domain_session         → core, identity, …, external_mirror   ← outbox + ExternalDelivery + Membership live HERE
ezagent_domain_socialware      → core, identity, session, external_mirror, ui   ← chat + external feed impls live HERE
ezagent_plugin_world           → …, session, external_mirror, …
ezagent_plugin_hello           → core, session, socialware, ui, identity, workspace
ezagent_web                    → …, session, socialware, world, hello, …   ← channel + AnonIngress live HERE
```

**Each piece this SPEC adds is legal with NO new app edge:**

1. **Contract callbacks in `external_mirror`** — pure signatures
   (`URI.t()`/`integer()`/`map()`/atoms), no session/socialware ref. `external_mirror`
   stays at `{core, identity}`. **Legal.** (And mandatory there — see #2.)
2. **`external_mirror` CANNOT host a concrete live helper.** The outbox
   (`Ezagent.Socialware.DeliveryOutbox`) + `Ezagent.Session.ExternalDelivery.topic/1`
   live in `ezagent_domain_session`; `external_mirror` deps only on core and
   CANNOT add `session` (session deps UP onto external_mirror — the reverse edge
   is a Mix deps-cycle, documented verbatim in `external_mirror/mix.exs`). So the
   CONCRETE delivery code lives in socialware/session impls; only abstract
   callbacks live low. (This is precisely why OQ3 resolves to "extend the contract
   low, implement high" — §3.2.)
3. **`ChatFeedAdapter` + `ExternalFeedAdapter` in socialware** — socialware
   already deps on `external_mirror` (behaviour), `session` (Membership/outbox/
   ExternalDelivery), `core` (MessageStore). **Legal today, same app, no new edge.**
4. **`SessionFeedChannel`/`Socket` + `AnonIngress` in `ezagent_web`** — web
   already deps on socialware + session + external_mirror. **Legal.**
5. **world (if included, §OQ5)** — already deps on `external_mirror` + `session`.
   **Legal.**

**Acyclic + undeclared-dep gates** (`im_session_agent_acyclic_test.exs`,
`undeclared_umbrella_dep_test.exs`): the acyclic gate is compile-dep + AST-symbol
based; the undeclared-dep gate requires every hard ref backed by a declared
`in_umbrella` dep. This SPEC adds NO new app edge and every hard ref is within an
already-declared dep, so neither gate can trip. **No cycle. No relocation.**

---

## 9. OQ5 — world Conversation, and the coherent elimination criterion

The elimination criterion (§9.2) is "no hand-rolled feed *channel* remains; all
comms ride the substrate." For that claim to be COHERENT we must take a
defensible position on world, because `WorldLive` IS a fourth live consumer of
`session_events_topic` (`handle_info {:chat_message,…}`).

### 9.1 OQ5 resolution: include world on the CONTRACT axis, not the transport axis

- **Include world on the projection + delivery-discipline contract.** `WorldLive`'s
  per-session live read (`ConversationData.load_messages` +
  `handle_info {:chat_message,…}`) is refactored to call the SAME adapter's
  `render/2` + `:snapshot_refresh` re-read path (operator sees the same projected
  stream the substrate owns), so the read/deliver LOGIC is the substrate's, not
  hand-rolled.
- **But world keeps its LiveView transport.** `WorldLive` is a `Phoenix.LiveView`,
  not a `Phoenix.Channel` — it cannot collapse into the `SessionFeedChannel` shell
  (different transport primitive; the operator surface is a full LiveView with
  many other concerns: PTY, audit, authz). So this is **"4→1 on the contract
  axis, not the transport axis."** World stops being an independent
  read/deliver *implementation*; it becomes a consumer of the substrate contract
  on a LiveView transport.

This is the only resolution that keeps the §9.2 elimination claim coherent: every
session-feed read/deliver path rides the substrate contract; the only surviving
non-channel transport (the operator LiveView) is explicitly carved out by
transport type, not left as a parallel hand-rolled stack.

### 9.2 Elimination criterion (the completion gate)

The unification is COMPLETE iff a structural test asserts ALL of:

- **E1.** No module named `*FeedChannel` exists except the single generic
  `EzagentWeb.Socialware.SessionFeedChannel` (grep: `chat_feed_channel` +
  `external_feed_channel` are gone).
- **E2.** Every `:pull` `ExternalMirror.Adapter` is REGISTERED in
  `AdapterRegistry` at boot (no declared-but-unregistered `:pull` adapter) — i.e.
  the registration is load-bearing.
- **E3.** No session-feed live read/deliver path constructs a snapshot/replay
  EXCEPT through `ExternalMirror.render/3` or the discipline callbacks. Concretely:
  `git grep` over web + world for direct `MessageStore.{chat_visible_recent,
  committed_external_visible,recent_in_session}` calls in transport/LiveView code
  returns ONLY the adapter impls in socialware (no transport-layer hand read).
- **E4.** Exactly ONE anon-lifecycle implementation: the +8
  `cross_file_duplicate_fn_groups` for the anon helpers collapse to one
  `AnonIngress`; the arch baseline manifest count drops accordingly.
- **E5.** The dep DAG is unchanged from §8 (no new app `in_umbrella` edge; both
  architecture gates green).

A test that FAILS when any hand-rolled feed channel reappears or any `:pull`
adapter goes unregistered is the architectural invariant gate for this work.

---

## 10. Sequencing (PRs — for the implementation SPEC that follows)

This DESIGN implies (does not execute) the following ordered, individually-green
PRs:

1. **PR-1 (contract):** extend `ExternalMirror.Adapter` with the live-delivery
   callbacks + registry `:pull` discipline enforcement (§3.2). No behavior change;
   pure additive contract. Unit tests: registry accepts `:cursor_replay` adapter
   requiring replay/2,3; rejects `:snapshot_refresh` adapter that declares them.
2. **PR-2 (external adapter revival):** `ExternalFeedAdapter` + `.Allow`,
   delegating to the existing `ExternalFeed` projection; register both chat +
   external adapters at boot (§6). External feed now rides the substrate again.
3. **PR-3 (generic channel + web pass incl. AnonIngress):** `SessionFeedChannel`
   + `SessionFeedSocket` + `AnonIngress`; collapse the two channels + two
   controllers + two sockets; delete `chat_feed_channel`/`external_feed_channel`
   (§5, §7). The web-layer sub-step (AnonIngress) ships HERE, in the same pass —
   not a separate PR.
4. **PR-4 (world contract convergence, OQ5):** refactor `WorldLive`'s session
   read/deliver onto the adapter contract (§9.1); world keeps its LiveView
   transport.
5. **PR-5 (elimination gate):** the §9.2 structural test (E1–E5).

Each PR carries the e2e + regression discipline (every distinct e2e bug earns a
fast unit test). hello requires NO change (it inherits the unified substrate via
its socialware reuse — N1).

---

## 11. Open questions for the lead (post-design)

1. **Adapter registration ownership.** Today no plugin declares the `:pull`
   adapters (the advisor vertical that did was retired). PR-2 must pick the boot
   declarer: a thin socialware-owned `adapters/0` vs. a dedicated micro-plugin.
   Recommendation: socialware-owned `adapters/0` (the feeds ARE socialware's),
   but the plugin-isolation north-star may prefer a dedicated plugin — lead's
   call.
2. **`SessionFeedChannel` topic compatibility.** The new
   `socialware:feed:<adapter_id>:<uri>` topic family changes the wire route from
   `socialware:chat_feed:<uri>` / `socialware:external:<uri>`. Need a deprecation/
   redirect window for any pinned client, OR keep the two legacy topic strings as
   thin aliases that resolve to the same generic channel. Recommendation: keep
   legacy topic aliases for one release (clients churn-free), generic internally.
3. **World inclusion timing (OQ5).** PR-4 is the cleanest place, but if the
   operator-surface refactor is risky, PR-4 can land later WITHOUT blocking
   PR-1..3 — at the cost of the E3/elimination gate scoping world out until then.
   Recommendation: scope the gate to "channels" first (E1–E2,E4 green at PR-3),
   add E3-for-world at PR-4.

---

## Method / provenance

- All reads via `git show origin/main:<path>` and
  `git show origin/refactor/retire-customer:<path>`. No working-tree trust.
- Substrate contract: `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter.ex`
  (the `:push`/`:pull`/`:request_scoped` kind axis; `render/2`; `kind_of/1`);
  `adapter_registry.ex` (`assert_required_callbacks!/1`, `kind_specific_required/1`).
- chat: `apps/ezagent_domain_socialware/lib/ezagent/socialware/chat_feed.ex`,
  `chat_feed_adapter.ex`; `apps/ezagent_web/lib/ezagent_web/socialware/chat_feed_channel.ex`.
- external (retire): `apps/ezagent_domain_socialware/lib/ezagent/socialware/external_feed.ex`;
  `apps/ezagent_web/lib/ezagent_web/socialware/external_feed_channel.ex`;
  controllers `controllers/socialware/{chat_feed,external_feed}_controller.ex`;
  sockets `socialware/{chat_feed,external_feed}_socket.ex`.
- dep finding: `external_mirror/mix.exs` (deps = `{core, identity}`; the explicit
  WARNING that `session` cannot be a dep — cycle); outbox/topic in
  `ezagent_domain_session` (`socialware/delivery_outbox.ex`,
  `session/external_delivery.ex`).
- world: `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`
  (`handle_info {:chat_message,…}` on `session_events_topic`).
- gates: `apps/ezagent_core/test/architecture/im_session_agent_acyclic_test.exs`,
  `undeclared_umbrella_dep_test.exs`.
- topic builders: `session/external_delivery.ex` (`topic/1`),
  `behavior/session/delivery.ex` (`session_events_topic/1`).
