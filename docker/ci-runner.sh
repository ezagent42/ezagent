#!/usr/bin/env bash
# ezagent local-ubuntu-CI runner — runs INSIDE the docker/Dockerfile.ci container.
#
# Two modes (first arg, default "gate"):
#   gate    Run the EXACT CI gate once (`mix ci.local`): the same chain CI runs
#           (deps.get -> pnpm install -> ecto.create/migrate -> precommit ->
#           check_invariants). Use to pre-verify a branch is CI-green from linux.
#   repro   Hunt the ubuntu-only timing flake: loop the full-umbrella `mix test`
#           across a seed sweep until a flake fires (or the budget runs out).
#           This is the whole point — macOS cannot reproduce these races.
#   shell   Drop into bash (debug the container).
#
# Core-constraint (the flake engine) is set on the CONTAINER via `--cpuset-cpus`
# in docker-compose.ci.yml (affinity → BEAM sees N cores → starts N schedulers;
# `--cpus` quota does NOT — `nproc` still reports all host cores). We also pin the
# scheduler count with ERL_AFLAGS="+S k:k" (k from $SCHEDULERS) so detection can't
# drift. Fewer schedulers + oversubscribed max_cases = more owner-teardown
# interleaving = the shared-mode-revert race the CI runner hits (see
# docs/together/2026-06-27/notes/ci-flake-diagnosis.md §1-3).
set -uo pipefail

MODE="${1:-gate}"

# --- DB connection (postgres service from compose). Mirror CI's env names. ---
export POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
export POSTGRES_PORT="${POSTGRES_PORT:-5432}"
export POSTGRES_USER="${POSTGRES_USER:-ezagent_pg_compat}"
export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-ezagent_pg_compat}"
export MIX_ENV=test
# CI runs the umbrella with NO MIX_TEST_PARTITION — every child BEAM shares the one
# DB `ezagent_pg_compat_test`. We do the SAME (the container is already isolated, so
# we don't need the per-dev partition that protects a shared mac dev DB). Leave empty.
export MIX_TEST_PARTITION="${MIX_TEST_PARTITION:-}"

# Scheduler pin — keep BEAM scheduler count == the container's cpuset width even if
# affinity detection is imperfect. SCHEDULERS is injected by compose (default 4).
SCHEDULERS="${SCHEDULERS:-4}"
export ERL_AFLAGS="${ERL_AFLAGS:-+S ${SCHEDULERS}:${SCHEDULERS}}"

wait_for_pg() {
  echo "==> waiting for postgres at ${POSTGRES_HOST}:${POSTGRES_PORT} ..."
  for _ in $(seq 1 60); do
    if pg_isready -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" -U "$POSTGRES_USER" >/dev/null 2>&1; then
      echo "==> postgres ready"; return 0
    fi
    sleep 1
  done
  echo "!! postgres never became ready" >&2; return 1
}

env_banner() {
  echo "================ ezagent local-ubuntu-CI ================"
  echo " mode          : $MODE"
  echo " elixir        : $(elixir --version 2>/dev/null | tr '\n' ' ')"
  echo " node / pnpm   : $(node --version) / $(pnpm --version)"
  echo " schedulers    : online=$(nproc) ERL_AFLAGS='${ERL_AFLAGS}'"
  echo " db            : ${POSTGRES_HOST}:${POSTGRES_PORT} partition='${MIX_TEST_PARTITION}'"
  echo "========================================================="
}

prepare_db() {
  mix ecto.create --quiet
  mix ecto.migrate --quiet
}

case "$MODE" in
  shell)
    exec bash ;;

  gate)
    env_banner; wait_for_pg || exit 1
    # `mix ci.local` does deps.get + pnpm install + ecto.create/migrate + precommit +
    # check_invariants itself — the exact CI chain. (deps/assets are pre-warmed in the
    # image, so this is fast on re-runs.)
    exec mix ci.local ;;

  repro)
    env_banner; wait_for_pg || exit 1
    # ---- the flake hunt ----
    # SEEDS: include the known-red CI seed (#1037 = 979933) + a sweep. Override with
    #   SEEDS="979933 1 42" docker compose ... run ci repro
    SEEDS="${SEEDS:-979933 1 42 123456 555 979933 7 999 2024 314159}"
    MAX_CASES="${MAX_CASES:-8}"           # CI default (schedulers_online*2); oversubscribe.
    RESET_DB_EACH="${RESET_DB_EACH:-0}"   # 0 = leave rows for more cross-app contention (amplify)
    # Suites whose failure == a real ubuntu flake (named in the task / diagnosis).
    FLAKE_PAT='never appeared.*with children|PluginIsolationWorkspaceTest|AgentReadTest|DefaultSessionTemplateSeedTest|PresenceReadReceiptsE2ETest|OwnershipError|cannot find ownership process'
    LOGDIR="/app/tmp/ci-repro-logs"
    mkdir -p "$LOGDIR"

    [ "$RESET_DB_EACH" = "1" ] || prepare_db   # if not resetting per-iter, create once

    iter=0; hits=0
    echo "==> repro hunt: seeds=[$SEEDS] max_cases=$MAX_CASES reset_db_each=$RESET_DB_EACH"
    for seed in $SEEDS; do
      iter=$((iter+1))
      log="$LOGDIR/iter-${iter}-seed-${seed}.log"
      if [ "$RESET_DB_EACH" = "1" ]; then
        mix ecto.drop --quiet 2>/dev/null || true
        prepare_db
      fi
      echo "---- iter $iter seed=$seed max_cases=$MAX_CASES schedulers=$SCHEDULERS ----"
      # Full umbrella (NOT single-app — single-app gives the different :umbrella_only
      # *.app missing-dep failures, NOT the flake). Capture combined output.
      set -o pipefail
      mix test --seed "$seed" --max-cases "$MAX_CASES" 2>&1 | tee "$log"
      rc=${PIPESTATUS[0]}
      if [ "$rc" -ne 0 ]; then
        if grep -Eiq "$FLAKE_PAT" "$log"; then
          hits=$((hits+1))
          echo "**** FLAKE REPRODUCED on iter $iter (seed=$seed). matching lines: ****"
          grep -Ein "$FLAKE_PAT" "$log" | head -40
          echo "**** full log: $log ****"
        else
          echo "!! iter $iter (seed=$seed) FAILED but did not match a known flake pattern (rc=$rc) — see $log"
        fi
      else
        echo "== iter $iter (seed=$seed) GREEN =="
      fi
    done
    echo "========================================================="
    echo "repro hunt done: $iter iterations, $hits flake hit(s). logs in $LOGDIR"
    [ "$hits" -gt 0 ] && exit 0 || exit 3 ;;

  *)
    echo "unknown mode: $MODE (use: gate | repro | shell)" >&2; exit 64 ;;
esac
