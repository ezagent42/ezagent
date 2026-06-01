# Scenario 08: 4-agent comprehensive (user → cc → curl → np → user)

**Category**: 2 — Agent lifecycle
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-05-23 (Allen Feishu spec + CI test passing)

## Pre-conditions

- Per `docs/runbook/4-agent-comprehensive-e2e.md`:
  - `uv` on PATH (np-agent + cc bridge)
  - `python3` on PATH (cc-agent)
  - `claude` CLI on PATH (cc-agent)
  - Anthropic API key set: `ANTHROPIC_API_KEY=sk-ant-...`
  - DeepSeek API key set: `DEEPSEEK_API_KEY=sk-deepseek-...`
- Admin logged in
- Three agent templates created: cc-orchestrator, curl-translator, np-math-helper

## Actors

- **Caller**: admin
- **Targets**:
  - cc agent `entity://agent/system/cc_orchestrator`
  - curl agent `curl-agent://my-deepseek` (translator)
  - np agent `np://default/math_helper` (numpy/sympy)
- **External systems**: real `claude` + DeepSeek + numpy/sympy
- **Behaviors**: chat, routing, orchestration

## Steps

The flow exercises multi-agent orchestration: admin asks cc to compute something; cc delegates to np for math + curl for translation; final reply flows back.

1. Set up routing rules so:
   - `@cc_orchestrator` mentioned → cc receives
   - cc emits `@curl-translator` mention → curl receives
   - cc emits `@math_helper` mention → np receives
   - All other text → admin only
2. From `/admin/sessions/<session-uri>`, send: `@cc_orchestrator please compute the square root of 144 then translate "the answer is X" to Mandarin`.
3. cc's LLM understands the multi-step task; emits:
   - `chat.send "@math_helper sqrt(144)"` → np computes `12` → reply
   - cc receives `12`; emits `chat.send "@curl-translator translate: the answer is 12"` → curl posts to DeepSeek
   - DeepSeek returns translated text
   - cc receives the translation; emits final reply to admin
4. Admin sees the final translation in the session.

## Expected outcomes

- Per-step `invocations` rows trace the orchestration (admin → cc → np → cc → curl → cc → admin).
- Mention-gated routing (scenario 10) prevents off-topic agents from joining.
- All 3 backend integrations (claude, DeepSeek, numpy/sympy) succeed.

## Failure modes to test

- np-agent math error (e.g. `sqrt(-1)` returning a complex number): cc must handle the unexpected type + relay a sensible error to admin.
- DeepSeek down: cc must surface "translation unavailable" + complete the math step alone.
- cc LLM hallucinates a wrong mention (e.g. `@unknown-agent`): mention-failed notification (PR #406) fires to admin.

## Cross-references

- Related PRs:
  - PR #126 — curl-agent
  - PR #390 — PTY phase state machine (np + cc)
  - PR #406 — mention-failed notification
  - PR #422 — mention-gated routing
- Related SPECs:
  - `docs/superpowers/specs/2026-05-22-mention-gated-routing.md`
  - `docs/superpowers/specs/2026-05-23-domain-python.md` — np-agent foundation
- Tests:
  - `apps/ezagent_plugin_np/test/integration/comprehensive_4agent_e2e_test.exs` — CI version with FakeCcAgent + mocked DeepSeek (Bandit Plug)
- Evidence + runbook:
  - `docs/runbook/4-agent-comprehensive-e2e.md` (full operator recipe)

## Notes

- This is the closest scenario to "production-realistic multi-agent flow" — the canonical regression for any change to routing, mention parsing, or agent orchestration.
- Per Allen 2026-05-23, this is the V1 sign-off scenario for multi-agent dispatch.
- The CI version (FakeCcAgent + Bandit Plug for DeepSeek) runs in ~3s; the operator runbook is the real-stack smoke (~30s wall-time).
