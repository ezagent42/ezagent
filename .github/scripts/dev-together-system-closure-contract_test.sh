#!/usr/bin/env bash
set -euo pipefail

repo_root="${DEV_TOGETHER_CONTRACT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
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

assert_no_forbidden_terminology() {
  if grep -nE 'Y engineering trigger|工程诱因' "$@"; then
    echo 'forbidden X/Y terminology found' >&2
    return 1
  fi
}

validate_board_structure() {
  local board_path="$1"

  uv run --with pyyaml python - "$board_path" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    board = yaml.safe_load(stream)

closures = board.get("system_closures")
assert isinstance(closures, list) and closures, "system_closures must be a non-empty list"
required_closure = {
    "id", "x_problem", "plan_invariant", "related_cards", "durable_proof",
    "integration_evidence", "resource_envelope",
}
required_envelope = {"runner", "memory_high", "memory_max", "memory_swap_max", "lock"}
closure_by_id = {}
for closure in closures:
    assert isinstance(closure, dict), "each system closure must be a map"
    assert required_closure <= closure.keys(), "system closure is missing required keys"
    for field in required_closure - {"related_cards", "resource_envelope"}:
        assert isinstance(closure[field], str) and closure[field].strip(), \
            f"system closure {field} must be a non-empty string"
    assert isinstance(closure["related_cards"], list) and closure["related_cards"], \
        "system closure related_cards must be a non-empty list"
    assert all(isinstance(item, str) and item.strip() for item in closure["related_cards"]), \
        "system closure related_cards must contain non-empty strings"
    assert isinstance(closure["resource_envelope"], dict) and closure["resource_envelope"], \
        "system closure resource_envelope must be a non-empty map"
    assert required_envelope <= closure["resource_envelope"].keys(), \
        "system closure resource_envelope is missing required keys"
    assert all(isinstance(key, str) and key.strip() and isinstance(value, str) and value.strip()
               for key, value in closure["resource_envelope"].items()), \
        "system closure resource_envelope fields must be non-empty strings"
    assert closure["id"] not in closure_by_id, "system closure ids must be unique"
    closure_by_id[closure["id"]] = closure

cards = board.get("cards")
assert isinstance(cards, list), "cards must be a list"
card_by_id = {}
for card in cards:
    if not isinstance(card, dict) or "id" not in card:
        continue
    assert isinstance(card["id"], str) and card["id"].strip(), "card id must be a non-empty string"
    assert card["id"] not in card_by_id, "non-empty card ids must be unique"
    closures_for_card = card.get("closures") or []
    assert isinstance(closures_for_card, list), "card closures must be a list"
    assert all(isinstance(item, str) and item.strip() for item in closures_for_card), \
        "card closures must contain non-empty strings"
    card_by_id[card["id"]] = card
for closure_id, closure in closure_by_id.items():
    for card_id in closure["related_cards"]:
        assert card_id in card_by_id, f"related card does not exist: {card_id}"
        assert closure_id in (card_by_id[card_id].get("closures") or []), \
            f"card {card_id} does not link back to {closure_id}"
for card_id, card in card_by_id.items():
    for closure_id in card.get("closures") or []:
        assert closure_id in closure_by_id, f"card closure does not exist: {closure_id}"
        assert card_id in closure_by_id[closure_id]["related_cards"], \
            f"closure {closure_id} does not link back to {card_id}"

required_delta = {
    "finding", "x_problem", "y_problem", "x_level_correction",
    "y_level_correction", "recurrence_prevention_proof", "owner", "destination",
}
structured = [item for item in board.get("review", {}).get("method_deltas", []) if isinstance(item, dict)]
assert structured, "at least one structured method delta is required"
for delta in structured:
    assert required_delta <= delta.keys(), "structured method delta is missing required keys"
    for field in required_delta:
        assert isinstance(delta[field], str) and delta[field].strip(), \
            f"structured method delta {field} must be a non-empty string"
print("board structure OK")
PY
}

skill=.claude/skills/dev-together/SKILL.md
standard=.claude/skills/dev-together/references/handoff-standard.md
handoff=.claude/skills/dev-together/references/handoff-template.md
plan=.claude/skills/dev-together/references/plan-template.md
review=.claude/skills/dev-together/references/review-template.md
example=.claude/skills/dev-together/scripts/render/board.example.yaml
renderer=.claude/skills/dev-together/scripts/render/board2html.py
plan_command=.claude/skills/dev-together/commands/plan.md
review_command=.claude/skills/dev-together/commands/review.md

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

for text in 'system_closures:' 'related_cards:' 'closures: ["<closure-id>"]'; do
  require_text "$plan_command" "$text"
done
for text in 'method_deltas:' 'x_level_correction:' 'y_level_correction:' \
  'recurrence_prevention_proof:' 'destination:'; do
  require_text "$review_command" "$text"
done

for text in 'system_closures:' 'x_problem:' 'plan_invariant:' 'durable_proof:' \
  'integration_evidence:' 'resource_envelope:' 'finding:' 'y_problem:' \
  'recurrence_prevention_proof:' 'owner:' 'id:' 'closures:'; do
  require_text "$example" "$text"
done

validate_board_structure "$example"

