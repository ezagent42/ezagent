# 2026-07-01 Lead Intake & Merge Analysis

Lead-side consolidation of today's team returns. Each PR carries its own return
doc inside its branch (`docs/together/2026-07-01/returns/…`) — this file does NOT
copy them (that would conflict on merge); it references them and records the
merge decision + completion analysis. Precedent: `docs/together/2026-06-26/`
team-PR intake.

`main` = `ed0f08dc`, CI green (Elixir 1.19 runner). All open PRs verified below
against **GitHub CI** (`mix precommit` + `mix ezagent.check_invariants`), not
local envs.

---

## 1. Open PRs — per-PR merge decision

| PR | Author | GitHub CI | State | Decision |
|----|--------|-----------|-------|----------|
| #1122 | zyli | (running) | BLOCKED | **Split**: cwd=config_dir slice = merge-now (Allen greenlit); world-UI shell = hold for tomorrow's UI redesign |
| #1121 | zhaomato | ✅ SUCCESS | BLOCKED | **Merge-now** — 官网 T2 收口, W1–W6 resolved, return-to open-redirect fixed |
| #1120 | gaga | ✅ SUCCESS | BLOCKED | **Cherry-pick the data slice**; hold the T7 framing (gaga self-blocked, T7A–E redo) |
| #1118 | ruihua | FAILURE(draft) | DRAFT | **Hold** — draft, thread resolved "接着改" |
| #1117 | jjkysy | ✅ SUCCESS | BLOCKED | **Merge-now candidate** — World UI-surface substrate, independent, no file overlap |
| #1116 | jjkysy | ✅ SUCCESS | BLOCKED | **Hold on interface-def** — materialize engine; Allen: kanban/autoservice rebase to socialware interface-def first |
| #1115 | jjkysy | ✅ SUCCESS | BLOCKED | **Hold** — Allen: settle socialware data-split before merging recipe-ownership decision |
| #1114 | allen | FAILURE (flake) | BLOCKED | **Merge-when-ready** — 2 failures = known #108 `PluginIsolationWorkspaceTest` flake (docs-only PR can't cause them); re-run CI |
| #1112 | FatNine | FAILURE + BEHIND | BEHIND | **Rebase+fix** — 5 real arch-gate failures (CrossFileDuplicateFn baseline + UriQuery scan); rebase onto main then re-run |
| #1110 | allen | FAILURE + BEHIND | BEHIND | **CLOSE** — jjkysy confirmed split done ("已经拆了，我一会儿关"); do not merge |

### Full-vs-cherry-pick, only where it matters
- **Full merge**: #1121, #1117 — single-purpose, clean, green.
- **Cherry-pick**: #1120 — take the AutoService KB/persona data-externalization
  (seed→`priv/socialware/autoservice/`, kb Tier-1 e2e green); leave the T7
  proposal doc for the T7A–E rework. gaga's own blocking review agrees.
- **Split**: #1122 — cwd=config_dir default is greenlit & isolated; the world-UI
  shell edits (Admin/Conversation/Identities/SessionsTable/main.tsx) overlap
  tomorrow's three-column IA redesign with zyli — hold those.

---

## 2. CI truth — two misdiagnoses corrected

**`.claude/hooks/` do NOT run in GitHub CI.** CI runs only `mix precommit` +
`mix ezagent.check_invariants` (`.github/workflows/ci.yml`). The `tput: No value
for $TERM` from `handoff-deadline-reminder.sh` is a *local Claude Code terminal
hook*, never invoked by the GitHub runner. Not a CI blocker.

