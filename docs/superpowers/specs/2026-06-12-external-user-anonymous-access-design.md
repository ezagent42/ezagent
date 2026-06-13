# External-User Anonymous Access — DESIGN spec

> **STATUS: DESIGN, not implementation.** Synthesized by a subagent from Allen's
> stated requirements + the current codebase (branch `spec/external-user-anon-access`,
> off `origin/main` with config-evolve #733 + the P4 chat external SPA #732).
> It is NOT a plan; it stops at design + the genuine OPEN QUESTIONS Allen must
> decide at review. Where a fork could not be resolved from requirements alone it
> is flagged in **§9 OPEN QUESTIONS** rather than silently chosen.

---

## 1. Problem & context

A socialware page (the chat external SPA at `GET /socialware/chat?session_uri=…`,
served by `EzagentWeb.Socialware.ChatFeedController`) is, today, mounted under the
`EzagentWeb.Plugs.RequireEntity` pipeline. That plug **bounces any request with no
`:current_entity_uri` session cookie straight to `/login`**. So a first-time,
not-logged-in visitor following a shared socialware link never sees the page — they
hit the login wall. Allen's position: anonymous first-open is a BASIC, necessary
feature. A visitor must be able to VIEW the page anonymously, and only be guided to
log in when they try to WRITE.

The current authorization model is moving (P5 collapse, option B) to a single
**membership-gated publisher-read**: `Ezagent.Socialware.ChatMembership.authorize/2`
is the one predicate — a caller may read a chat session's `:chat` slice iff it is a
well-formed bare principal `%URI{}` that is EITHER the session `owner_uri` OR a key of
the `:chat` slice `members` map. `ChatFeed.snapshot/2` (the `:pull` read) and
`Behavior.SocialwarePublisherRead` both call it; `ChatFeedChannel` re-checks it LIVE
on join AND on every advisory re-read, so an ex-member's view clears immediately.

There is **no anonymous-entry / external-user / login-replacement flow today**
(verified: no `external_user` / `guest` / `anon-` entity anywhere). The existing
`ChatFeedAuth` mints a `{caller_uri, session_uri}` token but ONLY for an already
signed-in principal (`conn.assigns.current_entity_uri`, populated by RequireEntity).

This spec designs the missing flow **without changing the permission mechanism**:
everything is expressed through session MEMBERSHIP. The visitor reads because we make
them a member; they cannot write because their membership is read-only and writes
demand a real authenticated principal.

---

## 2. The membership-only principle (the load-bearing constraint)

> **No new "non-member can read" session permission is introduced. Anonymous read is
> achieved by making the anonymous visitor a real session MEMBER (via an ephemeral
> external-user entity), and read authz stays exactly `ChatMembership.authorize/2`.**

Consequences that fall out of this principle, and which the whole design obeys:

1. **`ChatMembership` is untouched.** It already accepts "caller is a key of
   `members`". An external-user URI placed in `members` reads by construction. We do
   NOT add an `is_anon?` branch, a `:guest` allow-list, or a non-member read path.
   (This also satisfies `feedback_let_it_crash_no_workarounds` — no whitelist/shim.)
2. **The membership-mutation path is `chat.join` / `chat.leave`** (`Behavior.Chat`),
   the SAME path every other member uses. Anonymous entry is a `chat.join` of the
   external-user; login-replacement is `chat.leave` external-user + `chat.join` real
   user. No bespoke membership writer.
3. **Write authority is a SEPARATE axis from read.** Read = membership. Write
   (`chat.send`) = the `:send` cap, which the external-user is NOT granted. So a
   write attempt fails the normal CapBAC gate; the SPA catches the denial and guides
   to login. We do NOT model "read-only membership" as a new member flag — it is the
   plain ABSENCE of a `:send` cap on the external-user entity.
4. **Identity, not anonymity, on the token.** `ChatFeedAuth` already carries the
   caller identity (unlike `CustomerAuth`, which is identity-less). The external-user
   IS an identity (a real `entity://…` URI), so it slots into the existing
   `ChatFeedAuth.issue_token(external_user_uri, session_uri)` with no token change.

---

## 3. The external-user entity (Kind / URI / caps / lifecycle)

### 3.1 Chosen design: a **flavor of the User Kind**, not a new Kind

**Decision (proposed — see OQ-1): the external-user is an `Ezagent.Entity.User`
instance with an `anon` workspace-name segment and an `anon-<random>` name, created
read-only and GC-eligible — NOT a new ephemeral Kind.**

Why a User flavor and not a new Kind:

- `ChatMembership.valid_caller_uri?` delegates to `Ezagent.URI.bare_principal?/1`,
  which accepts `entity://<ws>/<user|agent|worker>/<name>`. A new scheme/type would
  be rejected by the predicate — to keep "membership-only", the external-user MUST be
  one of the three accepted entity types. `user` is the honest fit (it represents a
  human visitor).
- A new Kind means a new SpawnRegistry handler, a new supervisor, new snapshot
  plumbing, new CapBAC registration — a lot of surface for an entity whose ONLY job
  is "be a member URI that reads". The plugin-isolation north star
  (`feedback_north_star_plugin_isolation`) favors NOT adding a Kind when an existing
  one's identity slice already does the job.
- The User Kind already lazily demand-spawns via the `entity://` SpawnRegistry fn
  (`register_user_only_entity_spawn_fn`) and hydrates caps from `users.caps_json`.
  An external-user simply has a `users` row with a **read-only caps_json** (see §3.3).

The cost we accept: the external-user shows up as a `user` in any "list users" view.
We mitigate by the dedicated workspace/name segment (`anon`) so it is filterable, and
by GC (§3.4). (OQ-1 records the alternative: a distinct `worker`-flavored entity, or
a genuinely new ephemeral Kind, if Allen wants a hard structural separation.)

### 3.2 URI shape

```
entity://<viewed-workspace>/user/anon-<random>
```

- **Workspace segment = the viewed session's workspace** (from
  `Ezagent.WorkspaceRegistry.lookup(session_uri)`), NOT a global `anon` workspace.
  This is load-bearing for §5 security: `User.default_caps/1` and every workspace
  scope are derived from the entity's own workspace segment
  (`Ezagent.URI.entity_workspace_uri/1`), so binding the external-user into the
  viewed session's workspace keeps it from being usable cross-workspace. (See OQ-2 —
  an alternative is a dedicated `anon` sub-namespace inside the workspace, e.g. a
  reserved name prefix, which §3.1 already uses via the `anon-` name prefix.)
