# Homesite user journey — overview map (scenarios 36–39)

**Status**: draft — 2026-07-02. Author: Claude (with ruihua), from the 2026-07-02
product sync + ruihua's product-relationship model.

> Bilingual lockstep mirror: [`homesite-journey.zh_cn.md`](./homesite-journey.zh_cn.md).

## What this is

The connective map for the homesite E2E cluster. A single anonymous visitor walks
one continuous journey from landing on the ezagent homesite to entering world and
owning their own re-created session — and each leg is codified as one 1:1 scenario
(36–39). This doc is
the **overview**; the scenarios are the **detail**. It exists so a reader sees the
whole product story before reading any single scenario, and so the recording
(agent-browser / Playwright) has one narrative to follow.

## The three products (the ground the journey stands on)

```
hello    = generation / display face   one-sentence → a page; the homesite page IS a hello product
world    = IM / session backend        where the conversation really lives; the owner watches it here
homesite page = a hello product bound to ONE world session (a front face of that session)
```

> **One-line anchor**: *talking on the homesite page is not leaving a comment on a
> web page — it is talking inside the world session the page is bound to.* The page
> is just one face of that session.

> **The homesite is the customer's primary surface** — where they browse and talk.
> `world` is the backend session substrate + the full session/IM view. Two explicit
> buttons bridge the homesite into world: **查看当前session** (view the full session)
> and **Try world** (own a new session). The customer talks on the homesite; a red
> badge tells them when there's new activity; they enter world only by clicking one
> of those two buttons.

## The composer bar — talk here, jump to the session

The bottom composer bar on the homesite (`.previewbar` in the reference
`~/Desktop/Socialware.html`) is where the user talks into the bound world session.

```
┌─ homesite composer bar (.previewbar) ─────────────────────────────────┐
│  [ type here… (登录后参与) ]   [ 登录 / send ]   [查看当前session ⑤]   │
│   .previewbar-input             .previewbar-action    (red count badge) │
└────────────────────────────────────────────────────────────────────────┘
```

- **Talk**: type into `.previewbar-input`, click `.previewbar-action` — pre-login it
  reads `登录` (write-gate, stage 2); post-login it becomes **send**.
- **New-activity badge**: every new message in the 官网 session (from the user **or**
  an agent) adds a red count on **查看当前session**; it clears when the user opens the
  session. This is how the user knows their message landed and that a reply arrived,
  without leaving the homesite.
- **See the full session**: click **查看当前session** → enter world's 官网 session
  (the full conversation lives in world; the homesite shows the badge).
- **Removed**: the composer's old `选择` button and the inline `查看会话` panel are
  gone — replaced by the single `查看当前session` button + badge.

## The journey (6 stages)

| Stage | User action | Underlying product relationship | State change | Scenario |
|---|---|---|---|---|
| **0 page == session** | open the homesite page | page = a hello product bound to one world session; anon sees that session's external face | anonymous viewer | premise, cross-ref 35 |
| **1 anonymous browse** | GitHub / See progress | pure display, no session write | none | 36 |
| **2 write-gate → login** | write in the bottom composer | anon cannot write the session → gated | anon → login → signed-in | 36 |
| **3 dialog == talking in world** | type + send in the composer; **查看当前session** badge +1 on each new message; click it to enter world | the message lands in the 官网 session; new messages (user **or** agent) bump the badge; clicking enters world to read | becomes a session member | **37** |
| **4 share → same session** | share (from the homesite **or** from world) | invitees join the **SAME** session (group chat, history kept); each new message bumps everyone's badge | invitee = end user / member | **38** |
| **5 enter world → re-create as a new owned session** | click **Try world** (opt-in to build) → enter world | based on the homesite session, **re-create a NEW session** in world; the user becomes its **owner** (no history carried) | user = new owner / tenant | **39** |

## The decisive fork: two propagation paths (stages 4 & 5)

This is where the journey actually demonstrates the product relationships — the same
page, shared vs re-deployed, means two completely different product semantics:

```
┌─ stage 4  share / deploy ─────┐   ┌─ stage 5  Try world → re-create ────┐
│ the SAME session              │   │ a NEW session                        │
│ stay on the homesite          │   │ enter world (opt-in to build)        │
│ many people, one conversation │   │ re-create from the homesite session  │
│ history preserved             │   │ no history carried                   │
│ invitee = end user (member)   │   │ user = tenant / owner                │
│ "you and I are in one group"  │   │ "I liked it — now I own my own"      │
└───────────────────────────────┘   └──────────────────────────────────────┘
        end-user view                          tenant / owner view
        stays on the homesite                  enters world via Try world
```

stage 4 and stage 5 are written as **scenarios 38 and 39** — each is the other's
failure mode (38 asserts "spawn a new session instead of joining = bug"; 39 asserts
"join the same session instead of re-creating a new one = bug"), which forces the
backend's session semantics to be exact.

## Scenario mapping

- **36** — stages 0–2: anonymous browse + login-gate.
- **37** — stage 3: homesite dialog ↔ world session (bidirectional sync). The spine;
  prerequisite for 38 and 39.
- **38** — stage 4: share / deploy → same session (group chat, end-user member).
- **39** — stage 5: Try world → enter world → re-create the homesite session as a
  new owned session (new owner / tenant).

## Recording note

Everything downstream of stage 2 depends on backend wiring that is **not yet
connected** (2026-07-02 sync). Until built, the not-yet-implemented surfaces
(world→page reply propagation, the share affordance, the Try-world entry into world,
the re-create-a-new-session flow) are recorded against **unimplemented blank-HTML
placeholders** — the scenarios
assert the intended behavior, the placeholders stand in for the missing pieces. The
recorder is modelled on `scripts/demo/agent-create-record.js` (Playwright
`recordVideo`), driven by the role/text selectors each scenario specifies.

## Product decisions this journey encodes (2026-07-02 sync)

- Each opened hello page == one session.
- world = IM backend (owner watches / configures replies); hello = display face.
- `deploy`/`share` = same session, stay on the homesite, keeps history, end-user member.
- Stage-5 ownership = **Try world → enter world → re-create a new session from the
  homesite session**; new owner (tenant), no history carried. (Backend mechanism may
  be save-as session template + spawn; cross-ref scenario 21.)
- tenant (owner, enters world to build) vs end-user (member, stays on the homesite)
  is the load-bearing distinction between the two paths.
