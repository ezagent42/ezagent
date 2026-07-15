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
4. **Kanban/socialware governance** issues precise, signed, task-scoped caps via
   `Cap.issue`; it does not write `caps_json` directly.

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
        Task Workspace Provisioner
                |
                v
       Git Provider contract/registry
        |           |            |
        v           v            v
   GitHub plugin  GitLab plugin  Gitea plugin
        |                         (future)
        +---- OAuth/API credential binding
        |
        +---- Entity SSH Identity ---- encrypted secret backend
                |
                v
         isolated project_cwd
                |
                v
      cc-headless / :in_process_sync
```

The dependency direction is load-bearing:

- AgentRuntime and Workspace Provisioner know the provider contract, not GitHub.
- GitHub-specific OAuth scopes, API responses, PRs, checks, and reviews stay in
  the GitHub plugin.
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

### 4.3 Import and replacement transaction

```text
receive sensitive request
  -> parse with redaction-safe errors
  -> validate algorithm/policy
  -> derive public key and fingerprint
  -> stage encrypted secret
  -> verify provider connection when a provider binding exists
  -> atomically switch the active secret reference
  -> revoke/delete the staged or former secret according to retention policy
```

Failure before the pointer switch leaves the existing active identity usable.
No response includes private material. The request path must disable body and
parameter logging, and error reporting must receive only a redacted error code,
algorithm, and fingerprint where available.

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
- revoke identity;
- request a bounded SSH authentication/signing context.

The final operation is internal and cap-gated. There is no `get_private_key`
operation. Where a Git subprocess requires filesystem material, a broker creates
a short-lived mode-0600 credential view outside the agent workspace, binds it to
one operation, and removes it on completion. The path and contents are never
returned to the agent.

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

### 5.2 Repository reference

A Kanban card or socialware configuration supplies a normalized reference:

```text
provider: github
provider_host: github.com
repository: ezagent-chat/ezagent
base_ref: main
```

The canonical resource identity should be provider-neutral, for example:

```text
gitrepo://github/ezagent-chat/ezagent
```

Self-hosted providers require an unambiguous provider instance/host in the
resolved record. Callers must not infer provider solely from string matching a
clone URL.

### 5.3 Contract operations

V1 defines provider operations equivalent to:

- resolve and normalize a repository reference;
- check acting-user read/write access;
- prepare bounded clone/fetch/push authentication;
- create a change request;
- read a change request;
- list check/CI state;
- list review state.

Merge is deliberately absent from the agent-granted V1 interface. A plugin may
later implement it for a separate lead-controlled path.

The contract returns normalized data and structured errors. Raw GitHub response
maps must not leak into Kanban or Workspace Provisioner state.

### 5.4 Normalized errors

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
- brokering clone/fetch/push using the Entity SSH identity.

The OAuth token is resolved for the acting Entity at operation time. It is not
copied into an agent template, sidecar, `cc-headless` config directory, task
workspace, prompt, or transcript.

GitHub OAuth covers GitHub API operations. SSH identity covers Git transport.
Possession of one does not imply possession of the other; readiness reports both
states separately.

## 7. Task Workspace Provisioner

### 7.1 Lifecycle ordering

Provisioning is a precondition of agent startup:

```text
task assigned
  -> resolve repository/provider
  -> verify task caps and acting-user provider binding
  -> verify SSH identity and repository permissions
  -> clone/fetch repository cache as platform infrastructure
  -> create a task-specific branch/worktree
  -> verify project_cwd exists and matches the task
  -> start the agent sidecar with project_cwd
```

The sidecar MUST NOT start if provisioning fails. This prevents the observed
`:sdk_sidecar_not_started` path caused by a nonexistent `project_cwd`.

### 7.2 Isolation and cleanup

- Every task has a unique worktree and working directory.
- Concurrent agents never share a mutable checkout.
- The provisioner does not use a shared `git stash`.
- Task completion/cancellation schedules cleanup.
- A reaper handles abandoned worktrees using task ownership and age, without
  deleting an active worktree.

The provisioner owns directories and Git lifecycle, not credentials. It asks a
provider plugin for a bounded authentication context and destroys that context
after the Git operation.

### 7.3 Observable task states

Kanban can project the following normalized state flow:

```text
assigned -> provisioning -> ready -> agent_working
         -> pr_open -> ci_running -> review_ready -> done
         -> blocked
```

The projection records facts produced by the provisioner/provider path rather
than optimistically moving cards before an external operation succeeds.

## 8. CapBAC and governance

Socialware installation/governance issues signed, board/task-scoped capabilities
through `Cap.issue`. It must not directly mutate `caps_json`.

Provider-neutral capability subjects/actions should express intent such as:

- repository read;
- branch push;
- change-request create/read;
- checks read;
- reviews read.

The cap scope binds at least:

- acting Entity;
- agent Entity;
- workspace/session/task;
- provider instance;
- repository;
- branch or ref where relevant;
- action;
- expiry.

A cap for one repository or task cannot authorize another. A branch-push cap
does not imply change-request creation. No agent-facing V1 cap grants merge.

Exact action names and URI query encodings must follow the current Behavior/Kind
URI contract when the implementation plan is written; this design intentionally
does not bypass that contract with raw RPC or arbitrary eval.

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
- All secret reads are bound to an authenticated acting Entity and a cap-checked
  operation.
- A provider binding is resolved by acting Entity + provider instance + provider
  account + repository; there is no global fallback credential.
- Co-tenant credential lookup fails closed.
- Audits include acting Entity, agent, task, provider, repository, operation,
  safe request ID, result, and credential fingerprint/reference.
- Secret replacement is atomic from the caller's view and failure preserves the
  prior active credential.

## 11. V1 delivery slices and estimate

Suggested independently reviewable slices:

1. Provider-neutral contract, normalized repository reference, and fake-provider
   contract tests: **1–3 engineer-days**.
2. Entity SSH Identity, encrypted secret integration, generation/import,
   replacement, and redaction tests: **3–5 engineer-days**.
3. SSH settings UI and provider connection verification: **2–4 engineer-days**.
4. GitHub OAuth/binding and repository/change-request/check/review adapter:
   **4–7 engineer-days**.
5. Workspace Provisioner lifecycle and task state projection: **4–7
   engineer-days**.
6. Cap governance wiring and real canary E2E evidence: **2–4 engineer-days**.

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
- A valid isolated worktree exists before sidecar startup.
- An authorized agent can push a task branch, create a real change request, and
  read checks/reviews through provider-neutral operations.
- An unauthorized agent/repository/action fails closed at the CapBAC gate.
- Kanban reflects confirmed task/provider facts and structured blockers.
- Merge remains lead/human-controlled.
- A second provider can implement the provider contract without modifying
  Kanban, AgentRuntime, Entity SSH Identity, or Workspace Provisioner logic.

## 14. Deferred decisions

- Secret backend product and encryption-key hierarchy, after inventorying the
  currently approved operational secret facilities.
- Passphrase UX and whether decryption is per operation or at import time.
- Multiple identities and repository-specific key selection.
- Automated public-key registration/removal on providers.
- HTTPS Git credentials and GitHub App installation-token support.
- Lead-controlled merge capability and protected-branch policy integration.
- Stable URI/action spelling after review against the current URI SPEC and
  action-axis migration state.
