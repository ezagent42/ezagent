# Git Provider V1 Plan D1 system-closure amendment plan

**Design:** `docs/superpowers/specs/2026-07-20-git-provider-v1-d1-system-closure-amendment.md`

**Base for remediation review:** `d7c35d1e3`

**Approved forward amendment:** A+ Driver result ownership plus A++ runtime
provenance closure, 2026-07-21. This
narrowly supersedes the D0/D0.1 Driver callback-result surface while preserving
the existing normalized `ProviderAuthorizationBackend` envelope, provider
neutrality, decentralized CapBAC, URI authority, the credential backend
retrieval boundary, and `Ezagent.ActionSet.GitTaskAccess` unchanged. It adds
only the operation-specific `CredentialBackend` refresh-use exchange specified
by the amendment; `ProviderAuthorizationBackend` remains unchanged.

**Execution rule:** TDD, one guarded Mix/BEAM process at a time, and no edits to
the preserved report/handoff files.

## Task 1 — schema and forward invariants

Write failing schema/migration tests, then add the four historical forward migrations from
the amendment. Update `Connection`, `AuthorizationAttempt`, and `Operation` with
pending/reservation/result/recovery/cleanup fields, closed constraints,
canonical constructors, immutable transition changesets, relational checks,
and redacted `Inspect`. Do not amend or squash this historical task/commit for
the later A++ ownership-stage schema; that work lands in the explicit supplement
below.

Gate:

- fresh migrate from zero and upgrade a non-empty current D1 schema containing
  active, pending, consuming, backend-committed, cleanup-pending, refreshing,
  and termination fixtures;
- no sentinel pending account/ref values;
- canonical/immutable and cross-workspace/absent-parent tests fail closed;
- every durable struct passes runtime secret-sentinel Inspect tests.

Commit: `feat(provider-connection): model pending connection lifecycle`

## Task 2 — aggregate birth, begin, reauthorize, and read

Write RED public Router/Store tests for missing initial connection, exact retry,
conflicting retry, terminal/begin race, reauthorization source/version/assurance,
and safe read view.

Implement a focused lifecycle module. Initial begin reserves/creates under lock,
calls the backend outside the transaction, and settles the attempt under a
second lock. Reauthorize uses its own purpose and never delegates to initial
begin. Read uses exact owner/workspace scope and an allowlist.

Gate: all seven registered actions have a real Store implementation; no handler
falls through to `orchestration_not_implemented` for protocol-valid input. The
public boundary separately proves begin/consume/refresh/read are reachable and
reauthorize/revoke/disconnect always return the closed assurance error.
Test-only verifier injection may exercise the latter three protocols;
production runtime configuration cannot open them.

Commit: `feat(provider-connection): close owner command lifecycle`

## Task 3 — callback subject and cold authority

Write RED tests where an operator starts initial authorization or
reauthorization with distinct owner-granted callback artifacts and where the
owner User is cold at ingress. Each attempt reservation/digest combines the
artifact identity with purpose, connection id, and connection generation; the
capability format itself is unchanged. Add the narrow
durable-current-authority verification path in core. Store only owner-bound
continuations; retain central Router/Kind verification as the authorization
decision.

Gate: wrong generation/target/grantee creates zero DB/backend/driver mutation;
cold valid initial and reauthorization callbacks reach owner dispatch and exact
retry remains single-use; an artifact/reservation cannot replay across attempt,
purpose, or connection generation. Final Task 3 acceptance is a joint gate with
Task 4: a completed exact callback retry must recover the same real
`authorization_ref`, `authorization_version`, and `provider_result_ref`, produce
one logical provider consume, and preserve the owner/cold-target/artifact
guarantees above.

Commit: `fix(provider-connection): bind callback authority to owner`

## Task 1 supplement — A++ ownership-stage schema

