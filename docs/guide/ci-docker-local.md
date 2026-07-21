# Guide: Local ubuntu-CI harness (reproduce the ubuntu-only flakes)

> **Operational how-to** for running the GitHub `ubuntu-latest` CI environment
> **locally via docker**, so the recurring CI flakes that **only manifest on the
> ubuntu runner** can be reproduced and fixed — which **macOS cannot do**.
> Referenced from [`CONTRIBUTING.md`](../../CONTRIBUTING.md). Root-cause analysis:
> [`docs/together/2026-06-27/notes/ci-flake-diagnosis.md`](../together/2026-06-27/notes/ci-flake-diagnosis.md).

## Why this exists

The recurring `precommit + check_invariants` reds — `PluginIsolationWorkspaceTest`,
`Ezagent.Domain.AgentReadTest`, `DefaultSessionTemplateSeedTest`,
`PresenceReadReceiptsE2ETest` — are **timing races** rooted in the Ecto SQL Sandbox
**shared-mode revert** (a globally-supervised Kind queries on a connection whose owner
just terminated → `DBConnection.OwnershipError`, surfaced as empty Loader children or a
missing seed row). They are **green on darwin, red on the ubuntu runner**: the diagnosis
confirmed the *identical* seed `979933` passed on macOS but failed twice on CI. The
discriminator is **scheduler/core count × owner-teardown churn × shared-DB contention**,
all maximised by CI's full-umbrella, unpartitioned, low-vCPU invocation.

So you cannot reproduce — let alone *verify a fix for* — these flakes on a Mac. This
harness boots the **same linux/OTP environment CI uses** in a CPU-constrained container,
which is the only way to surface the race off a real ubuntu runner.

## What it mirrors (read from `.github/workflows/ci.yml`)

| dimension | CI (`ubuntu-latest`) | this harness |
|---|---|---|
| OS / libc | ubuntu (debian-family glibc) | `hexpm/elixir:…-debian-bookworm` |
| Elixir / OTP | 1.19 / 28 | 1.19.5 / 28.4.2 (pinned) |
| Node | 25 | 25 (nodesource) |
| pnpm | 10.33.0 (corepack) | 10.33.0 (corepack) |
| postgres | `postgres:16` service | `postgres:16` service |
| DB partition | **none** (one shared `ezagent_pg_compat_test`) | **none** (same) |
| vCPU | ~4 (max_cases:8 == ExUnit default schedulers×2) | `cpuset` 4 (mirror) / 2 (amplify) |
| gate run | `mix precommit` + `mix ezagent.check_invariants` | `mix ci.local` (same chain) |

**Core constraint is the engine.** We use `--cpuset-cpus` (CPU **affinity** → BEAM sees
N cores → starts N schedulers) plus `ERL_AFLAGS="+S k:k"` to pin the scheduler count.
`--cpus` (a CFS quota) does **not** work: `nproc` still reports all host cores, BEAM
starts 28 schedulers throttled, and the scheduling behaviour never changes. Fewer
schedulers + an oversubscribed `--max-cases` = more owner-teardown interleaving = the
shared-mode-revert race.

## Files

| file | role |
|---|---|
| `docker/Dockerfile.ci` | the linux CI image (pinned Elixir/OTP/Node/pnpm; deps + `_build` baked in) |
| `docker/docker-compose.ci.yml` | `postgres:16` service + the `ci` runner (cpuset constraint) |
| `docker/ci-runner.sh` | entrypoint: `gate` (lightweight deterministic gate — the ci.yml `gate` job) / `full-suite` (`mix ci.local`) / `repro` (flake hunt) / `shell` |
| `Makefile` | `make ci.docker` / `ci.gate` / `ci.full` / `ci.repro` / `ci.repro.amplify` / `ci.down` |

## Usage

One command (build + run the exact CI gate from linux):

```bash
make ci.docker
```

Individual targets:

