# Task 1 report — credential-independent template-role materialization

## Scope

Modified only the Task 1 implementation and test files:

- `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex`
- `apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs`

Unrelated dirty worktree changes were preserved.

## Implementation

- Removed DefinitionAgents' installer-host adoption, source preflight, and
  post-materialization credential checks from fresh and reused role paths.
- Removed conversion of `:backend_api_key_missing` spawn errors into role skips.
  Spawn errors now retain the normal `{:agent_spawn_failed, role_name, reason}`
  shape.
- Preserved existing recipe-cap binding and failed-join compensation behavior.
- Passed the scoped materializer content overrides:

  ```elixir
  %{
    credential_optional: true,
    session_template_member: true
  }
  ```

- Updated materialization regressions so credentialless slice/environment and
  reuse roles are expected to join as members. The legacy bare-orchestrator
  adoption assertion now reflects the same reuse rule.

## TDD evidence

### Initial RED

After changing the regressions, before production changes:

```bash
mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs
```

Result: **20 tests, 5 failures**. The expected gates were observed:

- required slice role skipped by `CredentialPrecondition.check_source/4`;
- env/profile roles skipped by the credential precondition;
- credentialless reuse skipped by `check_materialized/2`;
- env backend-key failure classified as a skip.

### Post-change expected RED

After the Task 1 implementation:

```bash
mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs
```

Result: **20 tests, 1 failure**. The sole failure is intentional and belongs to
Task 2: the custom-provider test stub still returns
`{:backend_api_key_missing, "deepseek", uri}`, which now propagates as
`{:agent_spawn_failed, role_name, reason}`. This confirms Task 1 no longer
converts it into a credential skip.

### Task 1 focused GREEN evidence

```bash
mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs:1034 \
  apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs:1062 \
  apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs:1211 \
  apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs:1271 \
  apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs:1294
```

Result: **5 tests, 0 failures**.

## Additional verification

- `mix format --check-formatted` on both Task 1 files: passed.
- `git diff --check` on both Task 1 files: passed.
- `mix precommit`: exit 0. It emitted the pre-existing `ezagent_core`
  test-load-filter warning for fixture/non-matching test paths.

## Task 2 handoff

Task 2 must enable the scoped custom-provider keyless branch so the remaining
custom-provider regression can materialize and the full focused file becomes
green. Do not restore any DefinitionAgents credential preflight or skip
translation while doing so.

---

# Task 1 report — World/Hello LLM flavor selector

## Scope

Committed only these Task-1 files:

- `apps/ezagent_plugin_world/assets/src/components/WorkspacePlugin.tsx`
- `apps/ezagent_plugin_world/assets/src/components/WorkspacePlugin.test.tsx`

All pre-existing Domain Session/Agent, Hello, planning, and prior-report changes
remain unstaged and untouched.

## Changes

- The Hello `llm` role now receives the registered World flavor list and renders
  a required selector limited to Hello completion-capable flavors.
- The default remains `curl`; its provider/API URL/model configuration remains
  visible and is preserved only for `curl`.
- Choosing another supported flavor clears curl configuration. The template
  serializer independently omits Hello `config` for non-curl selections, so a
  stale client choice cannot persist curl settings with another flavor.
- Tests cover the selector's curl default, invoke its actual `onChange` handler
  with `cc-headless`, and verify the resulting `role_slots` serialization has no
  curl configuration.

## TDD / RED status

A genuine failing RED could not be reconstructed without deleting or reverting
the already-authorized in-progress implementation in these two dirty files,
which the task brief expressly prohibited. Before the test strengthening, the
existing candidate implementation made the focused test suite green. The new
behavioral test was therefore added against that candidate and verified green.

## Verification

The default Node 20.19.4 cannot run the repository's pnpm 11.5.0 because pnpm
requires `node:sqlite`; all frontend checks below used `mise exec node@22.23.1`.

```text
$ mise exec node@22.23.1 -- pnpm test WorkspacePlugin.test.tsx
Test Files  8 passed (8)
Tests  35 passed (35)

$ mise exec node@22.23.1 -- pnpm typecheck
$ tsc --noEmit && tsc --noEmit -p tsconfig.e2e.json

$ mise exec node@22.23.1 -- pnpm lint
$ eslint src --max-warnings 0

$ git diff --check
# exit 0
```

