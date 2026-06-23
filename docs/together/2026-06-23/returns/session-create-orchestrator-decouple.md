> **Task:** session-create-orchestrator-decouple
> **Branch:** `fix/session-create-orchestrator-decouple`
> **PR:** none
> **Dev:** Codex
> **returned_at:** 2026-06-23 21:28 +0800
> **deadline:** 2026-06-23 20:00 +0800
> **deadline_status:** out_of_scope

# Return: session create orchestrator decouple

## Done

- Implemented the rev6 session-create decoupling: `create_session` returns a usable session without waiting for orchestrator startup, and the prior 90s wait/kill/rollback gate was removed from `domain_session`.
- Converted the default orchestrator path into a declared normal member role (`role: orchestrator`) and provisioned declared role members lazily at route time.
- Added tagged routing receiver persistence with dual-read compatibility for legacy bare strings.
- Moved transport readiness into the generic `domain_agent` contract using agent-URI keyed join state, ReadyGate `:failed`, and PendingDelivery coverage.
- Added the recurrence architecture gate that rejects transport readiness/join-state primitive definitions under plugin apps.
- Reworked orchestrator cap minting to fail closed through the policy path; tenant requested caps cannot mint genesis authority.

## DoD artifact

- `mix precommit` completed with `EXIT=0`.
- `mix ezagent.check_invariants` completed with all in-scope invariants clean.
- Focused gates for core routing/rule store, domain agent readiness, domain session create/provisioning, workspace create, plugin cc, plugin hello, web, and invariant/architecture tests passed before the final precommit.

## Notes

- A stale local test database had phantom applied migrations for missing email tables; `MIX_ENV=test mix ecto.reset` was used to reset local test DB state before invariant verification.
- The worktree uses a local `apps/ezagent_web/assets/node_modules` symlink to the main checkout so web tests can run in this linked worktree. The symlink is ignored and not part of the branch.
- No PR has been opened and no commit has been created in this handoff.

## Merge request

Please review and open/merge PR from `fix/session-create-orchestrator-decouple` into the task branch path only; do not merge directly to `main`.
