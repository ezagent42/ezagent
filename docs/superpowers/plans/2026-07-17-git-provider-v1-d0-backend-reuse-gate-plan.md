# Git Provider V1 D0 Backend Reuse Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce executable, test-only proof that the frozen provider-authorization and credential-backend contracts support interchangeable in-process and remote-shaped fakes, then record an evidence-based OneAuth/OneSystem reuse decision without implementing a production backend.

**Architecture:** Define the two behaviours, shared closed types, fakes, and conformance suite only under `apps/ezagent_domain_git/test/`. Run identical authorization and two-phase credential-lease cases against both fake pairs: the backend issues/consumes a short-lived operation-bound wrapper, while an adapter probe alone models private Req ownership and use. Add structural gates protecting Plan A transport ownership, Plan B authorization, and secret boundaries, then make a closed local-versus-remote decision from reproducible external evidence.

**Tech Stack:** Elixir 1.19, Erlang/OTP 28, ExUnit, Jason, existing `Ezagent.URI` and `Ezagent.DomainGit` values, Mix umbrella tasks.

## Global Constraints

- This is bounded research and contract proof: no production backend, OAuth client, route, migration, UI, deployment dependency, provider HTTP, or credential persistence.
- All executable D0 modules live under `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/`; production `lib/` stays unchanged.
- `Ezagent.ActionSet.GitTaskAccess` remains the sole Git-operation authorization entry; add no second dispatch, cap check, adapter contract, or registry.
- Credential backends only issue and consume short-lived operation-bound leases; provider adapters retain private Req construction, credential unwrap/use, provider HTTP, response normalization, and lease consumption orchestration.
- Social-login/product-login tokens are never repository consent.
- Forbid `decrypt`, `get_plaintext`, `fetch_secret`, secret export, and generic caller-selected retrieval.
- Provider credentials never enter agents, subprocess environments, `config_dir`, workspaces/worktrees, prompts, transcripts, snapshots, task cards, Kanban, or audit events.
- Persist and exchange opaque refs only; never expose ciphertext shapes, paths, SOPS/Age documents, KEK ids, authorization headers, callback codes, PKCE verifiers, tokens, refresh material, or raw provider bodies.
- Both fake pairs implement the same behaviours and run the same conformance cases; selection changes test configuration only.
- Every executable task follows RED → verify expected failure → minimal GREEN → verify pass.
- Run commands from `/home/huangjiajia/ezagent/.worktrees/git-domain-spine` using `mise exec -- mix ...`.
- Do not touch Plan C, production Plan B, Kanban, workspace provisioning, AgentRuntime, CapBAC, or credential-cascade files.
- Commit steps describe execution history; this planning turn does not execute them.

---

## File map

- Create `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/types.ex`: closed types/errors and recursive secret-safe envelope validation.
- Create `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/provider_authorization_backend.ex`: four-callback test-only behaviour.
- Create `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/credential_backend.ex`: six-callback test-only behaviour issuing and consuming operation-bound leases; it never owns provider transport.
- Create `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/conformance.ex`: backend-parameterized shared cases.
- Create `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/in_process_fake.ex`: deterministic stateful fake pair.
- Create `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/remote_transport.ex`: JSON round-trip and ambiguous-outcome transport.
- Create `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/remote_shaped_fake.ex`: serialized-envelope fake pair.
- Create `apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs`: runs both pairs.
- Create `apps/ezagent_domain_git/test/architecture/d0_backend_security_boundary_test.exs`: structural gates.
- Create `docs/superpowers/notes/2026-07-17-git-provider-v1-d0-external-evidence.md`: external evidence ledger.
- Create `docs/superpowers/specs/2026-07-17-git-provider-v1-d0-backend-decision.md`: backend decision.
- Create `docs/together/2026-07-17/returns/gaga-git-provider-plan-d0.md`: verification return.

### Task 1: Freeze test-only types and behaviour surfaces

**Files:**
- Create: `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/types.ex`
- Create: `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/provider_authorization_backend.ex`
- Create: `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/credential_backend.ex`
- Test: `apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs`

