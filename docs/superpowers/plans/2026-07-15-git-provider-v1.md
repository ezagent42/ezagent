# Git Provider V1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a provider-neutral, CapBAC-gated Git development path with Entity-owned SSH identities, a first GitHub adapter, pre-sidecar task workspaces, and self-service credential configuration.

**Architecture:** A new `ezagent_domain_git` app owns provider-neutral Resource Kinds, Behaviors, adapter registration, the Git operation broker, and task provisioning. `ezagent_domain_identity` owns versioned SSH identity metadata and the secret-store contract. A new `ezagent_plugin_github` app owns GitHub OAuth/account metadata and implements the provider adapter. Agent and provisioner calls target a `GitTaskAccess` Resource through Router dispatch; plugins are resolved only after CapBAC authorization.

**Tech Stack:** Elixir/OTP, Phoenix 1.8 LiveView, Ecto/PostgreSQL, Req, erlexec through `Ezagent.Runtime.OsProcess`, ExUnit, Mimic/BYPASS only where already available, agent-browser for canary evidence.

## Global Constraints

- Follow `docs/superpowers/specs/2026-07-15-git-provider-v1-design.md` and `docs/superpowers/notes/2026-07-15-demo-provisioning-constraints.md`.
- Use only registered URI schemes; Git resources use `resource://<workspace>/<type>/<id>`.
- GitHub is a plugin; no core/domain module may reference a GitHub implementation module.
- No OAuth token, SSH private key, credential path, file descriptor, or credential-bearing environment reaches an agent process, prompt, transcript, task card, snapshot, event, audit payload, or log.
- Every agent/provisioner operation enters through Router dispatch and a declared required cap before any filesystem, secret-store, provision-record, or provider API mutation.
- Use the current Capability axes only: kind, Behavior/action, instance, workspace, and provenance. Do not add expiry or modify EntityCaps A/B/D, `caps_json`, or no-tail enforcement.
- Governance issues artifacts through `Cap.issue`; the grantee self-stores and verifies them. Do not claim cryptographic signing unless Capability Phase 4 has landed before implementation.
- Use `Ezagent.Runtime.OsProcess` for Git subprocesses; do not use raw `Port.open`, `System.cmd`, MuonTrap, or a new OS-process library.
- Use Req for GitHub HTTP calls; do not add HTTPoison, Tesla, or `:httpc`.
- Provision `project_cwd` before starting the sidecar; each task generation has an isolated worktree and one-use start token.
- GitHub merge remains lead/human-controlled. Do not deploy or merge without lead authorization.
- The W29 demo remains loose-coupled; #1360 Layer B is pending. cc-PTY bridge join/#1405 is not in scope.
- Implement all behavior changes with strict red-green TDD. Run focused regression tests after every task and `mix precommit` before handoff.

---

### Task 1: Discovery and go/no-go evidence

**Files:**
- Create: `docs/superpowers/notes/2026-07-15-git-provider-v1-discovery.md`
- Inspect: `apps/ezagent_core/lib/ezagent/runtime/os_process.ex`
- Inspect: `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter.ex`
- Inspect: `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_registry.ex`
- Inspect: `apps/ezagent_core/lib/ezagent/capability.ex`
- Inspect: `apps/ezagent_core/lib/ezagent/router.ex`
- Inspect: `apps/ezagent_domain_identity/lib/ezagent/behavior/user_default_credential_source.ex`

**Interfaces:**
- Consumes: current repository primitives and the approved V1 design.
- Produces: a decision record selecting the secret backend interface, SSH parser, broker isolation mechanism, adapter registry seam, and explicit go/no-go result.

- [ ] **Step 1: Capture the current primitive inventory**

Run:

```bash
rg -n "defmodule|@callback|def spawn|def stop" \
  apps/ezagent_core/lib/ezagent/runtime/os_process.ex \
  apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/{adapter,adapter_registry}.ex
rg -n "defstruct|def cap|def matches|def issue|def verify" \
  apps/ezagent_core/lib/ezagent/{capability,cap}.ex
rg -n "secret|encrypt|credential" apps config -g '*.ex' -g '*.exs'
```

Expected: evidence for erlexec lifecycle and adapter registration; an explicit answer whether an approved encrypted secret backend already exists.

