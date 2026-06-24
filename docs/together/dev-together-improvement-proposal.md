# dev-together improvement proposal — durable roster + continuity for `plan`/`handoff`

> **Status:** PROPOSAL — for Allen's review. No skill or command file is edited by
> this doc. Drafted 2026-06-24.
> **Scope of the ask (Allen):** how should `dev-together` better (a) plan each
> day's work and (b) provide handoffs — and should we keep a per-developer folder
> archiving each dev's work content + work habits?

---

## 1. Problem

Producing the **2026-06-24 daily plan took three wrong drafts.** Not because the
information didn't exist — but because the planner had to be *told* each constraint
out loud instead of deriving it:

> "zyli does 人肉, gaga does protocol-api, zhaomato does hello, fatnine does
> agent-console, consider work continuity, human-devs-only, check yesterday's
> returns."

Decompose that instruction and map each piece to **"already durable?"**:

| What the planner had to be told | Where it should come from | Durable today? |
|---|---|---|
| **Who the devs are** (roster) | `docs/together/team.md` | ✅ **EXISTS** — but unused (see below) |
| **Each dev's current track** (zyli=人肉, gaga=protocol-api, …) | should be per-dev state | ❌ **NOT captured anywhere** — this is the real gap |
| **Work continuity** (next increment grounded in last work) | `returns/<task>.md` | 🟡 exists, but `plan` doesn't auto-read it |
| **"human-devs-only"** | a `plan` rule | ❌ not codified as a step |
| **"check yesterday's returns"** | a `plan` rule | ❌ not codified as a step |
| **"ladder to the weekly goal(s)"** | a weekly layer | 🟡 only as an *inline* block in the 06-24 plan |

### The load-bearing finding

**`docs/together/team.md` already exists** — a 7-row roster mapping GitHub username
→ Feishu name → verification. **But it is referenced NOWHERE** in `SKILL.md` or any
command file (`grep -rl team.md .claude/skills/dev-together/` → no hits). It is a
dead artifact. The roster the planner "had to be told" was sitting in the repo,
unwired.

Three concrete frictions in `team.md` as-is:
- It lists **7 people** including a designer (`ruihuachen-designer`) and `jjkysy`,
  with **no flag for "active human dev"** — so a planner can't filter to the four
  who get tracks.
- It uses **long GitHub usernames** (`zyli-developer`) while plans use **short
  names** (`zyli`) — no alias, so the two never join.
- It carries **no `current_track`** — the single piece of state that, more than any
  other, caused the three wrong drafts.

So the fix is overwhelmingly **"wire in the roster + add the one missing field
(`current_track`),"** not "build a new system." Everything else the ask enumerates
(work habits, PR links, an archive index) is secondary and should be lazy.

A second-order observation, not a design driver: the 06-23 returns show **Claude
executing *as* a human dev** (`zylideveloper (Claude)`). That's just "an agent is
support, running a human's track." The track/profile belongs to the **human dev**
regardless of who runs the keyboard that day. One line, not a subsystem.

---

## 2. The minimal spine (recommended), and the even-smaller alternative

Two options. The task explicitly asks to *evaluate* the per-dev folder, so both are
on the table; I recommend Option B but Option A genuinely fixes the three-wrong-
drafts pain and Allen should pick.

### Option A — just extend `team.md` (smallest thing that fixes the pain)

Add three columns to the existing roster: `role`, short-name alias, `current_track`
(+ optional `latest_return` pointer). No new folder. For **four** active devs this
may be entirely sufficient — `plan` reads one file, filters `role == human-dev`,
reads each row's `current_track`, opens the latest `returns/`, done.

- **Pro:** one file, zero new ceremony, immediately fixes the derivation gap.
- **Con:** no place to accumulate the durable *habit / archive* payload the ask
  wants over time; `current_track` history is lost on each edit.

### Option B — per-dev folder (recommended), with `team.md` as the index

