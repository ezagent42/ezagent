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
