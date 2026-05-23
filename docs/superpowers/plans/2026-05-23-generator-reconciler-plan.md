# Plan — Generator → Reconciler refactor

> **Companion to**: `docs/superpowers/specs/2026-05-23-generator-reconciler.md` (the SPEC).
> **Status**: DRAFT — 2026-05-23. NO code changes in this branch; this is the
> implementation roadmap for a follow-up PR sequence.
> **Estimated total**: 3 PRs of code + 1 PR of docs, ~4 working days.

## Sequencing overview

```
PR-A: derive_session_uri/3 + idempotency helpers (NON-BREAKING)
   ↓
PR-B: spawn_from_template/2 becomes reconciler (BREAKING — internal)
   ↓
PR-C: update_agent_template becomes per-slot reconciler
   ↓
PR-D: docs (supersede notice, retrospective, SKILL.md updates)
```

PR-A is reviewable in isolation (pure addition; no behaviour change).
PR-B is the cutover commit — old saga and new reconciler do not coexist
in main. PR-C builds on PR-B's `{:partial, _}` convention. PR-D documents.

---

## PR-A — Idempotency helpers (NON-BREAKING)

**Branch**: `feat/generator-reconciler-pr-a-idempotency-helpers`

**Scope** (additions only):

1. `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex` — add (private):
   - `derive_session_uri(template_content, workspace_uri, owner_uri) :: URI.t()`
     — deterministic per `(SessionTemplate URI, owner URI)`. Per SPEC §1.2:
     `session://generic/<workspace>/<owner_name>-<template_name>`.
2. `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex` — add (private):
   - `existing_routing_rule_for(table, matcher_ast, receiver_uris, workspace_uri) :: {:found, %RuleRow{}} | :not_found | {:disabled, %RuleRow{}}`
     — wraps `RuleStore.list/1` + filter by `enabled == true` AND
     `source == :system_default` AND normalized matcher (round-trip via
     `Matcher.to_json/1`) AND receiver-set equality (canonical-string
     compare) AND workspace scope. Returns `{:disabled, _}` when a row
     matches everything except `enabled` (operator drift — SPEC §7-4).
3. `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex` — add (private):
   - `cap_equal_ignoring_metadata?(%Capability{} = a, %Capability{} = b) :: boolean()`
     — `{kind, behavior, instance, workspace_uri, granted_by}` equality;
     ignores `granted_at`. The dispatch-gate for the reconciler's idempotent
     `grant_scoped_caps` (SPEC §2 step 6, codex rev-2 HIGH-1).
4. `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex` — add (private):
   - `worker_already_owned_by_us?(worker_uri, orch_uri, ws_uri) :: boolean()`
     — the structural equivalent of `Workspace.Loader.bind_one_gated/3`'s
     ownership predicate (lineage + workspace match). Used by both worker-slot
     reconcile (SPEC §2 step 3) and orchestrator-adopt gate (SPEC §2 step 2,
     codex rev-2 HIGH-6).
5. **Audit** the call sites of `Session.spawn_from_template/2` (commit message
   records the result; SPEC §7-3 expects "none outside session_live.ex + tests"
   — confirm or surface):
   - `rg -n 'Session\.spawn_from_template' apps/`
   - Each call site categorized: contract dependency or not.

**Tests added**:
- `apps/ezagent_domain_chat/test/ezagent/entity/session_uri_derivation_test.exs`
  - identical `(template, owner)` → identical URI;
  - different owners → different URIs;
  - workspace segment ≡ owner's workspace.
