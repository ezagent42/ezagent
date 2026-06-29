# 0629 status snapshot — coordinator working state

> **Date:** 2026-06-29 (Mon) · **Author:** Claude (coordinator)
> **Purpose:** plain working note (not the team-facing plan). Captures the 4 收口 items
> the lead needs to act on Monday. The team-facing `plan.html` references this file.
> **Repo state:** `origin/main` @ `ced8e3e5` (after #1078 design audit).

This is the coordinator's working snapshot — the 4 items the weekend left open
for Monday. Each item records what's done, what's pending, and the decision/input
needed from Allen.

---

## B1 — Live smoke of the socialware + plugin-package 收口

**Status:** not yet run (the deferred secondary from #1076).

**What landed (merged, not live-validated together):**
- #1069 socialware P1-P10 — base/socialware/fixture model + codex-orchestrator + P10 E2E gate.
- #1076 Q1-C plugin-package — manifest + hot-load + assets hot-load + unload/swap + codex-runnable E2E gate.

**What to run (owner: Claude on a fresh disposable stack; verification owner: zyli under FP2):**
1. Spin a fresh disposable stack (host repo + fresh `EZAGENT_HOME` + `PORT=10044` + dev mode; isolated docker re-seeded each run).
2. Run socialware P10 E2E gate + plugin-package E2E gate together on the live stack.
3. Live agent-browser pass (the deferred secondary confirmation of #1076) — screenshot (1) PTY+ls and (2) cc reply via channel (chat ≠ feishu, per E2E validation standards).
4. Bug triage from any failures — file + fix as found.

**Decision/input from Allen:** none for the smoke itself; this is FP2 work.
**Screenshots refs:** to be attached when run (evidence/ dir under the day's notes).

---

## B3 — #1020 kanban e2e review verdict

**Status:** deferred all weekend (Allen: "revisit after socialware lands"; socialware now landed in #1069).

**Context:**
- #1020 kanban e2e was deferred because the kanban-as-role + socialware model was in flux.
- The weekend landed: #1069 socialware unified, #1075 kanban 9-stage business chain code→data (taxonomy §4.1 leak closed), #1071 recipe storage-key rename.
- The kanban plugin (jjkysy original #964) entered main via the role-as-data + socialware path.

**What to do (owner: jjkysy under FP5; review owner: Claude):**
1. Re-run the kanban E2E scenarios on a fresh stack post-socialware.
2. Verdict: do scenarios still align, or did the socialware/recipe rename shift behavior?
3. If aligned → merge #1020 + 2 minor follow-ups.
4. If drifted → file the drift as a bug, fix, then merge.

**Decision/input from Allen:** confirm jjkysy owns this (kanban plugin original author); confirm the 2 minor follow-ups scope.

---

## C1 — Dogfood (自举) scenario — 3 options

**Status:** scenario not yet picked. Allen + Claude to choose one concrete, valuable scenario this week.

**The 3 options:**

1. **PR-E2E trigger (recommended).** An ezagent agent that, on a PR event (or a
   comment command), spins a fresh disposable stack, runs the E2E seed flows +
   `precommit + check_invariants`, and reports pass/fail back to the PR.
   - *Why recommended:* directly exercises socialware (the agent IS a socialware),
     the plugin-package (E2E runner installed as a plugin), the live stack, and the
     channel reply loop — i.e. it dogfoods the entire weekend's 收口 at once.
   - *Value:* real dev work (replaces manual CI babysitting); catches regressions
     before merge.
   - *Cost:* needs the PR webhook → agent dispatch wire; moderate.

2. **Issue triage agent.** An ezagent agent that triages incoming GitHub issues
   (label, route to a dev, summarize). Lower infrastructure cost; exercises socialware
   + channel but NOT the E2E/plugin-package surface.
   - *Value:* real but lighter; doesn't stress the 收口.
   - *Cost:* low.

3. **Doc drafter.** An ezagent agent that drafts/updates docs (e.g. the
   `docs/notes/` findings index, or GLOSSARY drift checks) from code.
   - *Value:* useful but narrow; exercises socialware + retrieval-first KB (#1036)
     but not E2E/plugin-package.
   - *Cost:* low.

**Recommendation:** option 1 (PR-E2E trigger) — it's the only one that dogfoods
the whole weekend 收口 (socialware + plugin-package + live stack + channel).
If Allen wants lower-cost, option 2.

**Decision/input from Allen:** pick the scenario; confirm owner (allen/zyli per
FP3 — TBD by Allen).

---

## D1 — Design-system audit (#1078) + 5 open questions

**Status:** audit DONE (merged #1078, `docs/together/2026-06-28/notes/design-system-adaptation-audit.md`).
5 OQs need Allen's call before FP4 Phase 0 can land cleanly.

**Audit summary (key findings):**
- 5 distinct styling regimes across 4 rendering modes; **no shared token layer**.
- `EzagentDesignSystem` has **0 code hits on main** — no adaptation started.
- DS ships `styles.css` (token layer) + `_ds_bundle.js` (global-attach IIFE, NOT an ESM).
- **The global bundle is unusable for React islands** (bare `React.createElement`, no
  `window.React` shim → `ReferenceError` in Vite ESM islands). Decision (recorded):
  **vendor `components/**/*.jsx` source into each island's Vite build.**
- **`--accent`/`--card` collision** (DS ↔ shadcn, narrow — daisyUI is NOT a party,
  uses `--color-*` prefix). Recommended: alias daisyUI/shadcn tokens → DS tokens during
  migration, retire them as end-state.
- React version split: world 18.3.1 vs customer/hello 19.2.3 (likely trivial; gate on compile).
- Dark-mode selector split: world uses `.dark` class; DS + S1 use `data-theme="dark"`
  (world can read `document.documentElement.dataset.theme` today — one-liner to unify).
- Phased plan: Phase 0 (LiveView shell + auth, website-first) → Phase 1 (customer SPA,
  parallelizable) → Phase 2 (world island) → Phase 3 (hello inline styles) → Phase 4 (cleanup).
- **Interim hazard:** globally linking `styles.css` (Phase 0) sets DS `--accent/--card`
  document-wide, but the world island late-injects its shadcn `:root` block at mount
  → re-clobbers back to gray document-wide on world pages. Phase 0 + Phase 2 must ship
  atomically, OR scope DS tokens (`.ez`/`data-ez`) until Phase 2 lands, OR defer the global link.

**The 5 open questions for Allen (condensed from audit §5; 7 listed, 2 resolved/low-priority):**

- **Q1 — Collision strategy.** Approve "alias daisyUI/shadcn tokens → DS tokens during
  migration, retire as end-state" (§3-B)? Or namespace DS tokens (`.ez`/`data-ez`) to
  avoid ever colliding? Aliasing = lower-effort, two vocabularies coexist till cleanup;
  namespacing = safer, needs a DS-side change.
- **Q2 — React 18 vs 19 (ratify).** Vendored DS components must compile under React 18
  (world) as well as 19 (customer/hello). Likely trivial (stateless-presentational);
  gate on a compile. Ratify the "vendor source, not global bundle" decision.
- **Q3 — Dark-mode selector unification (confirm go-ahead).** Standardize on
  `data-theme="dark"`, drop world's `.dark`/`@custom-variant dark`. Mechanically trivial
  (one-liner per island). Confirming go-ahead.
- **Q4 — Fonts.** DS ships Inter + Noto Serif SC + Noto Sans SC + Space Mono via Google
  Fonts. Switching adds 2 CN families (heavier payload). OK to load all four app-wide,
  or scope CN fonts to surfaces that render Chinese?
- **Q5 — daisyUI removal timing + @json-render/shadcn vs DS components.** Keep daisyUI
  as a token-only bridge (alias its theme vars to DS, stop using component classes) as
  intermediate, or remove ASAP? And: restyle `@json-render/shadcn` catalog onto DS tokens
  (less churn) vs replace with DS's own React components as the catalog (gives pill/
  floating-shadow behavior for free)?

(Q6 dot-grid and Q7 are low-priority / likely non-issues — see audit §5.)

**Decision/input from Allen:** Q1-Q5 calls before FP4 Phase 0 lands. FP4 owner:
zhaomato (落地) + ruihua (设计输入).

---

## Carry-in tracker (from 0628 review §3)

| Item | Status | This week |
|---|---|---|
| #110 live three-env deploy | unblocked, not done | FP2 (allen promotes, zyli verifies) |
| #1020 kanban e2e | deferred → socialware landed | FP5 (jjkysy) |
| Q1-C follow-ups (M-3/M-5/L-6/L-7/Ci de-bake) | tracked | FP6 (background unless 内测 surfaces) |
| #108 flake-hardening | in_progress | background |
| #111 deploy-flow skill | after #110 | not this week |
| #128 F7-PR-B hardening | deferred | not this week |
| #88 / #55 / #112 | long-term | backlog |
