# PR 1651 CI Architecture Gate Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the four PR 1651 `mix ci.fast` architecture failures pass without weakening their invariants or changing session credential-isolation behavior.

**Architecture:** Keep each CI gate attached to its original contract. Point the recipe-cap source test at both extracted owner modules, ratchet the dynamic-receiver baseline down after assertive access replaced legacy access, and mark extracted cross-module seams explicitly internal while documenting World-facing APIs.

**Tech Stack:** Elixir 1.19, ExUnit, source-AST architecture tests, Mix documentation scanner.

## Global Constraints

- Do not delete or relax architecture assertions.
- Do not increase the `undocumented_public_defs` baseline.
- Do not change credential/session runtime semantics.
- Preserve all pre-existing worktree changes.
- Do not run local `mix precommit`; use targeted tests and `mix ci.fast`.
- Do not create implementation commits from files containing pre-existing PR changes.

---

### Task 1: Follow extracted recipe-cap lifecycle ownership

**Files:**
- Modify: `apps/ezagent_core/test/invariants/recipe_cap_binding_invariant_test.exs`

**Interfaces:**
- Consumes: private lifecycle functions found by the test's existing AST `definition_source/3` scanner.
- Produces: the same spawn → bind → sync → join and rollback ordering guarantees across `definition_agents.ex` and `definition_agent_lifecycle.ex`.

- [ ] **Step 1: Verify the existing regression test is red**

Run:

```bash
mise exec -- mix test apps/ezagent_core/test/invariants/recipe_cap_binding_invariant_test.exs
```

Expected: two failures reporting `spawn_bound_agent/8` and `refresh_existing_binding/4` missing from `definition_agents.ex`.

- [ ] **Step 2: Point each assertion at its owning source file**

Add a lifecycle path attribute and use it for `spawn_bound_agent/8`, `finish_spawned_agent/8`, `rollback_failed_fresh/5`, and `refresh_existing_binding/4`. Keep `materialize_fresh_agent/6` and `reuse_existing_agent/6` attached to `definition_agents.ex`. Concatenate both source files for whole-materializer assertions such as the absence of direct worker termination and the presence of `RecipeCapBinding.issue_and_upsert`.

- [ ] **Step 3: Verify the invariant is green**

Run the Step 1 command again.

Expected: `6 tests, 0 failures`.

### Task 2: Ratchet the reviewed dynamic-receiver census downward

**Files:**
- Modify: `apps/ezagent_core/test/support/legacy_dynamic_receiver_baseline.ex`

**Interfaces:**
- Consumes: the exact `{path, function, kind, accessor, sha256}` census produced by `PluginWorkspaceLocalityContractTest`.
- Produces: a baseline containing no entries for the 12 accesses removed from `Ezagent.World.ErrorRenderer` by assertive `Map.fetch!/2` and intentional optional `Map.get/3` calls.

- [ ] **Step 1: Verify the census test is red and record the set difference**

Run:

```bash
mise exec -- mix test apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs:146
```

Expected: the actual census has no additions and is missing 12 obsolete `error_renderer.ex` baseline fingerprints.

- [ ] **Step 2: Remove only the 12 obsolete fingerprints**

Delete the `error_renderer.ex` entries for `layer1_card/1`, `layer2_card/2`, `layer3_fallback/2`, `register_issue/2`, and the two guard entries. Preserve the still-current `push_dispatch_error_card/3` fingerprint.

- [ ] **Step 3: Verify the ratcheted census is green**

Run the Step 1 command again.

Expected: `1 test, 0 failures` with two excluded tests.

### Task 3: Classify the 34 extracted public functions

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/agent_admission_reconciliation.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/agent_admission_state.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agent_lifecycle.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agent_support.ex`
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/admission_projection.ex`
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/agent_admission_actions.ex`
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex`

**Interfaces:**
- Consumes: 34 new public definitions reported by `Mix.Tasks.Ezagent.Doc.Scan.offenders/0`.
- Produces: explicit `@doc false` decisions for internal cross-module seams and useful `@doc` text for World-facing projection/action APIs.

- [ ] **Step 1: Verify the documentation gate is red**

Run:

```bash
mise exec -- mix test apps/ezagent_core/test/architecture/doc_coverage_test.exs:21
```

Expected: `undocumented_public_defs` measures 440 against cap 406.

- [ ] **Step 2: Mark session-creator seams internal**

Add `@doc false` immediately before each of the 28 newly exported definitions in the four `@moduledoc false` session-creator modules. Do not change their visibility or implementation because they are required across extracted module boundaries.

- [ ] **Step 3: Document World-facing APIs**

Add real `@doc` descriptions for `AdmissionProjection.list/1`, the four `AgentAdmissionActions` entry points, and `ConversationData.agent_admissions/1` before its `defdelegate`.

- [ ] **Step 4: Verify the documentation ratchet returns to its existing cap**

Run:

```bash
mise exec -- mix ezagent.doc.scan
mise exec -- mix test apps/ezagent_core/test/architecture/doc_coverage_test.exs:21
```

Expected: `undocumented_public_defs: count=406 cap=406` and the test passes.

### Task 4: Format and review all repaired gates

**Files:**
- Review all files modified in Tasks 1–3.

**Interfaces:**
- Consumes: the three independently green architecture repairs.
- Produces: formatter-clean changes and a final CI result.

- [ ] **Step 1: Format only touched Elixir files**

Run `mise exec -- mix format` with the exact file paths modified in Tasks 1–3.

- [ ] **Step 2: Run all affected gates together**

Run:

```bash
mise exec -- mix test \
  apps/ezagent_core/test/invariants/recipe_cap_binding_invariant_test.exs \
  apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs \
  apps/ezagent_core/test/architecture/doc_coverage_test.exs
```

Expected: all selected tests pass.

- [ ] **Step 3: Run the requested final review**

Run:

```bash
mise exec -- mix ci.fast
```

Expected: exit status 0. If another failure appears, stop and report it without expanding scope.

- [ ] **Step 4: Review the patch boundary**

Run:

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; only the intended additions are attributed to this repair, while all pre-existing PR files remain preserved.
