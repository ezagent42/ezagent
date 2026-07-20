# Dockerize CI (gate + full-suite) on OrbStack — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `.github/workflows/ci.yml`'s `gate` + `full-suite` backend jobs OFF native `mix` on the self-hosted macOS runner and INTO the existing OrbStack docker CI harness (`docker/docker-compose.ci.yml`), each PR job in its own compose project (isolated postgres + container), so a 2nd/3rd self-hosted runner becomes safe and per-PR CI runs concurrently.

**Architecture:** The dockerized harness already builds a pinned linux image (Elixir 1.19.5 / OTP 28.4.2 / Node 25 / pnpm 10.33.0) and runs `mix ci.local` against a `postgres:16` service on an isolated compose network. We (1) split the build so per-PR rebuilds don't refetch/recompile deps, (2) add a lightweight `gate` entrypoint distinct from the full-suite `mix ci.local` run, (3) parameterize compose with a per-run project name so N runners never collide, (4) rewrite the two ci.yml jobs to `docker compose build` + `run --rm`, and (5) register 2-3 self-hosted runner processes on the one mac. Isolation comes from each compose project owning its own postgres container — NOT from `MIX_TEST_PARTITION`.

**Tech Stack:** GitHub Actions (self-hosted macOS ARM64 runners), OrbStack/Docker 29.4 (BuildKit), docker compose, Debian bookworm image, Elixir/OTP/Mix umbrella (25 apps), postgres:16.

## Global Constraints

- **Pins are load-bearing, copy verbatim:** Elixir `1.19.5`, OTP `28.4.2`, base `hexpm/elixir:1.19.5-erlang-28.4.2-debian-bookworm-20260518`, Node `25`, pnpm `10.33.0`, postgres `16`. These already live in `docker/Dockerfile.ci` + `docker/docker-compose.ci.yml`; do not drift them.
- **Honest gate must be preserved:** `mix ci.local` arms `EzagentCore.CiLocalResult` via `arm_ci_local_result_capture/1` (step 1 of the `ci.local` alias) and ends with `finalize_ci_local/1` → `System.halt(1)` iff `after_suite` recorded failures, else `halt(0)`. `docker compose run --rm ci <mode>` propagates the container exit code, so a RED suite fails the job. Every task that runs the full suite MUST run it through `mix ci.local` (not a raw `mix test`) so this honesty holds. CI steps MUST assert on the exit code.
- **Non-root:** the suite runs as user `ezagent` (erlexec refuses root). Do not add `USER root` steps that run tests.
- **No proxy needed on this host:** direct egress works (verified: hex.pm HTTP 200; apt/nodesource/npm all fetch clean with empty `HTTP_PROXY`). Proxy fallback is `http://host.docker.internal:7897` (clash mixed-port; `7896` also open). `docker compose build` defaults `HTTP_PROXY`/`HTTPS_PROXY` to `${DOCKER_BUILD_PROXY:-}` (empty).
- **postgres publishes NO host port:** the compose `postgres` service is internal-only (reachable as `postgres:5432` on the compose network) and uses `tmpfs`. Parallel jobs therefore CANNOT collide on a host port — the only collision surface is container/network/volume *names* (solved by a unique `-p` project name) and the shared `image:` tag (solved by the warmed base image, Task 1/3).
- **Use `pnpm` not `npm`, `uv run` not bare `python`.**
- **Do NOT touch `docker/Dockerfile.dev`, `docker-compose.dev.yml`, or `entrypoint.prod.sh`** — those are the dev/deploy stacks, out of scope.

---

## Current state (what we are replacing)

`.github/workflows/ci.yml` on `main` (`5f5c811d7`) has these backend jobs, all now `runs-on: [self-hosted, macOS, ARM64]` (GitHub-hosted ubuntu billing exhausted 2026-07-20):

- **`gate`** — native `mix`: starts an ephemeral native postgres (`brew --prefix postgresql@18`, port **55441**, `$RUNNER_TEMP/ezagent-ci-gate-pg`), then runs the deterministic chain: `deps.get` → `compile --warnings-as-errors --force` → **`world.e2e.fixtures --check`** → `format --check-formatted` → `ecto.create`/`migrate` → `ezagent.check_invariants` → `ezagent.socialware.check` → arch/invariant ExUnit subset (5 paths) → reflow-rehearsal (`--include reflow_rehearsal`, 2 paths) → teardown.
- **`full-suite`** (`needs: [gate]`, `if: github.event_name != 'pull_request'`) — native `mix`: ephemeral native postgres (port **55440**, `MIX_TEST_PARTITION=${{ github.run_id }}`) → **`mix ci.local`** → teardown. `timeout-minutes: 40`.
- **`gitleaks`**, **`dispatch-canary`**, and a **`frontend`** reusable-workflow job — OUT OF SCOPE for this plan (gate + full-suite only). See "Out of scope / follow-ups".

