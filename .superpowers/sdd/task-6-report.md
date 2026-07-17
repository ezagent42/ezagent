# Task 6 report — receipt-backed TemplateSpawn completion

## Status

Implemented from approved HEAD `e3b5efcbe`.

## RED evidence

The exact Task 6 command initially failed because the production path invoked
`instantiate/3`: the workspace test received no launch context, and a Template
without `instantiate/4` executed its `/3` effect instead of failing closed.

## Implementation

- Added the option-aware `provision_and_instantiate/5` contract boundary. It
  validates `instantiate/4` before config allocation, flavor hooks, or Template
  effects, and invokes it with exactly `[launch_context: launch_context]`.
  The existing `/4` wrapper preserves the legacy `instantiate/3` path.
- Threaded `prepared.launch_context` separately through `TemplateSpawn`; it is
  never inserted into Template data.
- Plan C fresh completion now verifies `CreationInventory.exact/4` before
  sandbox, overlay, flavor, or completion work. It does not rewrite lineage,
  workspace ownership, or creation inventory already committed by Agent init.
- Non-Plan-C fresh completion retains its legacy lineage, workspace, inventory,
  sandbox, overlay, flavor, rollback, and grant behavior.
- Adopted Plan C completion finalizes PreStart first, returns
  `:sidecar_start_not_fresh`, and preserves the existing worker's lineage,
  workspace, sandbox, flavor, overlay, and creation inventory.
- PreStart fresh completion verifies the exact persisted receipt and maps a
  missing/conflicting receipt to `:ownership_receipt_missing`; it never marks the
  provision started.
- `reserve_creation_identity/1` was already absent at the approved Task 5 HEAD;
  no PreStart inventory prewrite remains.

## Verification

- Exact Task 6 command: 32 tests, 0 failures.
- Core Template boundary plus Task 5 flavor transport regressions: 93 tests,
  0 failures.
- Touched files formatted; `git diff --check` clean.

## Scope

No launch context is serialized, logged, persisted, or inserted into Template
data. The pre-existing untracked handoff file was preserved and excluded.
