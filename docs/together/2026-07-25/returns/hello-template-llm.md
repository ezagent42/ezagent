> **Task:** hello-template-llm
> **Branch:** `codex/hello-template-llm`
> **PR:** [#1576](https://github.com/ezagent42/ezagent/pull/1576)
> **Dev:** Codex
> **returned_at:** 2026-07-25 17:00 +0800
> **deadline:** 2026-07-25 23:59 +0800
> **deadline_status:** deferred

## Summary

The Hello LLM generation failure was traced to an incompatible default model:
the configured DeepSeek endpoint rejects `deepseek-chat` and accepts
`deepseek-v4-pro` or `deepseek-v4-flash`. The Hello recipe and template builder
now default to `deepseek-v4-flash`.

The browser flow was exercised through the isolated service: create/select a
Hello session, configure the LLM agent API key, send a page-generation request,
and verify the generated page in the preview iframe.

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | Hello's LLM default uses a model accepted by the configured DeepSeek endpoint | met | `EzagentPluginHello.RegistrationTest` and the World template default regression test; both passed in the targeted test run |
| 2 | A saved Hello template carries its declared role agents into a consuming session | met | `save_session_template_public_scope_gate_test.exs`; targeted World test passed with 7 tests and 0 failures |
| 3 | The consuming Hello session can receive a user request and route it to the builder | met | agent-browser session `session://system/hello/hello-v4-flash-consumer`; builder emitted “Built a fresh page” |
| 4 | The LLM agent can use the configured API key and generate the page/theme | met | agent-browser generated Sunrise Bakery page; builder emitted “Theme ready” with no browser errors |
| 5 | The generated interface is rendered in the session preview | met | iframe rendered `Sunrise Bakery`, hero heading, three content sections, menu CTA, and Contact CTA |
| 6 | Full project verification (`mix precommit` plus invariant gates) is green on the PR head | deferred | `mix precommit` was started but exceeded 18 minutes and was stopped; no CI URL exists yet. Lead must run CI and resolve any failures before merge |
| 7 | All Hello product functions are covered by E2E | deferred | Only the template/session/key/generation/preview main path was verified; unrelated or negative paths remain open and should not be represented as fully passed |

**Method friction:** The existing browser session, database state, and
workspace selection were not stable across service restarts; the isolated
service also had a stale Vite process on port 5174. The handoff should have
specified a reproducible browser state and an explicit asset-server ownership
rule before asking for UI verification.

## Verification evidence

- Targeted ExUnit run: `9` Hello registration tests and `7` World gate tests,
  `0` failures.
- Browser URL: `http://world.localhost:10043/sessions?session=session%3A%2F%2Fsystem%2Fhello%2Fhello-v4-flash-consumer`
- Generated preview: `http://world.localhost:10043/socialware/external?session_uri=session%3A%2F%2Fsystem%2Fhello%2Fhello-v4-flash-consumer`
- Service health: HTTP `302` from `/sessions` (expected unauthenticated
  redirect outside the browser session).

## Merge request

The branch is pushed in [#1576](https://github.com/ezagent42/ezagent/pull/1576)
and remains draft while the required CI gate is incomplete. It is rebased onto
`origin/main` at `846265571`.

## Review blockers before merge

- Critical: the branch removes the legacy `claude_code` backend/bridge and its
  integration test. The existing Hello LLM contract references
  `HELLO_LLM_BACKEND=claude_code`; the lead must either restore compatibility or
  explicitly approve and document that breaking removal.
- Important: `OfficialSiteSeed` now requires `EZAGENT_HELLO_FOUNDER_EMAIL`, while
  `site_seed_boot` remains enabled by default in dev/prod. Deployment must set
  the founder email or the seed behavior/config must be repaired before merge.
default to `deepseek-v4-flash`.
