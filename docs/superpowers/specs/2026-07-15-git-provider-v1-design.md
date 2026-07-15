# Git provider V1: Entity SSH identity, provider plugins, and task workspaces

**Status:** proposed for lead review

**Date:** 2026-07-15

**Owner:** gaga

**Context:** W29 dev-loop demo provisioning gaps; extends the constraints in
`docs/superpowers/notes/2026-07-15-demo-provisioning-constraints.md`

## 1. Decision summary

V1 separates Git development access into four responsibilities:

1. **Entity SSH Identity** owns a user's Git-capable SSH identity. It supports
   platform-generated keys and a deliberately narrow private-key import flow.
   Raw private material lives only in an encrypted secret backend.
2. **Git Provider plugins** adapt a provider-neutral repository/change-request
   contract to GitHub, GitLab, Gitea, or a future provider. GitHub is the first
   implementation, not a core-domain special case.
3. **Task Workspace Provisioner** creates the clone and per-task worktree before
   an agent sidecar starts. It depends only on the provider contract.
4. **Kanban/socialware governance** issues precise, provenance-stamped,
   task-scoped caps via `Cap.issue`; it does not write `caps_json` directly.

The agent receives neither a GitHub token nor an SSH private key. It receives a
capability to request a bounded operation. GitHub merge remains a lead/human
operation in V1.

This design does not change the current W29 honesty label: the demo path remains
**loose-coupled, not the final mount; #1360 Layer B is still pending**.

## 2. Goals and non-goals

### 2.1 Goals

- Let a user generate or import an SSH identity associated with their Entity.
- Let a user connect their own Git provider account; never use a shared platform
  developer credential.
- Keep credentials out of agent processes, prompts, transcripts, task cards,
  snapshots, event payloads, and logs.
- Give agents least-privilege repository operations through CapBAC.
- Provision a valid isolated `project_cwd` before `cc-headless` sidecar startup.
- Make adding GitLab or Gitea primarily a new plugin implementation rather than
  a rewrite of Kanban, AgentRuntime, or workspace lifecycle code.
- Preserve auditable acting-user, agent, task, repository, and operation facts.

### 2.2 Non-goals

- Passphrase-protected private keys in V1.
- Arbitrary SSH key formats or algorithms in V1.
- More than one active SSH key per Entity.
- Exporting or redisplaying imported private keys.
- Giving an agent merge authority.
- General-purpose shell access to credentials.
- Demo hardening, retries, or long-term workspace pooling beyond the first real
  closed loop.
- AgentRuntime ARB, EntityCaps A/B/D, `caps_json` persistence, no-tail
  enforcement, or cc-PTY bridge join/#1405.

## 3. Architecture

```text
Kanban task + governed task caps
                |
                v
   GitTaskAccess Resource Kind/Behavior
                |
        Router.dispatch + required_caps
                +------------------------+
                |                        |
                v                        v
 provider-neutral Behavior      Task Workspace Provisioner
                |                        |
        adapter registry                 v
       /        |       \         Git Operation Broker
      v         v        v               |
   GitHub    GitLab    Gitea              v
   plugin    plugin    plugin     Entity SSH Identity
   (first)          (future)              |
                |                 encrypted secret backend
                +-- normalized facts      |
                                         v
                                isolated project_cwd
                |
                v
      cc-headless / :in_process_sync
```

The dependency direction is load-bearing:

- AgentRuntime and Workspace Provisioner know the provider contract, not GitHub.
- Every agent/provisioner request enters through an addressable Resource Kind,
  Behavior, and `Router.dispatch`; the adapter registry is behind that dispatch
  target and is never an authorization entry point.
- GitHub-specific OAuth scopes, API responses, PRs, checks, and reviews stay in
  the GitHub plugin.
- Generic SSH Git transport stays in the domain-owned Git Operation Broker, not
  duplicated in every provider plugin.
