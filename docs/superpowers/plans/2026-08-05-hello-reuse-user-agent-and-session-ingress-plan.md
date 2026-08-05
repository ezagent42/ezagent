# Hello User-Agent Reuse and Session Ingress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox syntax for tracking.

**Goal:** Reuse a caller-selected LLM agent, remove front-desk, and route Hello messages through a Session ingress.

**Architecture:** Add a generic persisted ingress declaration. Session dispatches it with a narrow self capability and excludes protected internal roles from mention fan-out. Hello declares only llm; creation preflights and freezes a reused agent URI in its install config.

## Constraints

- Generic layers contain no Hello branch.
- Selected URI is session-install data, never manifest data.
- Eligible credential states: authenticated or expiring for credential flavors; n_a for credentialless flavors. Missing, expired, unknown reject.
- Preflight rejects before persistence. A later race leaves an explicit unfilled llm role and never fresh-spawns.
- Reuse may be multi-session; removal is membership-only.
- An at-mention of llm reaches ingress only, never agent.receive.

### Task 1: Definition ingress contract

**Files:** definition.ex, manifest_yaml.ex, conformance.ex and their Definition/YAML tests.

- [ ] Add Definition.ingress as nil or %{behavior: module, action: atom, protected_roles: [String.t()]}; persist it, render it in canonical YAML, and validate behavior, action, and declared protected roles.
- [ ] Write red tests for valid YAML round trip and unknown behavior/action/role rejection; run the two focused test files, implement, rerun, then commit feat(session): declare validated socialware ingress.

### Task 2: Generic ingress delivery and mention isolation

**Files:** behavior/session.ex, behavior/session/delivery.ex, definition_editor.ex, chat_test.exs, mention_gated_routing_test.exs.

- [ ] Materialize ingress into the Session working copy. After MessageStore.write, self-dispatch its declared action with %{message: stored_msg, session_uri: session_uri} and a target-issued capability limited to that action.
- [ ] Filter recipients corresponding to protected_roles before fan-out. Test one ingress call, zero direct agent.receive for at-llm, and unchanged non-protected mention delivery. Commit feat(session): dispatch declared ingress before member fan-out.

### Task 3: Reusable LLM candidate API and preflight

**Files:** create reusable_llm_agent.ex; modify hello_session.ex and app.ex; add reusable_llm_agent_test.exs and extend hello_session_test.exs.

- [ ] Implement list(caller, workspace, flavor) and validate(caller, workspace, flavor, agent_uri). Require Manage authority, hello.llm recipe, exact flavor/provider profile, and the eligibility policy.
- [ ] Accept llm_flavor plus llm_agent_uri in session.hello, synchronously validate before App.create_app, then freeze role_slots llm with install_mode reuse and reuse_agent_uri. Test all App.llm_flavors, status cases, authority and stale URI. Commit feat(hello): preflight reusable LLM agents.

### Task 4: Race-safe, multi-session reuse

**Files:** definition_agents.ex, definition_agents_materialize_test.exs, socialware_reuse_bind_test.exs.

- [ ] Revalidate the generic role contract immediately before reuse join. A race returns an unfilled role reason; it never calls fresh materialization.
- [ ] Test revoke after preflight, two sessions using one agent, removal of session A preserving B and the agent, and no fresh receipt. Commit fix(session): preserve reused agents across installs and removal.

### Task 5: Hello ingress and front-desk removal

**Files:** hello manifest, Hello application, hello_session_actions, router, generator, turn_driver, Hello integration tests; delete hello_orchestrator and bridge_adapter.

- [ ] Declare ingress to HelloSessionActions.route_inbound and retain only llm role. Route inbound preserves owner rebuild and visitor answer.
- [ ] Replace all front-desk actor lookups with a Session sender using a narrow session.send self-cap. Test no front-desk member, owner edit, visitor non-edit, at-llm isolation, narration/share no ingress loop. Commit feat(hello): route through session ingress and reuse llm.

### Task 6: Retire cross-layer relay names and wire UI

**Files:** agent receive, agent bridge, Session feed channel, World conversation data, authenticated new-session LiveView and tests.

- [ ] Rename hello completion metadata to generic completion metadata, delete hello sync-result mapping, remove front-desk mention injection, and retire the legacy hello-page fallback in favor of view registry.
- [ ] Add flavor and dependent agent selectors to the Hello create form, with empty state and disabled submit. Test filtering and selected reuse using render_change/render_submit. Run focused suites, mix ci.fast, then mix precommit. Commit feat(hello): select reusable LLM agent at session creation.
