# Handoff: #1498 (Git Provider D1 retrospective + guarded Mix runner) — owner follow-up

> **Date:** 2026-07-24 (worked 2026-07-24, re-verified against current `origin/main`)
> **From:** gaga track (agent-executed) · **To:** Allen (dev-together skill owner)
> **Tracking:** PR #1498 "docs: Git Provider D1 retrospective + guarded Mix execution runner" (sibling, already merge-ready) · this branch: `system-closure/dev-together-skill-updates`
> **Status:** evaluated, minimized, ready for your authorship — this is a 1-file, small diff, not the original "system-closure" schema proposal (renamed away from that term — see §0)

## 0. Mission

PR #1498 originally proposed two things behind the owner gate: a `guarded_mix.sh`
adoption push, and a full X/Y-taxonomy schema migration for `review.md`'s
`method_deltas`. Both got re-evaluated against the actual, currently-live
process (not just against the original incident) and cut down hard. This
handoff is the **only piece left that needs your authorship** — everything
else already landed or was dropped. It's small on purpose.

Also renamed: "system-closure" only made sense to people who lived through
the Git Provider D1 incident — the PR title/description no longer use it as
a headline term; it now reads "Git Provider D1 retrospective + guarded Mix
execution runner." The branch names (`docs/system-closure-method-...`,
`system-closure/...`) and the archived file paths still say
"system-closure" — those are left as-is (internal identifiers / dated
historical records, not something a reader needs to parse).

## 1. What already happened (no action needed from you)

- **PR #1498** ("Git Provider D1 retrospective + guarded Mix execution
  runner," branch `docs/system-closure-method-productization`) is rebased on
  current `main`, CI green (including `Only repo owner may edit dev-together
  skill` — it touches nothing under `.claude/skills/dev-together/**`),
  and ready to merge as-is. It carries: the bilingual Git Provider D1
  retrospective + runbook, `scripts/guarded_mix.sh` + its 11-case contract
  test, and — new this round — **one pointer paragraph in `CONTRIBUTING.md`**
  telling anyone debugging process-spawning code (erlexec/PTY/sidecars) to
  reach for `guarded_mix.sh`. That's the entire "adoption" story now: a
  signpost at the point of risk, not a mandatory `mix.exs`/CI rewiring. Full
  reasoning: `docs/together/2026-07-24/returns/system-closure-next.md`.
- **The full X/Y schema migration was dropped.** It would have touched
  `SKILL.md`, `commands/plan.md`, `handoff-standard.md`, `handoff-template.md`,
  `plan-template.md`, `review-template.md`, `board.example.yaml`,
  `board2html.py`, `validate_skill.sh` — ~200 lines across 9 files. Re-reading
  the *currently live* `handoff-standard.md` and `review.md` end to end showed
  the ground it was trying to cover is already handled: the four-property DoD,
  the 2026-07-09 #1276 "run the full static-gate set, not the one named gate"
  rule (same lesson as "Task-local convergence ≠ Plan-level closure", 12 days
  earlier), the discuss-first triggers (a Git-Provider-D1-shaped plan already
  qualifies as "core / cross-cutting" and should get a research phase first),
  and `review.md`'s own mandatory Method-deltas section — which is already
  working (#1555 went through exactly this pipeline).

## 2. The one thing left — your call, your authorship

**Branch:** `system-closure/dev-together-skill-updates` @ (latest, see `git log`)
**Diff:** 1 file, `.claude/skills/dev-together/commands/review.md` only —
adds to the existing (already-mandatory) Method-deltas requirement:

```diff
    close-review finding should name the **process rule (existing or new) that would
    have caught it**; a finding with no mapped rule is a signal to add one. This is
    the *Act* phase of the loop: it updates the **method**, not just the roster.
```
becomes
```diff
    close-review finding should name the **process rule (existing or new) that would
    have caught it**; a finding with no mapped rule is a signal to add one. Also
    name its **recurrence-prevention proof** — point at the specific test, CI
    gate, lint rule, or architecture invariant that would go red if the same
    class of gap returned. A sentence promising it won't happen again is
    **not** a recurrence-prevention proof; if no such check exists yet, say
    what check needs to be added and who owns adding it (2026-07-21
    system-closure retrospective: a Task-local fix with no such check is how
    the same class of gap comes back under a new name). This is
    the *Act* phase of the loop: it updates the **method**, not just the roster.
```

No new terminology, no schema, no other file touched. This is the one idea
from the original system-closure proposal that the current process didn't
already have an equivalent for: forcing every method delta to name *how it
would be caught again*, not just what was fixed.

**Wording note (fixed before you saw it):** the first draft of this sentence
just said "recurrence-prevention proof" without pinning down what "proof"
means here. "Proof"/证明 both carry a "a document/argument attesting X is
true" connotation strongly enough that a tired reviewer could satisfy the
requirement with a narrative paragraph ("we've thought about it, it won't
recur") instead of naming an actual checkable mechanism — which is exactly
the failure mode the system-closure retrospective was about in the first
place. Tightened to name concrete artifact types up front and explicitly
rule out the narrative-only reading, with a stated fallback for "no check
exists yet." If you still find a softer reading of the final wording, that's
worth another pass before landing it.

**Why it needs you specifically:** `protect-dev-together-skill.yml` keys off
the PR-author/push-actor GitHub login (`OWNERS: allenwoods jjkysy`); this
session's identity (`gagameow`) is not in that list, by design — no mechanism
under this authorship can land it.

**Your options, in order of least effort:**
1. Cherry-pick `c573fe826` under your own login and push/merge it directly.
2. Open a PR from this branch yourself (`gh pr create --head
   system-closure/dev-together-skill-updates`) — the gate will pass since
   you're an owner.
3. Decide the sentence isn't worth adding at all and close this branch. That's
   a legitimate outcome too — this whole handoff exists because the bigger
   version wasn't worth your time; if even this 1-line version isn't, say so
   and it's dropped, no further follow-up needed.

## 3. Minor FYI, not blocking, not touched

`bash .claude/skills/dev-together/scripts/validate_skill.sh` fails on this
branch — but reproduces identically on unmodified `origin/main` (verified via
`git stash` + re-run), so it's pre-existing and unrelated to this diff:
`.superpowers/sdd is not git-ignored` even though `.gitignore:69` has
`.superpowers/`. Worth a look sometime, not part of this handoff's scope.

## 4. Definition of Done

- [ ] You decide: land the 1-line diff (any of the 3 options above), or drop
      it. Either is an acceptable close for this handoff.
- [ ] If landed: `bash .claude/skills/dev-together/scripts/validate_skill.sh`
      still passes modulo the pre-existing `.superpowers/sdd` finding above.
- [ ] No other file changes — if the ask has grown back to more than this one
      sentence, that's a new decision, not this handoff.

## 5. Merge model

This branch was never opened as a PR under this session's authorship
(deliberately — `protect-dev-together-skill.yml` only triggers on
`pull_request`/push-to-`main`, so a plain pushed branch never shows a
confusing red check). It's sitting on `origin` at
`system-closure/dev-together-skill-updates`, ready for you to take from
here however is least friction for you.
