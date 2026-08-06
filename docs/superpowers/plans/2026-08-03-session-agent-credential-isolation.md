# Session Agent Credential Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Require a fresh credential connection for every credential-requiring agent role in every newly materialized Session, without reusing agents or authentication from earlier Sessions.

**Architecture:** The credential resolver gains an explicit `:session_local` source policy that preserves non-secret configuration layers while selecting no user-default, workspace-shared, or explicit credential source. The Session materializer derives admission from the flavor-owned `CredentialConnection` descriptor, always defers credential-requiring roles, spawns each provisional agent with `:session_local`, and completes admission without writing a reusable default-source pointer.

**Tech Stack:** Elixir 1.19, OTP 28, ExUnit, Ecto/PostgreSQL, Ezagent Behavior/Kind/CapBAC primitives.

## Global Constraints

- Every Session role with a PTY or API-key credential descriptor requires a fresh admission.
- Every new Session role receives a fresh agent URI; another Session's member agent is never reused.
- Session materialization ignores user-default and workspace-shared credential sources.
- Successful Session admission never creates, replaces, or restores a reusable credential-source pointer.
- Credential-free roles continue to materialize immediately.
- Existing joined Session agents remain running; unfilled roles use the new policy on retry.
- Credential material remains on the flavor-owned agent surface and never enters admission state or World payloads.
- Use `Req` for HTTP; add no dependencies.
- Do not run `mix precommit` for this worktree per the user's instruction.

---

### Task 1: Add a resolver-level session-local credential policy

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/credential/resolver.ex`
- Test: `apps/ezagent_core/test/ezagent/credential/resolver_test.exs`
- Modify: `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn/cascade.ex`
- Test: `apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs`

**Interfaces:**
- Consumes: resolution input map accepted by `Ezagent.Credential.Resolver.resolve_layers/1`.
- Produces: `credential_source_policy: :session_local`, which yields `secret_source: nil` without consulting or accepting reusable sources.

- [ ] **Step 1: Write failing resolver tests**

Add tests proving the policy bypasses both reusable-source lookups and rejects an explicitly supplied source:

```elixir
test "session-local policy selects no reusable credential source" do
  assert {:ok, nil} =
           Resolver.pick_credential_source(%{
             credential_source_policy: :session_local,
             explicit_source: nil,
             owner_uri: @owner,
             workspace_uri: @ws,
             flavor: "cc",
             credential_required?: true,
             user_source_lookup: fn -> flunk("user source must not be read") end,
             workspace_shared_lookup: fn -> flunk("workspace source must not be read") end
           })
end

test "session-local policy rejects an explicit credential source" do
  assert {:error, :credential_source_forbidden} =
           Resolver.pick_credential_source(%{
             credential_source_policy: :session_local,
             explicit_source: @explicit,
             owner_uri: @owner,
             workspace_uri: @ws,
             flavor: "cc"
           })
end
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
mise exec -- mix test apps/ezagent_core/test/ezagent/credential/resolver_test.exs
```

Expected: the first test attempts a reusable-source lookup or returns `:no_credential_source`; the explicit-source test returns the existing explicit-source result instead of `:credential_source_forbidden`.

- [ ] **Step 3: Implement the minimal resolver policy**

Thread `credential_source_policy` from `resolve_layers/1` into `pick_credential_source/1`. Dispatch before normal precedence:

```elixir
defp pick_by_policy(:session_local, nil, _opts), do: {:ok, nil}
defp pick_by_policy(:session_local, %URI{}, _opts), do: {:error, :credential_source_forbidden}
defp pick_by_policy(nil, explicit, opts), do: do_pick(explicit, opts.user_lookup, opts.ws_lookup, opts.required?, opts.available?)
```

Keep the existing explicit → user → workspace → required state machine unchanged for callers without the new policy. Use map access functions rather than struct access because resolver inputs are plain maps.

- [ ] **Step 4: Add a failing cascade propagation test**

In `cascade_credential_optional_test.exs`, call `Cascade.resolve_content/7` with `credential_source_policy: :session_local` and injected lookup functions that call `flunk/1`. Assert resolution succeeds and contains no `credential_source_uri` even with `credential_required?: true`.

- [ ] **Step 5: Run the cascade test and verify RED**

Run:

```bash
mise exec -- mix test apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs
```

Expected: the policy is ignored or the injected source lookup is called.

- [ ] **Step 6: Thread the policy through Cascade and verify GREEN**

Add `credential_source_policy` to the generated default resolution and to `resolver_inputs/7`:

```elixir
credential_source_policy: content_field(content, :credential_source_policy)
```

and:

```elixir
credential_source_policy:
  Map.get(resolution, :credential_source_policy) ||
    Map.get(resolution, "credential_source_policy")
