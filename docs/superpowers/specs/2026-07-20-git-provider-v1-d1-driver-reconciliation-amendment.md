# Git Provider V1 D1 Driver Reconciliation Amendment

**Status:** approved on 2026-07-20

## Decision

D1 extends the provider-owned `Ezagent.ProviderConnection.Driver` contract with
`reconcile_callback/1`. This is a deliberately narrow amendment to the D0
callback freeze: it reconciles an already-persisted, stable callback correlation
after an ambiguous provider effect. It is not a plaintext retrieval API and does
not accept caller-selected provider code, credentials, or authority.

## Contract

`reconcile_callback/1` receives only server-owned, durable callback coordinates:
the stable correlation, persisted backend/attempt identity, and a private exchange
context rebuilt from backend-owned ciphertext. It returns the same normalized,
write-only callback result shape as `consume_callback/1`, an explicit confirmed
not-completed outcome, or a fail-closed ambiguity error.

Every registered driver implementation must export the callback. The registry
validates this at declaration time. Both in-process and remote-shaped fakes prove
same-correlation reconciliation and reject changed stable input.

## State machine

Before a provider effect, the callback operation is durable `prepared`. If a
terminal transition wins after that effect but before local result persistence,
recovery invokes `reconcile_callback/1` with the same correlation. A reconciled
result is journalled exactly once and then follows the existing
`cleanup_pending -> revoke -> finalized` path. A confirmed non-result can be
fenced safely. An ambiguous response leaves the connection closing and the
operation recoverable; it may never be treated as terminal.

Terminal completion requires provider revoke, credential revoke, old-pointer
cleanup, and every callback reconciliation/cleanup obligation to be complete.

## Tests

Deterministic barriers must cover provider effect followed by worker death before
local result persistence, then terminal/restart reconciliation. They prove one
provider correlation, no pointer installation after closing, exact result cleanup,
and no terminal state when reconciliation is ambiguous.
