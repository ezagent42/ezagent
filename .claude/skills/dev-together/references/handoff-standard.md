# The handoff standard

Every handoff is a self-contained spec an unfamiliar developer (human or agent)
can execute. Copy-paste skeleton: [handoff-template.md](handoff-template.md).

## Definition of Done — four properties (all required)
The DoD is the **closed checklist** that makes a task "done". "Tests pass" is
necessary but **not sufficient** — a DoD that is an author-chosen subset, or that
proves "it worked once" instead of "it can't regress", or that verifies the wrong
layer, lets "green tests, broken product" through. A DoD is valid only if it is:

1. **Goal-derived** — every line enumerated from the **goal**, not a convenient
   subset. For **migration / replacement** tasks, enumerate the list **from the
   source of truth** (e.g. "frontend catalog == backend catalog", parity
   diff == ∅), never a hand-picked set.
2. **Verifiable, and carries its proof** — every line names *how it is proven*:
   - **UI / frontend** → an automated test **through the real surface** (a
     LiveViewTest mounting the route / an agent-browser script driving it) that
     fails if the feature breaks. An **agent-browser screenshot** is the
     human-readable companion, **not** the proof.
   - **Agent / chat / session** → a **success transcript from the real channel**
     (the agent actually replying — not a unit stub) + an automated regression test.
   - **Backend / API** → an **E2E run output** (a request hitting the new path,
     returning the expected shape) + the path's own test.
   - **Cross-layer change** (a contract + its consumers — e.g. backend catalog ↔
     frontend renderer) → a **parity checklist enumerated from the contract** AND
     an **end-to-end product proof** (generate → render → eyeball), not per-layer
     unit tests alone. Backend-only "done" on a cross-layer task is **rejected**.
   - **Demo-type** (design confirmation) → the **demo merged + viewable on Tailnet**
     + design sign-off.
3. **At the user-facing layer** — the proof exercises what the user/operator
   actually touches, not just an internal seam (a backend-seam test passing while
   the route 404s is **not** done).
4. **A closed set** — a dev may **defer** a line (→ lead-adjudicated, see Defer
   rules) but may never **delete** one. Done = **every** line green.

- **Always, in addition:** all gates green — `arch.scan`, `doc.scan`,
  `uri_query.scan`, `check_invariants`, `format`, `test`, `:ezagent_plugin_check`
  — **plus the work's own invariant/regression test**, and **CI green on the PR
  head + branch rebased on `main`** (the machine return gate — see
  [commands/return.md](../commands/return.md)).

> **完整静态-gate 集（return 前本地必跑，不跑子集）。** CI 的静态 gate 分散在不同 job：`gate (deterministic)` 只跑 `arch.scan` + `doc.scan`；`full-suite`（`mix ci.local`）才跑 `uri_query.scan`（含 `home_path_in_runtime_code` 行锚检查）+ 全部 ExUnit 不变量套件；`mix ezagent.check_invariants` **不含** `uri_query.scan`。因此 return 前本地必跑 `arch.scan + doc.scan + uri_query.scan + check_invariants`（或整套 `mix ci.local`）——只跑任务点名的那一道，绿了只会揭开下一道（2026-07-09 #1276：一个 PR 连环触发 arch/doc/uri_query/home_path 四道 gate，被红 arch gate 逐层掩盖；同周 W28 kanban/dealscout 改版又两次实踩——`uri_query.scan` 的 `tenant_derivation`、core 不变量套件，均到 CI 才暴露——是拓扑常态，不是一次性事故）。改动含**行锚豁免**文件（`HomePathExceptions`、locality-allowlist、arch.scan anchors）时，行锚随上方增删行漂移会把合法永久豁免变成"违规"——**重锚**（改行号），不要新增 allowlist 条目。
>
> **机器闸（CI 绿）≠ 产品验证。** 动 orchestrator / session-create / PTY 就绪的改动，test 环境跳过 `require_transport_join`、短路 `:exec.run`——"transport bridge 真 join、agent 真翻 :ready 并回话"**只有 canary 能证**。这类 PR 的 DoD 必须加一个显式的 **canary 实测**步骤（合并后在部署渠道上实测），实测通过再宣布"修好"（2026-07-09 #1294 create_session 根因修复即受此约束）。

**Litmus:** if every line passes, a fresh reviewer agrees the **goal** is met with
nothing important unproven — a *superset* of what a human reviewer would check.

**Who writes the DoD:** it is often **unknowable before research** (the lead cannot
enumerate it for a task full of unknowns). For such tasks the **clarify/research
front-phase produces the DoD** — see below.

## Discuss-first triggers → the clarify/research front-phase
These triggers are also the **tiering criterion**. If a task hits **any** of them,
it does **not** go straight to a build handoff: the lead first issues a
**research handoff** (a `clarify_first` task) whose deliverable is **findings +
the proposed build slices + the DoD**; only after that lands (via the normal
`dive`/`return`) does the lead issue the **build handoff**. Triggers:
- The approach has **more than one viable option with real trade-offs**.
- It touches **CapBAC/authorization**, **core** (a multi-app change), or a
  **cross-cutting invariant**.
- It **diverges from a north-star** (let-it-crash / no-workarounds, plugin
  isolation, external-integration-is-an-Adapter, no-unowned-caps).
- The design **rests on an unverified assumption** about the codebase.
- It's a **scope / MVP-line** decision, or **the scope / feasibility / DoD is not
  yet knowable** (the task carries real unknowns).
- Correctness crosses a **cross-Task state machine**, recovery/compensation, a
  destructive terminal operation, multiple durable stores, or a proof/publish
  transaction boundary.

### Stop Rule — stop local patching after the second cross-Task regression

When the same Closure exposes a second cross-Task regression, stop production
edits. Before continuing, write and review:

`failure -> Plan invariant -> one root cause -> one integrated repair surface`

The repair is serialized. Parallel agents may perform read-only review only
after the implementation is frozen. Frame the repair with **X problem — fundamental problem**
and **Y problem — engineering problem**, then require both level corrections and
a recurrence-prevention proof.

**Fast path:** no trigger fires → mechanical work inside an approved design,
following established patterns → just build it (`plan` → build → CI gate → merge).
Small/clear tasks are **not** forced through the research phase — that keeps the
loop from becoming ceremony.

## Defer rules
- **Deferrable only when explicitly flagged with a target** (a later phase /
  issue): later-phase breadth (token-level streaming, advanced editors),
  non-load-bearing polish, optional optimizations.
- **Deferral is the LEAD's call, not the dev's.** A return that defers any DoD
  line sets `deadline_status: deferred` and lists each deferred line as an **open
  decision for the lead**; "READY TO MERGE" is the lead's verdict at `close`,
  never the dev's at `return`.
- **Never deferrable:** the **load-bearing design decision**, anything solvable
  **now in the same PR**, **gates/invariants**, and **steps that need a human**
  (flag those; don't silently scope past them).

## Merge model
Split a task into as many PRs as needed; **all PRs merge into the task's own
branch, never `main`**. Keep the branch **rebased on `main`**. When the DoD is
met, the **lead** merges the task branch → `main` (via `close`). The lead is the
only path to `main`.

## Required-reading every handoff lists
- Skill **ezagent-developer** (always) + others as relevant (**ezagent-socialware**,
  **ezagent-session-orchestrator**).
- `docs/guide/world-coordination.md` — REQUIRED if the task touches `world`.
- The **dev-together** skill (this workflow + standard).
- The design spec / research note the work builds on (by path).