```

Run both Task 1 test files. Expected: all tests pass.

- [ ] **Step 7: Commit Task 1**

```bash
git add apps/ezagent_core/lib/ezagent/credential/resolver.ex \
  apps/ezagent_core/test/ezagent/credential/resolver_test.exs \
  apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn/cascade.ex \
  apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs
git commit -m "feat(credentials): add session-local source policy"
```

---

### Task 2: Enforce admission for every credential-requiring Session role

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agent_support.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agent_lifecycle.ex`
- Test: `apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs`
- Test: `apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs`

**Interfaces:**
- Consumes: `Ezagent.Agent.CredentialConnection.for_flavor/2` returning `:not_required`, `{:pty, %{label: label}}`, or `{:api_key, %{provider: provider, label: label}}`.
- Produces: `credential_admission_of/1` as the effective platform policy and provisional spawn content with `credential_source_policy: :session_local`.

- [ ] **Step 1: Write a failing effective-policy integration test**

Create a credential-bearing declaration with `credential_admission: :immediate`, materialize it, and assert that it is deferred rather than joined:

```elixir
assert {:ok, %{satisfied: [], skipped: [], deferred: [^role_name]}} =
         DefinitionAgents.materialize_definition_agents(
           session_uri,
           @workspace_uri,
           @owner_uri,
           [declaration]
         )

assert [%{role_name: ^role_name, status: :pending_auth}] = AgentAdmission.list(session_uri)
assert SessionBehavior.role_name_to_uri(members_of(session_uri), role_name) == nil
```

Retain a companion assertion that `ImmediateTemplate`, whose descriptor is `:not_required`, still joins immediately.

- [ ] **Step 2: Run the integration test and verify RED**

Run the new test by line or name:

```bash
mise exec -- mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs --only session_credential_isolation
```

Expected: the credential-bearing role is reported as satisfied/joined because its declaration says `:immediate`.

- [ ] **Step 3: Derive effective admission from the flavor descriptor**

Update `credential_admission_of/1` so a valid credential connection always wins over the template hint:

```elixir
case Ezagent.Agent.CredentialConnection.for_flavor(
       flavor_of(agent),
       backend_profile: provider_of(agent)
     ) do
  {:ok, :not_required} -> declared_credential_admission(agent)
  {:ok, _connection} -> :before_session_join
  {:error, _reason} -> declared_credential_admission(agent)
end
```

Keep raw declaration parsing in a private `declared_credential_admission/1` helper. Unknown flavors still fail at their existing registry/materialization boundary.

- [ ] **Step 4: Write failing tests for existing default and workspace sources**

Seed a valid user-default source in one case and a workspace-shared source in another. Materialize a new credential-requiring role and assert both return `deferred: [role_name]`, create `pending_auth`, and do not join or reuse the seeded source.

- [ ] **Step 5: Run the new source-isolation tests and verify RED**

Run:

```bash
mise exec -- mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs --only session_credential_isolation
```

Expected: at least the user-default case attempts direct materialization instead of producing `pending_auth`.

- [ ] **Step 6: Make gated materialization unconditionally defer**

Remove `CredentialPrecondition.check_source/4` from `materialize_gated_agent`. Preserve existing active/idempotent admission rows; otherwise call only:

```elixir
with {:ok, admission} <- AgentAdmission.defer(session_uri, agent) do
  {:deferred, admission}
end
```

Simplify the function signature and remove the now-unused `CredentialPrecondition` alias and source-check parameters.

- [ ] **Step 7: Prevent credential cascade into provisional agents**

In `DefinitionAgentLifecycle.spawn_agent/8`, extend the provisional override:

```elixir
template_content_overrides: %{
  credential_optional: true,
  credential_source_policy: :session_local,
  session_template_member: true
}
```

Assert after `AgentAdmission.begin/4` that the provisional agent has a fresh URI and its durable cascade resolution contains no selected credential source.

- [ ] **Step 8: Run Task 2 tests and verify GREEN**

Run:

```bash
mise exec -- mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs \
  apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs
```

Expected: both files pass.

- [ ] **Step 9: Commit Task 2**

```bash
git add apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agent_support.ex \
  apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex \
  apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agent_lifecycle.ex \
  apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs \
  apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs
git commit -m "fix(session): require fresh agent authentication"
```

---

