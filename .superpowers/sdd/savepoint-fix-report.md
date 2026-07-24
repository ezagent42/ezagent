# Savepoint Fix Report

## Change

- `Ezagent.Provenance.DerivationEdges` now passes `mode: :savepoint` only when
  `EzagentCore.Repo.in_transaction?/0` is true. Standalone inserts use the
  normal insert mode, while transaction-local uniqueness-race recovery keeps
  savepoint semantics.
- Added a direct PostgreSQL regression using an independent unsandboxed owner
  connection. It asserts the connection is not in a transaction and records a
  derivation edge successfully.

## Verification

All commands used `MIX_ENV=test MIX_TEST_PARTITION=savepointfix` from the
umbrella root after creating and migrating that isolated database.

- RED: the new direct-connection test failed with
  `%DBConnection.TransactionError{status: :idle, message: "transaction is not started"}`
  at `DerivationEdges.insert_fact/1`; the existing concurrency regression passed.
- GREEN: `agent_lineage_concurrency_test.exs` passed, 2 tests and 0 failures.
- Focused core derivation/lineage suites passed, 16 tests and 0 failures.
- Focused creation-inventory and Agent-template-spawn suites passed, 22 tests
  and 0 failures.
- Touched files pass `mix format --check-formatted`; `git diff --check` is clean.

## Concern

`mix precommit` was invoked on the same isolated partition and completed its
full compile, but the runner returned immediately after the repository's
pre-existing `:test_load_filters` warning without an ExUnit or trailing exit
summary. The focused umbrella-root commands above produced explicit zero exit
markers and are the verification evidence for this change.
