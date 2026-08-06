# Hello Session Retry Completeness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Repair same-owner partial Hello Sessions on retry and make the concurrent session-create regression test fail on any unsuccessful create.

**Architecture:** Reuse the existing idempotent `create_fresh_app/4` pipeline for same-owner retries so it restores post-spawn state while preserving the original frozen template derivation. Tighten the existing concurrent-create test at its result boundary so task exits and create errors cannot be filtered into a vacuous pass.

**Tech Stack:** Elixir 1.19, OTP, ExUnit, Ecto SQL Sandbox, ezagent Kind/Session runtime.

## Global Constraints

- Preserve the existing `:derivation_edge_conflict` result for a different owner.
- Do not wait for or validate asynchronously materialized role agents during session creation.
- Preserve the exact frozen template revision on retry.
- Do not modify or stage unrelated dirty-worktree files.
- Run from the umbrella root with
  `MIX_ENV=test MIX_TEST_PARTITION=hello_retry_1651 POSTGRES_PORT=55432`.

---

### Task 1: Repair same-owner partial Hello Sessions

**Files:**
- Modify: `apps/ezagent_plugin_hello/test/integration/hello_freeze_pin_test.exs`
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex:79-88`

**Interfaces:**
- Consumes: `App.create_app/3`, `Ezagent.WorkspaceRegistry.unbind/1`, `Ezagent.ActionSet.Session.system_set_working_copy/2`.
- Produces: same-owner `App.create_app/3` retries that restore workspace binding and the frozen template working copy.

- [ ] **Step 1: Create and migrate the isolated test database**

```bash
MIX_ENV=test MIX_TEST_PARTITION=hello_retry_1651 POSTGRES_PORT=55432 \
  mix ecto.create --quiet
MIX_ENV=test MIX_TEST_PARTITION=hello_retry_1651 POSTGRES_PORT=55432 \
  mix ecto.migrate --quiet
```

Expected: both commands exit 0. `ecto.create` may report that the isolated
database already exists on a repeated execution.

- [ ] **Step 2: Write the failing partial-session retry test**

Add this test beside the existing freeze-pin test:

```elixir
test "same-owner retry repairs post-spawn state without changing the frozen template", %{ws: ws} do
  name = "partial"
  workspace = Ezagent.URI.workspace(ws)

  assert {:ok, session_uri} = App.create_app(ws, name)
  frozen_content = persisted_template_content(session_uri)
  working_copy = Session.read_template_working_copy(session_uri)

  assert :ok = Ezagent.WorkspaceRegistry.unbind(session_uri)

  partial_working_copy =
    Map.drop(working_copy, [:session_template_uri, :member_declarations])

  assert {:ok, _} =
           Ezagent.ActionSet.Session.system_set_working_copy(
             session_uri,
             partial_working_copy
           )

  assert {:ok, ^session_uri} = App.create_app(ws, name)
  assert {:ok, ^workspace} = Ezagent.WorkspaceRegistry.lookup(session_uri)

  repaired = Session.read_template_working_copy(session_uri)
  assert %URI{} = repaired.session_template_uri
  assert [_ | _] = repaired.member_declarations
  assert persisted_template_content(session_uri) == frozen_content
end
```

- [ ] **Step 3: Run the test and verify RED**

Run:

```bash
MIX_ENV=test MIX_TEST_PARTITION=hello_retry_1651 POSTGRES_PORT=55432 \
  mix test apps/ezagent_plugin_hello/test/integration/hello_freeze_pin_test.exs \
  -n "same-owner retry repairs"
```

Expected: FAIL because the retry returns before restoring the removed workspace binding or working-copy declarations.

- [ ] **Step 4: Implement the minimal replay fix**

Change the same-owner branch in `App.create_app/3`:

```elixir
{:ok, %URI{} = existing_owner} ->
  if URI.to_string(existing_owner) == URI.to_string(owner),
    do: create_fresh_app(session_uri, ws, owner, opts),
    else: {:error, :derivation_edge_conflict}
```

- [ ] **Step 5: Run the test and verify GREEN**

Run the same focused command. Expected: `1 test, 0 failures`.

- [ ] **Step 6: Run the complete Hello freeze/admission focus**

```bash
MIX_ENV=test MIX_TEST_PARTITION=hello_retry_1651 POSTGRES_PORT=55432 \
  mix test \
  apps/ezagent_plugin_hello/test/integration/hello_freeze_pin_test.exs \
  apps/ezagent_plugin_hello/test/integration/hello_page_e2e_test.exs:211 \
  apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs:198 \
  apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs:228
```

Expected: all selected tests pass.

### Task 2: Make concurrent session-create verification fail closed

**Files:**
- Modify: `apps/ezagent_domain_session/test/integration/session_create_orchestrator_decouple_test.exs:95-132`

**Interfaces:**
- Consumes: the three `{short_name, elapsed_ms, create_result}` values returned by `Task.async_stream/3`.
- Produces: a regression test that requires exactly three successful creates before checking latency and durability.

- [ ] **Step 1: Tighten the test result boundary**

Replace the permissive async-stream unwrap:

```elixir
|> Enum.map(fn {:ok, result} -> result end)
```

with:

```elixir
|> Enum.map(fn
  {:ok, result} -> result
  {:exit, reason} -> flunk("concurrent create task exited: #{inspect(reason)}")
end)

assert length(results) == 3

for {short, elapsed_ms, result} <- results do
  assert {:ok, %{session_uri: session_uri}} = result
```

Keep the existing latency, URI, and finalized-snapshot assertions inside the loop.

- [ ] **Step 2: Verify that the tightened test detects the existing unsuccessful-create fixture**

Run:

```bash
MIX_ENV=test MIX_TEST_PARTITION=hello_retry_1651 POSTGRES_PORT=55432 \
  mix test \
  apps/ezagent_domain_session/test/integration/session_create_orchestrator_decouple_test.exs:90
```

Expected: the test can pass only if all three creates return `{:ok, ...}`. To
reconfirm the original regression, the already-observed default-database run
returned three errors but passed before this assertion was added.

- [ ] **Step 3: Run the focused file in a clean test database context**

```bash
MIX_ENV=test MIX_TEST_PARTITION=hello_retry_1651 POSTGRES_PORT=55432 \
  mix test \
  apps/ezagent_domain_session/test/integration/session_create_orchestrator_decouple_test.exs
```

Expected: `5 tests, 0 failures`.

### Task 3: Final verification

**Files:**
- Verify all touched files and preserve unrelated changes.

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces: formatter-clean, test-verified local changes.

- [ ] **Step 1: Format only touched Elixir files**

```bash
mix format \
  apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex \
  apps/ezagent_plugin_hello/test/integration/hello_freeze_pin_test.exs \
  apps/ezagent_domain_session/test/integration/session_create_orchestrator_decouple_test.exs
```

- [ ] **Step 2: Run focused regression tests**

Run the Task 1 and Task 2 focused commands again and require zero failures.

- [ ] **Step 3: Run the project gate**

```bash
MIX_ENV=test MIX_TEST_PARTITION=hello_retry_1651 POSTGRES_PORT=55432 \
  mix precommit
```

Expected: exit status 0. Fix only failures caused by the touched files; report unrelated pre-existing failures with exact output.

- [ ] **Step 4: Review the final diff**

```bash
git diff --check
git diff -- \
  apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex \
  apps/ezagent_plugin_hello/test/integration/hello_freeze_pin_test.exs \
  apps/ezagent_domain_session/test/integration/session_create_orchestrator_decouple_test.exs
git status --short
```

Confirm that only the intended hunks were added to already-dirty files.
