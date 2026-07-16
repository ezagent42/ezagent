> **Task:** gaga — Git Provider V1 Plan A security prerequisites
> **Branch:** `docs/git-provider-v1-design`
> **PR:** https://github.com/ezagent42/ezagent/pull/1423
> **Dev:** gaga / Codex
> **returned_at:** 2026-07-16 12:22 +0800
> **deadline:** 2026-07-16 23:59 +0800
> **deadline_status:** deferred

# Return summary

Plan A evidence and interfaces are implemented on commit `21334e29c` and ready
for lead review. No deployment, merge, canary mutation, production credential,
OAuth flow, Git domain production code, or UI was added.

Decision:

| Concern | Result |
|---|---|
| Encrypted secret backend | NO-GO — absent |
| SSH private-key parser | NO-GO — absent |
| SSH broker isolation | NO-GO — same-UID exposure reproduced |
| GitHub API transport | narrow GO — pure local contract prototype for downstream planning |

Selected W29 direction: public anonymous checkout plus a later GitHub-plugin Git
Data API write path. This remains GitHub-specific, loose-coupled, not the final
mount; #1360 Layer B is pending. Private checkout and all SSH transport remain
blocked.

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|---|---|---|
| 1 | Inventory Secret Store, SSH parser, Cap, OsProcess, and plugin primitives | met | `docs/superpowers/notes/2026-07-16-git-provider-v1-a-inventory.md`; commit `8fcbfe1b1` |
| 2 | Reproduce same-UID credential exposure with sentinel-only material | met | `os_process_secret_isolation_probe_test.exs`; 2 tests, 0 failures; commit `1e8b913fd` |
| 3 | Give an executable-evidence SSH broker GO/NO-GO | met | Candidate D selected in `2026-07-16-git-provider-v1-a-broker-options.md`; commit `1c16e2d28` |
| 4 | Prototype the public-repository GitHub Git Data change-request plan locally | met | `github_api_commit_transport_test.exs`; 5 tests, 0 failures; commits `5a908b187`, `21334e29c` |
| 5 | Publish exact transport decision and downstream interfaces | met | `docs/superpowers/specs/2026-07-16-git-provider-v1-a-decisions.md`; architecture and security reviews report no remaining Critical/Important |
| 6 | Do not touch live/canary credentials, deploy, merge, ARB, EntityCaps, caps_json, no-tail, or bridge join | met | Diff contains test-only probes and documentation; no live operation occurred |
| 7 | Full local machine gate and PR-head CI green | deferred | Focused tests and all four static gates pass. `mix precommit` found baseline/environment failures described below; PR-head CI URL/status pending push. Lead decision: accept CI result or require a separate baseline-failure owner before Plan A approval. |

**Method friction:** The isolated worktree initially lacked `deps`, `_build`,
`SHELL`, and web `assets/node_modules`. Explicit dependency/build paths made the
Elixir evidence reproducible, but the return standard should state the supported
isolated-worktree dependency and asset bootstrap command. The initial prototype
also overclaimed delete/replay behavior; adversarial review correctly narrowed
the approved contract to UTF-8 upserts and deterministic local planning.

## Verification evidence

Passing:

```text
focused Plan A tests: 7 tests, 0 failures
ezagent.arch.scan: PASS
ezagent.doc.scan: PASS
ezagent.uri_query.scan: no violations
ezagent.check_invariants: all in-scope invariants clean
architecture review: 0 Critical / 0 Important after fixes
security review: 0 Critical / 0 Important after fixes
```

`mix precommit` result:

- forced warnings-as-errors compilation completed;
- umbrella tests were not green;
- `Ezagent.SkillRegistryTest` consistently saw shipped seed refs
  `dev-together`/`kanban-assistant` while only the orchestrator plugin role was
  loaded in that test context;
- one `OrphanReaperTest` and one PTY test failed in the full concurrent run and
  passed under `mix test --failed`;
- the retry then reached web setup and failed because this worktree has no
  `apps/ezagent_web/assets/node_modules`, while the root checkout does.

None of these failure paths includes the Plan A files. They are recorded rather
than relabeled green.

## Branch and merge request

- Rebase/base SHA: `ea529a89b2876cf292679e30803652e66e6971c3`
- Plan A head before this return: `21334e29c80f91166379179b6b0f72e9bdd33096`
- PR: #1423 remains Draft; do not merge yet.
- Open lead decisions: approve the narrow Plan A interface after PR-head CI, and
  assign/waive the unrelated local precommit baseline failures.
- No later production plan was executed. Plan B is only eligible to be written
  after architecture/security approval; Plan D remains blocked on an encrypted
  token backend.
