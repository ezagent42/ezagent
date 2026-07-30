# Hello LLM Configuration and Errors Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Hello template LLM flavors selectable and preserve missing-key errors for actionable UI rendering.

**Architecture:** The World template component owns flavor selection and only sends curl-specific configuration for curl. The Hello generator owns error semantics and passes explicit credential errors into the existing World error-card registry unchanged.

**Tech Stack:** React/TypeScript, Elixir/ExUnit, existing World G5 error-card registry.

## Global Constraints

- Default Hello LLM flavor is `curl`.
- Expose only completion-capable registered flavors.
- Never persist API keys in a template role-slot configuration.
- Treat only `{:no_api_key, provider}` as a credential configuration failure.
- Keep unknown generation failures on the existing Layer 3 auto-registration path.
- Do not modify `DefinitionAgents`, credential cascade policy, agent readiness, or rollback.
- Do not stage unrelated pre-existing worktree changes.

---

### Task 1: Make the Hello flavor selector configurable

**Files:**
- Modify: `apps/ezagent_plugin_world/assets/src/components/WorkspacePlugin.tsx`
- Test: `apps/ezagent_plugin_world/assets/src/components/WorkspacePlugin.test.tsx`

**Interfaces:**
- Consumes: `WorkspacePluginState.agent_flavors` and the Hello LLM role slot.
- Produces: `role_slots` entry with selected `flavor`, plus `config` only for `curl`.

- [x] **Step 1: Write the failing component test**

Render the template builder with Hello and flavors `curl` and `cc-headless`; assert the Hello LLM selector exists, defaults to `curl`, and selecting `cc-headless` serializes that flavor without the curl provider/API/model config.

- [x] **Step 2: Run the frontend test to verify it fails**

Run: `cd apps/ezagent_plugin_world/assets && pnpm test WorkspacePlugin.test.tsx`

Expected: FAIL because the Hello component has no flavor selector and always writes `curl`.

- [x] **Step 3: Implement the minimal selector**

Pass the completion flavor list into `HelloLlmRoleSlot`, render a required select, retain curl defaults only for `curl`, and preserve the selected flavor in `installConfigForTemplate/2`.

- [x] **Step 4: Run the frontend test to verify it passes**

Run: `cd apps/ezagent_plugin_world/assets && pnpm test WorkspacePlugin.test.tsx`

Expected: PASS.

### Task 2: Preserve the missing-credential error reason

**Files:**
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/generator.ex`
- Test: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/generator_test.exs`

**Interfaces:**
- Consumes: generator result reason from `build_spec/5`.
- Produces: `TurnDriver.say_error/3` reason; explicit `{:no_api_key, provider}` is passed through and all other errors are wrapped as `{:generation_failed, reason}`.

- [x] **Step 1: Write the failing unit test**

Extract and test a pure `error_signal_reason/1` helper: assert `{:no_api_key, "deepseek"}` is returned unchanged and `{:http, 502, "bad gateway"}` is wrapped as `{:generation_failed, ...}`.

- [x] **Step 2: Run the focused test to verify it fails**

Run: `mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/generator_test.exs`

Expected: FAIL because the helper does not exist and current code wraps all failures.

- [x] **Step 3: Implement the minimal error normalization**

Add the pure private helper and call it at the one `TurnDriver.say_error/3` boundary in `generate_simple/4`.

- [x] **Step 4: Run focused tests to verify they pass**

Run: `mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/generator_test.exs apps/ezagent_plugin_world/test/ezagent/world/error_cards_test.exs`

Expected: PASS, including existing Layer 1/2 credential-card behavior.

### Task 3: Final verification and handoff

**Files:**
- Modify: the files from Tasks 1 and 2 only.

- [x] **Step 1: Format touched source files**

Run: `mix format apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/generator.ex apps/ezagent_plugin_hello/test/ezagent_plugin_hello/generator_test.exs`

- [x] **Step 2: Run project precommit**

Run: `mix precommit`

Result: the command was executed in the default and an isolated test partition.
The default partition is blocked by duplicate `entity://system/user/admin` test
data; the isolated run reaches existing Core architecture/invariant failures
outside this plan. Scoped World/Hello checks pass; see the SDD Task 3 report.

- [x] **Step 3: Review the final diff**

Run: `git diff --check && git diff -- apps/ezagent_plugin_world/assets/src/components/WorkspacePlugin.tsx apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/generator.ex`

Expected: no whitespace errors and only the planned behavior changes.
