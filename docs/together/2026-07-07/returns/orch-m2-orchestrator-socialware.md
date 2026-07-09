# orch-m2 orchestrator socialware return

Date: 2026-07-07
Branch: `work/m2-orchestrator-socialware`
Base: `origin/main` at `3b1782bd9`

## Summary

Implemented M2 orchestrator-as-socialware:

- Moved the 13 stock orchestrator MCP tool registrations to the cc orchestrator recipe contribution surface while leaving the domain tool implementations in place.
- Added the built-in `orchestrator` socialware Definition using plugin `cc`, role `orchestrator`, recipe `orchestrator`, flavor `cc`, and no socialware views or routing rules.
- Changed the default SessionTemplate seed to install `["chat", "orchestrator"]` and stopped hard-coding an orchestrator member into the template.
- Retired `ensure_orchestrator/3` into a compat shim that runs under the create-session `:global` lock, adopts legacy planned orchestrators into the Definition member model, and otherwise delegates new creation to the standard socialware materialization path.
- Added the orchestrator-specific post-materialization hook for scoped delegation capabilities and MCP context registration.

## Tests Added Or Updated

- `orchestrator_recipe_recipe_test.exs`: verifies the 13 tool contributions and catalog alignment.
- `installation_test.exs`: verifies the built-in orchestrator Definition shape.
- `default_session_template_seed_test.exs`: verifies default installs are `chat` plus `orchestrator` with no hard-coded members.
- `definition_agents_materialize_test.exs`: covers Definition e2e materialization, scoped caps, and legacy orchestrator adoption.
- `session_create_orchestrator_decouple_test.exs`: updates default-session expectations for Definition-born orchestrators.

## Verification

Local gates run in the isolated worktree:

- `mix test apps/ezagent_plugin_cc/test/ezagent/orchestrator/orchestrator_recipe_recipe_test.exs apps/ezagent_domain_session/test/ezagent/socialware/installation_test.exs apps/ezagent_domain_session/test/integration/default_session_template_seed_test.exs apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs apps/ezagent_domain_session/test/integration/session_create_orchestrator_decouple_test.exs apps/ezagent_domain_session/test/integration/session_template_materialize_test.exs apps/ezagent_domain_session/test/integration/session_survives_restart_test.exs` PASS (`50 tests, 0 failures`)
- `mix test apps/ezagent_core/test/ezagent/agent/recipe/compose_test.exs apps/ezagent_core/test/invariants/no_recipe_sense_role_test.exs apps/ezagent_core/test/architecture/doc_coverage_test.exs` PASS (`23 tests, 0 failures`)
- `mix test apps/ezagent_plugin_cc/test/ezagent/template/orchestrator_recipe_install_test.exs apps/ezagent_plugin_cc/test/integration/socialware_cc_credential_inherit_test.exs` PASS (`13 tests, 0 failures`)
- `mix precommit` PASS

Conflicts/blockers: none.
