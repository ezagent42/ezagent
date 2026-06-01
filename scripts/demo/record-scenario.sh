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
GIF_FPS="${GIF_FPS:-15}"
GIF_WIDTH="${GIF_WIDTH:-720}"
# Cold cc replies leave 20-40s of identical frames -> the naive GIF freezes on
# one frame. mpdecimate drops the duplicate runs (dead air); setpts=N/RATE/TB
# then holds each surviving distinct state ~1/RATE s so the result flows and the
# text stays readable. tpad holds the final frame before the loop restarts.
GIF_RATE="${GIF_RATE:-2.0}"
GIF_TAIL="${GIF_TAIL:-1.2}"

command -v node >/dev/null   || { echo "node not found"; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not found (brew install ffmpeg)"; exit 1; }
[ -d "$PW_HOME/node_modules/playwright" ] || { echo "Playwright not bootstrapped — run scripts/demo/record-demo.sh once."; exit 1; }

echo "[record-scenario] mode=${DEMO_MODE:-chat} -> $OUTDIR"
NODE_PATH="$PW_HOME/node_modules" DEMO_OUTDIR="$OUTDIR" node "$HERE/record-scenario.js"

# Operator mode records two side videos (operator console = left, customer = right);
# composite them side-by-side into demo.webm so the GIF shows the take-over click +
# typing on the left AND the customer receiving it on the right, in one frame.
# The two clips have different lengths (the operator page opens a few seconds after
# the customer page), so END-align them by clone-padding the shorter clip's head —
# the operator console correctly sits idle while the customer is still typing.
# NB: no drawtext labels — the Homebrew ffmpeg build ships without the drawtext
# filter; the two pages are self-labelling ("Customer Service" vs "Acme Support").
if [ "${DEMO_MODE:-chat}" = "operator" ] && [ -f "$OUTDIR/op-side.webm" ] && [ -f "$OUTDIR/cust-side.webm" ]; then
  echo "[record-scenario] compositing operator + customer side-by-side…"
  opd=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUTDIR/op-side.webm")
  cud=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUTDIR/cust-side.webm")
  opad=$(awk -v a="$opd" -v b="$cud" 'BEGIN{d=b-a; print (d>0)?d:0}')
  cpad=$(awk -v a="$opd" -v b="$cud" 'BEGIN{d=a-b; print (d>0)?d:0}')
  ffmpeg -y -i "$OUTDIR/op-side.webm" -i "$OUTDIR/cust-side.webm" -filter_complex \
    "[0:v]scale=760:-2,setsar=1,tpad=start_duration=${opad}:start_mode=clone,pad=iw+2:ih:0:0:0x3f3f46[Lv];[1:v]scale=760:-2,setsar=1,tpad=start_duration=${cpad}:start_mode=clone[Rv];[Lv][Rv]hstack=inputs=2,format=yuv420p[v]" \
    -map "[v]" "$OUTDIR/demo.webm" >/dev/null 2>&1
fi

WEBM="$OUTDIR/demo.webm"
[ -f "$WEBM" ] || { echo "[record-scenario] no video produced"; exit 1; }

echo "[record-scenario] converting to GIF + MP4…"
# Single-pane modes (chat/soul) sit on one frame for 20-40s waiting on cc, so we
# hold each surviving state ~1/GIF_RATE s. The operator composite is a busy 2-pane
# clip (rarely fully static), so play it near real-time (rate = fps) and widen it
# so both panes stay legible.
EFF_RATE="$GIF_RATE"; EFF_WIDTH="$GIF_WIDTH"
if [ "${DEMO_MODE:-chat}" = "operator" ]; then
  EFF_RATE="$GIF_FPS"
  [ "$EFF_WIDTH" -lt 960 ] 2>/dev/null && EFF_WIDTH=960
fi
ffmpeg -y -i "$WEBM" \
  -vf "mpdecimate=hi=64*12:lo=64*5:frac=0.03,setpts=N/${EFF_RATE}/TB,fps=${GIF_FPS},tpad=stop_mode=clone:stop_duration=${GIF_TAIL},scale=${EFF_WIDTH}:-1:flags=lanczos,split[s0][s1];[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer" \
  "$OUTDIR/demo.gif" >/dev/null 2>&1
ffmpeg -y -i "$WEBM" -movflags +faststart -pix_fmt yuv420p "$OUTDIR/demo.mp4" >/dev/null 2>&1

echo "[record-scenario] done:"
ls -lh "$OUTDIR"/demo.gif "$OUTDIR"/demo.mp4 "$OUTDIR"/demo.webm 2>/dev/null || true
