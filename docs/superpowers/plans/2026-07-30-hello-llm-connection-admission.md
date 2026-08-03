# Hello LLM Connection Admission Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a Hello session admit its declared LLM only after the creator has completed and passed that flavor's credential configuration, while keeping the session usable with `front-desk` from the first render.

**Architecture:** Extend a socialware agent role declaration with credential admission, enforced by the Session domain for every flavor that declares a credential connection. The existing post-create socialware-install transaction continues to create credential-free roles immediately, but always records an admission candidate for a credential-requiring role. A candidate is a fresh, session-local agent with a durable lifecycle record but no `session.join` edge. Its flavor-owned connection surface (PTY or secret configuration) writes credentials; the domain re-probes credential status, then binds recipe/caps and joins that same candidate without registering it as a reusable credential source. World renders the durable admission record and dispatches only authorized start/complete/cancel actions.

**Tech Stack:** Elixir/OTP, Phoenix LiveView, Ecto, TypeScript/React, Vitest, Playwright, Mix architecture gates.

## Global Constraints

- Preserve the existing `create_session/3` invariant: it installs config and owner only; no agent creation, credential check, PTY operation, or login wait may run in that transaction.
- The template/derived-template fixes `llm` flavor at creation time. No action may switch a live session's role flavor.
- A role agent and its configured authentication are session-local. A new Session always requires a fresh connection and never resolves a prior user-default or workspace-shared credential source.
- `session.join` remains the only membership admission action. Do not route the admission success path through `session.switch`; World must retain the `sessions.join` direct-action event shape that supplies layout state.
- Do not copy credential files in World or in a session call site. Configure credentials only through the provisional agent's flavor-owned connection surface, and use `Ezagent.Domain.Agent.read_credential_status/3` for validation. Session materialization must not resolve the existing credential-source pointer or cascade.
- All World actions must be added to `Ezagent.World.DispatchContract`, checked at a server-side authorization boundary, and return a refreshed `world:state` / `members:update` projection.
- Keep flavor details in flavor-owned adapter declarations. The core/session layer may consume a normalized connection descriptor but must not branch on `"codex"`, `"cc"`, or `"curl"`.

---

## File map

| Area | Files | Responsibility |
| --- | --- | --- |
| Declarative contract | `apps/ezagent_domain_agent/lib/ezagent/agent/credential_connection.ex`, `apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex`, `apps/ezagent_domain_session/lib/ezagent/socialware/definition_editor.ex` | Normalize a flavor's connection method and preserve a role's admission policy through template installation. |
| Durable session workflow | `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/agent_admission.ex`, `session_creator.ex`, `definition_agents.ex` | Candidate state machine, idempotency, source registration, join/cleanup. |
| Flavor integrations | `apps/ezagent_plugin_codex/lib/ezagent/template/codex_agent.ex`, `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex`, `apps/ezagent_plugin_curl_agent/lib/ezagent/template/curl_agent.ex` | Declare PTY versus API-key connection methods without adding core flavor conditionals. |
| World read/write surface | `dispatch_contract.ex`, `conversation_actions.ex`, `conversation_data.ex`, `world_live.ex`, `assets/src/main.tsx`, `assets/src/components/Conversation.tsx` | Expose the pending card, launch the right UI, and refresh member/state projections. |
| Regression repair | `apps/ezagent_domain_agent/lib/ezagent/agent/host_login_adopt.ex`, `agent_flavor_resolver.ex` and tests | Make the host-login durable source resolve to the expected flavor before pointer validation. |
| Hello declaration | `apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml` | Mark only the Hello `llm` role as credential-gated; `front-desk` remains immediate. |

## Task 1: Define and test the declarative admission and connection contracts

**Files:**
- Create: `apps/ezagent_domain_agent/lib/ezagent/agent/credential_connection.ex`
- Modify: `apps/ezagent_domain_agent/lib/ezagent/agent/credential_adapter.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent/socialware/definition_editor.ex`
- Test: `apps/ezagent_domain_agent/test/ezagent/agent/credential_connection_test.exs`
- Test: `apps/ezagent_domain_session/test/ezagent/socialware/definition_test.exs`
- Test: `apps/ezagent_domain_session/test/ezagent/socialware/definition_editor_test.exs`