- **`anon-<random>`**: `<random>` is a URL-safe 128-bit token
  (`:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)`), so the name
  is unguessable and collision-free. The `anon-` prefix makes the entity
  recognizable to GC and to "hide anon users" filters. It must pass
  `Ezagent.URI.entity/3` segment validation (alnum + `-`/`_`), which `Base.url_encode64`
  (with `+`/`/` → it does NOT; use `Base.url_encode64` which yields `-`/`_`) satisfies.

### 3.3 Caps — read-only by CONSTRUCTION (absence of `:send`)

The external-user's `users.caps_json` is **empty / read-only**: it does NOT get
`User.default_caps/1` (which grants `{kind: :session, behavior: :any, action: :any}`
in the workspace — that broad baseline cap is what lets a normal user attempt
`chat.send`). The external-user gets only the structural self-Identity cap that
`Behavior.Identity.init_slice/1` auto-adds (so it can exist as a Kind) and NOTHING
session-behavioral.

Result, expressed entirely through the existing CapBAC chokepoint:

- **READ** needs no cap — `ChatFeed.snapshot/2` / the channel authorize via
  `ChatMembership` (membership), and the external-user IS a member. ✓ reads.
- **WRITE** (`chat.send`) goes through dispatch step 5.5, which derives the needed
  `{kind: :session, behavior: Chat, action: :send, instance: <session_uri>}` cap. The
  external-user holds no such cap → `:unauthorized`. ✓ cannot write.

