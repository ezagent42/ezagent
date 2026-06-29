# 2026-06-29 — State snapshot: create-socialware skill gap, FatNine prior work, leak-gate gap, kanban #1020, ruihua 官网-demo inputs

> Read-only investigation. Author: Claude (investigation agent). Worktree `docs/skill-gates-state` off `origin/main` (tip `5d2b5d0d`).
> Scope: equip today's three owner tracks (FatNine skill+gates, jjkysy kanban #1020, ruihua 官网 demo) with verified current state + premise corrections.

## Premise corrections (read first)

The dispatch prompt carried several premises that do **not** hold against the tree. These reshape the three owners' tasks:

1. **"create-socialware/agent skill is missing" is NOT a gap.** `ezagent-socialware/SKILL.md` IS the authoring/creation guide (both world-UI path A and primitive/code path B, lines 100-168). The `socialware-creator-agent-config` task was deliberately narrowed *away* from a separate creator product (`docs/together/2026-06-23/plan.md:30`). FatNine's "complete the create-socialware skill" framing needs re-scope — see §1.
2. **PR #84 is NOT FatNine's Agent Console CRUD.** #84 is Allen's "spec(phase-7) DRAFT v1" (merged 2026-05-18). FatNine's CRUD PR is **#958** (closed, integrated). See §2.
3. **`no_customer_concept` / `no_role_concept_in_core` tests DO NOT EXIST.** Grep across `test/`+`apps/` = zero hits. The only leak gate today is NP-2 module-NAME lint, which omits business words. See §3.
4. **"B3 = MERGE-quality, scenarios reusable" wording is not verifiable** from any durable source. A B3 verdict section exists (`docs/together/2026-06-29/notes/0629-status-snapshot.md`) + a Feishu "复查完成" reply (06-29 09:21), but the snapshot frames it as a deferred to-do, not a positive MERGE call. See §4.
5. **"kanban 相当于是第一个最完整的 socialware" exact quote not found.** Docs attribute "first demo socialware vertical" to **advisor**; kanban is the *most complete* (K1..K5 完整) but not labeled "first" in docs. See §4.

---

## 1. create-socialware skill gap — what FatNine actually builds

### What exists (the skills inventory, 25 SKILL.md files)

Three ezagent-specific skills live under `.claude/skills/`:

- `ezagent-developer/SKILL.md` (136 lines) — codebase invariants, anti-patterns, contributor recipes, CapBAC. **Contains agent-extension guidance folded in by #1040** as `references/extending-agents.md` (6989 bytes, "Extending agents without violating the architecture") + plugin-authoring invariant 8 + how-to recipes ("add a new plugin/Kind/Behavior/Template Class"). The thrust: **don't create a new agent Kind; declare a role recipe on an existing flavor** (cc/codex/native), copying the kanban-manager + native-flavor precedents.
- `ezagent-socialware/SKILL.md` (280 lines) — **the socialware authoring guide**. Frontmatter triggers on "creating, configuring, or reasoning about a SOCIALWARE app." Central thesis (lines 44-66): the author's job is (1) author a `public_view` SessionTemplate, (2) instantiate a live session, (3) share the link. §"The author flow" (lines 100-168) gives two equivalent paths:
  - **Path A — world UI (productized):** Session templates panel → "Public socialware app" checkbox → `workspace.template.save` → `SessionTemplate.create/3`; then "New session" → `session.create`; share `/socialware/chat?session_uri=…`. Includes the `"current"`-tag versioning gotcha (lines 123-135).
  - **Path B — primitives (code/tests/CLI):** `persist_version_as_system/2` + `Kind.spawn` + `system_set_working_copy/2`, plus `mix ezagent.workspace.add_template` CLI.
- `ezagent-session-orchestrator/SKILL.md` — running as a CC orchestrator agent inside a session.

**No standalone `agent-extension`, `create-agent`, or `create-socialware` skill directory exists.** #1040 merged agent-extension guidance into `ezagent-developer` (confirmed at `docs/together/2026-06-26/notes/2026-06-26-weekend-session-process.md:16`, `docs/together/2026-06-28/review.md:54`).

### The real gap (re-scoped for FatNine)

There is **no missing authoring skill** — the gap is at the **arch-gate** level, not the skill level. FatNine's "complete the create-socialware skill + add detection gates" should be re-scoped to:

