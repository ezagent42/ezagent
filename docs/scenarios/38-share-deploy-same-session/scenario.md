# Scenario 38: Share / deploy — invite others into the SAME session (group chat)

**Category**: 3 — Session flows
**Status**: 🚧 design spec — the share/deploy affordance is not yet built;
recorded against an **unimplemented blank-HTML placeholder** for the share action.
Not ✅ (no test + no sign-off).
**Author**: Claude (with ruihua), 2026-07-02 — homesite user-journey stage 4.

> Bilingual lockstep mirror: [`scenario.zh_cn.md`](./scenario.zh_cn.md).

## Intent

The **first** of two propagation paths. The session owner **shares** (deploys) the
homesite link; an invited visitor opens it, logs in, and **joins the SAME
session** — everyone lands in **one shared conversation** (group chat), with the
existing history preserved. The invited visitor is an **end user / group member**,
NOT a new owner. This is the "you and I are in the same group" relationship.

Contrast with scenario [39](../39-redeploy-publish-fork-session/scenario.md)
(re-deploy / publish), where the visitor **forks a NEW session** and becomes its
owner. **deploy = same session; publish = new session.** Getting this distinction
visible is the whole point of stages 4 and 5.

This is journey **stage 4**, built on scenario
[37](../37-homesite-dialog-world-sync/scenario.md) (the owner already has a live
page↔session).

## Pre-conditions

Standard preconditions (README §1.1), plus:

- **Owner has a live session** — scenario 37 done: a signed-in owner with a
  homesite page bound to a world session that already carries some conversation.
- **A share/deploy affordance** — a control on the page (or in world) that produces
  a **share link** for this session. This is `deploy`/`share`, distinct from
  `publish` (2026-07-02 product decision).
- **A second visitor** — user B, initially anonymous, with the share link.

## Actors

- **Owner (A)**: the signed-in owner of the world session (from scenario 37).
- **Invited visitor (B)**: initially anonymous; becomes a **member (end user)** of
  A's session after login — not an owner.
- **Shared world session**: the single `session://<workspace>/hello/<slug>` both A
  and B talk in.

## Steps

### Share

1. **Owner shares** — A clicks the share/deploy affordance on the page.
   → a share link for A's session is produced.

### Invited visitor joins the same session

2. **B opens the link** — B navigates to the share link → sees A's homesite page
   (external/anon view of A's session, cross-ref scenario 35).
3. **B write-gate → login** — B tries to write in the composer → gated to login
   (cross-ref scenario 36) → B logs in.
4. **B joins as a member** — after login, B is added as a **read/write member of
   A's SAME session** (not a new session).
5. **Group chat** — B sends a message; it appears in A's session; A sees B's
   message on A's page / in world. Both talk in one conversation; history from
   before B joined is preserved.

## Expected outcomes

Behavior layer (membership/CapBAC substrate asserted in scenario 35):

- Step 4: B's membership targets the **same** `session_uri` as A's page binding —
  no new session is spawned for B.
- Step 5: A and B are **two members of ONE session**; the conversation is shared;
  pre-join history is preserved (deploy keeps history, 2026-07-02 decision).
- Role: B is an **end user / member**, not an owner — B cannot re-configure or
  destroy A's session.

## Failure modes to test

- **Fork instead of join** — B gets a NEW session of their own instead of joining
  A's. That is the scenario 39 (publish) behavior; for deploy it is a bug.
- **B becomes owner** — B is granted owner/tenant caps instead of member caps
  (must stay end-user per the tenant/end-user distinction, 2026-07-02 line 409).
- **History lost** — B (or A) no longer sees the conversation from before B joined.
- **Anon write leak** — B writes before logging in (must stay gated, scenario 36).

## Cross-references

- Scenario [37](../37-homesite-dialog-world-sync/scenario.md) — the live page↔session
  this scenario shares.
- Scenario [39](../39-redeploy-publish-fork-session/scenario.md) — the **other**
  propagation path (publish/fork → new session); 38 and 39 are the deploy-vs-publish
  pair.
- Scenario [35](../35-external-user-anon-access/scenario.md) — anon→member join
  substrate (B's join is a membership authorize).
- Scenario [36](../36-homesite-browse/scenario.md) — B's write-gate→login.
- Product decisions (2026-07-02 sync): deploy/share = same session, keeps history,
  end-user member; tenant vs end-user distinction.

## Notes

- **Terminology** — the meeting settled: `share` today == `deploy` (direct use of an
  app, group chat, history kept). The affordance may later be split into
  `publish` (scenario 39) and `deploy`. This scenario is the **deploy** half.
- **Recording placeholder** — the share/deploy affordance and B's join flow are not
  yet built; record against an **unimplemented blank-HTML placeholder** for the
  share action until the real control ships. The membership join can be exercised
  against scenario 35's anon→member substrate where available.
- **Status 🚧.** Do NOT mark ✅ until a deterministic/live test + runbook +
  agent-browser recording exist and ruihua/Allen sign off.
