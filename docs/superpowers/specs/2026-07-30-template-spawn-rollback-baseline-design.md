# Template Spawn Rollback Baseline Design

## Problem

Current `origin/main` has three failures in
`agent_template_spawn_sandbox_materialization_test.exs`.

Two failures expose a double-wrapped test-hook error:
`{:error, :reason}` becomes `{:error, {:error, :reason}}`. The remaining
failure uses a template fixture that returns a plugin-owned config directory
without implementing its destruction callback, so the strengthened rollback
code correctly reports an incomplete cleanup.

## Decision

Preserve the current fail-loud rollback contract.

- Normalize the post-profile hook result at the obligation boundary:
  `:ok` succeeds and `{:error, reason}` returns the unwrapped `reason`.
- Do not weaken rollback reporting when a real config directory cannot be
  destroyed.
- Bring `FallbackSandboxTemplate` into conformance by implementing
  `destroy_config_dir/2` with the same URI/path safety boundary used by test
  template fixtures.

## Scope

Only the template-spawn hook error projection and its test fixture are in
scope. Capability convergence, production template APIs, and rollback receipt
shapes remain unchanged.

## Verification

1. Reproduce all three failures on current `origin/main`.
2. Make the two error-shape tests and overlay rollback test pass.
3. Run the complete sandbox-materialization test file.
4. Run relevant invariant/compile checks, then `mix precommit`.
5. Review the branch independently before integration.