Land this as a forward supplement after the historical Tasks 1–3 and before
Task 4; do not rewrite, amend, or squash the original Task 1 commit. Migration
ownership is fixed: `20260720002000_close_provider_binding_cas.exs` owns the
generic `provider_result_ref`, while historical
`20260720004000_add_refresh_compensation_obligations.exs` owns only the two
cleanup-obligation statuses/errors, their coherence constraints, and due index.
Do not edit either migration.

Add
`apps/ezagent_core/priv/repo_pg/migrations/20260720005000_close_provider_result_ownership_stages.exs`
(or the next free timestamp after a read-only collision check), and update the
`Operation` schema/constructors/transitions for immutable
`expected_authorization_ref` and `expected_authorization_version`. Before
backfill, the migration runs read-only conflict queries and fails loudly on
unclassifiable partial rows. It safely classifies legacy rows, then enforces the
operation-class-specific `prepared` all-NULL XOR complete provider-owned shape.
`fenced` is allowed only as an all-NULL pre-effect terminal variant after
 reconciliation confirms no provider result; provider-owned or credential-owned
 `fenced` rows fail loudly. `backend_committed`, `connection_committed`,
 `finalized`, and `cleanup_pending` require complete provider and credential
 ownership. Backfill expected authorization
coordinates only from one provable bound record/reservation; ambiguous history
fails. Add expressible DB relationship checks and retain any temporal relation
as a locked application invariant plus concurrency test. Callback checks require
result ref equality and exactly
`result_authorization_version = expected_authorization_version + 1`; refresh
keeps result authorization columns NULL. Callback, refresh, discard, and
recovery load these frozen reservation coordinates rather than reconstructing
them from an advanced connection.

Gate:

- fresh migrate and non-empty upgrade include the new migration after the four
  historical D1 migrations;
- upgrade fixtures cover every ownership-stage legacy classification and reject
  every partial provider/credential tuple;
- schema and migration tests prove `050` is the sole owner of the added
  ownership-stage checks and expected-authorization fields, while `02000` and
  `04000` remain byte-identical;
- immutable/cross-bound expected-coordinate and concurrent connection-advance
  tests fail closed before an external effect.

Commit: `feat(provider-connection): close A++ ownership-stage schema`

## Task 4 — callback identity convergence and public receipt

**Contract and implementation files:**

- Modify `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/driver.ex`.
- Modify the callback path in
  `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/local_authorization_backend/exchange.ex`,
  `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/local_authorization_backend/reconciliation.ex`,
  `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/credential_replacement.ex`,
  `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/operation.ex`,
  and `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/store.ex`
  only where the staged ownership transition requires it.
- Update the concrete Driver implementations in
  `apps/ezagent_domain_provider_connection/test/support/fake_driver_alpha.ex`,
  `apps/ezagent_domain_provider_connection/test/support/fake_driver_beta.ex`,
  and `apps/ezagent_domain_provider_connection/test/support/task8_backends.ex`.
- Test in
  `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/registry_test.exs`,
  `apps/ezagent_domain_provider_connection/test/ezagent/provider_connection/local_authorization_backend_test.exs`,
  and
  `apps/ezagent_domain_provider_connection/test/integration/callback_recovery_test.exs`;
  re-run
  `apps/ezagent_domain_provider_connection/test/integration/callback_ingress_test.exs`
  and
  `apps/ezagent_domain_provider_connection/test/integration/provider_connection_cap_test.exs`
  for the Task 3 joint gate.
- Create
  `apps/ezagent_domain_provider_connection/test/architecture/driver_result_ownership_test.exs`
  as the structural A+ invariant gate shared by Tasks 4 and 6.

