# T1 Materialize Recipe Behavior Fold Return

Date: 2026-07-07
Branch: `work/t1-materialize-behavior-fold`
Base: `origin/main` at `dcabf6174`

## Summary

Implemented the shared recipe behavior fold for agent materialization:

- Added `Ezagent.Agent.RecipeBehaviorFold.fold/2` in `ezagent_domain_agent` as the single recipe x flavor composition seam.
- Changed `Workspace.AgentCreate.RoleStep.resolve/2` to delegate to the shared fold, preserving the existing direct `agent_create --role` materialized shape.
- Changed `RecipeMaterializer.create_agent_from_recipe/1` to compute the composed behavior set and pass it as a `behavior_overlay` through the template spawn opts.
- Changed `Entity.Agent.TemplateSpawn` to mount the overlay only in the `fresh?: true` branch, after post-spawn obligations and sandbox state recording. Adopted/reused workers are not retrofitted.
- Left #1209 `HostLoginAdopt.ensure_installer_source/3` ordering untouched in `DefinitionAgents.materialize_fresh_agent/7`.

## Tests Added

- `definition_agents_materialize_test.exs`: fresh Definition-materialized member with a recipe-only behavior now dispatches the recipe action instead of surfacing `{:unknown_action, :ping}`.
- `agent_template_spawn_sandbox_materialization_test.exs`: overlay mounts on fresh workers, does not retrofit adopted workers, and invalid overlay mount rolls back the fresh worker.

## Verification

Local gates run in the isolated worktree:

- `mix format --check-formatted ...` PASS
- `mix compile --warnings-as-errors` PASS
- `mix ezagent.check_invariants` PASS
- `mix ezagent.arch.scan` PASS
- `MIX_ENV=test mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs apps/ezagent_domain_agent/test/ezagent/entity/agent_template_spawn_sandbox_materialization_test.exs apps/ezagent_domain_workspace/test/integration/create_role_agent_test.exs` PASS (`5 + 2 + 8 tests, 0 failures`)
- `MIX_ENV=test MIX_TEST_PARTITION=h2oslabs mix ci.local` PASS
  - Includes `mix precommit`, umbrella tests, `mix ezagent.check_invariants`, and `mix ezagent.socialware.check`.
- Final `mix ezagent.arch.scan` PASS

Remote branch and CI status are reported in the coordinator handback after push.
