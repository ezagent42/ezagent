# Hello Two-Agent Materialization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep only Hello's `front-desk` and selected-flavor `llm` as platform-materialized agents while preserving build, answer, share, publish, and Kanban delegation.

**Architecture:** Add a Hello-specific Session Lifecycle ActionSet to the Hello Definition's `shape`; it owns five deterministic actions and delegates slow generation to the existing supervised generator. The front-desk remains the only chat-delivery agent and dispatches those actions on the Session; the LLM remains the only provider/credential/PTY-backed agent.

**Tech Stack:** Elixir, Ezagent Lifecycle, Session Definition installation, CapBAC dispatch, ExUnit.

## Global Constraints

- Agent creation remains exclusively in Ezagent's `SessionCreator.DefinitionAgents` platform materializer.
- No new URI scheme or direct Kind spawn from plugin code.
- All new developer behavior code uses `Ezagent.Lifecycle`.
- The LLM agent remains flavor-agnostic and owns provider credentials and bridge lifecycle.
- Session action authorization stays at the dispatch chokepoint; Router's owner/visitor routing remains the product policy.

---

### Task 1: Establish the two-agent definition contract

**Files:**
- Modify: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/registration_test.exs`
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex`
- Modify: `apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml`

**Interfaces:**
- Produces `EzagentPluginHello.Application.roles/0` containing only `hello.front-desk` and `hello.llm`.
- Produces a Hello Definition whose only `fill: agent` roles are `front-desk` and `llm`.

- [ ] Write a failing registration assertion that the role recipes are exactly front-desk and llm, and that the Definition's agent slots are exactly those two names.
- [ ] Run `mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/registration_test.exs` and confirm it fails because legacy local-role recipes and slots remain.
- [ ] Remove the five local-role recipes from `roles/0`; keep `hello_front_desk_recipe/0` and `hello_llm_recipe/0`; change the Hello manifest to declare only those two agent slots.
- [ ] Re-run the registration test and confirm it passes.

### Task 2: Host deterministic Hello operations on Session

**Files:**
- Create: `apps/ezagent_plugin_hello/lib/ezagent/behavior/hello_session_actions.ex`
- Create: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/hello_session_actions_test.exs`
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/application.ex`

**Interfaces:**
- Produces `Ezagent.ActionSet.HelloSessionActions` with actions `:rebuild`, `:answer`, `:share`, `:publish`, and `:delegate_to_kanban`.
- The module receives `%{session_uri: string, instruction/text/sender_uri: string}` and returns an empty result after scheduling or completing the existing service operation.
- The Hello Definition `shape` includes `HelloSessionActions`, making the actions dispatchable on `Ezagent.Entity.Session`.

- [ ] Write failing unit tests for the five public action declarations and invalid-argument no-op/error paths.
- [ ] Run the new test file and confirm it fails because the ActionSet does not exist.
- [ ] Implement the Lifecycle ActionSet by moving the active handler logic from `HelloBuilder`, `HelloConcierge`, `HelloSharer`, `HelloPublisher`, and `HelloDispatcher`; pass the front-desk URI as the result actor where narration requires an agent URI.
- [ ] Add the ActionSet to the dynamic Hello Definition `shape` and the shipped manifest `shape`.
- [ ] Re-run the new test file and confirm it passes.

### Task 3: Retarget front-desk routing to the Session

**Files:**
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/router.ex`
- Modify: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/router_test.exs`
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/generator.ex`

**Interfaces:**
- `Router` dispatches `HelloSessionActions` actions against `session_uri`, not `Members.role_uri/2` worker agents.
- `Generator` accepts an explicit narration actor or resolves `front-desk` for generated page narration; it does not require a builder member.

- [ ] Write a failing router regression asserting only front-desk outbound is excluded from re-routing and that a selected operation targets the session action.
- [ ] Run the router test and confirm it fails because worker-role membership and agent targets are still required.
- [ ] Replace worker-member lookup with front-desk loop protection; map route intent to the Session action namespace and keep the existing signed-cap trusted dispatch envelope.
- [ ] Refactor builder narration lookup so it resolves front-desk rather than builder and preserves visible completion messages.
- [ ] Re-run router and generator-focused tests and confirm they pass.

### Task 4: Update integration coverage and remove obsolete agent-only tests

**Files:**
- Modify: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/template/hello_session_test.exs`
- Modify: `apps/ezagent_plugin_hello/test/integration/hello_page_e2e_test.exs`
- Modify or delete: agent-role-specific tests for builder, concierge, sharer, publisher, and dispatcher.

**Interfaces:**
- A materialized Hello session has exactly `front-desk` and `llm` agent role members.
- Build, answer, share, publish, and delegation are exercised through Session actions.

- [ ] Write a failing integration assertion that the materialized member role set is exactly `MapSet.new(["front-desk", "llm"])`.
- [ ] Run the focused Hello template/integration tests and confirm the assertion fails under the seven-role definition.
- [ ] Update the tests to dispatch Session actions and assert the same product outcomes: Surface update for build, no Surface update for answer, customer-visible share/publish/delegation responses.
- [ ] Delete tests that only assert the retired five agent recipes or their agent-scoped handlers.
- [ ] Re-run the focused Hello test set and confirm it passes.

### Task 5: Verify and document the migration

**Files:**
- Modify: `docs/together/2026-07-28/returns/hello-template-llm.md`

- [ ] Run `mix format` for touched Elixir/test files and `mix test` for every changed Hello test file.
- [ ] Run `mix precommit` with the isolated test database available; record any environment limitation precisely if it cannot finish.
- [ ] Update the return document with two-agent evidence, test commands/results, PR state, and remaining CI status.
