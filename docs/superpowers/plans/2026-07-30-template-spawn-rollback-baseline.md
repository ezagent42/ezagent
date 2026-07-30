# Template Spawn Rollback Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore the three template-spawn rollback tests that fail identically on current main without weakening fail-loud cleanup.

**Architecture:** Normalize the injected hook's tagged error at the existing obligation boundary. Keep rollback's compound-error contract intact and make the fallback test template honor the config-directory lifecycle it opts into.

**Tech Stack:** Elixir, ExUnit, Phoenix umbrella Mix tasks.

## Global Constraints

- Preserve `{:error, {primary_reason, rollback_reason}}` whenever rollback is incomplete.
- Do not change CapBAC, capability convergence, production template callback types, or unrelated tests.
- Use the existing failing tests as the RED evidence before implementation.
- Run commands with a fresh `MIX_TEST_PARTITION`.

---

### Task 1: Normalize post-profile hook errors

**Files:**
- Modify: `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn.ex`
- Test: `apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs`

**Interfaces:**
- Consumes: `test_hook_after_display_profile/2 :: :ok | {:error, term()}`
- Produces: `establish_fresh_spawn_obligations/7` returning `{:error, reason, receipts}` with an untagged `reason`

- [ ] **Step 1: Run the two existing post-profile tests and verify RED**

Run:

```bash
MIX_TEST_PARTITION=spawnrollback mix test apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs:381 apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs:449
```

Expected: both assertions fail because actual output contains
`{:error, {:error, :injected_post_profile_failure}}`.

- [ ] **Step 2: Implement minimal tagged-result normalization**

Replace the boolean-style hook check with:

```elixir
case test_hook_after_display_profile(instance_uri, profile_status) do
  :ok -> {:ok, receipts}
  {:error, reason} -> {:error, reason, receipts}
end
```

- [ ] **Step 3: Run the two tests and verify GREEN**

Run the Step 1 command.

Expected: 2 tests, 0 failures.

### Task 2: Make the fallback fixture clean its owned directory

**Files:**
- Modify: `apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs`

**Interfaces:**
- Consumes: `Ezagent.Kind.Template.destroy_config_dir/2`
- Produces: `FallbackSandboxTemplate.destroy_config_dir/2 :: :ok | {:error, term()}`

- [ ] **Step 1: Run the existing behavior-overlay rollback test and verify RED**

Run:

```bash
MIX_TEST_PARTITION=spawnrollback mix test apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs:802
```

Expected: failure contains
`{:fresh_spawn_rollback_incomplete, [{:config_dir_destroy_unsupported, FallbackSandboxTemplate}]}`.

- [ ] **Step 2: Add the minimal safe cleanup callback to the fixture**

Implement `destroy_config_dir/2` so it accepts a `%URI{}`, verifies that the
provided path equals `Ezagent.Sandbox.ConfigDir.path(agent_uri, config_dir_namespace())`,
removes that path with `File.rm_rf/1`, and returns `:ok`; invalid paths return
`{:error, :config_dir_path_mismatch}`.

- [ ] **Step 3: Run the overlay test and verify GREEN**

Run the Step 1 command.

Expected: 1 test, 0 failures.

- [ ] **Step 4: Run the complete regression file**

Run:

```bash
MIX_TEST_PARTITION=spawnrollback mix test apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs
```

Expected: 22 tests, 0 failures.

- [ ] **Step 5: Verify and commit**

Run:

```bash
mix format --check-formatted
MIX_TEST_PARTITION=spawnrollback mix compile --warnings-as-errors
git diff --check
```

Review `git diff` and `git diff --cached`, then commit with:

```text
fix(agent): restore template spawn rollback baseline
```

### Task 3: Full branch validation

**Files:**
- No intended source changes.

**Interfaces:**
- Consumes: committed Task 1–2 branch
- Produces: merge evidence

- [ ] **Step 1: Run project precommit**

Run:

```bash
MIX_TEST_PARTITION=spawnrollbackfull mix precommit
```

Expected: exit 0.

- [ ] **Step 2: Record exact test counts, warnings, and commit SHA**

Write the evidence into the task report and return artifact. Do not claim
success unless the command completed with exit 0.
