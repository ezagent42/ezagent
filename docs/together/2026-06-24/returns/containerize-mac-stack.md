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
  Config mounted read-only from gitignored `docker/secrets-prod/mihomo/config.yaml`
  (the secret JMS subscription URL stays out of git). Committed template
  `docker/mihomo/config.example.yaml` mirrors the host :7896 scheme with the one
  container change `bind-address: '*'`. Agents + cloudflared egress now default to
  `http://mihomo:7896`.
- **Stale SQLite leftovers fixed:** `entrypoint.prod.sh` drops the SQLite
  `DATABASE_PATH`, now fails fast if `DATABASE_URL` is missing, and no longer
  creates a `db/` dir; `Dockerfile.prod` comments corrected (postgrex, no exqlite);
  `prod_home` volume comment no longer claims it holds the DB.
- **Docs:** `docker/README.md` gains a "Prod stack — fully containerized" section;
  `docker/.env.example` added.

## DoD artifact

- **Static validation (green):** `docker compose -f docker/docker-compose.prod.yml
  config` renders all 4 services with correct wiring — `DATABASE_URL` →
  `postgres:5432`, `HTTPS_PROXY: http://mihomo:7896` on both `ezagent` and
  `cloudflared`, `depends_on` conditions `postgres: service_healthy` +
  `mihomo: service_started`. `bash -n docker/entrypoint.prod.sh` clean.

## Gate status

`docker/`-only; no `mix` gates apply. Static compose + bash validation green.

## Remaining gate (NOT done here — needs a secret + must avoid the prod tunnel)

The **runtime E2E** (build → `up postgres mihomo ezagent` → migrate → app health →
one agent provider round-trip through the mihomo container) is **not run** because
it needs (a) the real **JMS subscription URL** (a secret not in this repo) and
(b) a ~10-min Elixir release build, and it must **not** bring up the prod
cloudflared tunnel (would touch `app.ezagent.chat`, #65 boundary). The exact safe
command sequence is in the handoff DoD §2 (bring up the 3-service subset by name,
cloudflared excluded). Recommend Allen runs it on the Mac (has the JMS secret).

## Merge request

- **Merge** `feat/containerize-mac-stack-pg-mihomo` → `main` after the runtime
  gate passes on the Mac (or merge now as docs/compose-only if you'll run the
  gate at deploy time — your call).
- Files (all under `docker/` + `docs/together/`): `docker-compose.prod.yml`,
  `entrypoint.prod.sh`, `Dockerfile.prod`, `mihomo/config.example.yaml`,
  `.env.example`, `README.md`, this return + handoff. Additive / low conflict risk.
- Operator setup before first `up`: create `docker/.env` (POSTGRES_PASSWORD) and
  `docker/secrets-prod/mihomo/config.yaml` (JMS URL) per `docker/README.md`.
