# Homesite user journey — overview map (scenarios 36–39)

**Status**: draft — 2026-07-02. Author: Claude (with ruihua), from the 2026-07-02
product sync + ruihua's product-relationship model.

> Bilingual lockstep mirror: [`homesite-journey.zh_cn.md`](./homesite-journey.zh_cn.md).

## What this is

The connective map for the homesite E2E cluster. A single anonymous visitor walks
one continuous journey from landing on the ezagent homesite to publishing their own
forked session — and each leg is codified as one 1:1 scenario (36–39). This doc is
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

## The journey (6 stages)

| Stage | User action | Underlying product relationship | State change | Scenario |
|---|---|---|---|---|
| **0 page == session** | open the homesite page | page = a hello product bound to one world session; anon sees that session's external face | anonymous viewer | premise, cross-ref 35 |
| **1 anonymous browse** | GitHub / See progress | pure display, no session write | none | 36 |
| **2 write-gate → login** | write in the bottom composer | anon cannot write the session → gated | anon → login → signed-in | 36 |
| **3 dialog == talking in world** | talk on the page | message enters the world session; agent/other-member replies **sync back** to the page | becomes a session member | **37** |
| **4 share → same session** | share the link, invite others | invitees join the **SAME** session (group chat, history kept) | invitee = end user / member | **38** |
| **5 re-deploy → fork new session** | re-deploy (publish) session + page | saved as session template → fork a **NEW** session → forker becomes owner, sees the conversation in world | forker = new owner / tenant | **39** |

## The decisive fork: two propagation paths (stages 4 & 5)

This is where the journey actually demonstrates the product relationships — the same
page, shared vs re-deployed, means two completely different product semantics:

```
┌─ stage 4  share / deploy ─────┐   ┌─ stage 5  re-deploy / publish(fork) ┐
│ the SAME session              │   │ a NEW session                        │
│ many people, one conversation │   │ forker starts their own              │
│ history preserved             │   │ no original history (publish)        │
│ invitee = end user (member)   │   │ forker = tenant / owner              │
│ "you and I are in one group"  │   │ "he copied my template"              │
└───────────────────────────────┘   └──────────────────────────────────────┘
        end-user view                          tenant / owner view
        = deploy (keeps history)               = publish → session template (fork)
```

deploy and publish are written as **scenarios 38 and 39** — each is the other's
failure mode (38 asserts "fork instead of join = bug"; 39 asserts "join instead of
fork = bug"), which forces the backend's session semantics to be exact.

## Scenario mapping

- **36** — stages 0–2: anonymous browse + login-gate.
- **37** — stage 3: homesite dialog ↔ world session (bidirectional sync). The spine;
  prerequisite for 38 and 39.
- **38** — stage 4: share / deploy → same session (group chat, end-user member).
- **39** — stage 5: re-deploy / publish → fork a new session (new owner / tenant).

## Recording note

Everything downstream of stage 2 depends on backend wiring that is **not yet
connected** (2026-07-02 sync). Until built, the not-yet-implemented surfaces
(world→page reply propagation, the share/publish affordances, the plugin-market
list) are recorded against **unimplemented blank-HTML placeholders** — the scenarios
assert the intended behavior, the placeholders stand in for the missing pieces. The
recorder is modelled on `scripts/demo/agent-create-record.js` (Playwright
`recordVideo`), driven by the role/text selectors each scenario specifies.

## Product decisions this journey encodes (2026-07-02 sync)

- Each opened hello page == one session.
- world = IM backend (owner watches / configures replies); hello = display face.
- `deploy`/`share` = same session, keeps history, end-user member.
- `publish` = save-as session template + fork, new owner, no history carried.
- plugin-market = session-template list.
- tenant (owner) vs end-user (member) is the load-bearing distinction between the
  two propagation paths.
