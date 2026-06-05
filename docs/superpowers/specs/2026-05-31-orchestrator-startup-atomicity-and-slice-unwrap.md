# Orchestrator Startup Atomicity + Slice Unwrap + Session-Creation Simplification

**Date:** 2026-05-31
**Status:** rev4 FINAL — IMPLEMENTATION-READY
**Author:** Claude (brainstorm with Allen, 2026-05-31)
**Converged through:** codex adversarial-review rev1 (root-cause correction → C2),
rev2 (rejected "route-through-Generator"), rev3 (detail resolutions), a
code-simplifier+LSP redundancy audit (the reframe below), and Allen's YAGNI calls
(no adoption; no static multi-slot).

**Origin:** Allen "更完整测试飞书同步" e2e — chained dispatch from Feishu group
`oc_83a4f1ff` never fired because **no orchestrator can register** after a phx
restart.

---

## 1. The reframe (audit, LSP-backed)

The premise of rev2/rev3 ("unify two live creation paths") was wrong.
**`Session.spawn_from_template/2` (the Generator) is production-DEAD** — zero
non-test callers; the `Behavior.Template :instantiate` branch returns
`{:error, :use_generator}` (template.ex:281) and nothing dispatches to it. The
live path is `EzagentDomainInstanceMessage.create_session/3` (home_live.ex:91,
admin_live.ex:804/2799, workspace.ex:732). Because the Generator — the only code
that sets `orchestrator_template_uri` (OTU) + registers the MCP context — is
never called in production, **no production session ever gets an orchestrator
set up.** That is the deep cause of "no orchestrator registers."

So this is NOT a unification. It is:
1. **Delete the dead Generator path** (~800–900 net LOC of `session.ex`).
2. **Lift its two still-needed steps** — template materialization (write OTU) +
   MCP registration — **into the live `create_session`**.
3. **Fix the slice-unwrap regression** so a registered orchestrator survives restart.
4. **Make orchestrator startup atomic** (fail-loud, no half-start).
5. **Remove the non-atomicity cruft** (adoption, `:pending`/`:degraded`/`:failed`-
   alive, retries, partial_report, duplicate helpers).

## 2. Root causes (confirmed)

