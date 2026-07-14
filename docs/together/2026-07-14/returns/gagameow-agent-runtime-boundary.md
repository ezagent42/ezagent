# AgentRuntime Boundary Return

**Returned at:** 2026-07-14 Asia/Taipei

**Last refreshed:** 2026-07-14 after rebase onto `origin/main@b29f0fc93`

**Status:** implementation complete for the approved ARB-0/ARB-1 scope; return is
conditionally ready because two upstream/environment gates remain red.

## Delivered

- Approved domain-agent narrow Facade ownership design; no core AgentRuntime,
  command bus, Port behaviour or duplicate PTY policy.
- Closed 34-edge Session→Agent lifecycle inventory.
- Syntax-only AST scanner over every Session production source.
- Exact 24-entry current-debt allowlist with stale, duplicate, schema and
  replacement checks.
- Adversarial fixtures for qualified/aliased/imported calls and lexical scope,
  including grouped aliases with options.
- Independent architecture verdict: `SOUND`; no remaining Critical/High finding.

ARB-2 through ARB-5 remain follow-up migration slices. This return does not claim
that the current 24-entry debt has already been removed.

## Verification after the latest rebase

| Gate | Result |
|---|---|
| touched-file format check | PASS |
| focused AgentRuntime architecture test | PASS — 23 tests, 0 failures |
| `mix ezagent.arch.scan` | PASS |
| `mix ezagent.doc.scan` | PASS |
| `mix ezagent.check_invariants` | PASS |
| architecture + invariants suite | BLOCKED — 484 tests, 3 existing shared-DB visibility failures caused by residual `probe-*` workspaces |
| `mix ezagent.uri_query.scan` | BLOCKED — `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex:216`, also present on `origin/main` |
| latest-main focused rerun | PASS — 23 tests, 0 failures on `b29f0fc93` |
| `SHELL=/bin/bash mix precommit` | BLOCKED — the URI-query violation remains; after installing local web dependencies, World tests still reproduce an upstream PTY state timeout |

No database cleanup, gate bypass or unrelated upstream fix was folded into this
branch to manufacture a green result.

## Upstream and follow-up boundaries

- PR #1375 and #1379 are present in the rebase baseline.
- PR #1381 is merged and correctly limits its claim to statically resolvable cap writers.
- PR #1382 lead-locks runtime structural enforcement as Ed25519-signed capability
  artifacts. Authority-persisting Agent Facade work waits for that Phase-4
  implementation/migration; it must not add an ETS fingerprint alternative.
- Read-only canary inspection confirms #1375 is deployed: the healthy container
  `ezagent-canary-ezagent-1` runs image `ezagent:22d966b04`, whose application
  commit descends from `ca65f5266`. The public `/_health` endpoint returns 200.
- `test-zyli-cc-1` now starts Claude and joins `agent_bridge:cc`, showing a
  credential-bearing runtime, but parks on an unrecognized interactive dialog.
  No terminal input or other production mutation was performed. Product-call and
  restart-persistence acceptance therefore remain incomplete.

## Requested lead action

1. Review/merge this ARB-0/ARB-1 gate independently of ARB-2..ARB-5.
2. Resolve or separately waive the upstream URI-query and World PTY-test failures
   with evidence.
3. Run the return branch in a clean CI database. The repo's `pnpm-lock.yaml` must
   also be synchronized with the four dependencies already present in
   `apps/ezagent_web/assets/package.json`; local verification used
   `pnpm install --lockfile=false` without repository changes.
4. Schedule ARB-2..ARB-5 as shrink-only slices until the allowlist reaches zero.
