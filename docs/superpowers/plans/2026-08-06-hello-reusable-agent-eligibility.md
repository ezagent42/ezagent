# Hello Reusable Agent Eligibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow Hello to reuse any caller-authorized, authenticated Agent with the selected flavor, while preserving same-workspace-by-default isolation and producing user-facing error messages.

**Architecture:** `ReusableLlmAgent` will stop treating `hello.llm` as an eligibility marker. It will continue to validate Agent URI, workspace membership, caller management authority, exact flavor, and credential readiness. Hello installation will read the selected Agent's durable flavor configuration so provider/model/API URL intent is preserved; cross-workspace reuse remains a separate explicit authorization seam and is not enabled implicitly by this change.

**Tech Stack:** Elixir 1.19, Phoenix LiveView, Ecto/PostgreSQL, ExUnit, existing Agent/Capability/URI APIs.

## Global Constraints

- Preserve CapBAC and workspace isolation; do not bypass `Ezagent.Invocation.dispatch/1` or introduce implicit cross-workspace authority.
- Use `Ezagent.Kind.read/3` with `spawn: :never` or `Ezagent.Kind.read_durable/3` for non-activating Agent configuration reads.
- Keep flavor-specific provider configuration in the selected Agent's durable slices; do not hard-code DeepSeek for reusable curl Agents.
- Keep Phoenix UI forms and error rendering compatible with the existing LiveView contracts.
- Run focused tests first, then `mix precommit` before completion.

### Task 1: Change reusable-agent eligibility contract

**Files:**
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/reusable_llm_agent.ex`
- Test: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/reusable_llm_agent_test.exs`

- [ ] **Step 1: Replace the recipe-gated test with a recipe-independent test**

  Change the existing exact-recipe test so a persisted Agent with no recipe but matching flavor and authenticated credentials is accepted. Retain a negative assertion for a flavor mismatch.

- [ ] **Step 2: Run the focused test and verify it fails**

  Run `mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/reusable_llm_agent_test.exs --only test`. Expected failure: the current `validate_recipe/1` returns `{:error, {:recipe_mismatch, nil}}`.

- [ ] **Step 3: Remove recipe validation from `ReusableLlmAgent.validate/4`**

  Delete the `RecipeAttributes` alias, `@recipe`, `validate_recipe/1`, and the recipe step from the `with` chain. Keep list discovery based on Agent existence plus the remaining eligibility checks.

- [ ] **Step 4: Run the focused test and verify it passes**

  Run `mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/reusable_llm_agent_test.exs`. Expected: all reusable-agent tests pass after updating the obsolete recipe-specific expectations.

### Task 2: Preserve selected Agent configuration during Hello installation

**Files:**
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex`
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/template/hello_session.ex`
- Test: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/template/hello_session_test.exs`

- [ ] **Step 1: Add a failing test for reusable curl configuration**

  Seed a curl Agent whose durable `:curl_agent` slice uses a non-default provider/model/API URL, then assert the Hello installation receives that selected configuration rather than `App.llm_provider_config/1`'s fixed DeepSeek value.

- [ ] **Step 2: Run the focused test and verify it fails**

  Run `mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/template/hello_session_test.exs --only reusable`. Expected failure: the current install config hard-codes `%{provider: "deepseek"}`.

- [ ] **Step 3: Add a non-activating selected-agent configuration reader**

  Read the selected Agent's durable `:curl_agent` slice and return its provider, API URL, and model fields. Use the existing slice readers and return a typed error when the required flavor slice is unavailable. Thread this configuration through `llm_create_opts/2` and the Hello install content.

- [ ] **Step 4: Run the focused Hello tests and verify they pass**

  Run `mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/template/hello_session_test.exs`. Expected: reusable selection, installation, and existing Hello tests pass.

### Task 3: Make Hello errors user-readable

**Files:**
- Modify: `apps/ezagent_web/lib/ezagent_web/live/home_live.ex`
- Test: `apps/ezagent_web/test/ezagent_web/live/home_live_test.exs`

- [ ] **Step 1: Add failing LiveView assertions for mapped errors**

  Submit the first-session form without an Agent and assert the rendered `#hello-wizard-error` contains a user-facing explanation, not `:llm_agent_required`. Add coverage for no eligible Agent and invalid/stale Agent selection.

- [ ] **Step 2: Run the focused LiveView test and verify it fails**

  Run `mix test apps/ezagent_web/test/ezagent_web/live/home_live_test.exs`. Expected failure: the current UI renders `Create failed: :llm_agent_required`.

- [ ] **Step 3: Add a centralized reason-to-copy mapper**

  Map expected Hello creation errors to concise actionable text, preserve safe generic fallback behavior, and render the mapped text in `#hello-wizard-error`. Do not expose URIs, credentials, or raw structs in user-facing output.

- [ ] **Step 4: Run the focused LiveView test and verify it passes**

  Run `mix test apps/ezagent_web/test/ezagent_web/live/home_live_test.exs` and confirm the key DOM IDs are used in assertions.

### Task 4: Verify the integrated behavior

**Files:**
- No source changes expected unless a focused test exposes a contract mismatch.

- [ ] **Step 1: Run the Hello and workspace focused suites**

  Run `mix test apps/ezagent_plugin_hello/test apps/ezagent_web/test/ezagent_web/live/home_live_test.exs apps/ezagent_domain_workspace/test/integration/create_session_dispatch_test.exs`.

- [ ] **Step 2: Check formatting and repository status**

  Run `mix format --check-formatted` for touched Elixir files and `git diff --check`; confirm no unrelated files changed.

- [ ] **Step 3: Run the required project gate**

  Run `mix precommit` and fix only issues caused by this change.

- [ ] **Step 4: Report the resulting eligibility contract**

  State clearly that recipe is no longer required, same-workspace remains the default boundary, and cross-workspace reuse still requires a future explicit authorization path.
