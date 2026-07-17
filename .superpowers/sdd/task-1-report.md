# Task 1 report: Core opaque transport and before-live hook

Status: `DONE_WITH_CONCERNS`

Commit: `690602a44262b2bd650a9e901d5b4279508bd110`

## Result

- Added `Ezagent.Kind.spawn/3`, transporting only `:launch_context` unchanged.
- Added optional `Ezagent.Kind.before_start/1` and invoked it after URI extraction but before snapshot load, ReadyTransition registration, or KindRegistry visibility.
- Removed `:launch_context` from server args immediately after the hook, preventing behavior initialization, snapshot persistence, state retention, or restart replay.
- Added option-bearing SpawnRegistry and LocalRuntime APIs while retaining legacy arities through default arguments.
- SpawnRegistry accepts arity-one and arity-two registrations, validates the sole runtime option, and fails closed with `{:error, :launch_context_unsupported}` rather than dropping context for an arity-one function.
- LocalRuntime delegates options directly to the existing owner-gated SpawnRegistry path.

## RED evidence

Command:

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/ezagent/spawn_registry_test.exs apps/ezagent_core/test/ezagent/local_runtime_test.exs apps/ezagent_core/test/invariants/kind_init_persists_initial_snapshot_test.exs
```

Observed: `26 tests, 6 failures`.

Expected missing-interface failures included:

- arity-two `SpawnRegistry.register/2` rejected by its arity-one guard;
- undefined `SpawnRegistry.spawn/2` and `spawn_detailed/2`;
- undefined `LocalRuntime.ensure_started_detailed/2`;
- `before_start/1` was not a Kind callback and was never invoked;
- rejection incorrectly returned `{:ok, pid}` and the blocking-hook message was absent.

This established RED for transport, legacy fail-closed behavior, LocalRuntime delegation, and pre-live ordering.

## GREEN verification

Focused command (fresh final run):

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/ezagent/spawn_registry_test.exs apps/ezagent_core/test/ezagent/local_runtime_test.exs apps/ezagent_core/test/invariants/kind_init_persists_initial_snapshot_test.exs
```

Result: `26 tests, 0 failures`.

Required invariant command (fresh final run):

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/invariants/single_spawn_entry_test.exs apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs
```

Result: `4 tests, 0 failures`. The locality test printed its existing six-entry allowlisted debt warning.

Formatting/staging checks:

- `mix format` on all seven Task 1 files: passed.
- `git diff --cached --check`: passed.
- staged-name review: exactly the seven planned Task 1 files.
- no `ezagent_core` mix/dependency file changed.
- exact scan of changed Core production files found no Agent ownership module, Provision, Workspace TaskWorkspace, or Retirement reference.

## Full precommit concern

`SHELL=/bin/bash MIX_ENV=test mix precommit` was run. It compiled all umbrella apps, then reported pre-existing/unrelated full-suite failures including:

- architecture manifest `oversized_modules_gt_1000`: measured 5, cap 4 (the unchanged branch already has five files over 1000 LOC; Task 1's `kind/server.ex` was already over the threshold before this patch);
- architecture `spawn_registry_call_sites`: initially measured 23, cap 21; Task 1 was then refactored to default-argument delegates so it no longer adds duplicate LocalRuntime call-site text;
- `SkillRegistryTest` seed bundle mismatch;
- URI-query scan violation in `apps/ezagent_domain_agent/lib/ezagent/home/skill_reconcile.ex`;
- documentation coverage baseline failure.

The long umbrella run was interrupted after those unrelated failures were captured because it could no longer produce a passing precommit result. The exact Task 1 tests and required invariants were rerun fresh after the final refactor and pass as recorded above.

## Files changed

- `apps/ezagent_core/lib/ezagent/kind.ex`
- `apps/ezagent_core/lib/ezagent/kind/server.ex`
- `apps/ezagent_core/lib/ezagent/spawn_registry.ex`
- `apps/ezagent_core/lib/ezagent/local_runtime.ex`
- `apps/ezagent_core/test/ezagent/spawn_registry_test.exs`
- `apps/ezagent_core/test/ezagent/local_runtime_test.exs`
- `apps/ezagent_core/test/invariants/kind_init_persists_initial_snapshot_test.exs`

The unrelated untracked handoff `docs/together/2026-07-17/handoffs/gaga-cc-custom-backends-clarify-first.md` was not touched or staged.

---

## Review correction — 2026-07-18

### RED evidence

Added regressions for supervisor restart replay, behavior/live-state visibility,
unknown options, and rejection-output exposure, then ran:

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/ezagent/spawn_registry_test.exs apps/ezagent_core/test/ezagent/local_runtime_test.exs apps/ezagent_core/test/invariants/kind_init_persists_initial_snapshot_test.exs
```

Observed: `29 tests, 3 failures`. The failures proved that the original handle
was replayed by the permanent child restart, `Kind.spawn/3` silently accepted an
unknown option, and the new SpawnRegistry expectation needed to match its
existing fail-closed `Keyword.validate/2` return shape.

### Implementation summary

- Added generic `Ezagent.Kind.LaunchContextStore`, a supervised one-use runtime
  transport. The supervisor child start MFA retains only an inert token; the
  first `Kind.Server.init/1` atomically consumes the opaque context.
