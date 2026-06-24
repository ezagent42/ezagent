# Close-review finding — #956 hello (returned not-green)

> **Owner:** zhaomato · **PR:** #956 → superseded by **#961** (`6cfabacd`) · **Status:** LANDED (greened by lead)

## Expected
A working hello AI-page-generation PR, green on its own tip, ready for the lead to merge.

## What actually happened
#956 was **never green on its own parent commit** `34f64614` (verified independent
of the merge):
- `mix compile --warnings-as-errors` **failed** (dead disabled-fan-out code).
- **6** failing tests/gates: `generator_test` (stale vs #956's own `{plan,scope}`
  rewrite), `SpecTest`(4) + `HelloPageE2ETest`(1) (stale vs #956's own shadcn
  catalog migration), and 3 arch/invariant caps (DocCoverage / RawHomePath /
  EffectDiscipline / DatabaseAgnosticGuard).

The branch was also **not rebased** onto current `main`.

## Lead action
Per Allen's direction ("帮 zhaomato 改完 #956 的所有修改"), the lead fixed all 6 at
the code level (one disclosed `arch-cap-bump` for the legitimately-new
`{:set,:shell}` effect), reaching `mix precommit` EXIT=0 (24 suites, all 0
failures) + `check_invariants` EXIT=0, and landed via #961.

## Root cause (process)
The dev's "gates green" was a **prose claim**, unverified until the lead ran
`precommit` at `close`. Same incomplete-migration pattern as the official-site
finding: the shadcn migration updated the backend but left this PR's **own** tests
inconsistent.

## Reminder for zhaomato
- Run `mix precommit` to **EXIT=0** and **rebase onto current `main`** *before*
  returning — both are now **CI-enforced** (branch protection on `main`).
- When you migrate a contract, update **all** of its consumers + tests in the
  same PR (don't leave your own tests red).

→ Process rules that would have caught this: **P1** (machine-checked return gate),
**P5** (cross-layer parity). See `dev-together-process-improvement.md`.