- **Skill side (small):** verify `ezagent-socialware/SKILL.md` author flow still matches post-#1069 (socialware) + #1072 (taxonomy) shifts; patch any drift in the Path-A world-UI steps (the `"current"`-tag auto-publish + customer-surface-subsumption are flagged as open usability gaps at lines 216-218, 268-272 — these are code gaps, not doc gaps).
- **Gates side (the real work):** implement the §6 arch-gates from the taxonomy SPEC — see §3. This is where FatNine's F1–F7 silent-failure findings (§2) feed directly: a "backend-correct / UI-silent" detection gate is the same no-silent-leak philosophy.

---

## 2. FatNine prior work + open PR #1027

### FatNine identity & track

GitHub `FatNine` = 戴明 (Dai Ming). `docs/together/team.md` roster row. `docs/together/2026-06-28/review.html` next-track: **"（待 Allen 派发；后端/core 面支持内测 bug triage）"** — no active W27 assignment; bug-triage reserve for FP2 (internal testing). `2026-06-29/plan.html` line: "gaga / fatnine: FP2 内测出 bug 后按面派发".

### Agent-console work history (the #84 series — #84 is the original brainstorm task, not a PR)

- **#892** (CLOSED, lead-squash `798f46bd` 2026-06-22) — "Agent Console (#84) Phase-0 设计确认 demo + Manage-gate 授权协议提案". Static self-contained demo `apps/ezagent_web/priv/static/agent-console-demo/index.html`; four-quadrant IA; Manage-gate authority matrix. Return: `docs/together/2026-06-22/returns/agent-console.md` (late).
- **#905** (MERGED 2026-06-23) — "world agent 创建/配置/详情页 → 适配 agent-contract (MVP, 0 core/domain 改动)". The create/read/detail base.
- **#918** (CLOSED) — "echo→Entity.Agent + soul 进 create (agent-contract 后端切片, #905 的后端落地)".
- **#958** (CLOSED 2026-06-24, not merged) — "Agent Console CRUD — world agent 增/查/改/删 (#84; 基于 #905, 接 #938 facade)". **This is the actual CRUD PR.** Added Update (config editor sub-route `/identities/agents/:uri/config` → `AgentConfig.read_cascade/4` → `apply_delta`/`delete_path`) + Delete (`agents.delete` → `Manage.:delete` + manage-cap + bound-session block via `agent_live_sessions/1` + two-step confirm) + fixed a Read bug (detail `Phase` "unknown" for live agents). Extracted agent dispatch into `Ezagent.World.AgentActions`, bringing `world_live.ex` 1087→784 LOC (under the 1000-LOC cap). Key files: `apps/ezagent_plugin_world/lib/ezagent/world/agent_actions.ex` (+381), `apps/ezagent_plugin_world/assets/src/components/Identities.tsx` (+297/-4), 6 new test files. Evidence: `docs/together/2026-06-24/evidence/agent-console-crud/{01,02,03}.png`.
- **#1027** (OPEN, this PR) — the QA findings report.

### PR #1027 — `qa/agent-console-findings-0626`

- **State:** OPEN, 0 reviews, no labels, 12 files (docs only, 0 code). Branch `qa/agent-console-findings-0626` → `main`. Findings doc: `docs/together/2026-06-26/agent-console-qa-findings.md` (+65) + `manual-tests/agent-console-manual-test-plan.md` (+167) + 10 evidence PNGs.
- **Method:** browser manual + Playwright, lifecycle create→find→view→use(join)→modify→delete→post-delete. Baseline `6f123b8b`. Verdict: trunk functionally usable; 7 issues; **F3/F4/F7 are silent-failure / dead-end class — recommended priority.**

