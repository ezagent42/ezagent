#!/usr/bin/env bash
# scripts/nightly-cache-sweep.sh — DURABLE nightly disk-usage-prevention sweep for the
# ezagent dev/CI/deploy machine (macOS + OrbStack). Follow-up to the 2026-07 disk-full
# incident (888G/926G → OrbStack crash → canary/beta/stable offline).
#
# WHAT IT RECLAIMS (each category: keep-recent / prune-old, size-logged, dry-runnable):
#   0. Docker — ephemeral CI/deploy IMAGES (>24h) + stopped containers + build cache.
#   1. uv cache   — `uv cache prune` (keeps in-use); size-gated monthly `uv cache clean`.
#   2. Worktrees  — `git worktree prune` + stale _build/deps (>14d) + `git gc --auto`.
#   3. Node        — npm cache verify, pnpm store prune, yarn cache clean (keep-current).
#   4. Homebrew    — `brew cleanup -s` (old downloads/versions).
#   5. Elixir      — left alone (small + re-download cost); size note only.
#   6. CI runner   — actions-runner*/_diag/*.log >7d; NOTE _work (never auto-rm).
#   7. Agent logs  — kimi sessions/logs >14d; codex log/*.log >14d (auth NEVER touched).
#   8. Syncthing   — .stversions entries >14d.
#
# 🔴 HARD SAFETY (these mirror the incident post-mortem — do not weaken):
#   - NEVER `docker … --volumes`, `docker volume rm`, `docker system prune --volumes`.
#     Live canary/beta/stable Postgres + agent-home data live in volumes.
#   - NEVER delete `ezagent-ci-base:*` nor the live `ezagent:canary|beta|stable` images.
#     The docker section builds a KEEP-SET of protected image IDs and FAILS CLOSED
#     (aborts the whole docker prune) if that set is empty or missing the ci-base id.
#   - Worktree _build/deps deletion is GATED on ~/Workspace/.stignore protecting those
#     paths (Syncthing sync-safety): if the guard is absent, that category is SKIPPED.
#   - Idempotent + safe to run while CI / canary / beta / stable are live (only touches
#     unused/labeled+aged/regenerable artifacts).
#
# USAGE:
#   scripts/nightly-cache-sweep.sh --dry-run   # print what WOULD be removed, per category
#   scripts/nightly-cache-sweep.sh             # REAL run (what the launchd cron installs)
#
# See docs/guide/nightly-cache-sweep.md for the ephemeral-label convention + install.

set -uo pipefail   # NOT `set -e`: one missing tool / failing category must never abort
                   # the whole sweep. Safety-critical sections guard themselves explicitly.

# --- Headless PATH bootstrap ---------------------------------------------------------
# launchd starts jobs with a minimal PATH and `/bin/zsh -lc` sources only LOGIN profiles
# (.zprofile/.zshenv), NOT interactive ~/.zshrc. Self-establish PATH so the sweep always
# finds docker/brew/uv/pnpm/npm regardless of launcher or where the user set up PATH —
# a headless maintenance job must not silently no-op (and refill the disk) because a tool
# resolved to nothing.
for _d in /opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin "$HOME/.local/bin" "$HOME/.orbstack/bin"; do
  [ -d "$_d" ] && case ":$PATH:" in *":$_d:"*) ;; *) PATH="$_d:$PATH" ;; esac
done
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv 2>/dev/null)" 2>/dev/null || true
export PATH

# ---------------------------------------------------------------------------- config ---
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

WORKSPACE="${EZAGENT_WORKSPACE:-$HOME/Workspace}"
ESR_NG="${EZAGENT_ESR_NG:-$WORKSPACE/esr-ng}"
DISK_ALERT_PCT="${EZAGENT_DISK_ALERT_PCT:-88}"     # Feishu/local alert if disk > this after sweep
IMAGE_AGE_H="${EZAGENT_IMAGE_AGE_H:-24}"           # ephemeral docker artifacts older than this (h)
WORKTREE_STALE_D=14                                # _build/deps in worktrees untouched > this
AGENTLOG_STALE_D=14                                # kimi/codex logs older than this
RUNNERLOG_STALE_D=7                                # actions-runner _diag logs older than this
STVERSION_STALE_D=14                               # syncthing .stversions older than this

