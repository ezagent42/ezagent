#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT

require_text() {
  local file="$1"
  local expected="$2"

  if ! grep -Fq -- "$expected" "$file"; then
    printf 'missing contract text in %s: %s\n' "$file" "$expected" >&2
    exit 1
  fi
}

skill=.claude/skills/dev-together/SKILL.md
standard=.claude/skills/dev-together/references/handoff-standard.md
handoff=.claude/skills/dev-together/references/handoff-template.md
plan=.claude/skills/dev-together/references/plan-template.md
review=.claude/skills/dev-together/references/review-template.md
example=.claude/skills/dev-together/scripts/render/board.example.yaml
renderer=.claude/skills/dev-together/scripts/render/board2html.py

for text in 'Plan-level closure' 'guarded_mix.sh' 'frozen implementation' 'parallel read-only review'; do
  require_text "$skill" "$text"
done

for text in 'X problem — fundamental problem' 'Y problem — engineering problem' 'Stop Rule' \
  'failure -> Plan invariant -> one root cause -> one integrated repair surface'; do
  require_text "$standard" "$text"
done

for text in '## X/Y problem framing' '## Plan-level system closure' \
  '## Execution resource envelope' '## Recurrence-prevention proof'; do
  require_text "$handoff" "$text"
done

for text in 'Plan-level system closure' 'Durable proof' 'Integration evidence'; do
  require_text "$plan" "$text"
done

for text in 'X problem' 'Y problem' 'X-level correction' 'Y-level correction' \
  'Recurrence-prevention proof' 'Owner'; do
  require_text "$review" "$text"
done

for text in 'system_closures:' 'x_problem:' 'plan_invariant:' 'durable_proof:' \
  'integration_evidence:' 'resource_envelope:' 'finding:' 'y_problem:' \
  'recurrence_prevention_proof:' 'owner:' 'id:' 'closures:'; do
  require_text "$example" "$text"
done

if grep -nE 'Y engineering trigger|工程诱因' "$skill" "$standard" "$handoff" "$plan" "$review"; then
  echo 'forbidden X/Y terminology found' >&2
  exit 1
fi

rendered_board="$test_tmp/board.html"
uv run --with pyyaml python "$renderer" "$example" "$rendered_board"
require_text "$rendered_board" 'Plan-level system closure'
require_text "$rendered_board" 'X problem'
require_text "$rendered_board" 'Recurrence-prevention proof'

legacy_board="$test_tmp/legacy.yaml"
legacy_html="$test_tmp/legacy.html"
sed '/^review:/,$d' "$example" >"$legacy_board"
cat >>"$legacy_board" <<'YAML'
review:
  method_deltas:
    - "legacy method delta remains visible"
YAML
uv run --with pyyaml python "$renderer" "$legacy_board" "$legacy_html"
require_text "$legacy_html" 'legacy method delta remains visible'

echo 'dev-together system-closure contract tests OK'
