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

## Important review correction after `56da93593`

- The option-aware core wrapper no longer invokes the persistent flavor store
  or delete hooks before/after `instantiate/4`. Legacy `/3` and option-free
  behavior retain their existing hook lifecycle unchanged.
- TemplateSpawn no longer restores an adopted Plan C flavor after the fact or
  deletes pre-existing flavor state on a Plan C instantiate failure. The only
  Plan C flavor write remains the fresh final obligation, after exact receipt
  acceptance, sandbox state, and behavior overlay completion.
- The adopted regression now probes `AgentFlavorAttributes` from inside the
  deterministic instantiate barrier. RED observed the requested flavor there;
  GREEN observes the original `"preexisting-flavor"`, proving no transient
  losing-attempt write occurred.
- Plan C test Template Classes start the declared Agent Kind directly because
  first-start resolution may no longer rely on a prematurely persisted flavor
  attribute. No implicit process-local resolver channel was added.

Fresh verification: exact Task 6 command `32 tests, 0 failures`; core Template
plus Task 5 transport regressions `86 tests, 0 failures`; touched files formatted
and `git diff --check` clean.
