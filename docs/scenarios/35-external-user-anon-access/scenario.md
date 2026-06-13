# Scenario 35: External-user anonymous access (membership-only)

**Category**: 1 — Auth & access (login, tokens, membership)
**Status**: 🚧 deterministic tier PARTIAL (mint/join/read + isolation GREEN;
public_view gate + 48h GC `@tag :pending_impl`); live tier = Allen / agent-browser runbook
**Author**: Claude, issue #51 (spec
`docs/superpowers/specs/2026-06-12-external-user-anonymous-access-design.md`)

> Bilingual lockstep mirror: [`scenario.zh_cn.md`](./scenario.zh_cn.md).

## Intent

An **anonymous external user** following a shared socialware link must be able to
**VIEW** the session — but ONLY a session whose Template was marked
`public_view: true`, and ONLY because we make them a real, read-only session
**member**. They cannot read any other session, and any attempt to WRITE guides
them to log in. The access model is **membership-only**: there is no new
"non-member can read" permission — anonymous read is a real
`Ezagent.Session.Membership.authorize/2` membership read by an ephemeral anon-User.

This is the B-line E2E wrap-up's anonymous-first-open → write-gate →
login-replacement user-path that the authenticated-member + customer-delivery gates
did not exercise.

## The anon-User (the load-bearing primitive)

- An anon-User is a flavor of the `Ezagent.Entity.User` Kind:
  `entity://<viewed-workspace>/user/anon-<random>`. The `anon-<random>` name is an
  unguessable URL-safe token; the `anon-` prefix is the GC + filter handle.
- It is minted **read-only by construction**: its `users.caps_json` is EMPTY (no
  `User.default_caps/1`), so `User.initial_caps_for_spawn/1` hydrates it with no
  session cap. It holds only the structural self-Identity cap. → it READS (via
  membership) but a `chat.send` is denied at CapBAC step 5.5.
- Its workspace segment = the viewed session's workspace, so it can never be used
  cross-workspace.
- It is GC'd 48h after `last_seen_at` by an in-app supervised sweeper (NOT Oban —
  Oban is absent from the dependency tree).

## public_view is a TEMPLATE-level config

A session is anonymous-viewable iff the SessionTemplate it was materialized from
declares `public_view: true`. A session whose Template does NOT declare it is
private — the anonymous GET bounces to `/login` and NO anon-User is minted. The
decision is made ONCE at the authorized creation chokepoint (the Template), not
re-litigated per session by a URL holder.

## The user-path (the property under test)

```
1. A session is materialized from a public_view Template.
2. Anonymous visitor opens GET /socialware/chat?session_uri=<that session>.
   → anon-User is minted + chat.join'd + a ChatFeedAuth token is issued.
   → the membership-gated snapshot renders (NOT a /login bounce).
3. The visitor tries to reply → "Log in to reply" CTA (no message sent);
   a crafted send is denied :unauthorized (no silent drop).
4. The visitor logs in → the SAME session renders, now with a working compose box;
   the anon-User has left + been GC'd.
5. A DIFFERENT (or non-public) session is NOT readable by this anon-User /
   anonymous visitor.
6. 48h after abandonment the anon-User is reaped (left + rows deleted).
```

The no-new-permission invariant: read advances ONLY through
`Session.Membership.authorize/2` (membership of the live `:session` slice). No
`is_anon?` branch, no guest allow-list, no non-member read path is introduced.

## Verification — TWO tiers

### Tier 1 — Deterministic ExUnit tests (CI)

The fast pre-gate lives in `apps/ezagent_domain_socialware/test/ezagent/socialware/`:

| File | What it proves | State |
|---|---|---|
| `anon_user_test.exs` | `AnonUser.mint/1` mints exactly one read-only anon-User (`anon-` prefix, viewed-workspace segment, EMPTY caps_json so `User.initial_caps_for_spawn/1` yields no session cap); `anon_uri?/1` predicate | GREEN |
| `anon_access_membership_test.exs` | after `chat.join` of the minted anon-User, `ChatFeed.snapshot/2` AUTHORIZES it (membership-gated read passes); a non-member / a DIFFERENT session is DENIED; the `ChatFeedAuth` token bound to session A fails `verify` for session B (cross-session isolation) | GREEN |
| `anon_public_view_test.exs` | `PublicView.public_view?/1` is true iff the session's Template declares `public_view: true`; the anon-access entry mints ONLY for a public-view session | `@tag :pending_impl` |
| `anon_user_gc_test.exs` | the sweeper reaps an anon-User whose `last_seen_at` is older than the 48h TTL (leave + delete `users`/binding rows) and is a no-op for a fresh one | `@tag :pending_impl` |

Run:

```bash
cd apps/ezagent_domain_socialware && MIX_ENV=test mix test \
  test/ezagent/socialware/anon_user_test.exs \
  test/ezagent/socialware/anon_access_membership_test.exs
```

The two `:pending_impl` files are the TDD definition of the not-yet-built
`PublicView` reader + the binding table + the GC sweeper; they are tagged
`:pending_impl` so CI's default `--exclude pending_impl` keeps the suite green while
the failing tests stand as the executable spec.

### Tier 2 — LIVE agent-browser runbook (Allen's disposable stack — the TRUE gate)

On the disposable stack (`http://100.64.0.27:10044`, dev mode, fresh seed), with one
seeded session materialized from a `public_view: true` Template and a login user
`e2e-visitor` (self-generated password):

- **35a [VISUAL] Anonymous first-open renders.** Fresh browser context (no cookies),
  open the public session's `/socialware/chat?session_uri=…`. Screenshot: the chat
  snapshot renders; URL did NOT become `/login`. Server assert: an
  `entity://<ws>/user/anon-…` member now exists in the session's `:session`
  `members`.
- **35b [VISUAL] Write attempt prompts login.** Click the reply affordance.
  Screenshot: a "Log in to reply" CTA; no message sent. Server assert: a crafted
  send is denied `:unauthorized` / `:login_required` (no silent drop).
- **35c [VISUAL] Post-login = same session, anon gone.** Follow the CTA, log in as
  `e2e-visitor`. Screenshot: the SAME session renders with a WORKING compose box.
  Server assert: `e2e-visitor` is a member; the `anon-…` user is no longer a member
  and its `users` + binding rows are deleted.
- **35d [VISUAL/AUTHZ] Cross / non-public denial.** Another fresh context: a
  non-public session URL bounces to `/login` (no anon-User minted); pointing an
  anon-User's session-A token at session B is denied. Screenshot the denial/bounce.
- **35e [REGRESSION] Anon entry does not weaken the member gate.** After a GC-leave
  of the anon-User, its rendered view CLEARS immediately (the existing
  `unauthorized` push + close), WITHOUT a subsequent message — the anon-User is
  gated by the SAME live membership predicate as a real member.

The live tier is run on the disposable stack, not in CI; screenshots 35a–35c attach
to the Feishu thread.

## What this scenario locks (anti-drift)

- `Ezagent.Session.Membership.authorize/2` stays byte-unchanged — anonymous read is
  a membership read, full stop.
- The anon-User is read-only by the ABSENCE of a write cap, never by a new member
  flag or a guest allow-list.
- `public_view` is a Template policy decided at the authorized creation chokepoint,
  not a URL-holder's per-session toggle.
