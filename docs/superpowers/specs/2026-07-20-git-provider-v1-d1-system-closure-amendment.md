# Git Provider V1 Plan D1 system-closure amendment

**Status:** approved for implementation; assurance Decision B approved 2026-07-20;
Driver result-ownership amendment A+ and runtime-provenance closure A++ approved
2026-07-21

**Amends:** the 2026-07-18 D1 connection-substrate design and the 2026-07-19/20 fence and reconciliation amendments

**Narrow forward amendment:** this document supersedes the earlier statement
that D1 does not change the D0/D0.1 callback surface. The approved A+ change
extends the provider-owned Driver result surface and requires Driver callback
results to strictly echo the existing normalized `ProviderAuthorizationBackend`
coordinates needed for durable ownership. It does not add management actions
or change public capability semantics. It narrowly extends `CredentialBackend`
with the operation-specific refresh-use exchange described in section 8; it
adds no credential retrieval API and does not change
`ProviderAuthorizationBackend`.

**Does not change:** provider neutrality, decentralized capability ownership,
URI/receiver authority, or the `Ezagent.ActionSet.GitTaskAccess` policy

## 1. Why this amendment exists

The D1 implementation started from an already-created, already-bound
`ProviderConnection`. That skipped three domain protocols:

1. aggregate birth before the provider account is known;
2. the single point where callback output becomes immutable connection identity;
3. durable ownership of every external result before a worker may lose its fence.

Fixtures hid the first gap with `pending:*` account ids and `pending` backend
references. Direct `Store.execute/3` tests hid missing public actions and the
production assurance bridge. Operation-status assertions hid the wrong public
receipt. The result was locally green code without a complete system contract.

This amendment closes those protocols. It does not introduce a central grant
table. Capability issuers still sign artifacts, grantees/processes carry them,
and the target User Kind remains the central dispatch verifier.

## 2. Aggregate birth and pending identity

`begin_authorization` is the only initial creation command. Its arguments name a
caller-chosen UUID `connection_id` plus owner-scoped provider, host, acquisition,
requested execution-identity class, permission, redirect, correlation, and an
owner-bound callback continuation artifact.

The first transaction locks the `connection_id` key and either:

- inserts a `pending_authorization` connection and a `beginning` attempt
  reservation; or
- reconciles an exact retry of the same reservation.

A conflicting correlation/digest fails closed. Existing active, degraded,
expired, revoking, revoked, disconnecting, or disconnected rows cannot enter the
initial-begin path.

Before first binding these fields are `NULL`, never sentinel strings:

- `external_account_id`;
- `display_login`;
- final canonical `execution_identity`;
- `authorization_backend_ref`;
- `credential_backend_ref`;
- `permission_digest` and provider expiry.

The pending row stores only owner/workspace, provider/normalized host,
acquisition method, and the requested execution-identity class. Pending rows are
not selectable by Git or adapter consumers.

The backend call occurs after the reservation transaction. A second transaction
locks connection then attempt, persists the returned authorization coordinates,
and advances `beginning -> pending`. Exact begin retries recover the same
reservation and backend correlation.

## 3. Initial callback is the identity convergence point

Callback settlement has two separately named durable stages. They must not be
collapsed into one "result journal."

**Provider ownership journal.** After the Driver provider effect, the paired
authorization backend first seals the Driver's private credential material and
returns its pair-private write-only handoff. That sealing is backend-private
packaging, not a `CredentialBackend` external effect and not credential-result
ownership. The operation then journals:

- the real `provider_result_ref`;
- external account id, display login, and canonical execution identity;
- granted permission digest and safe expiry;
- authorization ref/version;
- the pair-private handoff ref needed to resume the later credential effect.

No provider credential material is stored in the operation. Once this journal
commits, provider-result ownership is durable even if the worker loses its
claim or response. This is a named idempotent transition on a `prepared`
operation: it keeps status `prepared` while atomically filling the provider
result, normalized provider fields, authorization coordinates, and handoff ref.
The all-NULL pre-effect shape and the complete provider-owned shape are the only
valid `prepared` variants; partial ownership fields fail closed.

**Credential ownership journal.** The paired `CredentialBackend.store/1`
(initial bind) or `CredentialBackend.replace/1` (reauthorization) consumes the
write-only handoff as an external effect. Only after that effect returns does a
second operation transition journal the exact credential ref/version. No
credential material is stored in that journal. This named transition advances
the complete provider-owned `prepared` operation to `backend_committed`; it
cannot be called on the all-NULL pre-effect variant.