- [ ] **Step 1: Write failing unit tests for the normalized connection descriptor.**

  Cover `{:pty, label}` and `{:api_key, provider, label}` as valid results, and require unknown/malformed declarations to become `{:error, :unsupported_connection}` rather than a core fallback. Confirm a credential-less flavor reports `:not_required`; it must not enter this workflow merely because it appears in a role list.

  Run: `mise exec -- mix test apps/ezagent_domain_agent/test/ezagent/agent/credential_connection_test.exs`

  Expected: FAIL because `Ezagent.Agent.CredentialConnection` and the adapter callback do not exist.

- [ ] **Step 2: Add `Ezagent.Agent.CredentialConnection`.**

  Give it the public, flavor-neutral API:

  ```elixir
  @type descriptor ::
          :not_required
          | {:pty, %{label: String.t()}}
          | {:api_key, %{provider: String.t(), label: String.t()}}

  @spec for_flavor(String.t(), keyword()) :: {:ok, descriptor()} | {:error, term()}
  ```

  It resolves the registered template class and delegates only to an optional `credential_connection/1` callback. Add that callback to `CredentialAdapter` with a documented `:not_required` default. Do not add a `case flavor` table in this module.

- [ ] **Step 3: Add `credential_admission: :before_session_join` to agent role declarations.**

  `Ezagent.Socialware.Definition` must parse atom and string keys, reject values other than `:immediate` / `:before_session_join`, and default omitted roles to `:immediate` for backward compatibility. `DefinitionEditor.apply_role_slot_choice/2` must preserve the declaration policy while still allowing the existing template's `role_slots[].flavor` choice to override only flavor/install data.

  Use this durable role shape after composition:

  ```elixir
  %{
    role_name: "llm",
    fill: :agent,
    recipe: "hello.llm",
    flavor: "codex",
    credential_admission: :before_session_join
  }
  ```

- [ ] **Step 4: Prove declaration round-trip and compatibility.**

  Add tests that parse/serialize the new flag, preserve it after an install-level `llm` flavor override, reject invalid values, and retain the existing behavior for manifests without the field.

  Run: `mise exec -- mix test apps/ezagent_domain_agent/test/ezagent/agent/credential_connection_test.exs apps/ezagent_domain_session/test/ezagent/socialware/definition_test.exs apps/ezagent_domain_session/test/ezagent/socialware/definition_editor_test.exs`

  Expected: PASS.

- [ ] **Step 5: Commit the contract.**

  ```bash
  git add apps/ezagent_domain_agent/lib/ezagent/agent/credential_connection.ex \
    apps/ezagent_domain_agent/lib/ezagent/agent/credential_adapter.ex \
    apps/ezagent_domain_agent/test/ezagent/agent/credential_connection_test.exs \
    apps/ezagent_domain_session/lib/ezagent/socialware/definition.ex \
    apps/ezagent_domain_session/lib/ezagent/socialware/definition_editor.ex \
    apps/ezagent_domain_session/test/ezagent/socialware/definition_test.exs \
    apps/ezagent_domain_session/test/ezagent/socialware/definition_editor_test.exs
  git commit -m "feat(session): declare credential-gated role admission"
  ```

## Task 2: Add the durable candidate state machine outside session creation

