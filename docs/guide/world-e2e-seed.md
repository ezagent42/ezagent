# World plugin — PostgreSQL E2E seed + dev server recipe

A reusable recipe for standing up `ezagent_plugin_world` on the **PostgreSQL**
substrate and seeding known data, so the conversation surface (members panel,
@mention autocomplete, composer), agent/session flows, and the shared world E2E
have real data to render and dispatch against.

> **2026-06-23 (task `world-deploy-e2e-pg`): rewritten for PostgreSQL.** The
> previous version assumed the SQLite era (the "two-BEAM SQLite trap", an
> isolated `EZAGENT_HOME` SQLite file, ports 4020/5175). `main` is now
> **PostgreSQL-only** (the `pg-compat-audit` migration). PG handles concurrent
> connections, so the old single-file corruption hazard is gone — but the
> single-node *seed-then-start* pattern is still recommended (so the server
> cold-loads the seeded snapshots cleanly). Default dev ports are now **10042
> (phx) / 5173 (vite)**.

## 0. Facts you need (verified 2026-06-23 on `main`)

| Thing | Value |
|---|---|
| Phoenix HTTP | `0.0.0.0:10042` (override with `PORT`) |
| World Vite dev server | `5173` (override with `WORLD_VITE_PORT`) |
| **World operator UI** | host-routed on `world.` → **`http://world.localhost:10042`** (login-gated) |
| Login / register / auth | host-agnostic → `http://localhost:10042/login`, `/register` |
| **Public hello/customer page** | `http://localhost:10042/socialware/customer?session_uri=<enc>` (no login for `public_view` sessions) |
| Health probe | `GET /_health` → 200 |
| Backend action catalog | `GET /api/v1` (JSON; 106 `{kind, action}` routes) |
| Seeded admin login | `admin@ezagent.chat` / `worlddev` (after step 3) |

**HSTS gotcha (learned 2026-06-22):** do NOT use `world.ezagent.chat` — it
HSTS-upgrades to HTTPS and renders blank on a plain `:10042`. Use
**`world.localhost`** — `*.localhost` auto-resolves to `127.0.0.1` and is never
HSTS-upgraded. It matches the Phoenix `host: "world."` prefix.

## 1. Bring up PostgreSQL

The Repo (`config/dev.exs` → `EzagentCore.Repo`) reads `POSTGRES_*` env, defaulting
to the docker-compose values (`127.0.0.1:55432`, user/pass/db `ezagent_pg_compat`).

**Option A — canonical disposable PG (Docker):**

```bash
docker compose -f docker-compose.pg.yml up -d   # postgres:15 on 127.0.0.1:55432
# defaults already match config/dev.exs — no POSTGRES_* override needed
```

**Option B — an existing/host PostgreSQL (e.g. mirrored-networking WSL where PG
runs on the Windows host at `127.0.0.1:5432`):** point the Repo at it with env.
Export these in every shell that runs `mix` (or use `bin/dev-pg`, below):

```bash
export POSTGRES_HOST=127.0.0.1 POSTGRES_PORT=5432 \
       POSTGRES_USER=postgres POSTGRES_PASSWORD=postgres \
       POSTGRES_DB=ezagent_pg_compat_dev
```

> A non-committed `bin/dev-pg` launcher can bundle these env vars + the
> orphaned-vite cleanup + the server start. See §6.

## 2. First-time DB setup (once per fresh database)

Run with the **same `POSTGRES_*` env** as everything else. `main` added
`postgrex`, so `deps.get` first if you haven't:

```bash
mix deps.get
mix ecto.create
mix ecto.migrate
mix run apps/ezagent_core/priv/repo/seeds.exs   # core seed: admin user + workspace://system
```

Migrations live in `priv/repo_pg`. `mix ecto.create` reports
`The database for EzagentCore.Repo has been created`.

## 3. World E2E seed (members + admin password)