Write RED contract tests that reject a Driver missing
`reconcile_refresh/1`, `discard_callback_result/1`, or
`discard_refresh_result/1`, and that reject a generic
`reconcile_result/1`/`discard_result/1` tagged operation-kind API. Assert the
exact callback context for both `consume_callback/1` and
`reconcile_callback/1`, and the exact refresh context for both `refresh/1` and
`reconcile_refresh/1`: every required stable durable binding is present;
missing/extra keys fail before an effect; the function name fixes the operation
kind; claim tokens, mutable attempt/lease versions, lease deadlines, and
worker-local state are absent. Refresh additionally carries only the fresh
invocation-scoped `CredentialBackend.RefreshUse` as its non-durable field.

RED tests prove callback/discard/recovery authorization coordinates come from
the immutable operation reservation. Advancing the connection after reservation
must not alter those Driver inputs; an absent, ambiguous, or cross-bound
expected coordinate fails before any effect.

Assert that callback's private `exchange` value is a call-scoped,
non-serializable capability: it is the callback context's only non-durable
field, is recreated for callback reconciliation, and never appears in an
operation/attempt/backend public result, command digest, discard context,
recovery payload, Inspect output, log, telemetry, or receipt. Assert separately
that refresh/reconcile context has no callback `exchange` key and contains only
exact stable durable bindings plus the fresh `refresh_use` capability.
The refresh context is constructed only inside `CredentialRefreshExchange`
after it has verified the exact registered Driver declaration; the outer
coordinator never holds `RefreshUse` or invokes a Driver with it.

Require `consume_callback/1` and completed `reconcile_callback/1` to return the
same real stable opaque `provider_result_ref`, `authorization_ref`, and
`authorization_version`. Missing/extra result keys, a ref/version mismatch, or
a coordinator-derived/cross-bound provider reference fails closed. Prove the
reference is Driver-issued or Driver-authenticated and bound to the exact
provider/acquisition/pair, function-fixed operation kind, operation/correlation/
digest, connection and credential generations, callback attempt identity, and
native provider result.

Treat `authorization_ref` and `authorization_version` as
`ProviderAuthorizationBackend`/local connection coordinates, never
provider-native Driver state. RED tests require the backend normalized envelope
to remain authoritative: the Driver strictly echoes its ref and exactly
`expected_authorization_version + 1`; reconciliation returns that same
established successor. Reject Driver-authored refs, reused/skipped generations,
and any mismatch before journaling or CAS.
Validate callback `provider_metadata` against the exact registered Driver's
closed declaration and then discard it before returning to orchestration. It is
non-durable and recovery/CAS-independent, exactly like refresh metadata.

Write RED orchestration tests for first-bind normalized metadata, no placeholder
refs, and a barrier at each named boundary: Driver effect before pair-private
handoff sealing; handoff sealing before provider ownership journal; provider
ownership journal before `CredentialBackend.store/1` or `replace/1` external
effect; CredentialBackend effect before credential ownership journal;
credential ownership journal before connection CAS; and the losing CAS itself.
Also cover duplicate real-account CAS race, reauth identity drift, recovery,
independent provider-discard and credential-revoke failures, and receipt status
from Connection. Exact discard retry after confirmed discard returns `:ok` and
cannot affect another result. Assert `Driver.revoke/1` is never called for a
single losing callback result.

Implement the complete A+ Driver port in this task so every declaration remains
executable: keep the existing callbacks, add function-fixed
`reconcile_refresh/1`, `discard_callback_result/1`, and
`discard_refresh_result/1`, close all context/result/error shapes, and retain
`revoke/1` solely for whole-connection revocation. Do not add a generic
tagged operation-kind callback or a `ProviderResultBackend`.

After the Driver effect, allow the paired authorization backend to seal and
persist the pair-private write-only handoff; do not call that packaging a
CredentialBackend effect. Commit the provider ownership journal with normalized
connection-relevant fields, authorization ref/version, real provider ref, and
opaque handoff ref. Then call `CredentialBackend.store/1` for initial bind or
`replace/1` for reauthorization, and commit the separate credential ownership
journal with its exact credential ref/version. Only then run CAS.

