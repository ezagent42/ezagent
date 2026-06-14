# Backlog Handoff — non-基座化 tasks (#54, #56, #55, #51)

> **You (the receiving agent) own these four tasks to completion.** Work
> autonomously: set your own **goal** (e.g. via `/goal`), drive each task, open a
> PR per logical unit, and **self-merge (admin-merge) it once all gates pass +
> `/codex:adversarial-review` is clean.** Claude (the cc-openclaw session) checks
> the merged result on `main` afterwards and opens a **fix-PR** if something is
> off — **remember to rebase** onto those fixes. Work asynchronously; do not wait
> on Claude or Allen except where a task explicitly needs an Allen decision.
>
> **Out of scope / do NOT touch (Claude's lane):** the socialware 基座化 line is
> DONE (im→session→agent split merged, acyclic gate at 0). The LIVE E2E
> validation of it + the disposable docker stack (`ezagent-disp:10044`) + tasks
> #34/#57/#58 (transport/E2E-area) are Claude's. Don't run the disposable-stack
> E2E or edit the im→session→agent transport seams.

## 0. Environment

Full working checkout of `ezagent42/ezagent` with `mix` deps installed + `gh`
authed (NOT a deps-less sandbox). You MUST be able to run `mix compile`, the full
umbrella suite, the arch/invariant gates, and `gh pr`. If you can't, STOP and say so.

## 1. Skills to load (mandatory before any edit)

`ezagent-developer` + `elixir-phoenix-helper` — without them you'll write stale
2023-era Elixir and miss the ezagent RBK invariants (dispatch-is-the-only-path,
the CapBAC chokepoint `Ezagent.Capability.matches?`, `use Ezagent.Lifecycle`
Behavior contracts, the snapshot model). For #51's E2E user-path use
`agent-browser`.

## 2. The tasks

### #54 — Role-over-flavor (agent ROLE abstraction above cc/codex/curl)
**Spec + plan ALREADY WRITTEN + codex-reviewed + Allen-approved** — implement them:
- Design: `docs/superpowers/specs/2026-06-14-role-over-flavor-design.md` (+ `.zh_cn`).
  All 4 sub-decisions locked (Role = a **Template subtype**, not a registry;
  compose at materialization; session-template = reference-only; role = a queried
  attribute). Cap composition is **fail-closed** (§2.3.1 — role caps are
  *requested*, intersected with flavor/tenant policy; never copied — codex finding).
- Analysis (context): `docs/superpowers/specs/2026-06-14-role-over-flavor-analysis.md`.
- Governing principle (Allen): **sandbox CONTENTS = role** (skills/plugins/prompt/
  behaviors/caps/session-template); **how the sandbox is loaded = flavor**.
- Completion invariant: same role × two flavors → identical sandbox contents,
  **flavor-validated** (not identical) caps + a negative authz test (unsupported
  cap rejected). Write the impl plan first (superpowers:writing-plans) if you want
  finer steps; the design is settled.

### #56 — Cap-checked in-process op primitive (retire `reads_siblings`)
**Spec + TDD plan ALREADY WRITTEN + codex-reviewed** — implement them:
- Design: `docs/superpowers/specs/2026-06-14-cap-in-process-op-design.md` (+ `.zh_cn`).
- TDD plan: `docs/superpowers/plans/2026-06-14-cap-in-process-op-plan.md` (13 tasks).
- Core: `Ezagent.Capability.authorize_in_process/2` (pure; reuses `matches?` with
  the SAME closure as step 5.5/5.6 — removes the transport, NOT the check) + a
  cap-gated `ctx.read_slice` accessor resolving the **Kind's own** caps (codex:
  whose-authority + effective-set-closure). Migrate **6** `reads_siblings`
  consumers (the plan's Scope-correction table — NOT 3; 9c added curl_agent +
  session readers) then delete the mechanism. Reads-only; excludes option-D
  deadlock machinery. Touches CapBAC → never weaken authz; keep each step green.

