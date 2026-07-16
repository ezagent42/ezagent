# Git Provider V1-A same-UID isolation probe

**Date:** 2026-07-16

**Scope:** Reproduce the current `Ezagent.Runtime.OsProcess` credential boundary
with sentinel-only material. This is evidence for Plan A, not a production
credential implementation.

## Environment

```text
uid=1000(huangjiajia) gid=1000(huangjiajia)
Linux LAPTOP-E0QGQ218 6.6.87.2-microsoft-standard-WSL2 x86_64
worktree=/home/huangjiajia/ezagent/.worktrees/git-provider-v1-design
```

The worktree uses its own `_build` and the root checkout's existing dependency
directory through `MIX_BUILD_PATH` and `MIX_DEPS_PATH`. No dependency was added.

## Reproduction

Probe:

```text
apps/ezagent_core/test/security/os_process_secret_isolation_probe_test.exs
```

It exercises only argv-list `Ezagent.Runtime.OsProcess.spawn/2` calls and always
stops the returned `exec_pid`. The literal
`EZAGENT_SECRET_SENTINEL_DO_NOT_SHIP` is not a real credential.

Cases:

1. A sentinel file is created outside the child working directory with mode
   `0600`. A same-UID child given the path reads it successfully.
2. A sleeping child receives a sentinel environment variable. Another same-UID
   child reads `/proc/<pid>/environ` and observes the variable successfully.

Exact passing command:

```bash
SHELL=/bin/bash \
MIX_DEPS_PATH=/home/huangjiajia/ezagent/deps \
MIX_BUILD_PATH=/home/huangjiajia/ezagent/.worktrees/git-provider-v1-design/_build \
MIX_ENV=test mix test \
  apps/ezagent_core/test/security/os_process_secret_isolation_probe_test.exs \
  --trace
```

Observed result:

```text
2 tests, 0 failures
```

The first attempt omitted `SHELL`; erlexec stopped before ExUnit assertions with
`SHELL environment variable not set` and `port_exited_with_status, 4`. Adding
the existing host shell as an explicit test-process environment precondition
allowed the unchanged probes to run. This setup failure is not isolation
evidence.

## Result

Mode `0600` restricts other UIDs; it does not separate an agent and credential
broker that run under this same UID. On this host, `/proc` environment visibility
also exposes broker-injected secret material to the same runtime identity.

Current OsProcess boundary: lifecycle-safe, credential-isolation NO-GO by itself.