- [ ] **Step 2: Prove the agent boundary experimentally**

Create a disposable test process using `Ezagent.Runtime.OsProcess.spawn/2` and record whether OS-user separation, mount namespace isolation, or only process-group cleanup exists. Do not place a real secret in the experiment; use the sentinel `EZAGENT_SECRET_SENTINEL_DO_NOT_SHIP`.

Run:

```bash
MIX_ENV=test mix test apps/ezagent_core/test/ezagent/runtime/os_process_test.exs
```

Expected: PASS, followed by a discovery note stating which stronger isolation primitive is required for the broker.

- [ ] **Step 3: Write the go/no-go note**

The note must contain this exact decision table with evidence-filled selections:

```markdown
| Decision | Required property | Selected repository primitive | Evidence command | Gate |
|---|---|---|---|---|
| Secret backend | encrypted at rest; opaque refs; version create/read/delete | approved existing abstraction or a separately designed new abstraction | `rg ...` | GO/NO-GO |
| SSH parser | OpenSSH Ed25519/RSA; fixed safe errors; no shell | OTP/library already in dependency graph | `mix deps` | GO/NO-GO |
| Git broker | argv-safe erlexec; credential inaccessible to agent; crash cleanup | `Ezagent.Runtime.OsProcess` plus named isolation mechanism | focused ExUnit probe | GO/NO-GO |
| Adapter seam | duplicate-safe string ID; plugin boot rollback | domain-owned registry modeled on ExternalMirror | focused registry tests | GO/NO-GO |
| Capability | exact Resource instance/action/workspace | current `Ezagent.Capability` | focused cap test | GO/NO-GO |
```

The final line must be either `Decision: GO` or `Decision: NO-GO: <specific missing primitive>`. Stop the implementation if any security row is NO-GO; write a separate prerequisite design instead of weakening the boundary.

- [ ] **Step 4: Verify and commit**

Run:

```bash
git diff --check
rg -n "Decision: (GO|NO-GO)" docs/superpowers/notes/2026-07-15-git-provider-v1-discovery.md
git add docs/superpowers/notes/2026-07-15-git-provider-v1-discovery.md
git commit -m "docs(git): record provider V1 discovery gate"
```

Expected: one decision note commit. Continue only with `Decision: GO`.

---

### Task 2: Provider-neutral Git Resources, Behaviors, and adapter registry

**Files:**
- Create: `apps/ezagent_domain_git/mix.exs`
- Create: `apps/ezagent_domain_git/lib/ezagent_domain_git/application.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/git_provider/adapter.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/git_provider/adapter_registry.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/git_provider/repository_ref.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/entity/git_repository.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/entity/git_provider_binding.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/entity/git_task_access.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex`
- Modify: `apps/ezagent_core/lib/ezagent_core/ets_owner.ex`
- Test: `apps/ezagent_domain_git/test/ezagent/git_provider/adapter_registry_test.exs`
- Test: `apps/ezagent_domain_git/test/ezagent/git_provider/repository_ref_test.exs`
- Test: `apps/ezagent_domain_git/test/ezagent/behavior/git_task_access_test.exs`
- Test: `apps/ezagent_domain_git/test/invariants/provider_contract_test.exs`

**Interfaces:**
- Consumes: registered Resource URI shape and `Ezagent.Capability.cap/5`.
- Produces: `Ezagent.GitProvider.Adapter`, `AdapterRegistry.register/1`, `RepositoryRef.new/1`, `GitTaskAccess.uri/2`, and Router-dispatched provider-neutral actions.

- [ ] **Step 1: Write failing URI and registry tests**

```elixir
test "task access uses the registered resource scheme" do
  uri = Ezagent.Entity.GitTaskAccess.uri("demo", "task-42-g1")
  assert URI.to_string(uri) == "resource://demo/git_task_access/task-42-g1"
  assert {:ok, ^uri} = Ezagent.URI.parse(URI.to_string(uri))
end

test "a duplicate adapter id from another module fails loud" do
  assert :ok = AdapterRegistry.register(TestGithubAdapter)
  assert_raise ArgumentError, ~r/already registered/, fn ->
    AdapterRegistry.register(DuplicateGithubAdapter)
  end
end
```

