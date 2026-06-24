# Handoff — Fully containerize the stay-on-Mac deployment (PG + mihomo proxy)

> **Task:** containerize-mac-stack
> **Owner/dev:** Claude (agent) · **Lead:** Allen
> **Branch:** `feat/containerize-mac-stack-pg-mihomo` (off `main`)
> **Required reading:** `docs/notes/2026-06-24-cf-container-deploy-cost-analysis.md` §8.5
> (the containerization completeness audit that motivated this task);
> `docker/README.md`; `docker/Dockerfile.prod`; `config/runtime.exs`.

## Why

§8.5 audit found the stay-on-Mac stack is ~80% containerized but **NOT complete
for the post-PG world**: `docker-compose.prod.yml` predates the SQLite→PG
migration — it has no `postgres` service and sets no `DATABASE_URL`, while
`config/runtime.exs` (prod) now **raises** without it. So `up` would crash on
boot. Allen also asked to **containerize the proxy** (currently a host mihomo on
:7896) referencing that existing mihomo scheme.

## Scope (owned surfaces — no overlap with app code)

Only `docker/` + `docs/together/`. No `apps/**`, no `config/**` (runtime.exs
already expects PG — correct as-is).

## Definition of done (demonstrable)

1. **Static (done):** `docker compose -f docker/docker-compose.prod.yml config`
   renders with all 4 services (`postgres`, `mihomo`, `ezagent`, `cloudflared`),
   `DATABASE_URL` → `postgres`, agents+cloudflared egress → `mihomo:7896`,
   `ezagent depends_on postgres(healthy)+mihomo(started)`.
2. **Runtime (gate — needs the JMS secret; DO NOT bring up the prod tunnel):**
   ```bash
   cp docker/.env.example docker/.env            # set POSTGRES_PASSWORD + JMS_SUBSCRIPTION_URL
   #   (mihomo renders config.template.yaml from JMS_SUBSCRIPTION_URL — no secret file)
   #   Docker Desktop must pull via the host proxy (Settings→Resources→Proxies→http://127.0.0.1:7897)
   export DOCKER_BUILD_PROXY=http://host.docker.internal:7897   # host proxy for build
   docker compose --env-file docker/.env -f docker/docker-compose.prod.yml build
   # bring up ONLY the safe subset (NO cloudflared → does not touch app.ezagent.chat):
   docker compose --env-file docker/.env -f docker/docker-compose.prod.yml up -d postgres mihomo ezagent
   docker compose -f docker/docker-compose.prod.yml logs ezagent   # expect: migrating (Postgres via DATABASE_URL) → started
   curl -fsS http://localhost:10043/                               # app healthy
   # prove agent egress through the mihomo container (spawn a cc/codex agent, watch a provider call succeed)
   ```
   DoD artifact = that log + curl + one agent provider round-trip.

## Design decisions

- **One shared Postgres** (`postgres:15`, internal-only, `prod_pg` named volume,
  `pg_isready` healthcheck). DB password via `docker/.env` (compose
  interpolation) → both the postgres service and `DATABASE_URL`.
- **mihomo containerized** (`metacubex/mihomo`), config mounted read-only from
  gitignored `docker/secrets-prod/mihomo/config.yaml` (holds the secret JMS
  subscription URL). Two container-specific changes vs the host scheme:
  `mixed-port: 7897` (match the external Mac proxy port) and `bind-address: '*'`
  so the compose network can reach it. **NO `ports:` mapping → 7897 is
  cluster-internal only** (not reachable from host/LAN). `GEOIP,CN,DIRECT` rule so
  only foreign traffic uses JMS. Committed template: `docker/mihomo/config.example.yaml`.
- **Egress scope (refined):** the proxy is set **only on the `ezagent` service**
  (`ESR_PROXY` default `http://mihomo:7897`) so the spawned claude/codex
  subprocesses reach Anthropic/OpenAI. **cloudflared connects to the CF edge
  directly** (no proxy), and the BEAM core's own traffic stays direct
  (Feishu/Postgres + Elixir HTTP clients ignore the env). Build-time uses the HOST
  proxy (`:7897`) since the mihomo container doesn't exist yet at build.
- **Safe verification:** bring up `postgres mihomo ezagent` by name; cloudflared
  is left out so testing never exposes the real prod tunnel (#65 boundary).

## Discuss-first / caveats

- mihomo healthcheck uses `nc -z 127.0.0.1 7896`; if the metacubex image lacks
  `nc`, switch to a TCP check the image supports (or `service_started` only).
- Optional follow-up (not in scope): containerize a `pg_dump` backup sidecar /
  cron (the D1 leg of the §5 backup design).
