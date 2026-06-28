# Plan — week of 2026-06-29 (Mon)

**Lead:** Claude (coordinator)  ·  **Repo:** ezagent42/ezagent  ·  **main tip:** `299b6462` (socialware 收口 done)

## Theme — pivot from architecture 收口 to product/launch

This week's goals (lead-set):
1. **官网上线** (public website live) — initially introduces the ezagent project + team.
2. **系统内部测试** (internal system testing).
3. **自举** — use ezagent itself to develop ezagent (dogfood the socialware/agent platform on its own development).
4. **新 design system 适配** — Allen made a new design system; the website (and the world UI?) adapt to it.

## Tracks (parallel where possible)

### Track A — 官网上线 (website live) [Allen's hands + design]
- **A1. Design system intake** — Allen to share the new design system (location/source — claude.ai design project? a tokens file? a Figma?). **Owner: Allen** (provide the source). Claude to assess integration surface.
- **A2. Website scope** — what's the site? (static marketing site for ezagent + team; or a socialware-powered site riding ezagent itself = the 自举 path). **Decision needed**: pure-static vs ezagent-served. Recommend: ezagent-served (a socialware that IS the website) → simultaneously 官网 + 自举 demonstration.
- **A3. Build the website** — adapt the new design system; content = ezagent project intro + team. Owner: a subagent once A1+A2 settled.
- **A4. Deploy the website** — to the public domain. Owner: Allen + deploy flow (#110-related).
- **Gate**: site is live at the public URL, renders the new design system, shows project+team.

### Track B — 系统内部测试 (internal testing) [Claude]
- **B1. Smoke the socialware 收口 on a fresh disposable stack** — the weekend's #1069/#1076 are merged but not live-validated together. Run the socialware P10 E2E + plugin-package E2E + a live agent-browser pass (the deferred secondary from #1076) on a fresh stack. Owner: Claude (agent-browser).
- **B2. Carry-in #110 live three-env deploy** — now unblocked; schedule the nightly→beta→stable promotion with Allen. Owner: Allen's hands (the live promotion); Claude runs the verification.
- **B3. #1020 kanban e2e review** — post-socialware, check the kanban E2E scenarios still align (Allen flagged this). Owner: Claude.
- **B4. Bug triage from internal testing** — file + fix as found.

### Track C — 自举 (dogfood ezagent on its own dev) [Claude + Allen]
- **C1. Define the dogfood scenario** — what dev task does ezagent do on itself? (e.g. an ezagent agent that triages GitHub issues / runs the E2E seed flows / drafts docs). Pick one concrete, valuable scenario. Owner: Allen + Claude.
- **C2. Wire it** — install the chosen socialware/agent on a real ezagent instance pointed at the ezagent repo. Owner: Claude.
- **C3. Run it for real dev work** — actually use it this week; capture what works/breaks. Owner: Claude (with the team using it).

### Track D — design system 适配 [after A1]
- **D1. Audit current UI surfaces** (world console, hello, customer SPA) against the new design system. Owner: Claude (after A1 intake).
- **D2. Adapt** — bring world/hello/customer surfaces onto the new design system (or at least the website first; world later). Owner: subagent.

## Today (Mon 2026-06-29) — sequencing

1. **Allen shares the new design system source** (A1) — I need the location/format (claude.ai design project via DesignSync? a tokens JSON? Figma export?). **Blocker for A3/D.**
2. **Decision: website = static vs ezagent-served (自举)** (A2) — shapes everything.
3. While waiting: I run **B1** (live smoke of the socialware+plugin-package 收口 on a fresh stack — the deferred live agent-browser E2E for #1076) + **B3** (#1020 kanban e2e review).
4. **C1 dogfood scenario** — propose 2-3 concrete options for Allen to pick.

## Open questions for Allen (the inputs I need)

1. **Design system source** — where is it? (claude.ai design project / file path / Figma). What format (tokens? components?).
2. **Website = static marketing site OR ezagent-served (a socialware that IS the site, = 自举)?** I lean ezagent-served (kills two birds: 官网 + 自举 demo). But static is faster to ship.
3. **Public domain** — what's the URL for 官网?
4. **Dogfood scenario preference** — any preference for what ezagent should do on itself (issue triage / E2E runner / doc drafter / something else)?
5. **Internal testing scope** — just the socialware 收口, or broader (full release-candidate smoke)?

## Carry-in (from weekend review)

- #110 live deploy (unblocked, needs Allen's hands) — folds into B2.
- Q1-C live agent-browser E2E (secondary) — folds into B1.
- #1020 kanban e2e — B3.
- Q1-C follow-ups (M-3 install rollback, M-5 same-module hot-reload E2E, Ci de-bake) — tracked, not this-week's priority unless internal testing surfaces them.
- #108 flake-hardening — background.

## Conflict map

- A3 (build website) + D2 (adapt world UI) may both touch frontend assets — sequence A first (website ships), D2 after.
- B1/B2 (live stack) needs a disposable stack; coordinate with any live env Allen is using for the website deploy.
