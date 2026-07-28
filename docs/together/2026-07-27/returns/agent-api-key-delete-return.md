# Agent API Key Delete Return

> **Task:** agent-api-key-delete
> **Branch:** `codex/agent-api-key-delete`
> **Dev:** Codex
> **returned_at:** 2026-07-27

Base: `origin/main` at `bc336155a`.

## Root cause

The Agent API keys surface rendered stored provider and masked-key rows, but
provided no mutation control for removing an obsolete or incorrect credential.
The backend Behavior already exposed the capability-gated
`:delete_api_key` action; World and React had not wired it to the surface.

## Delivered

- The World React surface renders an Actions column only when the caller has
  `can_edit`; each stored key has a danger-styled Delete button and explicit
  browser confirmation.
- React sends only `agent_uri` and the stable `provider` identifier in the
  `agent.api_key.delete` event. It never sends a plaintext key.
- `WorldLive` validates the provider and agent URI, dispatches the existing
  `Ezagent.ActionSet.ApiKeys :delete_api_key` behavior with the caller's live
  presentation caps, and re-resolves the page state after success.
- The behavior's existing authorization is retained: data owner/admin or a
  matching capability authorizes the mutation; the UI is not a security
  boundary.

## Verification

### Backend

`mix test apps/ezagent_plugin_world/test/ezagent/world/agent_api_key_delete_contract_test.exs apps/ezagent_domain_identity/test/ezagent/behavior/api_keys_test.exs apps/ezagent_domain_identity/test/ezagent/behavior/api_keys_migration_parity_test.exs`

- `ezagent_domain_identity`: 24 tests, 0 failures.
- `ezagent_plugin_world`: 3 tests, 0 failures.
- The new World contract test proves deletion removes only the selected
  provider, retains other providers, emits an audit-safe deletion event, rejects
  incomplete input, and keeps the World bridge on the capability-gated action
  plus masked-state refresh.

### Frontend

`node apps/ezagent_plugin_world/assets/test/world_api_key_delete_test.mjs`

- PASS: verifies editor-only Actions rendering, destructive button styling,
  confirmation text, provider-only event payload, and the
  `agent.api_key.delete` React bridge.

Touched Elixir files pass `mix format --check-formatted`; `git diff --check`
passes.

## Remaining environment limitation

`mix precommit` was started with the shared dependency cache and temporary
build output but exceeded the local 124-second command limit without producing
a failure. The full frontend TypeScript check could not run in this isolated
worktree because its configuration resolves sibling plugin assets whose
`node_modules` are not installed here. The focused frontend contract test above
does run without that dependency graph.
