# External-User Anonymous Access — DESIGN spec (post-collapse refinement)

> **STATUS: DESIGN, re-aligned to the post-collapse (P5) substrate.** The original
> draft (§ history below) was synthesized against the PRE-collapse substrate
> (`Behavior.Chat`, `Ezagent.Socialware.ChatMembership`, the `:chat` slice, an Oban
> GC). This revision re-derives every load-bearing reference against CURRENT main
> (`origin/main` @ `e689c91e` + the P5 collapse PRs #741–#744) and revises each OQ
> decision with rationale. It is a DESIGN, not a plan; it stops at design + the
> genuine OPEN QUESTIONS for Allen, now annotated with the post-collapse answer
> where the substrate forces one.
>
> **Issue:** ezagent #51 — external-user anonymous access for socialware
> (membership-only). The companion deliverables (this pass): the E2E scenario doc
> `docs/scenarios/35-external-user-anon-access/` and the TDD tests under
> `apps/ezagent_domain_socialware/test/ezagent/socialware/anon_*`.

---

## 0. What changed for the post-collapse substrate (read this first)

The draft predates the P5 collapse. The eight substrate facts the design now binds to:

| Draft assumed (pre-collapse) | Post-collapse reality (CURRENT main) |
|---|---|
| `Behavior.Chat` with `chat.join` / `chat.leave` | `Ezagent.Behavior.Session` (the `:chat` Behavior was deleted → Session, #741). The `:join` / `:leave` actions live there; `handle_join/2` delegates to `Ezagent.Behavior.Session.Membership.do_join/5`. |
| The `:chat` slice | The `:session` slice. `Ezagent.Kind.get_slice(session_uri, :session)` is the live read. |
| `Ezagent.Socialware.ChatMembership.authorize/2` | `Ezagent.Session.Membership.authorize/2` (the security predicate, relocated to `ezagent_domain_instance_message`, file `session/membership_predicate.ex`). SAME shape: `(chat_slice, caller) → :ok | {:error, :unauthorized}`; reuse it, do NOT duplicate. |
| Two Session Kinds (chat + socialware) | ONE unified `Ezagent.Entity.Session` Kind (#743/#744). Templates select the per-instance Behavior subset via `:kind_base` (`Session.chat_behaviors/0` / `Session.socialware_behaviors/0`). |
| Customer-delivery in socialware/web | `CustomerOutbox`, the `CustomerDelivery` topic, `Settlement`, `Turn`, `Surface` moved into `ezagent_domain_instance_message` (#742). The customer FEED/view (`CustomerFeed`, the customer SPA, `customer_channel`) stays in socialware/web. The chat-feed external read (`ChatFeed`, `ChatFeedAuth`) stays in socialware. |
| `:receive` registered on a fixed module | `:receive` currently branches on `ctx.kind_module` inside `Behavior.Session` (User vs Agent). A parallel PR splits it into `user.receive` / `agent.receive`. The anon user RECEIVES session content via the membership-gated READ (`ChatFeed.snapshot/2` / the publisher snapshot), which is `:receive`-independent; tests assert the BEHAVIOR (membership-gated read passes), never a specific registered module, so they survive the split. |
| Oban GC | **No Oban in the codebase** (verified: zero `use Oban.Worker` / `oban` dep). GC is an **in-app periodic sweeper** (a small supervised `GenServer` using `Process.send_after/3`, the same idiom the codebase already uses for periodic work), NOT an Oban cron. This is the single largest design revision — OQ-5 below is re-answered accordingly. |
| `public_view` as a `:chat`-slice flag | `public_view` is a **Template-level config** (OQ-6, Allen-decided): the SessionTemplate's content decides whether sessions it materializes are publicly viewable. It threads through `SessionTemplate` content (a new `@config_atom_key`), not a per-session mutable flag. |

The membership-only PRINCIPLE (the load-bearing constraint, §2) is UNCHANGED by the
collapse — it was always expressed through `Membership.authorize/2`, which still
exists byte-for-byte under its new name. The collapse only renamed the modules the
design references; it did not weaken or move the security boundary.

---

## 1. Problem & context

A socialware page (the chat external SPA at `GET /socialware/chat?session_uri=…`,
served by `EzagentWeb.Socialware.ChatFeedController`) is mounted under the
`EzagentWeb.Plugs.RequireEntity` pipeline, which **bounces any request with no
`:current_entity_uri` session cookie straight to `/login`**. A first-time,
not-logged-in visitor following a shared socialware link never sees the page.
Allen's position: anonymous first-open is a BASIC, necessary feature. A visitor
must be able to VIEW the page anonymously, and only be guided to log in when they
try to WRITE.

The authorization model is the post-collapse **membership-gated publisher-read**:
`Ezagent.Session.Membership.authorize/2` is the one predicate — a caller may read a
session's `:session` slice iff it is a well-formed bare principal `%URI{}` that is
EITHER the session `owner_uri` OR a key of the `:session` slice `members` map.
`ChatFeed.snapshot/2` (the `:pull` read) and the publisher snapshot both call it;
`ChatFeedChannel` re-checks it LIVE on join AND on every advisory re-read, so an
ex-member's view clears immediately.

There is **no anonymous-entry / external-user / login-replacement flow today**
(verified: no `public_view`, no `external_user` / `guest` / `anon-` entity anywhere).
`ChatFeedAuth` mints a `{caller_uri, session_uri}` token but ONLY for an
already-signed-in principal.

This spec designs the missing flow **without changing the permission mechanism**:
everything is expressed through session MEMBERSHIP. The visitor reads because we
make them a member; they cannot write because their membership is read-only and
writes demand a real authenticated principal carrying the write cap.

---

## 2. The membership-only principle (the load-bearing constraint)

> **No new "non-member can read" session permission is introduced. Anonymous read
> is achieved by making the anonymous visitor a real session MEMBER (via an
> ephemeral anon-User entity), and read authz stays exactly
> `Ezagent.Session.Membership.authorize/2`.**

Consequences the whole design obeys:

1. **`Session.Membership` is untouched.** It already accepts "caller is a key of
   `members`". An anon-User URI placed in `members` reads by construction. We do
   NOT add an `is_anon?` branch, a `:guest` allow-list, or a non-member read path.
   (Satisfies `feedback_let_it_crash_no_workarounds` — no whitelist/shim.)
2. **The membership-mutation path is `chat.join` / `chat.leave` on
   `Behavior.Session`** — the SAME path every other member uses. Anonymous entry is
   a `chat.join` of the anon-User; login-replacement is `chat.leave` anon-User +
   `chat.join` real user. No bespoke membership writer.
3. **Write authority is a SEPARATE axis from read.** Read = membership. Write
   (`chat.send`) = the session-write cap, which the anon-User is NOT granted. A
   write attempt fails the normal CapBAC gate (dispatch step 5.5); the SPA catches
   the denial and guides to login. "Read-only membership" is the plain ABSENCE of a
   write cap, not a new member flag.
4. **Identity, not anonymity, on the token.** `ChatFeedAuth` already carries the
   caller identity (`entity://…` URI). The anon-User IS an identity, so it slots
   into the existing `ChatFeedAuth.issue_token(anon_user_uri, session_uri)` with no
   token change.

---

## 3. The anon-User entity (Kind / URI / caps / lifecycle)

### 3.1 Chosen design: a **flavor of the User Kind**, not a new Kind (OQ-1: confirmed)

**Decision: the anon-User is an `Ezagent.Entity.User` instance with an `anon-<random>`
name, created read-only and GC-eligible — NOT a new ephemeral Kind.**

Why a User flavor (re-verified post-collapse):

- `Session.Membership.valid_caller_uri?` delegates to `Ezagent.URI.bare_principal?/1`,
  which accepts `entity://<ws>/<user|agent|worker>/<name>`. A new scheme/type would
  be rejected — to keep "membership-only", the anon-User MUST be one of the three
  accepted entity types. `user` is the honest fit (a human visitor).
- The User Kind lazily demand-spawns via the `entity://` SpawnRegistry fn
  (`register_user_only_entity_spawn_fn`, and the `instance_message` overwrite) and
  hydrates caps from `users.caps_json` via `User.initial_caps_for_spawn/1`. An
  anon-User is a `users` row with a **read-only caps_json** (§3.3) → demand-spawns
  with NO session caps.
- A new Kind means a new SpawnRegistry handler, supervisor, snapshot plumbing,
  CapBAC registration — surface that the plugin-isolation north star
  (`feedback_north_star_plugin_isolation`) says NOT to add when an existing Kind
  already does the job.

Cost accepted: the anon-User appears in "list users" views. Mitigated by the
`anon-` name prefix (filterable) + GC (§3.4).

### 3.2 URI shape (OQ-2: viewed session's workspace — confirmed)

```
entity://<viewed-workspace>/user/anon-<random>
```

- **Workspace segment = the viewed session's workspace** (from
  `Ezagent.WorkspaceRegistry.lookup(session_uri)` → `Ezagent.Capability.workspace_of/1`).
  Load-bearing for §5: every workspace scope is derived from the entity's own
  workspace segment (`Ezagent.URI.entity_workspace_uri/1`), so binding the anon-User
  into the viewed session's workspace keeps it from being usable cross-workspace
  (Invariant #4/#13).
- **`anon-<random>`**: `<random>` is a URL-safe token
  (`:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)`), unguessable
  + collision-free. `Base.url_encode64` yields `-`/`_` which pass
  `Ezagent.URI.entity/3` segment validation. The `anon-` prefix makes the entity
  recognizable to GC + "hide anon" filters. (Note: the random tail may contain
  `_`/`-`; the GC + predicate match on the `anon-` PREFIX, which is sufficient.)

### 3.3 Caps — read-only by CONSTRUCTION (absence of the write cap) (OQ-3: absence — confirmed)

> **Post-collapse correction:** the anon-User's `users` row MUST NOT be created via
> `Ezagent.Domain.Identity.Users.create/3`, because that function UNCONDITIONALLY
> prepends `User.default_caps/1` — the broad `{kind: :session, behavior: :any,
> action: :any}` cap that is EXACTLY what lets a normal user attempt `chat.send`.
> The anon-User needs a read-only insert path that writes an EMPTY caps_json (no
> default_caps). This is a NEW, narrow minting function (`AnonUser.mint/1`), not a
> reuse of `Users.create/3`. (The original draft missed this because pre-collapse
> `Users.create` had the same prepend, but the draft asserted "read-only caps_json"
> without flagging the create-path conflict.)

Result, expressed entirely through the existing CapBAC chokepoint:

- **READ** needs no cap — `ChatFeed.snapshot/2` / the publisher snapshot authorize
  via `Session.Membership` (membership), and the anon-User IS a member. ✓ reads.
- **WRITE** (`chat.send`) goes through dispatch step 5.5, which derives the needed
  `{kind: :session, behavior: Behavior.Session, action: :send, instance:
  <session_uri>}` cap. The anon-User holds no session cap → `:unauthorized`. ✓ cannot write.

The anon-User keeps ONLY the structural self-Identity cap that
`Behavior.Identity.init_slice/1` auto-adds (so it can exist as a Kind) and NOTHING
session-behavioral.

### 3.4 Lifecycle — minted on grant, GC'd at 48h (OQ-5: in-app sweeper, 48h — REVISED)

- **Minted** when a session is granted anonymous view (§4.1) — i.e. on the first
  anonymous open of a public-view socialware page, bound to a visitor cookie so a
  RETURNING anonymous visitor keeps the same anon-User.
- **Backed by a `users` row** (read-only caps_json) PLUS a small **anon binding
  table** (OQ-4) recording `{cookie_id_hash, anon_user_uri, session_uri,
  workspace_uri NOT NULL, created_at, last_seen_at}`. The binding table is the GC
  index AND the cookie→entity resolver. Per Invariant #14 it carries `workspace_uri
  NOT NULL`.
- **GC / expiry**: abandoned anon-Users (no `last_seen_at` within the 48h TTL) are
  reaped: `chat.leave` from their session + delete the `users` row + delete the
  binding row + best-effort stop the Kind. **The sweeper is an in-app supervised
  `GenServer`** (`Ezagent.Socialware.AnonUser.Sweeper`) that re-arms via
  `Process.send_after/3` on a fixed interval (e.g. hourly), sweeping the binding
  table for `last_seen_at < now - 48h`. **NOT Oban** (absent from deps). Reaping an
  anon-User already replaced by login (§4.4) is a no-op (binding row gone).
- **Retired on login** (§4.4): leaved + GC'd immediately, membership migrated to the
  real user.

### 3.5 public_view — a TEMPLATE-level config (OQ-6: Template — confirmed/refined)

A session is anonymous-viewable iff the **SessionTemplate it was materialized from**
declares `public_view: true` in its content. This is a Template policy, not a
per-session mutable flag:

- Add `:public_view` to `SessionTemplate`'s `@config_atom_keys` (so string-keyed
  JSON-boundary input atom-coerces) and surface a `public_view?/1` reader that
  resolves the materializing Template for a session and reads its content flag.
- A session whose Template does NOT declare `public_view: true` is private — the
  anonymous GET bounces to `/login` and NO anon-User is minted.
- Rationale for Template-level (vs per-session): the Template is the authorization
  chokepoint for Kind creation (memory `project_creation_unification_pivot`); making
  public-view a Template policy means "is this class of session publicly viewable"
  is decided ONCE at the authorized creation surface, not re-litigated per session
  by whoever holds the session URI. It also composes with fork (a fork inherits or
  overrides the flag as configuration, per `feedback_fork_is_generic_template_concern`).

---

## 4. The four flows

### 4.1 First-open (anonymous GET → public-view check → anon-User minted + joined → token issued)

```
GET /socialware/chat?session_uri=<session://…>   (NO current_entity_uri cookie)
```

1. The chat route is **moved out of the `RequireEntity` pipeline** into the public
   `:browser` scope (alongside `/socialware/customer`). A controller branch then
   handles both authed and anon callers.
2. The controller resolves the visitor:
   - If `conn.assigns[:current_entity_uri]` is present → existing behavior: mint
     `ChatFeedAuth.issue_token(principal_uri, session_uri)`.
   - Else (anonymous):
     a. **Public-view gate** — if the session's Template is NOT `public_view: true`
        (§3.5), DO NOT mint; fall through to the login bounce (current behavior).
     b. Read the visitor cookie `socialware_anon` (signed, HttpOnly, SameSite=Lax).
        If it names a live anon-User already bound to THIS `session_uri`
        (binding-table lookup), reuse it.
     c. Else `AnonUser.mint(session_uri)` → fresh anon-User URI (§3.2) + read-only
        `users` row + binding row; set the cookie.
     d. **`chat.join`** the anon-User into the session (`Behavior.Session`'s `:join`
        via dispatch). This is the ONLY thing that makes the read authorized.
   - Either way, mint `ChatFeedAuth.issue_token(anon_user_uri OR principal_uri,
     session_uri)` and embed it in the SPA shell.

### 4.2 Read (membership-gated feed — unchanged)

No new read code path. The SPA connects `ChatFeedSocket` with `{session_uri, token}`;
`ChatFeedAuth.verify` recovers the anon-User `%URI{}`; `ChatFeedChannel.join`
subscribes + calls `ChatFeed.snapshot(session_uri, anon_user_uri)`, which calls
`Session.Membership.authorize/2`. The anon-User is a member → `:ok` → snapshot
renders. Live advisories re-read + re-authorize exactly as for a real member. If the
anon-User is later GC-leaved, the next advisory re-read returns `:unauthorized` and
the channel pushes `unauthorized` + closes (the existing fail-closed path).

### 4.3 Write-gate (a write by an anon-User → guided to login)

1. **Client:** the external SPA renders a "Log in to reply" affordance instead of a
   send button when the token's caller is an anon-User (cheapest correct UX +
   defense-in-depth). (OQ-7.)
2. **Server backstop (non-negotiable):** if a write IS attempted (crafted client),
   the `chat.send` dispatch fails CapBAC step 5.5 (`:unauthorized`, §3.3). The write
   surface surfaces that as "log in to continue", never a silent drop (Invariant
   #9). (`ChatFeedChannel` is read-only today; any future write handler MUST enforce
   this.)
3. The login CTA links to `/login?return_to=/socialware/chat?session_uri=…`.

### 4.4 Login-replacement (anon-User membership migrates to the real user)

On successful login, if the session has a `socialware_anon` cookie naming a live
anon-User:

1. Resolve the anon-User URI + bound `session_uri` from the binding table.
2. **Migrate membership (OQ-8):** join the real user FIRST (`:call`, await member
   set), THEN leave the anon-User (`:cast`) — never a no-member window; a brief
   both-member window is harmless. If the real user is already a member (OQ-9), skip
   the join.
3. **Retire the anon-User:** GC it immediately (delete `users` row + binding row +
   best-effort stop Kind). Clear the cookie.
4. **View continuity:** the SPA reconnects with a freshly minted `ChatFeedAuth` token
   for the REAL user; same session → same conversation, now with write enabled.

---

## 5. Security

1. **Cannot read OTHER sessions.** The anon-User is a member of exactly ONE session.
   `Session.Membership.authorize/2` is per-session. The `ChatFeedAuth` token binds
   `{caller_uri, session_uri}` — pointing it at a different `session_uri` fails
   token verification.
2. **Cannot escalate.** Read-only caps_json (§3.3): no write cap, no grant cap, no
   admin cap. It cannot `chat.send`, join others, grant caps, or invoke any session
   behavior.
3. **Workspace-scoped.** Its URI carries the viewed session's workspace segment, so
   even a leaked cap would be blocked cross-workspace by `Capability.cross_workspace?`.
   Not a `system://` principal; never holds a wildcard.
4. **Cannot read a private session by guessing.** A session is anonymous-viewable
   ONLY if its Template is `public_view: true` (§3.5). Otherwise the anonymous GET
   bounces to `/login` — no anon-User minted. Anonymous access is opt-in per Template.
5. **DoS / mass anon entities.** Mitigations: rate-limit anon-User creation per IP +
   per session (`EzagentWeb.RateLimiter`); cookie reuse caps growth (one entity per
   visitor per public session); GC bounds steady-state; optional per-session
   concurrent-anon ceiling (OQ-10).
6. **Cookie integrity.** `socialware_anon` is a signed (`Phoenix.Token`) value
   binding `{anon_user_name, session_uri}`, HttpOnly + Secure + SameSite=Lax. A
   tampered cookie fails verification → treated as "no cookie". The cookie does NOT
   authorize reads — the token + live membership do.
7. **No silent drops at the write surface** (Invariant #9): a denied write surfaces
   the login CTA.

---

## 6. The E2E user-path additions

(Full step-by-step in `docs/scenarios/35-external-user-anon-access/scenario.md`.) The
deterministic pre-gate (ExUnit, this pass) proves:

- **anon-mint + join + read** — `AnonUser.mint/1` creates exactly one read-only
  anon-User; after `chat.join`, `ChatFeed.snapshot/2` AUTHORIZES it (membership-gated
  read passes); a non-member is DENIED. (GREEN this pass.)
- **read-only-by-construction** — the minted anon-User's caps_json is empty (no
  `default_caps`), so `User.initial_caps_for_spawn/1` yields no session cap →
  `chat.send` would be denied. (GREEN: assert at the caps layer.)
- **public_view Template gate** — `public_view?/1` is true for a session whose
  Template declares it, false otherwise; the anon-access entry mints ONLY for a
  public-view session. (`@tag :pending_impl` until the `PublicView` reader +
  `:public_view` config key land.)
- **48h GC** — the sweeper reaps an anon-User whose `last_seen_at` is older than the
  TTL (leave + delete rows), and is a no-op for a fresh one. (`@tag :pending_impl`
  until the binding table + sweeper land.)
- **cross-session isolation** — an anon-User for session A fails
  `Session.Membership.authorize/2` for session B; the token bound to A fails verify
  for B. (GREEN this pass.)

The agent-browser LIVE tier (anonymous first-open renders; write prompts login;
post-login same session + anon gone; cross/non-public denial) is the scenario doc's
`§Verification` — run on the disposable stack, not in CI.

---

## 7. What is NOT changed (anti-drift guardrails)

- `Ezagent.Session.Membership.authorize/2` — byte-unchanged. No `is_anon?` branch,
  no allow-list.
- `ChatFeedAuth` token shape — unchanged (`{caller_uri, session_uri}`); the anon-User
  IS a `caller_uri`.
- `Behavior.Session` join/leave — unchanged; anonymous entry + login-replacement
  reuse them as-is.
- No new session permission, no non-member read path, no write cap for the anon-User.

NEW surface only: (a) a public route + controller branch that resolves/creates the
anon-User, (b) `AnonUser.mint/1` (read-only `users` row) + the binding table +
cookie, (c) the in-app GC sweeper, (d) the login-replacement hook, (e) the
`public_view` Template config + `PublicView.public_view?/1` reader, (f) rate-limits.
All OUTSIDE the read-authz core.

---

## 8. Honest assessment — what is underspecified (post-collapse)

- **The write path's home.** `ChatFeedChannel` is read-only today; where the SPA's
  send goes (channel handler / controller POST / reuse) is not settled. → OQ-7.
- **Atomicity of login-replacement** across a `:cast` leave + `:call` join is
  approximated (join-first), not transactional. → OQ-8.
- **The binding table schema** (per-tenant, `workspace_uri NOT NULL` per Invariant
  #14) is sketched, not migrated. → OQ-4.
- **The sweeper's supervision placement** (which app's supervision tree;
  socialware's, since it owns the anon flow) + interval are proposed, not pinned.
  → OQ-5.
- **`public_view` propagation through fork/materialize** — the flag is a Template
  content key; how a fork inherits/overrides it (default inherit) needs the
  fork-config audit. → OQ-6.

---

## 9. OPEN QUESTIONS for Allen — with the post-collapse answer

**OQ-1 — anon-User Kind choice.** A flavor of `Ezagent.Entity.User` (reuses lazy
demand-spawn + caps_json + `bare_principal?` acceptance; cost = appears in user
lists), OR a distinct `worker`-typed entity, OR a new ephemeral Kind. **Answer:
User flavor (confirmed) — unchanged by the collapse; the lazy-spawn + caps_json path
is intact.**

**OQ-2 — Workspace placement.** Viewed session's workspace vs. a global `anon`
workspace. **Answer: viewed session's workspace, `anon-` name prefix (confirmed) —
keeps it workspace-scoped where it reads; a global `anon` ws would fight Invariant
#4/#13.**

**OQ-3 — read-only as ABSENCE of write cap, or an explicit read-only cap?**
**Answer: absence (confirmed). Post-collapse caveat: this REQUIRES a new minting path
that does NOT go through `Users.create/3` (which prepends `default_caps`). The
read-only insert (`AnonUser.mint/1`) writes an empty caps_json.**

**OQ-4 — Binding table.** Confirm a per-tenant table `{cookie_id_hash, anon_user_uri,
session_uri, workspace_uri NOT NULL, created_at, last_seen_at}`. **Answer: dedicated
per-tenant table (confirmed, Invariant #14).**

**OQ-5 — GC policy.** TTL + mechanism. **Answer (REVISED for post-collapse): 48h TTL,
an in-app supervised `GenServer` sweeper re-arming via `Process.send_after/3`
(hourly), NOT Oban — Oban is absent from the dependency tree. Lives in socialware's
supervision tree.**

**OQ-6 — public_view placement.** **Answer: a SessionTemplate-level config
(confirmed/refined). Add `:public_view` to `SessionTemplate` content + a
`public_view?/1` reader; default private. Fork inherits the flag as configuration.**

**OQ-7 — write path home + gate.** **Answer: anon-User sees a login CTA (no working
send); the authed-member write path is a separately designed transport; the
server-side CapBAC denial is the non-negotiable backstop regardless.**

**OQ-8 — login-replacement atomicity.** **Answer: join-real-user-first then
leave-anon (no no-member window; a brief both-member window is harmless). Add a
`:replace_member` action only if the overlap proves problematic.**

**OQ-9 — real user already a member at login.** **Answer: skip the join; just leave +
GC the anon-User.**

**OQ-10 — per-session anonymous ceiling.** **Answer: yes, a configurable per-session
ceiling as DoS defense-in-depth (in addition to IP/session rate-limits).**

**OQ-11 — cookie scope.** One cookie per `{anon_user, session}` vs. a multi-binding
cookie. **Answer: support multiple bindings (map keyed by session_uri) so a visitor
browsing several public sessions keeps a distinct anon-User per session.**

---

## Appendix — original draft provenance

The pre-collapse draft was synthesized by a subagent from Allen's stated
requirements + the then-current codebase (branch `spec/external-user-anon-access`,
off `origin/main` with config-evolve #733 + the P4 chat external SPA #732). This
revision re-aligns it to `origin/main` @ `e689c91e` + P5 collapse PRs #741–#744 for
issue #51, and is the basis for the scenario doc + TDD tests delivered alongside.
