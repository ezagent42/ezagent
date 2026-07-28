# Template Agent Membership Before Credential Validation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Materialize every session-template role as a session member even when its credential is absent, so configuration and PTY login remain reachable.

**Architecture:** `DefinitionAgents` becomes responsible only for structural materialization: create, bind recipe caps, and join. It marks only the role-materialization spawn content as credential-optional, allowing the cascade to create a keyless slice agent without weakening ordinary agent creation. Custom-backend CC templates use the same scoped flag to create their member without a provider key; their normal launch and credential checks remain strict in every other path.

**Tech Stack:** Elixir, OTP, ExUnit, credential cascade, RecipeMaterializer, CC template classes.

## Global Constraints

- A successful template-role creation, cap bind, and `session.join` always yields a member, regardless of credential state.
- The scope flag is written only for `DefinitionAgents` fresh-role materialization and is retained in respawn data for that agent.
- Explicit agent creation, unknown provider profiles, malformed templates, capability binding failures, and join failures retain their existing fail-closed behavior.
- Missing credentials never cause `DefinitionAgents` to return a skipped role or terminate a newly created member.
- `mix precommit` is required after all implementation changes.

---

### Task 1: Make session-template role materialization credential-independent

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex`
- Test: `apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs`

**Interfaces:**
- Consumes: a fresh role declaration `%{recipe: recipe_name, role_name: role_name, flavor: flavor}`.
- Produces: `{:ok, %{satisfied: [role_name], skipped: []}}` and a member resolvable by `SessionBehavior.role_name_to_uri/2` when its credential is absent.

- [ ] **Step 1: Write failing materialization regressions**

Replace the existing assertions that credentialless environment and required-slice roles are skipped. Assert both roles are satisfied and resolve to members:

```elixir
assert summary.skipped == []
assert summary.satisfied == [cred_role, ok_role]

members = members_of(session_uri)
assert %URI{} = SessionBehavior.role_name_to_uri(members, cred_role)
assert %URI{} = SessionBehavior.role_name_to_uri(members, ok_role)
```

Add a reuse regression with a credentialless existing agent and assert that `reuse_existing_agent/6` joins it rather than returning `{:skip, _}`.

- [ ] **Step 2: Run the focused test to prove the current gate fails**

Run:

```bash
mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs
```

Expected: the required-slice role is skipped by `CredentialPrecondition.check_source/4`, and the environment role is skipped after `:backend_api_key_missing`.

- [ ] **Step 3: Remove credential decisions from the member-materialization path**

In `spawn_fresh_at_planned_uri/9`, call `spawn_bound_agent/8` directly; remove the synchronous `HostLoginAdopt.ensure_installer_source/3` and `check_credential_source/5` chain. In `spawn_bound_agent/8`, remove `verify_credentials_on_fresh/2`; in `reuse_existing_agent/6`, remove `verify_credentials_on_reuse/2`. Delete the now-unused private helpers.

Pass the scoped content override to `RecipeMaterializer.create_agent_from_recipe/1`:

```elixir
template_content_overrides: %{
  credential_optional: true,
  session_template_member: true
}
```

Keep the existing compensation only for recipe-cap binding and join failures. Do not translate `:backend_api_key_missing` into `{:skip, _}`; return a normal spawn error until Task 2 makes that scoped spawn structurally possible.

- [ ] **Step 4: Run the focused regression after Task 2 is complete**

Run:

```bash
mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs
```

Expected: all credentialless role cases are members; unknown recipes and non-credential spawn failures still fail.

- [ ] **Step 5: Commit the structural materialization change**

```bash
git add apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs
git commit -m "fix(session): join template roles before credential setup"
```

### Task 2: Permit scoped keyless custom-backend CC member startup

**Files:**
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/provider.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_custom_agent.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_custom_agent.ex`
- Test: `apps/ezagent_plugin_cc/test/ezagent/template/cc_custom_backend_test.exs`

**Interfaces:**
- Consumes: persisted template content containing `"session_template_member" => true` and a valid custom provider with no environment key.
- Produces: a structurally created custom-backend member with no `ANTHROPIC_AUTH_TOKEN`; ordinary custom-agent creation without the flag still returns `{:backend_api_key_missing, provider, agent_uri}`.

- [ ] **Step 1: Write failing custom-backend flag tests**

In `cc_custom_backend_test.exs`, add the following cases after the existing missing-key test:

```elixir
tmpl = Map.put(tmpl, "session_template_member", true)
assert {:ok, env} = Provider.provider_env(tmpl)
assert env["ANTHROPIC_BASE_URL"] == "https://api.deepseek.com/anthropic"
refute Map.has_key?(env, "ANTHROPIC_AUTH_TOKEN")
```

