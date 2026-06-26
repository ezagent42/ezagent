# Dev-Together Cycle Data — 2026-06-25 (ezagent42/ezagent)

Git window: `65da2c05..bbb575d5 (origin/main)` · **38 PRs** · **30,798 LOC** (add+del) · 28,731 add / 2,067 del

**PR kind:** 18 capability · 17 planning/docs · 2 fix · 1 test. The review focus is **delivered capability**, so the capability count — not raw PR count — is the headline.

> **Metric note — read first.** `lead_time` = `merged_at − earliest author.date` = **lead time (first commit → merge)**, which *includes* review/idle time — **not** hours-of-coding. We use `author.date`, not `committer.date`: squash-merge rewrites `committer.date` to the merge instant (e.g. PR #989's 13 commits all stamped `10:15:12Z` while author.date spans `07:02→09:54Z`), collapsing lead-time to ~0. Both fields are kept per-PR in the JSON for audit.

> **Lead-time UNDERSTATES activity (empirical).** Under this repo's squash workflow, per-PR lead-time is near-zero, so each dev's *summed* lead-time is **less than** their `wall_clock_span` (verified: every dev row has summed < wall-clock — it does NOT overlap-and-exceed). Treat `wall_clock_span` (earliest author.date → latest merge for that dev) as the better single-dev activity signal; summed lead-time is a floor, not a measure of effort.

> **Attribution:** PR author login = developer, **including that developer's managed Claude/CC agents** (per the cycle rule). No bot/`codex` author logins appeared.

> **Excluding the 2 stale PRs (#963, #982) changes lead-time totals only** — it does NOT change PR-count ranking or the merge-hour histogram (both stale PRs still merged in-cycle).

## Cycle totals

| Metric | Value |
|---|---|
| Total PRs | 38 (capability 18 / planning 17 / fix 2 / test 1) |
| Total LOC (add+del) | 30,798 |
| Summed lead-time, raw / excl-stale | 95.78 h / 34.9 h |
| Stale-base PRs (branch predates cycle) | #963, #982 |
| Busiest merge windows (KST) | 2026-06-25 11:00 KST (4), 2026-06-25 17:00 KST (3), 2026-06-25 18:00 KST (3), 2026-06-25 20:00 KST (3), 2026-06-26 02:00 KST (3) |

## Per-developer (sorted by PR count)

| Dev | PRs | Capability | Plan/Fix/Test | LOC | Lead sum raw (excl-stale) | Median lead | Wall-clock span |
|---|--:|--:|--:|--:|--:|--:|--:|
| allenwoods | 32 | 15 | 15/1/1 | 24,902 | 21.77 (21.77) h | 0.19 h | 22.56 h |
| zyli-developer | 2 | 1 | 1/0/0 | 1,796 | 4.63 (4.63) h | 2.31 h | 7.95 h |
| gagameow | 2 | 1 | 1/0/0 | 1,638 | 8.5 (8.5) h | 4.25 h | 8.7 h |
| jjkysy | 1 | 0 | 0/1/0 | 15 | 11.19 (0) h | 11.19 ⚠️ h | 11.19 ⚠️ h |
| zhaomaota97 | 1 | 1 | 0/0/0 | 2,447 | 49.69 (0) h | 49.69 ⚠️ h | 49.69 ⚠️ h |

⚠️ = dev's only PR is stale-base (branch predates cycle); its median and wall-clock reflect branch age, not cycle effort. See caveats.

## Per-developer feature points

### allenwoods — 32 PR(s): 15 capability, 15 plan/docs, 1 fix, 1 test

- #971: Plan: finalize agent-runtime consolidation scope (A+B+C streams)
- #972: Plan: A/B/C parallel dev handoffs + agent-console contract
- #973: Plan: zyli e2e-scenario task + zyli/gaga dispatch prompts
- #974: Plan: dispatch prompts + clarify-principle correction
- #976: Spec: agent flavor+config unification (stream A)
- #977: Refactor: route hello/protocol_api/world liveness+spawn through LocalRuntime (#99 C)
- #978: Spec: finalize stream-A post adversarial review
- #979: Plan: stream-A implementation plan rev2 + handoff
- #980: Feature: register template flavor hook (A1)
- #983: Todo: role-materialization foundation + kanban-as-role follow-ups
- #984: Spec: role-materialization foundation design (per-instance mount + role recipes)
- #986: Handoff: kanban heads-up for jjkysy (re-scheme + role-foundation dependency)
- #987: Spec: role-foundation rev2 (runtime mount/detach)
- #988: Plan: role-foundation implementation plan RF-1..RF-8
- #989: Feature: unify sidecars on erlexec OsProcess + AST gate (no orphans) — subtask B
- #991: Research: cross-workspace session join findings + todo
- #992: Feature: flavor+config unification A2–A7 (registry→domain.agent, behaviors registry-derived, config API/schema, create-config ingest)
- #993: Plan: role-foundation rev2 (generalized keystone)
- #995: Feature: RF-1 per-instance behavior resolution + slice-filter generalization (role-foundation keystone)
- #997: Test: de-flake 3 CI test-isolation/timing flakes (workspace/feishu/session)
- #998: Feature: RF-4 roles/0 plugin callback + RoleRegistry (code-seed)
- #999: Feature: RF-8 native flavor + its CapMint cap-policy
- #1000: Feature: RF-6 passive-actor isolation (non-principal data actors)
- #1001: Feature: RF-5a role-driven create (direct-spawn) + durable passive persistence
- #1002: Feature: RF-7 list-by-role read model (snapshot-sourced, cold-restart-safe)
- #1003: Feature: RF-2+RF-3 runtime per-instance behavior mount + detach on a live Kind
- #1004: Feature: kanban-as-role K1-K3 — recipe + native per-instance dispatch + create path
- #1005: Feature: RF-9 register OrchestratorRole via roles/0 + unify Compose path
- #1006: Fix: heal Kind-death race raising (EXIT) :noproc in deliver_to_ready
- #1007: Feature: kanban-as-role K4+K5 — world rewire + resource-only gate + retire Kanban Kind
- #1008: Docs: py-agent spec(rev3)+plan(rev2) + 2026-06-25 cycle closeout
- #1009: Feature: py-agent Phase 1 — file-channel + py flavor (Tasks 1.1-1.5)

### zyli-developer — 2 PR(s): 1 capability, 1 plan/docs, 0 fix, 0 test

- #975: Feature: operator UI to bind a Feishu chat to a session (external mirror) — F9
- #990: Docs/e2e: full-flow human E2E execution-record system + cc-create bug confirmation

### gagameow — 2 PR(s): 1 capability, 1 plan/docs, 0 fix, 0 test

- #981: Analysis: agent-console M1-M4 design + config_schema/0 callback note
- #994: Feature: agent console M1-M4 (world UI)

### jjkysy — 1 PR(s): 0 capability, 0 plan/docs, 1 fix, 0 test

- #963: Fix: dev watcher runs vite directly to kill orphan :5173 port-conflict error

### zhaomaota97 — 1 PR(s): 1 capability, 0 plan/docs, 0 fix, 0 test

- #982: Feature: AI page generator on public preview — pure-shadcn render, collab whiteboard, incremental edits

## By-PR table (all 38)

| # | Author | Kind | Lead (h) | LOC | Files | Merged (KST) | Feature point |
|--:|---|---|--:|--:|--:|---|---|
| 963 | jjkysy | fix | 11.19 ⚠️stale | 15 | 1 | 2026-06-25 11:18 | Fix: dev watcher runs vite directly to kill orphan :5173 port-conflict error |
| 971 | allenwoods | planning | 0.11 | 65 | 3 | 2026-06-25 11:12 | Plan: finalize agent-runtime consolidation scope (A+B+C streams) |
| 972 | allenwoods | planning | 0.1 | 197 | 5 | 2026-06-25 11:25 | Plan: A/B/C parallel dev handoffs + agent-console contract |
| 973 | allenwoods | planning | 0.1 | 87 | 4 | 2026-06-25 11:34 | Plan: zyli e2e-scenario task + zyli/gaga dispatch prompts |
| 974 | allenwoods | planning | 0.12 | 60 | 3 | 2026-06-25 12:03 | Plan: dispatch prompts + clarify-principle correction |
| 975 | zyli-developer | capability | 3.86 | 612 | 16 | 2026-06-25 16:06 | Feature: operator UI to bind a Feishu chat to a session (external mirror) — F9 |
| 976 | allenwoods | planning | 0.16 | 72 | 2 | 2026-06-25 12:49 | Spec: agent flavor+config unification (stream A) |
| 977 | allenwoods | capability | 2.81 | 429 | 11 | 2026-06-25 15:52 | Refactor: route hello/protocol_api/world liveness+spawn through LocalRuntime (#99 C) |
| 978 | allenwoods | planning | 0.1 | 135 | 2 | 2026-06-25 15:50 | Spec: finalize stream-A post adversarial review |
| 979 | allenwoods | planning | 0.11 | 142 | 2 | 2026-06-25 16:08 | Plan: stream-A implementation plan rev2 + handoff |
| 980 | allenwoods | capability | 0.48 | 251 | 10 | 2026-06-25 17:25 | Feature: register template flavor hook (A1) |
| 981 | gagameow | planning | 1.25 | 966 | 2 | 2026-06-25 17:33 | Analysis: agent-console M1-M4 design + config_schema/0 callback note |
| 982 | zhaomaota97 | capability | 49.69 ⚠️stale | 2,447 | 23 | 2026-06-25 22:13 | Feature: AI page generator on public preview — pure-shadcn render, collab whiteboard, incremental edits |
| 983 | allenwoods | planning | 0.11 | 22 | 1 | 2026-06-25 17:43 | Todo: role-materialization foundation + kanban-as-role follow-ups |
| 984 | allenwoods | planning | 0.1 | 57 | 1 | 2026-06-25 18:14 | Spec: role-materialization foundation design (per-instance mount + role recipes) |
| 986 | allenwoods | planning | 0.47 | 36 | 1 | 2026-06-25 18:44 | Handoff: kanban heads-up for jjkysy (re-scheme + role-foundation dependency) |
| 987 | allenwoods | planning | 0.14 | 122 | 1 | 2026-06-25 18:44 | Spec: role-foundation rev2 (runtime mount/detach) |
| 988 | allenwoods | planning | 0.11 | 57 | 1 | 2026-06-25 19:05 | Plan: role-foundation implementation plan RF-1..RF-8 |
| 989 | allenwoods | capability | 3.32 | 2,758 | 25 | 2026-06-25 19:21 | Feature: unify sidecars on erlexec OsProcess + AST gate (no orphans) — subtask B |
| 990 | zyli-developer | planning | 0.77 | 1,184 | 43 | 2026-06-25 20:11 | Docs/e2e: full-flow human E2E execution-record system + cc-create bug confirmation |
| 991 | allenwoods | planning | 0.1 | 142 | 2 | 2026-06-25 20:20 | Research: cross-workspace session join findings + todo |
| 992 | allenwoods | capability | 2.37 | 1,576 | 58 | 2026-06-25 20:35 | Feature: flavor+config unification A2–A7 (registry→domain.agent, behaviors registry-derived, config API/schema, create-config ingest) |
| 993 | allenwoods | planning | 0.77 | 98 | 1 | 2026-06-25 21:24 | Plan: role-foundation rev2 (generalized keystone) |
| 994 | gagameow | capability | 7.25 | 672 | 13 | 2026-06-26 01:00 | Feature: agent console M1-M4 (world UI) |
| 995 | allenwoods | capability | 2.84 | 309 | 7 | 2026-06-26 01:17 | Feature: RF-1 per-instance behavior resolution + slice-filter generalization (role-foundation keystone) |
| 997 | allenwoods | test | 0.85 | 154 | 3 | 2026-06-26 00:51 | Test: de-flake 3 CI test-isolation/timing flakes (workspace/feishu/session) |
| 998 | allenwoods | capability | 0.69 | 1,857 | 8 | 2026-06-26 02:02 | Feature: RF-4 roles/0 plugin callback + RoleRegistry (code-seed) |
| 999 | allenwoods | capability | 0.12 | 563 | 10 | 2026-06-26 02:46 | Feature: RF-8 native flavor + its CapMint cap-policy |
| 1000 | allenwoods | capability | 0.22 | 460 | 13 | 2026-06-26 02:56 | Feature: RF-6 passive-actor isolation (non-principal data actors) |
| 1001 | allenwoods | capability | 0.14 | 767 | 12 | 2026-06-26 03:47 | Feature: RF-5a role-driven create (direct-spawn) + durable passive persistence |
| 1002 | allenwoods | capability | 0.13 | 653 | 14 | 2026-06-26 04:22 | Feature: RF-7 list-by-role read model (snapshot-sourced, cold-restart-safe) |
| 1003 | allenwoods | capability | 0.24 | 1,036 | 10 | 2026-06-26 05:14 | Feature: RF-2+RF-3 runtime per-instance behavior mount + detach on a live Kind |
| 1004 | allenwoods | capability | 1.6 | 3,942 | 28 | 2026-06-26 06:45 | Feature: kanban-as-role K1-K3 — recipe + native per-instance dispatch + create path |
| 1005 | allenwoods | capability | 1.29 | 175 | 5 | 2026-06-26 06:38 | Feature: RF-9 register OrchestratorRole via roles/0 + unify Compose path |
| 1006 | allenwoods | fix | 0.68 | 274 | 2 | 2026-06-26 06:28 | Fix: heal Kind-death race raising (EXIT) :noproc in deliver_to_ready |
| 1007 | allenwoods | capability | 0.54 | 5,736 | 29 | 2026-06-26 08:07 | Feature: kanban-as-role K4+K5 — world rewire + resource-only gate + retire Kanban Kind |
| 1008 | allenwoods | planning | 0.01 | 584 | 3 | 2026-06-26 08:12 | Docs: py-agent spec(rev3)+plan(rev2) + 2026-06-25 cycle closeout |
| 1009 | allenwoods | capability | 0.84 | 2,086 | 20 | 2026-06-26 09:39 | Feature: py-agent Phase 1 — file-channel + py flavor (Tasks 1.1-1.5) |

## Caveats

- **Stale-base PRs (#963 jjkysy, #982 zhaomaota97):** earliest author.date predates the cycle floor (2026-06-25 00:00Z). Their lead-time (11.2 h / 49.7 h) reflects **branch age**, not cycle effort. Each is that dev's *only* PR, so both that dev's median **and** wall-clock span are distorted (flagged ⚠️ in the per-dev table). Counted in raw totals, excluded from `excl-stale`.
- **`jjkysy`** is a 5th contributor (1 PR, #963) beyond the four primary devs; author-login attribution applies as normal.
- **Capability vs planning:** 'Feature point count' is split by PR kind. Capability = `Feature`/`Refactor` PRs that ship a runtime capability; planning = Spec/Plan/Docs/Handoff/Todo/Research/Analysis (no shipped capability). A team-facing 'delivered' tally should use the **capability** column, not raw PR count.
- **One non-PR direct push** (`ae6420fc`, allenwoods, `docs(together): agent runtime situation analysis handoff`) is in the git range but has no PR, so it is **excluded** from the 38-PR table (explains the 38-PR vs 39-commit gap).
- **Lead-time ≠ effort, and understates it.** Most PRs show ~0.1–0.2 h lead-time because branches were authored and squash-merged in rapid succession; per-dev summed lead-time is below wall-clock span for all devs. Use wall-clock span as the activity signal.
- All `gh` fields were present for all 38 PRs; no missing `mergedAt`/`author.date`/LOC fields, no negative lead-times.