LOGDIR="${EZAGENT_CLEANUP_LOGDIR:-$HOME/Library/Logs/ezagent}"
mkdir -p "$LOGDIR" 2>/dev/null || true
LOGFILE="$LOGDIR/nightly-cache-sweep-$(date +%Y%m%d).log"
LOG_RETENTION_D=14

# Optional Feishu custom-bot incoming webhook (see docs). Env wins over the file.
WEBHOOK="${EZAGENT_CLEANUP_WEBHOOK:-}"
WEBHOOK_FILE="${EZAGENT_CLEANUP_WEBHOOK_FILE:-$HOME/.config/ezagent/cleanup-webhook.url}"
[ -z "$WEBHOOK" ] && [ -f "$WEBHOOK_FILE" ] && WEBHOOK="$(tr -d ' \t\r\n' < "$WEBHOOK_FILE" 2>/dev/null || true)"

TOTAL_FREED_KB=0
TOOL_TIMEOUT="${EZAGENT_TOOL_TIMEOUT:-180}"   # per cache-tool cap so a held lock never hangs the cron

# ------------------------------------------------------------------------- helpers ---
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOGFILE" ; }

# Portable timeout (macOS has no `timeout`/`gtimeout`). Runs <cmd…>, returns its rc,
# or 124 if it exceeds <secs> (TERM, then KILL after a 3s grace). Used so a blocked
# cache tool — e.g. `uv cache prune` waiting on a lock held by a live CI run — is
# skipped rather than stalling the whole sweep before the disk-alert step.
with_timeout() { # <secs> <cmd...>
  local secs="$1"; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 3; kill -KILL "$pid" 2>/dev/null ) & local killer=$!
  local rc; wait "$pid" 2>/dev/null; rc=$?
  kill -TERM "$killer" 2>/dev/null; wait "$killer" 2>/dev/null
  [ "$rc" -ge 128 ] && rc=124   # killed by our timer (143=TERM / 137=KILL) -> timeout
  return $rc
}
hdr() { log ""; log "═══ $* ═══"; }
human() { # KB -> human
  awk -v k="${1:-0}" 'BEGIN{ split("KB MB GB TB",u); i=1; while(k>=1024 && i<4){k/=1024;i++} printf "%.1f%s", k, u[i] }'
}
du_kb() { [ -e "$1" ] && du -sk "$1" 2>/dev/null | awk '{print $1}' || echo 0; }
disk_pct() { df / | awk 'NR==2{gsub("%","",$5); print $5}'; }

# Record freed = before-after for a path op. Usage: reclaim <path> <label>  (op done by caller in real mode)
add_freed() { TOTAL_FREED_KB=$((TOTAL_FREED_KB + ${1:-0})); }

# Delete matches of a find expression, size-accounted + dry-run-aware.
# Usage: prune_find <label> <find-args...>   (find-args select the files/dirs to remove)
prune_find() {
  local label="$1"; shift
  local matches n kb=0 p
  matches="$(find "$@" 2>/dev/null)"
  n=0
  if [ -n "$matches" ]; then
    while IFS= read -r p; do
      [ -e "$p" ] || continue
      kb=$((kb + $(du_kb "$p")))
      n=$((n+1))
      if [ "$DRY_RUN" = 1 ]; then log "  [DRY] rm: $p"; fi
    done <<< "$matches"
  fi
  if [ "$n" = 0 ]; then log "  $label: nothing to prune"; return; fi
  if [ "$DRY_RUN" = 1 ]; then
    log "  $label: WOULD free ~$(human "$kb") ($n items)"
  else
    while IFS= read -r p; do [ -e "$p" ] && rm -rf "$p" 2>/dev/null; done <<< "$matches"
    log "  $label: freed ~$(human "$kb") ($n items)"
    add_freed "$kb"
  fi
}

# Run a tool command that shrinks a cache dir, size-accounted + dry-run-aware.
# Usage: reclaim_cmd <label> <dir-to-measure> -- <cmd...>
reclaim_cmd() {
  local label="$1" dir="$2"; shift 2; [ "$1" = "--" ] && shift
  local before after freed
  before="$(du_kb "$dir")"
  if [ "$DRY_RUN" = 1 ]; then
    log "  [DRY] $label: would run: $*  (current size $(human "$before"))"
    return
  fi
  local rc; with_timeout "$TOOL_TIMEOUT" "$@" >>"$LOGFILE" 2>&1; rc=$?
  if [ "$rc" = 0 ]; then
    after="$(du_kb "$dir")"; freed=$((before - after)); [ "$freed" -lt 0 ] && freed=0
    log "  $label: freed ~$(human "$freed") (now $(human "$after"))"
    add_freed "$freed"
  elif [ "$rc" = 124 ]; then
    log "  $label: timed out after ${TOOL_TIMEOUT}s (cache in use?) — skipped"
  else
    log "  $label: command failed (rc=$rc, non-fatal) — skipped"
  fi
}