Both jobs serialize on the one runner and a native 2nd runner is unsafe (two `mix test` on one host contend on shared postgres). Dockerizing gives each job its own postgres container → a 2nd/3rd runner is safe.

### Harness ↔ ci.yml parity map (audit — nothing may be silently dropped)

| ci.yml `gate` step | in `mix ci.local`? | docker home after this plan |
|---|---|---|
| `mix deps.get` | yes | `full-suite` mode (ci.local) + baked in image |
| `compile --warnings-as-errors --force` | yes (`precommit`) | both modes |
| **`mix world.e2e.fixtures --check`** | **NO** | **NEW `gate` mode step (Task 2) — the one true gap** |
| `format --check-formatted` | yes (`precommit` `format`) | both modes |
| `ecto.create`/`migrate` | yes | both modes |
| `ezagent.check_invariants` | yes | both modes |
| `ezagent.socialware.check` | yes (`run_socialware_check`) | both modes |
| arch/invariant ExUnit subset (5 paths) | superset (full `test`) | `gate` mode runs the subset; `full-suite` runs all |
| reflow-rehearsal (`--include reflow_rehearsal`) | yes — `:reflow_rehearsal` is **NOT** default-excluded, full `test` runs it | `full-suite` runs by default; `gate` mode runs the 2 paths explicitly |

`mix ci.local` extra steps beyond the gate job (all preserved by `full-suite` mode): `pnpm_install_assets`, `ezagent.uri_query.scan`, `run_cc_sdk_worker_tests`, `finalize_ci_local`.

**Design decision:** the existing `ci-runner.sh gate` mode runs the FULL `mix ci.local` — i.e. it is really full-suite semantics, NOT the lightweight deterministic gate. Task 2 fixes this naming/behaviour mismatch: rename the current mode to `full-suite` and add a genuinely lightweight `gate` mode that mirrors the ci.yml gate chain (adding the missing `world.e2e.fixtures --check`).

---

## Validation baseline (already run against `5f5c811d7`)

- **Image build (no proxy):** `docker compose -f docker/docker-compose.ci.yml build` — see report for result/timing. Direct egress; no proxy arg needed.
- **In-container gate:** `docker compose -f docker/docker-compose.ci.yml run --rm ci gate` runs the honest `mix ci.local` — see report for GREEN/RED + timing. Note this current `gate` mode == full ci.local (Task 2 changes that).

---

## Task 1: Split the Dockerfile so per-PR rebuilds don't refetch/recompile deps

**Problem:** `docker/Dockerfile.ci` line 66 does `COPY . .` BEFORE `mix deps.get` / `pnpm install` / `mix compile`. Any source change invalidates that layer, so every PR rebuilds deps + node_modules + full compile from scratch (~10-15 min). Acceptable for the build-once/run-many-seeds repro tool it was written for; unacceptable for per-PR CI.

**Approach (recommended): a two-image split.** A `ezagent-ci-base` image (deps fetched + deps compiled + `node_modules` present) is rebuilt ONLY when `mix.lock` or an asset lockfile changes; per-PR builds are `FROM ezagent-ci-base` + `COPY . .` (source only) → the base layers are reused, so a source-only change rebuilds in seconds. The base bakes the expensive, source-independent work; the per-PR run-time `mix ci.local` force-recompiles the project anyway (`precommit` uses `compile --warnings-as-errors --force`), so the per-PR image need not re-bake a project compile.

**Files:**
- Create: `docker/Dockerfile.ci-base` (the deps/node_modules base)
- Modify: `docker/Dockerfile.ci` (become `FROM ezagent-ci-base` + source COPY)
- Modify: `docker/docker-compose.ci.yml` (add a `base` build target or document the two-step build)
- Create: `docker/build-ci-image.sh` (one script: build base if lock changed, then build thin image)