## Self-review and concerns

- The completion-flavor catalog intentionally mirrors Hello's server-side
  `llm_flavors/0` contract; World still intersects it with the registered
  `agent_flavors` received from the backend.
- `installConfigForTemplate` is exported solely to assert the user-facing save
  payload in the component test. No Domain Session/Agent path was changed.
- No full `mix precommit` was run for this scoped frontend task; that remains
  Task 3's repository-wide verification responsibility.

---

## Review correction — registered Hello flavor boundary

### Root cause

`HelloLlmRoleSlot` and `TemplateBuilder` treated the template-declared `curl`
flavor as an unconditional default. `installConfigForTemplate` also accepted a
stale `curl` choice without knowing the backend-registered flavor list. With
only `cc-headless` registered, the UI displayed curl-only fields and the save
payload could still emit curl.

### Fix

- Added one shared completion-flavor filter and default resolver: `curl` is the
  default only when registered; otherwise the first registered completion
  flavor is selected, or no flavor is selected when none is registered.
- Applied that resolver to TemplateBuilder's initial role choice and the
  `HelloLlmRoleSlot` display state.
- Passed the registered flavor list into `installConfigForTemplate`; it now
  revalidates Hello selections at the save boundary, removes stale/unregistered
  curl choices, and therefore cannot serialize curl configuration with an
  unavailable curl flavor.
- Added a regression with `flavors={["cc-headless"]}` that asserts the selector
  selects cc-headless, curl fields are absent, and a stale curl choice with
  provider/API/model data serializes as cc-headless without config. The test
  also asserts the resulting JSON has no provider value. No API-key field is
  introduced or placed in the payload.

### TDD evidence

Initial RED, after adding the regression and before the implementation change:

```text
$ mise exec node@22.23.1 -- pnpm test WorkspacePlugin.test.tsx
FAIL  uses a registered completion flavor instead of unregistered curl
Expected selected cc-headless option; received a selector with no selected
registered flavor and rendered curl provider/API URL/model fields.
Test Files  1 failed | 7 passed (8)
Tests  1 failed | 35 passed (36)
```

GREEN verification, all with Node 22.23.1 because pnpm 11 requires Node 22:

```text
$ mise exec node@22.23.1 -- pnpm test WorkspacePlugin.test.tsx
Test Files  8 passed (8)
Tests  36 passed (36)

$ mise exec node@22.23.1 -- pnpm typecheck
$ tsc --noEmit && tsc --noEmit -p tsconfig.e2e.json

$ mise exec node@22.23.1 -- pnpm lint
$ eslint src --max-warnings 0

$ git diff --check -- apps/ezagent_plugin_world/assets/src/components/WorkspacePlugin.tsx apps/ezagent_plugin_world/assets/src/components/WorkspacePlugin.test.tsx
# exit 0
```

### Scope

Only the two Task-1 World files are staged/committed for this correction. The
report itself is intentionally left unstaged, as directed; existing dirty
Domain Session/Agent and Hello files were not changed.

---

## Review correction — curl configuration secret allowlist

### Root cause

`installConfigForTemplate` persisted an arbitrary fresh `curl` role-slot
`config`. Although the World UI never writes credential fields, a stale or
injected choice could serialize `api_key` or `apiKey` into the template.

### Fix

- Added a curl-only allowlist at the serialization boundary.
- It preserves the intended nonsecret fields: `provider`, `api_url`, `model`,
  and `credential_optional`.
- All other keys, including both `api_key` and `apiKey`, are excluded.

### TDD evidence

The new regression supplied a fresh curl choice containing both secret-key
spellings and first failed against the previous serializer:

```text
$ mise exec node@22 -- pnpm test WorkspacePlugin.test.tsx
FAIL serializes only nonsecret curl configuration
Received config included api_key and apiKey
```

After the allowlist:

```text
$ mise exec node@22 -- pnpm test WorkspacePlugin.test.tsx
Test Files  8 passed (8)
Tests  37 passed (37)

$ mise exec node@22 -- pnpm typecheck
$ tsc --noEmit && tsc --noEmit -p tsconfig.e2e.json

$ mise exec node@22 -- pnpm lint
$ eslint src --max-warnings 0

$ git diff --check
# exit 0
```

### Scope

The implementation commit contains only the two Task-1 World files. This
report is intentionally left uncommitted.
