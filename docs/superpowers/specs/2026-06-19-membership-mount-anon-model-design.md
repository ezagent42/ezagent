# Unified membership-mount + anon model — design spec

**Date:** 2026-06-19 · **Author:** Claude (autonomous, Allen AFK with full-drive mandate) ·
**Status:** design, approved-in-principle (Allen co-designed the model 2026-06-19); awaiting async review.

This is **spec 甲** — the backend CapBAC piece and the **main current process** of the
"eliminate all system principals" north star (Decision #154). It is independent of **spec 乙**
(the LV/island frontend, `2026-06-19-frontend-islands-architecture-design.md`); the two meet only
at the anon-login UX seam (§6). Build 甲 first.

## 1. Motivation

Two long-standing problems share one root and one fix:

1. **System principals for chat fan-out.** `system://chat-reply` (agents posting replies) and
   `system://chat-router` (the receive fan-out) are ambient authorities that violate Decision #154
   ("every `granted_by` is a real entity"). They exist because **members don't hold the caps to
   participate** — agents have empty default caps ("chat receive only"), and the receive fan-out has
   no per-member cap to present, so it borrows a principal.
2. **Anonymous access is a bolt-on.** Anon users are a special mint (`Users.create_read_only` + a
   reserved `anon-` URI name-prefix detected by string-splitting in `Membership.anon_member?/1` and
   `Users.reserved_anon_name?/1`) — which violates "never key authorization off mutable display
   names" ([[uuid_is_canonical_identifier]]), and needs its own principals (`lv-anon-mount`,
   `socialware-gc`).

**Root:** participation authority is modeled inconsistently — a broad bootstrap-granted baseline for
users, nothing for agents, a special mint for anon, and ambient principals to paper the gaps.

**Fix (Allen's unified model, 2026-06-19):** **joining a session is ONE flow for every member; the
only difference is which cap set is MOUNTED at join, keyed on the member's class.** Anon becomes a
first-class state of a normal user (`confirmed: false`), not a special entity. Once members hold the
right caps, the chat principals dissolve.

A prior attempt at the user half (`feat/per-session-default-caps`, commit `e5b51888`) failed with 8
join-authorization failures. §5 explains why and how this spec fixes it.

## 2. Goals / non-goals

**Goals**
- A single join→mount flow; per-class cap tiers mounted at join.
- `confirmed` as a real entity attribute; retire the `anon-` name-prefix hack.
- Eliminate `chat-reply`, the receive half of `chat-router`, `lv-anon-mount`, `socialware-gc`
  (north-star ratchet 6 → ~2 + the separate `session-internal`/`template-materialize` + genesis).
- Anon→login takeover (route B): a confirmed user (new or existing) takes over the anon's session
  footprint; the anon is retired.
- `no_unowned` stays 0 throughout; every PR passes the full gate suite.

**Non-goals**
- The frontend (spec 乙). The anon-login *UX* lives there; this spec provides the *mechanism*.
- Interactive in-app OAuth login (#17 follow-up) — the takeover *mechanism* is here; the login UI is
  gated on spec 乙.
- `session-internal` and `template-materialize` elimination (separate; not fan-out) and the final
  `bootstrap`→`entity://system/user/admin` genesis collapse (last, separate).

## 3. The model

### 3.1 Member classes and cap tiers (mounted at join, scoped to the concrete session)
| Class | Detected by | Mounted tier (caps held BY the member, instance = this session) |
|---|---|---|
| **unconfirmed user** (anon) | `users.confirmed == false` | `cap(:session, Publisher.SessionImpl, :subscribe_from)` — view/stream history only, **no `:send`** |
| **confirmed user** | `users.confirmed == true` | the unconfirmed tier **plus** `cap(:session, Session, :send)` + `cap(:session, Session, :leave)` |
| **agent** | entity type `agent` | `cap(:session, Session, :send)` — provisioned **at spawn** (§4.3), not at join |

`:join` is never in a mounted tier — a member cannot self-grant the join it is performing (§3.3
covers join authority).

**Note on `:receive` (the fan-out delivery direction — distinct from the member-held tiers above).**
The receive fan-out dispatches `<entity>.receive` with `caller: session_uri` onto each member, so the
authority needed is the **session's** authority to deliver to the member, NOT a cap the member holds.
Eliminating `chat-router`'s receive use is therefore a PR-甲-4 decision between two options (§4 /
§7), not a member tier entry:
- **(R1) member-consent receive cap** — at join the member grants the SESSION
  `cap(<member_kind>, <Receive behavior>, :receive, instance: member)`, `granted_by: member`
  (self-consent: "I join, so I authorize this session to deliver to me"); the fan-out presents the
  matching held cap. In-CapBAC, always has a granter (the member). **Recommended** for north-star
  purity.
- **(R2) membership-gated cap-exemption** — mark `:receive` cap-exempt, gated UPSTREAM by the
  delivery fan-out's `valid_member?` filter (verified: the fan-out loop is the ONLY dispatcher of
  `:receive`). Simpler but widens the trust surface (advisor caution). Fallback if (R1) proves
  deadlock-prone at the join grant point.

