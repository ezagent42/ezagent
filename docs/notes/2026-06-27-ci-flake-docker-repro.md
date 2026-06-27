# CI flake reproduced locally on ubuntu-docker (macOS could not)

**Date:** 2026-06-27
**Harness:** `make ci.repro` — `docker/Dockerfile.ci` + `docker/docker-compose.ci.yml` +
`docker/ci-runner.sh` (guide: [`docs/guide/ci-docker-local.md`](../guide/ci-docker-local.md)).
**Root-cause analysis this validates:** `ci-flake-diagnosis.md` (the
`precommit + check_invariants` recurring reds — Sandbox shared-mode revert +
spawn-readiness races, **green on darwin, red on the ubuntu runner**).

## TL;DR — the key result

The diagnosis recorded an honest caveat: seed **979933** failed on the ubuntu CI runner
(PR #1037) but came back **GREEN on macOS** for the *same seed* — proving the flake is a
timing race the dev box cannot surface. **This harness reproduced it on the FIRST
iteration**, seed 979933, in a CPU-constrained linux container — exactly where macOS
cannot.

```
make ci.repro   (CPUSET=0-1  SCHEDULERS=2  MAX_CASES=8  RESET_DB_EACH=0  full umbrella)
iter 1  seed=979933  →  FLAKE REPRODUCED   (AgentReadTest + DefaultSessionTemplateSeedTest, fresh DB)
iter 2  seed=979933  →  FLAKE REPRODUCED   (same two named suites)
```

**Hit-rate: 2/2 on seed 979933** (the diagnosis's known-red CI seed). Iteration 1 runs
against a **freshly created DB** (the runner creates the DB once before the loop, and iter
1 is its first consumer), so iter 1 is **not** a dirty-cross-run artifact — it is faithful
to CI's fresh-postgres-per-job. Iter 2 (reused DB) reproducing the *same* suites shows the
race is robust, not accumulation-dependent.

## The reproduced failures (iteration 1, seed 979933)

App `ezagent_domain_session` — **4 failures** (the spawn-readiness / cold-read race class):

| # | suite | assertion | mechanism |
|---|-------|-----------|-----------|
| 1 | `SessionCreateOrchestratorDecoupleTest` (setup `:21`) | `(MatchError) … {:error, :no_such_actor}` | spawned orchestrator Kind not registered when queried |
| 2 | **`Ezagent.Domain.AgentReadTest`** `:127` (NAMED TARGET) | `(KeyError) key :effective_body not found … assert state.effective_body == %{"tone" => "decisive"}` | cold-agent read race — snapshot/slice not settled |
| 3 | **`DefaultSessionTemplateSeedTest`** setup `:53` (NAMED TARGET) | `(MatchError) … {:error, :no_such_actor}` | `seed_default_session_template_now/1` — seeded Session/Agent Kind not ready |
| 4 | **`DefaultSessionTemplateSeedTest`** (Task #58 case) | `(MatchError) … {:error, :no_such_actor}` | same class |

Two of these (`AgentReadTest`, `DefaultSessionTemplateSeedTest`) are **explicitly the
flakes named in the task**. The `:no_such_actor` from `seed_default_session_template_now`
is the exact spawn-readiness race `docs/futures/todo.md` flagged as **STILL OPEN** after
the prior fix batch.

Throughout the run the **shared-mode-revert engine** the diagnosis names is also visible
(in caught/log-noise form, e.g. `RouterTest`):

```
Ezagent.Kind.StateRebuilder.snapshot_exists?: snapshot lookup raised …
%DBConnection.OwnershipError{… cannot find ownership process … using mode :manual.
(Note that a connection's mode reverts to :manual if its owner terminates.)}
```

> These caught `OwnershipError` warnings appear on macOS too — they evidence the
> *mechanism*, not the *failure*. The discriminating proof is the **uncaught** failures
> in the table above (real assertion flunks), which macOS did not produce for seed 979933.

Iter 2 also surfaced the **canonical §1.1 mechanism in uncaught form** — a
globally-supervised Kind querying the DB in `init/1` on the reverted pool:

```
Ezagent.AgentBridge.Channel: failed to ensure Agent Kind for entity://team-alpha/agent/… :
  %DBConnection.OwnershipError{… mode :manual …}
    Ezagent.Kind.Snapshot.fetch_snapshot/2  (kind/snapshot.ex:230)
    Ezagent.Kind.Server.init/1              (kind/server.ex:110)
```

This is exactly the `Kind.Server.init → Snapshot.fetch_snapshot` revert-path the diagnosis
names as the engine behind the seed/read flakes — reproduced here, off the runner.

## What is NOT clean repro (honest caveats)

Two failures in other apps look like **CPU-constraint artifacts**, not the timing flake —
called out so they are not over-claimed:

- `ezagent_core` `CompilerDeadCodeGateTest` — `(Mix) Could not find a Mix.Project`: a test
  that shells out to `mix compile`; the subprocess lost its Mix project context. A harness
  /subprocess-env artifact, unrelated to the sandbox race.
- `ezagent_plugin_feishu` `SidecarOrphanReapTest` — a poll-window timing assertion on
  process reaping; sensitive to the 2-core throttle (a constraint artifact, not the flake).

`PluginIsolationWorkspaceTest` (app `ezagent_domain_workspace`) was **GREEN this
iteration** (179/0) — consistent with the diagnosis that the named suites flake
*intermittently*; on this seed/timing the session-app suites fired instead.

## Reproduce it yourself

```bash
make ci.docker.build                 # build the linux CI image (once)
make ci.repro                        # cpuset 0-1, 2 schedulers, max_cases 8, seed sweep incl. 979933
# faithful per-run fresh DB (rules out accumulation):
RESET_DB_EACH=1 SEEDS="979933" docker-compose -f docker/docker-compose.ci.yml run --rm ci repro
# more pressure if a run is green:  CPUSET=0 SCHEDULERS=1 make ci.repro
```

## Significance

1. **The macOS-impossible repro now exists locally.** A dev (or the deeper flake-fix
   task) can iterate on `AgentReadTest` / `DefaultSessionTemplateSeedTest` and *verify a
   fix* off the ubuntu runner — previously impossible from a Mac.
2. **Confirms the diagnosis empirically** (spawn-readiness `:no_such_actor` + cold-read
   `KeyError`), and confirms the todo's STILL-OPEN item is real and now reproducible.
3. **Deploy parity:** the same image base (`hexpm/elixir:1.19.5-erlang-28.4.2-debian-bookworm`
   + `postgres:16`) boots the umbrella on linux — a runtime-parity reference for the
   docker deploy (not the `mix release` artifact itself).
