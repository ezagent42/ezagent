#!/bin/sh
set -eu

cd "$(dirname "$0")"

pandoc platform-concept-model.md \
  --standalone \
  --from=gfm \
  --metadata pagetitle="MFU 平台概念模型" \
  --css=living-docs.css \
  --output=platform-concept-model.html

pandoc skill-tree.md \
  --standalone \
  --from=gfm \
  --metadata pagetitle="MFU 成长树" \
  --css=living-docs.css \
  --output=skill-tree.html