assert_no_forbidden_terminology \
  "$skill" "$standard" "$handoff" "$plan" "$review" \
  "$plan_command" "$review_command" "$example" \
  docs/runbook/guarded-mix-execution.md \
  docs/runbook/guarded-mix-execution.zh_cn.md \
  docs/notes/2026-07-21-git-provider-system-closure-retrospective.md \
  docs/notes/2026-07-21-git-provider-system-closure-retrospective.zh_cn.md

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
    - "legacy method delta one remains visible"
    - "legacy method delta two remains visible"
YAML
uv run --with pyyaml python "$renderer" "$legacy_board" "$legacy_html"
require_text "$legacy_html" '<div class="method-delta legacy">• legacy method delta one remains visible</div>'
require_text "$legacy_html" '<div class="method-delta legacy">• legacy method delta two remains visible</div>'

bash .claude/skills/dev-together/scripts/validate_skill.sh

# Mutation evidence: the contract itself proves that removal and schema drift
# are rejected instead of merely checking that generic tokens exist somewhere.
mutated_plan="$test_tmp/plan-command-without-closure.md"
sed 's/system_closures:/system closure removed:/' "$plan_command" >"$mutated_plan"
if (require_text "$mutated_plan" 'system_closures:') >/dev/null 2>&1; then
  echo 'mutation survived: plan command can lose system_closures' >&2
  exit 1
fi

mutated_review="$test_tmp/review-command-without-method-deltas.md"
sed 's/method_deltas:/method deltas removed:/' "$review_command" >"$mutated_review"
if (require_text "$mutated_review" 'method_deltas:') >/dev/null 2>&1; then
  echo 'mutation survived: review command can lose structured method deltas' >&2
  exit 1
fi

mutated_reference="$test_tmp/board-broken-closure-reference.yaml"
sed 's/closures: \["closure-a"\]/closures: ["missing-closure"]/' "$example" >"$mutated_reference"
if validate_board_structure "$mutated_reference" >/dev/null 2>&1; then
  echo 'mutation survived: broken card-to-closure reference' >&2
  exit 1
fi

mutated_delta="$test_tmp/board-missing-method-key.yaml"
sed '/^      recurrence_prevention_proof:/d' "$example" >"$mutated_delta"
if validate_board_structure "$mutated_delta" >/dev/null 2>&1; then
  echo 'mutation survived: structured method delta can lose a required key' >&2
  exit 1
fi

mutated_duplicate_card="$test_tmp/board-duplicate-card-id.yaml"
uv run --with pyyaml python - "$example" "$mutated_duplicate_card" <<'PY'
import copy, sys, yaml
with open(sys.argv[1], encoding="utf-8") as stream:
    board = yaml.safe_load(stream)
board["cards"].append(copy.deepcopy(next(card for card in board["cards"] if card.get("id"))))
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    yaml.safe_dump(board, stream, allow_unicode=True, sort_keys=False)
PY
if validate_board_structure "$mutated_duplicate_card" >/dev/null 2>&1; then
  echo 'mutation survived: duplicate non-empty card id' >&2
  exit 1
fi

mutated_empty_field="$test_tmp/board-empty-semantic-field.yaml"
uv run --with pyyaml python - "$example" "$mutated_empty_field" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as stream:
    board = yaml.safe_load(stream)
board["system_closures"][0]["durable_proof"] = "  "
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    yaml.safe_dump(board, stream, allow_unicode=True, sort_keys=False)
PY
if validate_board_structure "$mutated_empty_field" >/dev/null 2>&1; then
  echo 'mutation survived: empty closure semantic field' >&2
  exit 1
fi

mutated_empty_envelope="$test_tmp/board-empty-resource-envelope-field.yaml"
uv run --with pyyaml python - "$example" "$mutated_empty_envelope" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as stream:
    board = yaml.safe_load(stream)
board["system_closures"][0]["resource_envelope"]["memory_max"] = ""
with open(sys.argv[2], "w", encoding="utf-8") as stream:
    yaml.safe_dump(board, stream, allow_unicode=True, sort_keys=False)
PY
if validate_board_structure "$mutated_empty_envelope" >/dev/null 2>&1; then
  echo 'mutation survived: empty required resource-envelope field' >&2
  exit 1
fi

mutated_terminology="$test_tmp/plan-command-forbidden-terminology.md"
cp "$plan_command" "$mutated_terminology"
printf '\nY engineering trigger\n' >>"$mutated_terminology"
if assert_no_forbidden_terminology "$mutated_terminology" >/dev/null 2>&1; then
  echo 'mutation survived: forbidden terminology in operative command' >&2
  exit 1
fi

validator_repo="$test_tmp/validator-without-ignore-rule"
mkdir -p "$validator_repo/.claude/skills"
cp -a .claude/skills/dev-together "$validator_repo/.claude/skills/dev-together"
git -C "$validator_repo" init -q
if (cd "$validator_repo" && bash .claude/skills/dev-together/scripts/validate_skill.sh) >/dev/null 2>&1; then
  echo 'mutation survived: validator accepts a repository without the scratch ignore rule' >&2
  exit 1
fi
echo 'mutation checks OK: command removal, references, semantic fields, ids, terminology, ignore rule'

echo 'dev-together system-closure contract tests OK'