**Interfaces:**
- Consumes: approved D0 spec §§6–7 and canonical `%URI{}` owner/workspace identities.
- Produces: `D0.Types.authorization_errors/0`, `credential_errors/0`, `safe_envelope?/1`; authorization callbacks `begin_authorization/1`, `consume_callback/1`, `reauthenticate/1`, `cancel_authorization/1`; credential callbacks `store/1`, `replace/1`, `status/1`, `lease_for_operation/1`, `consume_lease/1`, `revoke/1`.

- [ ] **Step 1: Write failing callback and closed-error tests**

```elixir
assert Enum.sort(D0.ProviderAuthorizationBackend.behaviour_info(:callbacks)) ==
         Enum.sort(begin_authorization: 1, cancel_authorization: 1,
                   consume_callback: 1, reauthenticate: 1)
assert Enum.sort(D0.CredentialBackend.behaviour_info(:callbacks)) ==
         Enum.sort(consume_lease: 1, lease_for_operation: 1, replace: 1,
                   revoke: 1, status: 1, store: 1)
refute Enum.any?([:decrypt, :get_plaintext, :fetch_secret, :export], fn name ->
  name in Keyword.keys(D0.CredentialBackend.behaviour_info(:callbacks))
end)
assert D0.Types.authorization_errors() == [
  :authorization_backend_unavailable, :invalid_authorization_subject,
  :invalid_acquisition_method, :governed_host_mismatch, :state_mismatch,
  :pkce_mismatch, :callback_expired, :callback_already_consumed,
  :callback_invalid, :external_account_mismatch, :reauthentication_required,
  :reauthentication_failed, :authorization_cancelled,
  :provider_authorization_denied, :provider_protocol_error,
  :stale_connection_version
]
assert D0.Types.credential_errors() == [
  :credential_backend_unavailable, :credential_not_found,
  :credential_scope_mismatch, :credential_host_mismatch, :credential_revoked,
  :credential_expired, :credential_refresh_required,
  :credential_version_conflict, :operation_grant_missing,
  :operation_grant_invalid, :operation_not_permitted, :lease_not_found,
  :lease_expired, :lease_already_consumed, :lease_scope_mismatch,
  :lease_consume_failed, :credential_store_failed,
  :credential_replace_failed, :credential_revoke_failed
]
```

- [ ] **Step 2: Verify RED**

Run: `mise exec -- mix test apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs`

Expected: compilation fails because the three D0 modules are undefined. Repair syntax/harness failures until missing D0 modules are the reason.

- [ ] **Step 3: Add minimal exact contracts**

Authorization callback signatures:

```elixir
@callback begin_authorization(Types.authorization_request()) ::
  {:ok, Types.authorization_started()} | {:error, Types.authorization_error()}
@callback consume_callback(Types.callback_request()) ::
  {:ok, Types.authorization_result()} | {:error, Types.authorization_error()}
@callback reauthenticate(Types.reauthentication_request()) ::
  {:ok, Types.reauthentication_result()} | {:error, Types.authorization_error()}
@callback cancel_authorization(Types.cancellation_request()) ::
  :ok | {:error, Types.authorization_error()}
```

Credential callback signatures:

```elixir
@callback store(Types.store_request()) ::
  {:ok, Types.credential_record()} | {:error, Types.credential_error()}
@callback replace(Types.replace_request()) ::
  {:ok, Types.credential_record()} | {:error, Types.credential_error()}
@callback status(Types.status_request()) ::
  {:ok, Types.credential_status()} | {:error, Types.credential_error()}
@callback lease_for_operation(Types.operation_lease_request()) ::
  {:ok, Types.credential_lease()} | {:error, Types.credential_error()}
@callback consume_lease(Types.consume_lease_request()) ::
  :ok | {:error, Types.credential_error()}
@callback revoke(Types.revoke_request()) ::
  {:ok, Types.credential_record()} | {:error, Types.credential_error()}
```

Define spec §§6–7 request keys exactly. `safe_envelope?/1` recursively rejects keys `access_token refresh_token social_login_token authorization callback_code pkce_verifier credential_material plaintext raw_body`.

- [ ] **Step 4: Verify GREEN**

Run the Task 1 test command.

