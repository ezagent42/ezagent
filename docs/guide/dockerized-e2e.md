# Guide: Dockerized E2E (the disposable stack)

> **Operational how-to** for running ezagent E2E against a clean, isolated docker
> stack — the standard way to validate end-to-end (never hand-patch the shared
> dev/prod nodes). Referenced from [`CONTRIBUTING.md`](../../CONTRIBUTING.md) and
> `CLAUDE.md`. Design rationale (point-in-time): `docs/superpowers/specs/2026-06-04-dockerized-e2e-harness-design.md`.

## Why a disposable stack

E2E on a long-lived shared node accumulates stale state (snapshots, pre-rename
keys, expired creds) that causes spurious failures and tempts one-off hacks. The
disposable stack starts **blank** and the scenarios seed data through the **real
ingress paths**, so results are deterministic and isolated
(`feedback_e2e_in_docker_fresh_seed`). **Never touch the dev (`:10042`) or prod
(`:10043`) docker containers** for E2E — they are not disposable.

## Stacks on this host

| stack | port | container | notes |
|-------|------|-----------|-------|
| dev | 10042 | `docker-ezagent-1` | shared dev — do NOT use for E2E |
| prod | 10043 | `ezagent-prod-ezagent-1` | production — never touch |
| **disposable** | **10044** | **`ezagent-disp`** | the E2E stack; rebuild fresh per run |

The disposable stack needs its **own dedicated Feishu app** — two BEAMs sharing
one app round-robin the WS events and silently drop ~50%
(`project_docker_dev_dedicated_feishu_app`). Its secrets live in
`docker/secrets/` (git-ignored).

## Secrets layout (`docker/secrets/`, git-ignored — never commit)

| file | purpose |
|------|---------|
| `feishu.yaml` | the **disposable stack's dedicated** Feishu app creds |
| `cc/.credentials.json` | claude OAuth seed (copy of `~/.claude/.credentials.json`) |
| `codex/auth.json`, `codex/config.toml` | codex `CODEX_HOME` seed |
| `deepseek.key` | curl agent's DeepSeek API key (single line) |

## Build + run a fresh disposable stack (on current `main`)

The host is behind a proxy; the container reaches it via `host.docker.internal`.
Feishu + localhost go direct (`NO_PROXY`).

```bash
export DOCKER_BUILD_PROXY=http://host.docker.internal:7897
export ESR_PROXY=http://host.docker.internal:7897

# from a checkout at the commit under test (e.g. current main):
docker compose -f docker/docker-compose.dev.yml build
docker compose -f docker/docker-compose.dev.yml up -d
docker compose -f docker/docker-compose.dev.yml logs -f ezagent   # watch WSS connect
```

Reachable at `http://100.64.0.27:10044` (Tailscale IP — `feedback_remote_browser_ip`;
the disposable stack publishes container `:10042` on host `:10044`). On first boot
the entrypoint bootstraps a blank `$EZAGENT_HOME` (`mix ezagent.bootstrap`).

> **⚠️ Standardization gap (2026-06-14):** the committed `docker-compose.dev.yml`
> targets host `:10042`. The disposable variant (`ezagent-disp`, host `:10044`,
> volumes `ezagent-dispm-*`, secrets from a host checkout) was spun **manually**
> outside the committed compose. **TODO:** commit a `docker/docker-compose.disp.yml`
> override (port 10044, `ezagent-dispm-*` volumes, dedicated-Feishu secrets) so a
> fresh disposable stack is reproducible from the repo with one command. Until
> then, replicate the running `ezagent-disp` config (`docker inspect ezagent-disp`).

## Run E2E

First login: a fresh stack has **no admin password** — set one before logging in
(see scenarios README §1.1):

```bash
mix ezagent.user.set_password entity://system/user/admin --password <pw>
```

Two tiers (`feedback_esr_e2e_standards`):

1. **Programmatic / deterministic** — the harness driver replays scenarios through
   the real ingress boundary (`EzagentPluginFeishu.InboundDispatcher`), with
   checkpointed snapshot layers + resume:
   ```bash
   mix ezagent.e2e.run <scenario> [--resume | --from-step N | --fresh]
   ```
2. **Live tier (the bar for sign-off)** — a real `@mention` over the live Feishu
   WS + an **agent-browser screenshot** of the agent terminal (PTY + a reply) and
   the **real Feishu round-trip**. cc-openclaw chat does NOT count — only the
   disposable stack's dedicated Feishu app replying counts.

## Quick checklist

- [ ] Build + up the disposable stack at the commit under test (10044).
- [ ] Secrets present in `docker/secrets/` (dedicated Feishu app + cc/codex/deepseek).
- [ ] WSS connected (logs); admin password set.
- [ ] Run `mix ezagent.e2e.run` scenarios; capture agent-browser + Feishu evidence for the live tier.