Keep `team.md` as the **roster index** (don't duplicate the username↔Feishu map),
and add a thin per-dev folder that carries the state that benefits from *living
somewhere stable and accreting over time*:

```
docs/together/devs/
├── README.md              # the index: short-name ↔ GitHub ↔ Feishu ↔ role ↔ current_track
│                          # (this REPLACES/absorbs team.md, or team.md becomes a symlink)
├── zyli/
│   └── profile.md         # the only hand-maintained file
├── gaga/profile.md
├── zhaomato/profile.md
└── fatnine/profile.md
```

The folder earns its keep **only** because of the durable habit/archive payload —
that's the honest YAGNI verdict. If Allen doesn't want to accumulate habits over
time, **Option A is the right call.**

> **Archive index is DERIVED, not hand-maintained.** A dev's handoffs+returns
> already live in dated folders (`docs/together/<date>/{handoffs,returns}/`). We do
> NOT add a hand-edited archive list — `plan`/`review` (or a tiny script) can
> `glob docs/together/*/returns/*` and link the ones owned by that dev. Hand-
> maintaining an index would be double-entry; flag it as ceremony to avoid.

### `profile.md` template (keep it TINY — load-bearing first)

```yaml
---
dev: zyli                      # short name = canonical key in plans
github: zyli-developer         # joins to team.md / PRs
feishu: 李震宇
role: human-dev                # human-dev | designer | lead | agent-support
timezone: GMT+8                # load-bearing: deadlines
current_track: 人肉 full-flow validation (was world-deploy-e2e-pg)   # THE key field
latest_return: docs/together/2026-06-23/returns/world-deploy-e2e-pg.md
---

## Specialty / strengths
World deploy + E2E; live-node forensics (:erpc positive controls); root-causing.

## Work habits / preferences   # SPECULATIVE — populate lazily, only when it would
                               # change handoff depth. Empty is fine.
- Returns early with a precise blocker rather than expanding scope.

## Merged PRs (optional, nice-to-have)
- #902 world-deploy-e2e-pg
```

Field priority, explicitly:
- **Load-bearing:** `dev`, `github`, `role`, `current_track`, `latest_return`,
  `timezone`. These are what `plan` consumes.
- **Nice-to-have:** specialty, merged PRs.
- **Most speculative:** `work_habits` — leave empty until an observation would
  actually change how a handoff is written. Do not invent habits to fill the field.

### Update lifecycle (avoid double-entry — this is the ceremony trap)

| Field | Updated by | When | Cost |
|---|---|---|---|
| `current_track` | **`review`** (already runs daily, already feeds tomorrow's plan) | end of day, one line | 1 edit/dev/day |
| `latest_return` | `review` (same edit) or derived by `plan` from the glob | end of day | folds into above |
| `work_habits` | `review`, **only when noteworthy** | rarely | near-zero |
| archive list | **derived** (glob), never hand-edited | on demand | zero |

**Deliberately NOT touched:** `return.md` and `close.md` do **not** gain a "also
append to the dev's archive" step. Returns are already durable in dated folders;
adding a second write is the double-entry trap. (`return` could *optionally* bump
`current_track`, but `review` already owns the next-day handoff, so let `review`
own it — single writer.)

---

## 3. How `plan` should change — derive, don't guess

Today `commands/plan.md` step 2 says "List the day's tasks" with no input source.
The plan is authored from the planner's memory. Codify the three missing inputs as
explicit steps so the plan is **derived**:

**Proposed new `commands/plan.md` "Do:" steps (concrete):**

1. (unchanged) ensure today's folder exists.
2. **NEW — load the roster.** Read `docs/together/devs/README.md` (or `team.md`).
   **Filter to `role: human-dev`.** Agents (Claude/codex) are excluded from tracks
   — they go in the "Off-plan (support)" section, never get a track row.
3. **NEW — load each dev's current track + continuity.** For each human dev, read
   their `profile.md` `current_track` and their **latest return**
   (`latest_return`, or newest `docs/together/*/returns/*` they own). Each dev's
   "today's increment" must be **grounded in that last return** (e.g. zyli's 06-24
   increment = "re-run E2E now that #912 landed, verify the §7 crux is cleared" —
   derived directly from the 06-23 return §7, not invented).
4. **NEW — ladder to the weekly goal(s).** Read the weekly goals file (§5) and tag
   each track with the goal it serves (the 06-24 plan already does this with a
   `serves goal` column — make it a required step, sourced from the durable file).
5. (unchanged) build the cross-task conflict map.
6. (unchanged) write `plan.md`.

**Plan completeness gate — add three checks** to the existing gate:
- Plan was filtered to `role: human-dev` (no agent has a track row).
- Every track row cites the dev's **last return** as its continuity basis.
- Every track row names the **weekly goal** it ladders up to.

This turns "be told the four constraints" into four steps the command always runs.
The 06-24 plan is the proof-of-shape: it already contains exactly this structure
(human-only scope line, `basis: continuity from returns`, weekly-goals block,
per-dev continuity column) — it was just produced **by hand after three tries**
instead of by a codified procedure.

---

## 4. How `handoff` should change — tailor depth to the dev's profile

`commands/handoff.md` is sound; one additive step:

- **NEW step 1.5 — read the assigned dev's `profile.md`.** Use `specialty` +
  `work_habits` to **tailor handoff depth**: a dev with deep world/forensics
  background (zyli) needs less hand-holding on E2E mechanics; a dev new to a surface
  gets more required-reading + a worked example. The handoff *standard* (demonstrable
  DoD, discuss-first, defer rules) is invariant — only the **explanation depth**
  flexes.
- **Archive speeds future handoffs:** linking the dev's prior returns (derived
  glob) lets the handoff author say "you already did X in <return>, this builds on
  it" instead of re-deriving context — the continuity that was missing today.

No change to the handoff *template* or *standard* files.

---

## 5. Weekly layer

**Recommend: promote the existing inline block to a durable file.** The 06-24 plan
already has a `## Weekly goals (本周)` section with a `serves goal` column — this
isn't inventing a layer, it's **moving an inline block somewhere `plan` can read it
every day.**

Current week's goals (from the 06-24 plan, verbatim intent):
1. **Get ezagent running inside the team** — product works end-to-end, team uses it
   daily (zyli's 人肉 run is the *measurement*; gaga/fatnine/zhaomato + the
   session-create crux are the *gaps*).
2. **Build the official website (官网)** — public marketing/landing site; currently
   **owner-TBD** (a real open question the 06-24 plan surfaced).

**Shape — two options, an open question for Allen:**
- **Rolling file** `docs/together/weekly-goals.md` — one file, no path ceremony,
  edited when goals change. **Recommended for YAGNI** (we don't reliably work in
  clean week boundaries).
- **Dated** `docs/together/<week>/goals.md` — cleaner history per week, but adds a
  week-folder path convention to maintain. Heavier.

Either way `plan` step 4 reads it and threads `serves_goal` into each track.

---

## 6. Migration — what to create now

Minimal, do-it-now set:

1. **Add `role` + short-name alias + `current_track` to the roster.**
   - Option A: three columns in `team.md`.
   - Option B: create `docs/together/devs/README.md` as the index and make
     `team.md` point to it (or absorb it).
2. **Seed the 4 human-dev profiles** (Option B) from their recent returns:
   | dev | github | current_track (from returns) | latest_return |
   |---|---|---|---|
   | **zyli** | zyli-developer | 人肉 full-flow validation (was world-deploy-e2e-pg) | `2026-06-23/returns/world-deploy-e2e-pg.md` |
   | **gaga** | gagameow | protocol-api / agent-flavor (cc-headless real backend, 3A) | `2026-06-23/returns/agent-flavor-headless-protocol-api.md` |
   | **zhaomato** | zhaomaota97 | hello (world→hello path closed; next increment TBD) | `2026-06-23/returns/world-hello-convergence.md` |
   | **fatnine** | FatNine | agent-console (#84 CRUD) | (06-23 socialware-creator-agent-config return) |
   - `jjkysy`, `ruihuachen-designer` → `role: designer`/other, **no track**.
3. **Create the weekly goals file** with the two current goals (§5).
4. **Minimal skill edits — exactly these files:**
   | File | Change |
   |---|---|
   | `commands/plan.md` | +3 "Do" steps (roster filter, continuity read, weekly ladder) + 3 gate checks |
   | `commands/handoff.md` | +1 step (read profile → tailor depth) |
   | `commands/review.md` | +1 step (update `current_track` / `latest_return`; optional habit note) |
   | `SKILL.md` | document `docs/together/devs/` + `weekly-goals.md` in the artifact-layout section; add to Roles that the roster is the source of human-dev truth |
   | `scripts/new_day.sh` *(optional)* | nothing required; weekly file is hand-edited |

   **Deliberately unchanged:** `return.md`, `close.md`, `init.md`, `push.md`,
   `references/handoff-standard.md`, `references/handoff-template.md`. Showing
   restraint: the fix touches `plan` (the thing that broke) + two daily commands,
   nothing else.

---

## 7. YAGNI flags (ceremony without payoff — avoid)

- **Hand-maintained archive index** → DON'T. Derive it from the dated folders by
  glob. A second hand-written list of a dev's returns is double-entry that will rot.
- **`return`/`close` also writing to the profile** → DON'T. Single writer
  (`review`) for `current_track`. Returns are already durable.
- **A heavy profile schema** (skills matrix, velocity stats, availability calendar)
  → DON'T. Six load-bearing fields + a free-text habits note. Grow only on demand.
- **Dated week folders** → only if Allen wants per-week history; otherwise a rolling
  file is lighter.
- **Profiles for agents** → DON'T. Agents are support; they don't get a track or a
  profile. (`role: agent-support` in the roster index is enough if we want them
  listed at all.)

---

## 8. Open questions for Allen

1. **Option A vs B** — extend `team.md` only (4 devs, may suffice), or the per-dev
   folder (earns its keep only if we want to accumulate habits/archive over time)?
   *My recommendation: B, but A is a legitimate YAGNI choice.*
2. **Canonical `<dev>` key** — short name (`zyli`, used in plans) or GitHub username
   (`zyli-developer`, used in team.md / PRs)? The roster must carry the alias either
   way; I propose **short name = canonical**, GitHub as a joined field.
3. **Weekly file shape** — rolling `docs/together/weekly-goals.md` (recommended) or
   dated `docs/together/<week>/goals.md`?
4. **官网 owner** — goal #2 has no owner among the four continuity tracks (5th
   track / one dev pivots / stretch after in-team rollout). Same open item the
   06-24 plan already flagged.
5. **Who updates `current_track`** — `review` (recommended, single writer) or should
   `return` bump it when a dev pivots mid-stream?

---

### Files read to ground this proposal (all under the worktree)

- `.claude/skills/dev-together/SKILL.md`
- `.claude/skills/dev-together/commands/{init,plan,handoff,return,close,review}.md`
- `.claude/skills/dev-together/references/handoff-standard.md`
- `docs/together/team.md` *(the existing, unwired roster)*
- `docs/together/2026-06-24/plan.md` *(the 3-wrong-drafts output — proof of the target shape)*
- `docs/together/2026-06-23/{plan.md, returns/world-deploy-e2e-pg.md, returns/agent-flavor-headless-protocol-api.md, returns/world-hello-convergence.md}`