Expected: `2 tests, 0 failures`, with no callback/type warning.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_git/test/support/d0_backend_reuse_gate apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs
git commit -m "test(git): freeze D0 backend contracts"
```

### Task 2: Prove authorization semantics with the in-process fake

**Files:**
- Create: `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/conformance.ex`
- Create: `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/in_process_fake.ex`
- Modify: `apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs`

**Interfaces:**
- Consumes: Task 1 contracts.
- Produces: `D0.Conformance.authorization_cases/1`; fake `start_link/1`, `reset/1`, `provider_request_count/1`; `D0.InProcessFake.Authorization`.

- [ ] **Step 1: Add shared failing authorization cases**

Parameterize cases with:

```elixir
%{authorization: D0.InProcessFake.Authorization,
  credential: D0.InProcessFake.Credential,
  start: &start_in_process_fake/0,
  reset: &D0.InProcessFake.reset/1,
  provider_request_count: &D0.InProcessFake.provider_request_count/1}
```

Use fixed owner `entity://acme/user/alice`, workspace `workspace://acme`, provider `github`, host `github.com`, connection `conn-1`, version `1`, correlation `corr-auth-1`, state `state-1`, PKCE digest `pkce-digest-1`, external account `github-user-42`. Separate tests cover missing canonical identity, state/PKCE/host/subject/expiry mismatch, cancellation, exactly-once callback, immutable account id, safe metadata, re-authentication-only result, and rejection of `acquisition_origin: :social_login` with no stored credential.

- [ ] **Step 2: Verify RED**

Run: `mise exec -- mix test apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs --only d0_in_process_authorization`

Expected: missing `D0.Conformance`/fake compilation failure; after compile scaffolding, first case fails with `:authorization_backend_unavailable`.

- [ ] **Step 3: Implement minimal state machine**

Use isolated named Agent/GenServer state:

```elixir
%{authorizations: %{}, credentials: %{}, provider_requests: [],
  correlation_results: %{}, failure: nil}
```

Bind records to exact subject/host/version/expiry. Atomically mark callback consumed. Reject social-login origin. Return credential material only as `%Types.WriteOnlyHandoff{id: id}`; retain secret bytes privately.

- [ ] **Step 4: Verify GREEN**

Run the Task 2 command.

Expected: every `d0_in_process_authorization` case passes and provider request count is zero.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/conformance.ex apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/in_process_fake.ex apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs
git commit -m "test(git): prove D0 authorization contract"
```

### Task 3: Prove credential CAS and two-phase operation leases

**Files:**
- Modify: `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/conformance.ex`
- Modify: `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/in_process_fake.ex`
- Modify: `apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs`

**Interfaces:**
- Consumes: Task 2 write-only handoff and private state.
- Produces: `D0.Conformance.credential_cases/1`, `D0.InProcessFake.Credential`, a short-lived one-use sensitive wrapper, and `D0.InProcessFake.AdapterProbe.request_with_lease/2`, which models the provider adapter's private Req owner.

- [ ] **Step 1: Add failing credential cases**

Assert opaque store result/version 1/status active; safe status; exact-scope/version replace; one winner for concurrent same-version replacement; monotonic revoke; cross-owner/workspace/provider/host denial; no lease for missing/malformed/wrong-receiver/wrong-action/stale-version proofs; short expiry and exact operation binding; only `AdapterProbe.request_with_lease/2` may unwrap the sensitive wrapper, simulate one private Req request, and call `consume_lease/1`; reuse/expiry fail before provider effect; response/error contains none of sentinel `gho-D0-SENTINEL`.

Construct proofs only in test helper:

```elixir
def operation_grant(%OperationContext{} = context, attrs) do
  Map.merge(attrs, %{task_access_uri: context.task_access_uri,
                     caller_uri: context.caller_uri,
                     grantee_uri: context.grantee_uri})
