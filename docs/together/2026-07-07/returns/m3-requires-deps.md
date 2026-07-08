# M3 Requires Socialware Dependencies Return

Date: 2026-07-07
Branch: `work/m3-requires-deps`
Base: `origin/main` at `404f43ca6cc86dfb640299e32d62dcb02b5d6cdb`

## Scope

- Added `Definition.requires` as a validated string-list field, symmetric with `uses`.
- Added manifest resolution validation so required socialware must already be published in the workspace.
- Added recursive, idempotent install expansion for `requires`, including freeze-time transitive closure expansion.
- Added fail-closed installed-version conflict checks using the existing single `(session, ref)` install pointer model.
- Added repoint preflight validation against installed dependents before flipping current install pointers.
- Added conformance checks for published requirements, dependency cycles, merged role-name conflicts, and merged role-DAG analysis.
- Shifted SessionTemplate install semantics toward entry points: freeze/install expands transitive requirements automatically.

## Gates

- `MIX_ENV=test mix test apps/ezagent_domain_session/test/ezagent/socialware`  
  Result: `116 tests, 0 failures`
- `MIX_ENV=test mix ezagent.socialware.check`  
  Result: `chat`, `orchestrator`, and `socialware` all passed 15 assertions.
- `MIX_ENV=test mix precommit`  
  Result: passed. Notable summaries included:
  - `ezagent_domain_session`: `938 tests, 0 failures, 1 skipped`
  - `ezagent_domain_socialware`: `231 tests, 0 failures`
  - `ezagent_web`: `307 tests, 0 failures`
  - `ezagent_cli`: `32 tests, 0 failures`

## Acceptance Coverage

- YAML import/publish/install of two socialware definitions where one `requires` the other.
- Installing only the entry point materializes both required definitions.
- Conformance rejects dependency cycles.
- Idempotent install returns for already installed entries while still ensuring newly introduced requirements.
- Repoint preflight rejects incompatible flips before mutating install pointers.
- Role-DAG merge checks catch role-name collisions and cross-socialware cycles.

## Notes

- A direct `mix precommit` run in the fresh worktree first failed because `apps/ezagent_web/assets/node_modules` did not exist for Tailwind's `xterm` CSS import. The repo's `ci.local` alias documents that JS dependencies must be installed before direct precommit in a clean worktree. After running the same `pnpm install --no-frozen-lockfile` asset bootstrap used by `ci.local`, `mix precommit` passed.
