# Return: Hello live E2E + Kanban fusion deepening

## Outcome

Completed the evidence-bearing continuation of the Hello product path on
`feat/hello-recording-ready`:

- drove the real curl-LLM member through DeepSeek (`deepseek-chat`), without a
  stub, to generate and render a valid json-render page;
- edited the same live surface with a second prompt and recorded distinct
  before/after hashes;
- verified concierge answered from the current page without changing its hash;
- verified a fresh anonymous visitor can read the public page but cannot
  delegate anonymously;
- validated the live spec with `EzagentPluginHello.Spec.validate/1` and checked
  the exact 36-component catalog contract;
- created a real Hello-to-Kanban task receipt and matched node `n7` on the
  World Kanban board;
- captured six screenshots, a secret-free transcript, and a 31.44-second
  recording companion.

Evidence lives in
`docs/e2e/2026-07-15/hello-kanban-fusion-deepen/`.

## Contract boundary

Hello remains the product/delegation entry. Kanban remains the sole task-state
owner. This return does not add mirrored board data, a duplicate permission
model, direct Kanban slice reads, anonymous mutation, or Hello-side edits.

Deferred as agreed: cross-session sharing, bidirectional binding, and #1360
Layer B. The current connection is explicitly loose-coupled, not the final
mounting model.

## Surface ownership

- Hello entry, prompts, delegation receipt: `ezagent_plugin_hello` and the
  socialware customer viewer.
- Task state and authorization: `ezagent_plugin_kanban`.
- Board presentation: existing World Kanban surface.
- `apps/ezagent_plugin_world/assets/src/styles.css`: untouched.

## Verification ledger

- Hello focused suite: 71 tests, 0 failures, 1 skipped.
- Hello web delegation/continuation: 4 tests, 0 failures.
- Hello delegation JS contract: passed.
- Hello Vite production build: passed.
- Full `mix precommit`: passed on 2026-07-15 with exit status 0. The local
  PostgreSQL migration dependency was supplied through a container-backed
  `pg_dump`/`pg_restore` wrapper; `home_migration_test.exs` also passed alone
  with 3 tests and 0 failures.
- Live spec: 152 nodes, `Spec.validate/1` accepted, 36-component catalog, 13
  catalog types used.
- Product evidence: real DeepSeek generation, second-prompt edit, concierge
  read-only hash check, anonymous view, real Kanban node, screenshots and video.

## Replacement PR closeout

- PR: https://github.com/ezagent42/ezagent/pull/1425
- Main ancestry at closeout: 0 commits behind, 15 commits ahead.
- GitHub mergeability: mergeable; repository review/approval remains outside
  this implementation handoff.
- Required checks: deterministic gate, gitleaks, return advisory, and
  dev-together ownership gate all passed. The macOS full-suite and dispatch
  canary jobs were conditionally skipped by the workflow.
