# PTY Credential Admission Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Codex and Claude Code admission create a secret-free provisional agent, automatically open its PTY for CLI login, and admit it only after the existing explicit credential check succeeds.

**Architecture:** The session admission path marks only PTY-backed, session-local, credential-optional provisional spawns as bootstrap candidates. `TemplateSpawn.Cascade` validates and converts that request into an internal cascade marker only when no credential source or pending grant exists. `Credential.HomeRuntime` consumes the marker to atomically install configuration layers without reading secrets; all sourced cascades continue through the existing grant-backed materializer.

**Tech Stack:** Elixir 1.19, OTP 28, ExUnit, Ecto/PostgreSQL, existing AgentAdmission, TemplateSpawn.Cascade, HomeRuntime, CodexAgent, CcAgent, and Domain.Pty APIs.

## Global Constraints

- Preserve the existing `Connect Codex` / `Connect Claude` button and automatic PTY navigation.
- Preserve explicit user completion; add no polling and no outer timeout.
- Never mint a fake grant, copy operator credentials, or reuse another session's agent home.
- Grantless bootstrap requires PTY connection, `credential_optional: true`, `credential_source_policy: :session_local`, no selected credential source, no pending grant, and a created-winner witness.
- A sourced cascade without a valid grant must remain fail-closed.
- The provisional agent must not join the session before authenticated completion.
- Do not update architecture baselines or allowlists.
- Do not run `mix precommit`; run focused tests and `mix ci.fast`.

---

### Task 1: Carry an explicit PTY bootstrap request from admission

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agent_lifecycle.ex`
- Test: `apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs`

**Interfaces:**
- Consumes: `CredentialConnection.for_flavor/2` and the existing gated role declaration.
- Produces: template content field `credential_bootstrap: :pty` only for a PTY-backed provisional admission spawn.

- [x] **Step 1: Write a failing provisional-spawn capture test**

Add a test template class/recipe fixture to the existing integration test that captures the compiled template content. Begin admission for a role declared with `credential_admission: :before_session_join`, and assert the captured content contains the bootstrap request:

```elixir
assert {:ok, %{status: :authenticating}} =
         AgentAdmission.begin(session_uri, role_name, @owner_uri, caps)

assert_receive {:captured_provisional_content, content}
assert content[:credential_optional] == true
assert content[:credential_source_policy] == :session_local
assert content[:credential_bootstrap] == :pty
refute Map.has_key?(members_of(session_uri), content[:agent_uri])
```

Also add a non-PTY credential-connection fixture and assert it never receives `credential_bootstrap: :pty`.

- [x] **Step 2: Run the focused test and verify RED**

Run:

```bash
mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs --only test --trace
```

Expected: the new PTY assertion fails because provisional spawn overrides currently contain only `credential_optional`, `credential_source_policy`, and `session_template_member`.

- [x] **Step 3: Add the bootstrap request only for PTY admission**

In `spawn_provisional/4`, resolve the flavor connection and pass the result into `spawn_agent/9`. Build overrides through a helper:

```elixir
defp provisional_content_overrides({:pty, _descriptor}) do
  %{
    credential_optional: true,
    credential_source_policy: :session_local,
    credential_bootstrap: :pty,
    session_template_member: true
  }
end

defp provisional_content_overrides(_connection) do
  %{
    credential_optional: true,
    credential_source_policy: :session_local,
    session_template_member: true
  }
end
```

Resolve the connection using the existing flavor-neutral API and fail if it is unsupported:

```elixir
with {:ok, connection} <-
       Ezagent.Agent.CredentialConnection.for_flavor(flavor, role: declaration),
     ... do
  spawn_agent(..., provisional_content_overrides(connection))
end
```

Change `spawn_agent/9` to accept the overrides map and pass it unchanged as `template_content_overrides`.

- [x] **Step 4: Run the focused test and verify GREEN**

Run the same command. Expected: the new PTY and non-PTY assertions pass, and existing admission tests remain green.

- [x] **Step 5: Commit the admission marker change**

```bash
git add apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agent_lifecycle.ex \
  apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs
