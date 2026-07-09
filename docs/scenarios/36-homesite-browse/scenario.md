# Scenario 36: Homesite visitor journey — browse → login-gate → gated CTAs

**Category**: 1 — Auth & access (login, tokens, membership)
**Status**: 🚧 design spec — recordable against the static mock
(`docs/website-demo/v1/`) NOW; real-site tier (`feat/website-framework-hello-prod-0630`,
app.ezagent.chat) + live agent-browser recording PENDING. Not ✅ (no invariant
test + no sign-off yet).
**Author**: Claude (with ruihua), 2026-07-02 — brainstormed from the visitor
journey; no separate spec doc (design lives in this scenario + the git history
of this branch).

> Bilingual lockstep mirror: [`scenario.zh_cn.md`](./scenario.zh_cn.md).

## Intent

A first-time **anonymous visitor** lands on the ezagent marketing homesite and
walks a single continuous journey: read the pitch → leave for the source (GitHub)
or jump to live progress (world.cup) → try to write in the bottom composer and
get **gated to login** → after login **return to the same homesite page** with
the nav flipped to a signed-in state → use the two product CTAs (`Try world`,
`Try hello`), each of which **re-checks auth** and, when signed in, opens the
target in a **new browser tab**.

This is the **marketing-surface** sibling of scenario
[35](../35-external-user-anon-access/scenario.md) (external anonymous access to a
socialware session). 35 owns the load-bearing anon-User + membership + write-gate
substrate; 36 exercises the same *anonymous → write-gate → login* pattern from the
public homesite and adds the **post-login gated-CTA** paths that 35 does not cover.

## Pre-conditions

Standard preconditions (README §1.1) apply, plus:

- **Recording target (near-term)**: the static mock at `docs/website-demo/v1/`
  served locally (`cd docs/website-demo/v1 && npx --yes serve . -l 8080`), with its
  `mock-ezagent-api.js` + `login.html`. Selectors in this scenario are anchored to
  the authoritative visual reference `~/Desktop/Socialware.html` (a saved
  socialware-external render of the homesite); the **in-development real site
  differs from v1**, so steps are described by **role/text**, not by brittle
  structural classes.
- **Visitor state**: fresh browser, no session cookie → the page renders in the
  anonymous viewer state (`data-viewer="anon"`; composer input `disabled`).
- **Login credentials**: a real login is only needed for steps 4–6. Use any
  seed-provisioned user (README §1.1 self-serve token recipe) or the mock's
  `login.html` when recording against v1.

## Actors

- **Visitor (anonymous)**: `entity://system/user/anon-<rand>` — the read-only
  anon-User flavor from scenario 35 (empty `caps_json`; reads via membership,
  `chat.send` denied at CapBAC step 5.5).
- **Visitor (after login)**: a real `Ezagent.Entity.User` with a session cookie.
- **Surfaces**: the homesite page; nav pill (`.navlinks`); bottom composer
  (`.previewbar`, anon → `disabled`).
- **External targets**: `github.com/ezagent42` (source repo); `app.ezagent.chat/`
  (world app, new tab); the hello builder (new tab — **blank-HTML placeholder for
  now**).

## Steps

Selector column gives the **role/text** (contract) and the structural hint (`—`
reference only, from Socialware.html; the real site may differ).

### Anonymous browse

1. **GitHub via nav** — click the nav link `↗ GitHub`
   *(a[href="https://github.com/ezagent42"] in `.navlinks`)*.
   → browser navigates to `github.com/ezagent42`.
2. **GitHub via hero CTA** — from the hero, click `开始使用 · Get started →`
   *(primary `.cta [data-slot=button]`)*.
   → same destination as step 1: `github.com/ezagent42` (Get started == source repo,
   per ruihua 2026-07-02).
3. **Jump to progress** — click `看看进度 · See progress`
   *(secondary hero CTA)*.
   → page smooth-scrolls to the **world.cup** section (the `研发进度 · Progress`
   tab panel, `.worldcup`, label `PROGRESS · world.cup`). If world.cup lives inside
   a tab, the click also activates that tab before scrolling.

### Write-gate → login

4. **Composer write attempt** — the bottom composer input is `disabled` with
   placeholder `登录后参与`; click the composer action button `登录`
   *(`.previewbar-action`)*.
   → the anonymous write attempt is **replaced by a login flow** (no silent drop —
   the visitor is told to log in). This is the same write-gate as scenario 35.
