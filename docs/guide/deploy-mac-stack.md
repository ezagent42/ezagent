# Deploy: the fully-containerized Mac stack (prod)

How to deploy ezagent on a Mac as a self-contained Docker stack:
**ezagent (BEAM + agents) + Postgres + mihomo (egress proxy) + cloudflared
(tunnel)**. This is the current alpha production deployment — see
`docs/notes/2026-06-24-cf-container-deploy-cost-analysis.md` §8.5 for *why* Mac +
cloudflared tunnel is the right alpha target (it sidesteps the CF Containers
4-vCPU/team ceiling at $0 per-team cloud compute).

> Operational how-to lives here in `docs/guide/`; the compose/Dockerfiles live in
> `docker/` (with a short quick-start in `docker/README.md`). This guide is the
> durable, full version.

---

## 1. Architecture

```
                         ┌──────────────── Docker (compose project: ezagent-prod) ────────────────┐
   app.ezagent.chat ──▶ │  cloudflared ──▶ ezagent:10042 (BEAM)                                    │
   (CF tunnel 8e249ea0) │     │ (direct to     │  ├─ claude/codex agents (subprocesses, erlexec)   │
                         │     │  CF edge,      │  │     └─ HTTPS_PROXY=http://mihomo:7897 ──┐       │
   host :10043 ◀────────┼─────┘  no proxy)     │  │                                         ▼       │
   (Tailscale admin)    │                      │  └─ Repo ──▶ postgres:5432               mihomo    │
                         │                      │                  (prod_pg vol)         :7897       │
                         │                      └─ profile data ──▶ prod_home vol      (JMS proxy,   │
                         │                                                              internal)    │
                         └───────────────────────────────────────────────────────────────────────┘
```

Four services, one host dependency (Docker + secrets):

| Service | Image | Role | Host port | Persists in |
|---|---|---|---|---|
| `ezagent` | built `ezagent-prod:latest` | BEAM app + claude/codex/uv/node baked in | `10043→10042` (Tailscale/admin) | `prod_home` |
| `postgres` | `postgres:15` | the DB (Repo) | none (internal) | `prod_pg` |
| `mihomo` | `metacubex/mihomo` | egress proxy for agents | none (internal) | — (config mount) |
| `cloudflared` | `cloudflare/cloudflared` | tunnel → `app.ezagent.chat` | none | — (creds mount) |

### Proxy model (important)

The mihomo proxy exists for **one reason**: the agent (claude/codex) subprocesses
must reach `api.anthropic.com` / `api.openai.com` past the GFW. Therefore:

- The proxy env (`HTTP(S)_PROXY=http://mihomo:7897`) is set **only on the
  `ezagent` service**; the spawned agents inherit it.
- **cloudflared connects to the Cloudflare edge directly** — no proxy.
- The **BEAM core's own traffic is direct**: Feishu/Lark is China-accessible
  (in `NO_PROXY`), Postgres is internal, and Elixir HTTP clients don't auto-honor
  `HTTP_PROXY` env anyway.
- mihomo's own rules send `GEOIP,CN,DIRECT` and only foreign traffic via JMS.
- mihomo listens on **7897** (matching the external Mac proxy port) and is
  **cluster-internal only** — there is no `ports:` mapping, so 7897 is reachable
  from sibling containers but never from the host or LAN.

---

## 2. Prerequisites

