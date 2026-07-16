#!/usr/bin/env bash
# dev-together: deterministic markdown -> HTML render.
# The MODEL never hand-writes HTML. It fills a fixed markdown template
# (plan.template.md / review.template.md), then runs this script.
# Presentation (skeleton + CSS) lives ONLY in dev-together.pandoc.html.
#
# Usage: md2html.sh <input.md> [output.html]
#   default output = input with .md -> .html
#
# Requires: pandoc (>= 3.0). Install: brew install pandoc / apt install pandoc.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$HERE/dev-together.pandoc.html"

if ! command -v pandoc >/dev/null 2>&1; then
  echo "md2html: pandoc not found. Install pandoc (brew install pandoc / apt install pandoc)." >&2
  exit 1
fi

IN="${1:?usage: md2html.sh <input.md> [output.html]}"
OUT="${2:-${IN%.md}.html}"

if [[ ! -f "$IN" ]]; then
  echo "md2html: input not found: $IN" >&2
  exit 1
fi

# pandoc: GitHub-flavored md -> self-contained standalone HTML using the pinned
# template. raw_html is kept ON so the template's .kpi/.big/.risk/.pill spans in
# the markdown pass through verbatim.
pandoc "$IN" \
  --from=gfm+raw_html \
  --to=html5 \
  --standalone \
  --template="$TEMPLATE" \
  --wrap=none \
  -o "$OUT.tmp"

# Wrap tables so wide tables scroll instead of overflowing the page body
# (pandoc emits a bare <table>; the house style scrolls via .tablewrap).
sed -E 's#<table#<div class="tablewrap"><table#g; s#</table>#</table></div>#g' "$OUT.tmp" > "$OUT"
rm -f "$OUT.tmp"

echo "md2html: wrote $OUT"