- **Unwrap (HIGH):** `Kind.normalize_slice_view/1` (kind.ex:600) unwraps only
  `%{state, transients}`; persist strips `:transients` (Lifecycle #481) → on-disk
  `%{state}` falls through unchanged → `McpServer.load_chat_slice/1` can't read
  `template_working_copy` → `:orchestrator_not_registered`. Same class as Feishu
  bug #502.
- **No OTU/registration in the live path:** `create_session/3` requires a
  `template_name` (require_template_name!, ezagent_domain_instance_message.ex:112) but uses it
  only for the URI and spawns the Kind bare (`Kind.spawn(Session,…)`, :157) —
  never instantiating the template, so OTU stays nil + registration never runs.
  (NOT #481 data-loss.)
- **Half-start:** `:pending`/`:degraded`/`:failed`-alive states +
  `ensure_subprocess_alive/2` treating PTY-process-liveness as readiness leave
  silent non-functional zombies that retry the bridge JOIN forever.

## 3. Decisions (all locked)

| # | Decision |
|---|---|
| Unwrap | **A + C2** — `normalize_slice_view/1` gains a single-key `%{state}` clause (A); a normalized accessor at `decode_state` consumers (C2, raw output unchanged); only `McpServer.load_chat_slice/1` uses it; fold `feishu_adapter.slice_state/1` into the chokepoint. |
| Path | **`create_session/3` stays the single live entry**; delete the dead Generator; lift OTU-materialization + MCP-registration into it. |
| Adoption | **Removed** — a non-atomicity workaround. Spawn is idempotent: `{:already_started}` → return existing (complete), no re-finalize. |
| Multi-slot | **Removed** — static multi-agent-slot templates + routing reconcile deleted; the orchestrator dispatches workers dynamically at runtime. |
| Startup | **Atomic, fail-loud, 30s registration gate** via async PubSub readiness signal; no `:pending`/`:degraded`/`:failed`-alive. |
| Session-on-failure | session is a valid container; orchestrator failure → **rollback the create** → `{:error, _}` (no half-session left; recovery is an explicit re-create / repair, not a create-time zombie). |
| Restart repair | new helper re-materializes OTU + runs the atomic gate (fixes `main`, `orch-feishu-7429`). |
| Seed | `"default"` SessionTemplate seed = hard boot invariant in **prod/dev only** (`:test` carve-out — Ecto SQL Sandbox). |

## 4. The unified atomic `create_session` (minimal flow)

A single fail-loud sequence in `do_create_session(session_uri, workspace_uri,
owner_uri, template_name)`:

1. **Resolve + validate** — `require_template_name!`, `workspace_name_of!`, build
   `session_uri = session://<template_name>/<ws>/<name>` (the live literal
   convention; `derive_session_uri/3` is deleted with the Generator).
   **Resolve `template_name` → a real SessionTemplate; fail loudly if absent.**
2. **Spawn the Session Kind** (`Kind.spawn(Session, %{uri, owner_uri})`).
   `{:already_started}`/`{:already_registered}` → return existing (idempotent; NO
   adoption re-finalize). `{:error, _}` → `{:error, _}`.
3. **Bind workspace** (one idempotent `WorkspaceRegistry.bind`).
4. **Materialize the orchestrator working-copy fields EARLY** — read the
   template's `orchestrator_template_uri`; write `orchestrator_template_uri` +
   `session_template_uri` to the session working copy **now, before the
   orchestrator can JOIN** (codex rev3 Q3: this narrow early write is safe; it
   needs only template content, not a live orchestrator). If the template has no
   orchestrator (plain session) → skip 5–7.
5. **Ensure orchestrator atomically** — spawn the orchestrator PTY; **await
   registration ≤30s** via the async readiness signal (§5). `:ready` on success.
   On timeout / spawn error → **rollback (step 9) → `{:error, _}`** (fail-loud,
   no `:pending`, no `:failed`-alive). Ownership check is 2-way (`:owned` /
   `:not_live` / `:foreign`) — the `:ownership_pending` retry loop
   (`retry_after_race`/`do_retry`/`@retry_*`) is deleted (atomic spawn commits
   lineage+bind, so no limbo).
6. **Grant caps** — scoped orchestrator caps + **one** owner
   `OrchestratorAdmin :restart` grant (delete the duplicate at session.ex:1722;
   keep ezagent_domain_instance_message.ex’s, using the named `cap_equal_ignoring_metadata?`).
7. **Register MCP context** (`McpRegistry.register`) — cache-fill; the lazy
   `rebuild_from_durable` (now able to read OTU via A+C2) also reconstructs it on
   JOIN.
8. **Join members** — **one** helper over `[owner, orchestrator]` (merge
   `join_creator/2` + `auto_join_session_members/3`; both already dispatch
   `chat.join` as `system://session-internal`). No static workers.
9. **Rollback (on any 4–8 failure)** — minimal: terminate the orchestrator Kind
   (if spawned) + the Session Kind, unbind workspace, delete the snapshot row;
   each idempotent. (No multi-store enumeration — atomic structure means little
   has been committed.) Crash-mid-create safety: an incomplete session is caught
   by the completeness check in step 2 / boot reconcile + repaired (§6), not
   adopted.

**Degraded surfacing:** keep the cc "orchestrator skill failed to load" concept
(`notify_orchestrator_role_degraded`, one guarded function) → outcome
`:ready | :ready+degraded`. Return shape: `{:ok, session_uri, %{orchestrator_status:
:ready|:failed, ...}}` (preserve — the session is valid even if a *later*
orchestrator issue arises).

**Re-evaluate the `:global` lock:** its stated purpose (codex #409) is serializing
the `:fresh`-rollback vs `:adopted`-commit interleave. With adoption gone + spawn
idempotent, that race is gone; keep the lock ONLY if a concurrent same-URI create
can still tear state — otherwise remove (decide during implementation; default to
keeping a thin per-URI lock if cheap and clearly safe).

## 5. Atomic startup signal + boot

- **Async readiness:** `McpChannel.join/3` (mcp_channel.ex:61), on successful
  registration, `Phoenix.PubSub.broadcast`es `{:orchestrator_ready, uri}` on a new
  `"orch:lifecycle"` topic.
- **30s gate:** the creating process subscribes + `receive`s with a 30s timeout
  (no busy-poll). Timeout → kill PTY, mark `:failed`, emit operator-visible error
  (EventLog + owner notification), stop respawn.
- **`ensure_subprocess_alive/2` (cc_agent.ex:1389):** readiness = registered, not
  process-alive; on boot, after respawn, await the same gate; fail-loud + stop
  the respawn loop on timeout; **stagger** concurrent gates (bounded concurrency)
  to avoid an N×30s boot storm.

## 6. `:restart` repair (fixes existing nil-OTU sessions)
`OrchestratorAdmin :restart` (orchestrator_admin.ex:134) is cap-only and the LV
path dispatches `template.instantiate` (admin_live.ex:1203) — neither sets OTU.
Add a `repair_orchestrator/…` runtime helper that re-materializes the session
working copy (writes OTU + `session_template_uri` from the session's template)
then runs the §5 atomic gate. This is how `main` / `orch-feishu-7429` recover.

## 7. Deletions (audit + LSP-backed)
- **Dead now:** `Session.ensure_orchestrator/3` 3-tuple wrapper (zero callers).
- **Dead Generator tree:** `spawn_from_template/2`, `reconcile_loop/4`,
  `run_reconcile_steps_3_through_8/7`, `ensure_session/3`, `reconcile_each_slot`
  (+ slot helpers), `reconcile_routing_rules` (+ routing helpers), `merge_working_copy/6`
  (replaced by step-4 narrow write), `assemble_outcome/8`, `partial_report/1`,
  `derive_session_uri/3`, `owner_instantiate_preflight/2` (live path relies on the
  dispatch chokepoint), the other Generator preflights, the "this-pass
  revalidation" (`slot_still_owned?`), and the Generator-only test suites
  (`generator_test`, `reconciler_test`, `session_spawn_from_template_test`,
  `session_reconciler_helpers_test`).
- **Non-atomicity cruft in `ezagent_domain_instance_message.ex`:** the `:fresh`/`:adopted`/
  `:spawn_failed` 3-way branch, `rollback_fresh_session`'s 4-store enumeration
  (→ minimal terminate), the `:pending` + `:failed`-alive meta arms, the duplicate
  cap-grant + inlined `has_equiv?`, one of `safe`/`try_safe`.
- **Estimate:** ~1000 LOC removed (~35% of the two files) + dead tests.

## 8. Files touched

| File | Change |
|---|---|
| `…/kind.ex` | A: single-key `%{state}` clause + moduledoc constraint |
| `…/ecto/kind_snapshot.ex` | C2: normalized accessor (raw decode unchanged) |
| `…/orchestrator/mcp_server.ex` | `load_chat_slice/1` uses normalized accessor |
| `…/ezagent_domain_instance_message.ex` | the §4 atomic flow; remove adoption/`:pending`/`:failed`-alive/dup-cap; add step-4 materialization + step-7 register |
| `…/entity/session.ex` | DELETE the Generator tree (§7) + dead `ensure_orchestrator/3`; keep+rename `ensure_orchestrator_with_meta` → `ensure_orchestrator/3`; 2-way ownership; one join helper; one cap-grant |
| `…/orchestrator/mcp_channel.ex` | broadcast `{:orchestrator_ready, uri}` |
| `…/orchestrator/orchestrator_admin.ex` (+ admin_live) | `repair_orchestrator` re-materializes OTU + gate |
| `…/template/cc_agent.ex` | `ensure_subprocess_alive` = registration-gated + staggered |
| `…/plugin_liveview/admin_live.ex` | 2-state orchestrator UI (drop `:pending`/`:degraded`-as-state) |
| `…/plugin_feishu/feishu_adapter.ex` | fold `slice_state/1` into chokepoint |
| `…/ezagent_domain_instance_message/application.ex` | `"default"` SessionTemplate seed = hard boot invariant (prod/dev; `:test` carve-out) |
| `…/behavior/template.ex` | remove the `:use_generator` dead-end (or repoint) |

## 9. Validation
- **Invariant gate test:** create from orchestrator-bearing template → `:ready`;
  **drop `McpRegistry`, `from_orchestrator_uri/1` → `{:ok,_}`** (rebuilt from
  durable; FAILS on main today, PASSES with A+C2); plain template → no
  orchestrator, no failure; un-registerable orchestrator → `:failed` (loud, not
  zombie); **creator IS a member** after create; raw `decode_state` unchanged.
- **Unit:** `normalize_slice_view/1` table; template-resolution fail-loud;
  `repair_orchestrator` sets OTU.
- **E2E:** fresh orchestrator session + bind Feishu `oc_83a4f1ff` + chained-dispatch
  prompt → orchestrator dispatches → chained replies mirror back.

## 10. Scope / out
- **In:** §3–§9.
- **Out (follow-up):** generic non-orchestrator cc-agent readiness gating.

## 11. Implementation order (one PR)
1. A+C2 unwrap + invariant test (proves the registration fix in isolation).
2. Delete dead `ensure_orchestrator/3` + the Generator tree + dead tests.
3. Atomic `create_session` (§4) incl. step-4 materialization + step-7 register +
   remove adoption/`:pending`/`:failed`-alive; dedupe helpers.
4. Async readiness signal + 30s gate (§5) + `ensure_subprocess_alive` gating.
5. `repair_orchestrator` (§6) + default-seed invariant (§3).
6. AdminLive 2-state + feishu fold-in.
7. E2E validate; then codex adversarial-review the PR code.
