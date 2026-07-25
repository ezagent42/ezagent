# Nightly cache sweep — durable disk-usage prevention

A follow-up to the 2026-07 disk-full incident: the dev/CI/deploy machine
(macOS + OrbStack) hit **888G/926G (100%)**, which crashed OrbStack and took
canary/beta/stable offline. The dominant consumer was accumulated **docker
images** (every CI gate + every deploy left one behind, never pruned) plus the
`~/.cache/uv` cache and stale worktree `_build` dirs.

This guide covers the two durable mechanisms that prevent a recurrence:

1. an **`ezagent.ephemeral` image label** so age-based cleanup can target throwaway
   CI images safely, and
2. a **nightly launchd cron** (`scripts/nightly-cache-sweep.sh`) that reclaims
   docker + a set of developer caches, keep-recent / prune-old, with hard safety.

---

## 1. The `ezagent.ephemeral` label convention

Docker already stamps `.Created`, but an age filter alone (`--filter until=24h`)
would also match the **live** `ezagent:canary|beta|stable` images (they can be
weeks old). So the disposable CI image build carries an explicit marker:

```dockerfile
LABEL ezagent.ephemeral="true"
```

| Image | Labelled? | Why |
|---|---|---|
| **`docker/Dockerfile.ci`** — the thin per-PR image (`ci-gate-<run_id>-<attempt>-ci`, `ezagent-ci-local`) | **YES** | Every gate run leaves one; the compose `down -v` trap removes only containers+volumes, never the built image. |
| **`docker/Dockerfile.ci-base`** — `ezagent-ci-base:*` | **NO — must survive** | Rebuilding it needs docker.io (Elixir/Node base + `apt`/`hex`/`pnpm`), which flakes through the GFW. Deleting it breaks **every** PR gate. |
| **`ezagent:canary` / `:beta` / `:stable`** (live) | **NO — must survive** | The running channels. Deleting them takes prod offline. |

A `LABEL` in the child `Dockerfile.ci` stamps **only** that thin image — never the
`FROM` base — so `ezagent-ci-base` is never labelled by inheritance.

### Deploy per-sha images (`ezagent-deploy/docker/deploy.sh`)

`deploy.sh` builds `ezagent:<sha>` then **`docker tag ezagent:<sha> ezagent:canary`**
— the promoted tag is a *bare retag sharing the same image ID*. If the sha build
were labelled `ephemeral=true`, the live `ezagent:canary` (same ID) would inherit
the label and the obvious `docker image prune -af --filter label=ezagent.ephemeral=true`
would delete prod the moment its container is down (redeploy / crash-loop window).

To keep that footgun off the incident-scarred deploy path, the deploy build is
**deliberately NOT labelled**. Old `ezagent:<sha>` images are instead reclaimed by
the sweep's **name rule** (`^ezagent:[0-9a-f]{7,40}$`, minus the keep-set, >24h) —
which never matches `canary`/`beta`/`stable` (non-hex names) and never matches the
currently-promoted sha (its ID is in the keep-set). No deploy-repo change is
required. (If you ever prefer the literal label, the safe variant is to
relabel-on-promote to `ephemeral=false` so the live tag gets a distinct ID — but
that touches the promote path and is not needed.)

---

## 2. What the nightly sweep reclaims

`scripts/nightly-cache-sweep.sh` — each category is keep-recent / prune-old,
size-logged, and dry-runnable:

| # | Category | Action |
|---|---|---|
| 0 | **Docker** | ephemeral IMAGES >24h (label + `ci-gate-*`/`ci-full-*` name + `ezagent:<sha>` name), minus a fail-closed keep-set; stopped containers >24h; `docker builder prune` >24h. |
| 1 | **uv cache** | `uv cache prune` (keeps in-use); size-gated `uv cache clean` only if >30G on month-start. |
| 2 | **Worktrees** | `git worktree prune` + `git gc --auto`; stale `_build`/`deps` in worktrees untouched >14d — **gated on Syncthing `.stignore`** (see below). |
| 3 | **Node** | `npm cache verify`, `pnpm store prune`, `yarn cache clean` (all keep-current). |
| 4 | **Homebrew** | `brew cleanup -s`. |
| 5 | **Elixir** | left alone (`~/.hex`/`~/.mix` are small + costly to refetch) — size note only. |
| 6 | **CI runner** | `actions-runner*/_diag/*.log` >7d. `_work` is **noted, never deleted** (a job may be mid-run) — the real fix is `--ephemeral` runners. |
| 7 | **Agent logs** | kimi `sessions/wd_*` + `logs` >14d; codex `log/*.log` >14d. Codex **auth is never touched**; its large `logs_*.sqlite` is flagged for manual review, not auto-removed. |
| 8 | **Syncthing** | `.stversions` entries >14d under `~/Workspace`. |