- [ ] **Step 2: Run the tests and confirm RED**

Run:

```bash
mix test apps/ezagent_domain_git/test/ezagent/git_provider/adapter_registry_test.exs \
  apps/ezagent_domain_git/test/ezagent/git_provider/repository_ref_test.exs
```

Expected: FAIL because the app/modules do not exist.

- [ ] **Step 3: Implement the minimal provider contract**

The adapter contract must use normalized structs and must not accept credential material:

```elixir
defmodule Ezagent.GitProvider.Adapter do
  @callback adapter_id() :: String.t()
  @callback resolve_repository(Ezagent.GitProvider.RepositoryRef.t(), map()) ::
              {:ok, map()} | {:error, atom()}
  @callback check_access(map(), :read | :push, map()) :: :ok | {:error, atom()}
  @callback create_change_request(map(), map(), map()) :: {:ok, map()} | {:error, atom()}
  @callback get_change_request(map(), String.t(), map()) :: {:ok, map()} | {:error, atom()}
  @callback list_checks(map(), String.t(), map()) :: {:ok, [map()]} | {:error, atom()}
  @callback list_reviews(map(), String.t(), map()) :: {:ok, [map()]} | {:error, atom()}
end
```

Implement `AdapterRegistry` with atomic `:ets.insert_new/2`, idempotent same-module registration, fail-loud duplicate IDs, string IDs only, and an ETS table owned by `EzagentCore.EtsOwner`.

- [ ] **Step 4: Implement Resource URI constructors and Behavior actions**

`GitTaskAccess` exposes distinct actions for `:repository_read`, `:branch_push`, `:change_request_create`, `:change_request_read`, `:checks_read`, and `:reviews_read`. Each `required_caps/0` entry targets kind `:git_task_access`; handlers load the authoritative task policy before adapter lookup.

```elixir
def uri(workspace, stable_id) do
  Ezagent.URI.resource(workspace, "git_task_access", stable_id)
end
```

- [ ] **Step 5: Add invariant tests**

Assert that no `gitrepo://` string exists under `apps/`, domain code does not reference `Ezagent.PluginGithub`, every action has a required cap, and registering a second provider does not attach another provider-neutral Behavior.

Run:

```bash
mix test apps/ezagent_domain_git/test
mix ezagent.arch.scan
```

Expected: PASS with zero invariant failures.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_domain_git apps/ezagent_core/lib/ezagent_core/ets_owner.ex
git commit -m "feat(git): add provider-neutral resource contract"
```

---

### Task 3: Versioned Entity SSH Identity and secret ingress

**Files:**
- Create: `apps/ezagent_core/priv/repo/migrations/20260715010000_create_entity_ssh_identities.exs`
- Create: `apps/ezagent_domain_identity/lib/ezagent/ssh_identity.ex`
- Create: `apps/ezagent_domain_identity/lib/ezagent/ssh_identity/version.ex`
- Create: `apps/ezagent_domain_identity/lib/ezagent/ssh_identity/secret_store.ex`
- Create: `apps/ezagent_domain_identity/lib/ezagent/ssh_identity/import.ex`
- Create: `apps/ezagent_domain_identity/lib/ezagent/ssh_identity/reconciler.ex`
- Create: `apps/ezagent_domain_identity/lib/ezagent/behavior/ssh_identity.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex`
- Test: `apps/ezagent_domain_identity/test/ezagent/ssh_identity/import_test.exs`
- Test: `apps/ezagent_domain_identity/test/ezagent/ssh_identity/rotation_test.exs`
- Test: `apps/ezagent_domain_identity/test/ezagent/ssh_identity/reconciler_test.exs`
- Test: `apps/ezagent_domain_identity/test/invariants/ssh_secret_non_persistence_test.exs`

**Interfaces:**
- Consumes: secret backend selected by Task 1.
- Produces: `SSHIdentity.generate/2`, `SSHIdentity.import/3`, `SSHIdentity.active_metadata/1`, `SSHIdentity.lease_active/2`, `SSHIdentity.release/1`, and `SSHIdentity.revoke/2`. No private-key getter exists.

- [ ] **Step 1: Write failing import and rotation tests**

```elixir
test "unsupported or encrypted input returns a fixed error" do
  assert {:error, :unsupported_private_key} =
           SSHIdentity.import(user_uri, encrypted_fixture(), actor: user_uri)