- Entity SSH Identity knows SSH identity, not GitHub repositories or OAuth.
- Kanban describes repository intent and grants authority; it does not handle
  credentials or perform Git operations.

## 4. Entity SSH Identity

### 4.1 Ownership and persisted shape

Identity Domain owns the Entity-to-SSH-identity relationship. The durable public
record contains only:

- entity URI;
- public key;
- fingerprint;
- key algorithm;
- opaque secret reference;
- status (`active` or `revoked`);
- created, replaced, and revoked timestamps;
- provenance (`generated` or `imported`).

The private key body is stored only in an encrypted secret backend. It MUST NOT
be a Kind slice, snapshot field, ConfigObject, event field, audit argument,
LiveView assign retained after the request, or agent `config_dir` file.

The Entity owns the identity metadata and authority boundary; "Entity manages a
private key" does not mean plaintext private material is Entity state.

### 4.2 Supported V1 inputs

V1 accepts:

- platform-generated OpenSSH Ed25519 keys;
- imported, unencrypted OpenSSH Ed25519 private keys;
- imported, unencrypted OpenSSH RSA private keys that meet the configured
  minimum key size.

V1 rejects passphrase-protected keys, ECDSA, PEM/PKCS#1/PKCS#8 variants, malformed
keys, unsupported algorithms, and multiple-key bundles with a specific error.
The UI states these limits before upload.

### 4.3 Import and replacement state machine

```text
receive sensitive request
  -> parse with redaction-safe errors
  -> validate algorithm/policy
  -> derive public key and fingerprint
  -> stage encrypted secret with operation/idempotency key
  -> compare-and-swap active identity version
  -> tombstone the former version after in-flight leases drain
  -> asynchronously delete tombstoned secret with retry/reconciliation
```

The metadata database and external secret backend are not assumed to share an
atomic transaction. A versioned state machine provides caller-visible atomicity:
only one version is `active`; staged versions are not usable; compare-and-swap
serializes replace/revoke; each broker use holds a short lease on its version;
and a reconciler recovers orphan `staged` or `tombstoned` versions after crashes.
Failure before the pointer switch leaves the existing active identity usable.
No response includes private material. The request path must disable body and
parameter logging, and error reporting must receive only a redacted error code,
algorithm, and fingerprint where available.

Identity replacement is provider-independent. Provider-specific readiness tests
run afterward through each provider binding and do not participate in the active
identity pointer transition.

V1 does not automatically delete an old public key from an external provider.
The UI reports the old fingerprint and tells the user to remove it. Provider-key
registration/removal automation can follow after provider-specific ownership and
rollback semantics are specified.

### 4.4 Allowed operations

The public interface exposes operations such as:

- generate identity;
- import identity;
- get public metadata;
- replace identity;
- revoke identity.

There is no `get_private_key`, generic `sign`, or credential-context operation.
Only the internal Git Operation Broker may lease a secret version. The broker
accepts structured repository/host/ref intent, pins host-key policy, launches the
Git subprocess itself under OS-level isolation, and returns normalized results.
It never returns a key path, file descriptor, handle, environment, or signing
oracle to the agent or provider plugin. Credential artifacts are outside the
workspace and are removed on success, error, timeout, cancellation, and broker
crash recovery.

### 4.5 Import threat controls

Import requires recent user re-authentication and CSRF protection. The web edge
enforces strict byte/line limits before parsing. Parsing uses a fixed error
taxonomy rather than propagating library errors. Reverse proxy, APM, telemetry,
crash reporting, and operator diagnostics use explicit allowlists/redaction; no
plaintext temporary file is created. V1 does not promise reliable zeroization of
BEAM heap data, so plaintext lifetime is minimized and parsing/brokering is
isolated from long-lived Entity and LiveView processes. Tests cover exception and
crash paths as well as successful import.

## 5. Provider-neutral Git contract

### 5.1 Vocabulary

