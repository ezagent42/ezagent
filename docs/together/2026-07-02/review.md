# 2026-07-02 — End-of-Day Review (`dev-together review`)

Lead: `allenwoods` (林懿伦). Written by lead-agent (`claude`) under the AFK
autonomous goal. Ladders up to `2026-W27/weekly-goals.md` (官网上线 + 系统内部
测试 + 自举 + design-system). Feeds `2026-07-03` `plan`.

## 1. What landed on `main`

The **app-package 收口** — the socialware Definition is now the fattened publish
unit ("app"), and the pre-prod-window rename landed with it. `main` HEAD
**`e263785f`**, CI **clean green** (`mix precommit` ✓ + `check_invariants` ✓).

| task | PR | sha |
|---|---|---|
| T1 pre-prod foundation (ActionSet rename · config de-URI · URI gate · role→recipe) | #1138 | `76857dff` |
| session-template fork (`fork_config/3`) | #1139 | `609cb4d6` |
| hotfix main-red (fork's pre-T1 `Behavior.Template`) | #1141 | `0b8c46ab` |
| T2 app-package (Definition `agents`+`views` · `authorize_view/3` → SessionView · conformance gate) | #1140 | `e263785f` |

Substrate now in place for 0703: `Definition.agents: [{recipe, role_name}]` is
exactly where the 导游/客服 (concierge) agents will be declared.

## 2. Efficiency stats

| metric | value |
|---|---|
| tasks planned (`plans/app-package-plan.md`) | 2 tracks (T1, T2) + fork add-on |
| dev-subagents dispatched | 3 (T1, T2, fork) — opus, parallel on non-overlapping scopes |
| PRs merged to `main` | 4 (T1, fork, hotfix, T2) |
| real regressions caught + fixed pre-persist | 2 (T1 rebase straggler; fork main-red → #1141) |
| codex adversarial rounds | 3× spec-review + 2× plan-review before any code |
| parallel vs serial | T1 ‖ T2 dev parallel; merge serial (T1 must precede all, being the rename base) |

Cycle: design → spec → codex spec-review ×3 → plan → codex plan-review ×2 →
parallel opus dev → lead verify → serial merge. The heavy front-loaded review
(5 codex rounds) caught the stale-branch false-positives **and** my own stale
`Ezagent.Role` claim before implementation — cheap relative to a mis-built rename.

## 3. Gaps

- **G-1 — plan was app-package-only; website work ran off-ledger.**
  `plans/app-package-plan.md` covered only T1/T2/fork. The human devs
  (ruihua/gaga/zhaomato) advanced the 官网 journey in parallel (#1129/#1131/#1132/
  #1133/#1134) with **no task row in the 0702 plan**. Per the ledger rule this is
  a plan-incompleteness gap — the day had two workstreams but one plan. Tracked
  for 0703 (see §4). Not "inferred clean from merges": stated directly.
- **G-2 — fork #1139 red main for ~30 min.** A pre-T1 branch merged *after* T1
  carried the old symbol; caught by T1's grep gate, fixed by #1141. Root cause is
  a missing pre-merge check, promoted to MD-1 below.
- **G-3 — website PRs blocked on rebase + rename debt.** All 5 are 8 behind; #1132
  (docs prose) and #1134 (15 real source refs) carry pre-T1 symbols. Deferred, not
  skipped — merging tonight would red main and #1134 also needs the deferred
  concierge design. Tracked in `docs/futures/todo.md` (0703).
- **G-4 — #108 flake still open.** `PluginIsolationWorkspaceTest` PHASE 4 ×2 flaked
  on the T1 and T2 pre-merge runs (cleared on merged-main re-run). Still tracked
  (task #108); not a DoD slip for today since merged-main CI is clean green.

## 4. Next-day (0703) planning suggestions

1. **Write a complete `plan.md` covering BOTH workstreams** (app-package follow-on
   **and** website) so website work stops running off-ledger (fixes G-1).
2. **Rebase the 5 website PRs first thing** onto post-T1/T2 `main`; sequence the
   clean ones (#1129, #1131, #1133) ahead of the rename-debt ones (#1132, #1134).
3. **Resolve the 导游/客服 concierge design** (orchestrator mechanism) before
   touching #1134 — it materializes onto the T2 `Definition.agents` substrate. This
   is the pivotal 0703 decision; #1134's merge depends on it.
4. **Pre-empt conflict:** #1131/#1132/#1133 all touch Agent Console — stack them in
   author order, not parallel, to avoid world-overlap churn.
5. Consider quarantining `PluginPackageCodexGateTest` (destructive) and finally
   closing #108.

## 5. Method deltas (MANDATORY — promote, don't just collect)

**MD-1 (new rule → `dev-together` PR). Pre-merge symbol-debt gate for branches
behind a landed rename.** When a large symbol rename lands on `main` (T1:
`Behavior`→`ActionSet`, `config://`→structured subject), **every branch cut before
that rename will red `main` on merge** even if its own base CI was green — its base
predates the gate. This is exactly what fork #1139 did (G-2 → #1141).
- **Rule to add to `close`:** before merging any branch whose merge-base is behind
  a known rename commit, run the rename's own grep gate against the branch's added
  lines (`git diff main...branch | grep '^+' | grep -E '<old-symbol>'`) and require
  0 hits. A non-zero count blocks the merge until the author rebases + renames.
- **Existing rule that *should* have caught it:** `close` step 2 says "all gates
  green on the **task branch**" — but the branch's CI ran on its *pre-rename base*,
  so the gate wasn't present yet. The fix is to require the gate be evaluated
  **against post-rename `main`** (i.e. rebase-then-verify, not verify-on-stale-base).
  → I will file this as a `dev-together` skill PR amending `close` step 2/4.

**MD-2 (process-debt, owner = lead). Two-workstream days need one plan.** G-1: when
a background workstream (website) runs alongside the day's headline track
(app-package), the lead must still register it in `plan.md` (even as "carried,
owner X, off-critical-path") so `push`/`review` account for it instead of it
surfacing only at close. Rule that would have caught it: the "No empty plan /
account for all tasks" ledger rule — applied only to the app-package track today.
→ tracked as process-debt; fold into 0703 `plan`.

**MD-3 (confirmed-good, keep). Front-loaded adversarial review pays.** 5 codex
rounds before code caught both external false-positives and my own stale-symbol
claim. Keep the "SPEC/plan → codex adversarial-review before implementing" rule;
it converted a 500-file rename into a first-try-clean merge.

## 6. Roster update (single writer)

Today's headline work was lead + dispatched-agent (not the human-dev tracks), and
the human-dev website tracks did **not** return (deferred to 0703). Per the
single-writer rule I set `current_track` to each dev's 0703 increment and leave
`latest_return` at their last real return (no new returns today).

| github_username | new current_track (0703) | latest_return |
|---|---|---|
| `ruihuachen-designer` | 0703 官网 journey scenarios (#1129) — rebase onto post-T1/T2 main + merge | (design input, no code return) |
| `gagameow` | 0703 Agent Console `/overview` + lifecycle + route tests (#1131/#1132/#1133) — rebase, fix #1132 ActionSet prose, stack in author order | `2026-06-30/stack.md` |
| `zhaomaota97` | 0703 Hello concierge + publish-template (#1134) — **blocked on 导游/客服 design**; then rename-migrate + merge | `2026-06-30/stack.md` |
| `zyli-developer` | (unchanged — 0701 World UI shell polish) | `2026-06-30/stack.md` |
| `FatNine` | (unchanged — 0701 Agent Console prototype path) | `2026-06-30/returns/fatnine-agent-console-completeness-ia.md` |
| `jjkysy` | (unchanged — split #1110 into reviewable PRs) | `2026-07-01/handoffs/jjkysy-split-pr-1110.md` |

(Applied to `docs/together/team.md` in this same commit.)

## Required accounting

| question | answer |
|---|---|
| tasks in `plan.md`? | 2 tracks (T1, T2) + fork add-on — app-package only (G-1) |
| return files arrived / late? | 1 (`app-package-design-day.md`, design record); 0 late. Implementation via dispatched subagents, no per-task return per lead direction |
| returns entered `stack.md`? | 4 merged tasks reconciled (T1/fork/hotfix/T2) |
| merged to `main`? | 4 PRs (#1138, #1139, #1141, #1140) |
| superseded / out-of-scope / blocked / deferred? | 5 website PRs deferred to 0703 (#1129/#1131/#1132/#1133/#1134); #108 flake still open |
| related GitHub PRs merged / closed-subsumed / left-open? | 4 merged via GitHub; 0 closed-as-subsumed (nothing merged locally); 5 left open **intentionally** (website, deferred — owners + reasons in `stack.md`) |

Plan completeness: **incomplete** — covered only the app-package track (G-1/MD-2).
Stated directly, not inferred from the clean merges.
