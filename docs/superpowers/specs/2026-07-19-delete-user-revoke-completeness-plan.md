# delete_user — full revoke-completeness (close ALL codex findings + owned-agent cascade)

**Status:** coordinator plan, 2026-07-19. Allen chose B (do the cascade). Folded into ONE round on branch `feat/delete-user-atomic-revocation` (#1469) because codex's fence-hole findings undercut even the user-direct claim, so a clean user-only-first split is artificial. Result: #1469 becomes a genuinely complete "delete = atomic revocation incl. owned-agent authority."

**Principle (binding):** deleting a user revokes ALL authority that derives from that user — the user's own caps/respawn AND the authority of agents whose authority derives from them (owned or spawned-in-lineage). Revoking a principal revokes what they delegated. Fail closed.

## Part 1 — Close the remaining codex findings on the USER plane

- **F1 spawn-fence holes** — the C2 fence (Identity.create/activate) is bypassable: (a) `behaviors: []` entities skip Identity entirely; (b) an ALREADY-RUNNING process is returned by SpawnRegistry before the fence fires (spawn_registry.ex:181); (c) the owner-check walks only the direct parent. Close (a)+(b): a tombstoned principal must be refused even on the already-running-return path and the no-behaviors path (guard at the registry return + the Kind start, not only Identity.create). Invariant test: a tombstoned user whose process is still live is refused/torn down, not returned.
- **F2 absorb race** — a claimed delivery can pass the guard pre-tombstone, commit its slice post-tombstone, and its failed `mark_applied` be ignored. Close the window: re-check `deleted?` at slice-commit time (not only at guard entry), and on teardown remove any slice that committed inside the window.
- **F4 atomicity** — teardown is post-commit best-effort and the idempotent retry IGNORES cap-clear/outbox/destroy failures before returning success (users.ex:404-414, 478-497). Make the retry RE-ASSERT and propagate: a failed cap-clear/outbox/destroy must keep the tombstone in a retryable non-success state, never return :ok with a residual.

## Part 2 — Owned-agent authority CASCADE (the strongest finding)

**Enumerate** every agent whose authority derives from the deleted user:
- OWNED: `data_owner(agent) == user` (via `ApiKeys.data_owner/1` / creator_uri), across the user's workspaces (`Ezagent.Entity.Agent.list_in_workspace/1` scan + filter).
- LINEAGE: `Ezagent.AgentLineage.spawned_in_lineage?(agent, user)` catches nested/grandchild agents (closes codex's "direct-parent-only" gap). Use the existing walker.

**Per-agent revocation** (build an agent-tombstone that MIRRORS the user tombstone — reuse the patterns, don't invent):
- Clear the agent's SIGNED caps (same cap-clear op as the user, applied per-agent — incl. the agent snapshot store + any post-commit `store_cap` refill path codex flagged in F3, and retire the agent's per-Kind signing authority if present).
- Revoke the agent's PATs — `Ezagent.Entity.Token.revoke/1` per token; and extend `Token.authenticate` to reject a token whose principal is a tombstoned agent OR an agent owned/in-lineage-of a tombstoned user (token.ex:198 already has the disabled-principal hook — extend it).
- Extend the C2 spawn fence to refuse re-spawn/activate of a tombstoned agent (same fence, agent arm).

**Atomicity across N agents:** an IDEMPOTENT cascade sweep — mark the user tombstoned, then sweep+tombstone each owned/lineage agent; the whole thing retryable to convergence (reuse the delete_user idempotent-retry pattern). A partial failure leaves a retryable state, never a half-revoked "user gone but agent still capable" success.

## Acceptance (invariant tests — these ARE the completeness proof)

1. **Headline cascade invariant**: after `delete_user(U)`, an agent owned by U CANNOT authenticate (PAT rejected) and CANNOT dispatch (caps cleared) and CANNOT respawn. Fail-before: without the cascade, the agent still acts.
2. **Nested lineage**: an agent spawned by U's agent (grandchild) is also revoked (via `spawned_in_lineage?`).
3. **Independent agent NOT killed**: an agent in the same workspace whose authority is workspace/admin-granted (NOT derived from U) is UNAFFECTED — the cascade is scoped to U-derived authority, not "all agents near U". (This guards against over-broad revocation.)
4. **User-fence completeness (F1)**: tombstoned user refused on the already-running + no-behaviors paths.
5. **Atomicity (F4)**: an injected cap-clear/teardown failure yields a retryable non-success, and a retry converges to full revocation (no residual capability).
6. Full verify from umbrella root: compile -Werror, the new + existing offboarding suites, check_invariants.

## Verify env
`MIX_TEST_PARTITION=delcascade MIX_ENV=test mix ecto.reset` (shared PG drift). DBConnection.OwnershipError = known flake, re-run.
