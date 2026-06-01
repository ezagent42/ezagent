#!/usr/bin/env bash
# Record ONE demo scenario (chat | operator | soul) and convert to GIF + MP4.
# Wrapper around record-scenario.js (drives the browser) + ffmpeg (converts).
# Playwright must already be bootstrapped in $PW_HOME (record-demo.sh does it once).
#
# Usage:
#   DEMO_MODE=chat     DEMO_OUTDIR=docs/assets/demo          scripts/demo/record-scenario.sh
#   DEMO_MODE=operator DEMO_OUTDIR=docs/assets/demo-operator scripts/demo/record-scenario.sh
#   DEMO_MODE=soul     DEMO_OUTDIR=docs/assets/demo-soul     scripts/demo/record-scenario.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PW_HOME="${PW_HOME:-$HOME/.cache/ezagent-demo-record}"
OUTDIR="${DEMO_OUTDIR:-./demo-out}"
GIF_FPS="${GIF_FPS:-12}"
GIF_WIDTH="${GIF_WIDTH:-720}"

command -v node >/dev/null   || { echo "node not found"; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)"; exit 1; }
[ -d "$PW_HOME/node_modules/playwright" ] || { echo "Playwright not bootstrapped — run scripts/demo/record-demo.sh once."; exit 1; }

echo "[record-scenario] mode=${DEMO_MODE:-chat} -> $OUTDIR"
NODE_PATH="$PW_HOME/node_modules" DEMO_OUTDIR="$OUTDIR" node "$HERE/record-scenario.js"

WEBM="$OUTDIR/demo.webm"
[ -f "$WEBM" ] || { echo "[record-scenario] no video produced"; exit 1; }

echo "[record-scenario] converting to GIF + MP4…"
ffmpeg -y -i "$WEBM" \
  -vf "fps=${GIF_FPS},scale=${GIF_WIDTH}:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" \
  "$OUTDIR/demo.gif" >/dev/null 2>&1
ffmpeg -y -i "$WEBM" -movflags +faststart -pix_fmt yuv420p "$OUTDIR/demo.mp4" >/dev/null 2>&1

echo "[record-scenario] done:"
ls -lh "$OUTDIR"/demo.gif "$OUTDIR"/demo.mp4 "$OUTDIR"/demo.webm 2>/dev/null || true