notify() { # <message>  — Feishu webhook (if configured) + macOS local notification, never fatal
  local msg="$1"
  if [ -n "$WEBHOOK" ]; then
    curl -sS -m 10 -X POST "$WEBHOOK" \
      -H 'Content-Type: application/json' \
      -d "{\"msg_type\":\"text\",\"content\":{\"text\":\"$msg\"}}" >/dev/null 2>&1 \
      && log "  alert: posted to Feishu webhook" \
      || log "  alert: Feishu webhook POST failed (non-fatal)"
  else
    log "  alert: no Feishu webhook configured (set EZAGENT_CLEANUP_WEBHOOK or $WEBHOOK_FILE)"
  fi
  osascript -e "display notification \"$msg\" with title \"ezagent disk sweep\"" >/dev/null 2>&1 || true
}

# =========================================================================== 0. DOCKER
# The dominant accumulator. Ephemeral IMAGES pile up because the CI gate's
# `docker compose … down -v` trap tears down containers+volumes but NOT the built
# per-run image (`ci-gate-<run_id>-<attempt>-ci`). Deploy leaves old `ezagent:<sha>`
# images behind on each canary build. We remove those (>24h) but PROVABLY protect the
# live channel images + ci-base via a fail-closed KEEP-SET.
docker_cleanup() {
  hdr "0. Docker"
  command -v docker >/dev/null 2>&1 || { log "  docker not installed — skip"; return; }
  docker version >/dev/null 2>&1   || { log "  docker daemon down — skip"; return; }

  # --- KEEP-SET: image IDs that must NEVER be removed --------------------------------
  # (a) live channel tags, (b) every ci-base tag, (c) every image referenced by ANY
  #     container (running OR stopped) — a running canary's image is thus protected even
  #     if it happens to carry an ephemeral label via a bare deploy retag.
  # NOTE: all keep_ids are stored as FULL `sha256:…` ids (candidate ids are normalized
  # to full via `docker image inspect .Id` in the prune loop) so exact-line matching is
  # sound. `docker images --no-trunc` yields the full id; `.Image`/`.Id` already do.
  local keep_ids="" ref id
  for ref in ezagent:canary ezagent:beta ezagent:stable; do
    id="$(docker image inspect "$ref" --format '{{.Id}}' 2>/dev/null)" && keep_ids+="$id"$'\n'
  done
  while IFS= read -r id; do [ -n "$id" ] && keep_ids+="$id"$'\n'; done < <(docker images ezagent-ci-base --no-trunc --format '{{.ID}}' 2>/dev/null)
  while IFS= read -r id; do [ -n "$id" ] && keep_ids+="$id"$'\n'; done < <(docker ps -aq 2>/dev/null | xargs -r -n1 docker inspect --format '{{.Image}}' 2>/dev/null)
  keep_ids="$(printf '%s' "$keep_ids" | sort -u | sed '/^$/d')"

  # --- FAIL CLOSED: keep-set must be non-empty AND contain the ci-base id ------------
  local cibase_id
  cibase_id="$(docker image inspect ezagent-ci-base:latest --format '{{.Id}}' 2>/dev/null || true)"
  if [ -z "$keep_ids" ] || [ -z "$cibase_id" ] || ! grep -qxF "$cibase_id" <<<"$keep_ids"; then
    log "  ⛔ KEEP-SET invalid (empty, or ci-base id absent) — ABORTING docker image prune (fail-closed)"
    log "     keep_ids_count=$(grep -c . <<<"$keep_ids" 2>/dev/null || echo 0) cibase_id=${cibase_id:-<none>}"
  else
    log "  keep-set: $(grep -c . <<<"$keep_ids") protected image id(s) incl ci-base ${cibase_id:0:19}"

    # --- Candidate ephemeral image IDs -----------------------------------------------
    #  (a) label ezagent.ephemeral=true  (CI thin images; opt-in deploy builds)
    #  (b) compose per-run CI project images: repo ^ci-gate- / ^ci-full-
    #  (c) deploy per-sha images: repo == ezagent, tag = 7-40 hex (never canary/beta/stable)
    local cand=""
    cand+="$(docker images --filter 'label=ezagent.ephemeral=true' --format '{{.ID}}' 2>/dev/null)"$'\n'
    cand+="$(docker images --format '{{.ID}} {{.Repository}}' 2>/dev/null | awk '$2 ~ /^ci-gate-/ || $2 ~ /^ci-full-/ {print $1}')"$'\n'
    cand+="$(docker images --format '{{.ID}} {{.Repository}}:{{.Tag}}' 2>/dev/null | awk '$2 ~ /^ezagent:[0-9a-f]{7,40}$/ {print $1}')"$'\n'
    cand="$(printf '%s' "$cand" | sort -u | sed '/^$/d')"

    local cutoff=$(( $(date +%s) - IMAGE_AGE_H*3600 ))
    local removed_kb=0 kept=0 young=0 rmn=0
    if [ -n "$cand" ]; then
      while IFS= read -r id; do
        [ -n "$id" ] || continue
        local fid; fid="$(docker image inspect "$id" --format '{{.Id}}' 2>/dev/null)" || continue
        if grep -qxF "$fid" <<<"$keep_ids"; then kept=$((kept+1)); continue; fi   # protected
        local created cepoch
        created="$(docker image inspect "$id" --format '{{.Created}}' 2>/dev/null)" || continue
        cepoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "${created:0:19}" +%s 2>/dev/null || echo 0)"
        if [ "$cepoch" -gt "$cutoff" ]; then young=$((young+1)); continue; fi        # <24h
        local szb tags szkb; szb="$(docker image inspect "$id" --format '{{.Size}}' 2>/dev/null || echo 0)"
        tags="$(docker image inspect "$id" --format '{{join .RepoTags ","}}' 2>/dev/null)"; szkb=$((szb/1024))
        if [ "$DRY_RUN" = 1 ]; then
          log "  [DRY] rmi ${id:0:12} [${tags:-<none>}] (~$(human "$szkb"))"
        else
          if docker rmi -f "$id" >/dev/null 2>&1; then log "  removed ${id:0:12} [${tags:-<none>}] (~$(human "$szkb"))"; else
            log "  rmi ${id:0:12} failed (in use?) — skipped"; continue; fi
        fi
        removed_kb=$((removed_kb + szkb)); rmn=$((rmn+1))
      done <<< "$cand"
    fi
    if [ "$DRY_RUN" = 1 ]; then
      log "  images: WOULD remove $rmn ephemeral image(s) ~$(human "$removed_kb"); protected=$kept, too-young(<${IMAGE_AGE_H}h)=$young"
    else
      log "  images: removed $rmn ephemeral image(s) ~$(human "$removed_kb"); protected=$kept, too-young=$young"
      add_freed "$removed_kb"
    fi
  fi

  # --- Stopped containers > 24h (running canary/beta/stable untouched) ---------------
  if [ "$DRY_RUN" = 1 ]; then
    local sc; sc="$(docker ps -a --filter status=exited --filter status=dead --format '{{.ID}} {{.Names}} {{.Status}}' 2>/dev/null)"
    [ -n "$sc" ] && log "  [DRY] stopped-container prune (>${IMAGE_AGE_H}h) candidates:"$'\n'"$sc" || log "  stopped containers: none"
  else
    local out; out="$(docker container prune -f --filter "until=${IMAGE_AGE_H}h" 2>/dev/null | tail -1)"
    log "  stopped containers: ${out:-pruned}"
  fi

  # --- Build cache > 24h (cache only — no images, no volumes) ------------------------
  if [ "$DRY_RUN" = 1 ]; then
    local bc; bc="$(docker system df 2>/dev/null | awk '/Build Cache/{print $0}')"
    log "  [DRY] builder prune (>${IMAGE_AGE_H}h): ${bc:-<none>}"
  else
    local bout; bout="$(docker builder prune -f --filter "until=${IMAGE_AGE_H}h" 2>/dev/null | tail -1)"
    log "  build cache: ${bout:-pruned}"
  fi

  log "  (volumes intentionally UNTOUCHED — live channel data)"
}

