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

## 5. Definition of Done (a demonstrable artifact — not just "tests pass")
- [ ] <the artifact: agent-browser screenshot / real-channel chat transcript / E2E run output / merged demo on Tailnet>
- [ ] All gates green: arch.scan, doc.scan, uri_query.scan, check_invariants, format, test, :ezagent_plugin_check
- [ ] The work's own invariant/regression test

## 6. Discuss-first vs Deferred (both explicit)
**Discuss-first (do not build before lead-confirm):** <items hitting a discuss-first trigger>
**Deferred (flagged + targeted):** <later-phase scope, with the target phase/issue>
**Never deferred here:** load-bearing decisions, in-PR-solvable items, gates, human-assist steps.

## 7. Conflict-avoidance
<Surfaces/files this owns. If it touches world: link world-coordination.md + add a row to its in-flight registry.>

## 8. Merge model
PRs merge into the task branch `<branch>` (never `main`); keep rebased on `main`;
the lead merges `<branch>` → `main` when the DoD is met.

## 9. Gates, file/LOC estimate, open questions
<Gate list; new files + rough LOC; questions for the lead.>
```