### 3.2 `confirmed` — a real attribute
- Add `field(:confirmed, :boolean, default: false)` to the `users` schema (+ migration; backfill
  existing rows to `true` — they are real users).
- New registration → `confirmed: true`. Anon mint → `confirmed: false` (replaces `create_read_only`'s
  implicit anon-ness).
- `Membership.anon_member?/1` and `Users.reserved_anon_name?/1` → read the attribute; the reserved
  `anon-` naming convention retires (kept only as a transitional read-fallback during migration, then
  deleted).

### 3.3 Join authority comes from SESSION POLICY (the chicken-and-egg fix)
Join is authorized by the **session**, not by a cap the joiner pre-holds:
- **`public_view` session** → open join: anyone may join; the mounted tier is chosen by the joiner's
  class (unconfirmed → reduced; confirmed → full).
- **private session** → the owner/inviter authorizes the join (the add-member dispatch carries the
  inviter's authority); the existing **first-non-anon-join-becomes-owner** path (RFC #402) stays.
This removes the dependency on a universal participation baseline for join, so the baseline can be
narrowed/removed without breaking join (§5).

### 3.4 The mount mechanism
`Membership.mount_participation_caps/3` (generalizes the prior branch's `grant_participation_caps/3`):
at join, after membership is recorded, mount the class's tier onto the member —
- granter/authority = the session **owner** (`= effective_owner`, code-verified
  `session_creator.ex:329` `creator_uri || admin_uri()`, so always present), tag
  `{:rule, :session_participation, owner}` (concrete-instance + concrete-action ⇒ `rule_cap_bounded?`
  true ⇒ rule branch authorizes; `granted_by` = owner entity);
- dispatched `:async` (`:cast`) — dodges the Session→IdentityAdmin→`Session.owner`→`get_slice`
  deadlock (same hazard `grant_first_join_owner_cap` documents) and is best-effort (errors logged +
  telemetry, never abort the join).

### 3.5 Anon→login takeover (route B — Allen's override of route-A-primary)
One uniform path; "upgrade = re-join at a higher identity":
- A **confirmed** user (newly registered *or* pre-existing) joins the session → mounts the confirmed
  tier.
- The anon's **session footprint transfers** to that user: re-point `Session.ReadMarker` rows and
  session membership from `anon_uri` → `confirmed_user_uri` (the `AnonBinding` row, which links
  `anon_uri ↔ session_uri`, is the handle).
- The anon entity is then **retired** via the existing reap path (`AnonUser.GC` / `AnonBinding`).
- **New registration = create the confirmed user first, then the same transfer** — no separate
  promote-in-place path (route A is redundant because B's transfer machinery is needed for existing
  users regardless; one path is simpler).

## 4. Components & changes

- **`Ezagent.Users` / `Ezagent.Entity.User`** — `confirmed` column + migration + backfill;
  `anon_member?`/`reserved_anon_name?` read the attribute; **narrow `default_caps/1`**: drop the broad
  `cap(:session, :any, :any)` baseline; keep at most a narrow `cap(:session, Session, :join)` only if
  an audited self-join path still needs it (else remove entirely — §5).
- **`Ezagent.Behavior.Session.Membership`** — `mount_participation_caps/3` keyed on member class
  (§3.4); the existing `grant_first_join_owner_cap` stays.
- **Session join authorization** — `handle_join` consults session policy (§3.3): `public_view` →
  open; private → owner/inviter-authorized.
- **Agent spawn** (§4.3) — provision the agent its own session-scoped `Session:send`/`:receive` caps
  at spawn (the seam: Agent's `initial_caps` is empty by design; thread the session URI at spawn to
  mint the tier, granter = spawner/owner). Eliminates `chat-reply`: the cc/codex/echo/np/curl bridge
  adapters use the agent's OWN caps instead of `system://chat-reply`.
- **Delivery fan-out** (`Session.Delivery`) — `dispatch_receive_call` stops using
  `system_caps("chat-router")`; receive is authorized via R1 (session holds member-consent receive
  caps) or R2 (membership-gated cap-exemption) per §3.1. `chat-router`'s other two uses move
  separately: `sync_result` (agent/receive.ex:280) → agent self-authority;
  `cross_session_forward` (delivery.ex:80, Decision #97) → `{:rule, :cross_session_forward,
  created_by || ws-admin}` **+ same-workspace guard** (grep-verified: zero cross-ws dependents; every
  `cross_workspace` ref is a reject-guard, so the guard is consistent, not a #97 regression).
- **Anon family** — `lv-anon-mount` (LV mounts a `confirmed:false` user via the normal flow under the
  user's own authority) and `socialware-gc` (the reaper acts via admin/rule, or the anon's own
  `:leave`) both dissolve.

## 5. Why the prior branch failed, and the fix (load-bearing)

`feat/per-session-default-caps` removed the broad `default_caps` baseline and granted per-session caps
at join — but `Session.join` is itself cap-gated, and the cap that authorized *joining* came from the
very baseline being removed. Self-join paths lost join authority before the per-session grant could
run → 8 failures (the **chicken-and-egg**).

**Fix = MOUNT, never STRIP, + session-policy join authority (§3.3).** Don't grant everyone a broad
baseline then strip it for anon; grant the per-class tier *at* join, and authorize the join itself
from session policy (public → open; private → owner/inviter), not from a pre-held baseline. PR-甲-2
(§7) must **re-run the 8 prior failures** and show each is re-authorized by session policy; any that
genuinely needs a pre-held cap keeps ONLY a narrow `Session:join`.

## 6. Seam to spec 乙 (frontend)
The anon-login *UX* (the button/flow that triggers §3.5 takeover) lives in spec 乙. This spec exposes
the *mechanism*: a `confirm`/takeover behavior action (confirmed user joins + footprint transfer +
anon retire) callable from the frontend via the normal dispatch path. Spec 乙 references this; it does
not re-design it.

## 7. PR sequence (each: implement → subagent adversarial review → FULL gate suite → admin-merge)
- **PR-甲-1** — `confirmed` attribute + migration + backfill; `anon_member?`/`reserved_anon_name?`
  read it (behavior-preserving; no cap change yet). *Gate: anon still classified correctly via the
  attribute.*
- **PR-甲-2** (load-bearing) — `mount_participation_caps` by class + narrow/remove the `default_caps`
  baseline + session-policy join authz. **Re-run the 8 prior failures.** *Gates: unconfirmed holds
  ONLY the reduced tier; confirmed holds send; every prior join path still authorizes.*
- **PR-甲-3** — agent `Session:send`/`:receive` at spawn → eliminate `chat-reply` (bridge adapters
  use agent's own caps). *Ratchet −1.*
- **PR-甲-4** — receive authorization via R1 (member-consent receive cap, recommended) or R2
  (membership-gated cap-exemption) → delivery drops `chat-router` for receive; `sync_result`→self;
  `cross_session_forward`→rule + same-ws guard → eliminate `chat-router`. *Ratchet −1.*
- **PR-甲-5** — anon→login takeover (route B): `confirm`/takeover action + footprint transfer + anon
  retire. (Ties to #17 interactive login; UI in spec 乙.)
- **PR-甲-6** — eliminate `lv-anon-mount` + `socialware-gc` (fall out of the model). *Ratchet −2.*

After 甲: remaining principals are `session-internal` + `template-materialize` (separate, non-fan-out)
and `bootstrap` (genesis, last) — out of this spec's scope.

## 8. Testing / gates
- Per-PR: `system_principal_elimination_test` ratchet decrements; `no_unowned` stays 0; `no_admin`
  count/list; `no_wildcard`; `arch.scan` all_slices; `check_invariants`; `doc.scan`.
- Model-specific invariants: (a) an unconfirmed member, after join, holds EXACTLY the reduced tier
  (no `:send`); (b) the same user re-joining as confirmed holds `:send`; (c) removing the baseline
  breaks NO existing join path (the re-run of the 8 prior failures is the gate); (d) takeover
  re-points read-markers + membership and leaves no live anon row.
- **OWNER-ROOTED-JOIN GATE (Allen 2026-06-19 — the 甲-2 acceptance invariant).** This is THE
  correctness gate proving the chicken-and-egg fix: join authority is rooted at the session owner,
  never an ambient/universal baseline. Concretely:
  - **(g1)** a user holding NO broad baseline CANNOT self-join a PRIVATE session — it is rejected
    unless authorized by the owner (the owner adds them, or an owner-granted inviter does).
  - **(g2)** when a join IS authorized, the authorizing grant's `granted_by` == the session **owner**,
    EXCEPT the three principled exceptions: (i) **first-non-anon-join-becomes-owner** (no owner exists
    yet → self-authorized owner-claim); (ii) **ownerless-session fallback** `granted_by =
    entity://system/user/admin` (the #154 named extreme-case granter, per `anon_user.public_view_granter/1`);
    (iii) **system/boot joins** (e.g. admin → `session://system/default/main`) authorized by
    bootstrap/admin.
  - **(g3)** a `public_view` session admits a join via the public-view RULE (configurer = owner).
  A test that asserts (g1)–(g3) FAILS if join authority ever comes from a universal baseline — it is
  the invariant that "removing the baseline" is correct AND that authority is owner-rooted
  ([[feedback_completion_requires_invariant_test]]).
- Zero new test failures proven against a clean base ([[feedback_zero_new_failures_baseline_proof]]).

## 9. Risks
- **PR-甲-2 is the hard one** (the failed refactor). Mitigation: mount-don't-strip + session-policy
  authz + the 8-failure re-run as an explicit gate.
- **Migration/backfill** of `confirmed` on a live DB — additive column, default false, backfill
  existing→true; no destructive change ([[feedback_destructive_migration_anti_pattern]]).
- **Agent send-at-spawn** touches the spawn/provisioning seam (#17 cascade-adjacent) — keep it to the
  session-scoped send/receive tier; don't broaden.
