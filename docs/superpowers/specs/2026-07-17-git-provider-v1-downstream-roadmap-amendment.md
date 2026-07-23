# Git Provider V1 downstream roadmap amendment

**Status:** design approved for planning

**Date:** 2026-07-17

**Owner:** gaga

**Amends:** `2026-07-15-git-provider-v1-design.md` delivery sequencing only

## 1. Why this amendment exists

Plan A froze the downstream order as:

1. Plan B — provider-neutral Git domain spine;
2. Plan C — public anonymous checkout and task worktree provisioning;
3. Plan D — GitHub OAuth, Req, Git Data, pull request, checks, and reviews;
4. Plan E — settings, Kanban fact projection, and canary acceptance.

Plan B is now implemented on Draft PR #1445. A later discussion accidentally
called GitHub credential import "Plan C" and selected fine-grained PAT import as
the default connection method. That renaming lost the Plan C workspace seam and
made completed Plan B components appear greenfield. This amendment restores the
frozen order and withdraws PAT-first as the product default.

The amendment preserves the original requirements: user-owned provider
authorization, provider plugins, no credential in an agent, public checkout
before sidecar start, exact CapBAC authority, and future GitLab/Gitee/Gitea
support.

## 2. Source classification

### 2.1 Original requirements retained

- Plan C owns public checkout, per-task worktrees, `project_cwd`, and
  provision-before-sidecar ordering.
- Plan D is OAuth-first and GitHub is only the first provider plugin.
- Plan E owns user settings, confirmed Kanban facts, and real canary evidence.
- SSH, private checkout, agent merge authority, demo stabilization, AgentRuntime
  ARB, EntityCaps A/B/D, `caps_json` persistence, no-tail enforcement, cc-PTY
  bridge join/#1405, and #1360 Layer B are outside this delivery line.

### 2.2 Implemented facts retained

Plan A selected public anonymous checkout plus GitHub Git Data API and rejected
same-UID SSH secret brokering. Plan B delivered the `Ezagent.DomainGit` values,
`GitTaskAccess`, adapter contract/registry, signed receiver-bound dispatch,
closed errors, boot registration, and unauthorized-no-effect gates. Plans C–E
consume those interfaces and do not recreate them.

### 2.3 Evidence-based changes

1. W29 Plan C implements only the first-loop reliability minimum. Long-term
   pooling, cross-node leases, and comprehensive reaping remain target design,
   not first-loop DoD.
2. Plan D makes the already-required provider binding explicit as a thin,
   provider-neutral connection lifecycle. OAuth endpoints, scopes, token
   responses, refresh behavior, webhooks, and API payloads stay plugin-owned.
3. Fine-grained PAT import is not the default product path. A provider plugin
   may add it later as an explicit acquisition method with provider-specific
   limitations.
4. Plan D starts with a narrow D0 reuse gate for OneAuth and OneSystem. It
   freezes replaceable interfaces before choosing a local or remote backend; it
   does not make incomplete external services a W29 runtime dependency.

## 3. Frozen dependency direction

```text
provider authorization driver        provider Git adapter
             |                                |
             v                                v
 ProviderConnection lifecycle         Ezagent.DomainGit.Adapter
             |                                |
             +---------- opaque refs ---------+
                              |
                              v
                    encrypted credential backend

Kanban -> governed task policy -> GitTaskAccess dispatch -> provider adapter
Task Workspace Provisioner -> validated public RepositoryRef -> project_cwd
```

The connection lifecycle never authorizes a Git operation. `GitTaskAccess`
remains the only provider-operation entry. The credential backend never returns
a secret to an agent, task card, Kanban projection, snapshot, audit event, or
generic caller-selected decrypt endpoint.

## 4. Revised downstream plans

### 4.1 Plan C — public task workspace provisioner

Plan C consumes Plan B's validated `RepositoryRef` and authoritative task policy.
It adds a provider-neutral pre-start port outside `plugin_cc`, a durable record
keyed by task access URI plus generation, anonymous public fetch/clone, isolated
task worktree, ready verification, one-generation sidecar-start claim, explicit
cleanup, and structured blockers.

First-loop DoD requires CAS/idempotency, public-only fail-closed behavior,
provision-before-sidecar, generation isolation, explicit cleanup, and
unauthorized-no-filesystem-effect tests. It defers private/authenticated checkout,
SSH, pooling, cross-node leases, and comprehensive stabilization.

### 4.2 Plan D0 — OneAuth/OneSystem reuse gate

D0 is a bounded design/proof task, not a third product platform. It freezes two
replaceable ports:

```elixir
ProviderAuthorizationBackend
CredentialBackend
```

The proof must support one in-process fake and one remote-shaped fake without
changing `DomainGit`, Kanban, the workspace provisioner, or provider operation
contracts. It decides, with executable and operational evidence, whether the
first GitHub slice uses local implementations or existing H2OS services.

Current evidence constrains the decision:

- OneAuth owns human identity, sessions, AAL, external-login provider client
  configuration, sensitive-field masking, and KEK-encrypted operator secrets.
