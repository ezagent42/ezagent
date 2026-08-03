# Integrated CI fixes — continuation handoff

## Current state

- Target branch: `integrate/ci-isolation-dod24-20260803`
- Worktree: `/Users/h2oslabs/Workspace/ezagent/.worktrees/integrate-ci-isolation-dod24-20260803`
- HEAD: `5cfb64256292e06085a4ea876ef157f7e5136415`
- Relative to `origin/main`: ahead 33
- Worktree: clean
- `git diff --check`: passed
- Push/PR/main merge: **not done**
- Full `mix precommit`: **not completed**; stopped on owner request
- Stopped processes: runner stopped; leftover BEAM PID `35016` received SIGTERM and no longer exists

## Integrated work

| Work | Integrated commit |
|---|---|
| PR #1684, clean-slate per-grant revocation, head `dbdf4ad76` | merge `8bd91ec6a` |
| DoD24 `SessionViewRegistry` snapshot/restore fix | `84a5afb32` |
| Actor / SQL Sandbox owner lifecycle containment | `fabd595a9` (from `9b1bc3f2d`) |
| Async VM-global Application/System env and PATH isolation | `296f047c3` (from `1a11268a0`) |
| Historical migration-parity test removal | `5cfb64256` (from `f9e6e265d`) |

The only integration conflict was `identity_migration_parity_test`: PR #1684
modified it while the cleanup commit deleted it. The integration retained the
user-approved deletion.

## Evidence already obtained before integration

- DoD24 focused proof: Domain.UI 15/0, Hello 94/0, World 393/0.
- Actor fix: domain shard all green; core 2306/0; owner-exit,
  `OwnershipError`, RegistrationHooks-owner and failed-terminate counts all zero;
  force compile with warnings-as-errors passed.
- Global env fix: affected core/python/github/web sets all green; format and
  diff checks passed.
- Historical parity cleanup: 267 tests / 4,688 lines removed; focused CI parity,
  identity and external-mirror checks passed.

These are source-branch proofs. They do **not** replace one complete
`mix precommit` on the integrated target branch.

## Next-session Definition of Done

1. Confirm the target worktree and HEAD above are unchanged and clean.
2. Confirm no stale `mix precommit`/BEAM child from this handoff remains.
3. Run exactly one complete `mix precommit` from the target worktree and retain
   the full exit code/log.
4. If red, use systematic debugging and fix only demonstrated integrated-state
   failures on the target branch; rerun until honestly green. Do not mask, skip,
   widen timeouts blindly, or split the verification back into source PRs.
5. When green, push the target branch, create one PR to `main`, review the final
   diff/commit set, merge normally (no force push), and verify `origin/main`
   contains the target HEAD/merge.
6. Reconcile PR #1684 after the integrated PR lands: close/comment it as
   subsumed by the final main merge SHA so no duplicate open PR remains.
7. Report the final PR, main merge SHA, exact `mix precommit` result, and any
   deferred cleanup.

## Runtime legacy/migration paths still present

The local dev-DB audit observed no stored legacy rows at the time of audit:

```text
kind_snapshots_total=5
legacy_json_only=0
binary_without_kind_base_marker=0
session_rows=0
credential_grants_total=0
legacy_incarnation=0
missing_generations=0
provider_attempts_total=0
legacy_purpose=0
provider_operations_total=0
```

This proves only that local DB snapshot, not every deployment, backup or online
sidecar.

### A. Old persisted-data migration/runtime support

1. Legacy JSON snapshots / missing `:kind_base`
   - Tests: `apps/ezagent_core/test/ezagent/kind/kind_base_backfill_test.exs`
   - Runtime: `apps/ezagent_actor/lib/ezagent/ecto/kind_snapshot.ex`,
     `snapshot_store.ex`, `kind/kind_base_backfill.ex`
2. Snapshot `:chat` slice to `:session`
   - Tests: `apps/ezagent_core/test/ezagent/session/slice_migration_test.exs`
   - Runtime: `apps/ezagent_core/lib/ezagent/session/slice_migration.ex`
3. Old `Behavior.Chat` capability to `Behavior.Session`
   - Tests: `apps/ezagent_domain_identity/test/ezagent/identity/grant_migration_test.exs`
   - Runtime: `apps/ezagent_domain_identity/lib/ezagent/identity/grant_migration.ex`
4. Credential grants missing `incarnation_id`
   - Test: `credential_incarnation_backfill_migration_test.exs`
   - Runtime: PostgreSQL migrations `20260727120000_*` and `20260728000000_*`
5. Identity capability dual storage / cutover / pre-epoch support
   - Tests: `entity_caps/store_backfill_test.exs`, `identity/cutover_test.exs`,
     `identity/cutover/runbook_test.exs`, `pre_epoch_boot_remint_test.exs`,
     `entity_caps_test.exs`
   - Runtime: `identity/cutover.ex`, `entity_caps.ex`,
     `entity_caps/store.ex`, `entity_caps/user_store.ex`
6. Session member-cap and self-license migrations
   - Tests: `member_cap_migration_test.exs`,
     `members_are_cap_holders_invariant_test.exs`,
     `session_self_license_migration_test.exs`
   - Runtime: `session/member_cap_migration.ex`,
     `socialware/session_self_license_migration.ex` and their Mix tasks
7. Cross-version definition/recipe seed reflow
   - Tests: `reflow_rehearsal_test.exs`, `recipe_registry_test.exs`
   - Runtime: `recipe_registry.ex`, `definition_registry.ex`,
     `ConfigStore.seed_object_upsert/1`
