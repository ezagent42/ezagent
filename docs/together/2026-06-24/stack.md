# dev-together merge stack — 2026-06-24 (lead)

_returned handoffs in analyzed merge order · dependencies · conflict check · reconciliation_

> `push` orders + analyzes only; merging happens in `close` (lead → `main`).
> Base `origin/main` at push time = `cd0d4067` (after the per-dev handoffs #930).

## Returns analyzed (1 stacked)

| # | Task | Dev | PR | Branch | DoD | returned | status |
|---|---|---|---|---|---|---|---|
| 1 | cc-headless real implementation | @黄佳佳 (gagameow) | [#931](https://github.com/ezagent42/ezagent/pull/931) | `agent-flavor-headless-cc-headless-impl` | real SDK sidecar + cc-headless behavior + reply writeback + fake SDK + E2E seed/screenshots; cc tests pass, full precommit (cc pass, 2 pre-existing web-flaky `--failed`-passed) | on_time | ✅ stacked — verifying |

## Reconciliation (every return accounted for)

| return file | disposition |
|---|---|
| `returns/cc-headless-real-implementation.md` | **stacked** (#1) |

No other returns yet today. (zyli=人肉 validation is in-flight, not a code return; zhaomato=官网, fatnine=#84, Allen=core-bugs not yet returned.)

## Merge order

Single entry → no ordering needed. Merge #931 after the lead close gate passes.

## Conflict analysis

`#931` rebased onto latest `origin/main` (`cd0d4067`) **clean** (6 commits replayed, no conflicts). Touches `apps/ezagent_plugin_cc` + `apps/ezagent_domain_agent` (receive/delivery/agent + new cc_headless behavior) + `ezagent_core` (behavior_set, arch manifest/scan, single_spawn_entry test). No overlap with any other in-flight track today (gaga owns cc; world/hello/官网 are disjoint). The `behavior_set.ex` touch overlaps the recent oversized-extraction — rebase replayed clean, re-verify in precommit.

## Close gate (before merge)

- [ ] `mix precommit` EXIT=0 AND grep "every suite 0 failures" (exit code alone insufficient).
- [ ] `mix ezagent.check_invariants` EXIT=0.
- [ ] codex adversarial-review of the core/domain diff (routing-correctness cc/codex/curl/echo; arch-baseline bumps are real debt not masked regression).
- [ ] `gh pr merge 931 --admin --squash --delete-branch`; then update `team.md` current_track (gaga: cc-headless → agent-config backend) + this stack entry → merged.
