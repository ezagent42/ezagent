# Git Provider V1-A GitHub API transport prototype

**Date:** 2026-07-16

**Scope:** Test-only, pure request planning and local interpretation. No GitHub
network request, OAuth flow, production module, or credential persistence was
added.

## Contract exercised

`GithubGitDataPlan.build/2` accepts normalized regular-file changes and
repository/ref metadata. It produces this ordered request plan:

```text
GET base ref -> GET base commit/tree -> POST blobs -> POST tree -> POST commit -> POST ref -> POST pull
```

The plan contains paths, request bodies, the expected base SHA, and a
deterministic attempt key. It contains no authorization header, token, or credential
field. A local interpreter receives the sentinel authentication separately and
returns only:

```text
change_request_id
change_request_url
head_sha
```

No raw provider body or response headers cross the simulated transport result
boundary.

## Security cases

The executable prototype covers:

- relative regular files only; traversal and absolute paths are rejected;
- symlink and submodule changes are rejected;
- file count, per-file bytes, and total bytes are bounded;
- base SHA compare-before-write and strict base/head ref validation;
- deterministic local planning/result behavior from the attempt key;
- sanitized partial failures with no credential/header/raw-response leakage;
- absence of authorization and sentinel material from the request plan.

## Verification

Red phase:

```text
5 tests, 5 failures
GithubGitDataPlan.build/2 is undefined
```

Green command:

```bash
SHELL=/bin/bash \
MIX_DEPS_PATH=/home/huangjiajia/ezagent/deps \
MIX_BUILD_PATH=/home/huangjiajia/ezagent/.worktrees/git-provider-v1-design/_build \
MIX_ENV=test mix test \
  apps/ezagent_core/test/security/github_api_commit_transport_test.exs \
  --trace
```

Observed result:

```text
5 tests, 0 failures
```

This is a pure local fake. It does not claim GitHub API compatibility until Plan
D replaces it with a Req-backed GitHub plugin and contract tests against the
approved provider boundary.

It also does not prove provider-side replay idempotency. Plan D must persist an
attempt ledger, look up the deterministic head branch/change request, reconcile
partial success, and normalize ref/PR conflicts before retrying provider effects.

## Limitations

public anonymous checkout only; GitHub-specific; no private-repository checkout;
not final provider-neutral SSH transport; OAuth lifecycle remains Plan D.
