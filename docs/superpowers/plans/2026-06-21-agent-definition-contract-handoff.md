# Agent Definition Contract — Handoff to codex (implementation)

**Owner:** Allen · **Author of specs/plan:** claude · **Implementer:** codex · **Date:** 2026-06-21

You (codex) are implementing the agent-definition contract. The design is **DESIGN-READY** (3 adversarial review rounds; verdict on `docs/superpowers/specs/2026-06-21-agent-contract-codex-rereview.md` + round-3). Your job is implementation, not redesign — but you resolve `Plan-time (not spec)` seam decisions against live code.

## Authoritative docs (read in order)
1. `docs/superpowers/specs/2026-06-21-agent-definition-contract-design.md` — master; **read §0 "Review altitude" first**.
2. `…-agent-contract-spec1-manifest-compile-fallback.md`, `…-spec2-tools-participant.md`, `…-spec3-versioned-artifact.md`.
3. `docs/superpowers/plans/2026-06-21-agent-definition-contract-plan.md` — the phase/task roadmap + plan-time decision register.
4. Review records (context on what was already adjudicated): `…-codex-review.md`, `…-codex-rereview.md`.

## REQUIRED process

1. **Load skills first** (every session, before any `.ex` edit): **`ezagent-developer`** + **`elixir-phoenix-helper`**. They hold the invariants/CI-gates that are silent landmines.
2. **Work in a git worktree.** Create one off the **`agent-schema`** branch (the integration branch that already holds the specs + plan). Do NOT work directly in the main checkout. (e.g. `git worktree add ../esr-agent-schema agent-schema` then branch per phase, or use the project's worktree skill.)
3. **Set a `/goal` per phase** (the plan gives the goal text). Drive each phase under its goal; generate your own granular TDD steps. Commit frequently; run `mix ezagent.check_invariants` + `mix format --check-formatted` + `mix test` before each commit.
4. **E2E gates the "completed" status.** A phase/task is **completed ONLY after its E2E flow passes** (the VERIFICATION gate in the plan: G1/G2/G5 → Phase 1; G3 → Phase 2; G4 → Phase 3), driven via `mix ezagent` (no raw RPC). If E2E is red, the phase stays in-progress — do not mark completed, do not move on.
5. **Plan-time decisions (D1–D7 in the plan):** resolve them against the live code, applying the stated principle. You do NOT need sign-off for seam mechanics. BUT — per ezagent grill culture (CLAUDE.md) — if you hit a **genuine architecture conflict** (an invariant contradicts the spec, or a Behavior abstraction doesn't fit), **PAUSE, write an issue note, and surface it** rather than working around it.
6. **Merge target = `agent-schema`, NOT `main`.** When a phase's E2E + units are green, merge that phase's worktree branch into **`agent-schema`**. **You must NOT merge to `main`.** main is claude's gate.
7. **When ALL phases are green on `agent-schema`, write a handoff-back doc** `docs/superpowers/plans/2026-06-21-agent-contract-handback-from-codex.md` for claude, containing:
   - what landed per phase (modules + key decisions taken for D1–D7);
   - **E2E evidence** (the commands run + pass output for G1–G5);
   - any deviations from the spec + why; any open items / flagged architecture conflicts;
   - `git log agent-schema` range to review.
   Then **stop** — claude reviews `agent-schema`, checks the E2E evidence, and merges `agent-schema → main`.

## Scope boundaries (do NOT)
- Do NOT modify `ARCHITECTURE.md` / `GLOSSARY.md` (Allen-owned) — surface architecture issues instead.
- Do NOT implement deferred items: orchestrator NL-decomposition skill, SLA/filler, the optional Elixir code-builder, omnigent flavor, lifecycle ephemeral gating (cheap field only).
- Do NOT touch `main`. Do NOT merge to `main`.
- Do NOT keep back-compat shims (SPEC §5.11) — delete legacy paths.
- Do NOT cross-phase "while I'm here" — Phase N's deliverable is Phase N.

## Done definition (the whole handoff)
All of: Phase 1 (G1/G2/G5), Phase 2 (G3), Phase 3 (G4) E2E green on `agent-schema`; Phase 4 skills updated/created; invariant + format + test gates green; handback doc written. Then claude reviews + merges to main.
