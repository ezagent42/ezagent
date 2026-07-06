# ezagent dev/test docker environment (#21)

A blank, isolated ezagent for deterministic E2E (see
`docs/superpowers/specs/2026-06-04-dockerized-e2e-harness-design.md`). Dev only
(`mix phx.server`); the prod `mix release` image is a later phase.

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

## Prod stack — fully containerized (ezagent + postgres + mihomo + cloudflared)

`docker-compose.prod.yml` runs the whole Mac deployment in containers: the
`mix release` app, **Postgres** (the DB, post SQLite→PG migration), a
**containerized mihomo** egress proxy (replaces the host clash/mihomo), and
**cloudflared** fronting `app.ezagent.chat`. The only host dependency is Docker
+ the gitignored secrets.

> Proxy scope: mihomo (`mixed-port 7897`, cluster-internal — no host port) is
> used **only by the agent (claude/codex) subprocesses** to reach
> Anthropic/OpenAI past the GFW. It is configured **only on the `ezagent`
> service** (the agents inherit its env). cloudflared connects to the CF edge
> **directly**, and ezagent's own traffic (Feishu/Postgres) goes direct too.

```bash
# 1. compose secrets in docker/.env (Postgres password + JMS subscription URL)
cp docker/.env.example docker/.env
#   set POSTGRES_PASSWORD=$(openssl rand -hex 24)
#   set JMS_SUBSCRIPTION_URL=<your JMS subscription URL>
#   (mihomo renders docker/mihomo/config.template.yaml from JMS_SUBSCRIPTION_URL
#    at container start — no separate proxy config file to manage.)

# 2. app cookie env_file (docker/secrets-prod/ezagent.env) + the prod tunnel
#    credential (~/.cloudflared/8e249ea0-...json) must exist (as before).

# 3. build — runtime agent egress uses the mihomo SERVICE, but the BUILD runs
#    before that container exists, so point build-time fetches at the HOST proxy (:7897):
export DOCKER_BUILD_PROXY=http://host.docker.internal:7897
docker compose --env-file docker/.env -f docker/docker-compose.prod.yml build

# 4. run (mihomo + postgres come up first; ezagent waits for PG healthy)
docker compose --env-file docker/.env -f docker/docker-compose.prod.yml up -d
```

> Docker Desktop must pull images through your host proxy (Docker Hub is GFW'd):
> Settings → Resources → Proxies → Manual → `http://127.0.0.1:7897` (verified
> working on this host).

> DB durability: Postgres data lives in the `prod_pg` named volume. Back it up
> with `pg_dump` on a schedule (the D1 leg of the §5 backup design in
> `docs/notes/2026-06-24-cf-container-deploy-cost-analysis.md`).

## Auth email — `smtp_config.json` (magic-link / confirm / password-reset)

Outbound auth email is delivered by the compile-pinned Swoosh adapter. In prod
(`config/config.exs`) that adapter is `Ezagent.Mail.EzagentChatAdapter`, which
POSTs to the `email.ezagent.chat` REST API (Cloudflare Email Sending — REST
only, **not** an SMTP relay). The transport config lives in the `smtp_config`
app-setting; the entrypoint seeds it from a read-only secrets mount on first
boot (`entrypoint.prod.sh` copies `/secrets/smtp_config.json` →
`<profile>/credentials/smtp_config.json`, then the app auto-seeds it into
`AppSettings` — idempotent, gated on `AppSettings.mail_configured?/0`).

Drop the **REST-shaped** `smtp_config.json` into the secrets mount:

```json
{
  "from_address": "auth@ezagent.chat",
  "base_url": "https://email.ezagent.chat",
  "api_key": "emk_..."
}
```

- `from_address` — a mailbox the `api_key` owns (sent as `address` on
  `POST /api/send`; the service 403s otherwise). Also the visible `From:`.
- `base_url` — the mail service origin (no trailing `/api`).
- `api_key` — a mailbox key (`emk_…`) minted for that mailbox (see the
  mail-server runbook: `POST /api/mailboxes`).

Readiness (`AppSettings.mail_api_configured?/0`) requires non-empty `base_url` +
`api_key`. The legacy SMTP shape
(`{"host","port","username","password","from_address","tls"}`) is still accepted
by the SMTP adapter — `smtp_config` is the single mail-config slot for either
transport.