Implement these as two named operation changesets without inventing a new
status: provider ownership atomically converts the all-NULL pre-effect
`prepared` variant into the complete provider-owned `prepared` variant;
credential ownership accepts only that complete variant and advances it to
`backend_committed`. Add negative tests for every partial provider-owned field
combination and for attempting credential ownership from the all-NULL variant.

Atomically commit identity, authorization/credential pointers, versions,
permissions, expiry, backend ids, and connection/operation states. Route unique
losers and stale reauth results to two durable cleanup obligations without
replacing the winner. In the same loser transaction set connection
`failed/account_conflict`, cancel the attempt, and make exact retry return
`account_conflict` without recreating work. Finalization requires both provider
discard and credential revoke to be confirmed, or an obligation to have been
durably `not_required` before its external result existed.

Gate: selector sees only the winning active binding. Winner retry returns the
same `%{connection_id, status: "active", version}` and no internal state; loser
retry returns stable `account_conflict` and creates no new cleanup work. The
Task 3 joint gate proves cold owner dispatch, purpose/generation binding, one
logical provider consume, the same authorization ref/version and
`provider_result_ref` on exact retry, and both cleanup obligations surviving
independent failures. The new architecture gate proves all registered Drivers
implement the eight function-fixed callbacks and that no generic tagged result
port or result-level use of `revoke/1` exists.

Commit: `feat(provider-connection): atomically bind provider identity`

## Task 5 — recovery poison fairness

Write RED deterministic-clock tests with a permanently failing oldest row,
later successful rows in the same phase, and work in later phases. Assert no
zero-delay loop.

Implement durable attempts/backoff/due queries, cursor advancement for every
inspected row, bounded scheduling to earliest due work, and observable closed
errors. D1 retries permanent failures forever at capped backoff and never
quarantines or silently skips them.

Commit: `fix(provider-connection): schedule fair recovery retries`

## Task 6 — refresh losing-result compensation

**Consumes:** the complete A+ Driver port and concrete Driver implementations
landed in Task 4. Task 6 must not introduce another result abstraction or alter
the callback contract.

Refresh has no callback `exchange` capability and no new public or internal
refresh callback on `ProviderAuthorizationBackend` or
`LocalAuthorizationBackend`. It uses the operation-specific opaque
`CredentialBackend.RefreshUse` exchange; it does not reuse `GitTaskAccess` and
does not add credential retrieval/plaintext APIs. The Driver owns provider
semantics, while CredentialBackend owns current-credential use, fence
revalidation, and sealing the replacement into the pair-private
`{:write_only_handoff, handoff_ref}`. This is why Task 6 does not modify the
local authorization backend files.

The only high-level refresh exchange API is the new
`CredentialRefreshExchange` facade. The outer coordinator passes it the
exact registered Driver declaration, the closed durable command, and only the
function-fixed selection `:refresh` or `:reconcile_refresh`; it never receives
`RefreshUse`, supplies a Driver implementation, submits a closure, or directly
calls either CredentialBackend exchange primitive. The facade reuses
`RuntimeBindings.resolve/2` as the single runtime-binding source of truth,
freezes the jointly validated pair, Driver declaration/fingerprint, and
CredentialBackend implementation/proxy, begins the backend exchange, builds the
exact context internally, invokes the exact registered Driver callback, and
returns only the closed sealed result. Extend that resolver only if the closed
refresh command needs an additional invariant; the facade must not copy its
registry or application-environment validation.

**Implementation files:**

- Create
  `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/credential_refresh_exchange.ex`
  as the sole high-level facade and unique production call site for the two
  private CredentialBackend exchange primitives. Its scoped Driver-facing
  consume function performs a short atomic claim against an independent
  invocation-scope authority before delegating in the caller-owned invocation
  path to the exact selected backend primitive.
- Modify `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/refresh.ex`.
- Modify
  `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/operation.ex`
  only through named staged ownership/cleanup changesets.
