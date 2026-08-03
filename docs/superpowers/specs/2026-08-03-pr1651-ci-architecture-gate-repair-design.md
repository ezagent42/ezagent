# PR 1651 CI Architecture Gate Repair

## Goal

Restore the four failing `mix ci.fast` architecture checks after the PR 1651
module extraction without weakening the contracts enforced by those checks.
The repair must not change session credential-isolation behavior.

## Scope

1. Update `RecipeCapBindingInvariantTest` so each lifecycle assertion reads the
   module that now owns the asserted function. Keep the existing spawn, bind,
   sync, join, and rollback ordering assertions intact.
2. Compute the exact dynamic-receiver census difference for production plugin
   sources. Replace a newly introduced non-assertive access when practical; only
   update the fingerprint baseline when the access is intentional and reviewed.
3. Classify public functions introduced by the module extraction. Add useful
   `@doc` text to supported public APIs and `@doc false` to deliberately internal
   cross-module seams. Do not raise the undocumented-public-definition cap.

## Constraints

- Do not delete or relax architecture assertions.
- Do not increase the `undocumented_public_defs` baseline to accept the drift.
- Do not add unrelated refactors or change credential/session semantics.
- Preserve the user's existing worktree changes.
- Local `mix precommit` is not required for this task.

## Verification

Run the three affected architecture test files first, then `mix ezagent.doc.scan`
and `mix ci.fast`. If the final review exposes another issue, stop and report it
instead of expanding the repair without confirmation.
