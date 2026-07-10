# `dev-together return [branch]` (dev)

Return finished work to the lead before the deadline.

**Do:**
1. **Machine return gate (not prose).** A return is invalid unless the PR's **CI
   (`precommit + check_invariants`) is green on the PR head** AND the branch is
   **rebased onto current `main`**. Put the **CI run URL + status** and the
   **rebase-base SHA** in the return — "gates green" as a claim is not accepted.
   (CI + branch protection now enforce this structurally.) return 前跑完整静态-gate
   集（`arch.scan + doc.scan + uri_query.scan + check_invariants`，或整套
   `mix ci.local`——**不跑子集**，见
   [handoff-standard](../references/handoff-standard.md)）；动 orchestrator/session-create/PTY
   就绪路径的改动加 **canary 实测**步骤——合并后实测过再宣布"修好"。
2. **DoD reconciliation — go through the handoff's DoD line by line.** For each
   DoD line, state: met (with the proof link) / deferred (→ §3) / not-met. The DoD
   is a **closed set** — you may defer a line, never delete one. This is also where
   **divergence surfaces at `return`, not at `close`**: you are the first to know
   if the DoD was wrong — say so.
3. **Deferral is the lead's call.** If you defer any DoD line, set
   `deadline_status: deferred` and list each deferred line as an **open decision
   for the lead** — never self-declare "READY TO MERGE". Cleanly split the
   **finished** portion onto its own branch (gates green) and hand THAT off; never
   return a tangled half-task.
4. **Method-writeback capture.** Record the **method friction** you hit: what in
   the process (handoff/DoD/scope) was wrong or unknowable up front and should have
   been clarified first. Cheap + fresh — the lead promotes it in `review`. (You do
   NOT edit the skill yourself; the skill is a single-writer team contract.)
5. Write `docs/together/<date>/returns/<task>.md`: metadata · what's done · the
   **DoD reconciliation** (per-line) · the DoD proofs (path/link) · branch + gate
   status (CI URL + rebase SHA) · cleanly-split deferred follow-ups + open
   decisions · **method-friction notes** · the **merge request** (which branch/PR,
   rebase/order notes).
6. Emit the message the dev sends the lead.

## Required metadata block

Every return starts with a block equivalent to:

```md
> **Task:** <id/name>
> **Branch:** `<branch>`
> **PR:** <url-or-number-or-none>
> **Dev:** <human-or-agent>
> **returned_at:** 2026-06-23 07:12 +0800
> **deadline:** 2026-06-22 23:59 +0800
> **deadline_status:** late
```

Allowed `deadline_status` values:

- `on_time` — returned before the day's deadline.
- `late` — valid work, but returned after deadline. Keep it in `returns/` and
  make `push` decide whether it enters today's stack or tomorrow's plan.
- `deferred` — intentionally split follow-up, with target issue/plan.
- `out_of_scope` — not part of the day's plan; preserve it, but do not count it
  as planned work.

## Required DoD-reconciliation block (every return, even if all met)

Go through the handoff's DoD line by line. "All met" is itself a signal, so this
block is **mandatory on every return**:

```md
## DoD reconciliation
| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | <line from the handoff DoD> | met | <test path / E2E / screenshot link> |
| 2 | <line> | deferred | <why + the open decision for the lead> |
| 3 | <line> | not-met | <what's missing> |

**Method friction:** <what in the handoff/DoD/scope was wrong or unknowable up
front and should have been clarified first — or "none">.
```

**Output:** `docs/together/<date>/returns/<task>.md` + a return message to the lead.
