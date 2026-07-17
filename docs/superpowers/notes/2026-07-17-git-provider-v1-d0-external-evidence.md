# Git Provider V1 D0 External Evidence Ledger

Evidence was collected on 2026-07-17 (Asia/Taipei). A `pass` proves only the
named criterion. `unavailable` is a closed result and selects local V1; it is
not permission to infer a remote contract. Public standards establish general
protocol semantics only and do not substitute for OneAuth or OneSystem source,
runtime, ownership, or operational evidence.

## Reproducibility baseline

- ezagent revision: `d6021550b475c39650f5fc789af7f56171ff887a`.
- OneSystem checkout:
  `/home/huangjiajia/.config/superpowers/worktrees/OneSystem/opensource-readiness-0703`.
- OneSystem immutable revision:
  `7ca946aa6ddc7e5e3a0a12401352eaf82836f8fa` (authored
  `2026-07-06T17:51:31+08:00`). The three cited files are byte-identical to
  that revision; unrelated checkout changes do not affect this evidence.
- OneAuth search boundary: `/home/huangjiajia`, maximum depth 6. No matching
  OneAuth repository was found on 2026-07-17.
- Official protocol references: [RFC 6749](https://www.rfc-editor.org/rfc/rfc6749),
  [RFC 7636](https://www.rfc-editor.org/rfc/rfc7636),
  [RFC 9700](https://www.rfc-editor.org/rfc/rfc9700), and the
  [SOPS project](https://github.com/getsops/sops). RFC 6749 binds access to
  granted scope; RFC 7636 defines a per-authorization-request verifier; RFC
  9700 requires modern OAuth deployments to support PKCE. SOPS officially
  supports Age recipients and plaintext-producing decrypt operations. These
  facts support the safety criteria, not an internal-service approval.

### Evidence item OA-01
- Repository/service: OneAuth canonical owner mapping.
- Immutable revision/version: unavailable.
- Owner/operational contact: unavailable.
- Exact source line or API operation: unavailable; no local repository or
  executable client contract was found.
- Reproduction command: `find /home/huangjiajia -maxdepth 6 -type d -iname '*oneauth*' -print 2>/dev/null`.
- Observed output: empty on 2026-07-17.
- Contract criterion: immutable OneAuth subject maps to one canonical ezagent
  entity and workspace, including rename/deactivation lifecycle.
- Result: unavailable.
- Secret-safety: no token or secret material was inspected.
- Operations: availability, service auth, rotation, audit retention, incident
  response, and local-development ownership are all unavailable.

### Evidence item OA-02
- Repository/service: OneAuth AAL/re-authentication.
- Immutable revision/version: unavailable.
- Owner/operational contact: unavailable.
- Exact source line or API operation: unavailable.
- Reproduction command: the OA-01 repository search plus
  `rg -n -i 'oneauth|onesystem' mix.exs apps/*/mix.exs config apps --glob '!**/test/**'` from ezagent revision `d6021550b`.
- Observed output: no OneAuth runtime dependency or client surface.
- Contract criterion: recent-auth result bound to canonical subject, session,
  expiry, and correlation id without provider-token exposure.
- Result: unavailable.
- Secret-safety: RFC 7636/9700 support PKCE as a protocol requirement, but no
  OneAuth result envelope or binding was available to verify.
- Operations: all required operational fields are unavailable.

### Evidence item OA-03
- Repository/service: OneAuth governed provider catalog/client configuration.
- Immutable revision/version: unavailable.
- Owner/operational contact: unavailable.
- Exact source line or API operation: unavailable.
- Reproduction command: same local source/dependency searches as OA-01/OA-02.
- Observed output: no provider catalog, governed-host record, redirect metadata,
  masking contract, or ezagent client was found.
- Contract criterion: governed provider id/host and registered client metadata,
  with operator secrets neither returned nor duplicated into ezagent.
- Result: unavailable.
- Secret-safety: no client secret was accessed.
- Operations: availability, service auth, rotation, audit retention, incident
  response, and local development are unavailable.

### Evidence item OA-04
- Repository/service: OneAuth external OIDC/social-login token semantics.
- Immutable revision/version: unavailable for OneAuth; RFC 6749 is the stable
  public protocol reference (October 2012).
- Owner/operational contact: OneAuth owner unavailable.
- Exact source line or API operation: no OneAuth token audience/scope or
  connected-account consent operation was available.
- Reproduction command: OA-01/OA-02 searches; inspect RFC 6749 sections 3.3 and 5.1.
- Observed output: no proof that a product-login token represents repository
  account binding, requested/granted repository permissions, refresh, or revoke.
- Contract criterion: social-login token must never be treated as repository
  operation consent.
- Result: unavailable; therefore rejected for repository use.
- Secret-safety: no token was acquired or replayed.
- Operations: token rotation, revocation, audit, incident response, and local
  development are unavailable.

### Evidence item OA-05
- Repository/service: OneAuth connected-account authorization backend.
- Immutable revision/version: unavailable.
- Owner/operational contact: unavailable.
- Exact source line or API operation: no begin/callback/reauthenticate/cancel
  contract or observed service endpoint was available.
- Reproduction command: OA-01/OA-02 searches.
- Observed output: no executable surface matching `ProviderAuthorizationBackend`.
- Contract criterion: full authorization conformance, task-independent
  connection lifecycle, single-consume callback, closed errors, and secret-safe
  handoff.
- Result: unavailable.
- Secret-safety: no authorization code, verifier, token, or callback payload was
  accessed.
- Operations: every required operational field is unavailable.

### Evidence item OS-01
- Repository/service: OneSystem SOPS/Age storage primitive.
- Immutable revision/version: `7ca946aa6ddc7e5e3a0a12401352eaf82836f8fa`.
- Owner/operational contact: repository remotes identify H2OSLabs/OneServices,
  but an accountable deployment owner/contact is unavailable.
- Exact source line or API operation: `pkg/secret/manager.go:163-169` records the
  SOPS envelope and decrypt entry; `pkg/secret/manager_test.go:41-101` exercises
  real SOPS/Age encryption and decryption.
- Reproduction command: `git -C <checkout> rev-parse HEAD` and
  `go test ./pkg/secret` from the OneSystem checkout.
- Observed output: revision above; `ok github.com/h2os/onesystem/pkg/secret (cached)`.
- Contract criterion: encryption-at-rest primitive exists and is executable.
- Result: pass for the storage primitive only; not a remote backend approval.
- Secret-safety: test fixtures use synthetic values. The official SOPS project
  confirms Age recipient support and plaintext-producing decrypt behavior.
- Operations: service availability/SLO, service auth ownership, production key
  rotation, audit retention, incident response, and supported local development
  are unavailable.

### Evidence item OS-02
- Repository/service: OneSystem credential replace/version/revoke lifecycle.
- Immutable revision/version: `7ca946aa6ddc7e5e3a0a12401352eaf82836f8fa`.
- Owner/operational contact: unavailable.
- Exact source line or API operation: no opaque credential-ref API with atomic
  replace/version CAS/revoke semantics was found in the inspected secret handler
  or manager surface.
- Reproduction command: `rg -n 'Version|Replace|Revoke|Compare|CAS' pkg/secret pkg/handlers/secret.go` in the pinned checkout.
- Observed output: only unrelated `apiVersion: v1` test fixtures matched; no
  provider-credential lifecycle contract matched.
- Contract criterion: opaque scoped refs, atomic replace, observed version,
  fail-closed revoke, and correlated audit.
- Result: unavailable.
- Secret-safety: source-only inspection; no secret values used.
- Operations: all required operational fields are unavailable.

### Evidence item OS-03
- Repository/service: OneSystem short-lived operation-bound credential lease.
- Immutable revision/version: `7ca946aa6ddc7e5e3a0a12401352eaf82836f8fa`.
- Owner/operational contact: unavailable.
- Exact source line or API operation: no `lease_for_operation`, `consume_lease`,
  exact provider-host/action proof, one-shot consumption, or provider-adapter-only
  unwrap API was found.
- Reproduction command: `rg -n -i 'lease_for_operation|consume_lease|operation.*lease|provider.*adapter' pkg cmd` in the pinned checkout.
- Observed output: no matching API.
- Contract criterion: short-lived version-bound lease, single consume, unwrap
  only in the provider adapter that retains private Req ownership.
- Result: unavailable.
- Secret-safety: no secret release attempted.
- Operations: availability, auth, rotation, audit, incident response, and local
  development are unavailable.

### Evidence item OS-04
- Repository/service: OneSystem generic decrypt surface.
- Immutable revision/version: `7ca946aa6ddc7e5e3a0a12401352eaf82836f8fa`.
- Owner/operational contact: unavailable.
- Exact source line or API operation: `cmd/api-server/main.go:400-405` registers
  authenticated `POST /secrets/decrypt`; `pkg/handlers/secret.go:61-94` accepts
  caller-selected `encrypted_data` and returns plaintext `data` to an admin;
  `pkg/secret/manager.go:168-176` exposes generic decrypt and passes non-encrypted
  input through unchanged.
- Reproduction command: `git diff --quiet HEAD -- pkg/handlers/secret.go cmd/api-server/main.go pkg/secret/manager.go` (exit 0), then inspect the cited lines.
- Observed output: the route and plaintext response are present at the pinned
  revision; cited-file SHA-256 for `secret.go` is
  `0511dd9d0a8d8fe3459eacb9b08e549a051fe445e05018eacbd23f639728d175`.
- Contract criterion: absence of generic plaintext retrieval; provider adapters
  alone may use an operation-bound lease.
- Result: fail.
- Secret-safety: no endpoint was invoked and no secret was decrypted. The source
  contract itself is sufficient to reject this surface.
- Operations: admin authorization exists, but service ownership/SLO, service
  authentication from ezagent, audit retention, rotation, incident response,
  and local-development support remain unavailable.

## Closed evidence result

OA-01 through OA-05 do not collectively pass. OS-02 and OS-03 are unavailable,
and OS-04 fails. Under the approved gate this is a completed negative result:
local V1 authorization and credential backends are selected; remote replacement
is deferred until every criterion has immutable source/API, behavior, owner, and
operational proof plus lead authorization.
