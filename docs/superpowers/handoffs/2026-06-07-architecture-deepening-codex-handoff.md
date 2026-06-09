# Codex Handoff — #25 Architecture Deepening (loose-audit, two phases)

> **Mode:** loose-audit. **Phase 1 (analysis + proposal) is the immediate deliverable.**
> Phase 2 (refactors) runs ONLY after Allen/Claude review the Phase-1 proposal — do NOT
> blind-refactor 27 files. Codex self-merges; the author audits main + files
> `architecture-audit` issues.

## 1. What & why (#25)

`docs/futures/todo.md` #25: an **architecture-deepening discussion/proposal deliverable**.
Apply the **`improve-codebase-architecture`** lens (Ousterhout *A Philosophy of Software
Design* — deep modules: maximal functionality behind simple interfaces; eliminate shallow
modules, leaky abstractions, information leakage, pass-through methods, temporal decomposition,
god-modules) to the ezagent umbrella. Goal: make the codebase **deeper, more testable, more
AI-navigable**, without changing behavior.

Ground it in the project's own vocabulary + rules:
- `UBIQUITOUS_LANGUAGE.md` + `GLOSSARY.md` (decisions log) — the RBK / Kind / Behavior /
  Template / domain.agent model.
- The `ezagent-developer` skill invariants (P1–P27 + the 14 invariants) — especially P1
  (plugin-isolation), P9 (tier ownership), P11 (no plugin-owned schemes), P14 (dispatch-only),
  P15 (cap modules), P17 (workspace structure). A deepening proposal must PRESERVE these.

## 2. Inputs (already gathered)

**LOC + complexity report (2026-06-07)** — ~212K Elixir LOC across 20 RBK-layered apps,
test:code ratio 0.93 (healthy), but **27 lib files breach the project's own 800-LOC smell
line**. Concrete hotspots (the Phase-2 targets), biggest first:
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/admin_live.ex` — **3,218 LOC /
  186 fns** — the #1 god-module (many admin views + event handlers in one LV). 4× the line.
- The **`ezagent_domain_instance_message` cluster** (6 oversized): `…/session_creator.ex`
  (1,984), `ezagent/orchestrator/tools.ex` (1,887), `ezagent/behavior/chat.ex` (1,799),
  `ezagent/entity/agent.ex` (1,364), `ezagent/entity/session.ex` (1,352),
  `ezagent/orchestrator/mcp_server.ex` (1,072) — the densest bloat in the repo.
- `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` (2,223);
  `apps/ezagent_plugin_codex/lib/ezagent/template/codex_agent.ex` (1,010).
- core: `ezagent/kind/runtime.ex` (1,460), `ezagent/behavior.ex` (1,423),
  `ezagent/kind.ex` (1,077), `ezagent/capability.ex` (1,024).
- `ezagent_plugin_codex` test ratio 0.45 (low — secondary flag).

**Prior audit:** `docs/notes/2026-05-24-architecture-audit-v1.md` — 5 LOW follow-ups + two
named layer-purity caveats (core→domain runtime `apply/3` reach in `Capability.cross_workspace?`;
the `toggle_extension` install-from-source stub). Don't re-derive these; build on them.

**Skill:** `improve-codebase-architecture` (installed at `.claude/skills/` in the cc-openclaw
env; if not present in your env, apply the Ousterhout deep-module heuristics directly).

## 3. Phase 1 — Analysis + proposal (DELIVERABLE)

Produce `docs/notes/2026-06-07-architecture-deepening-v1.md` (+ a `.zh_cn.md` companion per the
bilingual-docs convention). For each hotspot above AND each notable RBK seam, identify:
- the **deepening opportunity** (which anti-pattern: shallow module / leaky seam / information
  leakage / pass-through / temporal decomposition / god-module / unclear interface), and
- a concrete, **behavior-preserving** refactor proposal: what to split or merge, the **new
  module boundaries + their interfaces**, and *why it is deeper* (more behind a simpler
  interface). Note for each whether it's a **pure mechanical split** (low risk) or **touches an
  invariant / public interface** (needs care + flagging).
Prioritize (impact × safety). End with a recommended Phase-2 PR sequence.
**This doc is the review gate** — Allen/Claude review it before any Phase-2 refactor PR.

## 4. Phase 2 — Refactors (ONLY after Phase-1 review)

Behavior-preserving refactors, **one PR per file/cluster**, biggest-first
(admin_live → instance_message cluster → cc_agent/codex_agent → core). Each PR:
- **NO functional change** — full suite stays green; no public API change unless internal (if a
  public interface must move, flag it in the PR, don't do it silently).
- Split by **responsibility** into focused modules with clear interfaces (deep, not shallow —
  don't just shard a 3000-LOC file into ten 300-LOC files that leak into each other).
- Preserve RBK invariants (dispatch-only, cap-checked, tier ownership, no plugin-owned schemes);
  run `apps/ezagent_core/test/invariants/` + the touched app's suite.
- Fresh worktree off origin/main per PR; check open `architecture-audit` issues first;
  `gh pr merge --admin --squash --delete-branch`.
- PR body: the split + a tests-green proof + a one-line "deeper because …".

## 5. Hard constraints

- **Behavior-preserving** — no functional regression; full suite green per PR. TEST DB only
  (`MIX_ENV=test`); NEVER `mix ecto.migrate` against dev/prod; NEVER touch the running dev/prod
  docker containers (`docker-ezagent-1` / `ezagent-prod-ezagent-1` / `ezagent-disp`).
- Do NOT weaken security-critical code: the cascade materializer, CapBAC, the leak-safe
  socialware customer feed + `validate_and_normalize` boundary.
- No silent defaults / shims; let-it-crash. No `git stash` (parallel worktrees).
- Codex companion review = **static only, skip mix** (isolated MIX_HOME, no deps).

## 6. Author-side (Claude/Allen)

- **Review the Phase-1 proposal doc before Phase-2 starts** (this is the gate).
- Audit each Phase-2 PR (codex adversarial review + a behavior-preservation check: diff is a
  pure move/split, tests unchanged-or-additive, no invariant weakened) + file `architecture-audit`
  issues for any regression. Arm a PR/issue monitor as the sequence runs.