Only after both ownership journals exist may the connection CAS run. The CAS
locks connection, attempt, and operation in that order. For an initial bind it
atomically commits all normalized identity, backend binding, credential
pointer, versions, `status = active`, and the operation transition to
`connection_committed`. A retry returns the same public receipt.

The active uniqueness tuple remains:

```text
(workspace_uri, owner_uri, provider_id, governed_host,
 external_account_id, execution_identity)
```

It applies only when `external_account_id IS NOT NULL` and the row is not
terminal. Concurrent pending authorizations may exist because the provider
account is not yet known. At CAS only one identical real binding wins. A loser
retains no active pointer. In the same transaction its connection becomes the
non-selectable terminal state `failed` with `last_error_code = account_conflict`,
its attempt becomes `cancelled`, and its operation becomes `cleanup_pending`.
Both its provider result and credential result are durably compensated. Exact
callback retry observes those terminal coordinates and returns the stable closed
error `account_conflict` without repeating CAS or cleanup creation. Cleanup may
finish after the aggregate is terminal; it never makes the connection selectable.

Reauthorization may update authorization/credential versions, permissions,
expiry, and display login, but must match the immutable external account and
canonical execution identity. Identity drift is an account conflict and cannot
replace the old pointer.

## 4. Command matrix and linearization

Every command locks/reloads its aggregate before an external effect.

| Command | Allowed source |
|---|---|
| initial begin | missing connection, or exact retry of its open reservation |
| reauthorize | `active`, `degraded`, `expired` with exact version and assurance |
| initial callback | `pending_authorization`, matching initial attempt generation |
| reauthorization callback | `active`, `degraded`, `expired`, matching reauth generation |
| read | every existing state, exact owner/workspace |
| refresh | `refresh_required`, or an expired `refreshing` lease |
| revoke/disconnect | the approved D1 termination sources with assurance |

`reauthorize` receives permission, redirect, correlation, requested identity,
and an owner-bound callback artifact in addition to connection/version and
assurance. It reserves a new attempt under the connection lock. Terminal or
refresh transitions racing it can have only one linearization winner.

`read_connection` returns a safe allowlisted view. It never returns authorization
or credential refs, backend implementation ids, attempt/operation ids, claim or
lease tokens, artifacts, ciphertext, or internal operation states.

Public callback receipts always use the connection source of truth:

```elixir
%{connection_id: id, status: connection.status, version: connection.connection_version}
```

## 5. Callback capability subject and cold targets

Management command authority and callback continuation authority are distinct:

- the management action cap may be held by the owner or a delegated operator;
- the stored `consume_callback` artifact is always granted to the owner because
  ingress dispatches as the owner to the owner User Kind.

Begin validates callback artifact target, workspace, action, and
`grantee_uri == owner`; it must not bind the artifact to `ctx.caller`.

Artifact prevalidation supports a cold target without starting or regenerating
it. The framework helper verifies against the durable current target authority
generation/public key. A live Kind may use the existing path. A retired
generation, wrong target, wrong receiver, or wrong grantee fails. The helper
does not issue, store, dispatch, start a Kind, or authorize handler entry.
Router dispatch still performs the only action authorization and may cold-start
the owner normally.

## 6. Assurance boundary — Decision B

`Assurance` binds action, owner, workspace, grantee, connection id/version,
reauth reference/version, issued/expiry times, key id, and signature. It is not
reusable across `reauthorize`, `revoke`, and `disconnect`.

The provider-connection domain exposes a backend-neutral
`SessionAssuranceVerifier` port. The default remains fail-closed. A production
issuer/validator in the follow-up phase may mint an assurance only after
verifying trusted AAL2/AAL3 session evidence; a caller-supplied
`%{aal: :aal2}` is not evidence.

The repository currently has no trusted AAL2 authority. The approved choice for
this phase is:

- **B — deferred:** keep reauthorize/revoke/disconnect fail-closed in D1 and
  explicitly move production assurance and those public flows to a follow-up.

OneAuth remains a candidate for that follow-up, but it is a remote dependency
and requires separate lead approval. D1 may implement and test the closed port,
action binding, and fail-closed behavior; it must not claim production
reachability for the three assurance-gated actions.

All seven actions remain registered and have closed domain handlers. Production
reachability is intentionally split: begin, consume callback, refresh, and read
are reachable; reauthorize, revoke, and disconnect always fail closed at the
public User boundary. Production is wired directly to the unavailable validator
and runtime application configuration cannot open it. Test-only builds may
inject a verifier to exercise those three domain protocols.

Magic-link or ordinary login must not be relabeled as AAL2.

## 7. Recovery fairness and durable retry