# =========================================================================== 1. UV CACHE
uv_cleanup() {
  hdr "1. uv cache"
  command -v uv >/dev/null 2>&1 || { log "  uv not installed — skip"; return; }
  local dir="$HOME/.cache/uv"
  reclaim_cmd "uv cache prune" "$dir" -- uv cache prune
  # Monthly-ish hard clean ONLY if it still creeps past 30G (forces re-download — rare).
  local kb; kb="$(du_kb "$dir")"
  if [ "$kb" -gt $((30*1024*1024)) ] && [ "$(date +%d)" = "01" ]; then
    log "  uv cache still $(human "$kb") on month-start — hard clean"
    reclaim_cmd "uv cache clean" "$dir" -- uv cache clean
  elif [ "$kb" -gt $((30*1024*1024)) ]; then
    log "  uv cache $(human "$kb") >30G — will hard-clean on next month-start (or run: uv cache clean)"
  fi
}

# =========================================================================== 2. WORKTREES
worktree_cleanup() {
  hdr "2. Git worktrees (esr-ng)"
  # --- Syncthing safety gate: only prune _build/deps if .stignore protects them -------
  local stignore="$WORKSPACE/.stignore" protected=1 pat
  for pat in _build deps node_modules; do
    grep -qE "(^|/)${pat}(\$|/|$)" "$stignore" 2>/dev/null || protected=0
  done
  if [ "$protected" != 1 ]; then
    log "  ⚠ $stignore does NOT protect _build/deps/node_modules — SKIP _build/deps prune"
    log "     (Syncthing would propagate deletions to peers). Re-run the installer to add them."
  else
    log "  .stignore guard OK — pruning _build/deps in worktrees untouched >${WORKTREE_STALE_D}d"
    local repo art
    for repo in "$WORKSPACE"/esr-ng "$WORKSPACE"/esr-ng-*; do
      [ -e "$repo/.git" ] || continue
      for art in _build deps; do
        [ -d "$repo/$art" ] || continue
        prune_find "$(basename "$repo")/$art" "$repo/$art" -maxdepth 0 -mtime +"$WORKTREE_STALE_D"
      done
    done
  fi
  # worktree prune (drops admin refs for vanished worktrees — no file deletion, always safe)
  if [ -e "$ESR_NG/.git" ]; then
    if [ "$DRY_RUN" = 1 ]; then
      local wp; wp="$(git -C "$ESR_NG" worktree list --porcelain 2>/dev/null | grep -c '^worktree ')"
      log "  [DRY] git worktree prune (currently $wp registered worktrees)"
    else
      git -C "$ESR_NG" worktree prune 2>>"$LOGFILE" && log "  git worktree prune done"
      git -C "$ESR_NG" gc --auto --quiet 2>>"$LOGFILE" && log "  git gc --auto done"
    fi
  fi
}

