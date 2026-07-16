# Git Domain Spine Design (Plan B Draft)

**Status:** Task 0 contract freeze; value-construction amendment requires architecture review before Task 2 RED

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

### 4.1 Review-fixed narrow contract amendment

Plan A references but does not define five types. Task 0 proposes these minimum
closed, provider-neutral shapes, corrected to the architecture review's required
authority, normalization, projection, and review-event decisions:

```elixir
defmodule Ezagent.DomainGit.CreateChangeRequest do
  @type t :: %__MODULE__{
          title: String.t(),
          body: String.t(),
          head_ref: String.t(),
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
  @type conclusion ::
          :succeeded
          | :failed
          | :cancelled
          | :skipped
          | :neutral
          | :timed_out
          | :action_required
          | :other
  @type t :: %__MODULE__{
          external_id: String.t(),
          name: String.t(),
          status: status(),
          conclusion: conclusion() | nil,
          url: URI.t() | nil
        }
end

defmodule Ezagent.DomainGit.Review do
  @type state :: :approved | :changes_requested | :commented | :dismissed
  @type t :: %__MODULE__{
          external_id: String.t(),
          author_label: String.t(),
          state: state(),
          submitted_at: DateTime.t() | nil
        }
end
```

Evidence and rationale:

- W29's tested request plan supplies expected `base_sha`, `head_ref`, `title`, and
  `body`; the authoritative `base_ref` comes only from the stored-policy-bound
  `RepositoryRef`, while the deterministic idempotency key remains in handler-built
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
- `Review` is a normalized submitted/latest review event. Its `external_id` is the
  stable provider event id used for dedupe. `author_label` is display-only and is
  structurally forbidden for authorization, identity matching, ownership, or
  dedupe; external reviewers need not have an Ezagent Entity URI.

Check normalization is total: an unrecognized but legitimate provider terminal
outcome becomes `:other`, never a raw provider string; an actionable, manual, or
blocked outcome becomes `:action_required` when provider semantics require human
action. `conclusion` is `nil` only while queued/in progress; every completed check
has one closed conclusion. W29 projects `:queued` and `:in_progress` to `ci_running`. For `:completed`,
`:succeeded`, `:neutral`, and `:skipped` are non-failing; `:failed`, `:timed_out`,
and `:cancelled` are failing; `:action_required` and `:other` remain non-green and
require inspection rather than being falsely projected green.

These structs are closed. They accept no arbitrary maps, provider payloads, token,
credential, credential reference, Req/client, local path, or Cap field.

Constructors validate closed enums, required fields, normalized repository-relative
paths, non-empty refs, URI axes, configured file size/count limits, and UTF-8 content
before dispatch reaches an adapter. Deletes, binary changes, rename/mode changes,
traversal, absolute paths, and `.git` paths are rejected by these values. Symlink
and submodule rejection belongs to the upstream capture boundary, because a
provider-neutral `FileChange` contains bytes and cannot inspect filesystem kind.

### 4.2 Review-required value construction and limit amendment

This amendment must receive architecture review before Task 2 writes its RED tests.
Every value module in §4 and §4.1 exposes `new/1`. It accepts only a map whose exact
atom-key set matches the frozen struct fields and returns
`{:ok, t()}` or `{:error, Ezagent.DomainGit.ValidationError.t()}`. Constructors do
not accept string-keyed maps, keyword lists, positional overloads, or partially
trusted structs. Validation failures never echo rejected values.

`Ezagent.DomainGit.ValidationError` is a closed pre-adapter construction type:

```elixir
@type t ::
        :invalid_attributes
        | :invalid_file_change
        | :change_limit_exceeded
        | {:missing_field, atom()}
        | :unknown_fields
        | {:invalid_field, atom()}
```

Validation order is fixed and non-echoing: reject a non-map or any non-atom key as
`:invalid_attributes` without converting keys; then reject any unknown atom key as
`:unknown_fields`; then report missing static allowed fields in deterministic module
field order as `{:missing_field, field}`; then validate values and return
`{:invalid_field, field}`. Missing/invalid field names are static schema atoms only.
This type is distinct from the frozen provider/adapter
`Ezagent.DomainGit.Error.t()` in §10.

