# Same-URI Template Spawn Serialization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure a failed same-URI TemplateSpawn request can never remove or mutate the Agent successfully created by another request.

**Architecture:** Wrap the whole `spawn_from_template_content/5` side-effect chain in the existing per-URI lifecycle transition lock. A caller that encounters an already-live URI returns `{:error, :agent_uri_already_live}` with no mutation; a caller queued behind a failed attempt runs only after that attempt has compensated its active products. The append-only provenance edge remains untouched.

**Tech Stack:** Elixir/OTP, Phoenix umbrella tests, Ecto/PostgreSQL, `Ezagent.Lifecycle.with_entity_transition/2`.

## Global Constraints

- Reuse the existing Core transition lock; do not add a Core synchronization primitive or a reservation table.
- The lock starts before cascade credential-grant resolution and ends after success or compensation.
- `fresh?: false` is zero-side-effect for this TemplateSpawn entry point.
- Preserve the append-only derivation/provenance invariant.
- Do not alter User display-name semantics or unrelated spawn APIs.

---

### Task 1: Lock the complete same-URI spawn transaction and reject adoption

**Files:**
- Modify: `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex:240-287, 361-425, 556-562`
- Test: `apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs`

**Interfaces:**
- Consumes: `Ezagent.Lifecycle.with_entity_transition(instance_uri, fun)` and atomic `fresh?` returned by a Template Class.
- Produces: `spawn_from_template_content/5 :: {:ok, %{workers: [URI.t()], fresh?: true}} | {:error, :agent_uri_already_live | term()}` for normal same-URI calls.

- [ ] **Step 1: Write the failing adopted-worker test**

  Add a fixture that starts an Agent at `instance_uri`, records its original flavor/config state, then calls `TemplateSpawn.spawn_from_template_content/5` for the same URI. Assert:

  ```elixir
  assert {:error, :agent_uri_already_live} =
           TemplateSpawn.spawn_from_template_content(content, instance_uri, owner_uri, workspace_uri, [])

  assert {:ok, original_flavor} = Ezagent.AgentFlavorAttributes.get(instance_uri)
  assert {:ok, _pid} = Ezagent.KindRegistry.lookup(instance_uri)
  ```

- [ ] **Step 2: Run the focused test to verify it fails**

  Run:

  ```bash
  MIX_ENV=test mix test apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs
  ```

  Expected: the pre-change path returns `{:ok, %{fresh?: false}}` and/or mutates adopted-worker attributes.

- [ ] **Step 3: Serialize the full chain and make the non-winner read-only**

  Refactor the existing body into a private function and call it under the existing lock:

  ```elixir
  def spawn_from_template_content(content, %URI{} = instance_uri, spawned_by, workspace, opts)
      when is_map(content) and is_list(opts) do
    Ezagent.Lifecycle.with_entity_transition(instance_uri, fn ->
      do_spawn_from_template_content(content, instance_uri, spawned_by, workspace, opts)
    end)
  end
  ```

  In both `fresh?: false` branches, return `{:error, :agent_uri_already_live}`. Remove the calls that revoke a grant, update sandbox state, or write flavor attributes for that adopted URI. Keep grant deletion only on paths that created the grant while holding this URI lock.

- [ ] **Step 4: Run focused tests to verify they pass**

  Run the command from Step 2. Expected: all existing TemplateSpawn materialization tests pass, including the new zero-side-effect assertion.

- [ ] **Step 5: Commit**

  ```bash
  git add apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex \
    apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs
  git commit -m "fix(agent): serialize same-uri template spawns"
  ```

### Task 2: Prove winner survival and failure-then-retry ordering

**Files:**
- Modify: `apps/ezagent_domain_agent/test/support/test_template_spawn.ex`
- Modify: `apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs`

**Interfaces:**
- Consumes: Task 1's `:agent_uri_already_live` result and `TestTemplateSpawn.hook/3`.
- Produces: deterministic two-process regressions that prove a queued request cannot observe partial creation or clean a winner's resources.

- [ ] **Step 1: Add a blocking post-profile test hook and write failing concurrency tests**

  Extend the support hook with a message-based `:block_after_display_profile` instruction: it sends the owner `{ :template_spawn_after_display_profile, agent_uri, status }`, waits for `:release_template_spawn`, and then returns either `:ok` or the configured injected failure.

  Start A with `Task.async`, wait for the hook message, then start B with the identical `instance_uri`. Before releasing A, assert B has not replied. Cover:

  ```elixir
  # A succeeds; B is rejected; A remains intact.
  assert {:ok, %{fresh?: true}} = Task.await(a)
  assert {:error, :agent_uri_already_live} = Task.await(b)

  # A fails after profile; B creates after A completes rollback.
  assert {:error, :injected_post_profile_failure} = Task.await(a)
  assert {:ok, %{fresh?: true}} = Task.await(b)
  ```

  Assert the success case retains profile, live Kind, workspace binding, active lineage, flavor/config and credential grant. Assert the retry case has B's active products and does not retain A-only active inventory/lineage; provenance is not asserted deleted.

- [ ] **Step 2: Run the new tests to verify the hook contract is absent**

  Run:

  ```bash
  MIX_ENV=test mix test apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs
  ```

  Expected: FAIL because the blocking hook instruction has not yet been
  implemented; this proves the regression needs deterministic hook support,
  not a production timing sleep.

- [ ] **Step 3: Implement only the deterministic test hook support**

  Add the hook branch described in Step 1; do not add production sleeps. The test owner controls release through a received message so the lock ordering is reproducible.

- [ ] **Step 4: Run focused and related TemplateSpawn suites**

  Run:

  ```bash
  MIX_ENV=test mix test apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs
  MIX_ENV=test mix test apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn
  ```

  Expected: all pass with no timing sleeps or flaky ordering assumptions.

- [ ] **Step 5: Commit**

  ```bash
  git add apps/ezagent_domain_agent/test/support/test_template_spawn.ex \
    apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs
  git commit -m "test(agent): cover same-uri spawn rollback"
  ```

### Task 3: Document and verify the final contract

**Files:**
- Modify: `docs/together/2026-07-24/returns/agent-display-name-profile.md`

**Interfaces:**
- Consumes: Task 1's conflict result and Task 2's passing race regressions.
- Produces: an auditable return record distinguishing local deterministic gates from full-suite status.

- [ ] **Step 1: Update return documentation**

  Record the exact same-URI behavior: A succeeds then B receives `:agent_uri_already_live`; A fails then B creates only after A's cleanup; provenance remains append-only. Remove the same-URI test from deferred follow-up.

- [ ] **Step 2: Run formatting and deterministic gates**

  Run:

  ```bash
  mix format --check-formatted
  MIX_ENV=test mix gate.arch
  ```

  Expected: zero formatting changes and all architecture suites pass.

- [ ] **Step 3: Run full suite if the existing pnpm approval environment is available**

  Run:

  ```bash
  mise exec node@22.23.1 -- mix ci.local
  ```

  Expected: pass. If it stops before tests at the existing `es5-ext` pnpm build-script approval policy, record that environment blocker without changing dependency policy.

- [ ] **Step 4: Commit and push only intended files**

  ```bash
  git add docs/together/2026-07-24/returns/agent-display-name-profile.md
  git commit -m "docs(return): verify same-uri spawn safety"
  git push --force-with-lease origin fix/agent-display-name-profile
  ```