Core/domain code uses these terms:

- **repository**, not GitHub repo;
- **change request**, not pull request or merge request;
- **checks**, encompassing GitHub checks/actions and GitLab pipelines/jobs;
- **reviews**, encompassing reviews and approvals;
- **provider account binding**, not GitHub login.

The first implementation maps change request to GitHub Pull Request. A later
GitLab plugin maps it to Merge Request without changing callers.

### 5.2 Addressable Resource Kinds

A Kanban card or socialware configuration supplies a normalized reference:

```text
provider: github
provider_host: github.com
repository: ezagent-chat/ezagent
base_ref: main
```

The canonical repository identity uses Ezagent's existing `resource` scheme:

```text
resource://<workspace>/git_repository/<stable-id>
```

There is no new `gitrepo://` scheme. The `GitRepository` cold Resource record
contains provider adapter ID, provider instance/host, external repository ID,
normalized owner/path, and canonical remote endpoints. Callers do not infer a
provider solely by matching a clone URL.

Each governed task generation also receives an addressable authorization target:

```text
resource://<workspace>/git_task_access/<stable-task-generation-id>
```

The `GitTaskAccess` Resource policy immutably binds task URI, generation,
credential-owner Entity, agent Entity, repository Resource URI, and allowed
branch. Its lifecycle status changes through Behavior effects. It is the dispatch
target for repository operations and is the current Capability model's instance
boundary.

Provider account bindings are separately addressable Receiver Resources:

```text
resource://<workspace>/git_provider_binding/<stable-id>
```

The domain-owned provider-binding envelope is the source of truth for addressable
identity, Entity association, provider adapter ID, and generic readiness. The
provider plugin is the source of truth for provider-specific external-account
metadata and the encrypted OAuth-token reference in its namespaced store.
`GitRepository` is a `:cold_resource`; `GitTaskAccess` is a supervised
`:hot_resource` for the active task generation; and `GitProviderBinding` is the
external-integration Receiver Resource. Provider plugins supply adapter
implementations without introducing a URI scheme or Kind.

### 5.3 Kind/Behavior/adapter dispatch path

The domain owns and implements the provider-neutral Resource types, Lifecycle,
operation Behaviors, and normalized request/result types exactly once. Provider
plugins only register adapter implementations through the declared adapter
callback/registry; they do not attach competing implementations of the
provider-neutral Behavior/action namespace. Core/domain code depends only on the
contract; plugins depend on the contract; core/domain code never references the
GitHub implementation.

If a provider binding needs provider-specific lifecycle state, its plugin may use
a namespaced plugin Behavior/store on that binding. That state cannot duplicate
or replace the provider-neutral operation actions.

Every operation follows:

```text
caller
  -> Router.dispatch(GitTaskAccess Resource URI + Behavior action)
  -> required_caps / audit / lifecycle readiness
  -> load immutable GitTaskAccess policy
  -> resolve provider adapter behind the Resource target
  -> provider API operation or domain Git Operation Broker
  -> normalized result/effects
```

Direct Provisioner-to-plugin operation calls are forbidden. The adapter registry
is dependency injection after authorization, not a callable bypass around Router.

### 5.4 Contract operations

V1 defines provider operations equivalent to:

- resolve and normalize a repository reference;
- check credential-owner read/write access under the governed delegation;
- resolve canonical Git remote endpoints and provider permission facts;
- create a change request;
- read a change request;
- list check/CI state;
- list review state.

Merge is deliberately absent from the agent-granted V1 interface. A plugin may
later implement it for a separate lead-controlled path.

The contract returns normalized data and structured errors. Raw GitHub response
maps must not leak into Kanban or Workspace Provisioner state.

Generic clone/fetch/push execution belongs to the Git Operation Broker. A provider
adapter supplies provider-specific endpoint and permission facts and may select a
declared transport strategy, but it does not handle raw SSH secrets or launch a
credential-bearing subprocess.

