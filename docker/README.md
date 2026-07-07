# ezagent dev/test docker environment (#21)

A blank, isolated ezagent for deterministic E2E (see
`docs/superpowers/specs/2026-06-04-dockerized-e2e-harness-design.md`). Dev only
(`mix phx.server`).

## Secrets layout (`docker/secrets/`, git-ignored — never commit)

| file | purpose |
|------|---------|
| `feishu.yaml` | Feishu app creds (copy of `~/.ezagent/<profile>/credentials/feishu.yaml`) |
| `cc/.credentials.json` | claude OAuth seed (the test login, e.g. `~/.claude/.credentials.json`) |
| `codex/auth.json`, `codex/config.toml` | codex CODEX_HOME seed |
| `deepseek.key` | curl agent's deepseek API key (single line) |

The container seeds `feishu.yaml` on first boot; cc/codex OAuth seeds populate the
durable per-flavor source volumes on first provision; the deepseek key is injected
via `put_api_key` during scenario seeding.

## Build + run (host is behind a proxy)

```bash
# host clash listens on 127.0.0.1:7897 → reachable from the container as host.docker.internal:7897
export DOCKER_BUILD_PROXY=http://host.docker.internal:7897
export ESR_PROXY=http://host.docker.internal:7897

docker compose -f docker/docker-compose.dev.yml build
docker compose -f docker/docker-compose.dev.yml up -d
docker compose -f docker/docker-compose.dev.yml logs -f ezagent   # watch WSS connect
```

Reachable at `http://100.64.0.27:10042` (Tailscale — `feedback_remote_browser_ip`).

> Proxy note: the host proxy must accept connections from the Docker VM
> (`host.docker.internal`). If clash binds `127.0.0.1` only, enable "Allow LAN" (or
> set Docker Desktop → Settings → Resources → Proxies to the system proxy) so the
> build/runtime can reach Anthropic/OpenAI/hex. Feishu + localhost go direct.

## E2E / CI compose files

- `docker-compose.dev.yml` — the dev/dogfood stack (above).
- `docker-compose.disp.yml` — disposable, isolated stack for one-shot E2E runs.
- `docker-compose.ci.yml` + `Dockerfile.ci` + `ci-runner.sh` — the local
  ubuntu-CI harness (`make ci.docker` / `make ci.gate`) that reproduces the
  ubuntu-only CI races macOS cannot (see `docs/guide/ci-docker-local.md`).

---

Deployment lives in a separate private repo.