end
```

- [ ] **Step 2: Verify RED**

Run: `mise exec -- mix test apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs --only d0_in_process_credential`

Expected: credential callback is missing/unavailable; provider count stays zero.

- [ ] **Step 3: Implement minimal credential boundary**

Private records contain `%{scope: scope, secret: "gho-D0-SENTINEL", version: n, status: :active, expires_at: ts}`. `lease_for_operation/1` checks ref → scope/host → status → version → proof, then returns `%Types.CredentialLease{lease_ref: opaque, sensitive: %Types.SensitiveCredential{}, expires_at: short_deadline, operation_digest: digest}`. The backend accepts no request plan and performs no HTTP. `AdapterProbe.request_with_lease/2` alone unwraps the wrapper in a private function, models authorization injection and Req ownership, scrubs the response, then calls `consume_lease/1`. Consumption is atomic; expiry, reuse, scope mismatch, and consume failure use closed errors. Expose no secret getter.

- [ ] **Step 4: Verify GREEN**

```bash
mise exec -- mix test apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs --only d0_in_process_credential
mise exec -- mix test apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs
```

Expected: both pass with zero failures.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_git/test/support/d0_backend_reuse_gate apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs
git commit -m "test(git): prove operation-bound credential use"
```

### Task 4: Run identical contracts across a remote-shaped boundary

**Files:**
- Create: `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/remote_transport.ex`
- Create: `apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/remote_shaped_fake.ex`
- Modify: `apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs`

**Interfaces:**
- Consumes: shared conformance and behaviours.
- Produces: `RemoteTransport.round_trip/3` with `:before_send | :after_commit | :after_response`; remote-shaped authorization/credential pair.

- [ ] **Step 1: Register remote pair and ambiguity cases**

Run the exact same shared cases with remote modules. Add assertions that every request/response JSON-round-trips; refs are strings; envelopes contain no PID/ref/function/path/struct; callback `:after_commit` response loss reconciles without a second credential; replace response loss reconciles by correlation/version; lease-creation response loss reconciles to the same short-lived lease ref; the remote backend receives no provider request plan and performs no provider HTTP; transport failures map to closed unavailable errors without sentinel leakage.

- [ ] **Step 2: Verify RED**

Run: `mise exec -- mix test apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs --only d0_remote_shaped`

Expected: missing remote modules, then first unimplemented shared callback failure; no shared case is skipped.

- [ ] **Step 3: Implement minimal remote boundary**

`round_trip/3` JSON-encodes request, decodes to string-key map, dispatches by operation name, encodes response, and reconstructs through explicit constructors. Reject unsafe envelopes both directions. Pass no module/closure/PID/path. Correlation journal makes ambiguous retry idempotent and stores no secret. The remote fake implements lease issue/consume only; `RemoteShapedFake.AdapterProbe` privately unwraps the returned wrapper, models Req ownership, and consumes the lease.

- [ ] **Step 4: Verify GREEN**

```bash
mise exec -- mix test apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs --only d0_remote_shaped
mise exec -- mix test apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs
```

Expected: remote cases and full two-backend conformance pass.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/remote_transport.ex apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/remote_shaped_fake.ex apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs
git commit -m "test(git): prove remote-shaped backend replacement"
```

### Task 5: Gate security boundaries and Plan B immutability

**Files:**
- Create: `apps/ezagent_domain_git/test/architecture/d0_backend_security_boundary_test.exs`

**Interfaces:**
- Consumes: repository source and exact Task 1/Plan B surfaces.
- Produces: detectors for forbidden APIs/fields/effects, test-only placement, five adapter callbacks, four OperationContext fields, and sole Git authorization entry.

- [ ] **Step 1: Write detector tests with violating fixtures**

```elixir
assert violations("def decrypt(ref), do: ref", :plaintext_api) != []
assert violations("defstruct [:task_access_uri, :access_token]", :secret_field) != []
assert violations("GitHub.authorize_operation(args)", :second_authorizer) != []
assert violations("File.write!(project_cwd, token)", :workspace_secret) != []
```

Repository assertions require all D0 modules under test support; exact ten callbacks; OperationContext fields `[:task_access_uri, :caller_uri, :grantee_uri, :idempotency_key]`; exact five adapter callbacks; no config-dir/worktree materialization, `Cap.issue`, cap authorization, or dispatch in D0; credential backend modules contain no Req/provider HTTP/request-plan ownership; only allowlisted `AdapterProbe` private functions may unwrap `SensitiveCredential` and simulate Req ownership; only existing GitTaskAccess performs adapter lookup/invocation; sentinel exists only in D0 tests.

- [ ] **Step 2: Verify RED**

Run: `mise exec -- mix test apps/ezagent_domain_git/test/architecture/d0_backend_security_boundary_test.exs`

Expected: fixture detectors pass and repository baseline assertion fails because exact allowlists are not implemented.

- [ ] **Step 3: Implement minimal scanners**

Use literal callback/field/path allowlists, `Path.wildcard`, and `File.read!`; assert non-empty targets so empty globs fail. No shell calls from ExUnit.

- [ ] **Step 4: Verify GREEN and Plan B compatibility**

```bash
mise exec -- mix test apps/ezagent_domain_git/test/architecture/d0_backend_security_boundary_test.exs
mise exec -- mix test apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs
mise exec -- mix test apps/ezagent_core/test/architecture/git_adapter_boundary_test.exs
mise exec -- mix test apps/ezagent_domain_git/test
```

Expected: all pass with no warnings.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_git/test/architecture/d0_backend_security_boundary_test.exs
git commit -m "test(git): gate D0 secret and authority boundaries"
```