**Interfaces:**
- Produces: image `ezagent-ci-base:<lockhash>` and `ezagent-ci-base:latest`; image `ezagent-ci-local:latest` (`FROM ezagent-ci-base:latest`).
- Consumes: nothing new; same pins as `docker/Dockerfile.ci` today.

- [x] **Step 1: Create `docker/Dockerfile.ci-base` — everything up to and including deps + node_modules, NO source**

Move the current `docker/Dockerfile.ci` lines 21-95 into `docker/Dockerfile.ci-base`, but replace the single `COPY . .` (line 66) with manifest-only copies so the deps/pnpm layers are keyed on lockfiles, not source. Use BuildKit `COPY --parents` (the `# syntax=docker/dockerfile:1` header already enables it) to copy the 25 umbrella `apps/*/mix.exs` preserving structure:

```dockerfile
# syntax=docker/dockerfile:1
FROM hexpm/elixir:1.19.5-erlang-28.4.2-debian-bookworm-20260518
# ... (identical ARG/ENV proxy block, apt+node25, pnpm@10.33.0 pin, useradd ezagent,
#      MIX_HOME, mix local.hex/rebar — copy verbatim from current Dockerfile.ci lines 23-61) ...

WORKDIR /app
# Manifests ONLY — deps layer keyed on mix.lock, not source.
COPY mix.exs mix.lock ./
COPY --parents apps/*/mix.exs ./
RUN for v in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do \
      eval "val=\${$v:-}"; [ -z "$val" ] && unset "$v" || true; \
    done; \
    ok=0; for i in 1 2 3 4 5; do \
      HEX_HTTP_CONCURRENCY=1 HEX_HTTP_TIMEOUT=180 mix deps.get && { ok=1; break; } || { echo "deps.get retry $i"; sleep 8; }; \
    done; \
    [ "$ok" = 1 ] || { echo "deps.get failed after 5 retries"; exit 1; }
# Asset manifests ONLY — pnpm layer keyed on package.json/lockfiles, not source.
COPY --parents apps/ezagent_web/assets/package.json apps/ezagent_web/assets/pnpm-lock.yaml ./
COPY --parents apps/ezagent_plugin_world/assets/package.json apps/ezagent_plugin_world/assets/pnpm-lock.yaml ./
COPY --parents apps/ezagent_plugin_hello/assets/package.json apps/ezagent_plugin_hello/assets/pnpm-lock.yaml ./
RUN pnpm --dir apps/ezagent_web/assets install --no-frozen-lockfile --config.strictDepBuilds=false \
    && pnpm --dir apps/ezagent_plugin_world/assets install --no-frozen-lockfile --config.strictDepBuilds=false \
    && pnpm --dir apps/ezagent_plugin_hello/assets install --no-frozen-lockfile --config.strictDepBuilds=false
# Compile DEPS only (source not present yet) so the deps _build is warm.
RUN for v in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do \
      eval "val=\${$v:-}"; [ -z "$val" ] && unset "$v" || true; \
    done; \
    mix deps.compile
ENV HTTP_PROXY="" HTTPS_PROXY="" http_proxy="" https_proxy="" NO_PROXY="" no_proxy=""
ENV SHELL=/bin/bash
```

> If `pnpm-lock.yaml` filenames differ, `ls apps/*/assets/` first and copy the actual lockfile names. If `COPY --parents` is unavailable on the installed BuildKit, fall back to 25 explicit `COPY apps/<app>/mix.exs apps/<app>/mix.exs` lines (verbose but robust).

> **As implemented (2026-07-21):** `COPY --parents` works on OrbStack BuildKit (docker 29.4). One deviation from the block above was REQUIRED: `mix deps.compile` → `mix deps.compile --skip-local-deps`. The umbrella's apps depend on each other via `in_umbrella: true` path deps, so a bare root `mix deps.compile` tries to compile sibling apps whose `lib/` source is deliberately absent from the base — failing with `could not compile dependency :ezagent_plugin_email`. `--skip-local-deps` compiles exactly the Hex deps (verified: no non-umbrella `path:` deps exist), which is the "deps only, source not present" intent.

- [x] **Step 2: Rewrite `docker/Dockerfile.ci` to build on the base**