Operations gain `recovery_attempts`, `next_recovery_at`, and a closed
`last_recovery_error_code`.

- every inspected row advances the in-pass cursor, success or failure;
- failure atomically increments attempts and schedules bounded exponential
  backoff with deterministic test clocks;
- recovery queries only due rows;
- a poison row cannot block later rows or later phases;
- an empty pass sleeps until the earliest due row (bounded by configuration),
  never self-schedules at zero milliseconds;
- the existing 50-row batch and 500-row pass yield remain;
- repeated permanent errors stay visible and retry forever with a capped
  backoff; D1 has no quarantine or skip state.

## 8. Callback and refresh result ownership and compensation

### 8.1 Approved A+ Driver surface

The Driver keeps eight function-fixed operations. The function name fixes the
operation kind; no context or result carries a caller-selected operation tag.
The exact callbacks are:

```elixir
begin_authorization(context)
consume_callback(context)
reconcile_callback(context)
refresh(context)
reconcile_refresh(context)
discard_callback_result(context)
discard_refresh_result(context)
revoke(context)
```

`consume_callback/1` and `reconcile_callback/1` receive the same exact callback
context:

```elixir
%{
  owner_uri: canonical_owner_uri,
  workspace_uri: canonical_workspace_uri,
  provider_id: nonempty_binary,
  acquisition_method: nonempty_binary,
  governed_host: normalized_host,
  backend_pair_id: nonempty_binary,
  operation_id: uuid,
  connection_id: uuid,
  attempt_ref: uuid,
  authorization_ref: nonempty_binary,
  expected_connection_version: non_neg_integer,
  expected_authorization_version: non_neg_integer,
  expected_credential_version: non_neg_integer,
  correlation_id: nonempty_binary,
  command_digest: nonempty_binary,
  callback_envelope_digest: nonempty_binary,
  exchange: private_call_capability
}
```

Refresh credential access is mediated by the narrow
`CredentialRefreshExchange` facade, one ephemeral invocation-scope authority,
and an operation-specific opaque `CredentialBackend.RefreshUse`. The backend
port adds exactly these private facade primitives:

```elixir
begin_refresh_exchange(closed_refresh_command)
consume_refresh_exchange(closed_private_exchange_request)
```

The consume request has exactly two fields:

```elixir
%{
  refresh_use: CredentialBackend.RefreshUse.t(),
  provider_exchange:
    (private_current_credential_frame ->
       {:ok,
        %{
          provider_result_ref: nonempty_binary,
          replacement_credential: private_replacement_credential_frame,
          granted_permissions_digest: nonempty_binary,
          expires_at: DateTime.t() | nil,
          provider_metadata: driver_declared_closed_map
        }}
       | {:error, closed_driver_error})
}
```

The Driver creates `provider_exchange`; it is call-scoped and subject to the
same non-persistence/non-serialization rules as `RefreshUse`. The credential
backend validates the closed Driver result, removes and seals
`replacement_credential`, and returns the same shape with
`credential_material: {:write_only_handoff, handoff_ref}` in its place. Neither
backend primitive is a coordinator API: only `CredentialRefreshExchange` may
begin an exchange or arrange its consumption.

The outer Refresh coordinator has one high-level entry: it passes
`CredentialRefreshExchange` the exact registered Driver declaration, one closed
durable refresh command, and the function-fixed selection `:refresh` or
`:reconcile_refresh`. It cannot pass a Driver closure or an arbitrary
implementation module. The facade reuses `RuntimeBindings.resolve/2` (extending
that resolver only if the closed refresh command needs an additional invariant)
as the single runtime-binding source of truth. That resolver jointly validates
the stable backend-pair declaration, exact registered Driver declaration and
fingerprint, and configured CredentialBackend implementation/proxy. The facade
must not repeat registry or application-environment resolution. It freezes the
resolved binding, starts the backend exchange and an ephemeral scope authority,
constructs the exact Driver context with the returned opaque use, and applies
only the selected callback on the exact registered implementation. The outer
coordinator never observes `RefreshUse`, `provider_exchange`, a private frame,
or credential plaintext and cannot submit a naked closure to a backend.

`BackendPair` and `BackendPairRegistry` remain stable data declaration and
lookup infrastructure. They carry no module, process, function, provider
closure, credential implementation, or invocation authority. Task 6 does not
change either merely to implement refresh; runtime resolution belongs in
`RuntimeBindings`, and conformance-only coverage requires no production change.

