# Return: Git Provider Plan D0 Backend Reuse Gate

## Outcome

D0 is closed. It freezes test-only replacement interfaces, proves identical
in-process and remote-shaped semantics, records reproducible external evidence,
and selects local V1 for both backends. Remote OneAuth/OneSystem replacement is
deferred. This return authorizes only reviewed D1/D2 planning against the frozen
interfaces; it does not authorize production implementation, deployment, or
merge.

## Frozen interfaces

- `ProviderAuthorizationBackend`: begin, callback consume, reauthenticate,
  cancel.
- `CredentialBackend`: store, replace, status, `lease_for_operation`,
  `consume_lease`, revoke.
- Closed errors and `OperationContext` remain backend-independent.
- `GitTaskAccess` remains the only Git-operation authorization entry.

## Two-fake proof

The same conformance suite passes against an in-process fake and a JSON
remote-shaped fake. The remote-shaped boundary rejects credential wrappers,
functions, PIDs, and references; authenticates sealed lease material before
constructing a local wrapper; and covers transport failures and ambiguous
outcomes. Structural tests keep executable D0 modules test-only and keep Req
ownership and sensitive unwrap at the provider-adapter boundary.

## OneAuth/OneSystem evidence and decision

The ledger at
`docs/superpowers/notes/2026-07-17-git-provider-v1-d0-external-evidence.md`
contains OA-01..OA-05 and OS-01..OS-04 with version, date, reproduction command,
observed output, safety, and operations fields.

OneAuth source/API and operational ownership were unavailable, so remote
authorization fails the all-criteria gate. A social-login token remains product
authentication, not repository consent. OneSystem revision `7ca946aa6` proves a
working SOPS/Age primitive, but does not prove version/revoke or operation-bound
leases and exposes a generic decrypt endpoint returning plaintext. Therefore
both choices are local V1; remote replacement is deferred.

## Security invariants

- No second CapBAC, task-policy, connection, or Git authority.
- No generic plaintext retrieval or agent/config/workspace secret flow.
- Only provider adapters unwrap and use short-lived operation-bound credentials.
- Plan A provider adapters retain private Req ownership.
- Plan B, Plan C, task workspace/worktrees, and Kanban contracts are unchanged.

## Commands and observed outputs

- D0 contract plus architecture: `18 tests, 0 failures`.
- `ezagent_domain_git` full application: `113 tests, 0 failures`.
- existing core Git adapter boundary: `11 tests, 0 failures`.
- OneSystem `go test ./pkg/secret`: `ok github.com/h2os/onesystem/pkg/secret (cached)`.
- OneAuth local repository search: empty on 2026-07-17.
- Documentation and diff gates are recorded in the final handback after this
  file is scanned.

## Files and commits

- Contract/types and shared conformance: `07f4b7005`.
- Authorization fake proof: `d58621007`.
- Credential lease proof: `54d1d386c`.
- Remote-shaped proof: `cfb091fbe`.
- Structural security gates: `d6021550b`.
- External evidence, backend decision, and this return are grouped in the final
  D0 documentation commit.

## D1 authorization

D1 may plan a local authorization backend implementing the frozen callbacks,
durable connection state, PKCE, single-consume callback, governed-host binding,
reauthentication, audit, and closed failures. A OneAuth runtime dependency is
not authorized without complete OA evidence and explicit lead approval.

## D2 blockers

D2 may plan a local encrypted credential backend. Remote OneSystem use remains
blocked until atomic replace/version/revoke, short-lived lease issue/consume,
provider-adapter-only unwrap, removal of generic decrypt, operational ownership,
and lead authorization are all proven at one immutable version.

## Explicit non-deliverables

There is no production backend, OAuth implementation, token persistence,
provider HTTP, UI, migration, deployment, merge, Plan C change, Kanban change,
or OneAuth/OneSystem repository modification in D0.

## Residual risks

- Local V1 encryption/key rotation and operational runbooks remain D2 design
  work, not D0 implementation.
- OneAuth and OneSystem may evolve after the recorded revisions/search date;
  replacement requires rerunning the complete evidence gate.
- The D0 remote-shaped fake proves contract substitutability, not production
  service availability or security.
