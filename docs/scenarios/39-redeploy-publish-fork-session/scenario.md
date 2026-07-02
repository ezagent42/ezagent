# Scenario 39: Re-deploy / publish — fork a NEW session, become its owner

**Category**: 3 — Session flows
**Status**: 🚧 design spec — publish → session-template → fork is not yet built,
and the `session template` concept is being reworked (APP absorption, in flight
2026-07-02); recorded against an **unimplemented blank-HTML placeholder**. Not ✅
(no test + no sign-off).
**Author**: Claude (with ruihua), 2026-07-02 — homesite user-journey stage 5.

> Bilingual lockstep mirror: [`scenario.zh_cn.md`](./scenario.zh_cn.md).

## Intent

The **second** propagation path. A user **re-deploys** (publishes) their session +
page → it is saved as a **session template** (discoverable in the plugin-market /
template list) → someone (the same user or another) **forks a NEW session** from
that template → the forker **becomes the owner** of the new session → and the
forker can **see their new session's conversation in world**. This is the
git-fork / tenant relationship: "he copied my template and started his own."

Contrast with scenario [38](../38-share-deploy-same-session/scenario.md) (deploy),
where the visitor joins the **same** session as a member. **publish = new session,
new owner, no history carried; deploy = same session, member, history kept.**
Making this pair visible is the payoff of the whole journey.

This is journey **stage 5**, built on scenario
[37](../37-homesite-dialog-world-sync/scenario.md).

## Pre-conditions

Standard preconditions (README §1.1), plus:

- **A live session to publish** — scenario 37 done: a signed-in author with a
  homesite page bound to a world session.
- **A publish affordance** — a control that saves the session + page as a **session
  template** (this is `publish`, distinct from `deploy`/`share`).
- **A discovery surface** — the plugin-market / template list where published
  templates appear (may be a placeholder dropdown for now, 2026-07-02 line 466).

## Actors

- **Author (A)**: the signed-in owner who publishes (from scenario 37).
- **Forker (C)**: a signed-in user (may be A) who instantiates the published
  template; **becomes the owner** of the resulting new session (a **tenant**, not
  an end-user).
- **Session template**: the published artifact (today's `session template`; being
  renamed/absorbing the `APP` concept, 2026-07-02).
- **New forked session**: `session://<workspace>/hello/<new-slug>` — C's own,
  distinct from A's.

## Steps

### Publish

1. **Author publishes** — A clicks re-deploy/publish on their session + page.
   → a **session template** is created from A's session config + page; it appears in
   the plugin-market / template list. Publish does **NOT** carry A's conversation
   history.

### Fork → new owned session

2. **Forker finds the template** — C opens the plugin-market / template list and
   finds A's published template (dropdown / list entry).
3. **Fork** — C selects it → a **NEW session** spawns from the template, **owned by
   C**, with C's own fresh page.
4. **C talks** — C sends messages in C's new session's page; the conversation is
   C's own (fresh, none of A's history).
5. **Owner sees their new session** — C opens **their own forked homesite page** and
   its `查看会话` panel → sees C's new session's conversation there. (The Word IM
   backend is where a tenant/developer configures replies internally, but the
   customer-facing observation stays on the homesite.)

## Expected outcomes

Behavior layer (membership/CapBAC substrate asserted in scenario 35; template
mechanics cross-ref scenario 21):

- Step 1: a session template exists and is discoverable in the list; A's history is
  **not** part of it.
- Step 3: the forked `session_uri` is **new** (≠ A's session); C holds **owner /
  tenant** caps on it.
- Step 4–5: C's conversation is fresh and is visible to C **in the `查看会话` panel
  of C's own page**; publish created a **new** session, not a join (the
  deploy/publish distinction holds).

## Failure modes to test

- **Join instead of fork** — C lands in A's session as a member instead of a new
  owned session. That is scenario 38 (deploy) behavior; for publish it is a bug.
- **History leaks into the fork** — A's conversation history bleeds into C's new
  session (publish must be clean, 2026-07-02 decision).
- **Forker isn't owner** — C gets member caps, cannot re-configure/re-publish
  (breaks the tenant relationship).
- **Template not discoverable** — publish "succeeds" but the template never appears
  in the list, so no one can fork it. Silent success = bug.

## Cross-references

- Scenario [38](../38-share-deploy-same-session/scenario.md) — the **other**
  propagation path (deploy/same session); 38 and 39 are the deploy-vs-publish pair.
- Scenario [37](../37-homesite-dialog-world-sync/scenario.md) — the live session
  being published.
- Scenario [21](../21-template-version-tag/scenario.md) — template instantiate /
  version-tag mechanics (the fork is a template spawn).
- Scenario [35](../35-external-user-anon-access/scenario.md) — membership/ownership
  substrate.
- Product decisions (2026-07-02 sync): publish = save-as session template + fork
  (git-fork), new owner, no history; plugin-market = session-template list; tenant
  vs end-user distinction.

## Notes

- **Concept in flight** — `session template` is being reworked today (林懿伦): the
  `APP` concept is being absorbed into it and it may be renamed. This scenario
  describes the **product behavior** (publish → fork → own), robust to the naming;
  update the template terms once the rework lands.
- **Recording placeholder** — publish, the plugin-market list, and fork-spawn are
  not yet built; record against an **unimplemented blank-HTML placeholder** (and a
  placeholder dropdown for the market list) until the real controls ship.
- **Versioning** — publishing N times creates N templates (versions kept, not
  overwritten; the simpler option chosen 2026-07-02 line 565). Out of scope for
  this scenario's happy path but noted for the failure matrix later.
- **Status 🚧.** Do NOT mark ✅ until a deterministic/live test + runbook +
  agent-browser recording exist and ruihua/Allen sign off.
