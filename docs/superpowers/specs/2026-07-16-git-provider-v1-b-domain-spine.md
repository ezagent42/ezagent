# Git Domain Spine Design (Plan B Draft)

**Status:** Task 0 contract freeze; narrow auxiliary-type amendment requires architecture review before production scaffolding

**Upstream:** Plan A decision records in `docs/superpowers/specs/2026-07-16-git-provider-v1-a-decisions.md`

**Stack:** branch `feat/git-domain-spine`, stacked on Plan A PR #1423

This document authorizes neither deployment nor merge.

## 1. Goal

Create a provider-neutral Git domain spine that lets an authorized task dispatch a
small repository operation through an exact `GitTaskAccess` Resource to a selected
adapter. Prove with two fake adapters that the domain is not GitHub-specific, and
prove that an unauthorized dispatch produces no adapter, HTTP, secret, or
filesystem side effect.

This is an architectural seam, not the W29 canary loop itself.

## 2. App boundary

Add an independent umbrella app, `apps/ezagent_domain_git`.

The domain owns:

- provider-neutral value types;
- the `GitTaskAccess` Resource Kind and exact task-scoped URI contract;
- the Lifecycle ActionSet that is the only authorized adapter entry point;
- the adapter behaviour and adapter registry;
- deterministic validation and error normalization at that boundary.

Provider plugins own credentials, transport clients, provider API payloads, and
provider-specific error translation. A future workspace provisioner consumes the
Git domain but does not own provider access. Kanban orchestration supplies task
intent but does not call adapters directly.

## 3. Dependency direction

```text
provider plugin (GitHub / GitLab / Gitea)
                  |
                  v
          ezagent_domain_git
                  ^
                  |
 future workspace provision / kanban orchestration
```

The domain may depend on `ezagent_core` and the minimum existing domain contracts
needed for caller/resource identity. It must not depend on a provider plugin,
Phoenix UI, Kanban socialware, or workspace provisioning implementation.

## 4. Frozen provider-neutral contract

Plan B uses the `Ezagent.DomainGit` namespace and freezes the following four Plan A
contracts verbatim:

```elixir
defmodule Ezagent.DomainGit.RepositoryRef do
  @type t :: %__MODULE__{
          repository_uri: URI.t(),
          provider_adapter: atom(),
          provider_host: String.t(),
          external_id: String.t(),
          owner_path: String.t(),
          base_ref: String.t(),
          visibility: :public | :private
        }
end

defmodule Ezagent.DomainGit.FileChange do
  @type t :: %__MODULE__{
          path: String.t(),
          operation: :upsert,
          content: String.t()
        }
end

defmodule Ezagent.DomainGit.ChangeRequest do
  @type t :: %__MODULE__{
          external_id: String.t(),
          url: URI.t(),
          head_ref: String.t(),
          head_sha: String.t(),
          base_ref: String.t(),
          state: :open | :closed | :merged
        }
end

defmodule Ezagent.DomainGit.OperationContext do
  @type t :: %__MODULE__{
          task_access_uri: URI.t(),
          caller_uri: URI.t(),
          grantee_uri: URI.t(),
          idempotency_key: String.t()
        }
end
```

`OperationContext` is constructed inside the authorized ActionSet from dispatch
identity plus the authoritative Resource policy. It is never accepted in invocation
arguments. No value contains a token, credential reference, path to a credential,
local checkout path, Req client, raw provider payload, or Cap.

### 4.1 Narrow contract amendment requiring review

Plan A references but does not define five types. Task 0 proposes these minimum
closed, provider-neutral shapes; they are **not approved for production scaffolding
until architecture review accepts this amendment**:

```elixir
defmodule Ezagent.DomainGit.CreateChangeRequest do
  @type t :: %__MODULE__{
          title: String.t(),
          body: String.t(),
          head_ref: String.t(),
          base_ref: String.t(),
          expected_base_sha: Ezagent.DomainGit.CommitSha.t()
        }
end

defmodule Ezagent.DomainGit.ChangeRequestId do
  @type t :: %__MODULE__{external_id: String.t()}
end

defmodule Ezagent.DomainGit.CommitSha do
  @type t :: %__MODULE__{value: String.t()}
end

defmodule Ezagent.DomainGit.Check do
  @type status :: :queued | :in_progress | :completed
  @type conclusion :: :succeeded | :failed | :cancelled | :skipped | :neutral | :timed_out
  @type t :: %__MODULE__{
          external_id: String.t(),
          name: String.t(),
          status: status(),
          conclusion: conclusion() | nil,
          url: URI.t() | nil
        }
end

defmodule Ezagent.DomainGit.Review do
  @type state :: :pending | :approved | :changes_requested | :commented | :dismissed
  @type t :: %__MODULE__{
          external_id: String.t(),
          author: String.t(),
          state: state(),
          submitted_at: DateTime.t() | nil
        }
end
```

Evidence and rationale:

- W29's tested request plan supplies `base_ref`, expected `base_sha`, `head_ref`,
  `title`, and `body`; the deterministic idempotency key remains in
  `OperationContext` (`apps/ezagent_core/test/security/github_api_commit_transport_test.exs:116`).
- Plan A returns a provider external change-request id and a head SHA
  (`apps/ezagent_core/test/security/github_api_commit_transport_test.exs:21`), while
  its approved `ChangeRequest` already names `external_id` and `head_sha`
  (`docs/superpowers/specs/2026-07-16-git-provider-v1-a-decisions.md:78`).
- Current domain terminology uses “checks” across GitHub checks/actions and GitLab
  pipelines/jobs, and “reviews” across reviews/approvals
  (`docs/superpowers/specs/2026-07-15-git-provider-v1-design.md:228`). These shapes
  expose only lifecycle facts needed for `ci_running` and `review_ready`
  (`docs/superpowers/specs/2026-07-15-git-provider-v1-design.md:463`).
- `Review.author` is display-only provider-neutral text, not an Ezagent identity or
  authorization coordinate. Whether this is sufficiently narrow is the amendment's
  explicit review concern; external reviewers need not have an Ezagent Entity URI.

These structs are closed. They accept no arbitrary maps, provider payloads, token,
credential, credential reference, Req/client, local path, or Cap field.

Constructors validate closed enums, required fields, normalized repository-relative
paths, non-empty refs, URI axes, configured file size/count limits, and UTF-8 content
before dispatch reaches an adapter. Deletes, binary changes, rename/mode changes,
symlinks, submodules, traversal, absolute paths, and `.git` paths are rejected.

## 5. GitTaskAccess Resource

Each development task receives a distinct Resource-pattern Kind instance. “Cold”
describes the Resource pattern, not snapshot restoration: the first slice declares
`persistence/0` as `:ephemeral`, explicitly spawns the instance before dispatch, and
owns it under a domain DynamicSupervisor. Its exact URI is the authorization target;
repository-wide or workspace-wide wildcard access is not substituted by the domain.

The stable URI shape must be finalized against the current URI SPEC when Plan B is
rebased onto main. The intended semantic components are:

```text
resource://<workspace>/<registered-git-task-access-type>/<task-access-id>
```

The URI is built with `Ezagent.URI.resource/3`; action targets use
`Ezagent.URI.with_action/3`, never string concatenation. Preflight selects the final
registered type string (prefer the repository's current hyphenated convention if it
remains canonical).

The ephemeral Resource holds an authoritative closed task policy containing at
least: task id, generation, `workspace_uri`, credential-owner/entity URI, assigned
agent/grantee URI, normalized repository binding, provider adapter binding, allowed actions, and non-secret
idempotency inputs. The policy is supplied only through the supported spawn/init
path, validates all URI/workspace relationships, defines idempotent same-policy
spawn and conflicting-policy collision behavior, and is removed on supervised
teardown. There is no lazy snapshot activation in this slice.

Adapter selection comes exclusively from this stored policy. A request-side
`RepositoryRef`, where an action requires one, is only a normalized assertion that
must equal the stored binding; it never selects or redirects the provider.

## 6. ActionSet and actions

`Ezagent.ActionSet.GitTaskAccess` uses `Ezagent.Lifecycle`. It is the only production
module allowed to resolve and invoke a Git adapter.

Initial action vocabulary follows the Plan A contract:

- `:resolve_repository`
- `:create_change_request`
- `:read_change_request`
- `:list_checks`
- `:list_reviews`