- Modify
  `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/recovery.ex`
  to reconcile a missing refresh response and retry the two cleanup obligations
  independently.
- Modify
  `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/credential_backend.ex`
  to define `CredentialBackend.RefreshUse` there and add exactly
  `begin_refresh_exchange/1` and `consume_refresh_exchange/1`, alongside the
  existing exact-result revoke contract. The consume `/1` input is one closed
  private exchange request containing the opaque use and Driver-owned provider
  operation; mark both primitives facade-private in contract and docs; do not
  add retrieval or plaintext APIs.
- Reuse, and only if necessary extend,
  `apps/ezagent_domain_provider_connection/lib/ezagent/provider_connection/runtime_bindings.ex`
  so its `resolve` remains the one place that validates the backend pair, exact
  Driver declaration/fingerprint, and CredentialBackend implementation/proxy.
  The frozen binding is never accepted as caller-supplied runtime authority.
  `BackendPair` and `BackendPairRegistry` stay stable data declaration/lookup
  infrastructure and must not gain modules, processes, functions, provider
  closures, credential implementations, or invocation authority. Do not modify
  them for Task 6 unless an independently demonstrated declaration invariant
  requires it; conformance-only work requires no production change. Modify
  application supervision only if the ephemeral scope-authority implementation
  requires a supervisor, never a central broker or work queue.
- Update
  `apps/ezagent_domain_provider_connection/test/integration/refresh_fence_test.exs`,
  `apps/ezagent_domain_provider_connection/test/integration/recovery_test.exs`,
  and the three Task 4 test Drivers.
- Add in-process and remote-shaped/proxy CredentialBackend conformance tests for
  the same begin/consume protocol, both fence checks, redaction,
  non-serialization, and restart reconstruction.
- Re-run
  `apps/ezagent_domain_provider_connection/test/architecture/driver_result_ownership_test.exs`
  as the invariant gate for the refresh implementation, not only for callback
  declarations.

Before implementation, run repository-wide inventory (not a test-directory-only
scan) with `rg` for every `@behaviour CredentialBackend` and fully qualified
equivalent, plus dynamic backend registration/proxy construction. Update every
match. The current known minimum is both implementations in
`test/support/fake_backend_pairs.ex`,
`test/support/d1_idempotent_credential_backend.ex`, the inline implementation in
`test/integration/callback_recovery_test.exs`, both implementations in
`test/architecture/secret_boundary_test.exs`, and the Task 8 implementation in
`test/support/task8_backends.ex`; the inventory must also catch implementations
in other apps and every dynamically selected or remote-shaped proxy. Record the
final inventory in the Task 6 report and fail the gate if any implementation is
missing the closed protocol.

Add RED exact-context tests for `refresh/1` and `reconcile_refresh/1`: identical
stable durable keys plus only the invocation-scoped `refresh_use`, no callback
`exchange`, no mutable claim/lease input, and
missing/extra/mismatched context keys rejected before a provider effect. Reject
missing/extra result keys. Require both success paths to return the same real
`provider_result_ref` and the same sealed pair-private handoff.