- OneAuth's current external OIDC support authenticates a human into a product;
  it does not expose a task-bound connected-account token broker for repository
  operations.
- OneSystem has a real SOPS/Age secret manager, but its current admin decrypt API
  returns plaintext to a generic caller and therefore is not an acceptable
  credential-use boundary.

D0 may reuse OneAuth identity/re-authentication and provider catalog concepts.
It must not reuse a social-login token as repository consent, call the generic
OneSystem decrypt API, create a second authority source, or make W29 depend on a
new cross-service deployment without lead authorization.

### 4.3 Plan D1 — provider connection substrate

The minimum common model records owner/workspace, provider id, governed host,
immutable external account id, display login, execution identity,
plugin-declared acquisition method, opaque credential reference, status,
version, and timestamps.

Common lifecycle owns state/PKCE correlation, callback single consumption,
atomic credential replacement, refresh CAS, revoke/status transitions, and
secret-safe audit. Provider plugins own authorization/token/revoke endpoints,
scopes, permission probes, refresh semantics, webhook parsing, and provider
metadata. A second fake driver proves the substrate is not GitHub-specific.

### 4.4 Plan D2 — GitHub connection and Git adapter

The first product connection method is OAuth-based GitHub user authorization.
The GitHub plugin verifies the canonical account and repository readiness,
stores access/refresh material behind `CredentialBackend`, and implements the
existing five `Ezagent.DomainGit.Adapter` callbacks with Req.

The plugin productionizes Plan A's Git Data plan and adds the minimum durable
attempt reconciliation for deterministic head refs, base-SHA races, partial
branch/PR success, and retries. Authorization headers and raw provider bodies
never enter request plans, returned structs, logs, telemetry, or errors.

GitHub App user authorization is the preferred GitHub driver candidate, not a
cross-provider domain concept. The Plan D design must confirm its exact actor,
installation, callback, refresh, and revocation semantics before implementation.

**D2 is the git team's delivery endpoint.** When the GitHub plugin can be called
independently by agents via the existing action/skill mechanisms, the git
development line is complete. Kanban integration, socialware manifest
registration, and agent skill orchestration are not in git plugin scope — they
are Allen's integration layer (see §4.5).

### 4.5 Plan E — integration and acceptance (Allen's layer)

Plan E is not a git team deliverable. Once the GitHub plugin is a working OTP
app that exposes Driver + Adapter + CredentialBackend, Allen integrates it:

- **socialware manifest registration**: the git plugin is declared as an
  available capability in the socialware registry
- **agent skill orchestration**: the "create PR → wait CI → review → merge"
  workflow is an agent skill, not git plugin code
- **Kanban fact projection**: card-level Git status (PR open, CI passing,
  merged) is rendered from git plugin return values at the Kanban surface
  layer, without coupling the plugin to Kanban concepts
- **canary acceptance**: real agent → PR → CI → review → merge loop with
  screenshots and transcript

The git plugin stays provider-neutral in its domain interfaces (Driver deals
with OAuth lifecycle state, Adapter returns closed DomainGit value types).
Allen's layer owns the orchestration, UX, and product acceptance evidence.

## 5. OneAuth/OneSystem replacement boundary

The V1 record stores opaque backend references rather than exposing ciphertext
shape to consumers. A local backend may ship first if D0 finds no production-safe
remote contract. A later OneAuth connected-account backend or OneSystem-managed
secret backend may replace it only if it preserves:

- canonical OneAuth/ezagent owner mapping;
- workspace and provider-host isolation;
- operation-bound authorization;
- versioned refresh/revoke and fail-closed reads;
- no generic plaintext retrieval;
- correlated audit without secret material;
- no second CapBAC or task-policy truth source.

Backend replacement must not alter `DomainGit.Adapter`, `GitTaskAccess`, Kanban,
or workspace provisioning.

## 6. Readiness and sequencing

```text
Plan A complete
  -> Plan B complete
       -> Plan C workspace -----------------------+
       -> Plan D0 reuse gate                      |
            -> Plan D1 connection substrate       |
                 -> Plan D2 GitHub connection/API +-> Plan E canary acceptance

cc-headless MCP + credential/rematerialization readiness -> Plan E
```

Plan C implementation and D0/D1 design may proceed independently after their
consumed Plan B interfaces are on the same updated main stack. Plan E waits for
both lines and for the separately owned cc-headless readiness gates.

## 7. Scope delta

Relative to the original A–E program:

- A and B: no change;
- C: same architecture, first-loop stabilization scope reduced;
- D: OAuth-first restored; thin provider-connection contract and D0 replacement
  seam added; PAT-first product work removed;
- E: same acceptance responsibility, now consumes the common connection read
  model;
- overall expected implementation delta: approximately flat to five percent
  additional work, subject to D0 findings.

Choosing to build a full OneAuth connected-account broker now is not authorized
by this amendment. That would be a separate cross-repository plan and lead
decision.

## 8. Planning gate

The next executable design is Plan C. It must list every consumed Plan B API and
every frozen component it cannot recreate. Plan D planning begins with D0; no
OAuth or credential implementation starts until D0's ownership decision and
replacement contracts are reviewed.
