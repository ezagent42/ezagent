# Template Member Roster Convergence Implementation Plan

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Report a template role as materialized only after its planned agent URI is visible in the session roster, including when CC transport lacks a credential or has not joined.

**Architecture:** Kind readiness and bridge availability become independent states. The existing member-cap and holder-authenticated session.add_self flow remains the only roster writer. DefinitionAgents waits for that projection; fresh failure compensation uses checked lifecycle rollback rather than a ready-gated sandbox destroy dispatch.

**Tech Stack:** Elixir, OTP, ReadyGate, TransportReadiness, RecipeMaterializer, ExUnit.

## Global Constraints

- DefinitionAgents alone supplies credential_optional and session_template_member for fresh template roles.
- A satisfied role requires role_name_to_uri(members, role_name) == planned_uri; a join :granted response is provisional.
- Do not add a direct Session roster write or a capability bypass.
- Bridge timeout must not mark an otherwise-live Kind not ready or failed.
- Ordinary custom-agent creation, unknown providers, malformed templates, and unscoped missing-key inputs remain fail-closed.
- Fresh rollback checks termination and tombstones only its binding version; reused agents are never terminated or tombstoned.
- Use Kind lifecycle rollback, never sandbox.destroy through normal dispatch, for a not-ready worker.
- Preserve unrelated worktree changes and run mix precommit at the end.

---

### Task 1: Separate transport status from Kind readiness

**Files:**
- Modify: apps/ezagent_domain_agent/lib/ezagent/agent/transport_readiness.ex
- Modify: apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent/spawn.ex
- Test: apps/ezagent_domain_agent/test/ezagent/agent/transport_readiness_test.exs

**Interfaces:**
- Consumes: TransportReadiness.require_transport_join/2 from CC spawn.
- Produces: a ReadyGate-ready Kind while transport_joined?/1 is false.

- [ ] **Step 1: Write failing readiness tests**

  Add tests which arm a transport record, set the fake Kind ready, and assert:

      assert Ezagent.ReadyGate.status(uri) == :ready
      refute TransportReadiness.transport_joined?(uri)

  Add a timeout test asserting await_transport_or_fail(uri) returns :ok and the ReadyGate remains :ready. Keep the stale-generation and late-join tests, but update them to assert transport-record cleanup rather than ReadyGate transitions.

- [ ] **Step 2: Prove RED**

  Run:

      mix test apps/ezagent_domain_agent/test/ezagent/agent/transport_readiness_test.exs

  Expected: current code sets ReadyGate to :not_ready and marks it failed after timeout.

- [ ] **Step 3: Implement transport-only tracking**

  In TransportReadiness, remove all ReadyGate.put(..., :not_ready), ReadyTransition.drain_pending_then_mark_ready_locked/2, and ReadyTransition.mark_failed_locked/1 calls. Keep ETS generation, incarnation checks, bridge-registry truth, listener timeout cancellation, and stale-record cleanup. A timeout clears the generation and returns :ok; a bridge join clears the matching generation only. Update the module documentation accordingly.

  Keep CcAgent.Spawn.require_transport_join/1 as the non-blocking record producer; it must not introduce another Kind readiness gate.

- [ ] **Step 4: Prove GREEN**

      mix test apps/ezagent_domain_agent/test/ezagent/agent/transport_readiness_test.exs

  Expected: every generation/incarnation safety test passes and an unavailable bridge leaves the Kind ready.

- [ ] **Step 5: Commit**

      git add apps/ezagent_domain_agent/lib/ezagent/agent/transport_readiness.ex apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent/spawn.ex apps/ezagent_domain_agent/test/ezagent/agent/transport_readiness_test.exs
      git commit -m "fix(agent): separate transport status from kind readiness"

### Task 2: Confirm member-cap roster convergence before success

**Files:**
- Modify: apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex
- Test: apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs

