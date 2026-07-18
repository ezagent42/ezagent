# Git Provider V1 D0 backend reuse gate design

**Status:** approved direction, design for review

**Date:** 2026-07-17

**Owner:** gaga

**Amends:** none; implements the bounded D0 design task introduced by the
[downstream roadmap amendment](2026-07-17-git-provider-v1-downstream-roadmap-amendment.md#42-plan-d0--oneauthonesystem-reuse-gate)

## 1. Decision

D0 freezes a hybrid, replaceable backend boundary before any GitHub OAuth or
provider credential implementation begins:

- a new provider-connection domain owns the common connection lifecycle and the
  two backend ports defined here;
- provider plugins own provider-specific authorization, token, refresh, revoke,
  permission-probe, and metadata semantics;
- V1 may ship local backend implementations when D0 cannot prove a
  production-safe OneAuth or OneSystem contract;
- OneAuth concepts may be reused for canonical owner mapping, human sessions,
  assurance level, and re-authentication, but a social-login token is never
  repository consent;
- OneSystem may replace the local credential backend only behind an
  operation-bound secret-use contract. Its generic plaintext decrypt API is
  forbidden.

The backend choice must not change `Ezagent.DomainGit.Adapter`,
`Ezagent.ActionSet.GitTaskAccess`, Kanban, or task workspace provisioning. This
is the replacement boundary already required by the roadmap
([roadmap §5](2026-07-17-git-provider-v1-downstream-roadmap-amendment.md#5-oneauthonesystem-replacement-boundary)).

## 2. Goals

1. Freeze the ownership and semantic contracts of
   `ProviderAuthorizationBackend` and `CredentialBackend` without implementing
   either production backend.
2. Prove that one in-process fake and one remote-shaped fake satisfy the same
   contract without changes to Plan B or Plan C interfaces.
3. Decide whether D1/D2 may use an existing OneAuth/OneSystem service or must
   start with local implementations.
4. Preserve a single Git operation authorization entry:
   `Ezagent.ActionSet.GitTaskAccess`.
5. Keep provider credentials out of agents, task worktrees, configuration
   directories, snapshots, audit records, telemetry, and returned domain
   values.
6. Make backend replacement operationally observable through secret-safe,
   correlated events and closed failures.

## 3. Non-goals

- Implementing GitHub OAuth, GitHub App user authorization, Req calls, token
  refresh, repository permission probes, or Git Data API operations.
- Building a complete OneAuth connected-account broker or changing OneAuth or
  OneSystem repositories.
- Selecting OAuth scopes or resolving GitHub App installation semantics.
- Adding UI, routes, migrations, deployment dependencies, or production secret
  storage.
- Changing `Ezagent.DomainGit.Adapter`, `OperationContext`, `GitTaskAccess`,
  Kanban, Plan C workspace provisioning, CapBAC, or task-policy truth.
- Supporting PAT import, SSH, private checkout, installation-token fallback, or
  service-account execution.

The roadmap explicitly requires a separate lead decision before building a
full OneAuth connected-account broker
([roadmap:223](2026-07-17-git-provider-v1-downstream-roadmap-amendment.md#L223)).

## 4. Current evidence

### 4.1 Plan B already owns Git operation authorization

`Ezagent.ActionSet.GitTaskAccess` revalidates task policy, validates the exact
request, authorizes the receiver-bound signed capability, constructs the
operation context, and only then looks up and invokes the provider adapter
([git_task_access.ex:115](../../../apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex#L115),
[git_task_access.ex:203](../../../apps/ezagent_domain_git/lib/ezagent/behavior/git_task_access.ex#L203)).
No backend introduced by D0 may duplicate or bypass that path.

`Ezagent.DomainGit.OperationContext` contains only task, caller, grantee, and
idempotency coordinates; it contains no token, credential reference, HTTP
client, or working-tree path
([operation_context.ex:4](../../../apps/ezagent_domain_git/lib/ezagent/domain_git/operation_context.ex#L4)).
The provider adapter contract consumes this authorized context and validated
domain values
([adapter.ex:1](../../../apps/ezagent_domain_git/lib/ezagent/domain_git/adapter.ex#L1)).

### 4.2 Existing ezagent credential seams are not the new backend

`Ezagent.Credential.GrantRow` provides useful precedent for an opaque source
reference, accountable approver, monotonic version, revoke state, and a
last-moment version recheck
([grant_row.ex:22](../../../apps/ezagent_core/lib/ezagent/credential/grant_row.ex#L22),
[grant_row.ex:113](../../../apps/ezagent_core/lib/ezagent/credential/grant_row.ex#L113)).
Those semantics may inform D1, but its source is an agent configuration home and
is not a provider-token store.

`Ezagent.Agent.CredentialAdapter` explicitly materializes flavor login state in
per-agent files and identifies the secret file subset
([credential_adapter.ex:7](../../../apps/ezagent_core/lib/ezagent/agent/credential_adapter.ex#L7),
[credential_adapter.ex:34](../../../apps/ezagent_core/lib/ezagent/agent/credential_adapter.ex#L34)).
That flow is forbidden for Git provider credentials.

`Ezagent.ActionSet.ApiKeys` persists plaintext keys on an Agent and exposes a
cap-gated plaintext getter
([api_keys.ex:6](../../../apps/ezagent_domain_identity/lib/ezagent/behavior/api_keys.ex#L6),
[api_keys.ex:39](../../../apps/ezagent_domain_identity/lib/ezagent/behavior/api_keys.ex#L39),
[api_keys.ex:185](../../../apps/ezagent_domain_identity/lib/ezagent/behavior/api_keys.ex#L185)).
It is therefore not an acceptable `CredentialBackend` implementation.

`Ezagent.Authentication` is a narrow credential-to-canonical-principal seam; it
does not load capabilities or model external account consent
([authentication.ex:1](../../../apps/ezagent_core/lib/ezagent/authentication.ex#L1),
[authentication.ex:21](../../../apps/ezagent_core/lib/ezagent/authentication.ex#L21)).

### 4.3 OneAuth and OneSystem evidence is incomplete

The approved roadmap records that OneAuth owns identity, sessions, assurance
level, external-login client configuration, masking, and KEK-encrypted operator
secrets, but its current OIDC support authenticates a human into a product and
does not expose a task-bound connected-account token broker. It records that
OneSystem has SOPS/Age secret management but its current generic decrypt API
returns plaintext to a generic caller
([roadmap:118](2026-07-17-git-provider-v1-downstream-roadmap-amendment.md#L118)).

No OneAuth or OneSystem source, runtime dependency, or client contract exists in
this repository. D0 must obtain executable and operational evidence from the
owning repositories or services before approving either remote backend.

## 5. Exact ownership

### 5.1 Provider-connection domain

A new provider-neutral domain app owns:

- the `ProviderConnection` record and state machine;
- state/PKCE correlation and callback single consumption;
- canonical ezagent owner/workspace association;
- provider id and governed provider host;
- immutable external account id, display login, and execution identity;
- opaque authorization and credential backend references;
- connection status, monotonic version, refresh compare-and-swap, revoke and
  disconnect transitions;
- the two backend behaviours and backend selection/configuration;
- secret-safe audit correlation.

It does not own Git task policy or authorize provider operations. It may answer
which active connection belongs to a canonical credential owner, but that answer
is only an input to the already-authorized provider adapter invocation.

This domain is separate from `ezagent_domain_git`: Plan B remains the provider-
neutral Git operation spine, and backend replacement must not alter its public
contracts.

### 5.2 Provider plugin

Each provider plugin owns:

- authorization, token, refresh, revoke, and installation endpoints;
- scopes and provider permission semantics;
- provider account and repository probes;
- token response parsing and provider-specific expiry/rotation rules;
- webhook parsing and provider metadata;
- its implementation of the existing `Ezagent.DomainGit.Adapter` callbacks.

Provider-specific data crosses the common domain only in explicitly opaque or
normalized fields. GitHub concepts do not enter the common behaviours.

### 5.3 Backend implementations

A backend implementation may live locally or behind a remote client, but it is
replaceable configuration beneath the provider-connection domain. It owns no
task policy, capability issuance, repository authorization, Kanban state, or
workspace lifecycle.

## 6. `ProviderAuthorizationBackend` semantic contract

The following is a semantic contract, not production Elixir code. Names may be
adjusted during the executable plan, but weakening the inputs, outputs, or
invariants requires design review.

```text
type AuthorizationSubject = {
  owner_uri: canonical entity URI,
  workspace_uri: canonical workspace URI,
  provider_id: provider-neutral registered id,
  governed_host: normalized allowed host,
  connection_id: immutable connection id,
  connection_version: non-negative integer
}

type AuthorizationRequest = {
  subject: AuthorizationSubject,
  acquisition_method: plugin-declared opaque method id,
  requested_permissions_digest: non-secret digest,
  redirect_uri_id: registered redirect identifier,
  correlation_id: opaque audit id
}

begin_authorization(AuthorizationRequest)
  -> ok {
       authorization_ref: opaque backend ref,
       redirect: provider-owned safe redirect descriptor,
       expires_at: timestamp
     }
  | error AuthorizationError

consume_callback({
  authorization_ref,
  callback_envelope,
  expected_subject: AuthorizationSubject,
  correlation_id
})
  -> ok {
       external_account_id: immutable string,
       display_login: string,
       execution_identity: normalized connected-user identity,
       credential_material: write-only opaque handoff,
       granted_permissions_digest: non-secret digest,
       provider_metadata: plugin-normalized non-secret map
     }
  | error AuthorizationError

reauthenticate({subject, session_assurance_evidence, correlation_id})
  -> ok {reauth_ref, expires_at}
  | error AuthorizationError

cancel_authorization({authorization_ref, expected_subject, correlation_id})
  -> ok | error AuthorizationError
```

Contract rules:

1. `begin_authorization` requires a canonical owner and workspace; it does not
   accept an agent URI as the authorization subject.
2. State/PKCE/callback correlation is bound to subject, connection, host,
   acquisition method, version, expiry, and one correlation id.
3. `consume_callback` is exactly-once from the lifecycle perspective and
   retry-safe across an ambiguous response. The first valid command commits.
   A retry with the same correlation id, authorization ref, expected subject,
   and callback digest returns the same logical result without repeating the
   provider effect. A second command with a different correlation id returns
   `callback_already_consumed`. Reusing a correlation id with different bound
   input fails closed as `callback_invalid`.
4. `credential_material` is a write-only handoff to `CredentialBackend`; it is
   never stored in `ProviderConnection` or returned to UI/domain consumers.
5. A OneAuth product-login/social-login token is not valid
   `credential_material` and is never evidence of repository consent.
6. Re-authentication proves recent control of the canonical human identity; it
   neither grants Git task authority nor substitutes for provider consent.
7. Provider endpoint, scope, callback payload, and refresh semantics remain in
   the provider plugin/driver.
8. For every mutating callback in both backend contracts, `correlation_id` is a
   durable idempotency-command key, not audit decoration. A backend atomically
   binds it to the operation class and a digest of all authority-bearing input.
   Exact retries return the committed logical result; mismatched reuse fails
   closed and never repeats an external effect.
9. A durable implementation enforces one command record for
   `{backend_id, operation_class, correlation_id}` and stores a canonical digest
   of every authority-bearing input. `consume_callback` additionally enforces a
   single committed consume command per `authorization_ref`.

### 6.1 Closed authorization errors

```text
authorization_backend_unavailable
invalid_authorization_subject
invalid_acquisition_method
governed_host_mismatch
state_mismatch
pkce_mismatch
callback_expired
callback_already_consumed
callback_invalid
external_account_mismatch
reauthentication_required
reauthentication_failed
authorization_cancelled
provider_authorization_denied
provider_protocol_error
stale_connection_version
```

Errors carry only safe codes plus correlation ids. Raw callback bodies, codes,
tokens, verifier material, authorization headers, and provider response bodies
are not error fields or inspected log payloads.

## 7. `CredentialBackend` semantic contract

```text
type CredentialScope = {
  owner_uri: canonical entity URI,
  workspace_uri: canonical workspace URI,
  provider_id: provider-neutral registered id,
  governed_host: normalized allowed host,
  connection_id: immutable connection id
}

type CredentialRef = opaque backend reference

store({
  scope: CredentialScope,
  credential_material: write-only opaque handoff,
  expected_absent: true,
  correlation_id
})
  -> ok {credential_ref: CredentialRef, version: 1, status: active}
  | error CredentialError

replace({
  credential_ref,
  expected_scope: CredentialScope,
  expected_version,
  credential_material: write-only opaque handoff,
  correlation_id
})
  -> ok {credential_ref, version: expected_version + 1, status: active}
  | error CredentialError

status({credential_ref, expected_scope, correlation_id})
  -> ok {status: active | refresh_required | revoked,
         version, expires_at?}
  | error CredentialError

lease_for_operation({
  credential_ref,
  expected_scope: CredentialScope,
  expected_version,
  operation_grant: opaque proof minted only after GitTaskAccess authorization,
  operation_class: closed provider-neutral operation class,
  correlation_id
})
  -> ok {sensitive_credential: single-use sensitive wrapper,
         lease_id, observed_version, expires_at}
  | error CredentialError

consume_lease({lease_id, expected_scope, expected_version, correlation_id})
  -> ok | error CredentialError

revoke({credential_ref, expected_scope, expected_version, correlation_id})
  -> ok {version: expected_version + 1, status: revoked}
  | error CredentialError
```

Contract rules:

1. There is no `decrypt`, `get_plaintext`, `fetch_secret`, `export`, or generic
   caller-selected secret retrieval callback.
2. `lease_for_operation` is the sole credential-release boundary. The backend
   binds credential scope, version, operation proof, governed host, and a closed
   operation class before returning a short-lived, single-use sensitive wrapper.
   Only a private function inside the already-authorized provider adapter may
   unwrap that value, attach it to its Req request, execute the provider call, and
   immediately consume/close the lease. This preserves Plan A's plugin-private
   token-attachment and Req boundary; the backend does not own provider transport.
3. The operation proof is produced only on the existing
   `GitTaskAccess -> provider adapter` path. A connection lifecycle event,
   backend ref, login session, or re-authentication result cannot mint it.
4. The sensitive wrapper is not a general domain value: it cannot be serialized,
   inspected, logged, persisted, audited, placed in an invocation, or returned by
   an adapter. The provider adapter normalizes or scrubs the response before it
   leaves its private operation function. Authorization headers and raw provider
   bodies never enter domain values, logs, telemetry, or errors.
5. `replace` and `revoke` use exact version compare-and-swap and fail closed on
   races. A revoked or stale ref never silently falls back to another owner,
   workspace, host, account, installation, or service token.
6. Backend refs are opaque. Consumers do not persist backend ciphertext shape,
   filesystem paths, SOPS/Age documents, KEK ids, or remote service internals.
7. The credential and refresh material never enters an agent process, agent
   snapshot, `config_dir`, task workspace/worktree, prompt, transcript, task
   card, Kanban projection, or general audit event.
8. `store`, `replace`, `lease_for_operation`, `consume_lease`, and `revoke`
   reconcile ambiguous outcomes by the durable correlation-id command key.
   An exact retry returns the original logical result without a second mutation
   or lease. Reusing the key with a different scope, version, operation class,
   grant digest, or credential-handoff digest fails closed. This is required
   even for a local backend so that it remains replaceable by a remote backend.
9. Reconciliation may replay only the same opaque write-only credential
   handoff. It must not expose or reconstruct plaintext credential material for
   a domain, UI, log, event, or transport response.
10. Authorization and credential backends are selected as a conformance-tested
    compatibility pair. The handoff is opaque outside that pair; independent
    module replaceability does not imply that every authorization backend can be
    combined with every credential backend. A compatible pair still preserves
    both behavior boundaries and may not add a generic export or unwrap API.

### 7.1 Closed credential errors

```text
credential_backend_unavailable
credential_not_found
credential_scope_mismatch
credential_host_mismatch
credential_revoked
credential_expired
credential_refresh_required
credential_version_conflict
operation_grant_missing
operation_grant_invalid
operation_not_permitted
request_plan_invalid
provider_response_invalid
credential_store_failed
credential_replace_failed
credential_revoke_failed
```

Backend-specific crypto, storage, HTTP, and remote-RPC failures map to this
closed vocabulary. Secret material is never attached to an error.

## 8. Contract-test proof design

D0 creates no production backend. It defines a shared behaviour conformance
suite run against two fakes.

### 8.1 In-process fake

The in-process fake stores opaque authorization and credential records in
isolated test state. Secret bytes may exist inside that fake only so tests can
prove they never cross its public boundary. It supports deterministic time,
version races, single-consume callbacks, revoke, backend failure injection, and
captured operation execution.

### 8.2 Remote-shaped fake

The remote-shaped fake uses a serialization boundary even when hosted in the
same BEAM test:

- requests and responses contain only serializable envelopes;
- refs are opaque strings with no local PID, function, path, or struct leakage;
- no callback accepts a closure such as `with_secret(ref, fun)`;
- transport can fail before send, after commit, and after response loss;
- retry behavior is driven by correlation id, callback consumption state, and
  version CAS rather than process identity;
- response fixtures verify secret-safe encoding and logging.

This proves the contract can later target OneAuth/OneSystem without changing
domain, plugin, Kanban, or workspace interfaces.

### 8.3 Shared conformance cases

Both fakes must pass the same cases:

1. owner, workspace, provider id, and governed host are mandatory and exact;
2. state/PKCE mismatch and expired callback fail without credential storage;
3. valid callback is consumed once; retry cannot create a second credential;
4. social-login material is rejected as repository credential consent;
5. store returns only opaque ref/version/status;
6. replace and revoke are monotonic CAS operations;
7. stale, revoked, cross-owner, cross-workspace, and cross-host use fail closed;
8. missing or invalid operation proof creates no lease and causes no provider request;
9. authorized use exposes the sensitive wrapper only to the provider adapter's
   private Req function and consumes the lease exactly once;
10. backend/transport/provider failures contain no token, refresh material,
    authorization header, raw body, or request secret;
11. retries after ambiguous remote outcomes reconcile by correlation id and
    version without duplicate callback consumption or rollback to old material;
12. swapping backend modules changes only test configuration.

Structural tests additionally reject callback names matching generic plaintext
retrieval and reject credential/token/secret fields in `OperationContext`, task
policy, adapter return structs, Kanban projections, provision records, snapshots,
and audit schemas.

## 9. OneAuth/OneSystem decision matrix

| Candidate | Evidence required | Current evidence | D0 decision |
|---|---|---|---|
| OneAuth owner mapping | Immutable OneAuth subject to canonical ezagent entity mapping; workspace association; lifecycle for rename/deactivate | OneAuth identity ownership is recorded, but no executable mapping contract is present locally | Reuse candidate; blocked pending contract proof |
| OneAuth re-authentication/AAL | Recent-auth result bound to canonical subject, expiry, session, and correlation id; no provider token exposure | Capability is described by roadmap only | Reuse candidate; blocked pending executable and operational proof |
| OneAuth provider catalog/client configuration | Governed provider id/host and registered redirect/client metadata without leaking operator secrets | Catalog and masking/KEK concepts are recorded | Reuse concept; remote dependency requires proof and lead approval |
| OneAuth external OIDC/social login token | Separate connected-account consent artifact, provider account binding, requested/granted repository permissions, refresh/revoke lifecycle | Current OIDC authenticates a human into a product only | Rejected; social-login token is not repository consent |
| OneAuth connected-account backend | Full `ProviderAuthorizationBackend` conformance, task-independent connection lifecycle, callback single consumption, secret-safe handoff | No such broker is evidenced | Not available for V1 unless D0 obtains new proof and lead approval |
| OneSystem SOPS/Age storage | Opaque scoped refs, atomic replace/version CAS, revoke, fail-closed reads, correlated audit | Real SOPS/Age management is recorded | Storage primitive is relevant; backend not approved yet |
| OneSystem generic decrypt API | No generic plaintext retrieval; operation-bound use with exact scope/version/host/proof | Current API returns plaintext to a generic caller | Rejected and explicitly forbidden |
| Local authorization backend | Shared conformance suite, durable state/PKCE, callback single consume, no second identity/Git authority | Not implemented in D0 | Approved fallback for D1 planning |
| Local encrypted credential backend | Shared conformance suite, encryption-at-rest/key rotation runbook, operation-bound use, no generic retrieval | Not implemented in D0 | Approved fallback for D1/D2 planning |

No remote candidate becomes a W29 runtime dependency merely because its concept
is reusable. Deployment ownership, availability/SLO, authentication between
services, audit retention, rotation, incident response, and local development
must also have operational evidence and lead authorization.

## 10. Security invariants

1. **One Git operation authorization entry.** Every provider operation remains
   authorized by `Ezagent.ActionSet.GitTaskAccess`; neither connection nor
   credential backends authorize Git work.
2. **Social login is not repository consent.** A product-login/OIDC token is
   never stored or spent as a Git provider credential.
3. **No generic plaintext retrieval.** `decrypt`, `get_plaintext`, secret export,
   and arbitrary caller-selected credential reads are forbidden. The only release
   is an operation-bound, short-lived lease consumed inside the authorized provider
   adapter's private Req function.
4. **No agent secret flow.** Provider credentials never enter an agent,
   subprocess environment, `config_dir`, agent credential cascade, prompt,
   transcript, or snapshot.
5. **No workspace secret flow.** Provider credentials never enter repository
   caches, task workspaces/worktrees, provision records, Git config, remote URLs,
   files, or environment variables.
6. **Canonical accountable owner.** Connections bind an immutable external
   account id to a canonical ezagent entity and workspace. Display login is not
   identity.
7. **Provider-host isolation.** A credential acquired for one provider id and
   governed host cannot be used on another host, including caller-selected URLs
   and redirects.
8. **Versioned fail-closed lifecycle.** Refresh, replace, revoke, disconnect, and
   use are versioned; stale reads and ambiguous races do not fall back.
9. **Opaque persistence.** Common records store only opaque backend refs, never
   ciphertext formats or backend filesystem/service internals.
10. **Secret-safe observability.** Audit and telemetry correlate owner,
    workspace, connection, action class, outcome, version, and correlation id,
    but never secret material, authorization headers, callback codes, PKCE
    verifier, or raw provider bodies.
11. **No second authority source.** OneAuth/OneSystem status, connection status,
    or backend possession never becomes a second CapBAC or task-policy truth.
12. **No unauthorized side effect.** Failed task authorization or failed
    operation proof causes no credential use and no provider request.

## 11. Bounded D0 research DoD

D0 is complete only when all of the following evidence is attached to its return:

- [ ] Current OneAuth and OneSystem source/API versions and deployment owners are
      recorded; claims are cited to executable code, API schemas, or observed
      service behavior rather than roadmap prose alone.
- [ ] Canonical OneAuth subject to ezagent entity/workspace mapping is proved or
      explicitly marked unavailable.
- [ ] OneAuth AAL/re-authentication, provider catalog, external-login, and any
      connected-account APIs are classified against §6.
- [ ] OneSystem store/replace/version/revoke/use and generic decrypt surfaces are
      classified against §7.
- [ ] Both behaviours have a single semantic contract and closed error set with
      no backend-specific leakage.
- [ ] The shared conformance suite passes for an in-process fake and a remote-
      shaped fake.
- [ ] Negative proofs show no social-login-token reuse, no generic plaintext
      retrieval, no agent/config-dir/workspace secret flow, and no second Git
      operation authorization path.
- [ ] Operational evidence covers availability ownership, service
      authentication, key/token rotation, audit retention, incident response,
      local development, and failure behavior for each proposed remote backend.
- [ ] A decision record selects local or approved remote implementations for D1
      and names every remaining blocker without expanding into cross-repository
      implementation.
- [ ] Backend replacement is demonstrated to require no change to
      `DomainGit.Adapter`, `GitTaskAccess`, Kanban, or workspace provisioning.

If external evidence is unavailable or either remote service fails one security
invariant, the bounded result is not “research incomplete.” The result is
“local backend for V1; remote replacement deferred,” with the failed criteria
recorded.

## 12. D1/D2 planning gate

D1 planning may begin only after review accepts:

1. exact port ownership and common/provider-plugin separation;
2. both semantic contracts and closed errors;
3. the shared fake conformance design;
4. a local-versus-remote decision backed by §11 evidence;
5. confirmation that no new cross-service runtime dependency is introduced
   without lead authorization.

D1 then designs the provider-connection record, state machine, persistence,
PKCE/callback lifecycle, opaque refs, versioned refresh/revoke, and selected
backend implementations. It must not change Plan B contracts.

D2 planning may begin only after D1 has a reviewed connection/credential
substrate and the GitHub driver has separately confirmed actor, installation,
callback, scope, refresh, permission-probe, and revocation semantics. D2 consumes
the existing five adapter callbacks; it does not introduce a second adapter or
operation authorization path. The downstream sequence remains the one frozen in
[roadmap §6](2026-07-17-git-provider-v1-downstream-roadmap-amendment.md#6-readiness-and-sequencing).

## 13. Self-review

- Placeholder scan: no `TBD`, `TODO`, or unresolved implementation choice is
  presented as a requirement. External evidence intentionally remains a D0 DoD
  item and has a defined local-backend fallback.
- Consistency: the provider-connection domain owns lifecycle but never Git
  operation authorization; provider plugins own protocol semantics; credential
  use remains operation-bound.
- Scope: this document freezes contracts and research proof only. It adds no
  implementation, migration, route, UI, deployment, or production dependency.
- Security: social-login-token reuse, generic plaintext retrieval, agent and
  workspace secret flow, and a second Git authorization entry are each forbidden
  both normatively and by proposed negative proofs.