```bash
make ci.docker.build      # build the image (base on lock change + thin source layer)
make ci.gate              # run the LIGHTWEIGHT deterministic gate (the ci.yml `gate` job chain) inside linux
make ci.full              # run the FULL `mix ci.local` (the ci.yml `full-suite` chain) inside linux
make ci.repro             # hunt the flake: seed sweep at cpuset=0-3 (~CI's ~4 vCPU)
make ci.repro.amplify     # MORE race pressure: cpuset=0-1, 2 schedulers, max_cases=8
make ci.shell             # drop into the container
make ci.down              # tear down postgres + volumes
```

> **Proxy:** the host is behind clash. The build reaches hex/apt/npm via
> `host.docker.internal`. Override:
> `make ci.docker.build DOCKER_BUILD_PROXY=http://host.docker.internal:7896`.
> postgres + the test run go direct (no proxy).

### Tuning the hunt

`make ci.repro` runs `docker/ci-runner.sh repro`, which loops the **full-umbrella**
`mix test` across a seed sweep (default includes the known-red CI seed `979933`),
greps each run for the named flake suites + `OwnershipError`, and reports hits. Override
via env on the compose run:

```bash
# narrow + intensify
CPUSET=0-1 SCHEDULERS=2 MAX_CASES=8 SEEDS="979933 979933 979933" RESET_DB_EACH=0 \
  docker-compose -f docker/docker-compose.ci.yml run --rm ci repro
```

- `CPUSET` — host cores the container may use (affinity). Fewer = more race.
- `SCHEDULERS` — BEAM scheduler pin (keep == cpuset width).
- `MAX_CASES` — ExUnit concurrency. Oversubscribe (8 on 2 cores) to amplify.
- `SEEDS` — space-separated; repeat a seed to re-roll the same ordering under fresh timing.
- `RESET_DB_EACH` — `0` (default) leaves rows for cross-app contention (amplify); `1`
  recreates the DB per iteration (faithful per-run isolation).

**Must be the full umbrella.** A single-app `cd apps/<one> && mix test` produces a
*different* failure set (the `:umbrella_only` cross-tier `*.app` missing-dep errors), not
the flake. The harness always runs the root `mix test`.

### Honest caveat — docker-on-mac is a linux VM, not bare metal

Docker Desktop / OrbStack run a linux VM under the mac hypervisor. The container is
genuinely linux (right libc, right scheduler), but timing is still hypervisor-mediated,
so the hit-rate is lower than a bare ubuntu runner. Treat repro as a **budgeted hunt**:
if `make ci.repro` is green, escalate to `make ci.repro.amplify`, then tighten `CPUSET`
to `0` (single core) and repeat the known-red seed. On a true linux host this same
harness reproduces the race directly.

## Proven reproduction (2026-06-27)

This harness **did** reproduce the macOS-impossible flake. On the **first** `make ci.repro`
iteration (cpuset 0-1, 2 schedulers, `max_cases 8`, **seed 979933** — the seed the
diagnosis records as *green on macOS, red on the runner*), the `ezagent_domain_session`
app failed with the named target flakes on a freshly-created DB:

- **`Ezagent.Domain.AgentReadTest`** — `(KeyError) key :effective_body not found` (cold-read race)
- **`DefaultSessionTemplateSeedTest`** — `(MatchError) {:error, :no_such_actor}` from
  `seed_default_session_template_now/1` (spawn-readiness race)
- `SessionCreateOrchestratorDecoupleTest` — same `:no_such_actor` class

Full evidence + honest caveats (which failures are constraint artifacts vs the real
race): [`docs/notes/2026-06-27-ci-flake-docker-repro.md`](../notes/2026-06-27-ci-flake-docker-repro.md).

## Deploy parity

`docker/Dockerfile.ci` shares its base (`hexpm/elixir:1.19.5-erlang-28.4.2-debian-bookworm`)
and OTP/Elixir pins with `docker/Dockerfile.dev`/`.prod`, and uses the same `postgres:16`
the prod compose targets. So the image **doubles as a deploy-parity base**: a "does it
boot the umbrella + reach postgres on linux with the pinned OTP" smoke is exactly what
`make ci.gate` exercises. It is **not** a `mix release` (prod is a release image), so it
is a *parity reference* for the runtime environment, not the deploy artifact itself.
