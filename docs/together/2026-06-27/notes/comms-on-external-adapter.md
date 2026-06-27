# Should the session comms surfaces be built ON the external-adapter substrate?

**Research + feasibility — NOT implementation.** Read-only against `origin/main`
(commit `3f68b502`) and `origin/refactor/retire-customer` (the just-renamed
external surface). No code changed.

**The lead's thesis under test:** extracting external/chat's shared anon-ingress
is reasonable, but the *deeper* idea is that chat's communication and the
hello-page↔session communication should themselves be built ON the
external-adapter foundation — one adapter substrate over a session's committed
message stream, with chat / hello / external all being adapters on top, rather
than three parallel hand-rolled feed/channel stacks. The lead is unsure whether
the code's dependency relationships support this. This note answers that.

---

## TL;DR

- **The "external adapter" substrate is real and already low in the DAG.** It is
  `Ezagent.ExternalMirror` in `apps/ezagent_domain_external_mirror`, which deps
  only on `ezagent_core` + `ezagent_domain_identity`. It carries an explicit
  adapter **kind axis** — `:push | :pull | :request_scoped` — and the `:pull`
  kind was *purpose-built* (P3-2, #727) to be the socialware customer feed: "a
  feed served on demand by its CALLER's Phoenix channel," `render/2` over the
  committed stream, no Worker. So **one of the three surfaces already rode the
  substrate** — this is an existence proof, not a hypothesis.

- **Dependency-feasibility verdict: LEGAL. No cycle. Partially already done.**
  `external_mirror` depends *down* only; every comms surface app
  (`socialware`, `world`, `hello` (transitively), `web`) *already declares*
  `ezagent_domain_external_mirror`. Chat (`ChatFeed*`) lives in
  `ezagent_domain_socialware`, which already deps on the substrate — so
  chat→substrate is legal *today*, inside the same app. The committed stream
  itself (`Ezagent.MessageStore`) sits in `ezagent_core`, below everything.
  Nothing about "chat builds on external-adapter" is backwards or cyclic.

- **BUT the substrate today is `:pull` = on-demand RENDER, not live DELIVERY.**
  Every browser surface gets *live* updates the same hand-rolled way: a Phoenix
  channel (or, for the operator surface, `WorldLive`) subscribes to a
  `Phoenix.PubSub` advisory topic — overwhelmingly the **same**
  `session_events_topic` — and re-reads on every wake-up. There are in fact
  **four** independent consumers of that one topic (chat channel, external feed
  channel, world `WorldLive`, and the external channel *also* doubling onto it),
  none using the ExternalMirror **Publisher push** path to reach the browser. So the substrate's *registration/contract* is shared
  (or was), but the *live-delivery transport* is hand-rolled per surface. A
  genuine unification needs a **live variant of the adapter kind axis**, not
  just reuse of `:pull` as it stands.

- **The retire-customer branch REGRESSED the external surface's footing.** The
  customer feed used to be a `:pull` `ExternalMirror.Adapter`
  (`CustomerFeedAdapter`). The retirement **deleted** that adapter and renamed
  `CustomerFeed → ExternalFeed` *without* re-declaring the adapter behaviour.
  So on `refactor/retire-customer` the external feed is now a fully hand-rolled
  stack, and `ChatFeedAdapter` (the surviving `:pull` declaration) is registered
  by *nobody* and used by *nobody*. The substrate framing is currently **dead
  code on both the chat and external sides** — exactly the drift the lead's
  thesis would reverse.

- **AnonIngress is a strict SUB-STEP, not a superseder.** AnonIngress is a
  *web-layer* dedup: `EzagentWeb.Socialware.AnonIngress` factoring the
  byte-identical anon-user lifecycle (mint/reuse → join → cookie → token) shared
  by `ChatFeedController/Socket` and `ExternalFeedController/Socket`. It is
  orthogonal to (and much smaller than) "build comms on the adapter substrate,"
  which is a *domain-layer* unification of the read/deliver path. Doing the big
  unification does not do AnonIngress, and AnonIngress does not advance the big
  unification — they are independent. AnonIngress should still be done; it is not
  subsumed.

- **Recommendation: PARTIAL yes.** Unify chat + external on a single
  *committed-stream projection + live-delivery* substrate that lives in/under
  `ezagent_domain_socialware` (or is lifted into `external_mirror` as a real
  `:pull`/live adapter kind). Keep hello's *write* path (Turn/Surface dispatch)
  as-is; converge only its *read/deliver* path. The dependency structure fully
  supports it with **zero app relocations**. The work is consolidation +
  reviving the adapter framing, not a re-layering.

---

## 1. What IS the "external adapter" substrate today — and which layer

**Module / app:** `Ezagent.ExternalMirror`, app
`apps/ezagent_domain_external_mirror`. SPEC:
`docs/superpowers/specs/2026-05-24-external-mirror-domain.md`.

It is the **ExternalMirror Domain** — "owns every outbound mirror" (developer
invariant #15). Its central contract is the **adapter behaviour**
`Ezagent.ExternalMirror.Adapter`
(`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter.ex`),
backed by `AdapterRegistry`, `AdapterInstall`, `Binding`, `Publisher`, and
`Publisher.Event`.

The contract is **not single-shaped** — there is a deliberate **kind axis**
(`adapter_kind/0`, default `:push`), and the kinds have *different* delivery
models:

| Kind | Transport owner | Delivery model | Required callbacks |
|---|---|---|---|
| `:push` (default) | a paired `Binding` GenServer (Worker per binding) | Domain pushes each `Publisher.Event` → `binding_module.publish/2` (Feishu/email/Slack) | `binding_module/0`, `cap_subject/0`, `target_ownership_check/2`, `event_to_payload/1` |
| **`:pull`** | **the CALLER's Phoenix channel** | **on-demand `render/2` for a session — NO Worker, NO external transport** | **`render/2` + `cap_subject/0`** |
| `:request_scoped` | the caller's HTTP handler (one request) | response/SSE IS the transport (protocol-api, OpenAI/Anthropic-compatible — the #82 work) | same as `:push`, may be no-ops |

The `:pull` kind is the load-bearing one for this question. Quoting the adapter
moduledoc verbatim:

> `:pull` — a feed served on demand by its CALLER's Phoenix channel (the
> socialware customer feed, built in P3-2). A pull adapter has NO per-binding
> external transport ... Instead it implements `render/2`, which returns the
> json-render map for a session on demand.

So the substrate *already encodes* the lead's idea: "a feed over a session,
rendered on demand, where the caller (a Phoenix channel) owns the live
transport." The customer feed was the first `:pull` adapter (#727 framing: "the
customer feed was a `:pull` ExternalAdapter over the committed cursor").

**Layer:** `external_mirror` is **low**. Its `mix.exs` deps are exactly:

```elixir
{:ezagent_core, in_umbrella: true},
{:ezagent_domain_identity, in_umbrella: true}
```

It depends *down* on core + identity and on **nothing** in the surface tier. It
does NOT depend on `ezagent_domain_session`, `ezagent_domain_socialware`,
`ezagent_plugin_world`, `ezagent_plugin_hello`, or `ezagent_web` (a `mix.exs`
comment block explicitly forbids adding the session dep). It sits *below*
`ezagent_domain_session` — in fact `ezagent_domain_session` deps *up onto*
`external_mirror`.

**The committed stream itself** is even lower: `Ezagent.MessageStore`
(`apps/ezagent_core/lib/ezagent/message_store.ex`) is in **`ezagent_core`** — the
bottom of the DAG. Committed reads (`chat_visible_recent/2`,
`committed_customer_visible/2` (main) / `committed_external_visible/2` (retire
branch), `recent_in_session/2`) and the settlement outbox / `committed_seq`
cursor all live there. **So the data foundation the thesis posits — "adapter
substrate OVER the committed stream" — already sits low enough that every surface
and the substrate can read it.**

---

## 2. The three comms surfaces — current footing

For each surface: *read path* (how it gets committed messages) and *deliver
path* (how a connected browser gets live updates), and whether it rides the
substrate.

### chat — `ChatFeed*`

- **Lives in** `ezagent_domain_socialware`
  (`lib/ezagent/socialware/chat_feed.ex`, `chat_feed_adapter.ex`,
  `chat_feed_auth.ex`); channel in
  `apps/ezagent_web/lib/ezagent_web/socialware/chat_feed_channel.ex`.
- **Read path:** `ChatFeed.snapshot/2` → `MessageStore.chat_visible_recent/2`
  (latest-N `:customer_visible` rows, ordered `routed_at desc, id desc`).
  **No cursor** — windowed snapshot.
- **Deliver path (live):** the channel subscribes to
  `Delivery.session_events_topic(session_uri)` (`"esr:session:<uri>:events"`,
  a plain `Phoenix.PubSub` topic the session Behavior's `:notify` effect already
  broadcasts to), then on **any** advisory re-reads the snapshot and pushes it.
  Self-healing: the advisory is treated as a wake-up only, never as the payload.
- **Substrate footing:** `ChatFeedAdapter` *declares* `@behaviour
  Ezagent.ExternalMirror.Adapter` with `adapter_kind :pull` and a `render/2`
  that calls `ChatFeed.snapshot/2`. **BUT** its own moduledoc (2026-06-26) says:
  "With the advisory vertical removed, NO plugin currently declares it ... The
  live chat feed does NOT depend on that registration — the channel calls
  `ChatFeed` directly." So chat is **substrate-shaped but substrate-bypassing**:
  the adapter declaration is vestigial; the real read+deliver path is
  hand-rolled (direct `ChatFeed` call + a plain PubSub subscribe).

### external / public — `ExternalFeed*` (was `CustomerFeed*`)

- **On `origin/main`:** `CustomerFeed` (`customer_feed.ex`) +
  `CustomerFeedAdapter` (a `:pull` `ExternalMirror.Adapter`) + `CustomerAuth` +
  `customer_channel.ex`. Read: `MessageStore.committed_customer_visible/2` +
  `Surface.tree_for_version/2`. Deliver: `customer_channel` subscribes to a
  `{:customer_delivery}` advisory topic and **replays a lower-bound cursor**
  (`committed_deliveries_since/2` over the settlement outbox, `committed_seq`),
  guaranteeing zero-loss delivery.
- **On `refactor/retire-customer`:** the surface was **renamed**
  customer→external/viewer (R067 `customer_feed.ex → external_feed.ex`, R072
  `customer_channel.ex → external_feed_channel.ex`, `customer_app.js →
  viewer_app.js`). Crucially:
  - `customer_feed_adapter.ex` was **DELETED** (`D`), and **no
    `external_feed_adapter.ex` was created**. The renamed `external_feed.ex`
    keeps `snapshot/2` + `replay/3` but **does not** declare `@behaviour
    Ezagent.ExternalMirror.Adapter`, has no `adapter_kind`, no `render/2`. Its
    moduledoc even says external routes must use it "rather than raw
    MessageStore, Publisher, or ExternalMirror streams."
  - So **the retirement DROPPED the `:pull` adapter framing for the external
    surface.** It is now a fully hand-rolled stack (cursor-replay channel + a
    `ExternalFeed` projection module). The retire branch's
    `external_feed_channel` also subscribes to **both** its outbox advisory topic
    **and** `Delivery.session_events_topic` ("collaborative-whiteboard chat:
    ALSO subscribe ... so a NEW chat message re-pushes") — i.e. the external and
    chat live-delivery paths are now *converging by accretion* onto the same
    session-events topic, but as duplicated channel code, not a shared substrate.
- **Substrate footing:** WAS on the substrate (`:pull` adapter); the retirement
  **regressed it off** the substrate.

### hello-page ↔ session

- **App** `ezagent_plugin_hello`. The hello *page* is an agent-generated
  json-render surface; an anonymous visitor views it **through the socialware
  substrate** (`public_view` template → CustomerFeed/ExternalFeed →
  `/socialware/chat`). Hello itself has **no** channel.
- **Write path (builder → session):** `TurnDriver.drive/4` dispatches
  `turn.open → turn.compose → turn.settle`; page refs route to
  `Behavior.Surface.put_version/2` (the page chokepoint). This is **invocation /
  dispatch**, not a feed — and correctly so; it is a *write*, not a comms feed.
- **Read/deliver path (visitor ← session):** hello does **not** own one — it
  reuses socialware's CustomerFeed/ExternalFeed channel. Hello's `mix.exs` deps
  on `ezagent_domain_socialware` *specifically* "for CustomerFeed + public_view
  (anon visitor delivery)" (its own comment).
- **The task names a "hello page-edit/preview channel" — it does not exist as a
  distinct transport.** There are two hello reads, neither a new channel:
  (a) the **operator preview** ("the right-side preview", `hello` gettext
  strings) is a React island rendered inside **`WorldLive`** — the operator sees
  the surface (including an *unapproved* version via `Surface.latest_version/1`)
  through the existing world LiveView, not a hello channel; (b) the **public
  viewer** sees only the approved tree (`Surface.customer_tree/1`, gated on
  `approved`) through socialware's feed channel. So the lead's premise of a
  separate hello preview channel does **not** hold: hello has *no* transport of
  its own — it borrows WorldLive (operator) and the socialware feed (public).
- **Substrate footing:** **NOT** on the ExternalMirror substrate. Its *write*
  path is dispatch (Turn/Surface). Its *read/deliver* path is whatever socialware
  / world provides — i.e. it inherits their footing (today: hand-rolled).
  `git grep ExternalMirror|Publisher|:pull|render/2` over
  `apps/ezagent_plugin_hello/**` returns **nothing**.

### Footing summary

| Surface | Read path | Live deliver path | On ExternalMirror substrate? |
|---|---|---|---|
| chat | `ChatFeed.snapshot` → `MessageStore.chat_visible_recent` (no cursor, windowed) | PubSub `session_events_topic` advisory + re-read snapshot | Declared `:pull` adapter **but bypassed** (registration unused) |
| external (main) | `CustomerFeed.snapshot` → `committed_customer_visible` + Surface | `{:customer_delivery}` advisory + lower-bound cursor **replay** | **Yes** (`CustomerFeedAdapter`, `:pull`) |
| external (retire) | `ExternalFeed.snapshot/replay` → `committed_external_visible` + Surface | `{:external_delivery}` advisory + cursor replay (+ session-events topic) | **No — adapter deleted in retirement** |
| hello | (no own read) reuses socialware feed (public) + WorldLive (operator preview) | (no own channel) inherits world / socialware | **No** (write = Turn/Surface dispatch) |
| world Conversation (operator) | `ConversationData.load_messages` → `MessageStore.recent_in_session` (SSR initial) | **`WorldLive` IS live** — subscribes per-session, `handle_info {:chat_message, …}` on `session_events_topic` | **No** (hand-rolled, a *fourth* consumer of the same topic) |

Net: **(at least) four parallel stacks, exactly as the lead suspected** — and
they have *already started colliding* on one PubSub topic (`session_events_topic`),
which is the tell that they want to be one substrate. The substrate
framing exists, was used once (customer `:pull`), is now dead/bypassed on both
chat and external. The lead's instinct that these are "three hand-rolled
feed/channel stacks" is accurate to the current code.

---

## 3. Dependency-feasibility crux — LEGAL, no cycle

The make-or-break: can chat/hello/external depend *down* onto the adapter
substrate without a cycle?

**In-umbrella deps (from each `mix.exs` on `origin/main`):**

```
ezagent_core                      → (bottom; holds MessageStore + the committed stream)
ezagent_domain_identity           → core
ezagent_domain_external_mirror    → core, identity              ← THE SUBSTRATE (low)
ezagent_domain_session            → core, identity, workspace, external_mirror, pty, agent_bridge, agent
ezagent_domain_socialware         → core, identity, session, external_mirror, ui   ← chat (ChatFeed*) lives HERE
ezagent_plugin_world              → core, agent, agent_bridge, external_mirror, pty, identity, session, workspace
ezagent_plugin_hello              → core, session, socialware, ui, identity, workspace
ezagent_web                       → core, identity, workspace, session, socialware, world, hello, protocol_api, feishu, ...
```

**Verdict — every check passes:**

1. **The substrate deps DOWN only.** `external_mirror → {core, identity}`. It has
   **no** edge to any surface app. So *anything* depending on it is acyclic by
   construction.
2. **socialware ALREADY deps on external_mirror**, and **chat lives in
   socialware**. ⇒ **chat → substrate is legal today, within one app.** No new
   edge needed; the hardest part of the question is already satisfied.
3. **world ALREADY deps on external_mirror.** Legal.
4. **hello deps on socialware** (which deps on external_mirror) and on session
   (which deps on external_mirror). ⇒ transitively legal; could add a direct
   edge with no cycle if it ever needs the substrate directly.
5. **The committed stream is in `ezagent_core`** — below the substrate and below
   every surface. A "substrate over the committed stream" is a legal stack:
   `core (stream) → external_mirror (adapter contract) → session → socialware
   (chat/external feeds) → hello / web`.

**Acyclic gate that enforces this:**
`apps/ezagent_core/test/architecture/im_session_agent_acyclic_test.exs` (the
im→session→agent split gate) plus
`apps/ezagent_core/test/architecture/undeclared_umbrella_dep_test.exs`. The
acyclic gate is **compile-dependency + AST-symbol based** (edges from `mix.exs`
`in_umbrella` deps; symbol refs from the AST `alias`/qualified-call/`%struct{}`
walk — comments/`@moduledoc` strings don't count). The undeclared-dep gate
requires every *hard* ref (`Mod.fun`, `%Mod{}`, `@behaviour`, `use/import`) to be
backed by a declared `in_umbrella` dep. **Both are already satisfied** for
"comms-on-substrate" because the edges already exist; consolidating chat/external
onto the substrate adds *no new app edge*, so it cannot trip either gate.

**Retire-branch confidence:** the DAG above was read on `origin/main`. The
`refactor/retire-customer` branch is **renames + deletes only** (customer→external/
viewer, delete `CustomerFeedAdapter`); it does **not** add or remove any
app-level `in_umbrella` dep. So the layering verdict carries unchanged to the
retire branch — the regression there is the *loss of the adapter declaration*,
not any change to the dependency graph.

**There is no backwards/cyclic dependency. The structure fully supports the
thesis.** The only reason it isn't already unified is *history*, not *layering*:
each surface was built (or retired) as its own feed+channel rather than as an
adapter on the shared substrate.

---

## 4. Recommendation — PARTIAL yes, no relocations needed

**Should comms unify on the adapter substrate? Yes for chat + external; no for
hello's write path; the read/deliver paths should converge.**

The dependency DAG is *already legal*, so this is a **consolidation +
revive-the-framing** task, not a re-layering. Nothing moves between apps.

### What "unified" should look like

One **committed-stream projection + live-delivery** substrate, with chat /
external / (hello's viewer) as adapters/projections on it:

- **Projection (read):** all three already bottom out in `Ezagent.MessageStore`
  (core) + `Behavior.Surface` (session). Keep that. Define a single `:pull`-style
  projection callback `render/2` (or `snapshot/2`) as the *one* contract a comms
  surface implements — exactly what `ExternalMirror.Adapter` `:pull` already
  specifies. Chat's `ChatFeedAdapter.render/2` already proves the shape.
- **Live delivery (the real gap — see §"delivery semantics"):** today every
  surface hand-rolls "subscribe to a PubSub advisory topic + re-read." This is
  the duplicated stack. Lift it into the substrate as a **live `:pull` delivery
  helper** (or a new `:pull_live` kind): "subscribe to the session's
  committed-delivery advisory; on wake-up call the adapter's `render/2`/`replay`;
  push." Both delivery disciplines that exist today (chat's windowed
  snapshot-refresh and external's lower-bound cursor replay) are *parameterized
  instances* of this one helper — choose `replay_from_cursor?` per adapter.
- **Adapters on top:** `ChatFeedAdapter` (windowed, no cursor), `ExternalFeed`
  adapter (cursor replay over the settlement outbox), and hello's viewer (reuses
  external). Each is ~the `render/2` + a delivery-discipline flag; the channel
  code becomes one shared generic channel parameterized by adapter id, instead of
  `chat_feed_channel.ex` + `external_feed_channel.ex` + future ones.

### Delivery semantics — the one substance caveat (why "partial", not "yes")

The substrate's `:pull` kind as written is **on-demand render**, not **live
push**. The browser-facing live updates are *not* part of the substrate today —
they are the hand-rolled channel layer in `ezagent_web`. So "unify on the
substrate" is only fully true once the substrate **owns a live-delivery
contract**, not just `render/2`. The two existing delivery disciplines differ
materially:

- **chat:** no settlement, windowed latest-N, snapshot-refresh on any session
  event. Cheap, self-healing, *not* zero-loss-guaranteed (doesn't need to be —
  it always shows current latest-N).
- **external:** durable settlement outbox, `committed_seq` lower-bound cursor
  replay, **zero-loss guaranteed**. Needed because an external viewer must never
  miss a committed delivery.

A naive "make chat a `:pull` adapter" that papers over this would either
over-engineer chat (forcing the cursor machinery it deliberately dropped — see
ChatFeed moduledoc "P4 drops the keyset cursor ... entirely") or under-deliver
external. **The unification must keep delivery-discipline as an adapter-chosen
parameter.** This is achievable and is the bulk of the real design work; it is
why the recommendation is *partial / staged*, not an unqualified yes.

### hello

Leave hello's **write** path (Turn/Surface dispatch) alone — it is a write, not
a feed, and is correctly modeled. Only its **read/deliver** path should ride the
unified substrate, which it already does *by proxy* (it reuses socialware's
feed). After unification hello inherits the shared substrate for free; no hello
change required beyond the socialware consolidation.

### Required module relocations

**None.** Every app that needs the substrate already declares it (or a parent
that does). The work is *within* `ezagent_domain_socialware` (consolidate
ChatFeed/ExternalFeed onto one projection+delivery substrate; revive the
`:pull` adapter declarations so they are actually registered+used) and *within*
`ezagent_web` (collapse `chat_feed_channel` + `external_feed_channel` into one
adapter-parameterized channel). Optionally, lift the live-delivery helper into
`ezagent_domain_external_mirror` itself as a `:pull` companion so the contract
is co-located with the adapter behaviour — also legal (external_mirror only deps
on core+identity, and `MessageStore`/PubSub live in core).

### Relationship to AnonIngress — SUB-STEP, not superseded

- **AnonIngress** = `EzagentWeb.Socialware.AnonIngress`, a deferred **web-layer**
  extraction of the byte-identical anon-user lifecycle
  (`resolve_caller`/`resolve_anonymous`/`reuse_or_mint`/`mint_fresh`/`join_anon`/
  `render_spa`/`read_valid_cookie`/`put_anon_cookie`/`show` + `Socket.connect`)
  duplicated across `ChatFeedController/Socket` and
  `ExternalFeedController/Socket`. (Source: the `arch_baseline_manifest.exs`
  +8 `cross_file_duplicate_fn_groups` note on the retire branch: "extracting a
  shared `EzagentWeb.Socialware.AnonIngress` is a deferred follow-up (touches
  ChatFeed*), 40→48.")
- It is the **ingress/auth** half of the per-surface web stack (who-are-you →
  mint/join/cookie/token, in the controller + `Socket.connect`). The substrate
  unification's web half is the **live-feed channel** consolidation (collapse
  `chat_feed_channel` + `external_feed_channel` into one adapter-parameterized
  channel that projects the committed stream). **Both halves are web-layer and
  sit on the *same* per-surface stacks** — so this is not "domain vs web";
  AnonIngress and the channel consolidation are *adjacent web-layer concerns on
  the identical files*.
- **Direct answer to the lead's binary: AnonIngress is a SUB-STEP, best done as
  the web-layer pass *of* the unification — not a separate prior PR, and not
  superseded.** When you collapse the two feed channels into one, you are already
  rewriting the very controllers/Sockets whose anon-lifecycle AnonIngress
  factors out; doing AnonIngress in the same pass avoids touching those files
  twice. It is *not* superseded (the anon-mint/cookie logic still has to live
  somewhere after unification), and it is *not* a clean standalone (it touches
  ChatFeed*, which is exactly what the unification touches). If you want a quick
  isolated win first, AnonIngress *can* stand alone (the retire branch proved the
  two ingresses byte-identical), but the cleaner sequencing is to fold it into
  the unification's web pass.

---

## Open questions for the lead

1. **Revert the retirement's adapter-drop, or accept it?** The
   `refactor/retire-customer` branch deleted `CustomerFeedAdapter` (the `:pull`
   registration) and did not re-create it for `ExternalFeed`. Is that a
   deliberate "the adapter framing was never load-bearing, kill it" decision, or
   an accidental regression to hand-rolled? The thesis implies *reviving* it;
   the retire branch is actively moving the *other* way. Which direction wins?

2. **Is `ChatFeedAdapter`'s `:pull` registration meant to be revived or
   deleted?** Right now it is declared but registered by nobody and called by
   nobody (moduledoc admits the channel calls `ChatFeed` directly). It is dead
   either way today — the question is whether it's the seed of the unification or
   cruft to remove.

3. **Live delivery: new kind vs. helper?** Do you want a first-class
   `:pull_live` adapter kind in `ExternalMirror.Adapter` (browser-facing live
   push, distinct from `:push`'s server-to-external and `:pull`'s on-demand
   render), or keep delivery in `ezagent_web` as a shared adapter-parameterized
   channel that *consumes* `:pull` `render/2`? The DAG allows either; it's a
   "where does the live-transport contract live" call.

4. **Keep two delivery disciplines or one?** The retire branch is already nudging
   external + chat toward the same `session_events_topic`. Is the long-term
   target "chat keeps windowed-no-cursor, external keeps cursor-replay, substrate
   parameterizes both," or "everything becomes cursor-replay" (zero-loss
   everywhere, at the cost of giving chat machinery it explicitly dropped)?

5. **Scope of `world` Conversation.** `WorldLive` already *is* a live consumer of
   `session_events_topic` (`handle_info {:chat_message, …}`), so the operator
   Conversation is a fourth hand-rolled delivery path on the same topic — not
   SSR-only. Should it converge onto the unified substrate too (it deps on
   `external_mirror` already, so it *can*), or is the operator surface
   deliberately kept on its own LiveView delivery? Including it makes the
   unification a clean four-into-one; excluding it leaves one stack standing.

---

## Method / provenance

- All file reads via `git show origin/main:<path>` and
  `git show origin/refactor/retire-customer:<path>` (working tree was on an
  unrelated branch; nothing in the tree was trusted).
- Deps read from each app's `mix.exs` `defp deps`.
- Acyclic/undeclared-dep gates:
  `apps/ezagent_core/test/architecture/im_session_agent_acyclic_test.exs`,
  `apps/ezagent_core/test/architecture/undeclared_umbrella_dep_test.exs`.
- Substrate contract:
  `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter.ex`
  (the `:push`/`:pull`/`:request_scoped` kind axis); SPEC
  `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`.
- Committed stream: `apps/ezagent_core/lib/ezagent/message_store.ex`.
- AnonIngress: `arch_baseline_manifest.exs` (`refactor/retire-customer`),
  retire-customer SPEC §5.3/§5.4/§9.
