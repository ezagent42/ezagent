> **Task:** gaga — Git Provider V1 Plan B domain spine
> **Branch:** `feat/git-domain-spine`
> **Baseline:** `origin/main@6bfe3d1b3288c93c128449a1183922140db66217`
> **PR:** WIP, to be created after final verification/review
> **Dev:** gaga / Codex
> **returned_at:** 2026-07-16 23:03 +0800
> **Status:** Tasks 0–12 implemented locally; broad review and Draft PR handoff in progress

# Return summary

Plan B delivers a provider-neutral, in-memory Git domain spine as one stacked
change on `feat/git-domain-spine`. It includes the Plan A constraints and evidence,
closed domain values, adapter contract/registry, ephemeral per-task access Resource,
CapBAC-gated ActionSet dispatch, atomic boot registration, structural gates, and a
real in-process integration proof through Invocation/Router/Kind to synchronized
fake providers.

This is not the original W29 external demo loop. GitHub plugin/API, user GitHub
authorization, credentials, checkout/worktree provisioning, Kanban, canary,
cc-headless execution, real PR/CI/review/merge, and #1360 Layer B final mounting are
not implemented by Plan B. No deployment or merge is authorized or claimed.

## DoD reconciliation

| Task | Status | Evidence |
|---|---|---|
| 0 contract/design freeze | complete | tracked design, plan, Plan A decisions and security constraints |
| 1 independent domain app | complete | exact production dependency `:ezagent_core`; architecture dependency tests |
| 2 closed values/limits/errors | complete | non-raising constructors, closed error union, configured aggregate limits |
| 3 adapter contract | complete | five provider-neutral callbacks and normalized result contracts |
| 4 adapter registry | complete | exact normalized repository routing and deterministic registration lifecycle |
| 5 ephemeral task Resource | complete | policy state is in-memory, per-task, and supervised |
| 6 capability contract | complete | five actions/subjects derived by the ActionSet macros |
| 7 signed-cap test fixture | complete | real `Cap.issue({:held_by, admin_uri}, ...)`, receiver-bound verification |
| 8 authorized dispatch | complete | exact-resource authorization before adapter effects |
| 9 atomic boot | complete | registrations and boot Resource bindings fail/roll back as one startup boundary |
| 10 structural gates | complete | dynamic-boundary, provider leakage, secret isolation, and URI scanner regressions |
| 11 integration proof | complete | real boot + Resource + Invocation/Router/Kind + two synchronized fake adapters |
| 12 handoff verification | in progress | rebased current main; docs, architecture, per-app and full umbrella verification recorded; broad review/PR pending |

## Fresh verification evidence

Environment: local Linux isolated worktree
`/home/huangjiajia/ezagent/.worktrees/git-domain-spine`, Elixir 1.19.2,
`SHELL=/bin/bash`. Dependencies/build assets are shared from the main checkout;
the ignored web `node_modules` symlink is an environment prerequisite, not a
tracked product change.

Already verified after the current-main rebase and Task 12 fixes:

```text
SHELL=/bin/bash mix cmd --app ezagent_domain_git mix test
  -> 84 tests, 0 failures

SHELL=/bin/bash mix test \
  apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs
  -> 3 tests, 0 failures

mix ezagent.doc.scan
  -> PASS, 404/404 public definitions documented

mix ezagent.arch.scan
  -> PASS, all architecture counters within baseline; oversized files 4/4

focused core capability chokepoint regression
  -> 1 test, 0 failures
```

Three serial full-precommit attempts were diagnostic, not green claims:

1. The first stopped because an isolated worktree lacked web `node_modules`.
   Clean `origin/main` reproduced that worktree-environment prerequisite.
2. After linking the existing ignored assets, the second reached the full suite.
   It exposed and led to fixes for two branch-owned issues: redundant manual
   `cap_subjects/0` and per-app test dependence on the Identity sibling app. It
   also reported unrelated/current-main state: the SkillRegistry seed bundle,
   one URI scanner finding in `skill_reconcile.ex`, and a full-suite HomeLive
   teardown timeout. The HomeLive test passes alone on clean current main (1/0).

3. The final run completed every umbrella app. All apps except core passed,
   including Web 359/0 (the prior teardown timeout did not reproduce), Git domain
   84/0, and CLI 37/0. Core reported 2123 tests / 5 failures: the SkillRegistry
   seed/runtime mismatch plus four scanner-task failures caused by current main's
   single `skill_reconcile.ex` URI finding. Therefore `mix precommit` is recorded
   as failed, not green. Full log: `/tmp/plan-b-precommit-3.log`.

## Baseline reproduction

Clean detached `origin/main@6bfe3d1b3` in `/tmp/ezagent-origin-main-verify` reports
exactly one hard URI scanner finding:

```text
apps/ezagent_domain_agent/lib/ezagent/home/skill_reconcile.ex:142
raw_uri_construction (string check for "entity://")
```

The branch does not edit that file or conceal the finding. Clean main's
`mix ezagent.arch.scan` passes with oversized-file count/cap 4/4. The isolated
HomeLive wizard test on clean main passes 1/0.

## Reproduction commands

```bash
cd /home/huangjiajia/ezagent/.worktrees/git-domain-spine
git status --short --branch
git diff --check origin/main...HEAD
SHELL=/bin/bash mix cmd --app ezagent_domain_git mix test
SHELL=/bin/bash mix test apps/ezagent_domain_git/test/integration/git_task_dispatch_test.exs
mix ezagent.doc.scan
mix ezagent.arch.scan
mix ezagent.check_invariants
SHELL=/bin/bash mix precommit
```

## Honest boundary and next slices

The delivered spine is provider-neutral but in-memory and loose-coupled. It does
not contain GitHub-specific transport. The next independently reviewable slices
are: GitHub plugin with per-user token brokering, entity SSH key management with
public-key generation and optional private-key import, repository/worktree
provisioning before sidecar start, then Kanban governance-cap issuance and the
#1360 Layer B final mount. Those slices are required before the original canary
Kanban-to-agent-to-real-PR demo can run.

## Lead handoff

Create/update a Draft PR only after final local verification and broad review.
Do not deploy or merge. Allen/lead retains authorization for integration order,
deployment, and merge.