# =========================================================================== 3. NODE PMs
node_cleanup() {
  hdr "3. Node package managers"
  command -v npm  >/dev/null 2>&1 && reclaim_cmd "npm cache verify" "$HOME/.npm" -- npm cache verify        || log "  npm: absent"
  command -v pnpm >/dev/null 2>&1 && reclaim_cmd "pnpm store prune" "$HOME/Library/pnpm/store" -- pnpm store prune || log "  pnpm: absent"
  command -v yarn >/dev/null 2>&1 && reclaim_cmd "yarn cache clean" "$HOME/Library/Caches/Yarn" -- yarn cache clean || log "  yarn: absent"
}

# =========================================================================== 4. HOMEBREW
brew_cleanup() {
  hdr "4. Homebrew"
  command -v brew >/dev/null 2>&1 || { log "  brew not installed — skip"; return; }
  reclaim_cmd "brew cleanup -s" "$(brew --cache 2>/dev/null || echo "$HOME/Library/Caches/Homebrew")" -- brew cleanup -s
}

# =========================================================================== 5. ELIXIR
elixir_cleanup() {
  hdr "5. Elixir (~/.hex, ~/.mix)"
  local h m; h="$(du_kb "$HOME/.hex")"; m="$(du_kb "$HOME/.mix")"
  log "  left alone (small + re-download cost): ~/.hex $(human "$h"), ~/.mix $(human "$m")"
}