`Ezagent.DomainGit.ChangeLimits` is a closed struct with exactly `max_files`,
`max_file_bytes`, and `max_total_bytes`. Its `current/0` owns the V1 collection
safety limits and has the contract
`{:ok, t()} | {:error, :invalid_change_limits_config}`. It reads runtime
`Application.get_env(:ezagent_domain_git, :change_limits, defaults)` with these
exact keys and defaults:

```elixir
%{max_files: 100, max_file_bytes: 1_000_000, max_total_bytes: 5_000_000}
```

Defaults apply only when the whole configuration is absent. An explicitly
configured value with missing or unknown keys, or a non-positive/non-integer limit,
returns `{:error, :invalid_change_limits_config}`; it never raises, uses a bang
path, or silently falls back. `EzagentDomainGit.Application.start/2` calls
`current/0` before starting children and returns that error unchanged.
These defaults are promoted from Plan A's tested prototype into domain-owned V1
safety defaults. Operators may configure them; invocation and agent payloads may
not supply or override them.

`FileChange.new/1` validates a single V1 UTF-8 regular-file-byte `:upsert`, including
the repository-relative path exclusions above, but applies no collection
limit. `FileChange.validate_many/1` accepts only a non-empty list of already-built
`FileChange` structs, loads `ChangeLimits.current/0` internally, and returns
`:ok | {:error, :invalid_file_change | :change_limit_exceeded |
:invalid_change_limits_config}`. Count uses list length; per-file and aggregate size
use `byte_size/1`. Invocation attributes named `kind`, `mode`, or any rename/delete
axis are forbidden unknown fields and return `:unknown_fields`; `FileChange` does
not add a `kind` field or claim to detect symlinks/submodules.

URI-bearing constructors require `%URI{}` values; parsing strings is outside them.
`RepositoryRef.repository_uri` is a canonical Ezagent `resource` URI of type
`git-repository`. `OperationContext.task_access_uri` is a canonical `resource` URI
of type `git-task-access`; its `caller_uri` and `grantee_uri` are canonical Ezagent
`entity` URIs. All four carry the same nonempty workspace axis. `ChangeRequest.url`
and a non-nil `Check.url` are absolute `http`/`https` `%URI{}` values with a
nonempty host and nil `userinfo`; `Check.url` may be nil. Provider web URLs are not
validated as Ezagent six-scheme URIs.

The exact ref subset is ASCII, 1..255 bytes, begins with an alphanumeric byte, and
otherwise permits only `A-Z`, `a-z`, `0-9`, `.`, `_`, `/`, and `-`. It rejects a
`refs/` prefix; leading/trailing `/` or `.`; `//`, `..`, `@{`; control/space; Git
forbidden `~^:?*[\\`; and any slash segment that is empty, `.`, `..`, dot-prefixed,
ends in `.lock`, or ends in `.`. Accepted refs are preserved exactly, never
normalized. This applies to `RepositoryRef.base_ref` and
`CreateChangeRequest.head_ref`.

V1 uses one shared `valid_sha1?/1`/constructor validation: exactly 40 ASCII hex
characters. `CommitSha.new/1` normalizes accepted uppercase to lowercase in its
frozen `%{value: String.t()}` shape. `ChangeRequest.new/1` validates its frozen raw
`head_sha: String.t()` through the same helper and stores the normalized lowercase
string. `CreateChangeRequest.expected_base_sha` must already be a constructed
`CommitSha`. SHA-256 requires a future contract revision and cannot silently pass.

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
agent/grantee URI, normalized repository binding, provider adapter binding,
`allowed_head_ref`, allowed actions, and non-secret idempotency inputs. The policy is
supplied only through the supported spawn/init
path, validates all URI/workspace relationships, defines idempotent same-policy
spawn and conflicting-policy collision behavior, and is removed on supervised
teardown. There is no lazy snapshot activation in this slice.

Task 5 attaches a minimal `Ezagent.ActionSet.GitTaskAccess` Lifecycle module so the
policy is held by the live Resource process in its supported Behavior slice. This
early module defines only validated `create/1` policy state: it declares no actions
and performs no registry lookup, adapter callback, or operation effect. Because the
standard Kind runtime reports a duplicate live URI as `{:already_registered, uri}`,
the Task 6 spawn wrapper resolves idempotency by reading and revalidating that live
slice: identical policy is success and any different policy is
`:conflicting_initialization`. Task 8 extends the same module with the frozen action
vocabulary; it does not create a second policy store.