Add RED port tests for the exact durable begin command binding owner/workspace,
provider/host/pair, function-fixed operation/correlation/digest, connection/
authorization/credential generations, current credential ref, exact registered
Driver implementation, declaration fingerprint, and backend pair. Prove the
facade owns an unforgeable one-shot invocation scope held by a separate,
short-lived process per scope (or equivalent protected authority), calls backend
begin, constructs the context, and applies only the function-fixed callback on
the registered implementation in the caller-owned invocation process. Driver
invokes the facade's scoped
`consume_refresh_exchange/1` with the capability and its private provider
operation. Before delegating to the backend primitive, the facade makes only a
short atomic `validate-and-claim` call to the scope authority for the live
scope, Driver/fingerprint/pair, all durable bindings, and one-shot state. After
that call returns, the facade invokes the backend primitive in the current
invocation path. The backend independently validates the captured binding
before credential injection, then revalidates before use and again before
sealing and returns only real provider ref, safe fields, and sealed handoff.
Neither current nor replacement plaintext is observable by coordinator code.
The authority performs only short atomic open/validate-and-claim/invalidate and
owner monitoring; it never calls or waits for a Driver, backend external effect,
provider closure, or caller. Scope exit, invocation-owner process death, or
authority death immediately invalidates unused capability; completion consumes
it. A crash
after claim is reconciled through a new scope and never reuses the claimed one.
Recovery asks the facade to create that fresh scope from the same frozen
operation coordinates and a fresh `RuntimeBindings.resolve/2` result.
Plain/coordinator closures, direct consume, wrong Driver/fingerprint/pair, and
missing, extra, replayed, persisted, serialized, inspected, or cross-operation
capabilities all fail before credential injection or provider effect.

Add deterministic topology RED tests: Driver callback to scoped consume must
complete without a self-call or deadlock; the scope authority must never invoke
or await Driver/backend effects/provider closures; owner death must invalidate
the scope; concurrent and replayed consumes must have exactly one winner; and a
scope-authority crash must recover only through fresh-scope reconciliation.
Reject a long-lived centralized domain-truth process or serialized work queue.
The scope is ephemeral authority only; durable truth remains in the operation,
issuer, and backend, consistent with decentralized fire-and-forget capability
ownership.

Do not implement provenance by asserting a fictitious BEAM module-caller
identity. The exact registered Driver is the trusted callback unit; provenance
comes from facade-owned selection/invocation and private unforgeable scope. A
unique-call AST gate is defense in depth only. Remote-shaped/proxy tests require
the remote endpoint to authenticate and validate the same binding and one-shot
state, not merely trust the local proxy.

Add deterministic RED barriers after: Driver provider effect but before its
sealed handoff is returnable; sealed handoff return but before provider
ownership journal; provider ownership journal but before
`CredentialBackend.replace/1`; CredentialBackend effect but before credential
ownership journal; credential ownership journal but before pointer CAS; and a
losing pointer CAS. For each barrier, restart recovery and prove convergence
without repeating a completed provider effect. Test a provider-discard failure
with successful credential revoke, then the inverse, and prove neither erases
the other obligation. Test exact discard/revoke retries and require both
confirmations before `finalized` or terminal cleanup release.

Call `CredentialRefreshExchange` with the registered declaration, durable
command, and function-fixed callback selection. Inside the facade, resolve and
freeze the binding through `RuntimeBindings.resolve/2`, call
`CredentialBackend.begin_refresh_exchange/1`, construct the Driver context with
the fresh `RefreshUse`, and apply the exact registered Driver callback in the
caller-owned invocation process. Permit that Driver to invoke only the facade's
scoped consume; it atomically claims the separate scope authority, returns from
that short call, and only then delegates to the exact selected backend primitive
outside the authority process. Immediately journal the returned real
`provider_result_ref`, permissions digest, safe expiry, and already sealed
pair-private handoff in the provider ownership journal. Validate refresh
`provider_metadata` against the exact registered declaration's closed schema,
then discard it; do not journal it or make recovery/CAS depend on it. If the
response was lost, reconstruct a fresh
capability and call `Driver.reconcile_refresh/1` with the same exact durable
context inside a fresh facade scope; only `{:ok, :not_completed}` permits a
subsequent fresh provider effect through another facade invocation. Pass the
handoff to `CredentialBackend.replace/1`, then commit the separate credential
ownership journal with its exact opaque credential ref/version, and only then
fence the connection-pointer CAS.

Reuse Task 4's named ownership changesets: refresh provider ownership keeps the
complete provider-owned operation at `prepared`; refresh credential ownership
alone advances it to `backend_committed`. Recovery distinguishes the all-NULL
and complete provider-owned `prepared` variants by their closed field set, never
by a worker-local flag.

