# Contributing to ezagent

## Operational guides — `docs/guide/`

Durable how-to guides for common operational tasks. (Point-in-time *design* records
live in `docs/superpowers/specs/`; per-scenario runbooks in `docs/runbook/`; this
section is the discoverable home for reusable operating procedures.)

| guide | what |
|-------|------|
| [Dockerized E2E (disposable stack)](docs/guide/dockerized-e2e.md) | spin a clean isolated docker stack + run E2E (never hand-patch dev/prod) |
| [Local ubuntu-CI harness](docs/guide/ci-docker-local.md) | `make ci.docker` — run the **ubuntu CI env locally** to reproduce the ubuntu-only timing flakes (macOS can't) + a deploy-parity smoke |
| [World plugin E2E seed + dev server](docs/guide/world-e2e-seed.md) | seed a session with joined members on an isolated home, then visually verify the world conversation surface with agent-browser |

> Add new operational how-tos under `docs/guide/<topic>.md` and index them here.

## Architecture references

- [`docs/architecture/`](docs/architecture/) — durable architecture (communication overview, protocol addressing & envelopes, …).
- [`docs/scenarios/`](docs/scenarios/) — the master E2E scenario catalog.

## Gates every PR must pass

Run from the umbrella root (force-compile first — a stale `.beam` lies):

```bash
mix compile --force
mix ezagent.arch.scan
mix ezagent.check_invariants && mix ezagent.check_invariants.lifecycle
mix ezagent.doc.scan          # documentation-coverage ratchet
mix test                      # full umbrella suite
```

### Pre-push: `mix ci.local` (mirror CI exactly)

Before pushing, run the **same** `precommit + check_invariants` job CI runs —
end-to-end against your **own** partitioned DB — with one command:

```bash
MIX_ENV=test MIX_TEST_PARTITION=$USER mix ci.local
```

This runs `deps.get` → `pnpm install` (web/world/hello assets, so esbuild can
resolve react/zod during compile) → `ecto.create`/`ecto.migrate` →
`mix precommit` → `mix ezagent.check_invariants`, all against the private DB
`ezagent_pg_compat_test$USER`. It NEVER touches the shared dev DB, and two devs
can run it concurrently.

Why a dedicated alias and not `cd apps/<one> && mix test`: a single-app run
silently excludes the `:umbrella_only` cross-tier suites and runs at a quieter
concurrency than CI's full umbrella, so it can pass on a branch that goes red on
CI. `mix ci.local` is the catch-net that makes admin-merge-after-flake (P5) a
conscious, verified choice rather than a blind push. (It is a catch-net, not a
cure: the recurring CI flake is a timing race — green on macOS, red on the
ubuntu runner — so a green local run does not *guarantee* green CI; see
`docs/together/2026-06-27/notes/ci-flake-diagnosis.md`.)

**To actually reproduce (not just gate) the ubuntu-only flake on a Mac**, use the
**local ubuntu-CI docker harness** — `make ci.docker` runs the *same* CI chain in a
CPU-constrained linux container, and `make ci.repro` hunts the timing race that
`mix ci.local` is green on. See [`docs/guide/ci-docker-local.md`](docs/guide/ci-docker-local.md).

### Debugging process-spawning code (erlexec / PTY / sidecars)

If you're iterating on code that forks or spawns OS processes — erlexec,
PTY servers, cc/codex/python sidecars — and want a safety net against a
runaway process tree taking down the box (see the 2026-07-21 incident:
[`docs/notes/2026-07-21-git-provider-system-closure-retrospective.md`](docs/notes/2026-07-21-git-provider-system-closure-retrospective.md)),
run the invocation through `scripts/guarded_mix.sh` instead of bare `mix` —
it bounds the whole process tree in a memory-capped cgroup and kills it
cleanly on breach instead of the runaway starving the host. See
[`docs/runbook/guarded-mix-execution.md`](docs/runbook/guarded-mix-execution.md).
This is a targeted tool for that specific risk, not a routine replacement
for `mix test` / `mix ci.local`.
