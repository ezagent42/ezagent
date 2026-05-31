#!/usr/bin/env bash
# Self-bootstrapping browser-native demo recorder for the ezagent PoC.
# Produces a committable GIF + MP4 (+ PNG screenshots) WITHOUT macOS Screen Recording permission,
# by capturing the browser compositor via Playwright (not the OS screen).
#
# Usage:
#   scripts/demo/record-demo.sh                          # auto-drive /chat/cinnox, output -> ./demo-out
#   DEMO_URL=http://127.0.0.1:10142/operator/cinnox \
#     DEMO_SECONDS=12 DEMO_HEADED=1 scripts/demo/record-demo.sh   # passive 12s record of any URL
#   DEMO_OUTDIR=docs/assets/demo scripts/demo/record-demo.sh      # write artifacts into the repo
#
# All knobs are env vars consumed by record-demo.js (see its header).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Cache the Playwright install outside the Elixir repo so we don't pollute it with node_modules.
PW_HOME="${PW_HOME:-$HOME/.cache/ezagent-demo-record}"
OUTDIR="${DEMO_OUTDIR:-./demo-out}"
GIF_FPS="${GIF_FPS:-12}"
GIF_WIDTH="${GIF_WIDTH:-720}"

command -v node >/dev/null || { echo "node not found (expected nvm node)"; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)"; exit 1; }

# 1) Bootstrap Playwright + Chromium once (cached).
if [ ! -d "$PW_HOME/node_modules/playwright" ]; then
  echo "[record-demo] bootstrapping Playwright into $PW_HOME (one-time)…"
  mkdir -p "$PW_HOME"
  ( cd "$PW_HOME" && npm init -y >/dev/null 2>&1 && npm i playwright@latest >/dev/null 2>&1 && npx playwright install chromium >/dev/null 2>&1 )
fi

# 2) Record (resolve the recorder against the cached node_modules).
echo "[record-demo] recording…"
NODE_PATH="$PW_HOME/node_modules" DEMO_OUTDIR="$OUTDIR" node "$HERE/record-demo.js"

WEBM="$OUTDIR/demo.webm"
[ -f "$WEBM" ] || { echo "[record-demo] no video produced — see output above"; exit 1; }

# 3) Convert to a high-quality GIF (palette) and an h264 MP4. Both are committable.
echo "[record-demo] converting to GIF + MP4…"
ffmpeg -y -i "$WEBM" \
  -vf "fps=${GIF_FPS},scale=${GIF_WIDTH}:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" \
  "$OUTDIR/demo.gif" >/dev/null 2>&1
ffmpeg -y -i "$WEBM" -movflags +faststart -pix_fmt yuv420p "$OUTDIR/demo.mp4" >/dev/null 2>&1

echo "[record-demo] done:"
ls -lh "$OUTDIR"/demo.gif "$OUTDIR"/demo.mp4 "$OUTDIR"/demo.webm 2>/dev/null || true
echo "[record-demo] commit demo.gif (or demo.mp4) into the repo, then reference its raw URL in the PR."
