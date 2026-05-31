# Scenario 33: Full-star — orchestrator dispatches ALL agent flavors (cc + codex + curl/DeepSeek)

**Category**: 3 — Session flows (orchestration, comprehensive)
**Status**: 🚧 not-implemented (gate for the orchestrator-chain dev round, 2026-05-31)
**Author**: Claude, per Allen Feishu directive 2026-05-31 ("还应该有一个 full star
的 e2e，把 codex、cc、DeepSeek（curl agent）都测试一遍")

## Intent

Build on Scenario 32 (Feishu @-mention orchestrator dispatch). The orchestrator,
driven by @-mentions from the bound Feishu group, **creates and round-trips an
agent of EACH flavor** — `cc` (claude), `codex`, and `curl` (DeepSeek) — proving the
full agent-flavor matrix works end-to-end under live orchestrator dispatch.

## Pre-conditions

- All of Scenario 32's pre-conditions (orchestrator is a member, reaches `:ready`,
  Feishu bound, startup-dialog-skip config in place for the orchestrator AND for
  spawned worker agents of every flavor).
- The cc / codex / curl agent templates are seeded + functional (Scenarios 05/06/07
  pass standalone).
- Provider creds available: Anthropic (cc, via proxy), codex (codex login), DeepSeek
  (curl agent — the DeepSeek endpoint + key).

## Steps

1. **cc flavor** — Feishu: `@orch 创建一个 cc agent 叫 worker-cc，让它回复「cc OK」`.
   → orch creates `worker-cc` (cc flavor) + it round-trips "cc OK" → mirrors back.
2. **codex flavor** — Feishu: `@orch 创建一个 codex agent 叫 worker-codex，让它回复「codex OK」`.
   → orch creates `worker-codex` (codex flavor) + it round-trips → mirrors back.
3. **curl/DeepSeek flavor** — Feishu: `@orch 创建一个 deepseek (curl) agent 叫 worker-ds，让它回复「ds OK」`.
   → orch creates `worker-ds` (curl flavor, DeepSeek) + it round-trips → mirrors back.
4. (Optional chain) `@orch 让 worker-cc、worker-codex、worker-ds 依次链式各报一句`.

## Expected outcomes (the GATE — LIVE)

- **F1**: all three worker agents created via orchestrator @-mention, one per flavor,
  each a session member.
- **F2**: each flavor round-trips a reply (`cc OK` / `codex OK` / `ds OK`) — proving
  the flavor's PTY/bridge/provider path works under orchestrator dispatch.
- **F3**: every reply mirrors OUT to the Feishu group (the user sees all three).
- **F4**: no worker stalls on a startup dialog (the config-dir fix covers all flavors).

## Verification

- **Automated** (`apps/*/test/e2e/scenario_33_*` or a cross-app harness): orchestrator
  tool-dispatch creates an agent of each flavor + asserts each round-trips (flavor
  fixtures may stub the provider call where a live provider isn't available in CI).
- **Live runbook**: real `@orch` Feishu messages create + round-trip all three flavors
  live; agent-browser screenshot of the Feishu group showing `cc OK` / `codex OK` /
  `ds OK` (per `feedback_esr_e2e_standards`). This is the true gate.

## Cross-references

- Composes Scenarios 05 (cc) + 06 (codex) + 07 (curl/DeepSeek) under Scenario 32's
  orchestrator-mention dispatch. Mirrors Scenario 08 (4agent-comprehensive) but
  orchestrator-driven via Feishu @-mention.
- Depends on Scenario 32 passing first (the orchestrator must receive + act on mentions).