### 5.5 Normalized errors

At minimum, callers can distinguish:

- provider account not connected;
- SSH identity missing or revoked;
- unsupported credential type;
- repository not found;
- repository read denied;
- repository push denied;
- base ref not found;
- provider unavailable;
- authentication rejected;
- change request conflict/already exists;
- checks unavailable.

Errors contain safe provider request identifiers where available, never access
tokens, private keys, Authorization headers, or sensitive command environments.

## 6. GitHub plugin V1

The GitHub plugin is the first provider adapter. It owns:

- user-initiated GitHub OAuth;
- an Entity-to-GitHub-account binding;
- encrypted OAuth token storage or a reference to the credential store;
- OAuth refresh/revocation behavior;
- GitHub repository permission probing;
- mapping GitHub PR/check/review APIs to the provider contract;
- resolving canonical GitHub SSH remote and host-key policy facts.

The OAuth token is resolved for the governed credential-owner Entity and provider
binding at operation time. The caller cannot select another account in args. The
token is not copied into an agent template, sidecar, `cc-headless` config
directory, task workspace, prompt, or transcript.

GitHub OAuth covers GitHub API operations. SSH identity covers Git transport.
Possession of one does not imply possession of the other; readiness reports both
states separately.

## 7. Task Workspace Provisioner

### 7.1 Lifecycle ordering

Governance/materialization first creates authoritative policy without any
agent-triggered filesystem or provider effect:

```text
governed task generation assigned
  -> governance creates GitTaskAccess policy using task URI + generation as its
     idempotency key
  -> governance creates/loads the provision record in planned state
  -> governance calls Cap.issue for the exact Resource instance/actions
  -> grantee agent self-stores and verifies the issued artifact
```

Only then may the agent request provisioning. Provisioning is a cap-checked
precondition of agent startup:

```text
agent dispatches to the pre-existing GitTaskAccess Resource
  -> Router verifies the instance/action cap once at the dispatch chokepoint,
     before the handler runs or any effect is produced/executed
  -> derive credential owner and provider binding from governed task state
  -> verify SSH identity and repository permissions
  -> clone/fetch repository cache as platform infrastructure
  -> create a task-specific branch/worktree
  -> verify project_cwd exists and matches the task
  -> CAS provision state to ready
  -> consume one sidecar-start token and start with project_cwd
```

The sidecar MUST NOT start if provisioning fails. This prevents the observed
`:sdk_sidecar_not_started` path caused by a nonexistent `project_cwd`.

### 7.2 Isolation and cleanup

- Every task generation has a unique deterministic branch/worktree identity.
- Concurrent agents never share a mutable checkout.
- The provisioner does not use a shared `git stash`.
- Task completion/cancellation schedules cleanup.
- A durable provision record keyed by task URI + generation owns state,
  worktree path, branch, lease, and sidecar-start token.
- Per-task locking plus compare-and-swap transitions make retries idempotent.
- A reaper may remove a worktree only when its lease expired and no live process
  or provision record matches that generation.

The state machine covers `planned`, `provisioning`, `ready`, `sidecar_started`,
`cleanup_pending`, `cleaned`, and `blocked`. Recovery handles crashes between Git
and database steps, duplicate claims, timeout retries, cancellation racing
startup, and concurrent reapers. A start token is valid for one generation and
prevents two sidecars from claiming the same worktree.

The provisioner owns directories and Git lifecycle, not credentials. Authorized
Git transport is performed by the Git Operation Broker after Router dispatch.

### 7.3 Observable task states

Kanban can project the following normalized state flow:

```text
assigned -> provisioning -> ready -> agent_working
         -> change_request_open -> ci_running -> review_ready
         -> awaiting_human_merge -> merged -> done
         -> blocked
```

The projection records facts produced by the provisioner/provider path rather
than optimistically moving cards before an external operation succeeds.