8. Provider Connection incremental schema upgrade
   - Test: `provider_connection/migration_upgrade_test.exs`
   - Runtime: PostgreSQL migrations `20260718001000_*` through `20260721001000_*`
9. Default routing-rule boot migration
   - Test: `default_rules_migration_test.exs`
   - Runtime: `ezagent_domain_instance_message/default_rules.ex` and boot call
10. Hello imperative-session migration
    - Test: `ezagent_plugin_hello/migrate_test.exs`
    - Runtime: `ezagent_plugin_hello/migrate.ex`, boot hook and
      `HELLO_MIGRATE_ORCHESTRATOR`

Retiring A requires deleting/squashing the corresponding production migration,
Mix task, boot hook and CI path—not merely deleting its tests.

### B. Old online protocol compatibility

1. Old `cc:bridge:<agent_uri>` sidecar topic
   - Tests: agent-bridge `socket_channel_test.exs`, `registry_test.exs`
   - Runtime: agent-bridge `channel.ex`, `registry.ex`
   - DB wipe cannot prove no old sidecar is online.
2. ExternalMirror optional-callback defaults
   - Runtime remains in `external_mirror/adapter.ex` although its fallback tests
     were removed by `f9e6e265d`.
3. ExternalMirror drifted synthetic binding ID
   - Test: `external_mirror/binding_row_test.exs`
   - Runtime: `binding_row.ex` natural-key deletion.

### C. Negative safety/absence gates

These do not migrate stored data; they prove retired or invalid external inputs
remain rejected:

- Old two-segment URI rejection:
  `all_per_tenant_uris_have_workspace_test.exs`, actor `uri_test.exs`, web
  `live_auth_test.exs`
- Removed grant authorization forms: identity `grant_test.exs`
- Unsigned/stale-generation capability rejection:
  `entity_caps/store_backfill_test.exs`, core `cap/visibility_test.exs`
- Legacy/null-generation PAT: `entity/token_generation_test.exs`
- Retired file URL: `uploads_controller_test.exs`,
  `no_legacy_files_route_test.exs`
- Old curl scheme: curl-agent `curl_agent_test.exs`
- Absence/architecture gates: `no_v1_bridge_after_cutover_test.exs`,
  `cap_signing_architecture_test.exs`, `socialware_seed_path_test.exs`

Deleting C is an explicit acceptance that CI will no longer catch future
reintroduction of those inputs. A DB wipe does not remove this risk because an
external caller can construct invalid input at any time.

### D. Not actually a legacy protocol

- Provider `SealedEnvelope` “legacy” golden vectors test the current AES-GCM
  wire format. Prefer renaming to `golden wire-format vector`; deleting it loses
  cryptographic interoperability coverage.
- The removed `*_migration_parity_test.exs` suites were genuine temporary
  old-vs-new implementation parity tests and are appropriate cleanup.

The audit stopped before a full-repo exhaustive pass. Likely remaining areas to
check: upload token missing-grantee, routing plain-list shapes, old PID-file
format, and Notifications dual payload shape.

## ChannelServer MCP finding

- Available Codex MCP tools: `call-channelserver({text})` and
  `send-file({file_path})` only.
- No `get-channelserver`, receive, poll, history or read-history tool exists.
- Incoming Feishu messages use the separate long-lived bridge push path:
  ChannelServer message -> Codex bridge -> app-server `turn/start`.
- MCP `call-channelserver` is outbound-only and talks directly to ChannelServer
  on port 21497.
- At audit time ChannelServer/bridge and 21497 were up, but no app-server was
  listening on 4500, so inbound bridge push failed. This is independent of the
  MCP tool list.

## Paste-ready prompt for the next session

```text
You are the coordinator for an ezagent integration handoff. The root agent only
coordinates and reports; all development/debugging must be delegated to Codex
gpt-5.6-sol subagents with reasoning_effort=high.

Read and follow:
1. AGENTS.md in /Users/h2oslabs/Workspace/ezagent
2. docs/together/2026-08-03/handoffs/integrated-ci-fixes-continuation.md
3. applicable skills, especially using-superpowers, dev-together,
   ezagent-developer, elixir-phoenix-helper, systematic-debugging,
   verification-before-completion and finishing-a-development-branch.

Resume from the existing clean integration worktree:
/Users/h2oslabs/Workspace/ezagent/.worktrees/integrate-ci-isolation-dod24-20260803

Expected branch: integrate/ci-isolation-dod24-20260803
Expected HEAD: 5cfb64256292e06085a4ea876ef157f7e5136415

First verify branch/HEAD/worktree cleanliness and that no stale precommit/BEAM
process remains. Then delegate one gpt-5.6-sol/high subagent to run exactly one
complete `mix precommit` on the integrated target branch. If red, debug and fix
the demonstrated integrated-state failures on this same target branch; do not
mask failures and do not split verification back into source PRs. When honestly
green, push the target branch, create one PR to main, review it, merge normally,
verify origin/main contains the merge, and close/comment PR #1684 as subsumed.

Do not rerun or modify anything before reading the handoff. Preserve all user
work and avoid the dirty root worktree. Report exact test exit, target PR URL,
main merge SHA and any remaining cleanup.

After integration is safely on main, use the handoff's A/B/C/D legacy inventory
for a separate clarify-first retirement plan. Do not delete current security or
crypto coverage merely because a test name contains legacy.
```
