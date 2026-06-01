# Migration LOC + deadcode analysis — Router/Behavior/Kind contract

**Date**: 2026-05-28 (Allen directive 16:13 — "请再次检查有没有deadcode遗留，并统计此次迁移后LOC的变化")
**Pre-migration baseline**: `00fe5eb6` — `Merge pull request #444` (2026-05-28 18:16:59 +0800, last commit before #451 merged at 20:33)
**Post-migration HEAD**: `4f5b09ca` — `test(e2e): scenarios #30 + #5-7 (#468)` (current `origin/main`)
**SPEC under audit**: `docs/superpowers/specs/2026-05-28-router-behavior-kind-architecture.md` (PR #445)
**Scope of "migration"**: PRs #451 (Router/Behavior/Kind primitives + LegacyAdapter), #452 (scenarios index), #453 + #454 (Kind.Runtime wiring), #462 (Phase 2 integration: chat / identity / workspace / external_mirror / pty / cc-verify / codex+feishu / echo+np+curl_agent), #463 (6 core Behaviors migrated), #464 (delete LegacyBehaviorAdapter + invoke/4), #465–#468 (e2e scenarios).

---

## Section 1 — Deadcode findings

### TL;DR

The migration's Phase 3 deletion gate (PR #464) already removed the LegacyBehaviorAdapter and the legacy `invoke/4` dispatch path. The remaining cleanup surface is small. The `mix xref` static-only path was unavailable (no `deps` fetched per `feedback_codex_companion_no_mix`); the findings below are from targeted greps over `apps/*/lib/`.

### Defined-but-unreferenced modules — **0 confirmed**

The naive scan flagged 71 module names where the **full-qualified** path appears only in the defining file. Manual verification showed **all** of them are reached by at least one of:

- Phoenix router using bare module names (`live "/admin/routing", RoutingLive`)
- Mix-task discovery (`mix ezagent.xxx` invocation, never imported)
- Application module configured in `mix.exs` (`mod: {EzagentDomainPython.Application, []}`)
- Group-form aliases (`alias EzagentDomainPython.{FrameBuffer, JsonRpc}`)
- Ecto schema joined via `from(r in MessageRouting, ...)`

Borderline-but-justified examples checked individually:

| Module | LOC | Why it stays | Action |
|---|---|---|---|
| `Ezagent.MessageRouting` | 44 | Ecto schema; referenced via `MessageRouting` short name in 2 query files | keep |
| `Ezagent.StressMetrics` | 237 | Started explicitly by `mix ezagent.stress`; intentionally outside supervision per moduledoc | keep |
| `Ezagent.Telemetry` | (small) | Re-exported with short alias from `ezagent_web/lib/.../telemetry.ex` | keep |
| `EzagentDomainAgentBridge` | 13 | Doc-only umbrella module (just `@moduledoc`); minimal anchor — could fold into `application.ex` | optional refactor (-13 LOC) |
| `EzagentDomainPython.FrameBuffer` | 114 | Used via group-alias `alias EzagentDomainPython.{FrameBuffer, JsonRpc}` in `server.ex` | keep |
| `EzagentPluginFeishu.SenderResolver` | (small) | Short-name used by 5 sibling files | keep |

**Conclusion**: no production modules are dead post-migration.

### Defined-but-unused functions — **not enumerated** (out of scope without `mix xref`)

A future audit running `mix xref deprecated` + `mix xref callers <mod>` against a full `deps`-fetched build would surface these. Statically not feasible from this worktree per `feedback_codex_companion_no_mix`.

### Orphan files in `lib/` — **0 confirmed**

`git ls-tree` shows 7 net new lib files (the new framework primitives: `cmd.ex`, `event_log.ex`, `event_subscriber.ex`, `kind/state_rebuilder.ex`, `router.ex`, `saga_runner.ex`, `snapshot_store.ex`). All are referenced from `Kind.Runtime`, `Ezagent.Behavior`, and/or `EzagentCore.Application`. No files were deleted by the migration (consistent with #464's behavior-of-deletion being a code path, not a file path).

### Stale `@behaviour` declarations — **0**

All 11 `@behaviour SomeMod` declarations across `apps/*/lib/` point to a `defmodule` that exists:

- `Ezagent.AgentBridge.Adapter`
- `Ezagent.Behavior`
- `Ezagent.Behavior.Publisher`
- `Ezagent.EventSubscriber`
- `Ezagent.ExternalMirror.Adapter`
- `Ezagent.ExternalMirror.Binding`
- `Ezagent.Kind`
- `Ezagent.Kind.Template`
- `Ezagent.Plugin`
- `Ezagent.UI.Form`
- `Ezagent.UI.SessionView`

### Phase cleanup remnants — **3 doc-only comments**

The Phase 3 deletion (#464) was thorough on code; the surviving Phase-N strings in `apps/*/lib/` are all `@moduledoc` history or co-existence notes that document the migration trajectory:

| File | Line | Note |
|---|---|---|
| `apps/ezagent_core/lib/ezagent/event_log.ex` | 36 | "co-exist until Phase 3 cleanup removes the telemetry-derived rows" — **stale**: Phase 3 is now complete; this comment should be revised or deleted |
| `apps/ezagent_core/lib/ezagent/snapshot_store.ex` | 41 | "Phase 1 coexistence with legacy adapter" — **stale**: legacy adapter is gone post-#464; the heading should be updated to "Production write seam (Phase 2+ migrations complete)" |
| `apps/ezagent_core/lib/ezagent/notifications.ex` | 50 | "legacy raw shape from Chat.invoke(:receive)) coexist with the new tagged envelope while migration completes" — **status-check needed**: if Chat.invoke(:receive) is gone (it is — #464 deleted invoke/4), this comment is stale |

Non-stale `Phase 3 deletion` markers (these correctly document what was removed and should stay as history):

- `apps/ezagent_core/lib/ezagent/behavior.ex` lines 5, 563, 718
- `apps/ezagent_core/lib/ezagent/cmd.ex` line 43
- `apps/ezagent_core/lib/ezagent/kind/runtime.ex` line 688
- `apps/ezagent_core/lib/mix/tasks/compile/ezagent_plugin_check.ex` line 297

Open TODOs (kept for future phases, not stale):

- `apps/ezagent_domain_identity/lib/ezagent/identity.ex:127` — `TODO Phase 8d`
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex:2751` — `Phase 7 PR 46 TODO`

### Test-support modules with no callers — **0** (false-positives only)

A scan flagged 5 modules in multi-`defmodule` test-support files (e.g. `Ezagent.TestSupport.OrderTracker` inside `post_init_test_behaviors.ex`). Manual short-name verification confirmed each is referenced — the scan's full-qualified pattern misses multi-defmodule-per-file naming conventions in test-support.

### SPEC #445 §11 acceptance-criteria gate results

Running the 7 grep gates from SPEC §11 against `apps/*/lib/ezagent/behavior/*` files (the plugin-Behavior surface):

| Gate | Target | Result |
|---|---|---|
| 1. No plugin Behavior defines `invoke/4` | 0 hits | **PASS** — 0 hits in behavior/ files (only `ApiV1Controller.invoke/2` and `Orchestrator.Tools.invoke/2` remain, both outside `/behavior/`) |
| 2. No plugin Behavior reads `slice` (action handlers) | 0 hits | **PASS** — `, slice,` appears only in `handle_continue/3` and `handle_kind_message/3` lifecycle hooks, which legitimately receive slice per the new `Ezagent.Behavior` contract |
| 3. No plugin Behavior calls `Ezagent.Invocation.dispatch` | 0 hits | **FAIL** — 4 violations in `workspace.ex` (1× live call in `resolve_source_config_dir`), `external_mirror_worker.ex` (2× live calls in subscribe-from + publish), `pty.ex` (1× doc-only), `publisher.ex` (1× doc-only). The 3 live calls are deliberate (need return value into `with` chain — `:dispatch` effect grammar doesn't return into handler) but they violate the SPEC §11 grep gate as written. **Decision needed**: either widen the effect grammar to support synchronous return-passing dispatches, or amend §11 to exempt documented escape hatches. |
| 4. No `Phoenix.PubSub.broadcast` in Behaviors | 0 hits | **PASS** — 0 hits |
| 5. No direct `Ezagent.(Kind.)?Snapshot.` calls | 0 hits | **PASS** — 2 hits are doc-only comments (`external_mirror.ex:192`, `lifecycle.ex:28`) — no runtime call |
| 6. No `Ezagent.(Behavior\|Capability)Registry` use in Behaviors | 0 hits | **PARTIAL** — 1 live use in `identity.ex:438` (`CapabilityRegistry.data_owner_of`); 2 doc-only mentions (`presence.ex:10`, `publisher/session_impl.ex:25`). The `data_owner_of` call in `identity.ex` is a real violation. |
| 7. Plugin Behavior LOC ≤ 5500 (was ~11000) | ≤5500 | **FAIL** — 9703 LOC across 22 files (11.8% reduction from the SPEC's 11000-baseline, **−0.3%** vs the actual `00fe5eb6` baseline of 9678 LOC) |

**Bottom line: 3 of 7 acceptance gates fail or partially-fail**. The architectural-commitment test the SPEC defines is NOT yet green. The grep-gate failures (3, 6, 7) are the most consequential — Gate 7 in particular indicates the plugin-isolation north-star is not yet achieved by LOC measure.

---

## Section 2 — LOC delta

### Total delta

| Metric | Value |
|---|---|
| Files changed | 166 (115 added, 51 modified, 0 deleted) |
| Lines added | +24,304 |
| Lines deleted | −3,875 |
| Net delta | **+20,429** |

### By top-level tree

| Tree | Files changed | Lines added | Lines deleted | Net |
|---|---|---|---|---|
| `apps/` | 104 | +18,906 | −3,875 | **+15,031** |
| `docs/` | 62 | +5,398 | 0 | **+5,398** |
| `tests/`, `scripts/`, `config/` | 0 | 0 | 0 | 0 |

### Framework code — `apps/ezagent_core/lib/ezagent/` (excluding `behavior/`)

| | LOC |
|---|---|
| Pre (`00fe5eb6`) | 17,779 |
| Post (`4f5b09ca`) | 21,208 |
| **Delta** | **+3,429** |

New framework modules added by PR #451 (the 8-module SPEC §5 framework machinery — 7 net new files):

| File | LOC |
|---|---|
| `apps/ezagent_core/lib/ezagent/router.ex` | 271 |
| `apps/ezagent_core/lib/ezagent/event_log.ex` | 329 |
| `apps/ezagent_core/lib/ezagent/event_subscriber.ex` | 302 |
| `apps/ezagent_core/lib/ezagent/snapshot_store.ex` | 325 |
| `apps/ezagent_core/lib/ezagent/kind/state_rebuilder.ex` | 300 |
| `apps/ezagent_core/lib/ezagent/saga_runner.ex` | 321 |
| `apps/ezagent_core/lib/ezagent/cmd.ex` | 102 |
| **Sum** | **1,950** |

The remaining ~1,479 of the +3,429 framework delta lives in modifications to existing core files (`behavior.ex`, `kind/runtime.ex`, `audit.ex`, `capability_registry.ex` etc.) absorbing the Router/Behavior/Kind contract.

SPEC §1.5.7 estimated "~2,480 LOC framework (down from ~5,000 LOC scattered today)". Actual framework growth of **+3,429 LOC** is **38% over the estimate** but the SPEC's "down from ~5,000" framing assumed deletions in core that did not materialise — the migration **added** framework primitives without removing the predecessor scaffolding around them. This is consistent with the absence of any `D` (deleted) files in `apps/*/lib/`.

### Per-domain plugin lib LOC

| App | Pre LOC | Post LOC | Delta | Reduction |
|---|---|---|---|---|
| ezagent_core (whole app, includes core Behaviors) | 19,139 | 22,641 | +3,502 | −18.3% |
| ezagent_domain_chat | 13,590 | 13,381 | −209 | 1.5% |
| ezagent_domain_identity | 4,685 | 4,329 | −356 | 7.6% |
| ezagent_domain_workspace | 4,007 | 3,885 | −122 | 3.0% |
| ezagent_domain_external_mirror | 6,267 | 6,376 | +109 | −1.7% |
| ezagent_domain_pty | 1,097 | 1,103 | +6 | −0.5% |
| ezagent_domain_python | 1,651 | 1,651 | 0 | 0% |
| ezagent_domain_ui | 4,087 | 4,087 | 0 | 0% |
| ezagent_domain_agent_bridge | 854 | 854 | 0 | 0% |
| ezagent_plugin_cc | 2,963 | 2,963 | 0 | 0% |
| ezagent_plugin_codex | 974 | 974 | 0 | 0% |
| ezagent_plugin_curl_agent | 897 | 890 | −7 | 0.8% |
| ezagent_plugin_echo | 811 | 792 | −19 | 2.3% |
| ezagent_plugin_feishu | 3,982 | 4,034 | +52 | −1.3% |
| ezagent_plugin_liveview | 14,332 | 14,332 | 0 | 0% |
| ezagent_plugin_np | 1,215 | 1,159 | −56 | 4.6% |
| ezagent_cli | 1,390 | 1,390 | 0 | 0% |
| ezagent_web | 4,992 | 4,992 | 0 | 0% |
| **TOTAL apps lib** | **87,118** | **90,018** | **+2,900** | **−3.3%** |

### Plugin-Behavior files (the SPEC §11 metric) — per-file

This is the surface the SPEC §11 LOC target measures (`apps/*/lib/ezagent/behavior/*.ex`):

| File | Pre LOC | Post LOC | Delta |
|---|---|---|---|
| ezagent_core/.../behavior/lifecycle.ex | 243 | 280 | +37 |
| ezagent_core/.../behavior/notifications.ex | 68 | 86 | +18 |
| ezagent_core/.../behavior/presence.ex | 67 | 73 | +6 |
| ezagent_core/.../behavior/routing.ex | 236 | 232 | −4 |
| ezagent_core/.../behavior/sandbox.ex | 746 | 762 | +16 |
| ezagent_domain_chat/.../behavior/chat.ex | 1,343 | 1,152 | −191 |
| ezagent_domain_chat/.../behavior/orchestrator_admin.ex | 112 | 125 | +13 |
| ezagent_domain_chat/.../behavior/template.ex | 747 | 713 | −34 |
| ezagent_domain_chat/.../behavior/publisher/session_impl.ex | 0 (new) | 613 | +613 |
| ezagent_domain_external_mirror/.../behavior/external_mirror.ex | 877 | 920 | +43 |
| ezagent_domain_external_mirror/.../behavior/external_mirror_worker.ex | 692 | 758 | +66 |
| ezagent_domain_external_mirror/.../behavior/publisher.ex | 119 | 119 | 0 |
| ezagent_domain_identity/.../behavior/api_keys.ex | 239 | 242 | +3 |
| ezagent_domain_identity/.../behavior/identity.ex | 912 | 590 | −322 |
| ezagent_domain_identity/.../behavior/user_credentials.ex | 177 | 162 | −15 |
| ezagent_domain_identity/.../behavior/user_tokens.ex | 308 | 293 | −15 |
| ezagent_domain_identity/.../behavior/workspace_user_admin.ex | 256 | 249 | −7 |
| ezagent_domain_pty/.../behavior/pty.ex | 135 | 141 | +6 |
| ezagent_domain_workspace/.../behavior/workspace.ex | 1,332 | 1,210 | −122 |
| ezagent_plugin_curl_agent/.../behavior/curl_agent.ex | 356 | 344 | −12 |
| ezagent_plugin_echo/.../behavior/echo.ex | 234 | 206 | −28 |
| ezagent_plugin_np/.../behavior/np_agent.ex | 479 | 433 | −46 |
| **TOTAL plugin-Behavior LOC** | **9,678** | **9,703** | **+25** |

(SPEC §11's "~11,000 → ≤5,500" baseline appears to have included plugin app code outside `/behavior/` directories. Even taking the most generous reading of "plugin LOC" the actual movement is small.)

### Test code

| | LOC |
|---|---|
| Pre apps test/ | 71,459 |
| Post apps test/ | 83,590 |
| **Delta** | **+12,131** |

Test growth (+12,131 LOC) breaks down:

- 23 migration-parity tests added (per-Behavior side-by-side old-vs-new behaviour verification, per SPEC §7.3)
- 13 e2e scenario tests added (scenarios #5–#7, #10–#11, #14–#15, #22, #24–#25, #30, plus categories 4, 5, 7, 10, 17)
- New framework primitive tests: `router_test.exs`, `event_log_test.exs`, `event_subscriber_test.exs`, `saga_runner_test.exs`, `snapshot_store_test.exs`, `state_rebuilder_test.exs`, `behavior_test.exs`, `kind/runtime_new_contract_dispatch_test.exs`, `kind_extensions_test.exs`

The test-to-lib growth ratio is **+12,131 / +2,900 = 4.2×**. This is healthy — the architectural-change had explicit parity-test coverage and broad e2e expansion.

### Doc code

| | LOC |
|---|---|
| Pre docs/ | 98,685 |
| Post docs/ | 104,083 |
| **Delta** | **+5,398** |

All +5,398 lines are in `docs/scenarios/` (62 new files; the e2e scenarios catalog Allen requested in #452 / 2026-05-28 12:32 directive). No churn in `docs/superpowers/specs/` or other doc trees.

### Totals

| Tree | Pre LOC | Post LOC | Delta |
|---|---|---|---|
| apps lib | 87,118 | 90,018 | **+2,900** |
| apps test | 71,459 | 83,590 | **+12,131** |
| docs | 98,685 | 104,083 | **+5,398** |
| **Grand total** (apps + docs) | **257,262** | **277,691** | **+20,429** |

---

## SPEC #445 §11 target validation

| Target | Status | Notes |
|---|---|---|
| Plugin LOC ≥50% reduction (≤5,500) | **NOT MET** | Actual: 9,703 / +25 from baseline 9,678 (11.8% reduction from SPEC's notional 11,000-baseline; −0.3% from observed baseline). The migration relocated Behavior responsibilities under the new contract but did not collapse the surface — and one large new helper file (`chat/publisher/session_impl.ex`, +613 LOC) was added to keep Chat's Session-Publisher contract clean. |
| Framework LOC budget (~2,480) | **OVER** | +3,429 LOC vs ~2,480 estimate. Acceptable per scope-expansion (7 new modules each averaging ~280 LOC). |
| Total LOC net delta | **NET POSITIVE** | +20,429 LOC (apps + docs). The "net negative or modest positive" expectation is missed — driven primarily by test/parity (+12,131) and the scenarios catalog (+5,398) rather than production code. |

### Why Gate 7 missed

Three structural reasons emerge from the per-file table:

1. **Plug-in lifecycle hooks (`handle_continue/3`, `handle_kind_message/3`) still receive `slice`** — these are NOT the action-handler surface §11 was attacking but they form a meaningful fraction of every domain Behavior (e.g. `external_mirror_worker.ex` has 5 lifecycle clauses, +66 LOC).
2. **The Chat Publisher split** (`publisher/session_impl.ex`, +613 LOC) — extracted from `chat.ex` (−191) but with growth, because the new Publisher contract requires 3-ary callbacks duplicated for each event class. Net: +422 LOC for that one Behavior cluster.
3. **External-mirror complexity is intrinsic** — `external_mirror.ex` and `external_mirror_worker.ex` grew (+43 / +66) because the new contract requires explicit effect lists where the old code had implicit `Snapshot.save_now` + `Phoenix.PubSub.broadcast` calls. The verbosity penalty offset the deletion savings.

### Why Gates 3 and 6 missed

The `:dispatch` effect grammar is fire-and-forget; it cannot pass a return value back into the handler's `with` chain. Three call sites (`workspace.ex` `resolve_source_config_dir`, `external_mirror_worker.ex` `subscribe_from` and `dispatch_publish_to_self`) genuinely need a synchronous return — they call `Ezagent.Invocation.dispatch/1` directly with documented rationale. Same with `identity.ex:438` calling `CapabilityRegistry.data_owner_of/3` — there is no effect grammar for "lookup the data-owner of this Cap and branch". These are real escape hatches the SPEC §11 grep gate does not yet account for.

---

## Recommendations

### Phase 3.5 cleanup (low-risk, immediate)

1. **Update 3 stale co-existence comments** in `event_log.ex:36`, `snapshot_store.ex:41`, `notifications.ex:50` — Phase 3 is complete; these moduledocs should be revised to reflect current state.

2. **Consider folding `EzagentDomainAgentBridge` (13 LOC, doc-only) into its `Application` module** — saves a file, no behavior change.

### Architectural follow-up (needs Allen + codex review)

3. **Decide on the synchronous-dispatch escape hatch**. Three live `Ezagent.Invocation.dispatch/1` call-sites in plugin Behaviors. Either:
   - (a) widen the effect grammar with `{:dispatch_sync, %Cmd{}, key}` that pushes the return into the handler's accumulator and runs in two passes, OR
   - (b) amend SPEC §11 Gate 3 with a per-file allowlist of documented exceptions and require `# §11-exempt: <rationale>` comments before each call site.
   
   Without one of these, Gate 3 stays red.

4. **Decide on registry-lookup escape hatch** (Gate 6). `identity.ex:438` calls `CapabilityRegistry.data_owner_of/3`. Same options as (3) — widen grammar or document exception.

5. **Re-baseline the plugin-LOC target**. The 50% reduction goal was set against an 11,000 LOC notional baseline. The observed Phase-0 baseline was 9,678 LOC. Decide whether:
   - (a) the migration "succeeded structurally" and the LOC target was misframed (new framework code absorbed some of what was "plugin LOC" in the original count), OR
   - (b) there is meaningful additional consolidation to extract — top candidates by current size: `chat.ex` (1,152), `workspace.ex` (1,210), `external_mirror.ex` (920), `sandbox.ex` (762), `template.ex` (713), `external_mirror_worker.ex` (758), `publisher/session_impl.ex` (613), `identity.ex` (590).

### Phase 4+ (out of scope here)

- The two open `TODO Phase 8d` (`identity.ex:127`) and `Phase 7 PR 46 TODO` (`admin_live.ex:2751`) remain. Track in `docs/futures/todo.md` per `project_durable_todo_list`.
- A future `mix xref deprecated` + `mix xref callers` audit (in a fully `deps`-fetched env) would surface defined-but-unused functions — out of scope for this static-only pass.

---

## Methodology notes

- **mix xref unavailable**: `mix xref unreachable` was attempted; the worktree has no fetched `deps/`, so mix bailed. Per `feedback_codex_companion_no_mix`, this analysis is static-grep-only.
- **Module-reference scanner caveats**: an initial scan using full-qualified module patterns over-reported deadcode (71 candidates) because Phoenix routers, Mix tasks, Ecto schemas, and `alias X.{A,B}` group forms reach modules without the full path appearing. Each flagged module was manually verified before being marked alive.
- **Baseline commit choice**: `00fe5eb6` is the last merge on `main` before PR #451 (the first migration PR) merged. This is also the commit that closed PR #444 (Loom spec; unrelated to architecture migration). The migration window is roughly 2026-05-28 18:16 → 22:33 — a 4-hour autonomous burst.
- **LOC = newline count**: `wc -l` on file contents. No comment-stripping, no test-vs-code split inside a single file. Numbers are gross LOC.
