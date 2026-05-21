# Phase 4.5 — Operator/Admin Tools Maturity + Observability

**⚠️ Naming history**: this was originally drafted and shipped under the label "Phase 5" (PRs #27-#32, branch prefix `phase-5/*`). Allen's 2026-05-17 review caught the divergence: this scope (operator-tool maturity + snapshot observability + per-rule cap-check) is **not** the original `IMPLEMENTATION_ROADMAP.md §8` Phase 5, which is `Feishu adapter + CC channel production rewrite + Pty-Web`. First renamed to `phase4-plus`, then to **phase4.5** (Allen prefers .5 versioning, 2026-05-17). The roadmap's true Phase 5 (Feishu/CC v2/Pty-Web, now integrated with current LV per Allen's 2026-05-17 directive) remains the next phase. Merged PR titles ("Phase 5 PR N: ...") are preserved as git history but should be read as `Phase 4.5 PR N` going forward.

**Status:** **completed 2026-05-17** (autonomous one-shot; 5/5 PRs merged: #27, #28, #29, #30, #31 + closeout `ScrollOnUpdate` prepend fix). All invariant tests green; demo recorded.

**Status (drafted):** 2026-05-16 (Allen AFK; autonomous one-shot)
**Theme:** Every operator action that today requires `mix` CLI gets an LV equivalent. Plus snapshot observability + completing the routing cap-protect.

## North star (per memory `feedback_production_usability_is_selection_criterion`)

After Phase 5, an operator can run Ezagent for a real team without ever opening `mix`. All admin surfaces (Workspaces / Users / Routing / Snapshots / Templates) are accessible from the browser with cap-protection.

## Decisions (defaults; no Allen blocking)

| # | Question | Default |
|---|---|---|
| P5-D1 | Workspace add-template LV form: form mode (4 standard fields) + JSON mode (custom Templates) | both — hybrid per PR 7 routing precedent |
| P5-D2 | /admin/users LV: full CRUD or read-only | full CRUD (create + disable + cap-edit) |
| P5-D3 | Cap-edit UI: per-cap form vs caps_str text input | text input (operator types comma-separated; parsed via Ezagent.Capability.Parser) |
| P5-D4 | /admin/snapshots scope: read-only (dump + clear) vs editable | read-only (dump JSON view + Clear button per-row) |
| P5-D5 | mix ezagent.snapshot.* tools: 3 (list/dump/clear) | yes |
| P5-D6 | RoutingAdmin Kind: synthetic singleton (`routing-admin://default`) or per-table | singleton — simpler, one cap to grant |
| P5-D7 | History scroll trigger: button vs infinite scroll | button ("Load older") — explicit; no JS hook complexity |
| P5-D8 | Pagination cursor: by `inserted_at` or `id` | `inserted_at` (id+0 isn't guaranteed monotonic across nodes; inserted_at is the canonical time order) |

## PR plan (5 PRs)

| PR | Files | LOC est |
|---|---|---|
| 1 | WorkspaceDetailLive + add-template form + Ezagent.Workspace facade unchanged | ~250 |
| 2 | UsersLive new + Ezagent.Users disable/grant + Phase 4 hooks | ~350 |
| 3 | SnapshotsLive + mix ezagent.snapshot.{list,dump,clear} + KindSnapshot.list_all/0 | ~300 |
| 4 | RoutingAdmin Kind + Behavior + cap wiring + RoutingLive cap-gated dispatch | ~400 |
| 5 | MessageStore.older_than/3 + LV "Load older" button + tests | ~200 |

Total ~1,500 LOC. Each PR has an invariant test + admin merge after green.

## Invariant tests

Per memory `feedback_completion_requires_invariant_test`:

- PR 1: Workspace LV add-template → GenericSession Class fires → Session spawned (via TemplateRegistry roundtrip)
- PR 2: Non-admin User logs in → /admin/users hidden (cap-deny) → admin sees user list
- PR 3: Snapshot from previous session restored visible in LV view; mix ezagent.snapshot.clear --uri X removes row
- PR 4: Non-RoutingAdmin user calls RuleStore.add via dispatch → :unauthorized; admin succeeds
- PR 5: send 100 messages → "Load older" reveals msgs 51-100 in correct order; second click reveals 1-50; no duplicates

## What's NOT in Phase 5

- Federation (Decision #48 deferred)
- BEAM hot-load runtime plugin install (Allen flagged in PR 7 chat; Phase 7+ realistically)
- Visual matcher tree builder (PR 7 JSON mode is acceptable for v1)
- Multi-user audit-row filtering (Phase 6+)
- Heartbeat / partition handling (Phase 7+ production reliability)
- ETS-cached Session state (perf optimization; Phase 7+)
