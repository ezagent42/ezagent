# Cap-signing No-tail Build-v2 Revision Plan

> **For agentic workers:** REQUIRED SUB-SKILL: use `executing-plans` and complete every checkbox inline in this worktree.

**Goal:** Restore B1-B5 and N-A-N-C without changing the v3 design, dual-read mode, four-source audit, or durable retry lane.

**Architecture:** Exact capability artifacts remain the CAS token. The two physical authority homes get dedicated fail-closed adapters; the heal executor resolves live, user-row, and snapshot state before mutating or quarantining. Recipe bindings refresh directly from their pre-agent durable row, while durable heal delivery receives a stable request identity.

**Tech Stack:** Elixir/OTP, Ecto, ExUnit, Phoenix umbrella Mix gates.

## Global Constraints

- `Ezagent.Cap.signed_and_valid?/2` is the only signedness classifier; never substitute `verify_for/2`.
- Audit keeps all four sources: `users.caps_json`, snapshot identity slices, recipe bindings, and open quarantine.
- `require_signature` remains `false`; no P4 enforce flip.
- Every production fix starts with a regression test that fails for the reported bug.

---

### Task 1: Fail-closed user storage and canonical revoke

**Files:**
- Modify: `apps/ezagent_domain_identity/lib/ezagent/entity_caps/user_store.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex`
- Test: `apps/ezagent_domain_identity/test/ezagent/identity/cap_self_heal_test.exs`

**Interfaces:**
- `UserStore.heal_exact/3` returns `:replaced | :no_match | {:error, term()}` and never writes on decode failure or no-match.
- `handle_revoke_cap/2` persists the reduced user cap set before returning its slice effect.

- [ ] Add malformed-sibling and delayed-heal-after-revoke tests; run them and observe the expected failures.
- [ ] Make `decode_caps/1` return an explicit result and make update/no-match paths non-writing.
- [ ] Persist canonical revoke to `caps_json` before live mutation; rerun focused tests green.

### Task 2: Artifact-CAS quarantine and two-home convergence

**Files:**
- Modify: `apps/ezagent_domain_identity/lib/ezagent/identity/cap_quarantine.ex`
- Modify: quarantine migrations under `apps/ezagent_core/priv/repo_pg/migrations/`
- Create: `apps/ezagent_domain_identity/lib/ezagent/entity_caps/snapshot_store.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/identity/cap/heal_executor.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex`
- Test: `cap_quarantine_test.exs`, `cap_self_heal_test.exs`, `cap_signing_sweeper_test.exs`

**Interfaces:**
- `CapQuarantine.close/2` matches holder + logical identity + exact artifact hash.
- `CapQuarantine.close_resolved/2` locks the current open row and closes that exact stored token after a trusted signed replacement lands.
- `EntityCaps.SnapshotStore.heal_exact/3` atomically replaces only one byte-identical snapshot artifact.

- [ ] Add stale-quarantine-after-signed-replacement and exact-ABA-close tests; observe red.
- [ ] Add artifact token persistence and current-state quarantine checks.
- [ ] Add snapshot exact-CAS adapter and include snapshot state in heal currentness/replacement resolution.
- [ ] Add caps_json-signed/snapshot-unsigned sweep regression; observe green convergence.

### Task 3: Binding reachability, audit tombstones, and outbox idempotence

**Files:**
- Modify: `apps/ezagent_domain_identity/lib/ezagent/identity/cap_signing_sweeper.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/identity/cap_signing_audit.ex`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/identity/cap_self_heal.ex`
- Test: `cap_signing_sweeper_test.exs`, `cap_signing_audit_test.exs`, `cap_self_heal_test.exs`

**Interfaces:**
- Binding candidates call `RecipeCapBinding.refresh_exact/2` directly before any holder-liveness requirement.
- Tombstoned bindings are excluded before artifact decoding.
- Heal dispatch context carries `idempotency_key = "cap-heal:" <> Envelope.payload_identity(request)`.

- [ ] Add never-created binding, malformed tombstone, and repeated-sweep outbox-count tests; observe red.
- [ ] Implement direct binding refresh, early tombstone exclusion, and deterministic heal key.
- [ ] Rerun focused tests green and confirm outbox rows stay constant across repeated passes.

### Task 4: Semantic resolver coverage

**Files:**
- Modify: `apps/ezagent_domain_workspace/lib/ezagent/workspace/cap_reissue_policy.ex`
- Modify: `apps/ezagent_core/test/invariants/cap_issue_chokepoint_test.exs`

**Interfaces:**
- Workspace policy classifies the member `Workspace.create_session` capability and reissues it via `{:rule, :workspace_membership, issuer}`.
- Resolver coverage carries a representative capability and succeeds only if `module.classify(cap)` returns `{:ok, _}`.
- The call scanner recognizes fully-qualified and aliased `Cap.issue` / `Identity.Grant` / `RecipeCapBinding` calls while excluding the canonical wrapper implementation itself.

- [ ] Add a rejecting-policy negative fixture that the old export-only gate would accept; observe red.
- [ ] Add the workspace class resolver and semantic coverage samples.
- [ ] Expand alias/wrapper scanning, update the issuance ratchet, and run invariant gates green.

### Task 5: Full verification and return

- [ ] Format only touched files and review the complete diff for unrelated churn or secrets.
- [ ] Run focused app suites, signing audit/coverage gates, deterministic gates, and `mix ci.local` with partition-safe settings.
- [ ] Fetch/rebase latest `origin/main`; rerun the full verification set.
- [ ] Create Conventional Commit(s), push `feat/cap-signing-notail-upgrade`, and return HEAD plus B/N evidence.
