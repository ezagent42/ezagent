# Git Provider V1-A decisions and downstream interfaces

**Date:** 2026-07-16

**Status:** evidence complete; architecture/security review requested

**Scope:** Close Plan A only. These decisions authorize later plans to describe
the approved W29 transport; they do not implement production credentials,
OAuth, Git domain resources, workspaces, or UI.

## 1. GO/NO-GO matrix

| Concern | Decision | Evidence | Consequence |
|---|---|---|---|
| Encrypted secret backend | NO-GO | Inventory found only plaintext application settings and credential files; `20260530000000_app_settings.exs` explicitly records no at-rest encryption | Self-service credential persistence/import is blocked pending a separately approved secret backend |
| SSH parser | NO-GO | No OpenSSH private-key import/parser dependency or module exists | Private-key import is blocked; accepted-format claims remain future design, not V1-A behavior |
| SSH broker isolation | NO-GO | `os_process_secret_isolation_probe_test.exs` proves known-path 0600 and `/proc/<pid>/environ` exposure; broker options select D | Generic SSH clone/fetch/push is blocked; no temporary key workaround |
| GitHub API transport | GO — local contract prototype | `github_api_commit_transport_test.exs`: 5 tests, 0 failures; pure plan/local fake only | Plan B may define the neutral change-request contract; Plans C/D may later implement public anonymous checkout plus GitHub Git Data API writes |

The GO is intentionally narrow. It proves the W29 strategy is internally
specifiable without an agent credential. It does not prove GitHub API behavior,
OAuth lifecycle, private checkout, or canary readiness.

## 2. Selected W29 route

```text
governed public repository + base ref
  -> anonymous platform checkout before sidecar
  -> isolated task worktree
  -> agent emits bounded regular-file changes
  -> GitTaskAccess dispatch verifies signed receiver-bound Cap
  -> GitHub plugin resolves the governed user's binding internally
  -> Git Data blobs/tree/commit/ref + pull request
  -> normalized change request/check/review facts
```

Honesty label: **GitHub-specific and public-repository-only; not the final
provider-neutral, private-repository, or SSH transport.** Plan B has no #1360
dependency. #1360 belongs to the separate Hello↔Kanban cross-session live-mount
and authorization line.

## 3. Approved downstream types

Plan B may introduce these provider-neutral modules. Field types below are the
minimum contract; adding provider payload maps or credential fields is not
allowed.

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

`FileChange` is normalized before adapter dispatch. V1-A permits UTF-8
regular-file upserts only; deletes, symlinks, submodules, traversal, absolute paths, `.git`
paths, and configured size/count overflows fail before provider effects.

## 4. Adapter contract

The provider-neutral callback is resolved only after Router/Behavior dispatch
authorizes the exact `GitTaskAccess` Resource. `OperationContext` is constructed
inside that handler from dispatch identity plus the stored task policy; it is
never decoded from agent/adapter payload. Credential owner and provider binding
are reloaded from `task_access_uri`, not accepted as context coordinates. The adapter receives no token, secret
reference, credential path, environment, callback closure, or arbitrary map.

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

Merge is absent. Generic SSH clone/fetch/push callbacks are absent while SSH is
NO-GO. Public checkout belongs to the provisioner and must reject
`visibility: :private` until an authenticated checkout mechanism is approved.

## 5. Secret-use boundary

The domain has no secret API. The only public product entry is Router dispatch
to the `GitTaskAccess` Behavior. That handler verifies the signed,
receiver-bound artifact with `Cap.verify_for/2`, reloads the immutable task
policy, constructs `OperationContext`, and only then resolves/calls the adapter.

The GitHub plugin owns its binding-specific token reference. Credential lookup
and Req execution are private functions inside the GitHub adapter module
(`defp`, not a remotely callable credential-use module or callback). They accept
the already-loaded authoritative task policy and a typed request plan, not a
caller-selected URI. Consequently there is no public `execute/2`, `execute/3`,
or secret-use function that can be called with a forged `task_access_uri`.

Plan B must add structural gates that reject adapter registry resolution or
adapter callback calls outside the domain-owned `GitTaskAccess` Behavior. Plan D
must add a gate that rejects token lookup/Req credential attachment outside the
GitHub adapter. Unauthorized-dispatch tests must prove zero adapter, HTTP,
secret-store, and filesystem effects. The adapter interface remains dependency
injection behind the authorized handler, never a second authorization facade.

The plugin-private implementation derives the credential owner and binding from
the loaded policy; it never accepts either coordinate from an agent or adapter request.
`GithubRequestPlan` cannot contain headers or tokens. `GithubResult` is a closed
union of normalized repository/change-request/check/review facts. There is no
`get_token`, `with_token`, `get_private_key`, generic signer, generic HTTP proxy,
or credential-bearing subprocess interface. The plugin derives the binding from
governed task state and verifies co-tenant ownership before secret use.

The deterministic attempt key is not sent as a claim that GitHub makes POST
operations idempotent. Plan D must own a durable attempt ledger, look up the
deterministic head ref/change request, reconcile partial success, and normalize
ref/PR conflicts before retrying.

Production implementation of this boundary remains Plan D and is blocked on the
encrypted secret backend decision. Plan A's local fake uses only the sentinel
and makes no network call.

## 6. Error union

> **Amended 2026-07-31** by
> `2026-07-31-git-provider-error-union-unreadable-response-amendment.md`, which
> adds `:provider_response_unrecognized`. The union below is left as written —
> it is the record of what was decided on 2026-07-16, not a live listing.

```elixir
@type t ::
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

Errors may carry an allowlisted provider request ID in a typed wrapper later;
they never carry raw response maps, headers, tokens, keys, paths, descriptors,
or environments.

## 7. Planning eligibility

- Plan B: eligible to write after review approves this interface.
- Plan C: may cover public anonymous checkout/worktree provisioning only after B.
- Plan D: may cover GitHub OAuth/Req/Git Data API only after an encrypted token
  backend is approved; the pure prototype does not remove that prerequisite.
- Plan E: may cover provider connection and Kanban projection after D. SSH
  identity import/generation UI is excluded while its three prerequisites remain
  NO-GO.