### Task 6: Collect external evidence and close the reuse decision

**Files:**
- Create: `docs/superpowers/notes/2026-07-17-git-provider-v1-d0-external-evidence.md`
- Create: `docs/superpowers/specs/2026-07-17-git-provider-v1-d0-backend-decision.md`

**Interfaces:**
- Consumes: immutable OneAuth/OneSystem source/API versions, observed behavior, operational ownership, conformance criteria.
- Produces: evidence items OA-01..OA-05 and OS-01..OS-04; binary choice per backend: approved remote or local V1 with remote deferred.

- [ ] **Step 1: Record every evidence item with exact schema**

```markdown
### Evidence item OA-01
- Repository/service:
- Immutable revision/version:
- Owner/operational contact:
- Exact source line or API operation:
- Reproduction command:
- Observed output:
- Contract criterion:
- Result: pass | fail | unavailable
- Secret-safety:
- Operations: availability, service auth, rotation, audit retention, incident response, local development
```

Items cover canonical mapping, AAL/re-auth, catalog/client config, OIDC token semantics, connected-account broker, SOPS/Age, replace/version/revoke, short-lived lease issue/consume, provider-adapter-only unwrap/Req ownership, and generic decrypt. Inaccessible evidence is `unavailable` with access boundary/date and selects local fallback; invent no API.

- [ ] **Step 2: Verify evidence completeness RED then GREEN**

```bash
for id in OA-01 OA-02 OA-03 OA-04 OA-05 OS-01 OS-02 OS-03 OS-04; do
  rg -q "^### Evidence item ${id}$" docs/superpowers/notes/2026-07-17-git-provider-v1-d0-external-evidence.md || exit 1
done
```

Expected RED: exit 1 at first missing item. Expected GREEN after classification: exit 0.

- [ ] **Step 3: Write the closed decision**

Select remote authorization only if every required authorization item passes; otherwise local. Select remote credential backend only if short-lived lease issue/consume, version/revoke, provider-adapter-only unwrap, and absence of generic plaintext retrieval all pass; otherwise local. Cite evidence ids, reject social-login reuse/generic decrypt, forbid second authority, preserve Plan A provider-adapter Req ownership, confirm Plan B/Plan C/Kanban compatibility, list D1 prerequisites/D2 blockers, and require lead authorization for new runtime dependencies. Use no provisional branch: unavailable proof means local V1.

- [ ] **Step 4: Verify documents**

```bash
rg -n "social-login token|generic decrypt|local V1|GitTaskAccess|lease_for_operation|consume_lease|Req ownership" docs/superpowers/specs/2026-07-17-git-provider-v1-d0-backend-decision.md
git diff --check -- docs/superpowers/notes/2026-07-17-git-provider-v1-d0-external-evidence.md docs/superpowers/specs/2026-07-17-git-provider-v1-d0-backend-decision.md
mise exec -- mix ezagent.doc.scan
```

