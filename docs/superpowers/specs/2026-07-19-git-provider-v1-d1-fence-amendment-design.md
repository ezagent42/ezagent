# Git Provider V1 Plan D1 Fence Amendment

## Status

Approved direction A after Sol's independent review of the staged Task 7
implementation. This amendment closes the lease/effect ownership gap before
any further production implementation.

## X problem

The original Task 7 implementation conflated three different identities:

1. the stable logical credential operation identified by the D0.1 correlation
   id and canonical bound-input digest;
2. the mutable local execution lease identified by claim token and attempt
   version; and
3. the worker which is entitled to adopt an external result after the worker
   may have lost its lease.

That conflation makes a lease renewal change the D0.1 command input, and lets a
stale worker validate its result against the *new* current fence. The result
can then be committed under the wrong execution owner. This is an ownership
protocol defect, not merely a missing conditional test.

## Invariants

### Prepared-operation claim recovery

Prepared recovery is bounded by the attempt claim, not by the operation row
alone. A live claim (`now < claim_until`) returns `callback_in_progress`. At
`now >= claim_until`, recovery locks connection, then attempt, then operation
and atomically renews the attempt token/version and the operation fence. The
renewed operation reuses the same correlation, handoff reference, and stable
digest. No recovery path creates a second logical operation or calls the
credential backend with changed D0.1 input.

### Stable logical command

The credential backend command contains only immutable logical scope:

- operation class and stable correlation id;
- owner/workspace, connection id and connection version;
- backend pair, provider, governed host, acquisition method;
- execution identity, authorization reference, and the canonical permission
  and callback input digests;
- the opaque handoff reference and write-only credential material.

It MUST NOT contain claim token, attempt version, lease deadline, or any other
mutable execution fence. The backend stores and compares the canonical digest
for `{backend_pair_id, operation_class, correlation_id}` exactly as required by
D0.1. A retry after response loss therefore has byte-equivalent logical input.

### Launch fence

Immediately before the external credential effect, the local store captures an
immutable private launch fence containing operation id, connection version,
attempt version, and claim token. The fence is not sent as logical backend
input.

When the result returns, the store locks connection, attempt, and operation in
that order and compares the captured launch fence with the current durable
fence. Only an exact match may transition `prepared -> backend_committed`.
If the fence differs, the result is recorded as `cleanup_pending` with the
exact stable correlation, result reference, and credential version. The stale
worker cannot overwrite or adopt the current lease. If another worker already
committed the same exact result, reconciliation may return that committed
receipt; any conflicting result is fail-closed.

### Connection linearization

Connection transitions and callback claims share the connection row lock and
generation fence. The first transaction to lock and reserve the connection
linearizes the decision:

- a terminal/closing transition which wins first prevents callback effect;
- a callback claim which wins first reserves the current generation, and a
  later terminal transition records closing/cleanup work rather than claiming
  that the already-authorized effect never existed;
- every provider/backend call rechecks the captured generation before its
  effect, and every returned result is handled by the launch-fence rule above.

This defines “zero mutation” relative to the durable linearization point and
prevents a terminal transition from racing an already-authorized callback as
if both had won.

The concrete shared interface is the existing `connection_version`: callback
claim records the expected version on the attempt/operation while holding
`FOR UPDATE`; `Transition` acquires the same connection lock first, rejects a
stale expected version, and either observes the active claim or increments the
version and creates its own durable obligation. The lock order is
connection -> attempt -> operation for callback recovery and connection ->
operation for connection transitions.

### Authority binding

Execution identity is bound at authorization begin and persisted in the
authorization backend record and its authenticated associated data. The begin
subject, callback/row AAD, stable operation digest, attempt, operation, and
connection must all agree on execution identity. Drift at any phase fails
closed before a provider or credential effect.

### Receipts and lookup

The public callback receipt contains only the declared connection id, status,
and connection version. Credential refs and versions remain internal durable
receipts for Task 8 cleanup/finalization. Every operation lookup includes the
full D0 key: `backend_pair_id`, `operation_class`, and `correlation_id`.
The `backend_committed` fast path performs the same full stable-scope and
digest verification as the prepared path.

The canonical stable digest includes authorization ref, backend pair, owner,
workspace, connection id/version, provider, governed host, acquisition method,
requested-permission digest, redirect id, execution identity, attempt ref, and
callback correlation. Handoff AAD authenticates the same scope plus the stable
handoff reference; mutable claim token/version are excluded.

## Task 7 / Task 8 boundary

Task 7 ends at `backend_committed` or `cleanup_pending`. It does not perform
connection pointer CAS, handoff shredding, attempt consumption, revoke, or
finalization. Task 8 owns cleanup of a stale result and all pointer/finalizer
obligations. Task 8 must implement the shared connection linearization rule
for terminal transitions and pointer CAS.

## Test contract

The focused suite must use a credential backend test double that stores the
canonical input digest and rejects same-correlation/different-input retries.
It must cover:

- live-lease rejection and expiry-boundary recovery with a deterministic clock;
- atomic renewal of both attempt and operation fences under the required lock
  order;
- lease renewal with byte-equivalent stable command input;
- a real response-loss barrier that blocks the credential response, terminates
  the worker, advances past claim expiry, and proves one logical external
  effect plus stale-result `cleanup_pending`;
- exact-result reconciliation versus conflicting-result rejection;
- committed-result scope drift and execution-identity drift;
- terminal transition versus callback claim using a deterministic barrier;
- public callback receipts containing no credential ref/version;
- full operation-key lookup behavior.

All commands remain serialized under the existing 1 GB/no-swap systemd scope.