end

test "failed staged replacement preserves the old active version" do
  {:ok, old} = SSHIdentity.generate(user_uri, actor: user_uri)
  FakeSecretStore.fail_next!(:put)
  assert {:error, :secret_store_unavailable} =
           SSHIdentity.import(user_uri, valid_ed25519_fixture(), actor: user_uri)
  assert {:ok, %{fingerprint: old.fingerprint}} = SSHIdentity.active_metadata(user_uri)
end
```

- [ ] **Step 2: Run and confirm RED**

```bash
mix test apps/ezagent_domain_identity/test/ezagent/ssh_identity/import_test.exs \
  apps/ezagent_domain_identity/test/ezagent/ssh_identity/rotation_test.exs
```

Expected: FAIL with undefined SSH identity modules.

- [ ] **Step 3: Add schema and migration**

Persist only Entity URI, public key, fingerprint, algorithm, opaque secret ref,
version, state (`staged|active|tombstoned|revoked`), operation id, lease count,
and timestamps. Add a partial unique index allowing one active row per Entity.
Never add a private-key column.

- [ ] **Step 4: Implement fixed-format parsing and generation**

Accept only unencrypted OpenSSH Ed25519 and policy-compliant RSA. Enforce request
byte/line limits before parser invocation. Map all parser failures to the fixed
taxonomy `:too_large | :unsupported_private_key | :malformed_private_key`.

- [ ] **Step 5: Implement CAS rotation and reconciliation**

Stage the secret with an operation ID, switch active version using an Ecto
transaction/CAS, lease versions during broker use, tombstone after leases drain,
and asynchronously retry secret deletion. Tests must cover crash after secret put,
crash after active switch, concurrent replace/revoke, and idempotent replay.

- [ ] **Step 6: Prove non-persistence and redaction**

The invariant test scans snapshot/event/audit/log representations and asserts the
fixture private-key sentinel is absent. Include exception and task-crash paths.

Run:

```bash
mix test apps/ezagent_domain_identity/test/ezagent/ssh_identity \
  apps/ezagent_domain_identity/test/invariants/ssh_secret_non_persistence_test.exs
mix ecto.migrate
```

Expected: PASS; migration contains no private material column.

- [ ] **Step 7: Commit**

```bash
git add apps/ezagent_core/priv/repo/migrations/20260715010000_create_entity_ssh_identities.exs \
  apps/ezagent_domain_identity
git commit -m "feat(identity): add versioned SSH identities"
```

---

### Task 4: Non-exporting Git Operation Broker

**Files:**
- Create: `apps/ezagent_domain_git/lib/ezagent/git_operation/broker.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/git_operation/operation.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/git_operation/host_key_policy.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/git_operation/credential_cleanup.ex`
- Modify: `apps/ezagent_domain_git/lib/ezagent_domain_git/application.ex`
- Test: `apps/ezagent_domain_git/test/ezagent/git_operation/broker_test.exs`
- Test: `apps/ezagent_domain_git/test/invariants/agent_secret_boundary_test.exs`

**Interfaces:**
- Consumes: `SSHIdentity.lease_active/2`, normalized repository endpoints, and `Ezagent.Runtime.OsProcess.spawn/2`.
- Produces: `Broker.run(%Operation{}, context)` returning only `{:ok, normalized_result}` or a normalized error.

- [ ] **Step 1: Write failing broker boundary tests**

```elixir
test "result and agent environment never contain credential artifacts" do
  op = Operation.fetch(task_access_uri, repository_uri, "main")
  assert {:ok, result} = Broker.run(op, authorized_context())
  refute inspect(result) =~ "PRIVATE KEY"
  refute Map.has_key?(result, :credential_path)
  refute Map.has_key?(result, :env)
