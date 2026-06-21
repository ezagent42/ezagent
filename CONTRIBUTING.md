# Contributing to ezagent

## Operational guides — `docs/guide/`

Durable how-to guides for common operational tasks. (Point-in-time *design* records
live in `docs/superpowers/specs/`; per-scenario runbooks in `docs/runbook/`; this
section is the discoverable home for reusable operating procedures.)

| guide | what |
|-------|------|
| [Dockerized E2E (disposable stack)](docs/guide/dockerized-e2e.md) | spin a clean isolated docker stack + run E2E (never hand-patch dev/prod) |
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