**Issue #1123 (`no_surface_read_dispatch_probes.ex` `@probes` regex) is a LOCAL
Elixir 1.18 / OTP 28 env issue.** The file is on `main`; main CI (Elixir 1.19)
is green. It fails only on a local 1.18/28 toolchain. Fix = align local Elixir to
1.19 (CI's version) or move the regex list out of the module attribute. Does not
block GitHub CI.

**#1112's real failure** = full-umbrella `1827 tests, 5 failures`: 2 arch-gate
(CrossFileDuplicateFn over baseline, UriQuery scan violation) + 3 associated.
FatNine's local "305 passed" ran only the overview app subset. Real, needs fix +
rebase.

---

## 3. Completion analysis vs week goals (#146) + today's focus (产品形态收口)

**Today's stated focus (Allen): 把产品形态收口** + 3 discussion tracks with 瑞华.

| Week goal (#146) | Today's movement | Status |
|------------------|------------------|--------|
| **官网上线** | #1121 官网 T2 prod path (mergeable, W1–W6 fixed, tokens→upstream DS); #1107 T4 framework already on main | 🟢 mergeable, near-live |
| **系统内部测试** | nightly.ezagent.chat carries latest UI; three-env deploy + reflow verified yesterday | 🟡 UI on nightly, awaiting sign-off |
| **自举 (E2E/CI runner)** | #1116 per-session role-agent materialize substrate (green); #1115 recipe-ownership decision | 🟡 substrate green, gated on socialware interface-def |
| **design system 适配** | #1118 T1 design-convergence gate (5-surface IA + CLI lint); zyli hiding tech jargon → 3-col IA; #1104 redesign prototype on main | 🟡 convergence memo done, UI redesign tomorrow |

**Product-form 收口 decisions landed today (from thread):**
- **socialware naming/boundary** (gaga blocking review): the installable unit
  should be "installable ezagent **app package**", NOT socialware. socialware =
  public/anonymous customer-facing *facet* only. AutoService = app-package whose
  main facet is socialware; kanban = operator/team app (socialware facet only if
  it declares a public view). → **Allen gate**: define socialware deployment +
  interface with a concrete CI test gate FIRST, then kanban/autoservice rebase to
  it. (T7A term/contract spec → T7B manifest schema → T7C conformance CI gate →
  T7D AutoService+kanban as examples → T7E externalize+installer.)
- **recipe ownership** (#1115): domain_agent hardcodes no recipes; pm-coordinator
  ships with kanban plugin, dev-together is user-configured. Materialize resolves
  by string NAME via RecipeRegistry, fail-closed on unknown → decouples cleanly.
- **#1110 → close** (split into #1116/#1117 + T7 data slices).
- **project_cwd**: backend already validates (config_dir + `EZAGENT_ALLOWED_CWD_ROOTS`);
  #1122 defaults empty cwd → config_dir. Issue #1119 asks V1 UX scope (5 Allen Qs open).
- **Agent Console → "创建一个岗位"（招聘）方向**: ruihua demo at
  `docs/website-demo/vx/agent-hire-demo/`; end-user "invite GTM engineering to
  org" framing; entry-point placement still open (FatNine + gaga).

**Open Allen decisions surfaced today:**
1. #1119 project_cwd V1 scope — 5 questions (existing-dir vs create-under-root,
   forbid arbitrary abs path, defer scratch mode, EZAGENT_ALLOWED_CWD_ROOTS as
   source-of-truth, error-when-no-roots).
2. socialware interface-def CI gate — the T7 gate Allen asked for.
3. Agent Console 招聘-direction entry point.
4. Whether to accept the "app package" rename (socialware → app-package facet).

---

## 4. Recommended merge sequence (awaiting Allen's go per code-PR)

1. **Now (docs)**: this intake doc.
2. **Merge-now** (green, independent, product-critical): #1121 (官网), #1117 (World UI-surface), #1122-cwd-slice.
3. **Close**: #1110.
4. **Re-run CI then merge**: #1114 (flake), after confirming green.
5. **Hold for socialware interface-def gate**: #1116, #1120-data-slice, #1115.
6. **Rebase+fix then merge**: #1112.
7. **Author edits, no action**: #1118 (draft).