```dockerfile
# syntax=docker/dockerfile:1
ARG CI_BASE=ezagent-ci-base:latest
FROM ${CI_BASE}
WORKDIR /app
# Source now — this is the ONLY layer that changes per PR.
COPY . .
RUN chmod +x docker/ci-runner.sh \
    && chown -R ezagent:ezagent /app /home/ezagent
USER ezagent
ENTRYPOINT ["/app/docker/ci-runner.sh"]
```

(The run-time `mix ci.local` force-recompiles the project against the warm deps `_build`, so no project-compile bake is needed here. If a warm project compile is desired for `gate`-mode speed, add `RUN mix compile` before the `USER ezagent` line — but it re-runs per PR, so leave it out unless measured worth it.)

- [x] **Step 3: Create `docker/build-ci-image.sh` — build base on lock change, then thin image**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
LOCKHASH="$(cat mix.lock apps/*/assets/pnpm-lock.yaml 2>/dev/null | shasum -a 256 | cut -c1-12)"
BASE_TAG="ezagent-ci-base:${LOCKHASH}"
if ! docker image inspect "$BASE_TAG" >/dev/null 2>&1; then
  echo "==> building CI base $BASE_TAG (deps changed)"
  DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile.ci-base -t "$BASE_TAG" -t ezagent-ci-base:latest .
else
  echo "==> CI base $BASE_TAG cached — skipping base build"
  docker tag "$BASE_TAG" ezagent-ci-base:latest
fi
echo "==> building thin CI image (source layer only)"
DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile.ci --build-arg CI_BASE=ezagent-ci-base:latest -t ezagent-ci-local:latest .
```

- [x] **Step 4: Verify per-PR rebuild is fast — deps/pnpm layers CACHED**

```bash
docker/build-ci-image.sh                       # cold: builds base + thin (~10-15 min once)
touch apps/ezagent_core/lib/ezagent_core.ex    # a source-only change
time docker/build-ci-image.sh                   # warm: base cached, only COPY+chown re-run
```
Expected: second run prints `CI base … cached — skipping base build` and completes in **< 60s** (no `deps.get`, no `pnpm install`, no `deps.compile`).

- [x] **Step 5: Commit**

```bash
git add docker/Dockerfile.ci docker/Dockerfile.ci-base docker/build-ci-image.sh docker/docker-compose.ci.yml
git commit -m "ci(docker): split base image so per-PR builds reuse deps/node_modules cache"
```

---

## Task 2: Add a lightweight `gate` entrypoint; rename the full-suite entrypoint

**Problem:** `docker/ci-runner.sh` mode `gate` execs `mix ci.local` (the WHOLE suite). The ci.yml `gate` job is a fast deterministic subset. Map each ci.yml job to a distinct mode: `gate` (lightweight, mirrors ci.yml gate chain incl. the missing `world.e2e.fixtures --check`), `full-suite` (the honest `mix ci.local`). Keep `repro`/`shell`.

**Files:**
- Modify: `docker/ci-runner.sh` (rename `gate` → `full-suite`; add new `gate`)
- Modify: `docs/guide/ci-docker-local.md` (document the two modes)

**Interfaces:**
- Produces: `ci-runner.sh` accepts `gate | full-suite | repro | shell`.
- Consumes: same env (`POSTGRES_*`, `MIX_ENV=test`, `ERL_AFLAGS`).

- [ ] **Step 1: Rename the current `gate` case to `full-suite` in `docker/ci-runner.sh`**

Change the `gate)` case (lines 70-75) to `full-suite)` — body unchanged (`env_banner; wait_for_pg || exit 1; exec mix ci.local`). Update the header comment block's mode list.

- [ ] **Step 2: Add a new lightweight `gate` case mirroring the ci.yml gate chain**

Insert before `full-suite)`. Uses `set -e` semantics via explicit `|| exit` so any red step fails honestly (each `mix` step exits non-zero on failure; a standalone `mix test` sets exit 1 via ExUnit's `at_exit` — the `halt` dodge is only needed for the multi-step `ci.local`, not here):

```bash
  gate)
    env_banner; wait_for_pg || exit 1
    set -e
    mix compile --warnings-as-errors --force
    mix world.e2e.fixtures --check
    mix format --check-formatted
    mix ecto.create --quiet
    mix ecto.migrate --quiet
    mix ezagent.check_invariants
    mix ezagent.socialware.check
    mix test \
      apps/ezagent_core/test/architecture \
      apps/ezagent_core/test/invariants \
      apps/ezagent_domain_external_mirror/test/invariants \
      apps/ezagent_domain_identity/test/invariants \
      apps/ezagent_domain_session/test/invariants
    mix test --include reflow_rehearsal \
      apps/ezagent_domain_identity/test/ezagent/socialware/config_store_seed_upsert_test.exs \
      apps/ezagent_domain_session/test/integration/reflow_rehearsal_test.exs
    ;;
