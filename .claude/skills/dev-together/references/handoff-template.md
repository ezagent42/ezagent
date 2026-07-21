# Handoff template (copy-paste)

Copy this skeleton for any new handoff. Fill every section; delete a section only
if you can say *why* it doesn't apply. Save to
`docs/superpowers/handoffs/YYYY-MM-DD-<topic>-handoff.md`. The standard behind
each section is in the `dev-together` SKILL.md §4.

```markdown
# Handoff: <title>

> **Date:** YYYY-MM-DD · **From:** <author> · **To:** an independent developer (human + cc/codex)
> **Tracking:** <task/issue> · **Base:** `origin/main` @ <sha>
> **Status:** <brainstormed | codex-reviewed | confirmed> — <one line>

## 0. Mission
<One paragraph: what + why. The single sentence a busy dev needs.>

## 1. Required reading (before writing code)
1. Skill `ezagent-developer` — invariants that gate your PRs.
2. <other project skills as relevant: ezagent-socialware / ezagent-session-orchestrator / …>
3. `docs/guide/world-coordination.md` — REQUIRED if this touches `world`.
4. The `dev-together` skill — the workflow + this standard.
5. <the design spec / research note this builds on, by path>

## 2. Locked decisions (settled in brainstorm — do not re-litigate)
| # | Decision | Value |
|---|----------|-------|
| 1 | … | … |

## 3. Architecture primer (for a dev new to the code)
<The minimum mental model + the exact modules/seams this work builds on, with paths.>

## 4. Design (+ review status) & phased plan
<The approach; note "codex-adversarially-reviewed YYYY-MM-DD" if it was.
Then Phase 0 / 1 / … as PR-sized units.>

## X/Y problem framing
### X problem — fundamental problem
<Incorrect abstraction, system model, responsibility boundary, invariant, or completion rule.>
### Y problem — engineering problem
<Concrete code, test, fixture, tool, workflow, runtime, or operational defect.>
### X-level correction
<Model, invariant, boundary, or completion-rule correction.>
### Y-level correction
<Concrete engineering correction.>

## Plan-level system closure
| Closure | X problem | Plan invariant | Related Tasks | Durable proof | Integration evidence |
|---|---|---|---|---|---|
| | | | | | |

## Execution resource envelope
- Guarded runner: `scripts/guarded_mix.sh`
- MemoryHigh: `4G`
- MemoryMax: `5G`
- MemorySwapMax: `0`
- Timeout: <seconds and reason>
- Partition: <unique value>
- Serialization: `/tmp/ezagent-mix.lock`

## Recurrence-prevention proof
<Machine gate or mandatory workflow proof, with owner and evidence.>

Mechanical/non-Mix tasks may mark a section not applicable only with a reason.

## 5. Definition of Done — a closed checklist (four properties; see handoff-standard)
<Goal-derived (for migrations: enumerated from the source, parity == ∅) ·
verifiable + carries its proof · at the user-facing layer · a closed set. The dev
reconciles this list line-by-line at `return`; a line may be deferred (lead-
adjudicated) but never deleted.>
- [ ] <DoD line 1 — its proof: an automated test THROUGH the real surface (LiveViewTest mounting the route / agent-browser driving it); a screenshot is the companion, not the proof>
- [ ] <DoD line 2 — …> (for a cross-layer change: a parity checklist from the contract + an end-to-end product proof, not per-layer units)
- [ ] All gates green: arch.scan, doc.scan, uri_query.scan, check_invariants, format, test, :ezagent_plugin_check
- [ ] The work's own invariant/regression test
- [ ] **CI (`precommit + check_invariants`) green on the PR head + branch rebased on `main`** (machine return gate)

## 6. Discuss-first vs Deferred (both explicit)
**Clarify-first?** <If this task hit a discuss-first trigger, it should have come
in as a RESEARCH handoff first (findings + slices + DoD), then this build handoff.>
**Discuss-first (do not build before lead-confirm):** <items hitting a discuss-first trigger>
**Deferred (flagged + targeted; LEAD-adjudicated at return, not dev-declared):** <later-phase scope, with the target phase/issue>
**Never deferred here:** load-bearing decisions, in-PR-solvable items, gates, human-assist steps.

## 7. Conflict-avoidance
<Surfaces/files this owns. If it touches world: link world-coordination.md + add a row to its in-flight registry.>

## 8. Merge model
PRs merge into the task branch `<branch>` (never `main`); keep rebased on `main`;
the lead merges `<branch>` → `main` when the DoD is met.

## 9. Gates, file/LOC estimate, open questions
<Gate list; new files + rough LOC; questions for the lead.>
```
