# 2026-07-02 — Merge Stack (`dev-together close`)

Lead: `allenwoods` (林懿伦). Close executed by lead-agent (`claude`) under the
AFK autonomous goal. **`main` is the only integration path; every entry below
landed through a GitHub PR merge (lead admin-merge on flake-only CI).**

Day theme: **app-package 收口** — fatten the socialware Definition into the
publish unit ("app"), landing the pre-prod-window foundation rename first. Design
→ spec → 3× codex adversarial spec-review → plan → 2× codex plan-review →
dispatched opus dev-subagents → lead verify+merge. (Handoff docs intentionally
skipped per lead direction; the design-day return + T1/T2 specs are the contract.)

## Reconciliation — every file in `returns/` is accounted for

| return file | status | landed as |
|---|---|---|
| `returns/app-package-design-day.md` | merged (design day) | #1136 `4fb230a0` (design record, merged 0702 AM) |

The 0702 *implementation* work was dispatched by the lead to opus dev-subagents
(no separate `returns/<task>.md` per lead direction — "不用写 handoff 文档… 你负责
验收、合并并填写 dev-together 文档"). Each landed as its own PR, reconciled below.

## Stack — analyzed merge order (as landed on `main`)

| # | task | PR | merge sha | gates | PR state |
|---|---|---|---|---|---|
| 1 | **T1 pre-prod foundation** — `Ezagent.Behavior.*`→`Ezagent.ActionSet.*` rename (500+ files) · config:// pseudo-URI → structured `"<kind>:<name>"` subject · URI-scheme catch-all gate (external allowlist) · role→recipe (`role/`→`recipe/`, `Ezagent.Agent.Recipe`) | #1138 | `76857dff` | green (flake-only: #108 PluginIsolation ×2) | MERGED |
| 2 | **session-template fork** — one-click copy session config → new owned session (`ConfigFork.fork_config/3`) | #1139 | `609cb4d6` | green on its base; **regressed main** post-merge (see 3) | MERGED |
| 3 | **hotfix main-red** — fork's `config_fork.ex:189` carried pre-T1 `Behavior.Template`; T1's grep gate (merged just before) caught it → `ActionSet.Template` | #1141 | `0b8c46ab` | green (flake-only) | MERGED |
| 4 | **T2 app-package** — Definition gains `agents: [{recipe, role_name}]` + `views: [view_actionset]` (view = render ActionSet, unique `<sw>_render` action, `dispatchable?: false`) · `authorize_view/3` sunk into `Ezagent.UI.SessionView` contract + registry · anon view-cap mint (public-def only) · `mix ezagent.socialware.check` conformance gate (10 assertions, on CI) | #1140 | `e263785f` | green (flake-only: #108 PluginIsolation ×2) | MERGED |

`main` HEAD after close: **`e263785f`** — full app-package line (T1 + fork + T2)
plus the pre-prod-window rename landed in one window, as required (rename affects
cap identity `{kind, actionset_module, action, instance, workspace}`, so it had
to precede any prod data).

**Authoritative post-close gate:** the `main` CI run on `e263785f`
(`28612633533`) is **completed / success — clean green**, not merely flake-only:
`mix precommit` ✓ and `mix ezagent.check_invariants` ✓, and the #108 flake did
**not** recur on the merged-main run. `main` is genuinely healthy after the whole
app-package line landed.

## Gate verification (close step 2)

CI job `precommit + check_invariants` runs `mix precommit`
(format + compile-warnings-as-errors + full umbrella test + `:ezagent_plugin_check`)
and `mix ezagent.check_invariants` (arch.scan / doc.scan / uri_query.scan /
lifecycle) on every push to `main` (branch-protected).

- **T1 #1138**, **T2 #1140**: core suite `2 doctests, 1837 tests, 0 failures`;
  only failure the **#108 flake** — `PluginIsolationWorkspaceTest` PHASE 4 ×2
  (plugin Kind/Template survives teardown+rehydrate). Triple-confirmed as flake:
  the identical 2 tests, and only those, failed across **three unrelated
  branches** (T1, fork, T2) — the strongest flake signal (independent branches,
  identical failure surface). T2's own `ezagent.socialware.check` conformance
  gate + the fork/rename invariant tests were green.
- **fork #1139**: green on its pre-T1 base; the post-merge main-red was a
  pre-T1-branch rename-debt miss, fixed in #1141 (see method delta MD-1).
- **hotfix #1141**: green (flake-only).

## PR closure loop

All four PRs merged **through GitHub** (lead admin-merge, flake-only CI). Nothing
was merged locally/cherry-picked, so there is no "subsumed, please close"
follow-up. No task branch was left without a PR.

| PR | head branch | outcome |
|---|---|---|
| #1138 | `feat/app-t1-foundation` | MERGED via GitHub → `76857dff` |
| #1139 | `feat/session-template-fork` | MERGED via GitHub → `609cb4d6` |
| #1140 | `feat/app-t2-reconciled` | MERGED via GitHub → `e263785f` |
| #1141 | `fix/main-red-fork-behavior-template` | MERGED via GitHub → `0b8c46ab` |

No open GitHub PR carries code that already landed through the lead path. ✅

## Not in this stack (deferred to 0703 — see `docs/futures/todo.md`)

The human-dev website PRs ran **in parallel, off this day's app-package plan**
and are **not** merged tonight — each is **8 commits behind** the post-T1/T2
`main` and needs rebase; two carry pre-T1 rename debt that the T1 grep gate would
reject; one intersects a design the lead deferred:

| PR | author | why deferred |
|---|---|---|
| #1129 docs(scenarios) 官网 E2E journey | ruihuachen-designer | clean content, but 8 behind — rebase then merge |
| #1131 feat(world) Agent Console `/overview` | gagameow | clean content, 8 behind — rebase then merge |
| #1132 docs(agent-console) lifecycle | gagameow | 8 behind + 8 stale `Ezagent.Behavior`/`config://` prose refs → update to ActionSet on rebase |
| #1133 test(agent-console) route coverage | gagameow | clean content, 8 behind — rebase then merge |
| #1134 feat(hello) concierge + publish-template + public-read | zhaomaota97 | 8 behind + **15 real `Ezagent.Behavior`/`config://` source refs** (gate would red main) **and** intersects the 导游/客服 concierge design the lead deferred to 0703 — needs rename migration **and** design confirmation before merge |

The `agents: [{recipe, role_name}]` field that T2 just landed is exactly the
substrate the 0703 导游/客服 (concierge) question resolves onto — so holding #1134
until that design is confirmed is deliberate, not neglect.