git diff --cached --check
git commit -m "fix(session): mark PTY credential bootstrap spawns"
```

---

### Task 2: Validate the bootstrap boundary in cascade resolution

**Files:**
- Modify: `apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn/cascade.ex`
- Test: `apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs`

**Interfaces:**
- Consumes: `credential_bootstrap: :pty`, `credential_optional`, session-local policy, resolved `secret_source`, and template class credential connection.
- Produces: internal cascade field `grantless_bootstrap: :pty` only after all resolver-side conditions are proven.

- [x] **Step 1: Write resolver RED tests**

Add a PTY credential adapter fixture and assert an eligible session-local resolution is marked:

```elixir
content = %{
  credential_optional: true,
  credential_source_policy: :session_local,
  credential_bootstrap: :pty
}

assert {:ok, resolved} =
         Cascade.resolve_content(content, PtyFileTemplate, @agent, @admin, @ws, "codex",
           source_template_uri: @source_tmpl
         )

assert resolved.cascade.grantless_bootstrap == :pty
refute Map.has_key?(resolved.cascade, :pending_grant)
```

Add table-driven negative cases and assert the marker is absent:

```elixir
for invalid <- [
      %{credential_optional: false},
      %{credential_source_policy: :user_default},
      %{credential_bootstrap: nil}
    ] do
  refute get_in(resolved_for(invalid), [:cascade, :grantless_bootstrap]) == :pty
end
```

Add a sourced-cascade case and assert it retains `pending_grant` and never gains the grantless marker.

- [x] **Step 2: Run the resolver tests and verify RED**

```bash
mix test apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs
```

Expected: eligible marker assertion fails because the resolver does not yet produce `grantless_bootstrap`.

- [x] **Step 3: Implement one boundary predicate**

After `build_cascade/5` has returned both `cascade` and `resolved`, call a helper that marks only the fully eligible result:

```elixir
defp maybe_mark_grantless_bootstrap(cascade, content, template_class, resolved) do
  eligible? =
    content_field(content, :credential_bootstrap) in [:pty, "pty"] and
      content_field(content, :credential_optional) in [true, "true"] and
      session_local_policy?(content) and
      resolved.secret_source == nil and
      not Map.has_key?(cascade, :pending_grant) and
      match?({:pty, _}, template_class.credential_connection(role: content))

  if eligible?, do: Map.put(cascade, :grantless_bootstrap, :pty), else: cascade
end
```

Use `function_exported?/3` before invoking `credential_connection/1`; unsupported or malformed declarations must leave the marker absent. Apply the helper to both authored-resolution and default-resolution branches after session-local sanitization.

- [x] **Step 4: Run resolver tests and verify GREEN**

Run the Task 2 test command. Expected: all positive and negative cases pass.

- [x] **Step 5: Commit the validated resolver marker**

```bash
git add apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn/cascade.ex \
  apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs
git diff --cached --check
git commit -m "fix(agent): validate grantless PTY cascade bootstrap"
```

---

### Task 3: Materialize secret-free homes without a grant

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/credential/home_runtime.ex`
- Test: `apps/ezagent_plugin_codex/test/ezagent/template/codex_agent_grant_restart_test.exs`
- Test: `apps/ezagent_plugin_cc/test/ezagent/template/cc_agent_cascade_materialize_test.exs`

**Interfaces:**
- Consumes: `cascade.grantless_bootstrap == :pty`, absent `pending_grant`, a created-winner witness, and the already-merged staging directory.
- Produces: `{:ok, target, nil}` for a valid secret-free bootstrap; grant-backed cascades continue returning `{:ok, target, {:grant, ...}}`.

- [x] **Step 1: Write Codex and CC RED tests**

For each flavor, construct a cascade with configuration layers, no credential source, and an explicit bootstrap marker plus a real created-winner witness fixture. Assert:

```elixir
assert {:ok, ^target, nil} = Template.create_agent_config_dir(agent_uri, tmpl)
assert File.exists?(Path.join(target, ".ezagent-config-complete"))
refute File.exists?(Path.join(target, secret_relpath))
assert GrantRow.get_for_agent(URI.to_string(agent_uri)) == nil
```

Add negative tests proving each invalid shape still returns the current grant error:

```elixir
for cascade <- [
      Map.delete(valid, :grantless_bootstrap),
      Map.put(valid, :pending_grant, pending_grant),
      Map.delete(valid, :created_witness)
    ] do
  assert {:error, {:cascade_materialize_failed, _reason}} =
           Template.create_agent_config_dir(agent_uri, put_in(tmpl["cascade"], cascade))
end
```

- [x] **Step 2: Run both flavor tests and verify RED**