- Docker Desktop for Mac (running), configured to **pull images through the host
  proxy** (Docker Hub is GFW'd): Settings → Resources → Proxies → Manual →
  `http://127.0.0.1:7897` (equivalently set in
  `~/Library/Group Containers/group.com.docker/settings-store.json` as
  `ProxyHTTPMode: manual` + `OverrideProxyHTTP/HTTPS`, then restart Docker).
  Verified working on this host (2026-06-24).
- A host proxy reachable at `host.docker.internal:7897` **for the build only**
  (hex/npm/CLI fetches go through the GFW). The runtime agent egress uses the
  containerized mihomo, not this.
- The Cloudflare prod tunnel credential on the host:
  `~/.cloudflared/8e249ea0-1285-4a86-81fc-eb3733a16cf4.json`.
- The JMS subscription URL (for mihomo).

---

## 3. One-time secrets setup

All secrets are gitignored. Create them once:

```bash
# (a) docker/.env — Postgres password + mihomo JMS subscription URL (compose vars)
cp docker/.env.example docker/.env
#   POSTGRES_PASSWORD=$(openssl rand -hex 24)
#   JMS_SUBSCRIPTION_URL=<your JMS subscription URL>
#   mihomo renders docker/mihomo/config.template.yaml from JMS_SUBSCRIPTION_URL at
#   container start (pure-shell render via docker/mihomo/render-config.sh) — the
#   secret URL lives ONLY in docker/.env, never in a committed file.

# (b) app distribution cookie (random per host) — env_file
#   docker/secrets-prod/ezagent.env must contain EZAGENT_COOKIE + RELEASE_COOKIE
#   e.g.:  printf 'EZAGENT_COOKIE=%s\nRELEASE_COOKIE=%s\n' "$(openssl rand -hex 24)" "$(openssl rand -hex 24)" > docker/secrets-prod/ezagent.env
#   (RELEASE_COOKIE must equal EZAGENT_COOKIE)

# (c) static prod credentials seeded on first boot (as before):
#   docker/secrets-prod/feishu.yaml  (and optionally smtp_config.json)
```

`SECRET_KEY_BASE` is auto-generated and persisted in the `prod_home` volume on
first boot if you don't supply one.

---

## 4. Build

The build runs before the mihomo container exists, so point build-time fetches at
the **host** proxy on 7897:

```bash
export DOCKER_BUILD_PROXY=http://host.docker.internal:7897
docker compose --env-file docker/.env -f docker/docker-compose.prod.yml build
```

This compiles the `mix release` and bakes in the agent CLIs
(`@anthropic-ai/claude-code`, `@openai/codex`, `uv`, node, git). Expect ~10 min.

---

## 5. Run

```bash
docker compose --env-file docker/.env -f docker/docker-compose.prod.yml up -d
```

Startup order is enforced: `postgres` (waits healthy) and `mihomo` come up first,
then `ezagent` (runs `EzagentCore.Release.migrate()` against Postgres), then
`cloudflared`.

Watch it:

```bash
docker compose -f docker/docker-compose.prod.yml logs -f ezagent
#   expect: "[entrypoint.prod] migrating (Postgres via DATABASE_URL)" → "starting release"
docker compose -f docker/docker-compose.prod.yml ps   # all healthy
```

---

## 6. Verify

**Safe verification (no tunnel — does NOT touch app.ezagent.chat).** Bring up only
the 3-service subset:

```bash
docker compose --env-file docker/.env -f docker/docker-compose.prod.yml up -d postgres mihomo ezagent
curl -fsS http://localhost:10043/                 # app responds
docker compose -f docker/docker-compose.prod.yml exec postgres pg_isready -U ezagent -d ezagent_prod
# agent egress: spawn a cc/codex agent and confirm a provider call succeeds
# (proves claude/codex → mihomo:7897 → Anthropic/OpenAI works)
```

Full prod adds the tunnel: re-run step 5 without the subset; then hit
`https://app.ezagent.chat`.

---

## 7. Backups (DB durability)

Postgres data lives in the `prod_pg` named volume. Back it up regularly — this is
the D1 leg of the backup design in
`docs/notes/2026-06-24-cf-container-deploy-cost-analysis.md` §5.

```bash
# logical dump (run from anywhere with the stack up)
docker compose -f docker/docker-compose.prod.yml exec -T postgres \
  pg_dump -U ezagent -d ezagent_prod | gzip > "ezagent_prod_$(date +%F).sql.gz"

# restore (into a fresh/empty DB)
gunzip -c ezagent_prod_YYYY-MM-DD.sql.gz | \
  docker compose -f docker/docker-compose.prod.yml exec -T postgres psql -U ezagent -d ezagent_prod
```

The agent working dirs + credentials live in `prod_home`; back that volume up too
if agents hold un-pushed work (D2 leg, §5).

---

## 8. Redeploy / upgrade

```bash
git pull
export DOCKER_BUILD_PROXY=http://host.docker.internal:7897
docker compose --env-file docker/.env -f docker/docker-compose.prod.yml build
docker compose --env-file docker/.env -f docker/docker-compose.prod.yml up -d
```

`prod_home` + `prod_pg` survive redeploys (only `down -v` deletes them).
Migrations run automatically on each boot via the entrypoint.

---

## 9. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `FATAL: DATABASE_URL is not set` on boot | `docker/.env` missing `POSTGRES_PASSWORD`, or you didn't pass `--env-file docker/.env`. |
| ezagent exits before postgres ready | shouldn't happen (`depends_on: postgres service_healthy`); check `postgres` logs / `pg_isready`. |
| agents can't reach Anthropic/OpenAI | bad/empty `JMS_SUBSCRIPTION_URL` in `docker/.env`. Check `docker compose logs mihomo` for the provider fetch + a routing line like `api.openai.com ... using auto[JMS-...]`. |
| `docker pull` / build times out on Docker Hub | Docker Desktop proxy not set — point it at `http://127.0.0.1:7897` (see §2). |
| build fails fetching hex/npm | host proxy on 7897 not reachable from the Docker VM — enable "Allow LAN" on the host proxy / set Docker Desktop proxies. |
| tunnel down / app.ezagent.chat unreachable | cloudflared goes direct by default; if this network can't reach the CF edge directly, add `HTTPS_PROXY=http://mihomo:7897` back on the `cloudflared` service (see the comment in the compose file). |
| WS 403 on the Tailscale admin port | add the origin to `EZAGENT_EXTRA_CHECK_ORIGINS`. |

---

## 10. When to move off this (Mac) deployment

Not a date — specific signals (see §8.5 of the cost analysis): need for SLA/HA,
per-team elastic scale/isolation, a saturated box, or the host leaving your
control. Then evaluate CF Containers (fits standard-4) vs AWS (needs a bigger box
or native volumes) per §8.4 of that note.