5. **Login + return** — complete login. On success the visitor is **returned to
   the same homesite page** (NOT `/admin`, NOT a bare `/`), and the nav
   `登录 · Login` button *(`.navlinks [data-slot=button][data-variant=secondary]`)*
   flips to a **signed-in state** (`已登录`). The composer input becomes enabled.

### Post-login gated CTAs

6. **Try world** — click the world product CTA `试玩 · Try world →`
   *(`.product-world .product-foot [data-slot=button]`)*.
   → **if anonymous**: re-gated to login (same as step 4). **If signed in**: opens
   `app.ezagent.chat/` in a **new browser tab** (`target=_blank`), homesite tab
   stays put.
7. **Try hello** — click the hello product CTA `试玩 · Try hello →`
   *(`.product-hello .product-foot [data-slot=button]`)*.
   → **if anonymous**: re-gated to login. **If signed in**: opens the **hello
   builder** in a new tab (currently a **blank-HTML placeholder** page).

## Expected outcomes

Marketing surface — outcomes are asserted at the **visible-behavior** layer
(this is transport, not a router副作用; the CapBAC denial substrate is asserted
in scenario 35, cross-referenced, not re-proven here):

- Steps 1–2: top-level document URL == `github.com/ezagent42`.
- Step 3: the world.cup section is scrolled into view (its heading visible; the
  Progress tab is active if tabbed).
- Step 4: an anonymous composer write never posts a message; it lands on login.
- Step 5: post-login document URL == the homesite path (round-trip preserved);
  nav shows the signed-in (`已登录`) affordance; composer input `disabled` → enabled.
- Steps 6–7 (signed in): exactly **one new tab** opens per click, targeting
  `app.ezagent.chat/` and the hello builder respectively.
- Steps 6–7 (anonymous): no new tab; lands on login.

## Failure modes to test

- **Auth-gate leak** — clicking `Try world` / `Try hello` while anonymous opens
  the target app directly instead of login. The gate is load-bearing; a leak
  means an anon user reaches an authed surface.
- **Login return loses context** — after login the visitor lands on `/admin` or a
  bare `/` instead of the homesite page they left. The return-URL must round-trip
  the homesite.
- **Silent CTA failure** — the new-tab open is popup-blocked or `target=_blank`
  is missing, so the CTA click does nothing visible. "If it fails, who knows?" →
  must degrade to a visible navigation or an error, never a no-op.
- **Stale nav state** — after login the nav still shows `登录 · Login` (state not
  re-rendered), so the visitor can't tell they're signed in.
- **Anchor miss** — `See progress` scrolls to the wrong section, or (when tabbed)
  fails to activate the Progress tab so world.cup stays hidden.

## Cross-references

- Scenario [35](../35-external-user-anon-access/scenario.md) — anon-User +
  membership + write-gate→login substrate this scenario reuses.
- Visual/structural reference: `~/Desktop/Socialware.html` (saved
  socialware-external render of the homesite).
- Recording mock: `docs/website-demo/v1/` (index.html, hello-demo.html,
  login.html, site-nav.js, worldcup.js, mock-ezagent-api.js).
- Real-site build: `feat/website-framework-hello-prod-0630` (T4,
  `docs/together/2026-06-30/plan.md`); production target
  `app.ezagent.chat`.
- Socialware external route: `/socialware/external`
  (`apps/ezagent_web/lib/ezagent_web/router.ex:157`).

## Notes

- **Status is 🚧 on purpose.** The login-return, `已登录` nav flip, and gated
  new-tab CTAs are **intended behavior not yet fully built** on the real site.
  Do NOT mark ✅ until a deterministic/live test + a runbook + an agent-browser
  screenshot exist and ruihua/Allen sign off (`feedback_completion_requires_invariant_test`).
- **Recording notes (path A).** This design scenario is the map for the Playwright
  recorder to come. Model the recorder on `scripts/demo/agent-create-record.js`:
  `login()` → store `storageState` → `recordVideo` context → drive steps 1–7 by
  role/text selectors + `snap()` per step → close → rename `demo.webm` → ffmpeg to
  GIF/MP4. Steps 6–7 open new tabs — the recorder must await `context.on('page')`
  (the popup) and capture it, or the video misses the new-tab content.
- **hello builder** is a blank-HTML placeholder until its real page ships; the
  scenario asserts "a new tab opens to the hello builder", not its contents.