Expected: terms present, diff check silent, doc scan green.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/notes/2026-07-17-git-provider-v1-d0-external-evidence.md docs/superpowers/specs/2026-07-17-git-provider-v1-d0-backend-decision.md
git commit -m "docs(git): decide D0 backend reuse gate"
```

### Task 7: Final verification and return

**Files:**
- Create: `docs/together/2026-07-17/returns/gaga-git-provider-plan-d0.md`

**Interfaces:**
- Consumes: Tasks 1–6 and exact outputs.
- Produces: bounded return authorizing only the reviewed D1 planning direction, not production work/deploy/merge.

- [ ] **Step 1: Check formatting**

Run: `mise exec -- mix format --check-formatted apps/ezagent_domain_git/test/support/d0_backend_reuse_gate/*.ex apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs apps/ezagent_domain_git/test/architecture/d0_backend_security_boundary_test.exs`

Expected: exit 0, no output. If red, format exactly these files, inspect diff, rerun.

- [ ] **Step 2: Run focused/domain verification**

```bash
mise exec -- mix test apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs
mise exec -- mix test apps/ezagent_domain_git/test/architecture/d0_backend_security_boundary_test.exs
mise exec -- mix test apps/ezagent_core/test/architecture/git_adapter_boundary_test.exs
mise exec -- mix test apps/ezagent_domain_git/test
```

Expected: all exit 0; both fake pairs and structural gates execute.

- [ ] **Step 3: Run static and precommit gates**

```bash
mise exec -- mix ezagent.arch.scan
mise exec -- mix ezagent.check_invariants
mise exec -- mix ezagent.doc.scan
mise exec -- mix ezagent.uri_query.scan
mise exec -- mix precommit
```

Expected: all exit 0. Record exact counts; any D0-touched red gate blocks completion.

- [ ] **Step 4: Write exact return**

Sections: Outcome; Frozen interfaces; Two-fake proof; OneAuth/OneSystem evidence/decision; Security invariants; Commands/outputs; Files/commits; D1 authorization; D2 blockers; Explicit non-deliverables; Residual risks. State there is no production backend, OAuth, token persistence, provider HTTP, UI, migration, deploy, merge, or Plan C change.

- [ ] **Step 5: Self-review coverage, placeholders, and types**

```bash
rg -n "ProviderAuthorizationBackend|CredentialBackend|social-login|generic decrypt|remote-shaped|GitTaskAccess|D1|D2" docs/together/2026-07-17/returns/gaga-git-provider-plan-d0.md
rg -n "T[B]D|T[O]DO|F[I]XME|fill[ ]in|implement[ ]later" apps/ezagent_domain_git/test/support/d0_backend_reuse_gate apps/ezagent_domain_git/test/ezagent/domain_git/d0_backend_contract_test.exs apps/ezagent_domain_git/test/architecture/d0_backend_security_boundary_test.exs docs/superpowers/notes/2026-07-17-git-provider-v1-d0-external-evidence.md docs/superpowers/specs/2026-07-17-git-provider-v1-d0-backend-decision.md docs/together/2026-07-17/returns/gaga-git-provider-plan-d0.md && exit 1 || true
git diff --check
git status --short
```

Expected: coverage terms present, placeholder scan silent, diff check clean, status contains intended D0 files plus separately owned pre-existing files.

- [ ] **Step 6: Commit**

```bash
git add docs/together/2026-07-17/returns/gaga-git-provider-plan-d0.md
git commit -m "docs(together): return Git provider Plan D0"
```

## Self-review completed while writing this plan

- Spec coverage: Tasks 1–7 cover contracts/errors, both fakes, security invariants, decision matrix/operations evidence, bounded DoD, and D1/D2 gate.
- Placeholder scan: no unresolved instruction or unnamed artifact; external unavailability has the exact `unavailable -> local V1` rule.
- Type consistency: both pairs implement the same ten callbacks; scope, opaque ref, version, correlation, operation proof, lease, sensitive wrapper, and errors retain identical names. Backends issue/consume leases; adapter probes alone unwrap/use them.
- Scope consistency: executable modules are test-only; no task modifies production code, Plan B/C, Kanban, workspace provisioning, CapBAC, AgentRuntime, route, migration, UI, or deployment.