`begin_refresh_exchange/1` accepts a closed private facade request combining the
locked durable command—bound to the exact owner, workspace, provider, governed
host and backend pair; function-fixed refresh operation, operation id,
correlation id and command digest; connection, authorization and credential
generations; and current credential ref—with the facade-verified concrete
registered Driver and declaration fingerprint. The runtime binding is not
persisted in or accepted as part of the caller's durable command. It returns an
invocation-scoped opaque `RefreshUse` for that one facade invocation. This is
not a callable struct. During the facade-owned invocation only, the selected
`Driver.refresh/1` or `Driver.reconcile_refresh/1` may call the facade's scoped
`consume_refresh_exchange/1` with one closed private request containing that use
and its Driver-owned provider exchange operation.

The facade executes the external flow in the caller-owned invocation process;
it is not a long-lived broker or serialized work queue. One separate,
short-lived process per invocation scope (or an equivalent protected authority)
holds only the unforgeable scope state and monitors the invocation owner. It
performs short atomic `open`, `validate-and-claim`, and `invalidate` operations.
It never invokes or waits for a Driver, CredentialBackend external effect,
provider closure, or caller. In particular, no authority `handle_call` may
apply a Driver or execute the Driver-owned provider operation.

When the Driver calls scoped `consume_refresh_exchange/1`, the facade first
makes only the short `validate-and-claim` call to that independent authority.
The authority atomically verifies the live one-shot scope, exact resolved
Driver/declaration fingerprint/backend pair, operation/correlation/digest, and
connection/authorization/credential generations captured by `RefreshUse`, and
then returns. Only after that return does the facade call the exact selected
CredentialBackend's private consume primitive in the current invocation path;
the backend performs fence reload, private credential/provider use, second
fence reload, and replacement sealing in its own invocation process or
authenticated protected endpoint. Thus the Driver-to-consume path cannot call
back synchronously into the process that is waiting for that Driver. Completion,
invocation-owner process death, or authority death invalidates the scope
immediately.
Concurrent consume and replay have exactly one winner; all other attempts fail
before credential injection or provider effect. Plain/coordinator closures,
wrong Driver/declaration fingerprint/backend pair, and cross-operation use fail
the same way.

This binding does not pretend that BEAM exposes trustworthy module-caller
identity: the concrete registered Driver is the trusted callback unit, and the
facade proves provenance by owning selection, invocation, and unforgeable scope,
not by inspecting a caller module. An AST unique-call gate is defense in depth,
not the runtime authority. The invocation scope is ephemeral authority, not
durable domain truth or a central grant table/queue; durable truth remains with
the operation, issuer, and selected backend. After restart/recovery the facade
reloads the same durable coordinates, re-resolves the binding through
`RuntimeBindings`, and creates a fresh invocation scope and capability. A crash
after claim is indeterminate and must use fresh-scope reconciliation; it never
reuses or reopens the claimed scope. `RefreshUse` and every frame reachable
through it are
non-serializable, non-persistable, redacted by `Inspect`, and absent from
digests, logs, telemetry, receipts, operations, recovery payloads, and discard
contexts. An in-process backend implements the closed protocol locally. A
remote-shaped backend uses a local opaque proxy plus authenticated protected
exchange framing; the remote endpoint independently validates the same scope,
Driver, declaration-fingerprint, pair, durable-binding, and one-shot values
against its authoritative fence without serializing `RefreshUse` or exposing a
credential frame to coordinator code. Neither form is
`Ezagent.ActionSet.GitTaskAccess`, and no task-access capability is reused or
attenuated for credential access. `ProviderAuthorizationBackend` is unchanged.

`refresh/1` and `reconcile_refresh/1` receive the same exact refresh context:

```elixir
%{
  owner_uri: canonical_owner_uri,
  workspace_uri: canonical_workspace_uri,
  provider_id: nonempty_binary,
  acquisition_method: nonempty_binary,
  governed_host: normalized_host,
  backend_pair_id: nonempty_binary,
  operation_id: uuid,
  connection_id: uuid,
  authorization_ref: nonempty_binary,
  expected_connection_version: non_neg_integer,
  expected_authorization_version: non_neg_integer,
  expected_credential_version: non_neg_integer,
  correlation_id: nonempty_binary,
  command_digest: nonempty_binary,
  refresh_use: CredentialBackend.RefreshUse.t()
}
```

Every context field other than callback `exchange` and refresh `refresh_use` is
loaded from the locked durable operation, connection, attempt, authorization
record, or frozen declaration. Missing or extra keys, a non-canonical value,
or a disagreement with those rows is `correlation_conflict` before a provider
effect. Claim tokens, mutable attempt/lease versions, lease deadlines, process
ids, and worker-local state are not Driver inputs.