Adapter selection comes exclusively from this stored policy. A request-side
`RepositoryRef`, where an action requires one, is only a normalized assertion that
must equal the stored binding; it never selects or redirects the provider.
`CreateChangeRequest.head_ref` is the requested change branch and must equal the
normalized stored-policy `allowed_head_ref` exactly before registry lookup.
`CreateChangeRequest.expected_base_sha` is the caller's concurrency assertion and is
required to be a valid `CommitSha` before registry lookup. The current remote base
SHA is dynamic provider state, not Resource policy: the selected adapter must compare
the assertion with the remote authoritative base while executing
`create_change_request/2` and return the frozen `:stale_base` error before creating
provider-side change-request state. The caller never supplies `base_ref`, provider
coordinates, or `OperationContext`.

## 6. ActionSet and actions

`Ezagent.ActionSet.GitTaskAccess` uses `Ezagent.Lifecycle`. Task 5 creates its minimal
policy-owning slice surface; Task 8 adds the actions below. It is the only production
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
Construction and collection-boundary failures use the closed
`Ezagent.DomainGit.ValidationError.t()` from §4.2; they are not members of, and must
not be converted into, this provider error union before adapter dispatch.

## 11. Boot, rollback, and restart

Application startup owns supervisor/registry startup followed by
Kind/CapabilityRegistry bindings. Registration is repeatable when the identical
binding already exists. If the Nth registration or a later child fails, startup
unregisters every binding created by that attempt and stops its children, leaving no
partial global ETS state. Tests cover child-start failure, Nth-binding failure,
repeat start, registry restart, and complete cleanup. Provider adapter declaration
follows the same all-or-nothing boot contract without executing adapter callbacks.
Before any child is started, `EzagentDomainGit.Application.start/2` calls
`ChangeLimits.current/0`; invalid explicit configuration returns
`{:error, :invalid_change_limits_config}` without raising and with zero children.

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
   `CommitSha`, `Check`, `Review`, `ValidationError`, `ChangeLimits`, and `Error`;
2. exact struct keys matching §4/§4.1, with no extra fields, including the absence
   of `CreateChangeRequest.base_ref`, `Review.author`, and any review `:pending`;
3. closed enums for `FileChange.operation`, repository visibility,
   change-request state, all eight check conclusions, and the four submitted review
   states; provider check strings must normalize to the closed union;
4. `Ezagent.DomainGit.Error.t()` contains exactly all 15 atom members and the
   `{:provider_request_failed, atom(), pos_integer()}` member in §10;
5. source and compiled struct inspection reject fields matching token, secret,
   credential, credential reference/path, Req/client, checkout/local path,
   provider payload/request/response, environment, callback, or Cap.
6. `Review.external_id` alone is the stable provider-event dedupe coordinate and
   `author_label` is structurally absent from authorization, identity matching,
   ownership, and dedupe code paths.
7. every value constructor has the exact `new/1` map boundary and deterministic
   closed validation errors in §4.2; rejected values are never returned;
8. `ChangeLimits.current/0` has the exact domain-owned defaults/config validation,
   and `FileChange.validate_many/1` alone enforces non-empty collection count,
   per-file bytes, and aggregate bytes without caller overrides.
9. config validation is non-raising and runs before application children;
   `validate_many/1` propagates `:invalid_change_limits_config`;
10. URI axes/web-URL distinctions, the exact preserved ref subset, shared lowercase
    SHA-1 normalization, and rejection of SHA-256 are enforced;
11. FileChange has no kind/mode/rename/delete axes, and capture-time
    symlink/submodule rejection is not falsely claimed by the value constructor.

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
6. create dispatch compares normalized `head_ref` to policy `allowed_head_ref` and
   validates the `expected_base_sha` shape before registry lookup. The adapter checks
   that assertion against the dynamic remote authoritative base and returns
   `:stale_base` before provider-side mutation; request input cannot select
   `base_ref`.
7. check projection covers every status/conclusion pair per §4.1 and never treats
   `:action_required` or `:other` as green.

## 14. Branching and landing

This tracked Task 0 documentation is intentionally stacked on Plan A PR #1423 in
`feat/git-domain-spine`. Do not begin production Task 1+ until #1423 lands and this
branch is rebased onto current
`origin/main`; then re-read current architecture gates and record any mainline drift.
Only the authorized lead flow may merge, deploy, or promote the branch.