end
```

Add tests for success, non-zero exit, timeout, caller cancellation, broker crash,
host-key mismatch, malicious ref beginning with `-`, symlink/hook attempts, and
credential cleanup in every terminal path.

- [ ] **Step 2: Run and confirm RED**

```bash
mix test apps/ezagent_domain_git/test/ezagent/git_operation/broker_test.exs
```

Expected: FAIL because Broker does not exist.

- [ ] **Step 3: Implement structured operations**

`Operation` accepts parsed Resource URIs and validated refs only. Broker builds an
argv list, never a shell string, pins known-host policy, runs Git itself through
`Ezagent.Runtime.OsProcess`, traps exits, enforces timeout, stops the process group,
releases the SSH identity lease, and removes broker-owned artifacts.

- [ ] **Step 4: Add architecture gates**

Assert no new code uses `System.cmd`, raw `Port.open`, or returns keys, paths,
file descriptors, or credential environments. Assert the agent process tree
cannot read the broker credential artifact using the isolation proven in Task 1.

Run:

```bash
mix test apps/ezagent_domain_git/test/ezagent/git_operation \
  apps/ezagent_domain_git/test/invariants/agent_secret_boundary_test.exs
mix ezagent.arch.scan
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_git
git commit -m "feat(git): add isolated Git operation broker"
```

---

### Task 5: GitHub provider plugin and OAuth binding

**Files:**
- Create: `apps/ezagent_plugin_github/mix.exs`
- Create: `apps/ezagent_plugin_github/lib/ezagent_plugin_github.ex`
- Create: `apps/ezagent_plugin_github/lib/ezagent_plugin_github/application.ex`
- Create: `apps/ezagent_plugin_github/lib/ezagent/plugin_github/adapter.ex`
- Create: `apps/ezagent_plugin_github/lib/ezagent/plugin_github/client.ex`
- Create: `apps/ezagent_plugin_github/lib/ezagent/plugin_github/binding_store.ex`
- Create: `apps/ezagent_core/priv/repo/migrations/20260715020000_create_git_provider_bindings.exs`
- Test: `apps/ezagent_plugin_github/test/ezagent/plugin_github/adapter_test.exs`
- Test: `apps/ezagent_plugin_github/test/ezagent/plugin_github/client_test.exs`
- Test: `apps/ezagent_plugin_github/test/invariants/token_isolation_test.exs`
- Test: `apps/ezagent_domain_git/test/support/second_provider_adapter.ex`

**Interfaces:**
- Consumes: `Ezagent.GitProvider.Adapter` and domain-owned binding envelope.
- Produces: adapter ID `"github"`, GitHub OAuth binding metadata, repository permission facts, normalized change-request/check/review results.

- [ ] **Step 1: Write failing adapter contract tests**

```elixir
test "GitHub pull request maps to a normalized change request" do
  assert {:ok, %{id: "17", state: :open, head_ref: "feat/demo"}} =
           Adapter.create_change_request(repo(), request(), binding_context())
end

test "caller cannot choose another provider account" do
  assert {:error, :provider_binding_mismatch} =
           Adapter.check_access(repo(), :push, forged_account_context())
end
```

- [ ] **Step 2: Run and confirm RED**

```bash
mix test apps/ezagent_plugin_github/test
```

Expected: FAIL because the plugin does not exist.

- [ ] **Step 3: Implement plugin boot registration**

Register the adapter once through the domain registry. The plugin owns only
GitHub-specific external-account metadata and its encrypted OAuth-token reference.
Do not attach a duplicate provider-neutral Behavior.

- [ ] **Step 4: Implement Req client and normalization**

Use Req with explicit base URL, Authorization redaction, bounded timeouts, and
safe GitHub request IDs. Implement repository permission probe, create/get pull
request, list checks, and list reviews. Never return raw response maps upstream.

- [ ] **Step 5: Add fake second-provider conformance**

Run the same domain contract suite against `SecondProviderAdapter`; prove no
GitHub module or vocabulary is required outside the GitHub plugin.

Run:

```bash
mix test apps/ezagent_plugin_github/test apps/ezagent_domain_git/test/invariants/provider_contract_test.exs
mix ezagent.arch.scan
```

Expected: PASS and no token sentinel in captured logs/events.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_plugin_github \
  apps/ezagent_core/priv/repo/migrations/20260715020000_create_git_provider_bindings.exs \
  apps/ezagent_domain_git/test/support/second_provider_adapter.ex
git commit -m "feat(github): add first Git provider adapter"
```

---

### Task 6: Governed GitTaskAccess materialization and task caps

