# SPEC — comms-unify PR-3 (AnonIngress) + PR-4 (world Conversation onto the contract axis)

**Status:** DESIGN (not implementation). Read-only basis; no code changed by this SPEC.
**Basis:** the comms-unify SPEC `docs/together/2026-06-27/specs/unify-comms-on-adapter-substrate.md`
(branch `docs/unify-comms-spec`), which scoped PR-3/PR-4 at a high level (§7 AnonIngress,
§9 world-on-contract-axis), and the merged code on `origin/main` (`9428570f`).
**Predecessors merged:** the substrate contract + external-adapter revival + the
adapter-parameterized `SessionFeedChannel`/`SessionFeedSocket` landed via #1047, and the
participation-profile + IoC source gates landed via #1060 (`2d32ebd3`). This SPEC designs the
**remaining two steps**: PR-3 (AnonIngress) and PR-4 (world Conversation).
**Skills:** `ezagent-developer`, `ezagent-socialware`.
**Read against (all via `git show origin/main:<path>`):** the two feed controllers + three sockets
+ `SessionFeedChannel`, `ChatFeedAdapter`/`ExternalFeedAdapter`, `AnonUser`/`AnonBinding`,
`Membership`, `WorldLive`/`ConversationData`/`ConversationActions`, `MessageStore`, the #1060
`check_invariants` gates, and every `mix.exs` dep set on the path.

---

## 0. Problem in one paragraph