- Removed the token before hook invocation and supplies the context only in the
  hook argument. Behavior init, live state, and snapshots receive sanitized
  args. A permanent restart finds the consumed token absent and runs normally
  without replaying the hook authority.
- Discards unconsumed tokens after the start attempt, including adopted/error
  paths, without changing ordinary permanent restart behavior or the sole
  `Kind.spawn` entry.
- `Kind.spawn/3` now validates only `:launch_context` and fails closed for
  unknown options. SpawnRegistry/LocalRuntime/Kind public docs now cover their
  option-bearing arities and compatibility behavior.
- Added deterministic assertions (monitors/messages, no sleeps) covering
  restart replacement, behavior/live-state/snapshot invisibility, unknown
  options, and rejection output redaction.

### GREEN evidence

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/ezagent/spawn_registry_test.exs apps/ezagent_core/test/ezagent/local_runtime_test.exs apps/ezagent_core/test/invariants/kind_init_persists_initial_snapshot_test.exs
```

Result: `30 tests, 0 failures`.

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/invariants/single_spawn_entry_test.exs apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs
```

Result: `4 tests, 0 failures`; the locality invariant emitted its pre-existing
six-entry allowlisted debt warning.

`git diff --cached --check` passed. Only the eight correction files were staged;
the unrelated handoff remained untouched and unstaged.

### Commit

`f2371458f23e99881c56ec3cc6da0fe87635cbbb` —
`fix(core): consume kind launch context once`

### Concerns

`SHELL=/bin/bash MIX_ENV=test mix precommit` was launched as required and
completed compilation, but the repository-wide test phase was still running at
handoff time. The exact Task 1 and required invariant commands above were rerun
fresh after the final code change and passed.

---

## Second review correction — 2026-07-18

### Root cause and correction

- Split the prior ambiguous missing-token result into durable runtime states:
  pending entries retain the opaque context, consumed entries retain only a
  context-free tombstone, and absent entries fail closed as
  `:launch_context_lost` before `before_start/1` or live registration.
- Moved the runtime entry table under the existing Core ETS owner so a
  `LaunchContextStore` process restart cannot erase a pending initial receipt.
  The store rebuilds issuer monitors after restart; no authority term enters a
  retained child spec, snapshot, log, telemetry event, or store GenServer state.
- Monitored issuers and made cleanup synchronous. Pending entries are removed
  on caller death and in `Kind.spawn/3`'s `after` block for normal, error,
  raised, and exited start paths, without racing a serialized successful take.
- Added OTP status redaction. Status/crash formatting exposes only a redacted
  marker, never the authority-bearing entry table.
- Non-empty launch context now fails closed before every custom spawn strategy
  invocation. Legacy context-free custom strategies remain unchanged.

### Regression coverage

Deterministic, sleep-free tests cover store restart between issue/take, a lost
initial token refusing context-free startup, consumed permanent replacement,
issuer death before take, raise and exit cleanup paths, status redaction, and
custom-strategy rejection before invocation.

### Verification

Focused command:

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/ezagent/spawn_registry_test.exs apps/ezagent_core/test/ezagent/local_runtime_test.exs apps/ezagent_core/test/invariants/kind_init_persists_initial_snapshot_test.exs
```

Result: `35 tests, 0 failures`.

Required invariants:

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/invariants/single_spawn_entry_test.exs apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs
```

Result: `4 tests, 0 failures`; the locality invariant emitted its existing
six-entry debt warning. Per task instruction, no repository-wide
`mix precommit` was run in this correction; Task 9 owns the serialized full gate.

---

## Third review correction — 2026-07-18

Replaced the rejected global ETS/tombstone transport with one private, unnamed
per-launch `LaunchContextRelay`. Raw authority exists only in the pending relay
heap and OTP status is redacted. The retained child spec carries only the relay
pid. `take` is atomic and one-shot; `commit` distinguishes a successfully live
Kind from an abandoned initialization, so permanent crash replacements receive
only `:consumed` and failed starts are reclaimed. Issuer death and synchronous
normal/error/raise/exit cleanup reclaim pending relays. `Kind.terminate/1`
explicitly reclaims committed relays after successful supervisor removal.

The `LaunchContextStore` application child and its public `EtsOwner` table were
removed. Regressions cover absence of a named/public ETS surface, private status
redaction, issuer and failed-start cleanup, relay loss before take, atomic initial
consume, permanent replacement without replay, explicit Kind removal, and no
Behavior/live-domain/snapshot exposure. No sleeps were added.

RED evidence: the first focused run failed because `LaunchContextRelay` did not
exist; subsequent GREEN debugging exposed and corrected replacement-monitor and
failed-init lifecycle distinctions.

Fresh focused verification:

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/ezagent/spawn_registry_test.exs apps/ezagent_core/test/ezagent/local_runtime_test.exs apps/ezagent_core/test/invariants/kind_init_persists_initial_snapshot_test.exs
```

Result: `37 tests, 0 failures`.

Required invariant command exited zero:

```bash
SHELL=/bin/bash MIX_ENV=test mix test apps/ezagent_core/test/invariants/single_spawn_entry_test.exs apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs
```

Per correction instructions, the full precommit suite was not run.