For callback consume/reconcile, `exchange` is the sole callback exception to the
durable-input rule: it is a non-serializable, invocation-scoped capability
constructed by the paired authorization side after loading its private state.
It exists only for the duration of one Driver call. It and every private frame
reachable through it must never be persisted, hashed into a durable command,
logged, returned in a receipt, placed in a discard context, or stored in durable
recovery state or payload. Recovery reconstructs a fresh capability at the final
`reconcile_callback/1` call boundary after reloading the same durable binding;
it never recovers a stored closure or private frame.

Refresh has no callback `exchange` key. Its sole non-durable field is the
operation-specific `refresh_use` capability created and inserted into the
context inside `CredentialRefreshExchange`; the outer coordinator never builds
that context and never holds the capability. The Driver exercises that
capability and returns an already sealed pair-private write-only handoff to the
facade. D1 adds no refresh callback to
`ProviderAuthorizationBackend` and does not route refresh through
`LocalAuthorizationBackend` callback internals.

`consume_callback/1` and a completed `reconcile_callback/1` return the same
closed normalized callback-result shape with exactly these fields:

```elixir
%{
  provider_result_ref: nonempty_binary,
  external_account_id: nonempty_binary,
  display_login: nonempty_binary,
  execution_identity: %{
    kind: :connected_user,
    external_account_id: nonempty_binary
  },
  authorization_ref: nonempty_binary,
  authorization_version: non_neg_integer,
  credential_material: write_only_private_exchange_value,
  granted_permissions_digest: nonempty_binary,
  expires_at: DateTime.t() | nil,
  provider_metadata: driver_declared_closed_map
}
```

`reconcile_callback/1` may instead return `{:ok, :not_completed}`. Exact
consume/reconcile retries return the same logical result and the same
`authorization_ref`, `authorization_version`, and `provider_result_ref`; they
do not repeat the provider effect.

`authorization_ref` and `authorization_version` are local
`ProviderAuthorizationBackend` connection coordinates, not provider-native
identity and never Driver source of truth. The backend's normalized envelope is
authoritative. A Driver result may only strictly echo the envelope ref and the
next local generation: the ref equals the context/backend ref and the returned
version is exactly `expected_authorization_version + 1`. The backend rejects a
missing echo, a different ref, a skipped/reused generation, or any attempt by a
Driver to choose these coordinates. `ProviderAuthorizationBackend` adds the
validated coordinates to its closed normalized result while converting
`credential_material` to the existing
`{:write_only_handoff, handoff_ref}` pair-private value. The private material
never crosses into coordinator code. Exact callback reconciliation returns the
same already-established next generation; it does not increment it again.

`refresh/1` and a completed `reconcile_refresh/1` likewise return exactly:

```elixir
%{
  provider_result_ref: nonempty_binary,
  credential_material: {:write_only_handoff, handoff_ref},
  granted_permissions_digest: nonempty_binary,
  expires_at: DateTime.t() | nil,
  provider_metadata: driver_declared_closed_map
}
```

`reconcile_refresh/1` may instead return `{:ok, :not_completed}`.

Both refresh success paths return the same handoff ref. Raw refresh credential
material never crosses into coordinator code.

