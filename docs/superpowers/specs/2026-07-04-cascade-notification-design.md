> **⚠️ SUPERSEDED (2026-07-04).** This S1-cascade-first spec is replaced by
> **`2026-07-04-membership-cap-unification-cascade-design.md`** (the "S3-first"
> approach). Codex adversarial review of this spec showed the cascade's whole
> difficulty (affected-principal indirection, session-`:members` re-fetch, the
> removal-notify gap, the reverse-lookup) is rooted in the **membership/capability
> incoherence** this spec rides on top of rather than fixes. The lead chose to
> unify membership into the capability model FIRST, after which cascade becomes a
> trivial rider (`affected_principals` is always `[X]`, removal-notify falls out
> symmetrically). Read this document ONLY for context and the carried-over codex
> findings; implement the successor spec. Do NOT implement this one.

# S1: Cascade Notification — Design Spec (SUPERSEDED)

**Status:** SUPERSEDED — see banner above. (Originally: Design brainstorm → **spec** → plan.)
**Scope:** S1 ONLY (see §"Out of scope / future specs"). Single-implementation-plan
sized.
**Date:** 2026-07-04

---

## 1. Problem & Goal

### Problem

When an entity **X** changes, the entities that **manage or own X** are not told.

Motivating case: user **B** pulls user **A**'s cc agent into **B**'s session. A's agent
then runs on **A**'s credential inside B's session — and **A is never notified** that
their agent (and thus their credential) was pulled into someone else's session. More
generally: a cap granted/revoked involving X, or a change to X's session membership,
is invisible to X's owners/managers.

The platform already has the delivery substrate for "something about entity X changed"
— `Ezagent.SliceChange` broadcasts `esr:entity:<X>:slice_changed` after every
persisted slice mutation (`apps/ezagent_core/lib/ezagent/slice_change.ex`). What is
missing is a component that, on such a change, **resolves who manages/owns the
affected entity and notifies them** — i.e. a *cascade* from the changed entity to its
responsibility holders.

### Goal

Add a **`CascadeNotifier`** — a subscriber on the existing per-entity `slice_changed`
stream that, for each cascade-worthy change, resolves the **manage/owner holders of
the affected principal(s)** (ONE level, no transitive walk) and notifies each via the
existing `Ezagent.Notifications` user inbox
(`apps/ezagent_core/lib/ezagent/notifications.ex`).