| # | Sev | Summary |
|---|---|---|
| **F3** | High | New-session default template `advisor` is invalid (`:invalid_template`); create failure **silently swallowed by UI** (no banner). `default` works. Root cause: dropdown offers unregistered `advisor` as default (valid is `default`, `conversation_actions.ex:64`); `session.create` failure pushes no error banner (contrast: `agents.create` failure *does*). |
| F4 | Med-high | Deleting an in-use agent from the **detail page**: backend correctly blocks (`agent_live_sessions/1`), but the delete-blocked banner routes to the **agents-list** `action_error` — invisible on the detail page. Silent. |
| F7 | Med-high | **No remove-member / delete-session control on the conversation page** → F4's "remove from session first" cannot be followed in UI. An agent in any live session **cannot be deleted via UI at all**. Amplifies F4. |
| F6 | Med | py flavor: required `script` field not marked `*`/not client-validated; submit returns bare atom `:missing_script` (other create errors translated to Chinese). |
| F1 | Low-med | agents list has no flavor filter (`AgentsTable` `Identities.tsx:238` doesn't wire `FilterBar` which exists at `:184`). |
| F2 | Low-med | After delete, deep-linking old `/identities/agents/<uri>` renders a shell detail page (`Phase: not_found`, config `nil`) — no clear empty state. |
| F5 | Low/cosmetic | Entity Caps `instance` column dumps raw `%URI{...}` struct instead of canonical `entity://system/agent/qa-browser-1` string. |

PR is **report-only, does not fix**; each finding has a fix recommendation.

### F-numbering collision warning

Three F-schemes exist — don't conflate: (1) FatNine's QA F1–F7 (above, console-lifecycle); (2) product-gap F-numbering in `docs/together/2026-06-24/evidence/blockers.md` + `returns/zyli-fullflow-validation-0624.md` (F3,F9,F10,F12,F14,F19–F24 — different findings, overlapping numbers); (3) comms "F7 session 治理" = comms-unify F7-PR-A/B (already completed, tasks #117/#118). Disambiguate when saying "F7".

### What FatNine carries forward today

F3/F4/F7 are textbook "backend-correct / UI-silent" failures — the same no-silent-leak philosophy a detection gate enforces. **F3 is the most directly socialware-relevant**: the socialware author flow (`ezagent-socialware` Path-A) runs straight through `session.create`; if that fails silently (as F3 shows for `advisor`), the author gets no signal. So FatNine's agent-console findings are **directly reusable as a leak-gate spec** — a gate that asserts "backend rejected → UI must surface" (no silent swallow) and "session membership is mutable/closable" (F7's missing remove-member control).

---

## 3. Detection-gate current state + the leak-gate gap (FatNine's "add detection gates" task)

### What EXISTS today

Two gate suites:

**`mix ezagent.arch.scan`** — `apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex`. Fitness-function counters (oversized modules, spawn registry chokepoints, duplicated fns, cc-bridge shim callers, raw_home_path, raw_port_spawn_executable AST gate, etc.). Baseline caps in `apps/ezagent_core/test/architecture/arch_baseline_manifest.exs`. **No business-vocabulary scanning.**

**`mix ezagent.check_invariants`** — `apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.ex`. 8 source-grep invariants (#1–#4, #6, #7, #9, #10; #5/#8 deferred): no bare PubSub.broadcast, only Kind.Server defines init/1, not_ready fail-fast, no bare Registry.register, audit.ex no direct SQL, DLQ declares :unroutable, no :stub_grant, Capability.matches? present. **None check business words.**

**`mix ezagent.check_invariants.lifecycle`** — `apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.lifecycle.ex`. 8 Phase-C HARD gates. **The only leak gate today is `gate_layer_vocab_lint` (NP-2, line 303)** — a module-NAME lint:
- Word list `@layer_vocab_words ~w(Agent Session Orchestrator Workspace Worker Feishu Cc Codex Np Curl)` (line 68) — **business words absent** (`Kanban/Board/Task/Sales/Customer/Autoservice` not in list).
- Scans `apps/ezagent_core/lib/**/*.ex` `defmodule` names only (line 307-316, anchors on `^defmodule`). **Name-level, never scans source/comment content.**
- Allowlist `@layer_vocab_allowlist` (line 79-120) for legitimate registries/indexes.

### What DOES NOT EXIST (corrects prompt premise)

- `no_customer_concept` test — grep `test/`+`apps/` = **zero hits**.
- `no_role_concept_in_core` test — grep = **zero hits**.
- Any business-word content grep / concept-leak detection — **no detection code**, only prose mentions (`lifecycle.ex:14` moduledoc, `2026-05-29-lifecycle-hooks-design.md:641`, `2026-05-28-router-behavior-kind-architecture.md:61`).

### SPEC #1072 §6 — proposed arch-gates (design doc, NOT impl)

SPEC: `docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md` (693 lines, commit `4c62e96f`, "Defines the 4 carrier layers… arch-gate ideas… §8 codex verdict pending"). §6 "Optional arch-gate ideas" (lines 504-573) proposes four gates — **all proposals, none implemented**:

| § | Proposed gate | Catches | Code today |
|---|---|---|---|
| 6.1 | **NP-2 EXTEND**: (a) add business words `Kanban Board Task Sales Customer Autoservice` to `@layer_vocab_words`; (b) add a **content-level** grep over `apps/ezagent_core/lib/**/*.ex` for `salesperson/customer_service/autoservice/board_config` outside a comment allowlist | anti-pattern 4.4 (business words in core) | Base NP-2 name-lint exists (`lifecycle.ex:303`) but **words not added + no content grep** |
| 6.2 | **New-Kind gate**: fail if a new `defmodule Ezagent.Entity.<X>` (or `Ezagent.Resource.<X>`) Kind appears outside sanctioned domain apps without an invariant-test justification | 4.1 (kanban-as-new-Kind) | **NOT implemented.** The cited `arch.scan.ex:335-352` seam is stale (now `raw_port_spawn_executable`); no `defmodule Ezagent.Entity.<X>` predicate exists |
| 6.3 | **Blob-inline gate**: fail if a migration in `apps/**/priv/repo/migrations/` adds a `:binary`/BLOB column named `data`/`bytes`/`blob`/`content` on an attachments/uploads table (scoped, not all `:binary`) | 4.5 (blob inline in Postgres) | **NOT implemented** |
| 6.4 | **Plugin-package manifest gate** (future, contingent on §2): assert every plugin package manifest separates `code` (layer 1) from `seed_definitions` (layer 2 data) | inline-business-defs-into-code | **NOT implemented** (plugin-package work = task #145, in flight) |

### The GAP — what FatNine builds

A "business-concept-leak detection gate" extending §6.1, scoped to **core/base = `apps/ezagent_core/lib/**/*.ex`** (the scope NP-2 already uses). Two prongs:

1. **Name-level extension (cheap, modify `lifecycle.ex:68`):** add `Kanban Board Task Sales Customer Autoservice` to `@layer_vocab_words`; extend `@layer_vocab_allowlist` (line 79) for legitimate registries. Fails a future `defmodule Ezagent.SalesPipeline` in core.
2. **Content-level grep gate (new — NP-2 is name-only; SPEC §6.1 lines 523-531 explicitly calls this out):** fail if `apps/ezagent_core/lib/**/*.ex` source lines contain business-logic words (`salesperson`, `customer_service`, `autoservice`, `board_config`, and arguably bare `customer`/`kanban` outside substrate-naming contexts) **outside a comment allowlist**. The allowlist is mandatory — SPEC §4.4 documents legitimate comment-level refs (`role_seed_hook.ex:16` "kanban plugin declares roles/0", `sandbox.ex:57-58` kanban-manager class, `arch.scan.ex:335-340`) and legitimate substrate uses (`socialware` table names, `customer feed`/`customer-delivery` route comments in `message_store.ex`).

**Verified live leaks (per SPEC §4.4 citations):** business words DO appear in `apps/ezagent_core/lib/` at comment level — `customer` in `message.ex:130`, `message_store.ex:86,182,184,185,210,215,258,266`, `plugin.ex:166`, `uploads/download_token.ex:9,36`, `kind/deferred_dispatch.ex:13`, `check_invariants.ex:100`. The visibility atoms `:customer_visible`/`:operator_only` are already gone (renamed to `:external_visible`/`:internal`). **No `defmodule`-level business concepts in core** (no `Ezagent.Kanban`, no `Ezagent.Sales`) — NP-2's name lint would catch those if the words were added.

**Mechanical pieces to reuse:** `lib_files/0` (`arch.scan.ex:377`), `grep/2` with `# arch-allow:` suppression (`arch.scan.ex:401-411`), `arch_baseline_manifest.exs` cap mechanism, `@layer_vocab_allowlist` pattern (`lifecycle.ex:79`). The gate can live as a new `arch.scan` counter (entry in `do_measure/0`, lines 279-318) or a new `check_invariants.*` gate. Missing = the business-word list + content-scan predicate + allowlist.

**FatNine's F1–F7 bridge:** the same no-silent-leak philosophy. F3 (silent `session.create` failure), F4 (silent delete-block), F7 (no UI path to correct backend op) are the runtime-behavior analog of the static business-word leak — both are "the system silently allows a wrong state." A detection-gate program naturally subsumes both.

---

## 4. jjkysy #1020 kanban — reframe + today's E2E task

### PR #1020 state

- **Title:** `feat(kanban): 穿起团队开发全流程(分 Phase 实施 + SPEC/真相源/计划)`. Author `jjkysy` (姚升悦). **State: OPEN**, `mergedAt: null`, 92 files, branch `feat/kanban-agent-e2e` → `main`.
- **Mergeability:** `mergeable: MERGEABLE` but `mergeStateStatus: BEHIND` (needs rebase — main advanced through weekend's #1069/#1071/#1075/#1076) + `reviewDecision: REVIEW_REQUIRED` with **0 GitHub reviews** (the B3 verdict is a Feishu/docs signal, not a PR review).
- **Adds 3 umbrella apps:** `apps/ezagent_plugin_kanban/**`, `apps/ezagent_plugin_github/**`, `apps/ezagent_plugin_dev_together/**` + `.claude/skills/{kanban-on-ezagent,kanban-off-ezagent,pm-coordinator}/**` + world UI wiring (`Kanban.tsx`, `Conversation.tsx`, `main.tsx`) + domain_agent seeds.

### B3 review verdict — premise correction

The "B3 = MERGE-quality, scenarios reusable" wording is **not in any durable source**. The B3 section lives in `docs/together/2026-06-29/notes/0629-status-snapshot.md` (referenced from `2026-06-29/plan.html:184`). It frames the review as **deferred all weekend** pending socialware landing, with the to-do: "re-run kanban E2E scenarios on fresh post-socialware stack; if aligned → merge #1020 + 2 minor follow-ups; if drifted → file drift as bug, fix, then merge." A Feishu "B3 #1020 kanban e2e 复查完成" reply was sent 06-29 09:21 (`channel-server.err.log:158036`), but the verdict body is not preserved in readable logs. **Net: a B3 verdict exists and was announced, but the positive-MERGE wording is unverified; the snapshot frames it as conditional.**

### Is kanban "the first complete socialware"?

**Kanban is the most full-stack socialware in the repo.** All kanban code lives on branch `pr-1020` (none on `main` yet — only `docs/together/2026-06-25/handoffs/jjkysy-kanban-heads_up.md` is on main). Components (read via `git show pr-1020:<path>`):

- **Recipe (kanban-manager) + 9-stage data (LAYER-2 data, not hardcoded):** `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:94-123` — `stages: [:positioning, :metric, :pain, :anchor, :ux, :feature, :issue, :test, :pr]`, `ci_stage: :pr`. Behavior reads it via `Shared.stages/1`.
- **Generic board Behavior (no stage names in code — the #1075 de-bake):** `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex` — 24 actions (`add_node`, `claim_node`, `set_status`, `register_pr`, …), per-node owner authz, `:unassigned|:claimed|:doing|:done` state machine.
- **Relay routing (zero core changes):** `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban/relay_routing.ex` — seeds core `Routing.Matcher` rule `{:and, [in_session(session_uri), text_contains("[kanban:<event>]")]} → [receiver]`. Prod path uses Orchestrator's `define_rule_set_rule` MCP tool.
- **pm-coordinator role:** `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/pm_coordinator_seed.ex` + `.claude/skills/pm-coordinator/SKILL.md` — "the COORDINATOR 职位 — a cc 大脑 driving the 9-stage team dev flow (judging each gate, helping edit, prompting for gaps, routing work by role)". 9 stages: 定位→北极星→痛点→认领→线框→功能卡→issue→测试→PR.
- **dev-together role:** `apps/ezagent_plugin_dev_together/` — covers stages ⑦⑧⑨ (issue→test→PR).
- **github plugin integration (dispatch-only, no cross-plugin直调):** `apps/ezagent_plugin_github/lib/ezagent/behavior/github.ex` — per-identity token (T8), `pr_sync.ex` auto-registers PRs to kanban nodes every 30s. The old `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/github.ex` was DELETED (-131) — github I/O pulled out into the dispatch-only gateway.
- **Board config + skills:** `board_config.ex` (per-board `github_repo`/`miro_board`/`session_uri`), `.claude/skills/kanban-on-ezagent/` + `kanban-off-ezagent/` (on/off-platform parity).

**Comparison:** `advisor` is "the first demo socialware vertical" (`docs/superpowers/specs/2026-06-09-socialware-substrate-design.md:20`) — narrower (no 9-stage relay, no pm/dev-together roles, no github sync); `autoservice` is Tier-1 seed only; `customer` retired (`2026-06-28/review.html:197`); `hello`/`world`/`comms` lack the recipe+9-stage+pm+routing+github stack. So kanban = most complete; "first" label belongs to advisor in docs; kanban's "K1..K5 完整" milestone recorded at `channel-server.err.log:151522`.

### E2E state (confirmed)

- **Tracked (Resolver contract test):** `apps/ezagent_plugin_kanban/test/e2e/scenario_kanban_relay_routing_test.exs` (on pr-1020) — asserts at `Ezagent.Routing.Resolver.resolve/4` layer (not live GenServer): line 16-17 "真路由判定…对 relay 消息求解收件人，断言下一棒"; line 38 `alias Ezagent.Routing.{Resolver, RuleStore}`; line 105 `Resolver.resolve(msg, session, [], workspace_uri: @workspace)`.
- **Live E2E (docs/e2e screenshots, on pr-1020):** `docs/e2e/2026-06-26-kanban-phase1/` (plugins-kanban-entry, kanban-list, board-bind-session-control), `docs/e2e/2026-06-26-kanban-phase2-inbound/` (node creation, repo-config, session-bound, PR-artifact attach), `docs/e2e/2026-06-26-kanban-agent-dev-loop/round-2-live-ui/01-board-9stage-chain.png`, `docs/discuss/2026-06-26-kanban-flow-redesign/t7b-evidence/` (16 PNGs: login→plugins→kanban surface→board bind→pm member→pm @mention→real claude reply). **None on `main` yet** — lands with #1020.

### The "2 minor follow-ups"

Referenced in `2026-06-29/plan.html:73,76,134` + snapshot B3 + `2026-06-28/review.html:216`, but **scope NOT enumerated — pending Allen confirmation**. Best candidates from PR #1020's own "⚠️ 待 Allen 决策" + Phase 5: (1) `gh/3` cap 收窄 (kanban connectors use `admin_genesis` wildcard god-cap; dev-together already narrowed to caller-passthrough — "gh/3 该一并收窄…记 Decision/issue 跟 Allen 拍"); (2) Phase 5 ① delete obsolete `attach_code_file` action + reconcile B1 relay收口. These are PR-body candidates, not confirmed follow-ups.

### jjkysy's today task (FP5)

`2026-06-29/plan.html:75-77,133-136`: jjkysy currently **off / no active track**, assigned FP5 carry-in cleanup. Today:
1. **Rebase** `feat/kanban-agent-e2e` onto current `main` (resolve weekend socialware/recipe-rename shifts — #1075 kanban 9-stage code→data de-bake + #1071 recipe rename are exactly the shifts that could drift the branch).
2. **Re-run E2E** on fresh post-socialware stack — the Resolver contract test + live E2E screenshots — to confirm alignment (the re-run is load-bearing, not ceremonial, given #1075/#1071 shifted kanban's substrate).
3. **Get a GitHub review approval** (the B3 Feishu verdict exists but is not on the PR — GitHub still blocks REVIEW_REQUIRED with 0 reviews).
4. **Merge** #1020 (squash).
5. **Open 2 follow-up PRs** once Allen confirms scope.

`team.md:40`: jjkysy profile — "kanban 插件原作（#964 13.5k LOC）、dev-together skill owner."

---

## 5. ruihua 官网-demo inputs

### ruihua identity & track

GitHub `ruihuachen-designer` = 陈瑞华. `docs/together/team.md:23` roster: "designer | 产品经理 · 产品/设计版式、可外发文档版式输入（设计输入，不改代码）". `current_track`: "(no active track)". One dedicated handoff: `docs/together/2026-06-25/handoffs/ruihuachen-designer-review-plan-format.md` (design the dev-together review/plan 可外发版式).

### PR #1022 — `rh/world-lock-and-docs` (OPEN, not merged)

- **Title:** `chore(world): lockfile sync for excalidraw/xyflow/dagre + docs/rh`. Author `ruihuachen-designer`. **State: OPEN.** Because unmerged, **`docs/rh/` does NOT exist on `origin/main`** — all content below read via `gh api ?ref=rh/world-lock-and-docs`.
- Adds 40 files under `docs/rh/`: `homesite/` (官网 work) + `value-chain-kanban/` (方法论 work, 9 docs + 1 demo).

### ruihua's prior 官网 work (in PR #1022, not on main)

- **`docs/rh/homesite/demo/官网原型-全站-暗黑玻璃-v2.html`** (671 lines) — the active main-site mockup, "Have your customers at hello" narrative. Uses a **different skin** than the design system: `--cream:#fde7de; --coral:#ff677a; --blue:#0037fe; --ink:#0c0c14` (cream/coral/electric-blue on near-black), "liquid-glass" `backdrop-filter:blur(4px)`, `Instrument Serif`, SVG-noise grain, morphing clip-path shapes. **Conflicts with design-system rules** (DESIGN.md:144 rejects cream/sand body, gradients/noise; PRODUCT.md:25-30 lists cream/sand body as anti-reference).
- **`docs/rh/homesite/docs/M-主站文案-v1.md`** (302 lines) — the locked 官网主站 copy draft (U1–U7). Hero locked (rev3): EN "Don't build sites. Build a site that builds itself.", ZH "别再做网站 / 做一个会自己生成的网站", subtitle "AI 时代的网站，不用浏览." Slogan "Have your customers at hello." Rule: main sell = AI-native site that reshapes per customer; foundation ("地基白拿") is supporting evidence only.
- **`docs/rh/homesite/docs/08-ezagent价值-一句话讲给别人听.md`** — value pitch memo (multi-channel→multi-agent correction; socialware layer = door to external; "更便捷" = what you don't touch).
- **`docs/rh/homesite/demo/components/{01,02,03}-demo-*.html`** — 3 perspective components (定位树多角色视角, 指挥官驾照, 路线图押注).
- **`docs/rh/value-chain-kanban/demo/07-demo-接力链-多角色视角.html`** (454 lines) — relay-chain multi-role mockup (kanban/contributors-section interaction seed).

### Design system (`/Users/h2oslabs/Workspace/ezagent-design`, tip `ebce041`) — reusable assets

- **`styles.css`** + `tokens/*.css` (base/colors/effects/fonts/spacing/typography) — self-contained (Google Fonts CDN). Link one file, get full token set. Colors: `--ground #E8E8EB`, `--card #FFFFFF`, `--ink #17171B`, primaries red `#D81830`/墨蓝 `#0048A8`/黄 `#FFD400`/翠 `#0FA06E`, interactive cobalt `#0B5CFF`. Fonts: Inter + Noto Serif SC + Space Mono. Full dark theme `data-theme="dark"`.
- **`DESIGN.md`** (15.4KB) — "柔软的构成主义 · Soft Constructivism". Named rules: One-Voice, No-Gradient, Wash, CN-Serif, Mono-Metadata, Sentence-Case, Light-Edge, Lift-on-Hover.
- **`components/`** (React, namespace `EzagentDesignSystem_b8e92c`): actions (Button, IconButton), forms (Input, Select, Toggle, Checkbox, Radio, SegmentedControl), data-display (Badge, Tag, Avatar, Card), surfaces (GlassPanel, AppIcon, ColorPoints), navigation (Tabs), feedback (Dialog, Toast, Tooltip). Each has `.jsx`+`.d.ts`+`.prompt.md`+`.card.html`.
- **`templates/landing/Landing.dc.html`** + `ds-base.js` + `support.js` — canonical Ezagent marketing hero: kicker "Organization IDE · 2026", CN serif headline "组织的 IDE。", dual CTAs (开始使用/查看文档), ColorPoints band. **Directly reusable as the 介绍 section seed.**
- **`slides/`** — 5 branded 1280×720 templates (TitleSlide, SectionSlide, ContentSlide, QuoteSlide, ComparisonSlide), link `../styles.css`.
- **`ui_kits/agent-console/`** + **`ui_kits/agent-builder/`** — full UI kits (login→chat workspace; design/dev/preview builder).
- **`guidelines/`** — 20 HTML spec cards (brand, color, type, spacing, radii, elevation, glass, motion).
- Logo: `assets/ezagent-logo.png` (light) + `assets/ezagent-logo-dark.png` (dark). No SVG.

### What ruihua needs for the 3-section demo (介绍 / kanban / contributors + mock API)

1. **Design tokens/styles — confirmed usable** (`styles.css` + tokens). Reusable for all 3 sections.
2. **介绍 section:** seed from `templates/landing/Landing.dc.html` + copy from `docs/rh/homesite/docs/M-主站文案-v1.md` (PR #1022).
3. **kanban section:** **kanban role/recipe source is NOT on `main`** — only `docs/together/2026-06-25/handoffs/jjkysy-kanban-heads_up.md` on disk; the live role/recipe lives on PR #1020's branch (`feat/kanban-agent-e2e`). **ruihua must ask jjkysy for the current kanban role/recipe schema** (9-stage data, board config, pm-coordinator) before building the showcase. The relay-chain mockup `docs/rh/value-chain-kanban/demo/07-demo-接力链-多角色视角.html` is the interaction seed.
4. **contributors section:** data source = `docs/together/team.md` (8 humans + 2 agents: zyli, gaga, zhaomato, fatnine, allen, jjkysy, ruihua, + claude/codex; backgrounds at lines 37-45).
5. **mock ezagent API:** **no OpenAPI/Swagger file exists** in either repo. Model on `:introspect` (ezagent's `/openapi.json` equivalent, `ARCHITECTURE.md:333` — `dispatch(agent://x, :introspect)` returns all Behaviors + `@interface`; URI = system-wide operationId, `ARCHITECTURE.md:292`) and the socialware chat-feed controller `apps/ezagent_web/lib/ezagent_web/controllers/socialware/chat_feed_controller.ex`. Her PR prototypes already hand-stub mock data (`docs/rh/homesite/demo/README.md`: "数据均为 mock").
6. **Reskin decision:** the dark-glass v2 mockup violates design-system rules (cream/sand body, gradients/noise). ruihua should either **reskin the v2 narrative onto the design system** (light `#E8E8EB` ground + white floating cards + cobalt + Noto Serif SC) or deliberately keep the dark-glass variant as a separate "dark hero" register if the team endorses it (design system supports `data-theme="dark"`, but its dark theme is `#16151C` cards, not cream/coral/electric-blue).
7. **PR #1022 dependency:** `docs/rh/` is not on main. If the demo depends on those docs, either merge #1022 or build the demo directly in the design repo / a new branch.

### ruihua's today deliverable

官网 demo (3 sections + mock ezagent API), deliver tomorrow. Use design-system tokens/components/styles.css from `/Users/h2oslabs/Workspace/ezagent-design`; carry forward the locked copy + IA from `docs/rh/homesite/docs/M-主站文案-v1.md` (PR #1022); get kanban schema from jjkysy (on PR #1020 branch); hand-stub the mock API on the `:introspect` shape.

---

## Cross-cutting notes

- **FatNine + jjkysy dependency:** FatNine's leak-gate (§3) and jjkysy's kanban #1020 (§4) intersect — kanban is the canonical "business concept done right" (9-stage chain is LAYER-2 data, not code; generic Behavior has no stage names). The leak-gate should *pass* against kanban-as-data and *fail* against a hypothetical `defmodule Ezagent.Entity.Kanban`. Once #1020 lands, kanban is the positive test fixture for the gate.
- **Skill-vs-gate scoping:** "complete the create-socialware skill" is largely done (`ezagent-socialware` is the authoring guide). FatNine's real contribution today is the **detection gates** (§3) — the skill side is a verification/patch task, not a build-from-scratch task.
- **All three owners are off / no active track** per `team.md` + `2026-06-28/review.html`; today's assignments come from `2026-06-29/plan.html` (FP2/FP5/FP4). FatNine = FP2 bug-triage reserve (but Allen's plan redirects him to skill+gates); jjkysy = FP5 kanban #1020; ruihua = FP4 官网 demo (with zhaomato97 on FP1 官网 + FP4 design system — coordinate to avoid duplicate 官网 work).