**Files:**
- Create: `apps/ezagent_core/priv/repo/migrations/20260715030000_create_git_task_accesses.exs`
- Create: `apps/ezagent_domain_git/lib/ezagent/git_task_access/store.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/git_task_access/materializer.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/git_task_access/cap_issuer.ex`
- Test: `apps/ezagent_domain_git/test/ezagent/git_task_access/materializer_test.exs`
- Test: `apps/ezagent_domain_git/test/ezagent/git_task_access/cap_issuer_test.exs`
- Test: `apps/ezagent_domain_git/test/invariants/unauthorized_no_effect_test.exs`

**Interfaces:**
- Consumes: governed task facts and current `Cap.issue`/self-store/verify flow.
- Produces: idempotent `Materializer.materialize(task, generation, assignment)` and exact instance-scoped cap artifacts.

- [ ] **Step 1: Write failing governance tests**

```elixir
test "materialization is idempotent for task URI plus generation" do
  assert {:ok, first} = Materializer.materialize(task(), 1, assignment())
  assert {:ok, second} = Materializer.materialize(task(), 1, assignment())
  assert first.task_access_uri == second.task_access_uri
end

test "branch push does not imply change-request creation" do
  push_cap = issued_cap(:branch_push)
  refute Capability.matches?(push_cap, required_cap(:change_request_create))
end
```

- [ ] **Step 2: Run and confirm RED**

```bash
mix test apps/ezagent_domain_git/test/ezagent/git_task_access
```

Expected: FAIL because materialization is missing.

- [ ] **Step 3: Implement trusted materialization**

Governance creates immutable task policy and a planned provision record using
`{task_uri, generation}` as the unique idempotency key, then calls `Cap.issue`
for exact `GitTaskAccess` Resource instance/actions. The agent self-stores the
artifact. Caller-provided provider account, repository, or branch values are not
accepted after materialization.

- [ ] **Step 4: Prove unauthorized no-effect behavior**

Dispatch without the exact cap and assert no provision row transition, filesystem
entry, secret-store lease, broker spawn, or provider client request occurs.

Run:

```bash
mix test apps/ezagent_domain_git/test/ezagent/git_task_access \
  apps/ezagent_domain_git/test/invariants/unauthorized_no_effect_test.exs
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_core/priv/repo/migrations/20260715030000_create_git_task_accesses.exs \
  apps/ezagent_domain_git
git commit -m "feat(git): materialize governed task access"
```

---

### Task 7: Idempotent pre-sidecar Workspace Provisioner

**Files:**
- Create: `apps/ezagent_core/priv/repo/migrations/20260715040000_create_git_task_provisions.exs`
- Create: `apps/ezagent_domain_git/lib/ezagent/git_workspace/provision.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/git_workspace/provision_store.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/git_workspace/reaper.ex`
- Create: `apps/ezagent_domain_git/lib/ezagent/git_workspace/start_token.ex`
- Modify: `apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_agent.ex`
- Test: `apps/ezagent_domain_git/test/ezagent/git_workspace/provision_test.exs`
- Test: `apps/ezagent_domain_git/test/ezagent/git_workspace/recovery_test.exs`
- Test: `apps/ezagent_domain_git/test/integration/provision_before_sidecar_test.exs`

**Interfaces:**
- Consumes: pre-existing `GitTaskAccess`, Router-authorized operation, provider endpoint facts, and Broker.
- Produces: `Provision.ensure_ready(task_access_uri, ctx)` and one-use `StartToken.consume/2` returning a verified `project_cwd`.

- [ ] **Step 1: Write failing ordering/idempotency tests**

```elixir
test "sidecar start is impossible before project_cwd is ready" do
  assert {:error, :workspace_not_ready} = StartToken.consume(task_access_uri(), generation())
  refute sidecar_started?()
end

test "duplicate claim starts one provision and one sidecar" do
  results = Task.async_stream(1..2, fn _ -> Provision.ensure_ready(uri(), ctx()) end) |> Enum.to_list()
  assert Enum.all?(results, &match?({:ok, {:ok, _}}, &1))
  assert count_worktrees(uri()) == 1
  assert count_start_tokens(uri()) == 1
end
```

