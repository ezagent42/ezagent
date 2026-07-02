# Scenario 39: Try world → re-create the homesite session as a new owned session

**Category**: 3 — Session flows
**Status**: 🚧 design spec — the Try-world entry into world + re-create-a-new-session
flow is not yet built, and the `session template` concept is being reworked (APP
absorption, in flight 2026-07-02); recorded against an **unimplemented blank-HTML
placeholder**. Not ✅ (no test + no sign-off).
**Author**: Claude (with ruihua), 2026-07-02 — homesite user-journey stage 5.

> Bilingual lockstep mirror: [`scenario.zh_cn.md`](./scenario.zh_cn.md).

## Intent

The **second** propagation path — the **opt-in-to-build / tenant** path. A visitor
who liked the homesite clicks **Try world** and **enters world** (this is the one
place the journey leaves the homesite, on the user's own initiative to build).
There, **based on the homesite session, they re-create a NEW session** — they
become its **owner** (a tenant), with no history carried over.

Contrast with scenario [38](../38-share-deploy-same-session/scenario.md) (deploy),
where the invitee **stays on the homesite** and joins the **same** session as a
member. **deploy = same session, stay on the homesite, member; stage 5 = a NEW
session, enter world, owner.** Making this pair visible is the payoff of the whole
journey: the homesite is where you *consume*; world is where you go to *own*.

This is journey **stage 5**. Its entry is the **Try world** CTA from scenario
[36](../36-homesite-browse/scenario.md); its source is the live session from
scenario [37](../37-homesite-dialog-world-sync/scenario.md).

## Pre-conditions

Standard preconditions (README §1.1), plus:

- **A live homesite session** — scenario 37 done: a signed-in user with a homesite
  page bound to a world session that carries some conversation.
- **Try world available** — the `试玩 · Try world →` CTA (scenario 36 step 6) opens
  world (`app.ezagent.chat`) in a new tab for a signed-in user.
- **Opt-in to build** — this stage is explicitly the visitor choosing to go deeper.
  Stages 0–4 never leave the homesite; stage 5 does, by the user's own action.

## Actors

- **Visitor → tenant (U)**: signed in; an end-user on the homesite who now chooses
  to enter world and **become the owner** of a new session (a tenant).
- **Source homesite session**: `session://<workspace>/hello/<slug>` — the session U
  was talking in on the homesite; the basis for the re-create.
- **New session in world**: `session://<workspace>/hello/<new-slug>` — U's own,
  distinct from the source.

## Steps

### Enter world (Try world)

1. **Click Try world** — from the homesite, U clicks `试玩 · Try world →`
   *(`.product-world .product-foot`, scenario 36 step 6)*.
   → a new tab opens world (`app.ezagent.chat/`), U already signed in.

### Re-create a new owned session

2. **Re-create from the homesite session** — in world, U re-creates a **NEW
   session based on the homesite session** (spawn a new session from the source's
   config).
   → a new session is created, **owned by U**; its `session_uri` ≠ the source's.
3. **Fresh conversation** — U talks in the new session; the conversation is U's own
   and **fresh** — none of the source homesite session's history is carried.
4. **Owner works in world** — U, now in world, sees and configures the new session
   there (world is where an owner/tenant operates the IM/replies — this is the
   deliberate "enter world to build" surface, not the customer-facing homesite).

## Expected outcomes

Behavior layer (ownership/membership substrate asserted in scenario 35; template
mechanics cross-ref scenario 21):

- Step 2: the re-created `session_uri` is **new** (≠ the source homesite session);
  U holds **owner / tenant** caps on it.
- Step 2: the new session is **based on the homesite session** (its config/shape is
  derived from the source — continuity of the thing U liked).
- Step 3: no source history bleeds into the new session (a clean re-create).
- Step 4: U observes/configures the new session in world (owner surface), distinct
  from the homesite customer surface.

## Failure modes to test

- **Join instead of re-create** — U lands in the **same** session as a member
  instead of a new owned session. That is scenario 38 (deploy) behavior; for stage
  5 it is a bug.
- **History leaks into the new session** — the source homesite conversation bleeds
  into U's re-created session (re-create must be clean).
- **User isn't owner** — U gets member caps, cannot re-configure the new session
  (breaks the tenant relationship).
- **Re-create loses the source shape** — the new session is a blank default, not
  based on the homesite session U liked (loses continuity / the reason they came).
- **Try world leaks while anon** — an anonymous visitor reaches world without the
  login gate (must stay gated per scenario 36 step 6).

## Cross-references

- Scenario [36](../36-homesite-browse/scenario.md) — the **Try world** CTA that is
  this stage's entry (step 6: signed-in → new tab to `app.ezagent.chat`).
- Scenario [38](../38-share-deploy-same-session/scenario.md) — the **other** path
  (deploy / same session / member, stays on the homesite); 38 and 39 are the pair.
- Scenario [37](../37-homesite-dialog-world-sync/scenario.md) — the source homesite
  session being re-created.
- Scenario [21](../21-template-version-tag/scenario.md) — template instantiate
  mechanics (a re-create may spawn from a session template under the hood).
- Scenario [35](../35-external-user-anon-access/scenario.md) — ownership/membership
  substrate.
- Product decisions (2026-07-02 sync): stage-5 ownership = Try world → enter world →
  re-create from the homesite session; new owner, no history; tenant (enters world
  to build) vs end-user (stays on homesite).

## Notes

- **User-facing vs backend** — the user's action is "Try world → re-create a new
  session based on this one, and own it." The **backend mechanism** may be
  save-as-session-template + spawn (the meeting's `publish`→template→fork), but that
  is an implementation detail behind the re-create; the `session template` concept
  is being reworked today (林懿伦, APP absorption) so this scenario describes the
  **product behavior**, robust to the naming.
- **This is the one stage that leaves the homesite** — consistent with "we present
  only the homesite to customers": stages 0–4 stay on the homesite; stage 5 is the
  user *choosing* to enter world to build/own.
- **Recording placeholder** — Try-world entry, the re-create flow, and the world
  owner surface are not yet built; record against an **unimplemented blank-HTML
  placeholder** until the real controls ship.
- **Versioning** — re-creating N times may create N templates/sessions (versions
  kept, not overwritten; simpler option chosen 2026-07-02 line 565). Out of scope
  for this scenario's happy path; noted for the failure matrix later.
- **Status 🚧.** Do NOT mark ✅ until a deterministic/live test + runbook +
  agent-browser recording exist and ruihua/Allen sign off.
