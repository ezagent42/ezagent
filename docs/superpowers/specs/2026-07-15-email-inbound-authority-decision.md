# Email Inbound Authority Decision

**Date:** 2026-07-15
**Status:** approved design
**PR:** #1412 (`fix/capability-auth-followups`)

## 1. Outcome

An inbound email may receive one ephemeral, receiver-bound `session.send`
capability only after one email-owned authority decision proves all of the
following at decision time:

1. the email projection is still verified;
2. its parent ExternalMirror binding still exists;
3. both durable records agree on binding id, session, adapter, target, and
   workspace;
4. the workspace also equals the workspace derived from the session URI;
5. the binding's `bound_by` value is an entity URI; and
6. the current message passes the email authentication and sender checks.

The resulting capability is issued through `Ezagent.Cap.issue/3`, is scoped to
exactly one session and action, and is bound to the synthetic email receiver.
No capability or synthetic Entity is persisted.

## 2. Trust model

Domain and plugin code loaded into the ezagent release is trusted. The generic
`{:rule, name, configurer}` authorization remains a trusted-code assertion:
the business module verifies the rule precondition before calling
`Ezagent.Cap.issue/3`; core enforces the capability's structural bound and
records accountable entity provenance.

This design does not claim to protect signing from arbitrary code executing in
the same BEAM. Such code can already reach signing configuration and signing
primitives. Supporting untrusted plugins would require a separately isolated
signer and first-class, verifiable rule evidence. That is a different security
phase and is not introduced by this email change.

## 3. Authority home

Create `Ezagent.Email.Inbound.Authority` as the only email-plugin home that may
issue inbound authority.

The module accepts the current inbox record and resolved binding metadata. It
freshly reads and joins the durable `InboundBinding` and `BindingRow` evidence,
revalidates the message, and only then constructs and issues the artifact.

Low-level operations remain private:

- synthetic receiver construction;
- concrete `session.send` capability construction;
- binding actor extraction;
- `Cap.issue/3` invocation.

Delete the public `Ezagent.Email.Inbound.Principal.mint/2` API. A static
invariant permits `Cap.issue/3` in the email plugin only inside the Authority
module and pins the removed public API surface.

## 4. Decision result

Authority decisions return an explicit tagged result:

```elixir
{:ok, %{session_uri: session_uri, principal_uri: principal_uri, caps: caps}}
{:reject, reason}
{:retry, reason}
```

`{:reject, reason}` means a successful durable read proved that the message is
not authorized: the binding is gone, unverified, mismatched, malformed, or the
message fails authentication. `Inbound` deletes the inbox item and returns a
skipped result.

`{:retry, reason}` means authorization could not be evaluated because an
infrastructure dependency failed, including Repo/query or signing failures.
`Inbound` retains the inbox item. Dispatch failures remain retryable under the
existing at-least-once contract.

The implementation must isolate database exceptions from durable-data
validation. It must never translate a Repo failure into a deterministic reject.

## 5. Revocation semantics

The successful fresh durable join is the authorization decision's
linearization point. An inbound operation whose decision completed before a
concurrent unbind may finish. A decision begun after unbind commits must reject.

The artifact is used for one dispatch and is not stored. This design does not
promise cancellation of an in-flight dispatch. Strong post-commit cancellation
would require a binding epoch/version checked at the Session boundary and is
outside this change.

## 6. Data and architecture constraints

- `users.caps_json` and Identity snapshots remain the physical capability
  stores for persistent entities.
- The synthetic email principal remains ephemeral and creates no third Entity
  or capability store.
- `Cap.issue/3` remains the only signed/provenance-bearing artifact constructor.
- The Email plugin owns email authentication and binding evidence; core does
  not depend on Email or ExternalMirror schemas.
- No rule registry, signer service, no-tail migration, signature-enforcement
  flip, or AgentRuntime work is added.

## 7. TDD acceptance

Tests must first fail against the current implementation and then prove:

1. `Principal.mint/2` is no longer exported;
2. no durable verified binding means no issued authority;
3. mismatched session, adapter, target, workspace, or actor fails closed;
4. reader failure is retryable and does not delete the inbox item;
5. confirmed removal or deterministic mismatch is rejected and deleted;
6. a valid binding succeeds through real dispatch with
   `require_signature: true`;
7. the issued artifact is receiver-bound and cannot authorize another session;
8. dispatch failure remains retryable; and
9. an invariant enforces one email issuance home.

The final branch must rerun the affected Email and Cap signing suites, complete
an independent review with no Critical or Important findings, update the return
record with immutable evidence, rebase on current `origin/main`, and obtain
green required PR-head checks without self-merging.
