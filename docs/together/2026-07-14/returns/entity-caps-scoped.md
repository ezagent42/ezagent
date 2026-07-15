# Entity Caps Scoped Patch Return

> **Task:** entity-caps-scoped (A durable retry / B outbound grant / D facade)
> **Branch:** `feat/entity-caps-scoped`
> **PR:** none (target-branch return; the handoff forbids a `main` PR here)
> **Dev:** Codex
> **returned_at:** 2026-07-15 10:14 +0800
> **deadline:** not provided (out-of-scope request)
> **deadline_status:** out_of_scope

## Delivered

- A adds a DB-backed capability-delivery outbox for grant/revoke only. Pending work
  survives BEAM restart, drains from the existing ready transition and a periodic
  sweeper, and reaches `:applied` only after the grantee handler has run.
- A leaves `require_sync_ack: []` as an unwired policy seam. No synchronous ACK
  protocol or blocking admin/manage/own delivery path was added.
- B adds the single shared `Ezagent.OutboundGrant` ledger and its record, revoke,
  granter-list, and grantee-list APIs. It has no runtime consumer in this patch.
- D adds `Ezagent.EntityCaps` over the existing physical stores: users remain in
  `users.caps_json`; agents and other entities remain in the Identity snapshot.
  Direct storage reads were routed through the facade and an AST architecture gate
  prevents new raw access or mutation outside the narrow storage boundary.
- The three independently reviewed sub-steps are merged into the target branch with
  separate merge commits. No commit was merged into `main` by this return.

## DoD reconciliation

| Handoff line | Status | Proof |
|---|---|---|
| A: durable outbox for absorb/revoke | met | `cap_delivery_outbox` migrations plus canonical envelope, claim lease, retry state and sweeper |
| A: retry on not-ready/buffer-full/no-actor and survive restart | met | ready-drain and cold-boot/sweeper integration; focused kill, overflow, restart and concurrent-drain tests |
| A: applied means grantee handler ran | met | handler/commit result controls terminal outbox state; transient and permanent failures are distinguished |
| A: config hook only, no sync ACK path | met | `require_sync_ack: []` exists in config and is read-only/unwired |
| B: one shared OutboundGrant record | met | one `outbound_grants` table with tenant grantee and globally audited granter identities |
| B: record/list/revoke API and six subtypes | met | focused API round trips and subtype-validation tests pass |
| B: no mount consumer or binding migration | met | source gate rejects `socialware_mounts`/composition coupling; runtime consumer count remains zero |
| D: facade preserves physical SSOT split | met | `EntityCaps` routes user persistence to `caps_json` and non-user persistence to snapshot Identity |
| D: converge raw access and add architecture gate | met | migrated production readers plus syntax-only AST gate covering aliases, imports, captures, `apply`, access/get-in and embedded constructors |
| D: pure behavior preservation | met | legacy grant/revoke/absorb persistence semantics restored; full identity and umbrella suites pass |
| P5, C/#1386 and `#1376` stay out of scope | met | no mount rebuild, no grantee-signing implementation, no `socialware_mounts` change |

**Method friction:** `main` advanced twice during final verification, so D and the
return had to be replayed and the full gate rerun. The umbrella gate also exposed
test-state leakage from a failed default SessionTemplate ReadyGate, and the web
dependency step rewrites unrelated lockfile entries. Future handoffs touching this
area should call out both cleanup checks explicitly; no DoD line was deferred.

## Commits and rebase proof

| Sub-step | Rebase base | Commits | Target merge |
|---|---|---|---|
| A | `be23fcf97a17da9f667b7ec3acccb1d3aedf4e2d` | `d973acaa2`, `42efcdd55`, `343003c00` | `c2a3fc423` |
| B | `958adb34ba4c598d438bd959b79956d61a621f61` | `5b43eb08b`, `5435963ad` | `1371da7b4` |
| D | `ae5a9bca9b2100cea5214b3c0a4ca513ad4588d7` | `4d895e044`, `61e992238`, `5544fe35b`, `f4dbf09d1`, `3fe91e75d`, `c1e295bee` | `8ab5eab9d` |

The target was finally rebased with merge topology preserved onto
`ae5a9bca9b2100cea5214b3c0a4ca513ad4588d7`. That base contains the Phase-4
Ed25519 capability-signing merge (`#1399`) plus the subsequent mainline fixes and
follow-up boundary/docs merges (`#1401`, `#1402`, `#1403`, `#1406`, `#1408`).
`origin/main...HEAD` was `0 16` after the rebase. The test-only reseed recovery
follow-up is `1d05f8789`.

## Reviews and gates

| Scope | Verification | Result |
|---|---|---|
| A independent review | post-hardening review | APPROVED |
| A full gate | `MIX_ENV=test MIX_TEST_PARTITION=entity_caps_a_gate mix ci.local` | PASS, deterministic exit 0 |
| B independent review | post-hardening review | APPROVED |
| B full gate | `MIX_ENV=test MIX_TEST_PARTITION=entity_caps_b_gate mix ci.local` | PASS, deterministic exit 0 |
| D independent review | facade, mutation boundary, gate and post-rebase reviews | APPROVED |
| D full gate | `CI=true MIX_ENV=test MIX_TEST_PARTITION=entity_caps_d_gate_final mix ci.local` | PASS, deterministic exit 0 |
| Latest-main focused | `MIX_ENV=test MIX_TEST_PARTITION=entity_caps_latest2_focus mix test ...` | PASS: core 54/0, identity 51/0, session 11/0 |
| Latest-main combined target | `CI=true MIX_ENV=test MIX_TEST_PARTITION=entity_caps_latest2_final mix ci.local` | PASS, every app summary 0 failures, deterministic exit 0 |
| Static hygiene | `git diff --check`; scope searches; `origin/main` ancestry | PASS |

The full target `ci.local` includes the repository precommit alias and all invariant,
architecture, documentation, conformance and umbrella test gates. This return has no
remote CI URL because the handoff explicitly returns the target branch to the
coordinator without opening or merging a `main` PR; the exact local commands and
deterministic terminal result are recorded above.

The focused command's first sandboxed start was blocked before code execution by
Mix.PubSub socket `:eperm`; the same command was rerun with the required local-socket
permission and passed. Because an earlier `ci.local` aggregation path had shown it can
continue after an app failure, this return relies on inspection of every per-app ExUnit
summary in addition to the final exit status.

## Scope and residual notes

- No existing `users.caps_json` data was migrated; the six live users keep the same
  SSOT. No agent snapshot storage was replaced.
- No recipe or composition binding was migrated onto `OutboundGrant`, and no P5 mount
  reconstruction was implemented.
- Entity lifecycle transitions use the sanctioned lifecycle/user deletion paths and a
  node-local transition lock. An operator performing raw snapshot maintenance outside
  those paths must not race a live cap mutation; cluster-wide locking is not claimed by
  this bounded patch.
- The umbrella gate exposed an existing failed default SessionTemplate ReadyGate leaking
  between tests. The public test-only seed escape hatch now terminates that exact failed
  standard DynamicSupervisor child and retries exactly once for `:failed`; production
  boot/ensure behavior and all other errors are unchanged. The private recovery helper
  was removed.
- `mix ci.local` rewrites the web pnpm lock from package metadata in this checkout. That
  generated-only drift was removed after each gate; the returned worktree is clean.

## Merge request

The target branch is rebased through current `origin/main`, the three bounded sub-steps
and their combined stack are fully green, and the branch is ready for coordinator review.
Do not merge this return directly to `main` until that review is complete.