Refresh `provider_metadata` is validated against the Driver's declared closed
schema and then discarded; it is diagnostic response data, not durable
recovery or connection state. The provider ownership journal persists only the
real `provider_result_ref`, sealed handoff ref, granted-permissions digest, and
safe expiry (plus the operation's existing durable bindings). Recovery and CAS
must not depend on `provider_metadata`, and D1 adds no metadata column.

Callback `provider_metadata` follows the same rule: the paired authorization
side validates it against the exact registered Driver declaration and then
discards it before returning the normalized result to orchestration. It is
non-durable diagnostic data, does not participate in callback recovery or CAS,
and adds no operation, attempt, connection, or backend-record column.

The reference is issued by the provider or is an authenticated opaque handle
created by the Driver over the provider-native result identity. It is stable
for the exact operation, independently usable by recovery, and cannot be
invented, derived, hashed, or synthesized by the coordinator. Its binding
covers the declared provider id, acquisition method, backend-pair id,
owner/workspace, governed host, function-fixed operation kind and operation id,
correlation id, canonical command digest, connection id and generation,
callback attempt identity when applicable, expected authorization/credential
generations, and provider-native result identity. A binding mismatch fails
closed without affecting another provider result.

`discard_callback_result/1` and `discard_refresh_result/1` receive closed maps
built only from locked durable rows. The callback context contains exactly:

```elixir
%{
  owner_uri: canonical_owner_uri,
  workspace_uri: canonical_workspace_uri,
  provider_id: nonempty_binary,
  acquisition_method: nonempty_binary,
  governed_host: normalized_host,
  backend_pair_id: nonempty_binary,
  operation_id: uuid,
  connection_id: uuid,
  expected_connection_version: non_neg_integer,
  attempt_ref: uuid,
  authorization_ref: nonempty_binary,
  expected_authorization_version: non_neg_integer,
  correlation_id: nonempty_binary,
  command_digest: nonempty_binary,
  expected_credential_version: non_neg_integer,
  provider_result_ref: nonempty_binary,
  discard_idempotency_key: nonempty_binary
}
```

The refresh discard context contains exactly:

```elixir
%{
  owner_uri: canonical_owner_uri,
  workspace_uri: canonical_workspace_uri,
  provider_id: nonempty_binary,
  acquisition_method: nonempty_binary,
  governed_host: normalized_host,
  backend_pair_id: nonempty_binary,
  operation_id: uuid,
  connection_id: uuid,
  expected_connection_version: non_neg_integer,
  authorization_ref: nonempty_binary,
  expected_authorization_version: non_neg_integer,
  correlation_id: nonempty_binary,
  command_digest: nonempty_binary,
  expected_credential_version: non_neg_integer,
  provider_result_ref: nonempty_binary,
  discard_idempotency_key: nonempty_binary
}
```

Missing/extra keys and any durable-binding mismatch fail closed before discard.
The function-fixed callback name fixes callback versus refresh; callers
cannot supply a generic operation-kind tag. Claim tokens, mutable attempt/lease
versions, lease deadlines, `exchange`, and private frames are absent. No
discard context contains a raw callback, authorization code, PKCE material,
provider token, or credential material.

Discard is idempotent: `:ok` includes an exact retry after the exact result was
already discarded. Consume, reconcile, refresh, and discard return only their
declared success variants or the closed Driver errors
`backend_unavailable`, `provider_denied`, `provider_protocol_failed`,
and `correlation_conflict`. An outcome that cannot be authoritatively
reconciled is `provider_protocol_failed`; it is not silently retried as
`:not_completed`. Unknown provider or transport failures are normalized to one
of those codes before they cross the Driver boundary. No arbitrary `term()`
result or provider payload crosses the port.

`revoke/1` remains whole-connection provider revocation. It must not be used as
a substitute for discarding one losing callback or refresh result.

### 8.2 Durable ownership protocol

Callback and refresh use the same implementable order:

1. The function-fixed Driver call performs or reconciles the provider effect
   through callback's invocation-scoped private `exchange` capability or, for
   refresh, inside a `CredentialRefreshExchange` invocation whose internally
   constructed context contains the invocation-scoped
   `CredentialBackend.RefreshUse`. Each refresh use/seal step revalidates its
   durable fence; the outer coordinator observes neither capability.
2. For callback, the paired authorization side seals returned private
   credential material and persists a pair-private write-only handoff before
   returning. For refresh, the Driver result already contains the handoff sealed
   through `consume_refresh_exchange/1`. Neither path is
   `CredentialBackend.store/1` or `replace/1`, and neither claims the new
   credential-result ownership.
3. The operation commits the **provider ownership journal** containing the real
   `provider_result_ref`, connection-relevant normalized fields, authorization
   ref/version where applicable, and opaque handoff ref. No provider credential
   material is stored. This named idempotent transition fills the complete
   provider-owned variant while status remains `prepared`.
4. `CredentialBackend.store/1` or `CredentialBackend.replace/1` performs the
   credential-backend external effect using that handoff and the stable
   operation correlation.
5. The operation commits the **credential ownership journal** containing the
   exact credential ref/version. No credential material is stored. This named
   transition advances the provider-owned operation to `backend_committed`.
6. Only now may the connection pointer CAS run.

A crash after the Driver effect but before provider ownership journal is
resolved by the corresponding exact reconcile callback. A committed provider
ownership journal forbids repeating the Driver effect and resumes from the
durable handoff. A crash after the CredentialBackend effect but before
credential ownership journal is resolved by that backend's existing exact
correlation contract. The two journals are distinct state transitions even if
one transaction happens to write other non-ownership bookkeeping.
For refresh, invocation-owner process or scope-authority death invalidates its
scope immediately: death before claim has no provider effect, while death during
or after an indeterminate claimed consume is resolved only by a fresh
facade-scoped `reconcile_refresh/1` invocation over the same frozen durable
coordinates and freshly resolved runtime binding. The outer coordinator never
recovers, reopens, or reuses an old use, scope, or closure.

A CAS/fence loser records two independent durable obligations:

1. discard the exact provider result through the function-fixed Driver
   callback;
2. revoke the exact credential backend result through `CredentialBackend`.

Recovery retries each obligation independently. An operation cannot finalize
and cannot release terminal cleanup gating until both obligations are either
`confirmed` or were durably classified `not_required` before any corresponding
external result existed. A transient failure of one obligation never erases or
blocks durable ownership of the other.

For refresh specifically, `Driver.refresh/1` must therefore return, and
`reconcile_refresh/1` must recover, the stable opaque provider-result coordinate
for the exact correlation. No branch may drop raw provider output merely
because a post-effect lease check failed.

### 8.3 Alternatives not selected

A generic `reconcile_result/1` or `discard_result/1` carrying a caller-supplied
`operation_kind` discriminator is rejected. It creates invalid callback/refresh
field combinations, couples distinct protocols behind a tag, and weakens the
closed contract. The eight Driver function names are the operation-kind sum
type.

A separate `ProviderResultBackend` or compensator behaviour is also rejected.
It would split ownership of a provider effect away from the Driver that created
it, introduce a second source of truth and another crash window, and add a new
concept without a second independent consumer.

The A+ surface is the smallest structural change that leaves provider ownership
with the provider Driver and makes exact compensation durable.

## 9. Validation, secrecy, and relational invariants

Application constructors validate canonical owner/workspace URIs and their
relationship, closed provider/acquisition ids, normalized governed host,
canonical account and execution identity, closed status/error, and immutable
bound fields. Updates use named transition changesets; arbitrary changesets may
not alter immutable identity.

Forward migrations add relational guarantees from attempt/operation/event to a
real connection and enforce matching workspace where PostgreSQL can express it.
Where a composite foreign key is impractical, the locked application invariant
and its concurrency tests are mandatory.

`Inspect` redacts callback artifacts, claim/lease tokens, handoff/result/prior
credential refs, provider-result refs, backend refs, refresh lease tokens,
ciphertext/nonces, and authorization refs. Runtime sentinel tests cover every
durable struct, not only the private backend record.

Migration DDL is fail-loud. New migrations do not use `IF NOT EXISTS`, and down
steps only reverse objects owned by that migration. Handoff finalization rejects
unknown lifecycle states; DB checks relate lifecycle, ciphertext, handoff ref,
and shredded timestamp.

## 10. Forward-only migration sequence

Previously committed migrations remain immutable. Add:

1. `20260720001000_reserve_pending_provider_connections.exs` — nullable pending
   identity/refs, requested identity, attempt purpose/reservation fields, and
   one-open-attempt constraint;
2. `20260720002000_close_provider_binding_cas.exs` — normalized callback result,
   the generic `provider_result_ref` coordinate, final-binding checks, active
   uniqueness rebuild, and relational constraints;
3. `20260720003000_add_provider_recovery_schedule.exs` — retry schedule and due
   index;
4. `20260720004000_add_refresh_compensation_obligations.exs` — two cleanup
   obligation statuses/errors plus their coherence constraints and due index,
   built around the generic `provider_result_ref` already added by `02000`; its
   historical filename remains unchanged and is not rewritten;
5. `20260720005000_close_provider_result_ownership_stages.exs` — closes the
   staged ownership shapes after first checking for conflicting rows: a
   callback/refresh operation at `prepared` is exactly all ownership fields
   NULL XOR a complete provider-owned tuple. `fenced` is legal only as the
   all-NULL pre-effect terminal variant produced after reconciliation confirms
   that no provider result exists; it may never carry provider or credential
   ownership. `backend_committed`, `connection_committed`, `finalized`, and
   `cleanup_pending` require the complete provider-owned tuple plus a complete
   credential ref/version tuple. It also adds immutable
   `expected_authorization_ref` and `expected_authorization_version` operation
   coordinates: Driver/discard/recovery contexts load these frozen reservation
   values and never reconstruct them from a subsequently changed connection.
   For a complete callback provider tuple, DB checks require
   `result_authorization_ref = expected_authorization_ref` and
   `result_authorization_version = expected_authorization_version + 1`;
   refresh does not write result authorization coordinates.
   It uses the next migration number if `20260720005000` is already occupied,
   and never edits `02000` or `04000`;
6. no assurance persistence migration in this phase; production assurance is
   deferred by Decision B.

For the new ownership checks, the common provider tuple is
`provider_result_ref`, `handoff_ref`, and `result_permission_digest`; callback
also requires `result_external_account_id`, `result_display_login`,
`result_execution_identity`, `result_authorization_ref`, and
`result_authorization_version`. Refresh requires those callback-only result
columns to remain NULL. `result_expires_at` is the one explicitly optional safe
field in either complete tuple and is not used as its presence marker.
Credential ownership is exactly non-NULL `result_ref` plus
`result_credential_version`. The all-NULL `prepared` alternative has every
common and operation-specific provider field, including `result_expires_at`,
NULL and has no credential ownership; the provider-owned alternative has the
complete class-specific tuple and no credential ownership. No other
combination is legal.

Each migration upgrades non-empty D1 data in an explicit
expand/backfill/validate sequence:

- attempt purpose is first nullable; existing open attempts on
  `pending_authorization` connections become `initial_bind`, while open attempts
  on every other state are cancelled and marked `legacy`; already consumed or
  terminal attempts are marked `legacy`;
- reservation/request fields remain nullable for `legacy` attempts and are
  required by a conditional check only for new `initial_bind`/`reauthorize`
  attempts;
- normalized callback-result fields remain nullable until an operation reaches
  the corresponding new committed state;
- existing operations receive `recovery_attempts = 0`; recoverable obligations
  receive `next_recovery_at = migration_time`, terminal rows receive `NULL`;
- every pre-A+ callback/refresh cleanup row sets provider cleanup to
  `not_required`: a generic coordinate backfilled by `02000` is not evidence of
  an actionable Driver-issued result ref. A durable credential result sets
  credential cleanup to `pending`; other legacy rows use `not_required` as
  appropriate;
- before adding the ownership-stage checks, `20260720005000` runs read-only
  conflict queries and fails loudly if a row cannot be safely classified. Safe
  legacy rows are explicitly classified/backfilled as all-NULL pre-effect,
  complete provider-owned, or complete credential-owned; no partial tuple is
  guessed and no synthetic provider/credential reference is created;
- the same migration backfills expected authorization coordinates only from the
  uniquely bound authorization record/attempt or the connection value proven
  current at operation reservation. Ambiguous or contradictory history fails
  the conflict check. New callback/refresh operation rows require both
  coordinates, keep them immutable, and enforce their
  connection/authorization-record relationship with DB checks/FKs where
  expressible and a locked application check plus concurrency test where
  PostgreSQL cannot express the temporal relation. Unrelated operation classes
  are not widened by this check;
- constraints and indexes are added only after backfill and validation.

Upgrade tests seed active, pending, consuming, backend-committed,
cleanup-pending, refreshing, and termination rows on the pre-amendment schema,
then assert their exact post-migration mapping.

## 11. Acceptance

Tests must prove initial creation without sentinel values, all begin crash
windows, callback identity CAS, duplicate real-account race, reauth identity
drift, terminal/begin race, all seven registered handlers, the explicit four
reachable/three production-fail-closed split, cold owner callback, delegated
operator begin and delegated operator reauthorize with separate owner-bound,
continuation artifacts. Each attempt reservation/digest binds its artifact
identity to purpose, connection id, and connection generation, and rejects
cross-attempt/purpose/generation replay. The capability itself gains no new
purpose or connection-version axis. Tests also cover action-bound assurance,
poison-row fairness/backoff, every refresh lease-loss window, public receipt
semantics, canonical/immutable validation, relational mismatch rejection, and
secret-free Inspect/log/error/telemetry.

The Task 3/4 joint gate additionally proves that callback consume and reconcile
return the same authorization ref/version and real `provider_result_ref`, an
exact completed retry performs one logical provider consume, and every callback
CAS loser retains independent provider-discard and credential-revoke
obligations until both confirm. Callback and refresh tests place crash barriers
after the Driver effect, pair-private handoff sealing, provider ownership
journal, CredentialBackend effect, credential ownership journal, and pointer
CAS; recovery must converge from every barrier. Contract gates reject missing
or extra callback/refresh context/result fields, persistence or recovery of the
private `exchange` or `RefreshUse` capability, a Driver missing any of the eight
function-fixed callbacks, any generic tagged result API, any
coordinator-derived provider reference, a Driver-authored authorization
coordinate, non-successor local authorization generation, durable refresh
metadata, and use of whole-connection `revoke/1` as result discard. In-process
and remote-shaped credential backends pass the same refresh-use conformance
suite, including fence loss at both use and seal and fresh capability
reconstruction after restart. A deterministic non-reentrancy gate proves that
Driver callback to scoped consume completes without self-call or deadlock, the
scope authority never calls or waits for a Driver/backend effect/provider
closure, owner death invalidates before use, concurrent/replayed consumes have
one winner, and authority crash recovery uses fresh-scope reconciliation.

All Mix/BEAM verification runs serialized inside the approved 5G cgroup guard.