#1047 unified the **live transport** for the browser feeds: `chat_feed_channel` +
`external_feed_channel` collapsed into one adapter-parameterized
`EzagentWeb.Socialware.SessionFeedChannel`, branching on the adapter's
`delivery_discipline/0` + `participation_profile/0`. Two consolidation debts remain. **(PR-3)**
The *ingress/auth half* of those surfaces was NOT collapsed: the anonymous-participant lifecycle
(mint/reuse anon identity → spawn principal → join session as member → mount participation caps →
cookie/token) is still **byte-duplicated** across `ChatFeedController` and `ExternalFeedController`
(the +8 dup groups #1037/#1047 tracked), and the inline caller-resolution that #1047 lifted into
`SessionFeedSocket` is a third copy of the token→caller step. **(PR-4)** `WorldLive` is still the
fourth independent live consumer of the committed stream — it hand-rolls its read
(`ConversationData.load_messages → MessageStore.recent_in_session`) and its delivery
(`handle_info {:chat_message,…}` on `session_events_topic`), riding none of the substrate's
contract. This SPEC designs (a) lifting the anon lifecycle to a **socialware domain primitive**
behind a **thin web shim**, and (b) converging world onto the substrate's **contract + delivery
discipline** while it keeps its **LiveView transport** — "4→1 on the contract axis, not the
transport axis."

---

## 1. Goals / Non-goals

### Goals (G)

- **G1 (PR-3).** ONE domain primitive `admit_anonymous_participant/2` owning the
  mint→spawn→join→mount-caps lifecycle; reusable, testable, cap-correct, fail-closed.
- **G2 (PR-3).** ONE thin web shim `EzagentWeb.Socialware.AnonIngress` owning ONLY
  HTTP/cookie/token + request-context, delegating admission to G1. Both feed controllers and the
  remaining inline socket caller-resolution route through it.
- **G3 (PR-3).** Elimination: no duplicated anon-ingress flow; the +8
  `cross_file_duplicate_fn_groups` collapse to one shim + one domain primitive.
- **G4 (PR-4).** world's session conversation reuses the SAME `:pull` delivery contract
  (subscribe-first / advisory-as-wakeup / re-authorize-on-read / `:snapshot_refresh` re-read)
  and a contract-shaped **gated read**, while keeping its `Phoenix.LiveView` transport, mount,
  assigns, and its own `ConversationData` encoding.
- **G5 (PR-4).** world's *writes* route by the adapter-declared **participation profile**, not by
  `adapter_id` and not by a world-specific special case — honoring the #1060 participation gate.
- **G6 (both).** ZERO new app-level `in_umbrella` edge; both architecture gates and both #1060
  source gates stay green.

### Non-goals (N)

- **N1.** The unified `SessionFeedChannel` read/replay/participation logic itself (merged in
  #1047) — PR-3/PR-4 consume it, they do not re-open it.
- **N2.** Converting world to a `Phoenix.Channel`. world stays a LiveView; convergence is on the
  contract axis only (§4).
- **N3.** hello's write path (`TurnDriver` → `Surface.put_version/2`) — a write/dispatch, untouched.
- **N4.** The anon GC/sweeper, cookie crypto, `ChatFeedAuth` token format, `PublicView` gate
  semantics — all reused verbatim; PR-3 only relocates the *orchestration*, not these parts.
- **N5.** History paging UX, advisory-topic mechanism, the legacy topic aliases (the channel
  already accepts `socialware:chat_feed:*` / `socialware:external:*` — kept).

---

## 2. PR-3 — current footing: the duplicated anonymous-ingress flow

### 2.1 Where the duplication lives (confirmed byte-for-byte)

`ChatFeedController.show/2` and `ExternalFeedController.show/2` contain a near-identical private
function cluster. Confirmed identical-by-signature on `origin/main`:

| Function | Chat controller | External controller | Identical? |
|---|---|---|---|
| `resolve_caller/2` | ✓ | ✓ | yes |
| `resolve_anonymous/2` (ensure_live → public_view gate → reuse_or_mint) | ✓ | ✓ | yes |
| `reuse_or_mint/2` (cookie → touch → reaping/error → mint_fresh) | ✓ | ✓ | yes |
| `mint_fresh/2` (mint → spawn → touch → join_anon → cookie) | ✓ | ✓ | yes |
| `join_anon/2` (dispatch `session.join` AS the anon → mount caps) | ✓ | ✓ | yes |
| `mount_anon_participation/2` (`Membership.mount_participation_caps`) | ✓ | ✓ | yes |
| `optional_current_entity/1` | ✓ | ✓ | yes |
| `read_valid_cookie/2`, `put_anon_cookie/2`, `secure_cookie?/1` | ✓ | ✓ | yes |
| `parse_session/1`, `bounce/1`, `bad_request/2` | ✓ | ✓ | yes |

The only legitimate per-surface differences are: the SPA shell `page/2`
(`data-socket-path` + `data-topic-prefix` + title), and the external controller's extra
`download/2` + legacy 301 redirects. **Everything in the anon lifecycle is duplicate.**

The third copy: `SessionFeedSocket.connect/3` re-implements the token→caller step inline
(`ChatFeedAuth.verify` + `parse_session`), and #1047's codex noted this inline caller-resolution
now lives in the socket. The two legacy sockets (`ChatFeedSocket`, `ExternalFeedSocket`) carry the
SAME `connect/3` body. That is a fourth/fifth copy of the token-verify step.

### 2.2 The lifecycle decomposed (what the primitive owns vs the shim owns)

The whole flow splits cleanly into a **domain half** (identity/spawn/membership orchestration, no
HTTP) and a **web half** (cookie/token/conn, no domain orchestration):

```
show(conn, %{"session_uri"})                                   [WEB]   parse + dispatch
 └─ resolve_caller(conn, session_uri)                          [WEB]   optional_current_entity?
     ├─ signed-in  → render_spa(token for principal)           [WEB]   token + SPA shell
     └─ anonymous  → resolve_anonymous                         [WEB→DOMAIN]
          ├─ ensure_live(session_uri)                          [DOMAIN] (demand-spawn)
          ├─ public_view?(session_uri) gate                    [DOMAIN] fail-closed
          ├─ read_valid_cookie(conn) → reuse_candidate         [WEB]    cookie verify
          ├─ admit_anonymous_participant(session_uri, cand)    [DOMAIN] mint→spawn→join→caps
          └─ on {:minted,_} set cookie; render_spa(token)      [WEB]    cookie sign + SPA shell
```

The domain primitive owns the **whole** `ensure_live → public_view gate → reuse-or-mint
(touch + reaping) → spawn_principal → join-AS-anon → mount_participation_caps` sequence.
The web shim owns ONLY: cookie read/verify → pass the verified candidate in; cookie sign on a
fresh mint; `ChatFeedAuth` token issue; the conn/SPA-shell. (`optional_current_entity/1` stays
web — it reads the `:browser` session cookie.)

---

## 3. PR-3 design — the socialware domain primitive + the thin web shim

### 3.1 Placement — the deliberate deviation from "where session membership lives"

The lead's shape says place the primitive "where session membership lives." Session membership
lives in `Ezagent.Behavior.Session.Membership` in **`ezagent_domain_session`**. But the anon
lifecycle needs `Ezagent.Socialware.AnonUser.mint_for_public_session/1`,
`Ezagent.Socialware.AnonBinding.touch/3`, and `Ezagent.Socialware.PublicView.public_view?/1` —
all in **`ezagent_domain_socialware`**.

**Dep direction (read from `mix.exs`, `origin/main`):** `socialware → session` (socialware
declares `{:ezagent_domain_session, in_umbrella: true}`; session does NOT dep on socialware).
Therefore `Membership` (session) **cannot** call `AnonUser` (socialware) — that is the reverse
edge, a Mix cycle. The orchestrator can only live **above** both, i.e. in **socialware**, which
reaches `AnonUser`/`AnonBinding`/`PublicView` locally AND `Membership` (session, below) AND
`Ezagent.Entity.spawn_principal` / `Ezagent.Invocation.dispatch` (core, below).

**Resolution:** place the primitive in **socialware** —
`Ezagent.Socialware.AnonAdmission.admit_anonymous_participant/2`. This satisfies the lead's intent
*in spirit*: the **anon-membership lifecycle** is a socialware concept (`AnonUser`/`AnonBinding`
already live there); session owns generic membership, socialware owns the anon flavor of joining
it. The deviation is forced by the DAG, not by preference. (Task point 2 itself says "socialware/
session domain primitive" — socialware is in scope.)

### 3.2 The domain primitive

```elixir
# Ezagent.Socialware.AnonAdmission   — ezagent_domain_socialware (domain, no HTTP)

@doc """
Admit an anonymous visitor to a public-view session as a real, cap-correct member.

Owns the full lifecycle: ensure the session is live (demand-spawn), gate on public_view,
reuse the cookie-verified candidate if its binding is healthy, else mint a fresh anon holding
its OWN narrow session.join cap (granted_by the session owner — #154, no system principal),
spawn its Kind, join AS THE ANON, and best-effort mount its participation tier.

`reuse_candidate` is the anon entity URI the WEB layer already recovered from a verified
signed cookie (nil if none / invalid). The primitive NEVER touches the cookie — it trusts a
%URI{} candidate as "the cookie verified to this anon for this session."

Returns the admitted caller URI plus whether it was reused or freshly minted, so the web shim
knows when to (re)issue the cookie.
"""
@spec admit_anonymous_participant(URI.t(), URI.t() | nil) ::
        {:ok, URI.t(), :reused | :minted} | {:error, term()}
def admit_anonymous_participant(%URI{scheme: "session"} = session_uri, reuse_candidate)
```

Body (lifted verbatim from the controllers, now in one place):

```
_ = Ezagent.SpawnRegistry.ensure_live(session_uri)          # cold-link revival
if PublicView.public_view?(session_uri) do
  case reuse_candidate do
    %URI{} = anon ->
      case AnonBinding.touch(anon, session_uri, now) do
        {:ok, _}              -> :ok = Entity.spawn_principal(anon); {:ok, anon, :reused}
        {:error, {:reaping,_}}-> mint_fresh(session_uri)       # do NOT resurrect (§4.1a)
        {:error, _}           -> mint_fresh(session_uri)       # fail closed → mint
      end
    nil -> mint_fresh(session_uri)
  end
else
  {:error, :not_public}                                        # web maps → bounce(/login)
end

# mint_fresh/1 (fail-closed `with`):
with {:ok, anon} <- AnonUser.mint_for_public_session(session_uri),  # holds OWN session.join cap
     :ok          <- Entity.spawn_principal(anon),                  # hydrate caps_json → live :caps
     {:ok, _}     <- AnonBinding.touch(anon, session_uri, now),
     :ok          <- join_anon(session_uri, anon) do               # dispatch + mount caps
  {:ok, anon, :minted}
else other -> {:error, other} end
```

**Two invariants pinned in the primitive's contract (codex will check these):**

- **INV-1 — join AS the anon, no system principal (#154).** `join_anon/2` dispatches
  `Ezagent.URI.with_action(session_uri, :session, :join)` with `mode: :call`,
  `args: %{member: anon}`, **`ctx: %{caller: anon, reply: :ignore}`**. The anon was minted holding
  exactly one `cap(:session, Behavior.Session, :join, instance: <session>)` whose `granted_by` is
  the session owner; step 5.5 (`granted_via_holds_cap?`) authorizes from the anon's own `:caps`
  slice. `:call` so membership is committed before the SPA renders (the live channel re-reads on
  connect). **No `system://` principal anywhere.**
- **INV-2 — caps mount is best-effort; mint/spawn/join are fail-closed.** After a successful join,
  `Membership.mount_participation_caps(session_uri, anon)` runs best-effort: a failed mount
  degrades the anon to "observe via membership" (read-only) and **does not** fail admission. By
  contrast a failed mint/spawn/join fails the whole admission closed (`{:error, _}` → web bounce).
  This matches the merged controllers exactly (`mount_anon_participation/2` returns `:ok`
  unconditionally inside the `with`).
- **INV-2a — fix the reuse-path spawn while lifting (codex MED).** The merged controllers'
  *reuse* path does `:ok = Ezagent.Entity.spawn_principal(anon_uri)` — a hard match that **crashes**
  the request if spawn fails, instead of fail-closing. When the lifecycle moves into
  `AnonAdmission`, the reuse-path spawn becomes a `with`-clause that on failure falls through to
  `mint_fresh/1` (a returning visitor whose Kind cannot respawn is treated as needing a fresh
  identity), so the whole primitive is uniformly fail-closed — never a process crash. This is a
  behavioral improvement the extraction should carry, called out so the PR is not a byte-for-byte
  move that preserves the crash.

`render`-side authorization is unchanged: the anon reads because it is a real member, via the
byte-unchanged `Membership.authorize/2` predicate. No new "non-member can read" path is created.

### 3.3 The thin web shim

```elixir
# EzagentWeb.Socialware.AnonIngress   — ezagent_web (web-layer only)

# Controller-side: resolve a caller for an HTTP request (signed-in OR mint/reuse anon).
@spec resolve_conn(Plug.Conn.t(), URI.t()) ::
        {:signed_in, URI.t(), Plug.Conn.t()}        # principal, conn unchanged
      | {:anonymous, URI.t(), Plug.Conn.t()}        # anon caller, conn carries Set-Cookie if minted
      | {:bounce, Plug.Conn.t()}                     # non-public / failure → /login
def resolve_conn(conn, session_uri)

# Socket-side: recover a TRUSTED caller from a server-minted token (no cookie/conn).
@spec resolve_token(token :: String.t(), URI.t()) :: {:ok, URI.t()} | :error
def resolve_token(token, session_uri)
```

`resolve_conn/2` flow: `optional_current_entity(conn)` → if `%URI{}` return `{:signed_in,…}`;
else `read_valid_cookie(conn, session_uri)` → candidate; call
`AnonAdmission.admit_anonymous_participant(session_uri, candidate)`; on `{:ok, anon, :minted}`
sign + `put_anon_cookie`, return `{:anonymous, anon, conn}`; on `{:ok, anon, :reused}` return
`{:anonymous, anon, conn}` (no cookie change); on `{:error, _}` → `{:bounce, conn}`.

The shim retains ONLY: `optional_current_entity/1`, `read_valid_cookie/2`, cookie sign +
`put_anon_cookie/2`, `secure_cookie?/1`, `ChatFeedAuth` issue/verify, `parse_session/1`. It calls
**no** `AnonUser`/`AnonBinding`/`Entity`/`Invocation` directly — those moved into the primitive.

**Controller-vs-socket split (base-SPEC §12 LOW, adopted):** `resolve_conn/2` (controller, returns
a conn) and `resolve_token/2` (socket `connect`, returns a bare caller) are SEPARATE entries — one
helper does not pretend to return a conn for a socket connect. Only `resolve_conn/2` calls the
domain primitive (an HTTP visitor minting an identity); `resolve_token/2` is identity recovery
only (the token was minted earlier, during the controller render).

### 3.4 What collapses

- `ChatFeedController.show/2` → parse → `AnonIngress.resolve_conn/2` → `render_spa` (per-surface
  `page/2` only). Same for `ExternalFeedController.show/2` (its `download/2` + legacy redirects
  stay). The +8 duplicate anon-lifecycle groups → one `AnonAdmission` + one `AnonIngress`.
- `SessionFeedSocket.connect/3` token-verify → `AnonIngress.resolve_token/2`. The two legacy
  sockets (`ChatFeedSocket`/`ExternalFeedSocket`) likewise delegate `connect/3` to
  `resolve_token/2` (kept as thin shells until their routes retire — out of PR-3 scope, but the
  duplicate body is eliminated now).

### 3.5 IoC gate compliance (#1060 Gate 2)

`AnonIngress` is identity/cookie/token only — it references **no** `Ezagent.ExternalMirror.*`
module, so the #1060 web→external_mirror IoC source gate is trivially satisfied. (The adapter
resolution stays where #1047 put it: the `Module.concat`/`apply` seam in `SessionFeedSocket`/
`SessionFeedChannel`.)

---

## 4. PR-4 — world Conversation onto the contract axis

### 4.1 Current footing: world is the fourth hand-rolled consumer

| Concern | world today | substrate equivalent |
|---|---|---|
| Read | `ConversationData.load_messages → MessageStore.recent_in_session/2` (direct, in the data module) | adapter `render_authorized/2` over the committed stream |
| Live deliver | `WorldLive.handle_info({:chat_message, src, msg})` → `ConversationData.message_row` → `push_event "chat:message"`; subscribe `Behavior.Session.session_events_topic` in `ensure_session_subscribed/2` | adapter `live_topics/1` + `:snapshot_refresh` re-read on advisory |
| Authz | route-gated operator surface; reads sessions it is NOT a member of; sees `:operator_only` messages | (see §4.2 — chat adapter is the WRONG projection) |
| Write | `ConversationActions.send_message/4` → `Invocation.dispatch(:session :send, caller, caps)` | participatory write path |
| Transport | `Phoenix.LiveView` (PTY, audit, authz, layout all share the socket) | `Phoenix.Channel` (carved OUT — N2) |

### 4.2 Why world CANNOT reuse `ChatFeedAdapter` — two independent blockers (verified)

The naive reading ("world reuses `ChatFeedAdapter.render_authorized`") **regresses the operator**.
The operator Conversation and the chat feed are NOT the same projection on two axes, both verified
against `origin/main`:

1. **Authorization.** `ChatFeed.snapshot/2` runs `with :ok <- authorize(session_uri, caller)`
   (live per-session `Membership.authorize/2`) and returns `{:error, :unauthorized}` for a
   non-member. The **operator views sessions it is not a member of** (an admin surface, gated at
   the route, not by session membership). Reuse → operator gets empty for every non-member
   session. **This axis alone kills the reuse.**
2. **Visibility.** `chat_visible_recent/2` filters `m.visibility == :external_visible` — an
   `:operator_only` message never appears. world reads `recent_in_session/2` (no visibility
   filter): **the operator is supposed to see `:operator_only` messages.** Reuse silently drops
   them.

So consuming the chat adapter is **incorrect**, not merely suboptimal. The coherent convergence is
contract-shaped but with the **operator's own projection**.

### 4.3 Design — an operator-profile adapter, world-hosted, on the SAME contract

world reuses the **contract + delivery discipline**, not the chat adapter:

- **Reuse (the contract axis):**
  - the `Ezagent.ExternalMirror.Adapter` `:pull` behaviour shape:
    `render_authorized/2`, `live_topics/1`, `delivery_discipline/0`, `participation_profile/0`;
  - the `:snapshot_refresh` **delivery discipline** — subscribe-first (subscribe
    `live_topics/1` BEFORE first read), advisory-as-wakeup (every PubSub message is a re-read
    trigger, never trusted as payload), re-read current window on each advisory,
    re-authorize-on-read (re-run the operator's authz on every read so a revoked operator clears);
  - the contract guarantee: render returns **raw `Ezagent.Message.t()`** (proven by
    `ChatFeed.snapshot`'s `{:ok, %{messages: [Ezagent.Message.t()], page: map()}}` spec), so any
    consumer re-encodes — world keeps its own `ConversationData.message_row` encoding unchanged.
- **Keep (the transport axis — N2):**
  - `WorldLive` stays a `Phoenix.LiveView`; mount, assigns, `push_event "world:state"` /
    `push_event "chat:message"`, PTY/audit/authz/layout handlers — all unchanged;
  - the React `Conversation.tsx` island and its richer row shape (`sender_kind`, `render`,
    `render_css`, attachment download tokens, `members`, `routing_rules`, `sessions`) — unchanged;
  - world's own paging (`load_older` / `MessageStore.older_than`) and member/routing reads — these
    are NOT feed-render, they stay in `ConversationData` (see §4.5 elimination scoping).

- **The new module — `Ezagent.World.ConversationFeedAdapter`, hosted in `ezagent_plugin_world`:**
  a `:pull` `ExternalMirror.Adapter` with `adapter_id: "world_conversation"`,
  `delivery_discipline: :snapshot_refresh`, `participation_profile: :participatory`,
  `live_topics/1 = [Behavior.Session.session_events_topic(session_uri)]` (world's existing
  subscription), and `render_authorized/2` = the **operator projection**:
  `MessageStore.recent_in_session/2` (all visibilities) gated by a **concrete operator
  authorization** (see §4.3a), NOT session membership. `WorldLive` resolves it and drives the
  discipline.

#### 4.3a Operator authorization is load-bearing — the projection MUST NOT be left at "route-level" (codex HIGH)

The operator projection reads `recent_in_session/2` with **no visibility filter** — it includes
`:operator_only` messages. The `/sessions` route today is gated by `RequireEntity` only (NOT
`require_admin`), and `WorldLive`'s session list is **workspace-wide live sessions**, not
membership-filtered (`world_live.ex:703-704` → `Listing`). So an unfiltered operator projection
behind only `RequireEntity` would **leak `:operator_only` content to any authenticated workspace
user** — a regression relative to the chat surface's per-message gating. The SPEC's earlier
"gated by route-level authority" phrasing was underspecified; this is the load-bearing decision:

- `ConversationFeedAdapter.render_authorized(session_uri, caller)` MUST run an **explicit operator
  capability / admin check** for `caller` on `session_uri` (e.g. an operator/admin cap subject, or
  the session-owner/operator predicate the world surface already implies), and return
  `{:error, :unauthorized}` otherwise — fail-closed, re-checked on every read (so a revoked
  operator clears mid-session, exactly like the chat adapter re-authorizes).
- The check is the adapter's `render_authorized/2` body, not the HTTP route — it travels with the
  contract and is re-run on every advisory re-read. The route guard stays as defense-in-depth.
- **Open question §6.6** asks the lead to name the exact operator/admin predicate (the codebase
  has no `require_admin` on `/sessions` today; PR-4 must introduce the cap-level gate, it cannot
  inherit one). This is a prerequisite, not a detail: shipping the unfiltered projection without
  it is a `:operator_only` disclosure bug.

  **Why world-hosted (recommended), not socialware:** `ezagent_plugin_world` already deps on
  `ezagent_domain_external_mirror` (the behaviour) and `ezagent_core` (`MessageStore`) — it can
  implement the contract **directly**, with **no new app edge** and no registry round-trip for its
  own read. world does NOT dep on `ezagent_domain_socialware` (verified — its `mix.exs` lists
  external_mirror + session, not socialware), so it could not reach a socialware-hosted operator
  adapter without a new edge anyway. World-hosting also makes "world IS a contract implementor"
  literal. (Open question §6.3: whether to register it in the boot registry or call it directly —
  for world's own read it can call its own module directly; the registry buys nothing for a
  same-app reach. We must NOT bake operator authz into the membership-gated `read_only`
  `ChatFeedAdapter`.)

### 4.4 The #1060 participation-profile finding — world's writes too

#1060 made `SessionFeedChannel`'s write handlers (`post`/`join`/`history`) route by the
adapter-declared `participation_profile/0`, NOT by `adapter_id == "external_feed"`; the
`check_invariants` Gate 1 fails if any `handle_in` branches on that adapter_id. The same principle
applies to world's writes once world is a contract implementor:

- world's conversation write path (`ConversationActions.send_message/4` / `chat.send`,
  `load_older`, `mark_displayed`) is the **participatory** surface. With the operator adapter
  declaring `participation_profile: :participatory`, world's write authority is keyed off **that
  profile** (the adapter's declared participation), not off `adapter_id` and not off a
  world-special-case branch.
- Concretely: `send_message/4` keeps dispatching `:session :send` **AS the operator**
  (`ctx: %{caller, caps}` — unchanged authz), but the *gating decision* "is this surface allowed
  to post?" reads `participation_profile/0`, parallel to the channel. A `:read_only` adapter's
  surface refuses the write; `:participatory` permits it. This keeps the participation axis single-
  sourced (the adapter declaration) across BOTH transports (channel and LiveView).
- The PR-4 regression test asserts world's write path does NOT branch on `adapter_id` (mirrors
  the #1060 Gate 1 tripwire, extended to world).

### 4.5 Elimination criterion (PR-4)

world stops being an independent feed-render *implementation*:

- **E-W1.** `WorldLive`'s session read/deliver constructs its message window ONLY through the
  contract (`ConversationFeedAdapter.render_authorized/2` + the `:snapshot_refresh` re-read on
  advisory) — no direct `MessageStore.recent_in_session/2` call survives in the *transport/LiveView
  layer*.
- **E-W2.** The direct `MessageStore.recent_in_session/2` read appears ONLY in the **adapter
  impl** (`ConversationFeedAdapter`), i.e. the contract chokepoint — never in `WorldLive`'s
  `handle_info`/`handle_params`. (Refines base-SPEC E3 "ONLY in socialware" → "ONLY in adapter
  impls", since world hosts its own.)
- **E-W3.** world's writes route by `participation_profile/0`; no `adapter_id` branch in the world
  write path (#1060 Gate 1, extended). **The #1060 `check_invariants` Gate 1 today only scans
  `SessionFeedChannel`** (`ezagent.check_invariants.ex:348-379`); world's `chat.send` path
  (`conversation_actions.ex`) is NOT covered. PR-4 MUST add an **actual checker** — either extend
  Gate 1's scan to include `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex`,
  or add a sibling world-specific source gate — so E-W3 is enforced, not merely asserted in prose
  (codex MED).
- **Carve-out (kept, NOT eliminated):** `load_older`/`MessageStore.older_than` (history paging,
  base-SPEC N3) and `member_options`/`list_session_routing_rules` (members + routing, not feed
  render) stay in `ConversationData` — they are not the live feed window and are out of contract
  scope.

---

## 5. Dep-DAG legality (both PRs) — ZERO new app edge

In-umbrella deps read from each `mix.exs` (`origin/main`):

```
ezagent_core                   → (bottom; MessageStore, Entity, Invocation, SpawnRegistry)
ezagent_domain_identity        → core
ezagent_domain_external_mirror → core, identity            ← Adapter behaviour + AdapterRegistry
ezagent_domain_session         → core, identity, …, external_mirror   ← Membership, session_events_topic
ezagent_domain_socialware      → core, identity, session, external_mirror, ui   ← AnonUser/AnonBinding/PublicView/ChatFeed
ezagent_plugin_world           → core, agent, agent_bridge, external_mirror, pty, identity, session, workspace
ezagent_web                    → …, session, socialware, world, hello, …   ← controllers/sockets/channel/AnonIngress
```

| Addition | App | Reaches | New edge? |
|---|---|---|---|
| PR-3 `AnonAdmission` primitive | socialware | `AnonUser`/`AnonBinding`/`PublicView` (local), `Membership` (session ↓), `Entity`/`Invocation`/`SpawnRegistry` (core ↓) | **No** — all already-declared deps |
| PR-3 `AnonIngress` web shim | ezagent_web | `AnonAdmission`/`ChatFeedAuth` (socialware ↓), `AnonCookie` (web), `Membership` (session ↓) | **No** — web already deps socialware+session |
| PR-4 `ConversationFeedAdapter` | ezagent_plugin_world | `ExternalMirror.Adapter` behaviour (external_mirror ↓), `MessageStore` (core ↓), `session_events_topic` (session ↓) | **No** — world already deps external_mirror+core+session |
| PR-4 `WorldLive` drives the adapter | ezagent_plugin_world | its OWN `ConversationFeedAdapter` (same app) | **No** |

**Gates:** the acyclic gate (`im_session_agent_acyclic_test.exs`) is compile-dep + AST-symbol
based; the undeclared-dep gate (`undeclared_umbrella_dep_test.exs`) requires every hard ref backed
by a declared dep. Both PRs add NO new app edge and every hard ref is within an already-declared
dep → neither gate trips. **#1060 Gate 1** (participation writes) is honored by §4.4; **#1060 Gate
2** (web→external_mirror IoC) is honored by §3.5 (AnonIngress touches no ExternalMirror module).

**Critical dep facts that shaped the design (both forced, not chosen):**

1. `socialware → session` (one-directional) ⇒ the anon primitive **must** live in socialware, NOT
   in session's `Membership` (session cannot reach `AnonUser`).
2. `world` does **not** dep on `socialware` ⇒ world **must** host its own operator adapter (it
   cannot reach `ChatFeedAdapter`); and even if it could, §4.2 forbids reusing it.

---

## 6. Open questions for the lead

1. **Primitive name + module.** `Ezagent.Socialware.AnonAdmission.admit_anonymous_participant/2`
   proposed. Alternative: fold onto an existing socialware membership-facade module if one is
   preferred as the anon-lifecycle home. Recommendation: a dedicated `AnonAdmission` module (the
   lifecycle is cohesive and testable in isolation).
2. **Operator-adapter registration.** PR-4's `ConversationFeedAdapter` is world-hosted and called
   directly by `WorldLive` for its own read — it needs **no** boot registration for that. But the
   base SPEC's open question on "who declares the `:pull` adapters at boot" (socialware-owned
   `adapters/0` vs a dedicated micro-plugin) now also covers whether the operator adapter should be
   *additionally* registered (for symmetry / future external consumers). Recommendation: keep it
   unregistered (direct same-app call) unless an off-world consumer appears — the registry round-
   trip buys nothing for a same-app read and the plugin-isolation north-star is unaffected.
3. **PR ordering / gate scope.** PR-3 and PR-4 are independent (web-ingress vs world-LiveView, no
   shared file). Either can land first. If PR-4 slips, the base-SPEC elimination gate stays scoped
   to channels (E1/E2/E4) and adds E-W1..3 at PR-4 — world remains a documented carve-out until
   then. Recommendation: PR-3 first (smaller, pure web/socialware refactor), PR-4 second.
4. **`participation_profile` for world writes — depth.** §4.4 routes the *gating decision* by
   `participation_profile/0` while keeping the operator's existing `:session :send` dispatch authz.
   Confirm the lead wants the participation gate as a thin "may this surface post?" check (parallel
   to the channel) rather than a deeper rework of `ConversationActions` authz. Recommendation: thin
   gate only — the authz (caps) is already correct; this PR only single-sources the participation
   axis.
5. **Legacy sockets.** `ChatFeedSocket`/`ExternalFeedSocket` are kept as thin shells delegating to
   `AnonIngress.resolve_token/2` (their routes still exist). Confirm they should NOT be deleted in
   PR-3 (route retirement is a separate concern; PR-3 only de-duplicates their bodies).
6. **Operator authorization predicate (PR-4, codex HIGH — §4.3a).** The operator projection is
   unfiltered (`recent_in_session`, includes `:operator_only`) and `/sessions` is `RequireEntity`
   only — no `require_admin` exists today. The lead MUST name the exact operator/admin cap or
   predicate `ConversationFeedAdapter.render_authorized/2` enforces, OR confirm operator_only
   exposure to any authenticated workspace user is intended (it almost certainly is not).
   Recommendation: a dedicated operator/admin cap subject checked fail-closed in the adapter; PR-4
   introduces it. This blocks PR-4 merge — it is a disclosure bug otherwise.

---

## 7. Codex adversarial-review verdict

**Overall: SOUND-WITH-FIXES.** Static review (no build) against `origin/main` via the codex
companion. Per-question dispositions (codex citations preserved):

- **Q1 — PR-3 placement: SOUND.** socialware deps core+session (`socialware/mix.exs:31,33`); session
  does NOT dep socialware (`session/mix.exs:31-67`) → socialware can legally reach `AnonUser`/
  `AnonBinding` (local), `Membership` (session), `Entity`/`Invocation` (core); session canNOT host
  the primitive. Cap model correct: anon join cap `granted_by` owner/admin, not `system://`
  (`anon_user.ex:99-105,142-150`); controllers join AS the anon (`chat_feed_controller.ex:177-185`;
  `external_feed_controller.ex:188-194`). Confirms §3.1/§3.2/INV-1.
- **Q2 — PR-3 invariants: SOUND-WITH-FIXES.** INV-1 + INV-2 faithful to the merged controllers.
  **FIX FOLDED (§3.2 INV-2a):** the *reuse* path uses `:ok = Entity.spawn_principal(...)`
  (`chat_feed_controller.ex:122-127`; external `:145-148`) — a hard match that crashes on spawn
  failure instead of fail-closing. The primitive makes reuse-path spawn fall through to
  `mint_fresh/1`.
- **Q3 — PR-4 contract-reuse + keep LiveView: SOUND-WITH-FIXES.** Coherent; forces NO transport
  change (world already subscribes-before-read, `world_live.ex:69-96,722-728`). Both blockers
  CONFIRMED: `ChatFeedAdapter` is read-only (`chat_feed_adapter.ex:100-105`) over membership-gated
  `ChatFeed.snapshot` (`chat_feed.ex:119-135`); `chat_visible_recent` filters `:external_visible`
  (`message_store.ex:274-278`) unlike `recent_in_session` (`message_store.ex:146-148`).
  World-hosted adapter dep-legal (`world/mix.exs:33-40` — external_mirror+core+session, not
  socialware). **FIX FOLDED (§4.3a + OQ §6.6):** operator authority was underspecified —
  `/sessions` is `RequireEntity` only, NOT `require_admin` (`router.ex:35-67`); unfiltered
  projection would leak `:operator_only` to any authenticated workspace user.
- **Q4 — PR-4 #1060 participation routing: SOUND-WITH-FIXES.** Principle matches
  `SessionFeedChannel` (`session_feed_channel.ex:42-60,72-81`). **FIX FOLDED (E-W3):** the #1060
  gate scans only `SessionFeedChannel` (`ezagent.check_invariants.ex:348-379`); world `chat.send`
  has no profile gate (`conversation_actions.ex:34-37,140-158`) — PR-4 must add an actual world
  checker.

**Missed issues raised by codex (all folded above):**
- **HIGH** — unfiltered operator projection leaks `:operator_only` unless PR-4 defines a concrete
  operator/admin/cap gate; session list is workspace-wide, not membership-filtered
  (`world_live.ex:703-704`; `listing.ex:23-24`). → §4.3a, OQ §6.6.
- **MED** — #1060 gate does not cover world; E-W3 needs a real checker. → E-W3.
- **MED** — reuse-path spawn crash should be fixed during extraction. → INV-2a.

No finding was UNSOUND; PR-3 placement is fully sound, PR-4's design is sound but gated on the
operator-authz predicate (OQ §6.6) before it can merge.

---

## Method / provenance

- All reads via `git show origin/main:<path>` (`9428570f`) and `git show 2d32ebd3` (#1060). No
  working-tree trust.
- PR-3 footing:
  `apps/ezagent_web/lib/ezagent_web/controllers/socialware/{chat_feed,external_feed}_controller.ex`;
  `apps/ezagent_web/lib/ezagent_web/socialware/{chat_feed,external_feed,session_feed}_socket.ex`;
  `apps/ezagent_domain_socialware/lib/ezagent/socialware/{anon_user,anon_binding}.ex`;
  `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex`
  (`mount_participation_caps/2`, `provision_invited_join_authority/3`).
- PR-4 footing:
  `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`
  (`ensure_session_subscribed/2`, `handle_info {:chat_message,…}`);
  `apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex`
  (`load_messages → MessageStore.recent_in_session`, `load_older`, `message_row`);
  `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex` (`send_message/4`);
  `apps/ezagent_domain_socialware/lib/ezagent/socialware/chat_feed.ex`
  (`snapshot/2` membership gate + `chat_visible_recent` `:external_visible` filter);
  `apps/ezagent_core/lib/ezagent/message_store.ex`
  (`recent_in_session/2` unfiltered vs `chat_visible_recent/2` filtered);
  `apps/ezagent_domain_socialware/lib/ezagent/socialware/chat_feed_adapter.ex` (the contract shape).
- Contract + gates:
  `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter.ex`
  (`render_authorized/2`, `live_topics/1`, `delivery_discipline/0`, `participation_profile/0`,
  optional `post/3`,`join/2`,`history/2` — #1060);
  `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_registry.ex`;
  `apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.ex`
  (#1060 Gate 1 participation-profile, Gate 2 web→external_mirror IoC).
- Dep edges: every `apps/*/mix.exs` `deps/0` (`origin/main`).