```

> Keep this list byte-identical to the ci.yml `gate` job steps. A drift test (Task 5, optional) can assert the two stay in sync.

- [ ] **Step 3: Run the new gate mode against the container postgres**

```bash
docker compose -p ci-t2 -f docker/docker-compose.ci.yml build
docker compose -p ci-t2 -f docker/docker-compose.ci.yml run --rm ci gate; echo "EXIT=$?"
docker compose -p ci-t2 -f docker/docker-compose.ci.yml down -v
```
Expected: green, `EXIT=0`, noticeably faster than `full-suite` (no full test suite, no pnpm/cc-sdk steps). If `world.e2e.fixtures --check` fails, that is a REAL fixture-drift regression (fix the fixtures, not the gate).

- [ ] **Step 4: Verify `full-suite` mode still runs the honest ci.local**

```bash
docker compose -p ci-t2 -f docker/docker-compose.ci.yml run --rm ci full-suite; echo "EXIT=$?"
```
Expected: runs `mix ci.local` end-to-end; `EXIT=0` on green, `EXIT=1` if any test fails (honest `finalize_ci_local`). Confirm by grepping the tail for `0 failures` AND `EXIT=0` together.

- [ ] **Step 5: Commit**

```bash
git add docker/ci-runner.sh docs/guide/ci-docker-local.md
git commit -m "ci(docker): split gate (lightweight) vs full-suite (ci.local) entrypoints"
```

---

## Task 3: Parameterize compose for safe parallel per-PR runs

**Problem:** Concurrent per-PR jobs must not collide. postgres publishes no host port, so the only shared surfaces are (a) container/network/volume names — solved by a unique compose project name `-p` — and (b) the fixed `image: ezagent-ci-local:latest` tag — a per-PR build must not race another PR's build of the same tag.

**Files:**
- Modify: `docker/docker-compose.ci.yml` (drop the hard-coded `image:` tag OR make it project-scoped; confirm no `ports:`)
- Modify: `docs/guide/ci-docker-local.md` (document `-p` per-run usage + resource caps)

**Interfaces:**
- Produces: a documented invocation `docker compose -p ci-<run_id> -f docker/docker-compose.ci.yml run --rm ci <mode>` that is collision-free across concurrent runs.

- [ ] **Step 1: Confirm postgres has no published host port**

```bash
grep -n 'ports:' docker/docker-compose.ci.yml; echo "(no output = good — internal-only)"
```
Expected: no output. (If a `ports:` mapping exists, remove it — internal `postgres:5432` is all the `ci` service needs.)

- [ ] **Step 2: Make the image tag per-run to avoid concurrent-build races on one tag**

In `docker/docker-compose.ci.yml`, change the `ci` service so its built image is scoped to the compose project (or drop the explicit `image:` so compose names it `<project>-ci`). With the Task 1 two-image split, the shared expensive layers live in `ezagent-ci-base:latest` (built once, read-only reuse), so each project only builds the thin source layer — cheap and race-free:

```yaml
  ci:
    build:
      context: ..
      dockerfile: docker/Dockerfile.ci
      args:
        CI_BASE: ezagent-ci-base:latest
        HTTP_PROXY: "${DOCKER_BUILD_PROXY:-}"
        HTTPS_PROXY: "${DOCKER_BUILD_PROXY:-}"
    # no explicit image: tag → compose names it <project>-ci, unique per -p