- `apps/ezagent_domain_chat/test/ezagent/entity/existing_routing_rule_test.exs`
  - matcher + receivers + scope + enabled match → returns `{:found, _}`;
  - matcher matches but receivers differ → returns `:not_found`;
  - workspace scope differs → returns `:not_found`;
  - `enabled == false` but otherwise matches → returns `{:disabled, _}` (codex rev-2 HIGH-5);
  - `source == :admin` but otherwise matches → returns `:not_found` (operator's rule, not ours);
  - matcher tuple vs JSON-roundtripped map equality holds.
- `apps/ezagent_core/test/ezagent/capability_equal_ignoring_metadata_test.exs`
  - same authority shape + different `granted_at` → true (codex rev-2 HIGH-1);
  - same authority shape + different `granted_by` → false (provenance matters);
  - different `instance` → false;
  - different `workspace_uri` → false.
- `apps/ezagent_domain_chat/test/ezagent/entity/worker_ownership_predicate_test.exs`
  - live worker + lineage match + workspace match → true;
  - live worker + lineage MISmatch → false;
  - dead worker → false;
  - mirrors `Workspace.Loader.bind_one_gated/3` test coverage.

**No behaviour change.** All existing tests pass unmodified. The new
helpers are unused in production code paths.

**Verification**:
- `mix test --include slow` green.
- `mix dialyzer` green.
- Audit result documented in PR-A commit message.

**Estimated time**: 0.5 day.

---

## PR-B — `spawn_from_template/2` becomes reconciler (BREAKING — INTERNAL)

**Branch**: `feat/generator-reconciler-pr-b-reconcile`

**Scope** (rewrite):

1. `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex`:
   - DELETE: `do_spawn/4` (lines 317-442), `guard/2` (456-467),
     `cleanup_partial/1` (497-542), `terminate_kind/1` (549-563),
     `safe/1` (565-571), `preflight_agent_slots/1` (692-707; codex rev-2
     HIGH-2 — moves into per-slot reconcile), `preflight_candidate_uris_free/3`
     (783-803; the reconciler accepts orphan workers IF they pass the
     ownership gate).
   - REWRITE: `spawn_from_template/2` to call `reconcile_loop/3`.
   - ADD: `reconcile_loop/3` orchestrating the 7 step fns from SPEC §2.
   - ADD: 7 step fns (one per SPEC §2 step), each `:already_converged | {:ok, _} | {:error, reason}`:
     - `ensure_session/3` (SPEC §2 step 1)
     - `ensure_orchestrator/3` (SPEC §2 step 2 — REWRITTEN with `cond` gate
       + bounded re-read for live-but-ownership-unknown race; codex rev-2
       HIGH-6 + rev-3 MEDIUM)
     - `reconcile_slot/5` (SPEC §2 step 3 — REWRITTEN with fast-path
       ownership check + per-slot `ensure_template_alive` formerly in Step 0;
       codex rev-2 HIGH-2)
     - `reconcile_routing_rules/4` (SPEC §2 step 4 — uses `existing_routing_rule_for/4`
       full-contract probe; codex rev-2 HIGH-5)
     - `merge_working_copy/5` (SPEC §2 step 5 — **NEW name + REWRITTEN body**;
       replaces `populate_working_copy/5`; merges prior tuples for pending
       slots via `worker_already_owned_by_us?/3` ownership check; codex rev-2
       HIGH-3 + rev-3 HIGH-1)
     - `grant_scoped_caps_idempotent/3` (SPEC §2 step 6 — **REWRITTEN body**;
       replaces `grant_scoped_caps/3`; reads `Identity.list_caps_for/1`,
       compares each desired cap via `cap_equal_ignoring_metadata?/2`,
       dispatches only the missing ones; codex rev-2 HIGH-1)
     - `register_orchestrator_mcp_context/5` (SPEC §2 step 7 — KEPT body
       unchanged; ETS put is already idempotent)
   - KEEP UNCHANGED (per SPEC §3): `owner_instantiate_preflight/2`,
     `preflight_workspace_isolation/3` + `same_workspace/3` + `slots_in_workspace/2`
     (the structural URI-segment check, no Kind probe — confirmed safe by
     codex rev-2 review), `preflight_slot_name_uniqueness/1`,
     `preflight_routing_rules/1` (pure matcher shape validation),
     `resolve_target_workspace/1`, `validate_workspace_name/2`,
     `read_template_content/1`, `session_discriminator/1`,
     `agent_template_flavor/1`, `verify_slot_candidate_ownership/5`,
     `delegable_template_caps/3` (the owner-cap preflight; the dispatch
     loop around it is the part that gets rewritten as
     `grant_scoped_caps_idempotent/3`).
   - RESTRUCTURE: `instantiate_agent_slots/4` becomes `reconcile_each_slot/4`
     — iterates slots, calls per-slot `reconcile_slot/5`, accumulates
     `{slot_name, outcome}` tuples into `:slots`/`:pending`/`:errors`
     buckets. Loses the `{:error, reason, partial_slots}` 3-tuple return
     form. `instantiate_one_slot/5` body is FOLDED INTO `reconcile_slot/5`
     (the per-slot fast-path comes first, then the `ensure_template_alive`
     +`template.instantiate` dispatch).

2. **Wire `derive_session_uri/3` from PR-A** into `ensure_session/3` (replaces
   `spawn_fresh_session/1`'s `gen-<millis>-<unique_int>` allocation).

3. **Restructure `install_routing_rules/5`** (rename → `add_missing_routing_rules/5`):
   - For each rule in the SessionTemplate's `routing_rules`, call
     `existing_routing_rule_for/4` (PR-A helper); if nil, add to a
     to-insert batch.
   - The to-insert batch runs inside ONE `Repo.transaction` (preserves
     Phase-7 round-4 invariant at the *per-pass* level).
   - `load_into_registry/1` after commit (unchanged).
   - Deferred rules (some receiver `slot_name` resolved to nil because the
     slot is `pending`) go into the pass's `pending` list (not inserted
     this pass).

**Tests added/rewritten**:

- `apps/ezagent_domain_chat/test/integration/spawn_from_template_full_convergence_test.exs`
  — REWRITE (was `session_spawn_from_template_test.exs`); same happy-path
  assertions; now also asserts `slots:` field present in `{:ok, _}`.
- `apps/ezagent_domain_chat/test/integration/idempotent_re_run_test.exs` — NEW.
  - Invoke `spawn_from_template/2` twice with same args;
  - assert second `{:ok, _}` URIs equal first;
  - assert `KindRegistry`, `AgentLineage`, `WorkspaceRegistry`, `routing_rules`
    table byte-equivalent between invocations.
- `apps/ezagent_domain_chat/test/integration/partial_resume_test.exs` — NEW.
  - SessionTemplate has 3 slots;
  - mid-spawn, kill slot 2's worker pid (`DynamicSupervisor.terminate_child/2`);
  - first call returns `{:partial, %{pending: [{:slot, "<name>", :worker_dead}]}}`;
  - second call returns `{:ok, _}` with all 3 slots present;
  - slots 1 + 3 not respawned (assert pid stability via `Process.info(pid, :start_time)`).
- `apps/ezagent_domain_chat/test/integration/failed_slot_retry_test.exs` — NEW.
  - `Application.stop(:ezagent_plugin_curl_agent)` before test;
  - SessionTemplate cites a curl slot;
  - first call returns `{:partial, %{pending: [{:slot, "curl-bot", :agent_template_unresolvable}]}}`;
  - `Application.ensure_all_started(:ezagent_plugin_curl_agent)`;
  - second call returns `{:ok, _}` with curl slot present.
- `apps/ezagent_domain_chat/test/invariants/generator_no_saga_rollback_test.exs` — NEW.
  - The V1-R7 invariant (SPEC §8): `refute session.ex =~ ~r/cleanup_partial|abort_swap|guard\([^,]+,\s*spawned\)/`.

- `apps/ezagent_plugin_liveview/test/ezagent_plugin_liveview/session_live_test.exs` — UPDATE.
  - Assert the LV shows the "Retry instantiation" button when result is `{:partial, _}`.

- `apps/ezagent_domain_chat/test/integration/working_copy_merge_test.exs` — NEW (rev-3 HIGH-1).
  - 3-slot template; reconcile to converged state;
  - manually re-parent ONE slot's worker in `AgentLineage` to a foreign orchestrator;
  - re-invoke reconciler;
  - assert the merge writes a nil-worker tuple for that slot (not the re-parented worker);
  - assert the slot accumulates into `pending` so the next pass attempts re-spawn.

- `apps/ezagent_domain_chat/test/integration/orchestrator_concurrent_race_test.exs` — NEW (rev-3 MEDIUM).
  - Spawn the Session;
  - synchronously start TWO `spawn_from_template/2` callers in parallel tasks;
  - assert: ONE caller succeeds with `{:ok, _}`, the OTHER also returns `{:ok, _}` with the SAME `orchestrator_uri`;
  - neither returns `{:orchestrator_foreign, _}`;
  - exactly ONE orchestrator process exists at the candidate URI;
  - lineage + binding match expected owner / workspace.

- `apps/ezagent_domain_chat/test/integration/cap_grant_no_duplicate_test.exs` — NEW (rev-2 HIGH-1).
  - Reconcile a fresh template (4 caps granted on pass 1);
  - capture `:invocations` row count for `identity.grant_cap`;
  - re-invoke reconciler (pass 2);
  - assert `:invocations` row count unchanged for the orchestrator URI;
  - assert `Identity.list_caps_for(orchestrator_uri)` returns 4 entries (not 8).

**KEPT WITHOUT MODIFICATION**:
- `workspace_isolation_test.exs`
- `cross_workspace_isolation_test.exs`
- `template_caps_test.exs`
- All round-1..3 / round-7..10 preflight + ownership-verification tests.

**Verification**:
- `mix test --include slow` green.
- `mix dialyzer` green.
- V1-R1..V1-R5 + V1-R7 (SPEC §8) green.
- Manual: bring up a SessionTemplate in dev, instantiate it, kill a worker
  pid via observer / `:rpc.call`, instantiate again, see partial → re-invoke
  → ok.

**Estimated time**: 2 days.

---

## PR-C — `update_agent_template` becomes per-slot reconciler

**Branch**: `feat/generator-reconciler-pr-c-update-slot-reconcile`

**Scope** (rewrite):

1. `apps/ezagent_domain_chat/lib/ezagent/orchestrator/tools.ex`:
   - DELETE: `abort_swap_after_repoint_rollback/_` (1123-1188),
     `halt_routing_revert_failed/_` (1189-1221), `manual_repair_error/_`
     (1222-1261), `rollback_slot_to_old/_` (1262-1309),
     `compensate_orphan_worker/4` (301-318), `revert_receivers_by_ids_txn/_`
     (1027-1088).
   - REWRITE: `do_update_agent_template/8` per SPEC §4 (shrinks from ~195
     lines to ~70).
   - REWRITE: `update_agent_template/3`'s return shape — `{:ok, worker_uri}`,
     `{:partial, %{slot, completed, pending, errors}}`, `{:error, reason}`
     (REMOVES `{:error, {:update_needs_manual_repair, _}}`).
   - KEEP: `preflight_template_read/_`, `preflight_swap_uniqueness/_`,
     `preflight_candidate_uri_free/_`, `commit_slot_step2/7` body,
     `repoint_routing_rules/2` body, `maybe_terminate_old/4`.

**Tests rewritten**:

- `apps/ezagent_domain_chat/test/orchestrator/update_agent_template_test.exs`
  — REWRITE every "saga rollback" assertion to reconciler semantics:
  - `{:error, {:update_needs_manual_repair, _}}` removed everywhere;
  - new test: `re_run_after_partial_repoint_converges_test`.

**Verification**:
- `mix test --include slow` green.
- `mix dialyzer` green.
- V1-R6 (SPEC §8) green.

**Estimated time**: 1 day.

---

## PR-D — Documentation

**Branch**: `docs/generator-reconciler-supersede`

**Scope**:

1. `docs/superpowers/specs/2026-05-22-phase-7-completion.md` — prepend
   superseded notice for `cleanup_partial` / `do_spawn` sections; the
   §1.0-1.7 architectural decisions (template Behavior, real `:template`
   slice, Generator owner preflight, workspace isolation) STAND — only
   failure-handling abstraction is superseded.
2. `docs/notes/phase-7-implementation-audit-2026-05-22.md` — append
   "Resolution (2026-05-23)" section pointing at THIS SPEC + PR sequence.
3. `docs/notes/generator-reconciler-retrospective.md` (NEW) — the "10
   rounds of cleanup hardening proved the abstraction was wrong"
   retrospective. Pull lessons from the codex round 1-10 trajectory:
   - r1-3: structural preflights (correct then, still correct);
   - r4: routing batch transaction (correct then, still correct in the
     new pass-level invariant);
   - r5-7: orphan compensation + `fresh?` gate (the round-7 `fresh?`-gate
     IS preserved in the reconciler; the compensation half goes away);
   - r8: ownership verification (preserved);
   - r9: gated load bind (preserved — the precedent);
   - r10: spawner-cleans-its-own-spawn (preserved at the spawn-helper
     level; the saga-level cleanup goes away);
   - the cumulative lesson: each round added one more store to the
     enumeration; the unbounded enumeration is the smell.
4. `docs/notes/generator-reconciler-retrospective.zh_cn.md` (NEW) —
   bilingual parallel per Allen's convention.
5. `.claude/skills/ezagent-developer/SKILL.md` — add to How-to recipes
   section: "How-to: write a reconcile step — idempotent forward
   progress." 5-bullet pattern.

**Verification**:
- Bilingual parity check (both `.md` files exist; manual content check).
- SKILL.md How-to renders correctly when viewed.

**Estimated time**: 0.5 day.

---

## Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| `derive_session_uri/3`'s `(template, owner)` keying breaks the "owner runs same template twice for two purposes" use case | LOW (no current users) | SPEC §7-1 + Allen confirms A vs B before PR-A merges. If B, the slug becomes the 3rd arg in PR-A. |
| External caller depends on strict-atomic contract | LOW | PR-A audit. If found, PR-A inserts deprecation warning + delays PR-B one phx release. |
| Re-run on a partial state finds the prior pass's `routing_rules` rows as "already-installed" but a slot worker is dead — re-converges the slot but rules point at the OLD (dead) worker URI | LOW | The slot's `derive_worker_uri` is deterministic; reconcile step 3 re-spawns at the SAME URI; routing rules still point at the same URI. Verified by V1-R3 test. |
| `RuleStore.list/1` returns N rows; matcher equality compare is structural — equal matchers as `%{}` map and `[...]` list don't compare equal | LOW | `existing_routing_rule_for/4` (PR-A helper) normalizes both sides via the same `Matcher.to_json/1` round-trip the preflight uses. Test in PR-A covers. |
| The `{:partial, _}` arm silently turns into success at a caller that only matches `{:ok, _}` | MED | Dialyzer's tagged-tuple coverage catches the missing-clause in callers. PR-B explicitly updates LV + tests. Codex review pass (this branch) catches anything else. |
| Idempotent re-run accidentally re-grants a cap, leaking telemetry / audit-log spam | LOW | `Identity.grant_cap` IS idempotent at the set level but does emit `:invocations` audit rows on every dispatch. Mitigation: PR-B re-uses a `caps_already_granted?/3` helper that short-circuits the dispatch when the cap is already present. Sub-task in PR-B. |

---

## Open dependencies / cross-PR coordination

- **Phase-9 URI work**: SPEC v3 §5.15 (per-tenant 3-segment URIs) is
  ALREADY shipped (on main); the reconciler builds on it. No coordination
  needed.
- **Codex adversarial-review of THIS SPEC**: scheduled for this branch
  before PR-A is filed. Focus per the trigger prompt: per-Kind idempotency
  claim validity, recoverability of removed `cleanup_partial`,
  `{:partial, _}` + re-run-converges semantics for routing+caps+working-copy,
  migration-window safety, design principle conflicts (P1-P26), parity
  with `Workspace.Loader.gated_load_bind/3`.
- **Allen sign-off on SPEC §7-1 (session URI scheme)** before PR-A.
- **Allen sign-off on SPEC §7-2 (3-arm vs 2-arm return)** before PR-B.

---

## Definition of done (the gate per Allen P6)

PR-A + PR-B + PR-C + PR-D merged. ALL of:

- V1-R1..V1-R8 (SPEC §8) tests green in CI.
- `mix dialyzer` green.
- `generator_no_saga_rollback_test.exs` (V1-R7) green AND verified-failing
  by temporarily reintroducing one `cleanup_partial` line.
- LV shows "Retry instantiation" button on `{:partial, _}` (manual
  agent-browser screenshot per Allen `feedback_open_terminal_first_when_debugging`).
- Bilingual retrospective exists.
- SKILL.md updated.

ONLY after all of the above does this phase claim "done." The V1-R7
invariant test is the architectural gate — it FAILS the moment a future
PR re-introduces saga rollback, which IS the architectural goal per P6.