**Interfaces:**
- Consumes: SessionBehavior.role_name_to_uri/2 and a planned role URI.
- Produces: a satisfied role only after the roster maps its role name to that exact URI; otherwise {:error, {:agent_membership_convergence_failed, role_name, reason}, partial}.

- [ ] **Step 1: Write failing membership invariant tests**

  Replace the never-ready expectation that a successful role is absent from the roster. Use a bridge-unavailable but ReadyGate-ready template role and assert:

      assert {:ok, %{satisfied: [^role_name], skipped: []}} = materialize(...)
      assert eventually(fn ->
        SessionBehavior.role_name_to_uri(members_of(session_uri), role_name) == planned_uri
      end)
      assert Ezagent.ReadyGate.status(planned_uri) == :ready
      refute transport_joined?(planned_uri)

  Add a convergence-timeout double and assert its role is absent from satisfied and returns :agent_membership_convergence_failed.

- [ ] **Step 2: Prove RED**

      mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs

  Expected: existing code returns after session.join reports :granted, before the roster projection exists.

- [ ] **Step 3: Add bounded confirmation**

  Add a private await_role_member(session_uri, planned_uri, role_name) helper with 100 attempts and 10 ms sleep. Each attempt reads members_of(session_uri) and succeeds only when role_name_to_uri equals planned_uri; timeout returns {:error, :membership_convergence_timeout}.

  Call it after join_or_cleanup/4 for fresh roles and after Participants.add_participant/2 for reuse. Wrap failures as {:agent_membership_convergence_failed, role_name, reason}. Do not dispatch session.add_self as admin and do not alter the member-cap authorization path.

- [ ] **Step 4: Prove GREEN**

      mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs

  Expected: a keyless, bridge-unavailable role is visible in the roster; a non-convergent role is never satisfied.

- [ ] **Step 5: Commit**

      git add apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs
      git commit -m "fix(session): confirm template member roster convergence"

### Task 3: Roll back failed fresh roles without readiness dependence

**Files:**
- Modify: apps/ezagent_domain_agent/lib/ezagent/agent/recipe_materializer.ex
- Modify: apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn/rollback.ex
- Modify: apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex
- Test: apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs

**Interfaces:**
- Consumes: fresh spawn receipt and RecipeCapBinding version.
- Produces: {:ok, :retired} only after Kind termination, workspace unbind, lineage cleanup, config-dir cleanup, and version-checked binding tombstone.

- [ ] **Step 1: Write failing compensation tests**

  Make a fresh template role fail after spawn at bind, join, and convergence. For each assert:

      assert eventually(fn -> Ezagent.KindRegistry.lookup(planned_uri) == :error end)
      assert :not_found = RecipeCapBinding.fetch(planned_uri)
      assert {:error, :not_found} = Ezagent.AgentLineage.lookup(planned_uri)
      refute File.exists?(Ezagent.Sandbox.ConfigDir.path(planned_uri, namespace))

  Add a reused-agent join failure regression proving its process and active binding remain.

- [ ] **Step 2: Prove RED**

      mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs

  Expected: current sandbox.destroy compensation can report success while a not-ready worker survives.

- [ ] **Step 3: Expose one receipt-based rollback API**

  Add RecipeMaterializer.rollback_fresh_agent/2 accepting only a fresh spawn receipt, not reconstructed caller data. The receipt carries URI, template class, config metadata, workspace, and lineage facts from template spawn. Delegate mechanics to TemplateSpawn.Rollback so it uses checked Kind.terminate!, WorkspaceRegistry.unbind, template-class destroy_config_dir/2, and lineage cleanup.

  Keep the fresh receipt through DefinitionAgents.spawn_agent and spawn_bound_agent. On bind, sync, join, or convergence failure: tombstone RecipeCapBinding with the attempt version; invoke rollback only for a fresh receipt; preserve the original materialization error and include a rollback failure if cleanup cannot be confirmed. Reused roles run neither operation.

- [ ] **Step 4: Prove GREEN**

      mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs
      mix test apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn

  Expected: fresh failures leave no live worker or durable residue; reused workers remain unchanged.