This is the cleanest realization of "read-only membership": it is the plain absence
of the write cap, not a new flag. (OQ-3 records the alternative of an explicit
narrowly-scoped read-only cap if any path turns out to need a positive cap rather
than membership alone.)

### 3.4 Lifecycle — created on first open, GC'd when abandoned

- **Created** on the first anonymous open of a socialware page (§4.1), bound to a
  visitor cookie so a RETURNING anonymous visitor keeps the same external-user.
- **Backed by a `users` row** (so the existing lazy demand-spawn + caps_json hydrate
  path works unchanged) PLUS a small **external-user binding table** (OQ-4) recording
  `{cookie_id (or its hash), external_user_uri, session_uri, workspace_uri, created_at,
  last_seen_at}`. The binding table is the GC index and the cookie→entity resolver.
- **GC / expiry**: abandoned external-users (no `last_seen_at` activity within a TTL,
  e.g. 24–72h — OQ-5) are reaped: `chat.leave` from their session + delete the
  `users` row + delete the binding row + (best-effort) stop the Kind. GC is a periodic
  sweep over the binding table (an Oban cron or a `Process.send_after` sweeper —
  OQ-5). Reaping an external-user that has ALREADY been replaced by login (§4.4) is a
  no-op (the binding row is gone).
- **Retired on login** (§4.4): the external-user is leaved + GC'd immediately, its
  membership migrated to the real user.

---

## 4. The four flows

### 4.1 First-open (anonymous GET → external-user is a member → token issued)

```
GET /socialware/chat?session_uri=<session://…>   (NO current_entity_uri cookie)
```

1. The chat route is **moved out of the `RequireEntity` pipeline** into the public
   `:browser` scope (alongside `/socialware/customer`). RequireEntity is what bounces
   anonymous visitors today; removing it is the single change that unblocks the
   anonymous view. A NEW controller path then handles both authed and anon callers.
2. The controller resolves the visitor:
   - If `conn.assigns[:current_entity_uri]` is present (already logged in) → existing
     behavior: mint `ChatFeedAuth.issue_token(principal_uri, session_uri)`.
   - Else (anonymous) → resolve-or-create the external-user:
     a. Read the visitor cookie `socialware_anon` (signed, HttpOnly, SameSite=Lax).
        If it names a live external-user already bound to THIS `session_uri`
        (binding-table lookup), reuse it. (A returning visitor keeps their entity.)
     b. Else mint a fresh external-user URI (§3.2), create its `users` row
        (read-only caps_json), insert the binding row, set the cookie.
     c. **`chat.join`** the external-user into the session (the membership mutation —
        a `:cast` or `:call` of `Behavior.Chat`'s `:join` on the Session Kind). This
        is the ONLY thing that makes the read authorized.
   - Either way, mint `ChatFeedAuth.issue_token(external_user_uri OR principal_uri,
     session_uri)` and embed it in the SPA shell (unchanged page/2).
3. **[HUMAN/AUTHZ flag]** Whether an anonymous visitor may join ANY session by URL, or
   only sessions explicitly marked "publicly viewable", is OQ-6 — the default below
   (§5) is "only sessions whose owner opted them public".

### 4.2 Read (membership-gated feed — unchanged)

No new code path. The SPA connects the `ChatFeedSocket` with `{session_uri, token}`;
`ChatFeedAuth.verify` recovers the external-user `%URI{}`; `ChatFeedChannel.join`
subscribes + calls `ChatFeed.snapshot(session_uri, external_user_uri)`, which calls
`ChatMembership.authorize/2`. The external-user is a member → `:ok` → snapshot
renders. Live advisories re-read + re-authorize exactly as for a real member. If the
external-user is later GC-leaved, the next advisory re-read returns `:unauthorized`
and the channel pushes `unauthorized` + closes (the existing P4 fail-closed path).

### 4.3 Write-gate (a write by an external-user → guided to login)

1. The SPA's compose/send action attempts a write. **Decision (OQ-7): the external
   SPA does NOT expose a working send path to an external-user at all — the compose
   box renders a "Log in to reply" affordance instead of a send button** when the
   token's caller is an external-user. This is the cheapest correct UX (no wasted
   round-trip) AND defense-in-depth.