Every loser enters `cleanup_pending`. Build
`discard_refresh_result/1` context only from locked durable coordinates and use
a stable discard idempotency key. Retry provider discard and exact credential
revoke independently in recovery; preserve each confirmed status across failure
of the other. `Driver.revoke/1` remains whole-connection-only and is not called
by this result cleanup path.

Gate: source scans and executable conformance reject generic result APIs, a
`ProviderResultBackend`, coordinator-synthesized refs, arbitrary Driver result
terms/errors, durable refresh metadata, reuse of `GitTaskAccess`, a callable
struct masquerading as the refresh exchange, credential plaintext crossing the
private Driver/backend frame, and whole-connection revoke used as result
discard. In-process and remote-shaped/proxy implementations pass the same
conformance. All six crash windows recover to either the winning active pointer
or fully confirmed loser cleanup with no unowned provider or credential result.
The gate additionally rejects any production call to backend begin/consume
outside `CredentialRefreshExchange`, outer-coordinator possession of
`RefreshUse`, caller-supplied Driver implementations or scope nonce/authority,
naked backend closures, consume outside the live exact scope, and a remote proxy
that omits any runtime binding validation. It also rejects duplicated
registry/environment resolution in the facade, runtime authority in
`BackendPair`/`BackendPairRegistry`, Driver/backend/provider work inside the
scope authority, any synchronous self-call topology, and any centralized
domain-truth queue. Compile the facade, runtime binding, all inventoried
implementations/proxies, and their conformance suite with warnings as errors.

Commit: `fix(provider-connection): compensate stale refresh results`

## Task 7 — assurance fail-closed boundary (Decision B)

Add `action` to `Assurance`, define the backend-neutral trusted-session verifier
port, keep production hard-wired to the unavailable validator with no runtime
opening, and test
action/replay/expiry/owner/version binding. Document and gate the deferred
`reauthorize`, `revoke`, and `disconnect` public flows; do not claim them as
production-complete D1 actions. No OneAuth/WebAuthn dependency is added.

Commit: `fix(provider-connection): keep assurance actions fail closed`

## Task 8 — structural gates and finalizer closure

Extend authority/secret AST gates to grouped aliases and all durable structs.
Make HandoffFinalizer fail closed on unexpected lifecycle and add DB/runtime
coherence tests. Gate only the five new amendment migrations against
`IF NOT EXISTS`; previously committed migrations remain byte-immutable, and any
historical correction uses another forward migration.

Include
`20260720005000_close_provider_result_ownership_stages.exs` (or its explicitly
recorded next-free timestamp) in the exact file/count gate. Its DB gate covers
every callback/refresh `prepared` XOR variant, every credential-owned stage,
legacy conflict-before-backfill behavior, immutable expected authorization
coordinates, and their relational checks. Architecture gates also prove
`RefreshUse` is defined in `credential_backend.ex`, cannot be persisted or
inspected, and both in-process and remote-shaped implementations conform.

Commit: `test(provider-connection): close structural boundary gaps`

## Task 9 — verification and review

Run, serialized under the 5G cgroup guard:

1. focused RED/GREEN files per task;
2. full provider-connection suite;
3. Git, Identity, Core cap, Workspace, Session callback, architecture, migration,
   doc/URI/invariant/lifecycle gates;
4. warnings-as-errors compile, fresh DB migration, and a non-empty upgrade that
   asserts exactly the five amendment migrations including
   `20260720005000_close_provider_result_ownership_stages.exs` (or its recorded
   collision-safe successor), while checksumming immutable `02000`/`04000`;
5. `mix precommit`, classifying only independently reproduced failures;
6. `git diff --check`, exact status, and log from `d7c35d1e3`.

Then run two independent read-only reviews: one against this amendment and one
whole-branch X-level review from the original D1 base. Any finding is fixed and
re-reviewed before completion.