```

- [ ] **Step 3: Prove two concurrent projects don't collide**

```bash
docker/build-ci-image.sh   # warm the shared base once
docker compose -p ci-a -f docker/docker-compose.ci.yml run --rm ci gate & \
docker compose -p ci-b -f docker/docker-compose.ci.yml run --rm ci gate & \
wait
docker compose -p ci-a -f docker/docker-compose.ci.yml down -v
docker compose -p ci-b -f docker/docker-compose.ci.yml down -v
```
Expected: both runs go green independently; `docker ps -a` during the run shows `ci-a-postgres-1` + `ci-b-postgres-1` as SEPARATE containers on SEPARATE networks. No "container name already in use" error.

- [ ] **Step 4: Document OrbStack resource ceiling**

Add to `docs/guide/ci-docker-local.md`: OrbStack should be given enough CPU/RAM for N concurrent projects (each `gate` peaks ~2-4 cores + ~2-3 GB; a full-suite ~4 cores + ~4 GB). Recommend capping concurrency at 2-3 given the mac's core count, and setting OrbStack's memory limit in OrbStack settings (or `~/.orbstack/config`) to leave headroom for the dev machine. Note the `cpuset:` in compose still applies per-container (default `0-3`); for real CI (not flake-repro) widen it — see Task 4 Step 3.

- [ ] **Step 5: Commit**

```bash
git add docker/docker-compose.ci.yml docs/guide/ci-docker-local.md
git commit -m "ci(docker): project-scoped compose for safe parallel per-PR runs"
```

---

## Task 4: Rewrite ci.yml `gate` + `full-suite` jobs to dockerized steps

**Problem:** Replace native postgres + native `mix` with docker. Only the `gate` and `full-suite` jobs change; `frontend`, `gitleaks`, `dispatch-canary` are untouched.

**Files:**
- Modify: `.github/workflows/ci.yml` (`gate` job + `full-suite` job only)

**Interfaces:**
- Consumes: `docker/build-ci-image.sh`, `ci-runner.sh` modes `gate`/`full-suite` (Tasks 1-2), project-scoped compose (Task 3).

- [ ] **Step 1: Rewrite the `gate` job body**

Replace ALL native steps (ephemeral native postgres start/stop, `setup`/cache/`deps.get`/`compile`/…/reflow) with docker steps. Keep `runs-on`, `needs: [frontend]`, `name`, and the `on:`/`concurrency:` blocks unchanged.

```yaml
  gate:
    name: gate (deterministic)
    needs: [frontend]
    runs-on: [self-hosted, macOS, ARM64]
    steps:
      - uses: actions/checkout@v4
      - name: Build CI image (base cached on lock change)
        run: docker/build-ci-image.sh
      - name: Run gate in docker
        run: |
          set -euo pipefail
          P="ci-gate-${{ github.run_id }}-${{ github.run_attempt }}"
          trap 'docker compose -p "$P" -f docker/docker-compose.ci.yml down -v || true' EXIT
          docker compose -p "$P" -f docker/docker-compose.ci.yml run --rm ci gate
```

Remove the `env:` postgres/port block (the compose postgres service owns that now).

- [ ] **Step 2: Rewrite the `full-suite` job body**

```yaml
  full-suite:
    name: full-suite (self-hosted macOS)
    needs: [gate]
    if: github.event_name != 'pull_request'
    runs-on: [self-hosted, macOS, ARM64]
    timeout-minutes: 40
    env:
      DEEPSEEK_API_KEY: sk-test-dummy-deepseek-not-a-real-key
      MOONSHOT_API_KEY: sk-test-dummy-moonshot-not-a-real-key
    steps:
      - uses: actions/checkout@v4
      - name: Build CI image (base cached on lock change)
        run: docker/build-ci-image.sh
      - name: Run full-suite (mix ci.local) in docker
        run: |
          set -euo pipefail
          P="ci-full-${{ github.run_id }}-${{ github.run_attempt }}"
          trap 'docker compose -p "$P" -f docker/docker-compose.ci.yml down -v || true' EXIT
          docker compose -p "$P" -f docker/docker-compose.ci.yml run --rm \
            -e DEEPSEEK_API_KEY="$DEEPSEEK_API_KEY" -e MOONSHOT_API_KEY="$MOONSHOT_API_KEY" \
            ci full-suite
```

> The two dummy API keys were env on the native job. `config/test.exs` sets the same fallbacks, so the suite passes without them — but pass them through (compose `-e` or add to the `ci` service `environment:`) to keep parity and avoid orchestrator-materialization surprises. If `docker compose run -e` ordering is finicky, add `DEEPSEEK_API_KEY`/`MOONSHOT_API_KEY` to the `ci` service `environment:` in the compose file with `${VAR:-fallback}` defaults instead.

- [ ] **Step 3: Widen the cpuset for real CI (not flake-repro)**

The compose `cpuset: "${CPUSET:-0-3}"` + `SCHEDULERS: 4` is the flake-repro constraint (deliberately starves cores to surface timing races). For CI you want SPEED + STABILITY, not race pressure. In the ci.yml docker steps, export a wide cpuset:

```yaml
        env:
          CPUSET: "0-9"       # or the runner's core count - 1
          SCHEDULERS: "10"    # keep == cpuset width; pins +S