**Files:**
- Create: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/agent_admission.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex`
- Test: `apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs`
- Test: `apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs`
- Test: `apps/ezagent_domain_session/test/architecture/session_create_no_agent_spawn_test.exs`

- [ ] **Step 1: Write failing domain tests for the lifecycle.**

  Exercise this sequence with a fake credential-bearing flavor: immediate `front-desk` is joined; gated `llm` is recorded as `pending_auth`; starting creates exactly one managed provisional agent but no membership edge; duplicate start returns the same attempt/agent; unauthenticated completion leaves the candidate out of members; authenticated completion binds recipe/caps and joins the candidate as `llm`; retry after failure creates a new attempt; cancel/timeout removes the provisional agent and never removes a valid prior credential source.

  Run: `mise exec -- mix test apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs`

  Expected: FAIL because no candidate state or admission service exists.

- [ ] **Step 2: Persist a session working-copy admission record.**

  `SessionCreator.AgentAdmission` owns one explicit working-copy key, `:agent_admissions`, keyed by role name. Store only durable, non-secret data:

  ```elixir
  %{
    "llm" => %{
      status: :pending_auth | :authenticating | :materializing | :joined | :failed,
      flavor: "codex",
      role_name: "llm",
      template_revision: revision,
      attempt_id: "uuid",
      provisional_agent_uri: "entity://...",
      connection: {:pty, %{label: "Connect Codex"}} | {:api_key, %{provider: "...", label: "..."}},
      failure_code: nil | :authentication_failed | :connection_cancelled | :connection_timed_out
    }
  }
  ```

  Expose `list/1`, `begin/4`, `complete/4`, `cancel/4`, and `expire/2`. Every mutator must re-read the declaration, bind the attempt to `(session, role, flavor, template_revision)`, and reject stale or forged role/agent values. Emit telemetry for transition success/failure without credential contents.

- [ ] **Step 3: Split DefinitionAgents materialization into immediate and gated lanes.**

  Keep `materialize_definition_agents/5` as the post-create entry point. For `:immediate`, retain the current `spawn_bound_agent → bind_recipe_caps → grant_creator_manage_cap → session.join` path. For `:before_session_join`:

  - if `CredentialPrecondition.check_source/4` succeeds, use the normal bound spawn/join path and clear any stale admission row;
  - otherwise record `pending_auth` and return it as a non-fatal deferred result, not as the old generic `:missing_credentials` skip;
  - never call candidate start from `create_session/3`.

  Extract the presently private spawn/bind/join helpers only as much as needed so `AgentAdmission.complete/4` uses the same capability grant, recipe binding, `session.join`, membership-convergence, and receipt compensation behavior as normal materialization.

- [ ] **Step 4: Implement candidate start, completion, and cleanup.**

  `begin/4` creates a fresh role-shaped agent with the selected flavor and a creator manage cap, but deliberately omits `session.join` and credential-source resolution. It records `:authenticating` only after the spawn receipt is durable. `complete/4` must call `Ezagent.Domain.Agent.read_credential_status/3` using the caller's authorized context; only `:authenticated` may proceed to bind and join. It must not create or replace a user/workspace/flavor default source. `:missing`, `:expired`, `:unknown`, and `:n_a` are non-success states; the last one is valid only when the declared connection contract is `:not_required`.

  On every post-spawn failure, use the spawn receipt to compensate the provisional agent, write `:failed`, and preserve any pre-existing valid source pointer. Candidate cancellation and expiry use the same cleanup path and are idempotent.

- [ ] **Step 5: Re-run the focused domain and architecture tests.**

  Run: `mise exec -- mix test apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs apps/ezagent_domain_session/test/architecture/session_create_no_agent_spawn_test.exs`

  Expected: PASS; the architecture test still proves `create_session/3` contains no agent-spawn writer.

- [ ] **Step 6: Commit the workflow.**

  ```bash
  git add apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/agent_admission.ex \
    apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex \
    apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex \
    apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs \
    apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs \
    apps/ezagent_domain_session/test/architecture/session_create_no_agent_spawn_test.exs
  git commit -m "feat(session): admit credential-gated agents after validation"
  ```

## Task 3: Declare each flavor's connection surface and repair host-login flavor persistence

**Files:**
- Modify: `apps/ezagent_plugin_codex/lib/ezagent/template/codex_agent.ex`
- Modify: `apps/ezagent_plugin_codex/lib/ezagent/template/codex_remote_agent.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_agent.ex`
- Modify: `apps/ezagent_plugin_curl_agent/lib/ezagent/template/curl_agent.ex`
- Modify: `apps/ezagent_domain_agent/lib/ezagent/agent/host_login_adopt.ex`
- Test: `apps/ezagent_domain_agent/test/ezagent/agent_flavor_resolver_durable_sandbox_test.exs`
- Test: `apps/ezagent_domain_identity/test/ezagent/behavior/set_default_source_behavior_test.exs`
- Test: `apps/ezagent_domain_agent/test/ezagent/agent/host_login_adopt_test.exs`

- [ ] **Step 1: Write failing flavor contract and host-source regression tests.**

  Assert Codex/Claude descriptors select `{:pty, ...}` and the curl descriptor selects `{:api_key, ...}`. Seed a host-login source with the same snapshot shape `HostLoginAdopt` writes and assert `Ezagent.UriQuery.resolve(:flavor, source)` returns the declared flavor and `set_default_credential_source` accepts it.

  Run: `mise exec -- mix test apps/ezagent_domain_agent/test/ezagent/agent_flavor_resolver_durable_sandbox_test.exs apps/ezagent_domain_identity/test/ezagent/behavior/set_default_source_behavior_test.exs apps/ezagent_domain_agent/test/ezagent/agent/host_login_adopt_test.exs`

  Expected: FAIL on the host-login source case; current snapshot has `flavor` beside `template_class: nil` and the resolver intentionally reads only respawn data/template class.

- [ ] **Step 2: Implement connection declarations in the flavor packages.**

  Each registered template class implements the contract introduced in Task 1. PTY-backed flavors describe a user-facing label only; curl describes its provider/key form. Environment-only or credential-less flavors return `:not_required` only if their existing `CredentialPrecondition` can positively prove readiness; otherwise they must return an explicit unsupported/needs-deployment error so the session is never falsely joined.

- [ ] **Step 3: Correct durable host-login source representation.**

  In `HostLoginAdopt.register_source/4`, write flavor where the existing resolver contract consumes it:

  ```elixir
  sandbox: %{
    state: %{
      config_dir_path: host_dir,
      respawn_template_data: %{"flavor" => flavor},
      template_class: nil,
      passive: true
    }
  }
  ```

  Do not loosen `AgentFlavorResolver.resolve_flavor_from_sandbox/1` to trust an arbitrary top-level sandbox `:flavor`; that would create a second durable representation. Preserve all existing owner-edge and cap-checked pointer behavior.

- [ ] **Step 4: Verify flavor/source behavior.**

  Run: `mise exec -- mix test apps/ezagent_domain_agent/test/ezagent/agent_flavor_resolver_durable_sandbox_test.exs apps/ezagent_domain_identity/test/ezagent/behavior/set_default_source_behavior_test.exs apps/ezagent_domain_agent/test/ezagent/agent/host_login_adopt_test.exs`

  Expected: PASS, including a real `:flavor` URI query from the host-login snapshot.

- [ ] **Step 5: Commit flavor boundaries and source repair.**

  ```bash
  git add apps/ezagent_plugin_codex apps/ezagent_plugin_cc apps/ezagent_domain_agent/lib/ezagent/agent/host_login_adopt.ex \
    apps/ezagent_domain_agent/test/ezagent/agent_flavor_resolver_durable_sandbox_test.exs \
    apps/ezagent_domain_agent/test/ezagent/agent/host_login_adopt_test.exs \
    apps/ezagent_domain_identity/test/ezagent/behavior/set_default_source_behavior_test.exs
  git commit -m "fix(agent): make credential connection sources flavor-resolvable"
  ```

## Task 4: Expose the admission workflow through World without weakening PTY access

**Files:**
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/dispatch_contract.ex`
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/conversation_actions.ex`
- Modify: `apps/ezagent_plugin_world/lib/ezagent/world/conversation_data.ex`
- Modify: `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`
- Modify: `apps/ezagent_plugin_world/assets/src/main.tsx`
- Modify: `apps/ezagent_plugin_world/assets/src/components/Conversation.tsx`
- Test: `apps/ezagent_plugin_world/test/ezagent/world/world_live_dispatch_routing_test.exs`
- Test: `apps/ezagent_plugin_world/test/ezagent/world/pty_read_exits_test.exs`
- Test: `apps/ezagent_plugin_world/assets/src/components/Conversation.test.tsx`

- [ ] **Step 1: Write failing World tests and UI tests.**

  Add server tests for `session.agent_admission.begin`, `.complete`, and `.cancel`: malformed/stale attempts fail cleanly; a caller cannot start or open a candidate from another session; success pushes the updated member roster. Add React tests for a pending Codex card, an API-key card, a retry card, and no card when joined. Assert the card is rendered in the message-list conversation surface, not only in the member-management drawer.

  Run: `mise exec -- mix test apps/ezagent_plugin_world/test/ezagent/world/world_live_dispatch_routing_test.exs apps/ezagent_plugin_world/test/ezagent/world/pty_read_exits_test.exs && pnpm --dir apps/ezagent_plugin_world/assets test -- Conversation.test.tsx`

  Expected: FAIL because the actions, state projection, and card do not exist.

- [ ] **Step 2: Add a strict World dispatch family.**

  Add the three action names to the `conversation` list in `DispatchContract`. In `ConversationActions`, parse only the current session URI and delegate to `SessionCreator.AgentAdmission`; do not accept a client-provided flavor, role recipe, source URI, or arbitrary agent URI. On `begin`, refresh `world:state`; for a PTY descriptor, call the existing `switch_to_pty/3` only with the server-returned provisional URI. Keep `Ezagent.Domain.Pty.Access.may_read?/3` in that method and add a session-candidate relationship check before invoking it.

- [ ] **Step 3: Project durable admissions and membership changes.**

  `ConversationData` and `push_session_management_state/2` expose `agent_admissions` with role, flavor, status, connection descriptor, attempt ID, and sanitized failure code. Extend `push_members/1` with the same projection so a completion immediately replaces the card and refreshes the roster. Never include a config directory, credential status detail, token, or source URI in the browser payload.

- [ ] **Step 4: Render the persistent message-list card.**

  In `Conversation.tsx`, add a typed `AgentAdmission` state field and a card with stable IDs:

  ```tsx
  data-world-agent-admission={admission.role_name}
  data-world-agent-admission-connect
  data-world-agent-admission-retry
  ```

  Labels derive from the backend descriptor (for example, “连接 Codex”, “连接 Claude”, “配置 API key”), not from role-name or flavor string comparisons in React. For a PTY flow, dispatch begin then let the returned state activate the existing terminal; for API key, show the existing secure agent-key form for that returned provisional agent, then dispatch complete after save. Cancellation and failed validation leave a clear retry affordance and no session member.

- [ ] **Step 5: Prove the frontend/backend contract.**

  Run: `mise exec -- mix test apps/ezagent_plugin_world/test/ezagent/world/world_live_dispatch_routing_test.exs apps/ezagent_plugin_world/test/ezagent/world/pty_read_exits_test.exs && pnpm --dir apps/ezagent_plugin_world/assets lint && pnpm --dir apps/ezagent_plugin_world/assets typecheck && pnpm --dir apps/ezagent_plugin_world/assets test -- Conversation.test.tsx`

  Expected: PASS.

- [ ] **Step 6: Commit the World surface.**

  ```bash
  git add apps/ezagent_plugin_world/lib apps/ezagent_plugin_world/assets/src apps/ezagent_plugin_world/test
  git commit -m "feat(world): guide credential-gated agent admission"
  ```

## Task 5: Opt Hello in and prove the end-to-end journey

**Files:**
- Modify: `apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml`
- Modify: `apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex` only if its programmatic template path must retain the admission field
- Test: `apps/ezagent_plugin_hello/test/ezagent_plugin_hello/app_test.exs`
- Test: `apps/ezagent_plugin_world/assets/e2e/world.spec.ts`
- Test: `apps/ezagent_domain_session/test/ezagent/socialware/installation_test.exs`

- [ ] **Step 1: Write failing Hello integration and browser tests.**

  Cover a Hello session created with an LLM flavor requiring connection: `front-desk` is present; `llm` is absent; the message-list card names the template-selected connection; completing a mocked valid credential makes the *same provisional URI* the `llm` member; a second Hello session gets a new LLM URI and a separate connection card even while an earlier credential source exists; a failed/cancelled attempt leaves no `llm` member. Retain the existing `world:dispatch` assertion for `sessions.join` and its layout payload.

  Run: `mise exec -- mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/app_test.exs apps/ezagent_domain_session/test/ezagent/socialware/installation_test.exs`

  Expected: FAIL until the Hello manifest declares the policy.

- [ ] **Step 2: Mark the Hello LLM role, and only that role, as gated.**

  Add `credential_admission: before_session_join` under the `llm` role in `apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml`. Preserve `front-desk` as immediate. If `EzagentPluginHello.App.hello_template_content/1` writes a derived Hello template with a flavor override, ensure it carries the definition's admission policy; it may supply flavor but must not let callers remove the policy.

- [ ] **Step 3: Execute end-to-end verification.**

  Run: `mise exec -- mix test apps/ezagent_plugin_hello/test/ezagent_plugin_hello/app_test.exs apps/ezagent_domain_session/test/ezagent/socialware/installation_test.exs && pnpm --dir apps/ezagent_plugin_world/assets test:e2e -- e2e/world.spec.ts`

  Expected: PASS. The browser test must exercise the public `world:dispatch` route, not invoke an Elixir helper directly.

- [ ] **Step 4: Commit the Hello adoption.**

  ```bash
  git add apps/ezagent_web/priv/socialware_seed/hello/manifest.yaml \
    apps/ezagent_plugin_hello/lib/ezagent_plugin_hello/app.ex \
    apps/ezagent_plugin_hello/test apps/ezagent_domain_session/test/ezagent/socialware/installation_test.exs \
    apps/ezagent_plugin_world/assets/e2e/world.spec.ts
  git commit -m "feat(hello): require LLM connection before session admission"
  ```

## Task 6: Run the merge gates and record exact results

**Files:**
- Modify only if necessary to fix a deterministic failure from Tasks 1–5; do not make unrelated cleanup changes.

- [ ] **Step 1: Format and compile strictly.**

  Run: `mise exec -- mix format --check-formatted && mise exec -- mix compile --warnings-as-errors`

  Expected: both exit `0`.

- [ ] **Step 2: Run the required deterministic architecture gate.**

  Run: `mise exec -- mix gate.arch`

  Expected: exit `0`; no newly introduced core/domain/plugin arrow or `create_session` spawn violation.

- [ ] **Step 3: Run the complete frontend gate.**

  Run: `pnpm --dir apps/ezagent_plugin_world/assets lint && pnpm --dir apps/ezagent_plugin_world/assets typecheck && pnpm --dir apps/ezagent_plugin_world/assets test && pnpm --dir apps/ezagent_plugin_world/assets test:e2e`

  Expected: every command exits `0`, including `e2e/world.spec.ts`’s `world:dispatch` contract.

- [ ] **Step 4: Run the repository precommit suite and capture any pre-existing failure separately.**

  Run: `mise exec -- mix precommit`

  Expected: exit `0`. If it fails, rerun the single failing test once, include its exact command/output in the PR, and do not label an unrelated architecture timeout as caused by this change without a reproducer.

- [ ] **Step 5: Final review and commit.**

  Inspect `git diff --check`, `git status --short`, and the complete commit series. Confirm no generated credential file, `.env`, runtime config directory, or unrelated worktree artifact is staged. If gate-only corrections were needed, commit them separately:

  Commit a gate-only correction only when a deterministic failing test identifies
  a source file in this feature's file map; use the conventional message
  `test(hello): cover credential admission contract`.

## Acceptance journey

1. A user creates a session from Hello or a derived Hello template. The template-selected LLM flavor is fixed.
2. The session detail opens. `front-desk` is already a member; `llm` is shown as a connection card in the message list, not as a misleading active member.
3. The user clicks the descriptor-derived action. A provisional session-local agent is created but has no `session.join` membership edge.
4. Codex/Claude exposes the authorized PTY; API-backed flavors expose the secure key configuration path. The UI does not ask the user to understand PTYs or choose a flavor.
5. On successful validation, the system binds the role recipe/caps and joins that same provisional URI as `llm`. It does not register or replace a reusable credential source. The card disappears and the member list updates.
6. A later Hello session creates a different `llm` agent URI and requires a new credential connection. It reuses neither the earlier member agent nor its authentication.
7. On cancel, timeout, or failed validation, the candidate is cleaned up, `llm` remains absent, and the card gives a retry path. Existing valid credential sources remain untouched.