```bash
mix test \
  apps/ezagent_plugin_codex/test/ezagent/template/codex_agent_grant_restart_test.exs \
  apps/ezagent_plugin_cc/test/ezagent/template/cc_agent_cascade_materialize_test.exs
```

Expected: valid bootstrap cases fail with `{:cascade_materialize_failed, :no_grant}`.

- [x] **Step 3: Add a narrowly validated HomeRuntime branch**

In `materialize_cascade/6`, after building the staging directory and completion marker, select one of two private helpers:

```elixir
defp commit_cascade(agent_uri, staging, target, cascade, template_module, opts) do
  case cascade do
    %{
      grantless_bootstrap: :pty,
      created_witness: witness
    } = grantless when not is_map_key(grantless, :pending_grant) ->
      with true <- Ezagent.Kind.CreatedWitness.authorizes?(witness, agent_uri),
           [] <- template_module.secret_relpaths(),
           :ok <- chmod_credential_files(staging, template_module, opts),
           :ok <- swap_into_place(staging, target) do
        {:ok, {target, nil}}
      else
        secret_paths when is_list(secret_paths) ->
          # Secret paths may be declared by the flavor, but none may exist in
          # the secret-free staging tree.
          ensure_secret_paths_absent_and_commit(secret_paths, staging, target, template_module, opts)

        {:error, _} = error -> error
      end

    _ ->
      commit_grant_backed_cascade(agent_uri, staging, target, cascade, template_module, opts)
  end
end
```

`ensure_secret_paths_absent_and_commit/5` must reject any declared secret path that exists in staging, then perform the same chmod and atomic swap. Return `{:ok, target, nil}` through `materialize_cascade/6`. Keep the existing mint, `materialize_with_grant`, revalidation identity, and compensation code byte-for-byte inside `commit_grant_backed_cascade/6`.

Do not treat `:no_grant` from the grant-backed branch as permission to retry grantlessly.

- [x] **Step 4: Run both flavor tests and verify GREEN**

Run the Task 3 command. Expected: both bootstrap cases pass, negative cases fail closed as asserted, and all existing grant lifecycle tests remain green.

- [x] **Step 5: Commit the materializer branch**

```bash
git add apps/ezagent_core/lib/ezagent/credential/home_runtime.ex \
  apps/ezagent_plugin_codex/test/ezagent/template/codex_agent_grant_restart_test.exs \
  apps/ezagent_plugin_cc/test/ezagent/template/cc_agent_cascade_materialize_test.exs
git diff --cached --check
git commit -m "fix(credentials): bootstrap PTY homes without secrets"
```

---

### Task 4: Prove end-to-end provisional PTY admission

**Files:**
- Modify: `apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs`
- Test: `apps/ezagent_plugin_world/test/ezagent/world/world_live_dispatch_routing_test.exs`

**Interfaces:**
- Consumes: `AgentAdmission.begin/4`, the grantless HomeRuntime result (`grant_ctx == nil`), and existing World PTY admission projection.
- Produces: a provisional live agent with an isolated config home and PTY connection metadata, while session membership remains unchanged.

- [x] **Step 1: Add Codex and CC admission integration tests**

Run each plugin in its existing test mode so no real CLI or API key is required. For both flavors:

```elixir
assert {:ok,
        %{
          status: :authenticating,
          provisional_agent_uri: provisional_uri,
          connection: {:pty, %{label: label}}
        }} = AgentAdmission.begin(session_uri, role_name, @owner_uri, caps)

assert label in ["Connect Codex", "Connect Claude"]
assert {:ok, agent_uri} = Ezagent.URI.parse(provisional_uri)
assert Ezagent.Kind.alive?(agent_uri)
assert Ezagent.Domain.Pty.alive?(agent_uri)
refute Map.has_key?(members_of(session_uri), agent_uri)
assert GrantRow.get_for_agent(provisional_uri) == nil
```

Simulate absent authentication and assert explicit completion does not join:

```elixir
assert {:error, :authentication_failed, _failed} =
         AgentAdmission.complete(session_uri, role_name, attempt_id, {@owner_uri, caps})

refute Map.has_key?(members_of(session_uri), agent_uri)
```

- [x] **Step 2: Run the integration tests and verify RED or current coverage gap**

```bash
mix test apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs
```