```
Add this `env:` to both docker `run` steps (or set defaults in compose for CI). Document that `make ci.repro` still overrides these narrow for flake hunting.

- [ ] **Step 4: Validate on a throwaway branch (do NOT merge from this plan)**

Push a no-op branch, open a draft PR, confirm the `gate` job runs green in docker on the self-hosted runner. Then push to a scratch branch that main-merges into a test fork (or use `workflow_dispatch`) to exercise `full-suite`. Confirm `docker ps -a` on the runner shows the per-run project containers created + torn down.

Acceptance: gate job green in docker; full-suite green in docker; `down -v` leaves no lingering `ci-gate-*`/`ci-full-*` containers, networks, or volumes (`docker ps -a`, `docker network ls`, `docker volume ls` clean).

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: run gate + full-suite jobs inside docker (OrbStack) on the self-hosted mac"
```

---

## Task 5: Register 2-3 self-hosted runner processes for concurrent per-PR CI

**Problem:** One runner process handles one job at a time. To run multiple PRs' dockerized jobs concurrently on the one mac, register additional runner processes; the compose `-p` isolation (Task 3) makes their docker jobs safe.

**Files:**
- Create: `docs/guide/ci-parallel-runners.md` (operational runbook — no repo code)

**Interfaces:** none (ops/infra task). Each runner shares the same labels `[self-hosted, macOS, ARM64]`; GitHub dispatches queued jobs to whichever runner is idle.

- [ ] **Step 1: Register N runner instances, each with its own work dir**

For each instance (2-3), from a fresh `actions-runner-N` directory:
```bash
mkdir -p ~/ci-runners/runner-2 && cd ~/ci-runners/runner-2
# download the runner tarball per GitHub's "Add self-hosted runner" page, then:
./config.sh --url https://github.com/ezagent42/ezagent \
  --token <REG_TOKEN> --name mac-ci-2 \
  --labels self-hosted,macOS,ARM64 --work _work --unattended --replace
```
Same labels as the existing runner so any job targeting `[self-hosted, macOS, ARM64]` can land on any instance. Distinct `--name` + distinct directory + distinct `_work` per instance (critical: shared `_work` would corrupt concurrent checkouts).

- [ ] **Step 2: Install each as a LaunchAgent so they survive reboot**

```bash
cd ~/ci-runners/runner-2 && ./svc.sh install && ./svc.sh start
```
Repeat per instance. Verify in the repo's Settings → Actions → Runners that N runners show "Idle".

- [ ] **Step 3: Cap total concurrency to protect the dev machine**

The mac is also the lead's dev box. 2-3 runners × (gate ~2-4 cores | full-suite ~4 cores) can saturate it. Options: register only 2 runners; OR give each docker `run` a modest `CPUSET`/`SCHEDULERS` (Task 4 Step 3) sized so `N × width ≤ cores - 2`. Document the chosen ceiling.

- [ ] **Step 4: Prove concurrency**

Open 2 PRs simultaneously (or re-run two workflows). Confirm both `gate` jobs run at the same time on different runners, each in its own `ci-gate-<run_id>` compose project, both green. `docker ps` shows two independent postgres containers.

- [ ] **Step 5: Commit the runbook**

```bash
git add docs/guide/ci-parallel-runners.md
git commit -m "docs(ci): runbook for parallel self-hosted runners + docker isolation"
```

---

## full-suite-on-PR decision (recommendation)

**Keep the gate-on-PR / full-suite-on-main split — with an opt-in override.** Rationale:

- Dockerization makes full-suite *safe* to run concurrently (isolation) but not *cheap*: it is still ~500-580s of tests + the per-PR thin-image build + a force recompile. Running it on EVERY PR would multiply runner-hours 5-10× and, with only 2-3 runners on a shared dev mac, would starve the fast `gate` feedback loop that reviewers actually wait on.
- The `gate` job is a genuine 100% subset of correctness-critical deterministic checks; full-suite adds the flake-prone concurrent suite. Keeping full-suite off PRs preserves fast, stable PR signal.
- **Opt-in:** add a `full-suite-on-pr` PR label (or a `/full-suite` comment trigger) that flips the `full-suite` job's `if:` to also run when the label is present — so a risky PR can request the full run without making it the default. Implementation: `if: github.event_name != 'pull_request' || contains(github.event.pull_request.labels.*.name, 'full-suite-on-pr')`.
- Re-evaluate once a 3rd runner is stable and full-suite build+run is measured < ~4 min warm: if throughput allows, promote full-suite to all PRs.

