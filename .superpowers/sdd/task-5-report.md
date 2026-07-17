# Task 5 report — Template launch-context transport

## Status

Implemented from approved HEAD `e7faf7a56e2d03f8c7b25e0a4c2a91f0781e6542`.

## Implementation

- Added optional `Ezagent.Kind.Template.instantiate/4`.
- Added option-aware callbacks for cc, cc-headless, both DeepSeek variants,
  codex local/remote, curl, py, and native.
- Each callback accepts exactly `[launch_context: opaque_handle]`, keeps the
  handle separate from template data, and forwards it unchanged to the existing
  `Kind.spawn/3` or `LocalRuntime.ensure_started_detailed/2` seam.
- Preserved `instantiate/3`, atomic fresh/adopted results, sidecar startup and
  rollback branches. Launch-context calls do not take a context-dropping
  already-alive shortcut.
- Changed the unified `entity` spawn registration to arity two. Agent URIs
  forward options; User URIs reject non-empty options before cap hydration or
  Kind spawn. Identity early registration is unchanged.
- Workspace test support derives freshness from the atomic detailed start
  result instead of mutable Application environment state.

## Verification

- Exact focused plugin command: 73 tests, 0 failures.
- Workspace sidecar-gate integration: 16 tests, 0 failures.
- Focused compilation completed without warnings after clause regrouping.
- Forbidden added runner/client scan: clean.
- `git diff --check`: clean.

## Scope

No runner path, provider request, config/env/argv transport, persistence,
serialization, logging, or inspection of the opaque context was added. The
pre-existing untracked handoff file was preserved and excluded.

## Review correction after `2a1a1da63`

- Added valid-data identity probes for all nine variants: cc, cc-deepseek,
  cc-headless, cc-headless-deepseek, codex local, codex remote, curl, py, and
  native. Each uses a distinct reference and traces the existing
  `Kind.spawn/3` or `LocalRuntime.ensure_started_detailed/2` call, asserting the
  exact separate `[launch_context: ref]` argument.
- The probe references are intentionally unissued. Agent `before_start/1`
  rejects them before any external subprocess, sidecar, or network work begins;
  no runtime implementation is overridden. The shared test helper always
  removes its global trace pattern in an `after` block.
- Retained explicit `instantiate/3` compatibility assertions and changed every
  sole-option rejection assertion to use otherwise-valid template data.
- Focused matrix: 79 tests, 0 failures. Workspace sidecar gate: 16 tests,
  0 failures. Added forbidden runner/client scan and `git diff --check`: clean.

The reviewer Critical about carrying `prepared.launch_context` through
`TemplateSpawn`/`provision_and_instantiate` is deliberately deferred to Task 6,
which owns that completion integration. This correction does not modify
`TemplateSpawn` or add the context-bearing core wrapper. Task 5 therefore remains
pending until the Task 5 + Task 6 joint re-review confirms both layers together.