Seeds, into `session://system/default/main`: users `alice` and `bob` (each with a
narrow per-session `:join` + `:send` cap), and the admin login
(`WORLD_E2E_ADMIN_EMAIL`, default `admin@ezagent.chat` / `WORLD_E2E_ADMIN_PW`,
default `worlddev`) — email bound + verified so the email+password login form
(task #87) accepts it. The script is idempotent and prints the `?session=`
deep-link.

```bash
mix run scripts/world_e2e_seed.exs
```

> **PG note:** on PostgreSQL you *may* run this while the dev server is up (the
> `mix run` node does NOT bind the HTTP port — `server: true` is set only by
> `mix phx.server` — and PG has no single-file lock). Still prefer
> **seed-then-start** so the server cold-loads the seeded snapshots.
>
> **Known limitation (fresh DB):** the `alice`/`bob` member-join logs
> `{:error, :no_such_actor}` because `session://system/default/main` does not
> exist until something creates it. The user rows + admin login are still seeded
> correctly. For the full E2E you create your own session through the world UI
> (step 3), so this pre-seeded conversation session is optional. If you need it
> populated, create that session first (via the world UI or `workspace/create_session`)
> then re-run the seed.
>
> **⛔ Known blocker (operator conversation E2E — steps 3/4/8).** Two bugs, NOT a
> cap/auth issue (admin holds a wildcard cap): **(X)** `create_session` times out at
> the 5 s framework dispatch limit (orchestrator/template instantiation is slow), so
> the world "New session" is racy/timeout-prone; **(Y)** a session that ends up
> without a respawnable `kind_snapshots` row (e.g. `e2e-chat`, `main`) is
> un-dispatchable once its live process is gone — `:session :send` / `:join` /
> `:routing :add_rule` return `:no_such_actor`. `send_message` dispatches
> `:cast` + `reply: :ignore`, so that error is swallowed and shown ONLY as the
> hidden `data-last-dispatch="error:no_such_actor"` attribute (composer clears,
> transcript stays "No turns"). **Send itself is fine** — to a session that HAS a
> snapshot it returns `{:ok, stored: true}` and persists the message. Root cause +
> in-node `:erpc` positive control + fix owner:
> `docs/together/2026-06-23/returns/world-deploy-e2e-pg.md` §7.

## 4. Start the dev server

```bash
# Option A (docker PG, default ports): defaults already match
mix phx.server
# Option B (host PG): with the POSTGRES_* env from §1 exported
mix phx.server
# custom ports if needed:
PORT=10042 WORLD_VITE_PORT=5173 mix phx.server
```

`phx` starts its own vite watcher on `WORLD_VITE_PORT`. If you see
`Port 5173 is already in use`, a stale vite is orphaned — see §6.

## 5. Open it

- **World operator UI:** `http://world.localhost:10042` → bounces to `/login`
  (RequireEntity). Sign in as `admin@ezagent.chat` / `worlddev`.
- **Conversation deep-link:** `http://world.localhost:10042/sessions?session=session%3A%2F%2Fsystem%2Fdefault%2Fmain`
- **Public customer page:** `http://localhost:10042/socialware/customer?session_uri=<url-encoded public_view session uri>`
  (no login). Without a valid `session_uri` it returns 400.

## 6. Clean restart / orphaned vite

The Phoenix watcher runs vite via an Erlang port; on `Ctrl+C` the port only
closes vite's stdin, which vite ignores — so vite **orphans** and keeps holding
`:5173`, breaking the next start. Clear it before booting:

```bash
pkill -f "vite --host 0.0.0.0 --port 5173"   # clear orphaned vite
lsof -ti :10042 | xargs -r kill              # clear a stale beam if any
```

`bin/dev` does the vite cleanup automatically, then `exec iex -S mix phx.server`.
A local (non-committed) `bin/dev-pg` wraps `bin/dev` with the §1 Option-B env so
one command brings the whole stack up against a host PG.

## 7. agent-browser (login + verify) — when available

The world UI is host-routed; map `world.localhost` (NOT `world.ezagent.chat` —
HSTS). The login form's first `<input>` is the hidden `_csrf_token`; fill the two
**visible** inputs (`email`/`secret`). React-controlled inputs ignore `fill`/`type`
— set the value via the native setter + dispatch an `input` event:

```bash
SESSION=world-e2e
B="agent-browser --session $SESSION"

$B open "http://world.localhost:10042/login"
$B eval "var f=document.forms[0]; var v=[...f.querySelectorAll('input')].filter(i=>i.type!=='hidden'); var s=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set; s.call(v[0],'admin@ezagent.chat'); v[0].dispatchEvent(new Event('input',{bubbles:true})); s.call(v[1],'worlddev'); v[1].dispatchEvent(new Event('input',{bubbles:true})); f.submit();"
$B open "http://world.localhost:10042/sessions"
$B screenshot /tmp/world-members.png
```

## Gotchas (learned the hard way)

- **Use `world.localhost`, never `world.ezagent.chat`** — HSTS upgrades the latter
  to HTTPS → blank page on `:10042`.
- **`pkill -f "PORT=10042"` does not match** — the env var isn't in argv. Kill by
  port (`lsof -ti :10042`) or by the vite arg string (`pkill -f "vite --host ..."`).
- **PG, not SQLite** — the old "don't seed while the server runs" rule was a SQLite
  single-file hazard. On PG it's safe; the remaining reason to seed-then-start is
  clean cold-load, not corruption.
- **`mix` needs the `POSTGRES_*` env every time** (host-PG case) — without it the
  Repo dials the docker default `:55432` and fails to connect.
- **React-controlled inputs** ignore `fill`/`type` — use the native setter +
  `input` event (the login snippet does this).