2. **Server-side backstop (non-negotiable):** if a write IS attempted (crafted
   client), the `chat.send` dispatch fails CapBAC step 5.5 (`:unauthorized`, §3.3).
   The write surface must surface that as "log in to continue", not a silent drop
   (Invariant #9 — no silent drops at user-facing surfaces). The channel/endpoint
   that accepts writes returns a structured `{:error, :login_required}` the SPA maps
   to the login CTA. (Today `ChatFeedChannel` is read-only — it has NO send handler;
   if/when a write path is added it MUST enforce this. OQ-7 covers where the write
   path lives.)
3. The login CTA links to `/login?return_to=/socialware/chat?session_uri=…` so the
   visitor returns to the same page post-login (login-replacement, §4.4).

### 4.4 Login-replacement (external-user membership migrates to the real user)

On successful login (`SessionController.credentials_create` / magic-link consume), if
the session has a `socialware_anon` cookie naming a live external-user:

1. Resolve the external-user URI + its bound `session_uri` from the binding table.
2. **Migrate membership atomically (OQ-8):** `chat.leave(external_user)` +
   `chat.join(real_user)` on the Session. Because `chat.leave` is a `:cast` and
   `chat.join` is a `:call`, true cross-dispatch atomicity is not free; the proposed
   ordering is **join real-user FIRST (`:call`, await member set), THEN leave the
   external-user (`:cast`)** so there is never a window where NEITHER is a member
   (continuity of the viewer's read — at worst BOTH are members for a blink, which is
   harmless: the real user reads, the external-user is about to be reaped). If the
   real user is **already a member** (OQ-9), skip the join; just leave + GC the
   external-user.
3. **Retire the external-user:** GC it immediately (leave already done; delete
   `users` row + binding row + stop Kind). Clear the `socialware_anon` cookie.
4. **View continuity:** the SPA, after login, reconnects with a freshly minted
   `ChatFeedAuth` token for the REAL user (the page re-render under the now-authed
   controller path mints it). The snapshot is the same session, so the viewer sees the
   same conversation — now as themselves, with write enabled (they hold `:send`).

---

## 5. Security

The external-user must be strictly read-scoped to the ONE session it was created for,
and must not enable abuse. Concrete guarantees + how each is achieved:

1. **Cannot read OTHER sessions.** The external-user is a member of exactly ONE
   session (the one it joined in §4.1). `ChatMembership.authorize/2` is per-session
   (re-checks membership of THAT session). The `ChatFeedAuth` token binds
   `{caller_uri, session_uri}` — it only authenticates the external-user on its own
   session. Pointing the same token at a different `session_uri` fails token
   verification (`session_uri` mismatch).
2. **Cannot escalate.** Read-only caps_json (§3.3): no `:send`, no grant cap, no
   admin cap. The structural self-Identity cap only lets it exist. It cannot
   `chat.send`, `chat.join` others, grant caps, or invoke any session behavior.
3. **Workspace-scoped.** Its URI carries the viewed session's workspace segment, so
   even if a future cap leaked, `Ezagent.Capability.cross_workspace?` would block any
   cross-workspace use. It is NOT a `system://` principal and never holds a wildcard.
4. **Cannot read a private session by guessing.** Default (OQ-6): a session is
   anonymous-viewable ONLY if its owner opted it public (a flag on the session, e.g.
   `:chat` slice `public_view: true`, or a workspace policy). If not public, the
   anonymous GET does NOT create/join an external-user — it falls back to the login
   bounce (the current behavior). So anonymous access is **opt-in per session**, not a
   blanket "any URL is viewable".
5. **DoS / mass anonymous entities.** Mitigations:
   - **Rate-limit** external-user creation per IP and per session via the existing
     `EzagentWeb.RateLimiter` (the magic-link flow already uses it): e.g. N new
     external-users/hour/IP, M/hour/session. Over-limit → serve a static "too many
     anonymous viewers, please log in" page (no entity created).
   - **Cookie reuse** caps growth: a returning visitor reuses their external-user
     (§4.1a), so normal browsing creates ONE entity per visitor per public session,
     not one per page-load.
   - **GC** (§3.4) bounds the steady-state population — abandoned external-users are
     reaped on a TTL.
   - **Cap on concurrent anon members per session** (OQ-10): refuse new external-user
     joins past a per-session ceiling (serve login CTA instead).
6. **Cookie integrity.** `socialware_anon` is a signed (Phoenix.Token / signed
   cookie) value binding `{external_user_name, session_uri}`; it is HttpOnly + Secure
   + SameSite=Lax. A tampered cookie fails verification and is treated as "no cookie"
   (mint fresh). The cookie does NOT itself authorize reads — the `ChatFeedAuth`
   token + live membership do; the cookie only resolves "which external-user is this
   returning visitor".
7. **No silent drops at the write surface** (Invariant #9): a denied write surfaces
   the login CTA, never a silent failure.

---

## 6. The E2E user-path additions (fold into the 2026-06-11 acceptance gate)

The pinned gate (`2026-06-11-socialware-substrate-e2e-acceptance-gate.md`) exercises
the AUTHENTICATED member + the customer-delivery path, but — as Allen flagged — it
**does not exercise the anonymous-first-open → write-gate → login-replacement
user-path**. Proposed addition: a new criterion **10 [USER-PATH: anonymous → login]**,
agent-browser-verifiable on the same disposable stack (`http://100.64.0.27:10044`),
with these concrete steps. (Seed addition: mark one seeded chat session
`public_view: true` and emit its anonymous URL; create a real login user `e2e-visitor`
with a known password via the self-generate-credentials path.)

**Steps (agent-browser, headless Chrome from the agent side FIRST):**

10a. **[VISUAL] Anonymous first-open renders the page.** In a FRESH browser context
    (no cookies, not logged in), navigate to the public session's
    `/socialware/chat?session_uri=…`. Screenshot: the chat snapshot renders (the page
    is the external SPA, NOT a `/login` redirect). Assert the URL did NOT become
    `/login`. Server-side assert: an `entity://<ws>/user/anon-…` member now exists in
    the session's `:chat` `members` (the external-user was created + joined).

10b. **[VISUAL] Write attempt prompts login.** Click the compose/reply affordance.
    Screenshot: a "Log in to reply" CTA appears (no message is sent). Server-side
    assert: no new message in the session from the external-user; if a crafted send is
    injected, it is denied with `:unauthorized` / `:login_required` (no silent drop).

10c. **[VISUAL] After login the real user sees the same session; the external-user is
    gone.** Follow the login CTA, log in as `e2e-visitor`. Screenshot: the SAME chat
    session renders, now with a WORKING compose box (send enabled). Server-side
    assert: `e2e-visitor` is now a member; the `anon-…` external-user is NO LONGER a
    member (left + GC'd) and its `users` row + binding row are deleted.

10d. **[VISUAL/AUTHZ] A different session's anonymous visitor cannot read this one.**
    In another fresh context, open the PUBLIC URL for a DIFFERENT public session (or a
    NON-public session URL). For the different-session case: that visitor's
    external-user reads ITS session only — point its token/URL at the FIRST session's
    `session_uri` and assert DENIED (token `session_uri` mismatch / non-member).
    For the non-public case: the anonymous GET bounces to `/login` (no external-user
    created). Screenshot of the denial / bounce.

10e. **[REGRESSION] Anonymous entry does not weaken the existing member/ex-member
    gate.** Re-run gate criterion 6 (ex-member view clears on `chat.leave`) with an
    external-user as the member: after a GC-leave of the external-user, its rendered
    view CLEARS immediately (the existing `unauthorized` push + close), WITHOUT a
    subsequent chat message — proving the external-user is gated by the SAME live
    membership predicate as a real member.

These fold in as **criterion 10 (a–e)**; the gate is GREEN iff 1–8 AND 10 hold (9
only if P5 ships). Screenshots 10a, 10b, 10c are attached to the Feishu thread.

The cheap deterministic pre-gate (ExUnit) additions, mirroring the existing
fast-test half:
- **anon-join test**: first anonymous open creates exactly one external-user, joins
  it, and `ChatFeed.snapshot/2` authorizes it (membership-gated read passes for the
  external-user).
- **write-deny test**: a `chat.send` dispatched as the external-user is denied at
  CapBAC step 5.5 (`:unauthorized`) — it holds no `:send` cap.
- **login-replacement test**: after login-migration, the real user is a member, the
  external-user is NOT, and the binding/users rows are gone (idempotent if the real
  user was already a member).
- **cross-session-isolation test**: an external-user for session A fails
  `ChatMembership.authorize/2` for session B; the token bound to A fails verify for B.

---

## 7. What is NOT changed (anti-drift guardrails)

- `ChatMembership.authorize/2` — byte-unchanged. No `is_anon?` branch, no allow-list.
- `ChatFeedAuth` token shape — unchanged (`{caller_uri, session_uri}`); the
  external-user IS a `caller_uri`.
- `Behavior.Chat` join/leave — unchanged; anonymous entry + login-replacement reuse
  them as-is.
- No new session permission, no non-member read path, no `:send` for the external-user.

The only NEW surface: (a) a public route + a controller branch that resolves/creates
the external-user, (b) the external-user `users`-row + binding table + cookie, (c) the
GC sweeper, (d) the login-replacement hook in the auth controllers, (e) the
public-view opt-in flag, (f) rate-limits. All of it sits OUTSIDE the read-authz core.

---

## 8. Honest assessment — what is underspecified

- **The write path's home.** `ChatFeedChannel` is read-only today; where the SPA's
  send actually goes (a new channel handler? a controller POST? the operator
  LiveView's compose reused?) is NOT settled — §4.3 specifies the GATE behavior but
  not the transport. → OQ-7.
- **Atomicity of login-replacement** across a `:cast` leave + `:call` join is
  approximated (join-first ordering), not transactional. → OQ-8.
- **The binding table schema** (and whether it should be per-tenant with
  `workspace_uri NOT NULL` per Invariant #14 — it likely must) is sketched, not
  finalized. → OQ-4.
- **GC mechanism** (Oban cron vs. in-app sweeper) and TTL are proposed, not pinned.
  → OQ-5.
- **Public-view opt-in** (session flag vs. workspace policy vs. a per-link grant) is
  defaulted to a session flag but not designed in detail. → OQ-6.
- Whether the `User` Kind is the right home vs. a distinct entity is the single
  biggest fork. → OQ-1.

---

## 9. OPEN QUESTIONS for Allen (the genuine design forks — decide at review)

**OQ-1 — External-user Kind choice.** Make the external-user a flavor of the existing
`Ezagent.Entity.User` (this spec's choice: reuses lazy demand-spawn + caps_json +
`bare_principal?` acceptance; cost = it appears in user lists), OR a distinct
`worker`-typed entity (also `bare_principal?`-accepted; cleaner separation, but new
provisioning), OR a genuinely new ephemeral Kind (hard structural separation, but new
SpawnRegistry/supervisor/CapBAC surface and `ChatMembership` would have to accept its
type — which dents "membership-only"). **Recommendation: User flavor.**

**OQ-2 — Workspace placement of the external-user.** Put it in the VIEWED session's
workspace (this spec's choice — keeps it workspace-scoped to where it reads), OR a
dedicated global `anon` workspace (cleaner to filter/GC, but then cross-workspace caps
machinery must treat it specially to let it read the real session — friction with
Invariant #4/#13). **Recommendation: viewed session's workspace, `anon-` name prefix.**

**OQ-3 — Read-only as ABSENCE of `:send`, or an explicit read-only cap?** This spec
realizes read-only as the plain absence of any session cap (membership alone grants
read). Is that acceptable, or do you want a positive, narrowly-scoped read-only cap on
the external-user (more explicit, but introduces a "read cap" concept the membership
model deliberately avoids)? **Recommendation: absence of `:send` (membership-only).**

**OQ-4 — Binding table.** Confirm a new table
`{cookie_id_hash, external_user_uri, session_uri, workspace_uri NOT NULL, created_at,
last_seen_at}` (per-tenant, Invariant #14), keyed for cookie→entity resolution AND GC.
Or do you prefer to overload an existing table / stash the binding on the `:chat`
slice member meta? **Recommendation: dedicated per-tenant table.**

**OQ-5 — GC policy.** TTL for an abandoned external-user (proposed 24–72h of no
`last_seen_at`), and the sweeper mechanism (Oban cron vs. an in-app periodic
`Process.send_after` sweeper). **Recommendation: 48h TTL, Oban cron daily-or-hourly.**

**OQ-6 — Public-view opt-in.** Is a session anonymous-viewable by default for anyone
with the URL, or ONLY if its owner explicitly marks it public (this spec's default —
a `:chat` slice `public_view: true` flag the owner sets)? If opt-in, where does the
flag live and who can set it (owner only)? **Recommendation: owner-set per-session
opt-in flag; default private (anonymous GET on a private session bounces to login).**

**OQ-7 — Where the write path lives + the gate.** The external SPA's send must be
gated to "log in to reply". Should the external SPA (a) render NO working send for an
external-user (compose shows a login CTA — this spec's recommendation), and where does
a logged-in member's send actually go — a new `ChatFeedChannel` write handler, a
controller POST, or reuse of the operator compose path? The server-side CapBAC denial
backstop is non-negotiable regardless. **Recommendation: external-user sees a login
CTA (no send); the authed-member write path is a separate, explicitly-designed
transport.**

**OQ-8 — Atomicity of login-replacement.** `chat.leave` is `:cast`, `chat.join` is
`:call`. This spec proposes join-real-user-first then leave-external-user (never a
no-member window; a brief both-member window is harmless). Acceptable, or do you want a
true atomic membership-swap primitive on `Behavior.Chat` (a new `:replace_member`
action)? **Recommendation: join-first ordering; add a `:replace_member` action only if
the brief overlap proves problematic.**

**OQ-9 — Real user already a member at login.** If the logging-in user is ALREADY a
member of the session, login-replacement skips the join and just leaves + GC's the
external-user. Confirm that's the intended behavior (vs. erroring / vs. keeping the
external-user). **Recommendation: skip join, leave + GC the external-user.**

**OQ-10 — Per-session anonymous ceiling.** Should there be a cap on concurrent
external-user members per session (refuse new anon joins past N, serve login CTA), in
addition to the IP/session rate-limits? **Recommendation: yes, a configurable
per-session ceiling as DoS defense-in-depth.**

**OQ-11 — Cookie scope.** One `socialware_anon` cookie bound to a single
`{external_user, session}` (this spec), or a cookie that can hold MULTIPLE
session→external-user bindings (a visitor anonymously viewing several public sessions
keeps a distinct external-user per session)? **Recommendation: support multiple
bindings (map keyed by session_uri) so a visitor browsing several public sessions
isn't collapsed into one shared anon identity.**
