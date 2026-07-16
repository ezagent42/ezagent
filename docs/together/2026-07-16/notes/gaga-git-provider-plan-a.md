# gaga — Git Provider V1 Plan A execution ledger

**Date:** 2026-07-16

**Track:** agent 开发自举（Git provider dev-loop / provisioning）

**Owner:** gaga

**Worktree:** `/home/huangjiajia/ezagent/.worktrees/git-provider-v1-design`

**Branch:** `docs/git-provider-v1-design`

**Start SHA:** `84421c25bbb2c42a43f6a190aea4ba47f35e88cc`

**Base:** `origin/main` at `ea529a89b2876cf292679e30803652e66e6971c3`

**PR:** [#1423](https://github.com/ezagent42/ezagent/pull/1423) (Draft; review and Plan A proceed in parallel)

## Today’s assignment

Execute only Plan A from
`docs/superpowers/plans/2026-07-15-git-provider-v1-a-security-prerequisites.md`:

1. inventory the current Cap, secret-store, SSH-parser, OS-process, and plugin primitives;
2. reproduce same-UID sentinel credential exposure;
3. decide SSH broker isolation GO/NO-GO using executable evidence;
4. prototype the public-checkout + GitHub Git Data API request plan locally;
5. publish the transport decision matrix and exact downstream interfaces.

## Acceptance boundary

- No production credential or real private key.
- No canary/live-node mutation, raw RPC, arbitrary eval, deployment, or merge.
- No `0600` temporary key is accepted as an isolation proof.
- SSH transport is GO only with evidence that the agent cannot observe or reuse credential material.
- GitHub API transport is explicitly GitHub-specific and public-checkout-only unless authenticated checkout is separately proven.
- Plans B–E do not start in this work item.
- Honest label remains: loose-coupled, not final mount; #1360 Layer B pending.

## Execution log

| Task | Status | Result / evidence | Commit |
|---|---|---|---|
| Baseline and ledger | complete | Worktree clean; rebased on current main; PR #1423 open Draft | `8fcbfe1b1` |
| 1. Primitive inventory | complete | Secret Store absent; SSH parser absent; Cap signed/receiver-bound; OsProcess lifecycle-only; plugin rollback pattern reusable. See `docs/superpowers/notes/2026-07-16-git-provider-v1-a-inventory.md` | `8fcbfe1b1` |
| 2. Same-UID reproduction | complete | Both mode-0600 known-path read and `/proc/<pid>/environ` observation reproduced under UID 1000; 2 tests, 0 failures. See `docs/superpowers/notes/2026-07-16-git-provider-v1-a-isolation-probe.md` | `1e8b913fd` |
| 3. Broker GO/NO-GO | complete | Candidate D selected: no approved agent-inaccessible boundary. SSH remains disabled; public checkout + GitHub API is the viable Plan D route. See `docs/superpowers/notes/2026-07-16-git-provider-v1-a-broker-options.md` | `1c16e2d28` |
| 4. GitHub API request-plan prototype | complete | Pure plan/local fake proves Git Data sequence, input bounds, base/ref checks, idempotency, partial-failure sanitization, and credential-free plan. 5 tests, 0 failures. See `docs/superpowers/notes/2026-07-16-git-provider-v1-a-github-api-transport.md` | pending |
| 5. Decision/interface closeout | pending | — | — |

## Verification commands

```bash
git diff --check
SHELL=/bin/bash MIX_DEPS_PATH=/home/huangjiajia/ezagent/deps \
  MIX_BUILD_PATH="$PWD/_build" MIX_ENV=test mix test \
  apps/ezagent_core/test/security/os_process_secret_isolation_probe_test.exs --trace
SHELL=/bin/bash MIX_DEPS_PATH=/home/huangjiajia/ezagent/deps \
  MIX_BUILD_PATH="$PWD/_build" MIX_ENV=test mix test \
  apps/ezagent_core/test/security/github_api_commit_transport_test.exs --trace
```

Additional focused commands and their exact results are appended to this ledger and the Plan A evidence notes as work proceeds.

## Stop conditions

Stop and report rather than broadening scope when:

- the approved secret backend, parser, or isolation primitive is absent;
- a required prototype would need sudo, a host-user mutation, a new unapproved dependency, or a production credential;
- review changes the architecture/security scope before Plans B–E;
- lead authorization is required for external state changes.
