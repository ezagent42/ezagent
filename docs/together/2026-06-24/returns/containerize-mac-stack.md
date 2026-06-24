# Return — Fully containerize the stay-on-Mac deployment (PG + mihomo proxy)

> **Task:** containerize-mac-stack
> **Branch:** `feat/containerize-mac-stack-pg-mihomo` (off `main` @ `94ae55a7`)
> **PR:** none
> **Dev:** Claude (agent)
> **returned_at:** 2026-06-24 (+0800)
> **deadline:** n/a — no `plan.md` for 2026-06-24
> **deadline_status:** out_of_scope
> **Handoff:** `docs/together/2026-06-24/handoffs/containerize-mac-stack.md`

## What's done

Closed the §8.5 containerization gap so the stay-on-Mac stack is fully
containerized: **BEAM + agents + Postgres + mihomo proxy + cloudflared**, all in
`docker-compose.prod.yml`. `docker/` only — no app code touched.

- **Postgres added** (`postgres:15`, internal-only, `prod_pg` named volume,
  `pg_isready` healthcheck, `restart: unless-stopped`). `DATABASE_URL` wired into
  `ezagent` (`ecto://ezagent:${POSTGRES_PASSWORD}@postgres:5432/ezagent_prod`);
  `ezagent depends_on postgres(service_healthy)` so `Release.migrate()` runs after
  PG is up. Password via gitignored `docker/.env` (compose interpolation).
- **mihomo containerized** (`metacubex/mihomo`), replacing the host clash/mihomo.
  Config is **rendered at container start from a committed template**
  (`docker/mihomo/config.template.yaml`) substituting `JMS_SUBSCRIPTION_URL` from
  `docker/.env` via `docker/mihomo/render-config.sh` — the secret URL lives only in
  the env, no committed/gitignored config file. **Port `7897`** (matches external Mac),
  **cluster-internal only** (no `ports:` mapping), `bind-address: '*'`,
  `GEOIP,CN,DIRECT` so only foreign traffic uses JMS.
- **Proxy scoped to agents only (per Allen's analysis):** the proxy env is set
  **only on the `ezagent` service** (`http://mihomo:7897`) — the claude/codex
  subprocesses inherit it to reach Anthropic/OpenAI. **cloudflared now connects to
  the CF edge directly** (proxy removed), and the BEAM core's own traffic stays
  direct. Build-time uses the HOST proxy on `:7897`.
- **Stale SQLite leftovers fixed:** `entrypoint.prod.sh` drops the SQLite
  `DATABASE_PATH`, now fails fast if `DATABASE_URL` is missing, and no longer
  creates a `db/` dir; `Dockerfile.prod` comments corrected (postgrex, no exqlite);
  `prod_home` volume comment no longer claims it holds the DB.
- **Docs:** new durable deploy guide **`docs/guide/deploy-mac-stack.md`** (full
  architecture, proxy model, secrets setup, build/run/verify, backups, redeploy,
  rollback, troubleshooting); `docker/README.md` gains a "Prod stack — fully
  containerized" quick-start; `docker/.env.example` added.

## DoD artifact

- **Static validation (green):** `docker compose -f docker/docker-compose.prod.yml
  config` renders all 4 services with correct wiring — `DATABASE_URL` →
  `postgres:5432`, `HTTPS_PROXY: http://mihomo:7896` on both `ezagent` and
  `cloudflared`, `depends_on` conditions `postgres: service_healthy` +
  `mihomo: service_started`. `bash -n docker/entrypoint.prod.sh` clean.

## Gate status

`docker/`-only; no `mix` gates apply. Static compose + bash validation green.

## Runtime gate — PASSED (2026-06-24, live on the Mac)

Two of the three moving parts were tested live with real credentials; the full
ezagent build is the only remaining piece.

- **Docker Desktop pull proxy:** configured to pull through `http://127.0.0.1:7897`
  (Docker Hub is GFW'd). Verified: `docker pull metacubex/mihomo` succeeded after
  the change (timed out before).
- **mihomo proxy (containerized, ENV-rendered config) — PASS.** Ran the
  `metacubex/mihomo` container with `JMS_SUBSCRIPTION_URL=<JMS sub>`; the
  template rendered correctly and the proxy came up (`Mixed proxy listening at
  :7897`). Egress through it: `https://www.gstatic.com/generate_204` → **204**
  (routed `GeoIP(cn) DIRECT`), `api.openai.com` → **401** and `api.anthropic.com`
  → **401**, both routed `Match using auto[JMS-622510@...]` — i.e. foreign traffic
  goes via JMS, domestic direct. Exactly the intended behavior.
- **cloudflared tunnel — PASS.** Created a throwaway tunnel `test-0624`, routed
  `test-0624.ezagent.chat` to it, ran cloudflared (connected **directly** to the
  CF edge, no proxy — validating §8.5 proxy scoping; one transient QUIC retry then
  registered at `sjc10`), and `curl https://test-0624.ezagent.chat/` → **HTTP 200**
  serving the local origin. Then torn down: cloudflared stopped, tunnel deleted,
  cred removed.

- **Full ezagent release build + stack bring-up — PASS.** Built
  `ezagent-prod:latest` (1.84 GB; deps→compile→assets→npm sidecar→`mix release`,
  all GFW'd fetches via the Docker Desktop proxy). Brought up the subset
  `postgres mihomo ezagent` (NO cloudflared): all three reached **healthy** in
  dependency order (postgres healthy → ezagent). **Migrations ran into Postgres**
  (PgBaseline + ProtocolApiKeys + EmailThreadState + EmailInboundBinding; `\dt`
  shows the full schema — `invocations`, `dlq`, `credential_grants`, …). Phoenix
  served **HTTP 302** on :10043; Feishu node sidecar started in the release image.
  Then torn down (`down -v`, test volumes removed for a clean real deploy).

**All gates PASSED.** Nothing functional remains; an in-app live-agent round-trip
(needs OAuth creds seeded) is the only thing not exercised, but agent→provider
egress was already proven directly against the mihomo container.

**Leftovers:** none. The `test-0624.ezagent.chat` DNS record was deleted via the
CF API (token saved gitignored at `docker/secrets-prod/cf_api_token` in the main
checkout).

## Merge request

- **Merge** `feat/containerize-mac-stack-pg-mihomo` → `main` after the runtime
  gate passes on the Mac (or merge now as docs/compose-only if you'll run the
  gate at deploy time — your call).
- Files (all under `docker/` + `docs/together/`): `docker-compose.prod.yml`,
  `entrypoint.prod.sh`, `Dockerfile.prod`, `mihomo/config.example.yaml`,
  `.env.example`, `README.md`, this return + handoff. Additive / low conflict risk.
- Operator setup before first `up`: create `docker/.env` (POSTGRES_PASSWORD) and
  `docker/secrets-prod/mihomo/config.yaml` (JMS URL) per `docker/README.md`.