### #55 — Code comment-coverage burn-down (moduledoc/fn-doc)
The enforcement gate is LIVE: `mix ezagent.doc.scan` (ratchet counters in
`apps/ezagent_core/.../arch_baseline_manifest.exs`: `undocumented_public_defs`,
`undocumented_public_modules`, `dynamic_public_def_heads`). Task = burn the
`undocumented_public_defs` counter DOWN by adding real `@doc`s, ratcheting the cap
lower each PR. **Doc the WHY, code-verified** (memory `feedback_doc_why_must_be_code_verified`
— verify every behavioral claim against the code; never infer from names). One
`@doc` covers all arities (don't add per-arity). Small, steady PRs that lower the
cap; never raise it.

### #51 — External-user anonymous-access for socialware (+ E2E user-path)
Foundation MERGED (#747: `Users.create_read_only`/`AnonUser`/`PublicView`/GC +
3 codex security fixes). **NOW UNBLOCKED** — 基座化 is done so the session domain
is stable. Remaining feature impl (the `@tag :pending_impl` tests are the
executable spec): cookie→entity binding table; public-route controller + signed
cookie; in-app GC sweeper GenServer + table-backed sweep; SessionTemplate
`:public_view` content key + resolver; login-replacement hook; rate-limits.
Scenario 35 (bilingual) is the acceptance reference. **Coordinate with Claude on
the E2E user-path** — that runs on the disposable stack (Claude's lane); you do
the feature impl + unit/integration tests.

## 3. Non-negotiable gates (EVERY PR — run them, don't eyeball)

1. `mix compile --force` (ALWAYS first — stale `.beam` lies; if you edit a Mix-task
   gate like `arch.scan.ex`, force-compile AGAIN before re-running it).
2. `mix ezagent.arch.scan` — watch the **line-coupled allowlists**
   (`@spawn_fresh_sanctioned`, `@all_slices_sanctioned`): any line shift breaks
   them; update the line numbers.
3. `mix ezagent.check_invariants` + `mix ezagent.check_invariants.lifecycle`.
4. `mix ezagent.doc.scan` (new public defs need `@doc`).
5. Full umbrella `mix test`. **SQLite sandbox test-isolation pollution** causes
   varying transient failures — confirm a real failure by running the named test
   in ISOLATION before treating it as a bug. Prove "pre-existing" claims by
   reproducing on a clean base checkout (memory `feedback_zero_new_failures_baseline_proof`).
6. After finishing, `/codex:adversarial-review` the diff before it's integrated.

## 4. Workflow + division of labor

- **You:** set your own goal, implement #54/#56/#55/#51, open a PR per unit, keep
  all gates green, and **self-merge (admin-merge) once gates + codex-review pass.**
- **Claude (cc-openclaw):** periodically checks your MERGED PRs on `main`
  (post-merge); if something's off, opens a **fix-PR** — you rebase onto it.
  Claude does NOT pre-gate or merge your PRs; you own the merge.
- **Allen:** product decisions only (none currently open for #54/#56 — both fully
  specced; #55/#51 are mechanical/spec-driven).
- **Collision avoidance:** #56 touches `core` (Capability/Kind.Runtime) + the 6
  consumer Behaviors; #54 touches the Template/flavor model + the cc orchestrator
  bootstrap; #55 touches many files' docs; #51 touches the session domain + web.
  Claude is concurrently doing the 基座化 LIVE E2E + fixes (admin-cap bootstrap,
  #58 orchestrator coupling) on the disposable stack — keep your `lib/` edits off
  the im→session→agent transport seams; if you must touch a shared file, note it
  in the PR so Claude rebases cleanly.

## 5. Per-task definition of done

- **#54:** RoleRegistry-as-Template-subtype + role×flavor materialization +
  fail-closed cap composition; cc-orchestrator migrated to role `orchestrator` ×
  flavor `cc`; the completion invariant test passes. All gates green.
- **#56:** `authorize_in_process/2` + `ctx.read_slice`; all 6 consumers migrated;
  `reads_siblings`/`reads_sibling_slices` mechanism deleted; the deny/allow/revoke/
  whose-authority/closure invariant tests pass. All gates green.
- **#55:** `undocumented_public_defs` cap ratcheted down materially (agree a target
  with Allen), every added `@doc` code-verified. Gate green at the new (lower) cap.
- **#51:** the 6 remaining feature components implemented; `@tag :pending_impl`
  tests un-tagged + green; scenario 35 acceptance met (E2E user-path coordinated
  with Claude on the disposable stack).