**Coherence line (the acceptance sentence for the motivating case):**
> When B pulls A's agent into B's session, the session's `:members` slice changes;
> CascadeNotifier resolves the owners/managers of the *members* the slice references
> — which includes A (owner of A's agent) — and notifies A. **A is notified.**

### Non-goals of the design (kept deliberately simple in v1)

- Not a new lifecycle hook. `CascadeNotifier` is *another subscriber* on the stream
  `SliceChange` already publishes — it stays OFF the dispatch hot path.
- Not a new notification transport. It calls the existing `Ezagent.Notifications.notify/2`.
- Not transitive. A→B→C: A's change notifies B (one level), never C.

---

## 2. Architecture

```
   dispatch mutates X's slice
            │
            ▼
   Kind.Server.commit_and_notify/3        (apps/ezagent_core/lib/ezagent/kind/server.ex)
            │  (post-snapshot)
            ▼
   Ezagent.SliceChange.emit/1             (security-minimal 5-key envelope)
            │  Phoenix.PubSub.broadcast
            ▼
   topic esr:entity:<X>:slice_changed
            │
     ┌──────┴───────────────┬────────────────────┐
     ▼                      ▼                    ▼
  Flash/Feishu/mobile   (existing subs)   ★ Ezagent.CascadeNotifier  ← NEW (this spec)
                                              │
                                              │ 1. is {scheme, slice_key} cascade-worthy? (allowlist)
                                              │ 2. resolve affected principals (default [X];
                                              │    session :members → re-fetch member set)
                                              │ 3. for each principal P: resolve manage/owner
                                              │    holders in P's workspace (one level)
                                              │ 4. dedup, filter to User URIs
                                              ▼
                                     Ezagent.Notifications.notify/2  (per recipient)
```

The `CascadeNotifier` is a **supervised GenServer** (one per node) that
`Ezagent.SliceChange.subscribe_unverified/1`-subscribes to the entity streams it must
watch. Because a `slice_changed` topic is per-entity URI, and we cannot know the full
universe of entity URIs up front, the notifier subscribes to a **single shared
subscription surface**: it subscribes at boot to the broadcast the producer already
sends and filters in-process. (Implementation detail resolved in §Components — the
producer broadcasts to a per-URI topic, so the notifier subscribes via a wildcard-free
strategy described below.)

### Substrate fidelity

Per the converged brief, the cascade rides the **existing `slice_changed`
broadcast**. It does NOT introduce a second event substrate. The alternative
(subscribing to `esr:session_membership:changes`, which already carries a
`{:member_joined, member_uri}` delta) is **explicitly rejected** in §Key Decision Q4
with rationale.

---

## 3. Components

### 3.1 `Ezagent.CascadeNotifier` (NEW — `apps/ezagent_core/lib/ezagent/cascade_notifier.ex`)

**What it does.** Supervised GenServer. On each `{:slice_changed, event}` it (1) checks
the change is cascade-worthy, (2) resolves the affected principals, (3) resolves each
principal's one-level manage/owner holders, (4) dedups + filters to User URIs, (5)
calls `Ezagent.Notifications.notify/2` per recipient with a security-minimal payload.

**Interface.**

```
start_link(opts)                    # supervised child; subscribes at boot
handle_info({:slice_changed, ev}, s) # the whole cascade pipeline
```

Internal (private, unit-tested as functions):

```
cascade_worthy?(scheme, slice_key) :: boolean          # allowlist gate (Q4)
affected_principals(uri, slice_key) :: [URI.t()]        # default [uri]; :members re-fetch (Q4)
recipients_for(principal_uri) :: [URI.t()]              # one-level manage/owner holders (Q1)
```

**Dependencies (all CONFIRMED-existing):**
- `Ezagent.SliceChange` — subscribe + envelope shape (`.../slice_change.ex`).
- `Ezagent.Kind.SliceAccess.get_slice/2` — re-fetch of a live slice
  (`apps/ezagent_core/lib/ezagent/kind/slice_access.ex:56`) for `:members` expansion.
- The Q1 resolver (§3.2, NEW).
- `Ezagent.Notifications.notify/2` (`.../notifications.ex`) — User-inbox delivery.

**Subscription strategy.** `slice_changed` topics are per-URI
(`esr:entity:<uri>:slice_changed`). A single subscriber cannot enumerate every entity
URI. v1 resolves this by having `CascadeNotifier` subscribe to the topics of the
**entity kinds whose slices are in the cascade allowlist**, at the moment those Kinds
boot: the Kind's own boot subscribes it to its own `slice_changed` topic today
(SliceChange moduledoc, "the Kind GenServer subscribing to its OWN topic at boot"). We
add a parallel enrollment: when a Kind whose scheme is in the allowlist activates, it
also registers its URI with `CascadeNotifier`, which subscribes. **This enrollment
piece is the one piece of wiring the plan must add** (a single call in the entity
Kind activate path, or a `NotificationSubscriptions`-style registry the notifier reads
at boot + on Kind activation). See §Open risks — this is the wiring detail the plan
must pin.

### 3.2 `Ezagent.CascadeNotifier.Resolver` (NEW — the Q1 reverse lookup)

**What it does.** Given a principal URI **P**, returns the list of User URIs that hold
**manage/owner authority over P**, one level, bounded to P's workspace.

**Interface.**

```
managers_of(principal_uri) :: [URI.t()]   # User URIs holding Manage-over-P or ws-admin
```

**Algorithm (bounded, no global scan):**
1. `workspace = Ezagent.Capability.workspace_of(P)` — O(1) from the URI (SPEC v3: the
   workspace is the first authority segment).
2. `users = Ezagent.Users.list_in_workspace(workspace)` — CONFIRMED-existing
   (`apps/ezagent_domain_identity/lib/ezagent/users.ex:411`); returns each user's
   **decoded caps** (from the `users.caps_json` column).
3. Filter to users whose decoded caps include a **Manage-over-P** cap OR a
   **workspace-admin** cap, reusing the exact predicates already shipped in
   `Ezagent.ActionSet.IdentityAdmin`:
   - `holds_manage_over_target?/2`-equivalent: a `Ezagent.ActionSet.Manage`, `:any`-action
     cap whose instance scope covers P (via `Ezagent.Capability.matches?/2`, which
     honors `{:within_workspace | :spawned_by | concrete}` instance-scope tuples).
   - `holds_workspace_admin_cap?/2` / `holds_admin_caps?/1` (public in
     `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex`).
4. Return the matching user URIs.

**Dependencies (CONFIRMED-existing):** `Ezagent.Users.list_in_workspace/1`,
`Ezagent.Capability.matches?/2` + `workspace_of/1`, the `Manage`/admin predicates in
`Ezagent.ActionSet.IdentityAdmin`.

**Provenance:** this resolver is **PROPOSED-NEW code over a CONFIRMED-EXISTING durable
store**. See Q1 for the full evidence and gotchas.

---

## 4. Data flow (worked: motivating case)

1. **B pulls A's agent into B's session S.** Dispatch runs `Ezagent.ActionSet.Session`
   `:join`/`:attach`; `do_join` mutates **S's** `:members` slice
   (`apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex` —
   `{:set, :members, new_members}`). NOTE: it does NOT write to the agent's own slice
   (verified) — so the change surfaces on **S's** stream, not the agent's.
2. `Kind.Server.commit_and_notify/3` persists, then `SliceChange.emit/1` broadcasts
   `{:slice_changed, %{uri: S, slice_key: :members, cursor: c, event_at: t,
   result_summary: :ok}}` on `esr:entity:<S>:slice_changed`.
3. `CascadeNotifier` receives it. `cascade_worthy?("session", :members) == true`.
4. `affected_principals(S, :members)`: because the changed slice is `:members`, the
   affected principals are the **members**, obtained by re-fetching
   `Kind.SliceAccess.get_slice(S, :members)` → `[B(user), A's-agent, ...]`. (The
   content-free envelope carries no member list; re-fetch is the sanctioned pattern —
   SliceChange moduledoc.)
5. For each principal, `Resolver.managers_of/1`:
   - `A's-agent` → workspace(A's-agent) → users in that workspace holding
     `Manage(:agent, :any, instance: A's-agent)` → **A** (A holds the
     `CreatorGrant.manage_cap` minted at agent-create). → recipient **A**.
   - `B(user)` → B is its own owner (Identity `data_owner/1` = self). → recipient **B**.
6. Dedup + filter to User URIs → recipient set `{A, B}`.
7. `Notifications.notify(A, %{type: :cascade_slice_change, body: <minimal>, source: Ezagent.CascadeNotifier})`
   (and B). **A is notified** — goal met. (On B, see Q3: v1 cannot suppress the actor
   because the envelope omits `:caller`; B may receive a content-free notice of their
   own action — accepted, low-harm.)

For a **cap change to X** (X granted/revoked a cap): X's `:identity` slice mutates →
`slice_changed` on X → `affected_principals(X, :identity) == [X]` → `managers_of(X)` →
X's owner/managers notified "X's caps changed." Same pipeline, default principal set.

---

## 5. Key decisions (Q1–Q5)

### Q1 — Reverse lookup: "who holds the manage-cap over instance X?"

**Answer: PROPOSED-NEW resolver built on a CONFIRMED-EXISTING durable store and
CONFIRMED-EXISTING predicates. No new index/table.**

**Evidence — there is NO existing reverse index:**
- Caps live in **each grantee's `:identity` slice** (a `MapSet` of `%Capability{}`),
  see `Ezagent.ActionSet.Identity` (`.../behavior/identity.ex`). The manager check that
  exists today — `IdentityAdmin.holds_manage_over_target?/2` — reads the **caller's**
  caps (`ctx.caps`), i.e. it answers "does *this caller* manage the target", NOT "who
  are all managers of the target". A repo grep for `holders_of`/`who_holds`/
  `managers_of`/`caps_over` returns nothing cap-related (only the unrelated
  `ResponsibilityAssignment.holders/2` and `RoutingRegistry.reverse_index`).
- `Ezagent.CapabilityRegistry` indexes cap *subjects* (`{kind, behavior, action}`), not
  cap *holders*. `default_grants_from_data_owner/2` walks Behaviors to compute grants;
  it does not answer "who holds X".

**Why a per-dispatch full scan is not needed:** the workspace is O(1)-extractable from
X's URI (`Ezagent.Capability.workspace_of/1`; SPEC v3 first authority segment). The
durable, queryable cap store for **users** is `users.caps_json`
(`apps/ezagent_domain_identity/lib/ezagent/users.ex`), and
`Ezagent.Users.list_in_workspace/1` already returns the workspace's users with decoded
caps. So the candidate set is **the workspace's users** — bounded — not a global scan
of every Kind process or every user.

**The resolver (§3.2):** `workspace_of(X)` → `list_in_workspace/1` → in-memory filter on
decoded caps using `Capability.matches?/2` + the shipped `Manage`/`workspace-admin`
predicates. The **creator is subsumed** (the creator holds the `CreatorGrant.manage_cap`
minted at create — `apps/ezagent_core/lib/ezagent/creator_grant.ex`), so no separate
`:creator_uri` lookup is needed.

**Gotchas the plan must respect:**
- `caps_json` is a `:string` column (JSON text), **not `jsonb`** → **no DB containment
  query**; we decode in memory over the bounded per-workspace user set. (If this set
  ever grows large, a `jsonb` migration + GIN index is the future optimization — noted,
  not in S1.)
- Only **Users** are in `caps_json`. Agents also carry an `:identity` slice but are not
  projected to `caps_json`. This is exactly correct for v1 because
  `Ezagent.Notifications.notify/2` **raises for any non-User URI** (`.../notifications.ex`,
  `kind_module_of!/1`) — recipients must be Users. Agent-held Manage caps → agent
  recipients are **S2** (agent inboxes), out of scope. User-only resolution makes the
  S2 boundary clean.
- Instance-scope matching must go through `Capability.matches?/2` (not naive URI
  equality): a Manage cap scoped `{:within_workspace, ws}` or `{:spawned_by, uri}` must
  still match a concrete target — naive equality would silently miss scoped managers.

### Q2 — What the notifier delivers (payload)

**Answer: a security-minimal, content-free notification.** Same discipline as the
`slice_changed` envelope (the HIGH-1 leak fix). The notification carries only *that*
and *which slice* changed, never the values.

```
Ezagent.Notifications.notify(recipient_user_uri, %{
  type:   :cascade_slice_change,
  source: Ezagent.CascadeNotifier,
  body:   %{
    entity_uri: <affected principal URI, string>,   # the entity that changed
    slice_key:  <atom, e.g. :members | :identity>,   # which slice
    event_at:   <DateTime from the envelope>,
    cursor:     <non_neg_integer from the envelope>  # for consumer dedup
    # NO slice content: no member list, no cap values, no old/new slice.
  }
})
```

Rationale: the `slice_changed` envelope is content-free by design; the cascade
notification MUST NOT re-introduce the leak by copying re-fetched content into the
inbox. A recipient who is authorized to see the detail re-fetches via a cap-gated read
(`Ezagent.Invocation.dispatch/1` on a `:list_*`/`:get_*` action) — exactly the
framework's default-secure re-fetch model. Note the notifier *does* re-fetch `:members`
internally (to resolve recipients), but that re-fetched content is used ONLY to compute
recipients and is **never placed in the payload**.

### Q3 — Dedup / self-notify (does the actor get notified of their own action?)

**Answer: v1 does NOT implement actor self-suppression, by an unavoidable constraint;
it dedups per recipient.** This is a deliberate, documented tradeoff.

- **Why no actor suppression:** the security-minimal `slice_changed` envelope
  **deliberately omits `:caller`** — `build_broadcast_event/2` in
  `.../slice_change.ex` drops `caller` (only 5 keys survive, asserted by
  `slice_change_event_carries_no_slice_content_test.exs`). A `slice_changed` subscriber
  therefore **cannot know who caused the change.** Re-adding the actor to the envelope
  would break that invariant test and re-open the reviewed HIGH-1 decision — **out of
  S1 scope.**
- **Consequence:** if the actor is also an owner/manager of an affected principal, they
  may receive a content-free notice of their own action (e.g. B in the worked example).
  Accepted as **low-harm**: the payload carries no slice content, and dedup (below)
  caps it at one notice.
- **Dedup that IS implemented:** the notifier dedups recipients within one cascade so a
  principal reachable via two affected members is notified once; and it suppresses a
  repeat for the same `{entity_uri, cursor}` within its process lifetime (in-memory
  set). This gives **at-most-once per (entity, cursor)**.
- **Future refinement (noted, not S1):** precise actor-suppression needs an actor
  side-channel or a reviewed envelope change — deferred.

### Q4 — Which slices/changes are cascade-worthy?

**Answer: a curated, bounded ALLOWLIST — cascade is OFF by default.** High-frequency
internal slice churn must NOT spam owners, so a slice cascades ONLY if it opts in.

- **Mechanism:** a central allowlist in `CascadeNotifier`, keyed by
  `{scheme_or_kind, slice_key}`, that ALSO declares the affected-principal expansion.
  A central allowlist (rather than a new per-Behavior callback) keeps S1 a pure
  subscriber with zero Behavior-contract changes and stays single-plan-sized.

  ```
  # {scheme, slice_key} => affected-principal rule
  {"session", :members}  => :members_of_slice   # re-fetch members; principals = the members
  {"entity",  :identity} => :self               # principal = the entity itself (cap change to X)
  # (entity lifecycle slices may be added here as the need is proven)
  ```

- **`affected_principals/2`** dispatches on this table: `:self` → `[X]`;
  `:members_of_slice` → re-fetch `get_slice(X, :members)` and return the member URIs.
- **Why this bounded set:** `:members` covers the motivating membership case;
  `:identity` covers cap grant/revoke. Everything else (a chat message ring, PTY output,
  agent scratch state) is intentionally excluded to prevent notification spam. **This is
  a design decision, flagged for review** — the initial allowlist is deliberately
  minimal and grows only with a demonstrated need.

- **Rejected alternative — subscribe to `esr:session_membership:changes` for a precise
  `{:member_joined, member_uri}` delta** (`.../presence_fanout.ex`): it would avoid
  re-fetch and pinpoint the exact joined/left member (no over-notify). **Rejected for
  S1** because (a) the brief mandates a single `slice_changed` subscriber and this is a
  second substrate; (b) it couples S1 to session-domain internals. It is the natural
  **future** optimization once over-notification is measured to matter. **Tradeoff
  owned:** with re-fetch (option a), a membership change notifies owners of *all current
  members* (over-notify, bounded by dedup + low membership-change frequency + content-
  free payload), and a **member REMOVAL cannot notify the removed member's owner**
  (the leaver is absent from the re-fetched set) — a documented v1 gap; removal-notify
  needs the delta substrate and is deferred.

### Q5 — Delivery reliability / async

**Answer: best-effort, at-most-once. v1 keeps it simple.**

- `CascadeNotifier` is a supervised GenServer. On crash it restarts and **re-subscribes**
  but does **not** replay events missed during downtime (no cursor-gap backfill in v1).
- Delivery is **at-most-once**: PubSub is fire-and-forget; if the notifier is down when
  an event fires, that cascade is lost. Acceptable for v1 — cascade notifications are
  advisory, not a transactional guarantee.
- The notifier never blocks or crashes the producer: it is a *separate* subscriber
  process, off the dispatch/commit path (the producer already treats its own emit as
  non-fatal — `SliceChange.do_emit` rescues). A slow resolver in the notifier cannot
  roll back a mutation.
- **Tradeoff noted:** at-least-once + cursor-gap backfill (replay from the monotonic
  per-URI `cursor`) is the reliability upgrade path — deferred to a future spec.

---

## 6. Error handling

- **Bad / non-dict envelope:** ignore (guard clause), do not crash the GenServer.
- **`get_slice/2` fails** (Kind not live / slice absent): treat affected principals as
  empty for that change → no notification; log at `:debug`. Never crash.
- **Resolver DB error** (`list_in_workspace/1` raises): rescue, log `:warning`, emit no
  notification for that event. The notifier survives.
- **`Notifications.notify/2` raises** (e.g. a non-User URI slipped through): the
  resolver already filters to User URIs, so this is a programmer error — let it surface
  in tests, but wrap the per-recipient notify in a rescue so one bad recipient does not
  drop the rest of the batch.
- **Non-fatal by construction:** every failure path is observable (log/telemetry) and
  local to the notifier; the producer and the mutating dispatch are never affected
  (mirrors the `SliceChange.emit` post-commit non-fatal contract).

---

## 7. Testing (TDD)

Write tests first; each maps to a behavior above.

**Unit — Resolver (Q1):**
1. `managers_of(agent_uri)` returns the creator (holds `CreatorGrant.manage_cap`) — the
   core reverse-lookup test.
2. A user granted a `Manage(:agent, :any, instance: agent)` cap is returned; a user with
   an unrelated cap is NOT.
3. Scope-tuple coverage: a `{:within_workspace, ws}` Manage cap IS returned for a target
   in `ws` (proves `matches?/2` path, not naive equality).
4. Workspace-admin user is returned.
5. Bounded-scan proof: users in a *different* workspace are never returned (asserts the
   `list_in_workspace/1` scoping, i.e. no global scan).

**Unit — cascade-worthy gate (Q4):**
6. `{"session", :members}` and `{"entity", :identity}` are cascade-worthy; a
   non-allowlisted `{scheme, slice_key}` is not (no notification fires).

**Unit — affected principals (Q4):**
7. `:identity` change → principals `[X]`.
8. `:members` change → principals = re-fetched member set.

**Unit — payload minimality (Q2):**
9. The notification `body` contains ONLY `{entity_uri, slice_key, event_at, cursor}` —
   assert NO member list / cap values (the S1 analogue of
   `slice_change_event_carries_no_slice_content_test.exs`).

**Integration — the motivating case (the acceptance test):**
10. B pulls A's agent into B's session; assert **A receives** a `:cascade_slice_change`
    notification (subscribe A's `Notifications` topic). This is the S1 done-gate.
11. Cap grant to X → X's owner receives a notification.

**Unit — reliability/error (Q5, §6):**
12. A non-dict `{:slice_changed, "oops"}` does not crash the notifier.
13. `get_slice` failure yields zero notifications and a live process.
14. Dedup: a principal reachable via two members is notified once per `{entity, cursor}`.

---

## 8. Out of scope / future specs

Named here so the plan does NOT design them:

- **S2 — all-entity inboxes.** Today only **Users** have inboxes
  (`Notifications.notify/2` raises for non-User URIs). Notifying *agents* (so an agent
  can receive a cascade) needs an agent inbox primitive. S1 filters recipients to Users;
  S2 lifts that. (This is *why* Q1's User-only resolution is correct, not a shortcut.)
- **S3 — unify membership into the cap model.** Membership (`session :members`) and caps
  are separate mechanisms today. S1 rides both because both mutate slices; it does NOT
  unify them. Unification (and thus a single reverse-lookup for both) is S3.
- **S0 — delete legacy `Notifications.notify/3`.** The legacy notify surface removal
  (referenced in `SliceChange` moduledoc "PR-N5") is independent housekeeping, not S1.
- **session.join ADMISSION authz gate.** Whether B is *allowed* to pull A's agent in is
  an authorization concern (the grant/admission side). S1 is the **notification** side
  only — it tells A *after* the fact; it does not gate the join.
- **Delta-precise membership + removal-notify + at-least-once backfill.** The Q4/Q5
  optimizations (subscribe the membership-delta topic; notify removed members' owners;
  replay cursor gaps) are deferred future refinements.

---

## 9. Open risks (not fully resolved in this spec)

1. **Subscription enrollment wiring (§3.1).** `slice_changed` topics are per-URI, so
   `CascadeNotifier` must be subscribed to each allowlisted entity's topic. The plan
   must pin ONE of: (a) a small enrollment call in the entity Kind activate path (Kinds
   already self-subscribe at boot — piggyback), or (b) a boot-time + on-activation
   registry the notifier reads. This is wiring, not a design fork, but it is the one
   piece not fully nailed here. Recommendation: (a), mirroring the existing "Kind
   subscribes to its OWN topic at boot" pattern.
2. **Over-notification on membership re-fetch (Q4).** Notifying owners of all current
   members on any membership change is bounded (dedup, low frequency, content-free) but
   not precise; if measured to matter, adopt the rejected delta substrate.
3. **Removal-notify gap (Q4).** A member REMOVAL cannot notify the removed member's
   owner via re-fetch (the leaver is gone from the slice). Documented; needs the delta
   substrate — deferred.