## 8. CapBAC and governance

Socialware installation/governance issues provenance-stamped, instance-scoped
capabilities through `Cap.issue`. It must not directly mutate `caps_json`.

Provider-neutral capability subjects/actions should express intent such as:

- repository read;
- branch push;
- change-request create/read;
- checks read;
- reviews read.

V1 uses only Capability dimensions that exist today: kind, Behavior/action,
instance, workspace, and provenance. The cap instance is the exact
`GitTaskAccess` Resource URI. Task, generation, credential owner, agent,
repository, provider instance, and allowed branch are immutable authoritative
fields of that Resource and are rechecked by its Behavior before invoking an
adapter or broker. They are not falsely represented as independent cap axes.

The agent is the grantee/self-store owner. Governance is the issuer; it calls
`Cap.issue`, produces an issued artifact carrying accountable provenance, and
follows ISSUE -> STORE -> VERIFY. Under the current same-BEAM/trusted-node model,
`Cap.verify` verifies provenance shape; this design does not claim a
cryptographic signature or cross-node absorb. If Capability Phase 4 lands first,
its separately approved signing semantics apply without changing this dispatch
boundary. The human credential owner and task owner are recorded separately. The
provider binding is derived from the governed Resource record, never from
caller-supplied account coordinates.

Current Capability has no expiry axis. V1 therefore revokes the task-access caps
and closes the Resource generation on terminal/cancelled state; the Behavior
fails closed for any non-active generation. Time-based cap expiry is deferred to
an independently approved Capability change and is not claimed by this design.

A cap for one task-generation Resource cannot authorize another. Branch push
does not imply change-request creation because they are distinct Behavior
actions. No agent-facing V1 cap grants merge. Action names use the current
Behavior/action query contract; no raw RPC or arbitrary eval is permitted.

## 9. User experience

### 9.1 SSH Identity settings

The settings surface shows configuration state, key type, fingerprint, public
key, provenance, timestamps, and provider verification state. It offers:

- generate;
- import;
- copy public key;
- verify;
- replace;
- revoke.

The import form explicitly states accepted formats and that an imported private
key cannot be retrieved afterward. Sensitive input is cleared after submission.

### 9.2 Provider integration settings

The GitHub surface shows connected account, granted scopes, connection time,
repository access test results, and SSH readiness. It offers connect,
reauthorize, disconnect, and repository verification.

The two readiness dimensions remain visible:

- **API ready**: OAuth binding can create/read change requests and checks;
- **Git transport ready**: SSH identity can clone/fetch/push the target repo.

## 10. Security and audit invariants

- No private key or OAuth token enters an agent process.
- No private key or token is persisted in snapshots, events, audit arguments,
  task cards, Kanban projections, logs, transcripts, or error reports.
- Sensitive request bodies are excluded from web/server logging.
- All secret reads are bound to an authenticated credential-owner Entity, active
  task generation, and cap-checked operation.
- Caller, grantee agent, credential owner, task owner, cap issuer, and audited
  external actor are distinct recorded roles. A provider binding is derived from
  immutable governed task state; there is no payload-selected or global fallback
  credential.
- Co-tenant credential lookup fails closed.
- Audits include caller, grantee agent, credential owner, cap issuer, task,
  provider, repository, operation, safe request ID, result, and credential
  fingerprint/reference.
- Versioned secret replacement is atomic from the caller's view; reconciliation
  handles cross-store failure and preserves the prior active credential before
  compare-and-swap.

Invariant tests permanently enforce: no new Git URI scheme; no direct
Provisioner-to-provider operation call; every GitTaskAccess action declares a
required cap; no token/key/path/fd/environment reaches an agent; no agent merge
action; provision-before-sidecar ordering; task-generation idempotency; and a
second fake provider passing the same contract suite without attaching a
duplicate provider-neutral Behavior/action namespace. Unauthorized dispatch must
produce no filesystem, provision-record, secret-store, or provider API mutation.

