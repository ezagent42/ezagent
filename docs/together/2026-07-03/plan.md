# 2026-07-03 — Daily Plan (`dev-together plan`)

Lead: `allenwoods` (林懿伦). Ladders up to **`2026-W27/weekly-goals.md`**.
Derived from `team.md` + the 0702 `review.md` §4/§5 (not guessed).

> **This plan covers BOTH workstreams** (app-package follow-on **and** website) —
> fixing 0702 method-delta **MD-2** ("a two-workstream day needs one plan"; 0702
> ran app-package on-ledger and website off-ledger).

## Week goal alignment (which strand each track ladders to)

- **G1 — ezagent used inside the team, end-to-end.** Blocking path today: the
  **导游/客服 concierge** so a website/team session actually greets + backstops a
  user. This is today's **headline**, not "more E2E scenarios".
- **G2 — official website.** Land the remaining website-journey PRs on the
  `@json-render` substrate without colliding with operator World surfaces.
- **G3 — dev-together self-bootstrapping.** Close today's PRs through the ledger,
  keep CI green, promote the 0702 method-deltas into the skill.

**On "continue E2E scenarios":** the scenario set is mature (main has 1–35; #1129
adds 36–39, the website journey). Today's driver is **making that journey actually
run (concierge) and landing its PRs**, i.e. the *proof* layer — not authoring
scenarios 40+. E2E is a strand under G2, not the day's headline.

## Tracks

### T-A (HEADLINE, discuss-first) — 导游/客服 concierge design → #1134 · lead + zhaomato
- **Goal:** G1. A website session auto-greets (导游) and backstops unanswered user
  messages (客服) — the thing that makes the journey usable by real/team users.
- **Why discuss-first (`clarify_first`):** lead flagged 2026-07-03 "还没完全理解为什么
  要特殊处理". Research/design must write the DoD **before** any build handoff.
  Working thesis (to confirm): **no new mechanism** — 导游 = a participant declared
  at the SessionTemplate default layer; 客服 = a `Definition.agents` recipe + a
  fallback routing rule. The only genuinely new bit is the 客服 **trigger
  semantics** ("no agent answered within a window" vs "always route").
- **Order:** design (lead, this session) → confirm #1134 concierge doesn't already
  cover 客服 fallback (avoid dup) → spec → hand build to `zhaomato` on #1134.
- **Blocks:** #1134 stays HELD until this lands.
- **Surfaces:** `Ezagent.Socialware.Definition` (agents), SessionTemplate default
  layer, routing rules. **Conflict:** none with T-B/T-C (different files).

### T-B (website 收口) — land remaining website-journey PRs · ruihua + gaga
- **#1129** (journey scenarios 36–39, ruihua): rebased; CI re-running (0702 red was
  the #108 flake on a pure-docs PR). **Merge on green.** `PR: #1129`
- **#1132** (Agent Console lifecycle doc, gaga): rebase + rewrite the 8
  `Ezagent.Behavior`/`config://` prose refs to ActionSet/structured-subject, then
  merge. `branch: docs/agent-console-lifecycle-current-state-0702`
- **DONE earlier today:** #1131 (`/overview`, `12762f04`), #1133 (route tests,
  `e9c33e96`) — both merged.
- **Conflict map:** #1132 touches Agent Console docs only; #1131/#1133 already
  landed. No live overlap remains. Merge #1132 **after** #1129 to keep order.

### T-C (self-bootstrap + stability) — lead
- **Skill PR #153:** `dev-together` `review` step must also produce team-facing
  `review.html` (the 0702 gap; lead-approved). `branch: docs/dev-together-review-html-contract`
- **#108 flake:** quarantine the destructive `PluginPackageCodexGateTest` and close
  the flake task — it has now flaked on **4 independent branches** (T1/fork/T2/#1129),
  identical 2 `PluginIsolationWorkspaceTest` PHASE-4 tests. `task #108`
- **team-seed (G1 enabler):** add the `team.md` roster into a website session so the
  team can dogfood — depends on T-A's concierge shape (defer within-day until T-A).

### Continuing tracks (unchanged from 0702 review roster; no new handoff today)
- `zyli` — World UI shell polish aligned to ruihua direction.
- `FatNine` — Agent Console one complete prototype path.
- `jjkysy` — split #1110 into reviewable PRs.

## Merge order (lead path)
1. #1129 (flake rerun → green) — in flight.
2. #1132 (after ActionSet-prose fix).
3. Skill PR #153.
4. #1134 — **only after T-A concierge design + spec** (held).

## Conflict / pre-empt notes
- **Pre-T1 rename debt (MD-1):** every remaining website branch (#1132, #1134) was
  cut before T1 — grep for `Ezagent.Behavior`/`config://` in added lines and require
  0 before merge. #1129/#1131/#1133 already cleared.
- **Agent Console:** #1131/#1132/#1133 all touched this area; #1131/#1133 landed, so
  #1132 rebases onto them (author-order, not parallel).

## Open decision (lead) — gates T-A
- **导游/客服 concierge product shape** (scope of 导游: configurable-default vs
  website-only; 客服 flavor + fallback trigger semantics). Deferred from 0703 AM to
  a focused design discussion. **This is the day's pivotal decision.**
- **Settled 0703 AM:** website sessions share one **`ezagent`** workspace (session-
  level isolation is sufficient) → the "fork cross-workspace variant" deferral is
  **dropped**.