### 🔴 Hard safety (do not weaken)

- **Never** `docker … --volumes`, `docker volume rm`, or `docker system prune --volumes`
  — live canary/beta/stable Postgres + agent-home data live in volumes.
- **Never** delete `ezagent-ci-base:*` or the live `ezagent:canary|beta|stable`
  images. The docker section builds a **keep-set** of protected image IDs (the three
  live tags + every `ezagent-ci-base` tag + every image referenced by any container,
  running or stopped) and **fails closed**: if that set is empty or missing the
  ci-base ID, it aborts the docker prune entirely.
- Worktree `_build`/`deps` deletion is **gated on `~/Workspace/.stignore`** listing
  those paths — `~/Workspace` is a Syncthing `sendreceive` folder, so an un-ignored
  deletion would propagate to peers. If the guard is absent the category is skipped.
- Idempotent + safe to run while CI / canary / beta / stable are live.

---

## 3. Install

### 3a. Syncthing `.stignore` prerequisite (one-time)

`~/Workspace` is Syncthing-synced. Before the sweep may prune worktree build
artifacts, those paths must be ignored so deletions don't propagate to peers.
Adding a path to `.stignore` does **not** delete peer copies; it only stops sync,
after which a local deletion is invisible to sync. Ensure `~/Workspace/.stignore`
contains at least:

```
_build
deps
node_modules
.stversions
```

### 3b. Load the launchd agent

Install a **stable copy** of the script (repo/worktree paths are not durable — a
PR worktree is removed on cleanup) and point the plist at it:

```bash
SWEEP_BIN="$HOME/Library/Application Support/ezagent/nightly-cache-sweep.sh"
mkdir -p "$(dirname "$SWEEP_BIN")"
install -m 755 scripts/nightly-cache-sweep.sh "$SWEEP_BIN"    # re-run after each repo update

PLIST=~/Library/LaunchAgents/com.ezagent.nightly-cache-sweep.plist
sed "s#__SWEEP_BIN__#$SWEEP_BIN#g" scripts/com.ezagent.nightly-cache-sweep.plist.example > "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"
launchctl list | grep com.ezagent.nightly-cache-sweep     # verify scheduled
```

The cron runs **REAL mode nightly at 03:30** (before the 04:00 deploy backup, so
the two never contend for docker). Logs: `~/Library/Logs/ezagent/nightly-cache-sweep-<date>.log`
(14-day retention) + `/tmp/ezagent-nightly-sweep.{out,err}`.

### 3c. Verify first — dry run

```bash
scripts/nightly-cache-sweep.sh --dry-run     # prints what it WOULD remove, per category
```

Confirm the docker section reports a valid keep-set incl. the ci-base ID and that
no live/base image is ever a removal candidate.

---

## 4. Optional — Feishu alert

If disk is still `>88%` after a sweep, the script emits a macOS local notification
and, if a Feishu **custom-bot incoming webhook** is configured, posts there too:

```bash
mkdir -p ~/.config/ezagent
echo 'https://open.feishu.cn/open-apis/bot/v2/hook/XXXX' > ~/.config/ezagent/cleanup-webhook.url
# or: export EZAGENT_CLEANUP_WEBHOOK=https://…   (env wins over the file)
```

Without a webhook the alert degrades to the local notification + a logged `WARN`
— it is never silently dropped.

---

## Tunables (env)

| Var | Default | Meaning |
|---|---|---|
| `EZAGENT_DISK_ALERT_PCT` | `88` | Alert threshold after sweep. |
| `EZAGENT_WORKSPACE` | `~/Workspace` | Syncthing-synced worktree root. |
| `EZAGENT_ESR_NG` | `~/Workspace/esr-ng` | Repo for `worktree prune` / `gc`. |
| `EZAGENT_CLEANUP_WEBHOOK[_FILE]` | — / `~/.config/ezagent/cleanup-webhook.url` | Feishu webhook. |
| `EZAGENT_CLEANUP_LOGDIR` | `~/Library/Logs/ezagent` | Log directory. |