Merge is explicitly absent. The ActionSet validates that invocation arguments and
the selected repository agree with the target task-access Resource before looking
up an adapter.

## 7. Adapter contract and registry

`Ezagent.DomainGit.Adapter` defines the five exact Plan A callbacks:
`resolve_repository/2`, `create_change_request/4`, `read_change_request/3`,
`list_checks/3`, and `list_reviews/3`:

```elixir
@callback resolve_repository(OperationContext.t(), RepositoryRef.t()) ::
            {:ok, RepositoryRef.t()} | {:error, Error.t()}

@callback create_change_request(
            OperationContext.t(),
            RepositoryRef.t(),
            [FileChange.t()],
            CreateChangeRequest.t()
          ) :: {:ok, ChangeRequest.t()} | {:error, Error.t()}

@callback read_change_request(
            OperationContext.t(),
            RepositoryRef.t(),
            ChangeRequestId.t()
          ) :: {:ok, ChangeRequest.t()} | {:error, Error.t()}

@callback list_checks(OperationContext.t(), RepositoryRef.t(), CommitSha.t()) ::
            {:ok, [Check.t()]} | {:error, Error.t()}

@callback list_reviews(
            OperationContext.t(),
            RepositoryRef.t(),
            ChangeRequestId.t()
          ) :: {:ok, [Review.t()]} | {:error, Error.t()}
```

Every callback receives validated
`Ezagent.DomainGit` values and returns the frozen closed result/error contract.
Generic SSH clone/fetch/push and merge callbacks remain absent.

`Ezagent.DomainGit.AdapterRegistry` maps a stable provider id to an adapter module. It:

- validates `@behaviour Ezagent.DomainGit.Adapter` and required callbacks at registration;
- rejects invalid ids and conflicting duplicate registrations deterministically;
- exposes adapter-selecting lookup only to the ActionSet; any operator-facing
  non-effectful list is exposed through a domain-owned diagnostic wrapper;
- performs no authorization and stores no credentials;
- does not call adapter callbacks during registration.

Registration is dependency injection only. Repository-wide structural gates forbid
adapter-selecting registry lookup and adapter callback invocation outside the Git
domain ActionSet; registry internals may validate declarations but never execute a
callback.

## 8. Authorization and effect ordering

The required call path is:

```text
Invocation
  -> exact GitTaskAccess Resource
  -> CapBAC authorization
  -> GitTaskAccess ActionSet
  -> AdapterRegistry lookup
  -> provider adapter callback
```

Authorization must complete before registry lookup or any provider effect. Tests
use observable fake counters/messages and failing sentinels to prove that an
unauthorized invocation causes:

- zero adapter callbacks;
- zero HTTP requests;
- zero credential/secret resolution;
- zero filesystem mutation.

The registry is never treated as an authorization boundary. The adapter never
receives a raw Cap and cannot broaden access.

The authorized test path constructs a capability with concrete Kind, ActionSet,
action, workspace, and exact `Ezagent.URI.instance(task_access_uri)` axes. It calls
the current `Cap.issue(authorization, grantee_uri, capability)`, verifies the
receiver-bound artifact using `Cap.verify_for/2`, and presents only that artifact as
the actual grantee through the real Invocation path. Raw `%Capability{}` injection,
unsigned caps, wildcard workspace/instance axes, raw RPC, and eval are forbidden.
Negative proofs cover wrong grantee, action, task instance, and workspace.

## 9. Fake-adapter proof

Two fake providers register under different ids and return distinguishable results.
Each test owns a unique synchronous effect probe. If a fake callback is entered it
trips adapter, HTTP, secret, and filesystem bomb sentinels before returning. Tests
are non-async or use unique registry/process names, clean up with `on_exit`, and use
a synchronization barrier rather than sleeps before asserting absence of messages.
Contract tests prove:

1. both satisfy the same adapter behaviour;
2. an authorized exact-resource dispatch selects only the requested provider;
3. repository data cannot redirect the invocation to an unbound provider;
4. an unknown provider returns a closed domain error;
5. an unauthorized dispatch has zero observable effects;
6. direct adapter access is caught by a structural test.

## 10. Error model

`Ezagent.DomainGit.Error.t()` is the exact Plan A union:

```elixir
:provider_account_not_connected
| :credential_backend_unavailable
| :repository_not_found
| :repository_read_denied
| :repository_write_denied
| :private_checkout_not_supported
| :base_ref_not_found
| :base_sha_mismatch
| :invalid_ref
| :invalid_file_change
| :change_limit_exceeded
| :change_request_conflict
| :checks_unavailable
| :provider_unavailable
| :authentication_rejected
| {:provider_request_failed, operation :: atom(), status :: pos_integer()}
```

Plan B separately freezes closed pre-adapter errors for invalid construction,
unknown adapter, policy mismatch, authorization, and unsupported action instead of
smuggling them into provider errors. Secrets, raw HTTP bodies/headers, provider
exception structs, request maps, and filesystem paths never escape in results/logs.

## 11. Boot, rollback, and restart

Application startup owns supervisor/registry startup followed by
Kind/CapabilityRegistry bindings. Registration is repeatable when the identical
binding already exists. If the Nth registration or a later child fails, startup
unregisters every binding created by that attempt and stops its children, leaving no
partial global ETS state. Tests cover child-start failure, Nth-binding failure,
repeat start, registry restart, and complete cleanup. Provider adapter declaration
follows the same all-or-nothing boot contract without executing adapter callbacks.

## 12. Explicit non-goals

- GitHub plugin, OAuth, token storage, or credential configuration UI;
- SSH public/private key management;
- clone, checkout, worktree creation, cleanup, or sidecar startup;
- Kanban dispatch/status integration;
- database migrations or durable GitTaskAccess persistence;
- merge operations;
- canary deployment;
- `#1360` Layer B, AgentRuntime ARB, EntityCaps work, or bridge join/#1405.

## 13. Acceptance criteria

Plan B is ready to hand to the next slice when:

- the independent domain app compiles without provider dependencies;
- two fake adapters pass one shared contract suite;
- an authorized in-memory task action dispatches through its exact
  `GitTaskAccess` Resource and reaches exactly one fake adapter;
- an unauthorized dispatch returns the canonical authorization error with zero
  mutation/effects;
- structural gates prevent adapter/registry bypass and provider dependency leakage;
- boot failure/restart leaves no partial CapabilityRegistry or adapter state;
- focused regression, umbrella static gates, and `mix precommit` pass from a clean
  worktree, or any unrelated baseline failure is reproduced and recorded honestly.

## 13.1 Exact incremental assertions for Tasks 2–3

Task 2's `plan_a_contract_test.exs` will assert:

1. exact namespaces under `Ezagent.DomainGit`: `RepositoryRef`, `FileChange`,
   `ChangeRequest`, `OperationContext`, `CreateChangeRequest`, `ChangeRequestId`,
   `CommitSha`, `Check`, `Review`, and `Error`;
2. exact struct keys matching §4/§4.1, with no extra fields;
3. closed enums for `FileChange.operation`, repository visibility,
   change-request state, and the proposed check/review states;
4. `Ezagent.DomainGit.Error.t()` contains exactly all 15 atom members and the
   `{:provider_request_failed, atom(), pos_integer()}` member in §10;
5. source and compiled struct inspection reject fields matching token, secret,
   credential, credential reference/path, Req/client, checkout/local path,
   provider payload/request/response, environment, callback, or Cap.

Task 3 will extend that gate and its shared fake-adapter suite to assert:

1. exactly the five callbacks and arities in §7, with the exact typed arguments and
   result shapes shown there;
2. exactly five ActionSet actions: `:resolve_repository`,
   `:create_change_request`, `:read_change_request`, `:list_checks`, and
   `:list_reviews`;
3. both fake adapters compile with `@behaviour Ezagent.DomainGit.Adapter` and pass
   the same result/error contract;
4. no callback accepts maps, provider payloads, credentials/tokens, Req/client,
   checkout/local path, or Cap;
5. callback/action inventories contain no merge, clone, fetch, push, SSH, checkout,
   or credential operation.

## 14. Branching and landing

This tracked Task 0 documentation is intentionally stacked on Plan A PR #1423 in
`feat/git-domain-spine`. Do not begin production Task 1+ until the auxiliary-type
amendment is approved, #1423 lands, and this branch is rebased onto current
`origin/main`; then re-read current architecture gates and record any mainline drift.
Only the authorized lead flow may merge, deploy, or promote the branch.
