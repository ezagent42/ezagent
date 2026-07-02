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
(Try world → re-create a new owned session). It builds on scenario
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
- **How the user observes** — the composer's **查看当前session** button carries a red
  new-message count (badge); clicking it **enters world's 官网 session** to read the
  full conversation. There is no inline panel. `world` is the backend session
  substrate; the homesite shows only the badge + the jump.

## Actors

- **Visitor (signed in)**: a real `Ezagent.Entity.User`, a **member** of the bound
  world session (membership substrate = scenario 35).
- **World session**: `session://<workspace>/hello/<slug>` — the single
  conversation the page and world share.
- **World-side responder**: an agent configured on the session, or another member
  replying from the Word IM side.

## Steps

### Send — page → session (via the composer)

1. **Type + send** — in the homesite composer (enabled post-login), type into
   `.previewbar-input` and click `.previewbar-action` (now **send**, not the
   pre-login `登录`). → the message is written to the bound 官网 session.

### New-message badge (how the user knows)

2. **Badge bumps on every new message** — each new message in the 官网 session — the
   user's own send **and** any reply (an agent, or another member) — adds a red count
   to the **查看当前session** button. This is how the user learns their message
   landed and a reply arrived, **without leaving the homesite**.

### See the full session

3. **Click 查看当前session** → enter world's 官网 session and read the full
   conversation (the user's message + replies). The badge clears. The full session
   view lives in world; the homesite shows only the badge + the jump.

## Expected outcomes

Behavior layer (the CapBAC/membership substrate is asserted in scenario 35,
cross-referenced, not re-proven):

- Step 1: exactly one message is written to the bound 官网 session; its `session_uri`
  == the page's `data-session-uri` (no drift to another session).
- Step 2: each new message (user **or** agent) bumps the **查看当前session** badge by
  one; the badge reflects the session's new-message count for this viewer.
- Step 3: clicking **查看当前session** enters world's 官网 session showing the shared
  conversation (the sent message + replies); the badge clears.

## Failure modes to test

- **Message never reaches the session** — the composer "sends" but no session row is
  written and the badge never bumps. "If it fails, who knows?" → must surface an
  error, never a silent no-op.
- **Badge never updates on a reply** — the homesite isn't subscribed to the session's
  new-message signal, so the user never learns a reply arrived.
- **查看当前session opens the wrong session** — the deep-link resolves to a different
  session than the page's binding.
- **Badge doesn't clear** — after the user views the session in world, the count
  persists, so it always looks like there's unread activity.
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

- **Two backend deps are NOT built yet** (2026-07-02 sync): (1) world→homesite
  **new-message count push** that feeds the badge, and (2) the **deep-link** that
  opens world's 官网 session from 查看当前session. Both are world/backend features
  (see handoff → zyli). Until built, record against **unimplemented blank-HTML
  placeholders**; the send (composer→session) can run against the
  `docs/website-demo/v1` mock's `mock-ezagent-api.js`.
- **cookie caveat** — a homesite login currently rides a fornax-cookie override
  across `*.ezagent.chat` (2026-07-02 sync); this is a system-level issue, recorded
  but not fixed here. The signed-in precondition may need a real per-domain login
  when the override is removed.
- **Status 🚧.** Do NOT mark ✅ until a deterministic/live test + runbook +
  agent-browser recording exist and ruihua/Allen sign off.