# =========================================================================== 6. CI RUNNER
runner_cleanup() {
  hdr "6. CI runner logs"
  local r found=0
  for r in "$HOME"/actions-runner*; do
    [ -d "$r/_diag" ] || continue
    found=1
    prune_find "$(basename "$r")/_diag/*.log" "$r/_diag" -type f -name '*.log' -mtime +"$RUNNERLOG_STALE_D"
    [ -d "$r/_work" ] && log "  NOTE: $(basename "$r")/_work kept ($(human "$(du_kb "$r/_work")")) — a job may be mid-run; switch to --ephemeral runners for the real fix"
  done
  [ "$found" = 0 ] && log "  no actions-runner*/_diag dirs"
}

# =========================================================================== 7. AGENT LOGS
agentlog_cleanup() {
  hdr "7. Agent session logs (kimi / codex)"
  if [ -d "$HOME/.kimi-code" ]; then
    [ -d "$HOME/.kimi-code/sessions" ] && prune_find "kimi sessions/wd_* >${AGENTLOG_STALE_D}d" "$HOME/.kimi-code/sessions" -maxdepth 1 -name 'wd_*' -mtime +"$AGENTLOG_STALE_D"
    [ -d "$HOME/.kimi-code/logs" ]     && prune_find "kimi logs >${AGENTLOG_STALE_D}d"        "$HOME/.kimi-code/logs" -type f -mtime +"$AGENTLOG_STALE_D"
  else
    log "  kimi: ~/.kimi-code absent"
  fi
  # codex: ONLY plain log files under log/; NEVER auth.json/.credentials.json/config.toml,
  # and NOT the large logs_*.sqlite / sessions (may be open + state-bearing → flag, not rm).
  if [ -d "$HOME/.codex/log" ]; then
    prune_find "codex log/*.log >${AGENTLOG_STALE_D}d" "$HOME/.codex/log" -type f -name '*.log' -mtime +"$AGENTLOG_STALE_D"
  fi
  local cs; cs="$(du_kb "$HOME/.codex/logs_2.sqlite" 2>/dev/null)"
  [ "${cs:-0}" -gt $((512*1024)) ] && log "  NOTE: ~/.codex/logs_2.sqlite is $(human "$cs") — manual review (open DB; not auto-removed)"
}

# =========================================================================== 8. STVERSIONS
stversions_cleanup() {
  hdr "8. Syncthing .stversions"
  local d found=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue; found=1
    prune_find "$(dirname "$d" | sed "s#$HOME#~#")/.stversions >${STVERSION_STALE_D}d" "$d" -type f -mtime +"$STVERSION_STALE_D"
  done < <(find "$WORKSPACE" -maxdepth 3 -type d -name .stversions 2>/dev/null)
  [ "$found" = 0 ] && log "  no .stversions dirs under $WORKSPACE"
}

# ================================================================================ MAIN ===
main() {
  local mode="REAL"; [ "$DRY_RUN" = 1 ] && mode="DRY-RUN"
  local before_pct; before_pct="$(disk_pct)"
  log "════════════════════════════════════════════════════════════════════"
  log "ezagent nightly cache sweep [$mode]  $(date '+%Y-%m-%d %H:%M:%S %Z')"
  log "disk before: ${before_pct}% used  ($(df -h / | awk 'NR==2{print $4" free / "$2}'))"
  log "════════════════════════════════════════════════════════════════════"

  docker_cleanup
  uv_cleanup
  worktree_cleanup
  node_cleanup
  brew_cleanup
  elixir_cleanup
  runner_cleanup
  agentlog_cleanup
  stversions_cleanup

  local after_pct; after_pct="$(disk_pct)"
  hdr "Summary"
  log "  reclaimed this run: ~$(human "$TOTAL_FREED_KB")"
  log "  disk after: ${after_pct}% used  ($(df -h / | awk 'NR==2{print $4" free"}'))"

  if [ "$after_pct" -gt "$DISK_ALERT_PCT" ]; then
    local msg="[ezagent] disk still ${after_pct}% after nightly sweep (>${DISK_ALERT_PCT}%). Investigate: docker system df, du -sh ~/.cache/uv ~/Workspace/*/{_build,deps}."
    log "  ⚠ ALERT: $msg"
    notify "$msg"
  else
    log "  disk ${after_pct}% ≤ ${DISK_ALERT_PCT}% — no alert"
  fi

  # log rotation: keep dated logs for LOG_RETENTION_D days
  find "$LOGDIR" -name 'nightly-cache-sweep-*.log' -mtime +"$LOG_RETENTION_D" -delete 2>/dev/null || true
  log "done."
}

main "$@"