## 11. V1 delivery slices and estimate

Before implementation estimation is accepted, a mandatory discovery/go-no-go
slice inventories the approved secret-store abstraction, encryption-key
hierarchy, SSH parsing library, OS-process isolation primitive, and existing
provider-adapter registration seam. It must demonstrate that secrets can be
brokered without entering the agent process. If no approved primitive exists,
the missing infrastructure is separately designed and estimated.

Suggested independently reviewable slices:

1. Discovery/go-no-go and threat-model evidence: **2–4 engineer-days**.
2. Provider-neutral Resources/Behaviors/adapter contract and fake-provider
   conformance/invariant tests: **3–5 engineer-days**.
3. Entity SSH Identity, encrypted secret integration, versioned
   generation/import/replacement/reconciliation, and redaction tests: **6–10
   engineer-days**.
4. SSH settings UI and post-replacement provider readiness: **3–5
   engineer-days**.
5. GitHub OAuth/binding and repository/change-request/check/review adapter:
   **5–8 engineer-days**.
6. Git Operation Broker plus idempotent Workspace Provisioner lifecycle:
   **7–12 engineer-days**.
7. Cap governance wiring, Kanban projection, and real canary E2E evidence: **3–5
   engineer-days**.

Supporting constrained private-key import adds approximately **5–8
engineer-days** over generation-only support; including UI, audit, and leak-path
verification, reserve **7–12 engineer-days**.

These estimates are planning ranges, not a commitment; implementation planning
must first inventory the existing secret-store and provider-adapter primitives.

## 12. Relationship to the W29 first closed loop

The W29 P0 demo does not wait for the whole self-service V1. It may use a test
user's manually and safely provisioned SSH identity and GitHub OAuth binding to
exercise the same production-facing provider and workspace boundaries.

The evidence must state which self-service pieces are absent. It must not place
a test token/private key in the agent, use raw RPC/eval/live-DB mutation, grant
wildcard caps, deploy, or merge without lead authorization.

## 13. Acceptance criteria

- A user can generate or import a supported SSH private key.
- Invalid/unsupported imports return redacted errors and preserve the old active
  key.
- Automated leak-path tests demonstrate that secrets are absent from durable
  Entity state, events, logs, error payloads, agent homes, and transcripts.
- A user can connect a GitHub account and inspect API/Git readiness independently.
- The agent cannot retrieve a GitHub token or SSH private key.
- Repository and base ref come from the task, not a hard-coded GitHub path.
- Repository, provider binding, and task authorization use registered
  `resource://` identities; no provider introduces a new URI scheme.
- Agent and Provisioner operations enter through Router/Behavior dispatch before
  adapter resolution; a direct adapter call cannot authorize an operation.
- A valid isolated worktree exists before sidecar startup, and duplicate claim or
  recovery cannot start a second sidecar for the same task generation.
- An authorized agent can push a task branch, create a real change request, and
  read checks/reviews through provider-neutral operations.
- An unauthorized agent/repository/action fails closed at the CapBAC gate.
- Kanban reflects confirmed task/provider facts and structured blockers.
- Merge remains lead/human-controlled, and `done` follows a confirmed merged or
  explicitly accepted terminal fact.
- A second provider can implement the provider contract without modifying
  Kanban, AgentRuntime, Entity SSH Identity, or Workspace Provisioner logic.

## 14. Deferred decisions

- Secret backend product and encryption-key hierarchy, after the mandatory
  discovery gate confirms the required interface and threat assumptions.
- Passphrase UX and whether decryption is per operation or at import time.
- Multiple identities and repository-specific key selection.
- Automated public-key registration/removal on providers.
- HTTPS Git credentials and GitHub App installation-token support.
- Lead-controlled merge capability and protected-branch policy integration.
- Time-based Capability expiry, requiring a separately approved Capability
  model change.
