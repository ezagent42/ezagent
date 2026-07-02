# Scenario 37: Homesite dialog ↔ world session (bidirectional sync)

**Category**: 3 — Session flows
**Status**: 🚧 design spec — backend dialog wiring NOT yet connected (per
2026-07-02 product sync); the world→page reply surface is recorded against an
**unimplemented blank-HTML placeholder** until built. Not ✅ (no test + no
sign-off).
**Author**: Claude (with ruihua), 2026-07-02 — homesite user-journey stage 3.

> Bilingual lockstep mirror: [`scenario.zh_cn.md`](./scenario.zh_cn.md).

## Intent

The load-bearing claim of the whole homesite story: **talking on the homesite
page IS talking in a world session.** A signed-in visitor who types into the
homesite composer is writing into the **world session the page is bound to**; and
a reply produced **inside that world session** (by an agent or another member)
flows back and renders **on the homesite page**. The homesite page is one front
face of a world session, and the sync is **bidirectional**.

This is journey **stage 3** — the spine the whole product demo hangs on. It is the
prerequisite for scenario [38](../38-share-deploy-same-session/scenario.md) (share
→ same session) and [39](../39-redeploy-publish-fork-session/scenario.md)
(re-deploy → fork). It builds on scenario
[36](../36-homesite-browse/scenario.md) (the visitor is already signed in after
36's login-gate).

## Pre-conditions

Standard preconditions (README §1.1), plus:

- **Signed in** — the visitor completed scenario 36 stage 2 (login-gate → return →
  `已登录`); the composer input is **enabled**.
- **Page ↔ session binding** — the homesite page is a hello product bound to one
  world session (reference: `data-session-uri="session://system/hello/web"` in
  `~/Desktop/Socialware.html`). Each opened hello page == one session (product
  decision, 2026-07-02).
- **World surface** — the same session is observable in world/Word (IM backend),
  e.g. `/admin/sessions/<session-uri>` or `app.ezagent.chat` world session view.

## Actors

- **Visitor (signed in)**: a real `Ezagent.Entity.User`, a **member** of the bound
  world session (membership substrate = scenario 35).
- **World session**: `session://<workspace>/hello/<slug>` — the single
  conversation the page and world share.
- **World-side responder**: an agent configured on the session, or another member
  replying from the Word IM side.

## Steps

### Outbound — page → world

1. **Send from the page** — in the homesite composer (enabled post-login), type a
   message and send *(`.previewbar-input` + `.previewbar-action`, now in the
   signed-in state)*.
2. **Observe in world** — open the same session in world/Word.
   → the message posted on the page **appears in the world session**, attributed to
   the signed-in visitor, in the **same** `session_uri` the page is bound to.

### Inbound — world → page

3. **Reply from world** — in the world session, produce a reply (an agent answers,
   or another member sends a message from Word).
4. **Observe on the page** — return to the homesite page (do not reload).
   → the world-side reply **propagates back and renders on the homesite page**
   feed, live, without a manual refresh.

## Expected outcomes

Behavior layer (the CapBAC/membership substrate is asserted in scenario 35,
cross-referenced, not re-proven):

- Step 1–2: exactly one message is written to the bound world session; its
  `session_uri` == the page's `data-session-uri` (no drift to another session).
- Step 3–4: the world-side reply renders on the page feed live; the page and world
  show **one shared conversation**, not two copies.
- Round-trip identity: a message sent on the page and a reply from world are both
  members of the **same** session timeline.

## Failure modes to test

- **Page message never reaches world** — the composer "sends" but no world session
  row appears. "If it fails, who knows?" → must surface an error, never a silent
  no-op.
- **World reply never reaches the page** — the page never subscribed to the session
  publisher, so world-side replies are invisible until a manual reload.
- **Wrong-session drift** — the page writes to a different session than its binding
  (e.g. a fresh session per keystroke), breaking the "page == one session" invariant.
- **Anon write leak** — an anonymous visitor manages to write into the session
  (must stay gated per scenario 36).

## Cross-references

- Scenario [36](../36-homesite-browse/scenario.md) — the login-gate that puts the
  visitor into the signed-in state this scenario starts from.
- Scenario [35](../35-external-user-anon-access/scenario.md) — anon-User +
  membership read/write substrate.
- Journey stages 4–5: [38](../38-share-deploy-same-session/scenario.md),
  [39](../39-redeploy-publish-fork-session/scenario.md).
- Product decisions (2026-07-02 sync): world = IM backend, hello = display face;
  each hello page == one session.
- Socialware external route + binding: `/socialware/external`
  (`apps/ezagent_web/lib/ezagent_web/router.ex:157`);
  `data-session-uri` on `~/Desktop/Socialware.html`.

## Notes

- **Backend dialog wiring is NOT connected yet** (2026-07-02 sync: "对话交互还没
  接"). Until the world↔page bridge is built, the **inbound (world→page) reply
  surface is recorded against an unimplemented blank-HTML placeholder** — the
  scenario asserts "a world reply renders on the page", and the placeholder stands
  in for the not-yet-built propagation. Outbound (page→world) can be recorded
  against the `docs/website-demo/v1` mock's `mock-ezagent-api.js` when available.
- **cookie caveat** — a homesite login currently rides a fornax-cookie override
  across `*.ezagent.chat` (2026-07-02 sync); this is a system-level issue, recorded
  but not fixed here. The signed-in precondition may need a real per-domain login
  when the override is removed.
- **Status 🚧.** Do NOT mark ✅ until a deterministic/live test + runbook +
  agent-browser recording exist and ruihua/Allen sign off.