### Task 3: Stop Session admission from publishing reusable credentials

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/agent_admission.ex`
- Test: `apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs`

**Interfaces:**
- Consumes: authenticated provisional agent and its existing `complete_provisional/6` lifecycle operation.
- Produces: joined admission without any `UserDefaultSource` mutation.

- [ ] **Step 1: Write failing pointer-isolation tests**

Add two completion cases:

```elixir
assert UserDefaultSource.resolve(owner, workspace, flavor) == nil
assert {:ok, %{status: :joined}} = AgentAdmission.complete(session, role, attempt, actor_ctx)
assert UserDefaultSource.resolve(owner, workspace, flavor) == nil
```

and, with a pre-existing external pointer:

```elixir
assert UserDefaultSource.resolve(owner, workspace, flavor) == prior_source
assert {:ok, %{status: :joined}} = AgentAdmission.complete(session, role, attempt, actor_ctx)
assert UserDefaultSource.resolve(owner, workspace, flavor) == prior_source
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```bash
mise exec -- mix test apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs
```

Expected: successful completion writes the candidate URI as the default source.

- [ ] **Step 3: Remove the default-source transaction from completion**

Reduce the authenticated completion chain to:

```elixir
with {:ok, materializing} <- put_status(session_uri, current, :materializing, nil),
     :ok <-
       DefinitionAgents.complete_provisional(
         session_uri,
         actor_uri,
         declaration,
         agent_uri,
         attempt_id,
         actor_ctx(actor_uri, caps)
       ),
     {:ok, joined} <- put_joined(session_uri, materializing) do
  {:ok, joined}
end
```

Delete `set_default_source/6`, `prepare_default_source_transaction/4`, restore/reapply helpers, their fault-injection helpers, and `default_source_transaction` cleanup fields. Remove the unused `UserDefaultSource` alias.

- [ ] **Step 4: Replace obsolete transactional tests**

Delete tests whose only contract is pointer replacement/rollback/CAS. Preserve their meaningful lifecycle portions as focused tests that a joined-state write failure retires the provisional agent and leaves any pre-existing pointer unchanged.

- [ ] **Step 5: Run the admission tests and verify GREEN**

Run:

```bash
mise exec -- mix test apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs
```

Expected: all tests pass with no default-source writes from admission.

- [ ] **Step 6: Commit Task 3**

```bash
git add apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/agent_admission.ex \
  apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs
git commit -m "fix(session): keep admitted credentials session-local"
```

---

### Task 4: Acceptance regression and final review

**Files:**
- Modify: `apps/ezagent_plugin_hello/test/integration/hello_page_e2e_test.exs`

**Interfaces:**
- Consumes: Session-domain admission projection and existing Hello/World connection card.
- Produces: end-to-end proof that consecutive Sessions require separate authentication.

- [ ] **Step 1: Write the consecutive-Session acceptance regression**

Create two Hello Sessions under the same owner/workspace. Complete authentication for the first, then create the second and assert:

```elixir
assert first_agent_uri != second_provisional_agent_uri
assert [%{role_name: "llm", status: :pending_auth}] = AgentAdmission.list(second_session)
assert SessionBehavior.role_name_to_uri(members_of(second_session), "llm") == nil
```

Also assert the second Session's World projection contains its API-key or PTY connection card.

- [ ] **Step 2: Run the acceptance regression**

Run:

```bash
mise exec -- mix test apps/ezagent_plugin_hello/test/integration/hello_page_e2e_test.exs
```

Expected: the test passes using the policy established by Tasks 1–3. The lower-level tests in those tasks were each observed failing before their corresponding production change.

- [ ] **Step 3: Preserve the explicit manifest declaration**

Keep `credential_admission: :before_session_join` in the Hello manifest as explicit documentation even though the Session boundary now enforces it. Do not add a user-selectable reuse option.

- [ ] **Step 4: Run focused suites**

Run:

```bash
mise exec -- mix test apps/ezagent_core/test/ezagent/credential/resolver_test.exs
mise exec -- mix test apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs
mise exec -- mix test apps/ezagent_domain_session/test/ezagent_domain_instance_message/session_creator/agent_admission_test.exs
mise exec -- mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs
mise exec -- mix test apps/ezagent_plugin_hello/test
```

Expected: zero failures; existing intentional skips remain documented.

- [ ] **Step 5: Run static review without precommit**

Run:

```bash
mise exec -- mix format --check-formatted
git diff --check
git status --short
```

Inspect the diff for credential data, unrelated worktree artifacts, default-source writes from admission, and any remaining source-resolution branch in gated Session materialization.

- [ ] **Step 6: Restart the isolated service and manually verify**

Restart the existing worktree service at `http://world.localhost:10042`. Reset only the isolated PR data through the sanctioned reset path, then create `hello-1` and `hello-2`. Confirm both independently display configuration, produce different LLM agent URIs, and neither receives the other's authentication.

- [ ] **Step 7: Commit acceptance coverage**

```bash
git add apps/ezagent_plugin_hello/test/integration/hello_page_e2e_test.exs
git commit -m "test(hello): require per-session credential setup"
```