- [ ] **Step 5: Commit**

      git add apps/ezagent_domain_agent/lib/ezagent/agent/recipe_materializer.ex apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn/rollback.ex apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs
      git commit -m "fix(session): roll back failed fresh role materialization"

### Task 4: Verify scoped custom-provider respawn data

**Files:**
- Modify: apps/ezagent_plugin_cc/lib/ezagent/template/cc_custom_agent.ex
- Modify: apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_custom_agent.ex
- Test: apps/ezagent_plugin_cc/test/ezagent/template/cc_custom_backend_test.exs

**Interfaces:**
- Consumes: sandbox respawn_template_data with exact string-key session_template_member true.
- Produces: scoped keyless restart environment without ANTHROPIC_AUTH_TOKEN; unflagged restart still returns backend_api_key_missing.

- [ ] **Step 1: Write failing sandbox-state tests**

  For PTY and headless custom templates, instantiate scoped keyless content, inspect the sandbox slice, and assert:

      assert sandbox.respawn_template_data["session_template_member"] == true
      assert {:ok, env} = Provider.provider_env(sandbox.respawn_template_data)
      refute Map.has_key?(env, "ANTHROPIC_AUTH_TOKEN")

  Remove the flag in copied data and assert Provider.provider_env/1 returns {:error, {:backend_api_key_missing, "deepseek"}}.

- [ ] **Step 2: Prove RED**

      mix test apps/ezagent_plugin_cc/test/ezagent/template/cc_custom_backend_test.exs

  Expected: current serializer-only coverage does not prove the persisted sandbox respawn value.

- [ ] **Step 3: Preserve exact flag and update docs**

  Ensure both normal PTY and headless metadata paths place the exact string-key boolean in respawn_template_data. Do not widen Provider.session_template_member?/1. Update the two moduledocs so they state the scoped exception to otherwise strict missing-key validation.

- [ ] **Step 4: Prove GREEN and commit**

      mix test apps/ezagent_plugin_cc/test/ezagent/template/cc_custom_backend_test.exs
      git add apps/ezagent_plugin_cc/lib/ezagent/template/cc_custom_agent.ex apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_custom_agent.ex apps/ezagent_plugin_cc/test/ezagent/template/cc_custom_backend_test.exs
      git commit -m "test(cc): cover scoped member respawn data"

### Task 5: Run the complete invariant gate

**Files:**
- Modify: docs/superpowers/specs/2026-07-28-template-member-roster-convergence-design.md only if implementation changes a documented interface.
- Modify: docs/superpowers/plans/2026-07-28-template-member-roster-convergence.md only to record completed tasks after review.

- [ ] **Step 1: Run all contract suites**

      mix test apps/ezagent_domain_agent/test/ezagent/agent/transport_readiness_test.exs apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs apps/ezagent_plugin_cc/test/ezagent/template/cc_custom_backend_test.exs

  Expected: bridge-unavailable roles are roster members, ordinary providers fail closed, and fresh-role failure removes all artifacts.

- [ ] **Step 2: Format and verify**

      mix format apps/ezagent_domain_agent/lib/ezagent/agent/transport_readiness.ex apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent/spawn.ex apps/ezagent_domain_agent/lib/ezagent/agent/recipe_materializer.ex apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn/rollback.ex apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex apps/ezagent_plugin_cc/lib/ezagent/template/cc_custom_agent.ex apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_custom_agent.ex apps/ezagent_domain_agent/test/ezagent/agent/transport_readiness_test.exs apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs apps/ezagent_plugin_cc/test/ezagent/template/cc_custom_backend_test.exs
      mix precommit
      git diff --check

  Expected: every command exits 0 and git diff --check has no output.

- [ ] **Step 3: Commit documentation**

      git add docs/superpowers/specs/2026-07-28-template-member-roster-convergence-design.md docs/superpowers/plans/2026-07-28-template-member-roster-convergence.md
      git commit -m "docs(session): verify template member convergence"