---

## Honest-gate compatibility (confirmed)

- `mix ci.local` (`mix.exs` alias) step 1 = `arm_ci_local_result_capture/1` → sets `EZAGENT_CI_LOCAL_SENTINEL` + registers `EzagentCore.CiLocalResult.record_result/1` as an ExUnit `after_suite` callback.
- On test failures, `record_result/1` appends to the sentinel file (survives the `halt` bypass because `after_suite` runs synchronously before shutdown).
- Final step `finalize_ci_local/1` → `System.halt(1)` iff `CiLocalResult.failed?()`, else `halt(0)`.
- `docker/ci-runner.sh` `full-suite` mode execs `mix ci.local`, and `docker compose run --rm` returns the container's exit code, so a RED suite → non-zero → failed CI job. **The honesty is preserved end-to-end in docker.** The lightweight `gate` mode runs discrete `mix` steps (each non-zero-on-failure), so it is honest per-step without needing the `halt` machinery.

## Prod-parity note

`docker/Dockerfile.ci`'s base (`hexpm/elixir:1.19.5-erlang-28.4.2-debian-bookworm-20260518`) matches `docker/Dockerfile.dev`/`.prod` OTP/Elixir pins and the `postgres:16` prod compose targets — so the same linux/debian base doubles as a **deploy-parity reference**: "does the umbrella boot + reach postgres on linux with the pinned OTP" is exactly what `full-suite` exercises. It is NOT a `mix release` artifact (prod ships a release image), so treat it as a runtime-environment parity reference, not the deploy artifact.

## Migration / rollback / risks

- **Rollback:** the ci.yml rewrite (Task 4) is a single-file change. Keep the native-mix job bodies in git history; reverting the commit restores native CI immediately. Tasks 1-3 (docker harness) are additive and don't affect native CI until Task 4 wires them in.
- **OrbStack as a hard CI dependency:** dockerized CI can't run if OrbStack is down. Mitigations: (a) OrbStack LaunchAgent auto-starts at login; (b) add a preflight step `docker version >/dev/null || { echo "OrbStack down"; exit 1; }` with a clear message; (c) the native-mix jobs remain a documented fallback (revert Task 4).
- **Image-build caching:** the Task 1 two-image split is the core mitigation for "don't rebuild deps every run." The `ezagent-ci-base` rebuilds only when `mix.lock`/asset locks change; per-PR builds are the thin source layer (seconds). Warm the base on the runner after any lock bump (a scheduled `docker/build-ci-image.sh` or a `paths: [mix.lock]`-triggered workflow can pre-warm it).
- **Disk usage:** OrbStack already holds ~277 GB images + ~194 GB build cache on this host. Per-PR thin images + tmpfs postgres are small, but base images accumulate one per lockhash. Add a periodic `docker image prune -f --filter 'label=…'` / `docker builder prune` to the runner (weekly cron) and prune old `ezagent-ci-base:<hash>` tags. `down -v` per job (Task 4 trap) prevents volume/container leaks.
- **Teardown:** every docker `run` step wraps `down -v` in a shell `trap … EXIT` so a cancelled/failed job still tears down its project. Verify no lingering `ci-*` projects with `docker compose ls`.
- **tmpfs postgres data loss on OOM:** the compose postgres keeps data in `tmpfs` (RAM). Under many concurrent full-suites this adds RAM pressure; the concurrency cap (Task 5 Step 3) bounds it.

## Out of scope / follow-ups (flag to coordinator)

- **`frontend` job** (`uses: ./.github/workflows/frontend-ci.yml`, commented "Ubuntu-only"): with GitHub-hosted ubuntu billing exhausted, this reusable workflow may already be broken/blocked on `main`. Not part of gate+full-suite; needs a separate decision (dockerize on the mac, or move to a paid runner).
- **`gitleaks` job**: already converted to native `brew install gitleaks` on the mac (no docker). Fine as-is.
- **`dispatch-canary`**: pure curl/jq, no change needed.
```
