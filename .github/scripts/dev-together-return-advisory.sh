#!/usr/bin/env bash
set -euo pipefail

labels_json="${LABELS_JSON:-[]}"
pr_body="${PR_BODY:-}"

if grep -q '"no-dev-together-return"' <<<"$labels_json"; then
  echo "dev-together return advisory skipped: no-dev-together-return label present"
  exit 0
fi

if grep -qiE '^Dev-Together:[[:space:]]*out-of-scope[[:space:]]*$' <<<"$pr_body"; then
  echo "dev-together return advisory skipped: PR body marks Dev-Together: out-of-scope"
  exit 0
fi

if grep -Eq '^docs/together/[0-9]{4}-[0-9]{2}-[0-9]{2}/returns/[^/]+\.md$'; then
  echo "dev-together return file found"
  exit 0
fi

echo "::warning title=Missing dev-together return file::This PR targets main but does not add or modify docs/together/YYYY-MM-DD/returns/*.md. If this PR is part of the daily dev-together flow, add a return file. If it is outside that flow, add the no-dev-together-return label or put 'Dev-Together: out-of-scope' in the PR body."
exit 0