Expected before the full fix: Codex/CC `begin` returns the original `{:agent_spawn_failed, ..., {:cascade_materialize_failed, :no_grant}}`; after Tasks 1-3 it must reach the PTY assertions.

- [x] **Step 3: Make only test-seam adjustments required by real plugin test modes**

Reuse existing `:test_mode` application configuration and existing PTY fakes. Do not add production branches keyed by `Mix.env()`. If the integration test needs deterministic readiness, use the existing plugin test-mode readiness hooks and condition-based assertions already present in each plugin's tests.

- [x] **Step 4: Run integration and World action tests**

```bash
mix test \
  apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/world_live_dispatch_routing_test.exs
```

Expected: all tests pass; begin exposes PTY, failed completion leaves the agent outside membership, and the existing World action still switches to the admission PTY.

- [x] **Step 5: Commit the end-to-end regression coverage**

```bash
git add apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/world_live_dispatch_routing_test.exs
git diff --cached --check
git commit -m "test(session): cover PTY credential admission bootstrap"
```

---

### Task 5: Final review and PR verification

**Files:**
- Modify: `docs/superpowers/plans/2026-08-03-pty-credential-admission-bootstrap.md` (check completed steps)

**Interfaces:**
- Consumes: all implementation commits from Tasks 1-4.
- Produces: formatter-clean code, green affected gates, and a pushed PR 1651 head.

- [x] **Step 1: Format and inspect the complete diff**

```bash
mix format \
  apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator/definition_agent_lifecycle.ex \
  apps/ezagent_domain_agent/lib/ezagent/entity/agent/template_spawn/cascade.ex \
  apps/ezagent_core/lib/ezagent/credential/home_runtime.ex \
  apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs \
  apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs \
  apps/ezagent_plugin_codex/test/ezagent/template/codex_agent_grant_restart_test.exs \
  apps/ezagent_plugin_cc/test/ezagent/template/cc_agent_cascade_materialize_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/world_live_dispatch_routing_test.exs
git diff --check
git diff --stat
git diff
```

Expected: no formatter or whitespace errors; no unrelated changes, baselines, or allowlists.

- [x] **Step 2: Run focused regression suites**

```bash
mix test \
  apps/ezagent_domain_agent/test/ezagent/entity/agent/template_spawn/cascade_credential_optional_test.exs \
  apps/ezagent_plugin_codex/test/ezagent/template/codex_agent_grant_restart_test.exs \
  apps/ezagent_plugin_cc/test/ezagent/template/cc_agent_cascade_materialize_test.exs \
  apps/ezagent_domain_session/test/integration/definition_agents_materialize_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/world_live_dispatch_routing_test.exs
```

Expected: zero failures.

- [x] **Step 3: Run architecture and fast CI gates**

```bash
mix test \
  apps/ezagent_core/test/architecture/cross_file_duplicate_fn_test.exs \
  apps/ezagent_core/test/invariants/plugin_workspace_locality_contract_test.exs
mix ci.fast
```

Expected: both commands exit 0. On any failure, stop and report it before pushing.

Verification note: `mix ci.fast` exposed and led to fixing the accidental
`spawn_bound_agent/9` chokepoint change. Its second run passed invariant and
socialware phases, then one source-scanning architecture test exceeded ExUnit's
60-second budget under full-suite load. That test passed alone in 15.5 seconds,
and the exact `gate.arch` file set passed 757 tests with `--timeout 120000`.

- [ ] **Step 4: Commit plan status and push**

```bash
git add docs/superpowers/plans/2026-08-03-pty-credential-admission-bootstrap.md
git diff --cached --check
git commit -m "docs(session): record PTY bootstrap verification"
git push origin HEAD:refs/heads/docs/hello-llm-connection-design
```

- [ ] **Step 5: Restart the isolated service and verify the manual-test entry**

Restart only the process whose cwd is this worktree, preserving:

```text
PORT=10042
POSTGRES_PORT=55432
POSTGRES_DB=ezagent_pr1651_hello_llm_connection_design_dev
EZAGENT_HOME=/home/lenovo/.ezagent/pr1651-hello-llm-connection-design
WORLD_VITE_PORT=5173
```

Then verify:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' http://world.localhost:10042/login
```

Expected: HTTP `200`. Manual flow: recreate or retry the `llm` admission in `hello-codex-1`, click `Connect Codex`, confirm automatic PTY navigation, run `codex login`, then click the existing completion action.