- [ ] **Step 2: Run and confirm RED**

```bash
mix test apps/ezagent_domain_git/test/ezagent/git_workspace \
  apps/ezagent_domain_git/test/integration/provision_before_sidecar_test.exs
```

Expected: FAIL because provisioner modules do not exist.

- [ ] **Step 3: Implement durable state machine**

Persist `planned|provisioning|ready|sidecar_started|cleanup_pending|cleaned|blocked`,
lease owner/expiry, deterministic worktree path and branch, generation, and a
hashed one-use start token. Use a per-task-generation lock plus CAS transitions.

- [ ] **Step 4: Implement recovery and reaping**

Cover crashes after fetch, worktree creation, ready CAS, and token consumption.
The reaper requires expired lease plus no live matching generation/process before
cleanup. Cancellation racing startup closes the generation and invalidates the
token before cleanup.

- [ ] **Step 5: Wire before sidecar startup**

At the materialization entry point, call `Provision.ensure_ready/2`, verify the
directory exists, consume the start token once, and only then start cc-headless
with `project_cwd`. A failure returns a structured blocker and starts no sidecar.

Run:

```bash
mix test apps/ezagent_domain_git/test/ezagent/git_workspace \
  apps/ezagent_domain_git/test/integration/provision_before_sidecar_test.exs
```

Expected: PASS, including duplicate claim and crash recovery.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_core/priv/repo/migrations/20260715040000_create_git_task_provisions.exs \
  apps/ezagent_domain_git apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_agent.ex
git commit -m "feat(git): provision task workspaces before sidecars"
```

---

### Task 8: Self-service SSH and GitHub settings UI

**Files:**
- Modify: `apps/ezagent_web/lib/ezagent_web/router.ex`
- Modify: `apps/ezagent_plugin_world/lib/ezagent/plugin_world/world_live.ex`
- Create: `apps/ezagent_plugin_world/lib/ezagent/plugin_world/git_credentials_view.ex`
- Test: `apps/ezagent_plugin_world/test/ezagent/world/git_credentials_view_test.exs`
- Test: `apps/ezagent_plugin_world/test/ezagent/world/git_credentials_live_test.exs`

**Interfaces:**
- Consumes: SSH Identity public operations and GitHub provider binding operations.
- Produces: `/profile/git` surface with generate/import/replace/revoke, GitHub connect/disconnect, and separate API/Git readiness.

- [ ] **Step 1: Write failing LiveView tests against stable DOM IDs**

```elixir
test "profile Git page separates SSH and provider readiness", %{conn: conn} do
  {:ok, view, _html} = live(conn, "/profile/git")
  assert has_element?(view, "#ssh-identity-panel")
  assert has_element?(view, "#github-provider-panel")
  assert has_element?(view, "#ssh-private-key-import-form")
end
```

- [ ] **Step 2: Run and confirm RED**

```bash
mix test apps/ezagent_plugin_world/test/ezagent/world/git_credentials_live_test.exs
```

Expected: FAIL because the route/view does not exist.

- [ ] **Step 3: Implement the authenticated route and LiveView surface**

Begin rendering through `<Layouts.app flash={@flash} current_scope={@current_scope}>`.
Use `to_form/2`, `<.form>`, `<.input>`, unique DOM IDs, recent re-authentication,
CSRF protection, strict input limits, and cleared sensitive assigns immediately
after submit. Never render or redisplay private material.

- [ ] **Step 4: Implement readiness and fixed errors**

Show public key/fingerprint/provenance and separate `API ready` from `Git transport
ready`. Map import failures only to the fixed error taxonomy. Provider readiness
runs after identity replacement and does not roll it back.

Run:

```bash
mix test apps/ezagent_plugin_world/test/ezagent/world/git_credentials_view_test.exs \
  apps/ezagent_plugin_world/test/ezagent/world/git_credentials_live_test.exs
```

Expected: PASS with selector-based assertions and no raw HTML assertions.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_web/lib/ezagent_web/router.ex apps/ezagent_plugin_world
git commit -m "feat(world): add Git credential settings"
```

---

### Task 9: Kanban projection and real W29 canary closed loop