Add equivalent assertions that `CcCustomAgent.instantiate/3` and `CcHeadlessCustomAgent.instantiate/3` bypass `Provider.ensure_api_key/2` only with this flag; retain the existing unflagged missing-key assertion.
Also assert the two template classes preserve the flag in their generated template data:

```elixir
assert CcCustomAgent.template_data_extra(%{session_template_member: true})[
         "session_template_member"
       ] == true
```

- [ ] **Step 2: Run the custom-backend test to verify failure**

Run:

```bash
mix test apps/ezagent_plugin_cc/test/ezagent/template/cc_custom_backend_test.exs
```

Expected: `Provider.provider_env/1` and both template classes still reject the missing key.

- [ ] **Step 3: Implement the scoped incomplete-provider launch mode**

Add a public predicate in `Ezagent.PluginCc.Provider`:

```elixir
def session_template_member?(tmpl) when is_map(tmpl),
  do: Map.get(tmpl, "session_template_member") in [true, "true"]
```

Keep `profile_env/1` unchanged for ordinary callers. Make `provider_env/1` call a
new private `profile_env/2` with
`allow_missing_key?: session_template_member?(tmpl)`. That private branch
returns the catalog profile's `static_env` and `ANTHROPIC_BASE_URL`, but omits
`ANTHROPIC_AUTH_TOKEN`, when the scoped member has no key. Every unflagged call
keeps the existing error. In both custom template classes, replace the
unconditional `Provider.ensure_api_key/2` with a helper that returns `:ok` for
the scoped flag and otherwise delegates to `ensure_api_key/2`.
`SpawnPlan.build_claude_cmd/3` already calls `Provider.provider_env/1`, so its
environment contains no secret when missing.

In each `template_data_extra/1`, add the persisted field only when the source
content contains the exact boolean flag:

```elixir
case Ezagent.Kind.Template.content_field(content, :session_template_member) do
  true -> Map.put(base, "session_template_member", true)
  _ -> base
end
```

- [ ] **Step 4: Run the custom-backend test to verify success**

Run:

```bash
mix test apps/ezagent_plugin_cc/test/ezagent/template/cc_custom_backend_test.exs
```

Expected: scoped keyless templates build and instantiate; all unflagged missing-key and unknown-profile tests remain green.

- [ ] **Step 5: Commit the custom-backend change**

```bash
git add apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/provider.ex apps/ezagent_plugin_cc/lib/ezagent/template/cc_custom_agent.ex apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_custom_agent.ex apps/ezagent_plugin_cc/test/ezagent/template/cc_custom_backend_test.exs
git commit -m "fix(cc): materialize keyless template members"
```

### Task 3: Verify the complete contract

**Files:**
- Test: `apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs`
- Test: `apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs`

**Interfaces:**
- Consumes: template content containing `credential_optional: true` for a role-materialized slice agent, or an unflagged ordinary create input.
- Produces: a keyless role-member cascade while an unflagged required slice still returns `{:error, :no_credential_source}`.

- [ ] **Step 1: Write the cascade persistence regression**

Keep the existing cascade distinction explicit with these assertions:

```elixir
assert {:ok, _resolved} =
         Cascade.resolve_content(keyless_content, SliceTC, @agent, @admin, @ws, "curl",
           source_template_uri: @source_tmpl
         )

assert {:error, :no_credential_source} =
         Cascade.resolve_content(required_content, SliceTC, @agent, @admin, @ws, "curl",
           source_template_uri: @source_tmpl
         )
```

The session integration test is the regression that proves `DefinitionAgents`
supplies the keyless role content; this cascade test proves ordinary inputs are
not globally relaxed.

- [ ] **Step 2: Run the cascade and session tests**

Run:

```bash
mix test apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs
```

Expected: the cascade test stays green before and after the change; the session test passes after Tasks 1–2 and proves no global relaxation has been introduced.

- [ ] **Step 3: Run all focused suites**

Run:

```bash
mix test apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs apps/ezagent_plugin_cc/test/ezagent/template/cc_custom_backend_test.exs
```

Expected: PASS with credentialless curl, file-login, and custom-provider role agents present as members.

- [ ] **Step 4: Format and run the project gate**

Run:

```bash
mix format apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agents.ex apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/provider.ex apps/ezagent_plugin_cc/lib/ezagent/template/cc_custom_agent.ex apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_custom_agent.ex apps/ezagent_plugin_cc/test/ezagent/template/cc_custom_backend_test.exs apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs
mix precommit
git diff --check
```

Expected: all commands exit successfully and `git diff --check` has no output.

- [ ] **Step 5: Commit verification and documentation**

```bash
git add docs/superpowers/specs/2026-07-28-hello-llm-configuration-and-errors-design.md docs/superpowers/plans/2026-07-28-template-agent-membership-before-credential-validation.md
git commit -m "docs(hello): document credentialless role materialization"
```