**Files:**
- Create: `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/git_flow_projection.ex`
- Modify: `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban_render.ex`
- Modify: `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/board_view.ex`
- Test: `apps/ezagent_plugin_kanban/test/git_flow_projection_test.exs`
- Create: `apps/ezagent_domain_git/test/integration/kanban_git_flow_test.exs`
- Create: `docs/e2e/2026-07-15-git-provider-v1/README.md`
- Create: `docs/together/2026-07-15/returns/git-provider-v1.md`

**Interfaces:**
- Consumes: confirmed provision/provider facts.
- Produces: normalized Kanban states and canary evidence for dispatch → agent → change request → CI/review → human merge → done.

- [ ] **Step 1: Write the failing projection test**

```elixir
test "done requires a confirmed merged or accepted terminal fact" do
  state = project([:change_request_open, :checks_passed, :review_ready])
  assert state == :awaiting_human_merge
  assert project([:change_request_open, :checks_passed, :review_ready, :merged]) == :done
end
```

- [ ] **Step 2: Run and confirm RED**

```bash
mix test apps/ezagent_domain_git/test/integration/kanban_git_flow_test.exs
```

Expected: FAIL because the provider-neutral projection is missing.

- [ ] **Step 3: Implement confirmed-fact projection**

Project the detailed Git flow into a dedicated card artifact displayed by
`KanbanRender`/`BoardView`: `assigned -> provisioning -> ready -> agent_working
-> change_request_open -> ci_running -> review_ready -> awaiting_human_merge ->
merged -> done`, with structured `blocked` reasons. Preserve Kanban's existing
coarse node-status contract (`unassigned|claimed|doing|done`): map pre-work to
`claimed`, active/waiting/blocked flow to `doing`, and only confirmed merged or
explicitly accepted terminal work to `done`. Never move optimistically before an
external operation succeeds.

- [ ] **Step 4: Run repository gates**

```bash
mix test apps/ezagent_domain_identity/test \
  apps/ezagent_domain_git/test \
  apps/ezagent_plugin_github/test \
  apps/ezagent_plugin_world/test/ezagent/world/git_credentials_live_test.exs
mix compile --warnings-as-errors
mix format --check-formatted
mix ezagent.arch.scan
mix precommit
```

Expected: every command exits 0 with zero failures/warnings.

- [ ] **Step 5: Verify canary preconditions without modifying live state**

Verify the test user's LLM credential, SSH identity readiness, GitHub OAuth
binding, exact board/task caps, repository access, and cc-headless
`:in_process_sync`. Use UI/API production paths only; no raw RPC, eval, live DB
write, wildcard cap, deploy, or merge.

- [ ] **Step 6: Execute the authorized real canary loop**

After lead authorizes deployment and merge actions, capture:

```text
Kanban assignment and every state transition
agent-browser screenshots and transcript
task generation / GitTaskAccess / provision IDs
project_cwd created before sidecar evidence
real change-request URL and head SHA
PR-head CI checks and review state
lead/human merge fact
structured blockers, reproduction commands, host, image/release SHA, timestamp
```

If lead authorization is absent, stop at the reviewable PR/head-CI state and
record merge/done as not executed rather than manufacturing evidence.

- [ ] **Step 7: Write the dev-together return and commit**

```bash
git add apps docs/e2e/2026-07-15-git-provider-v1 \
  docs/together/2026-07-15/returns/git-provider-v1.md
git commit -m "test(git): prove provider-backed development loop"
```

The return must include base/head SHA, commands with outputs, evidence paths,
real change-request link, CI/review status, blockers/skips, and the honesty label
“loose-coupled, not final mount; #1360 Layer B pending.”

---

## Final review gate

- [ ] Re-read every acceptance criterion in the design and link it to a passing test or canary artifact.
- [ ] Run `rg -n "T[B]D|T[O]DO|implement l[a]ter|appropriate error h[a]ndling|tests for the a[b]ove" docs/superpowers/plans/2026-07-15-git-provider-v1.md`; expected output is empty.
- [ ] Run `git diff --check`; expected exit 0.
- [ ] Request architecture/security review over the full implementation range.
- [ ] Fix every Critical and Important finding, rerun focused tests, then rerun `mix precommit`.
- [ ] Do not push, deploy, merge, or clean the worktree without the corresponding lead/user authorization.
