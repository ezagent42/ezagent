# Return: cc-custom configurable completion backends — clarify first

> **Task:** cc-deepseek → cc-custom + DeepSeek/Kimi real proof (clarify-first research)
> **Branch:** `feat/cc-custom-backends` (worktree `.worktrees/cc-custom-backends`)
> **PR:** Draft PR #1449 — https://github.com/ezagent42/ezagent/pull/1449
> **Dev:** gaga Codex session (Claude)
> **returned_at:** 2026-07-17 (same-day)
> **deadline:** 2026-07-17 EOD
> **deadline_status:** on_time
> **Base / rebase-base SHA:** `66734aae52ce5f39c54ad5f4d34569cf929a6015` (origin/main at branch creation; branch is a single doc commit on top)

## What's done

- **Design spec (the deliverable):** `docs/superpowers/specs/2026-07-17-cc-custom-backends-design.md`
  — goals/non-goals, verified vendor facts with citations, approach comparison,
  full design (catalog / Provider facade / flavors / credential routing /
  redaction), migration, test strategy, 7 PR-sized build slices, rollout/rollback,
  closed build DoD, 3 open questions for the lead.
- **R1 parity inventory:** spec Appendix A — every deepseek-coupled site with
  `file:line` evidence and migrate/retain/defer disposition.
- **R2 vendor reproduction:** spec §2 — official docs cited with access date;
  credential-free shape reproduction through the real `claude` 2.1.212 binary
  against a local SSE stub (scrubbed env, no key material):
  `POST {base}/v1/messages?beta=true` with `Authorization: Bearer`,
  small-model slot (`deepseek-v4-flash`) and main model (`deepseek-v4-pro`)
  both honored, `stream: true`. **Real DeepSeek/Kimi probes: BLOCKED — no
  `DEEPSEEK_API_KEY` / `MOONSHOT_API_KEY` in this session's environment.**
  Exact lead-authorized probe commands recorded in spec §2.4.
- **R3 comparison:** spec §3 — three approaches scored against five verified
  codebase constraints (C1 1:1 registry, C2 flavor-keyed credential routing,
  C3 respawn-data persistence, C4 no-shims, C5 headless reply clause).
  Recommendation: **Approach 1** (`cc-custom` / `cc-headless-custom` + closed
  catalog) — the handoff's expected direction, confirmed by evidence.
- **Self-review:** caught and fixed two items before return — a `[1m]` model-tag
  inconsistency between §2.1 and the §4.1 catalog example (now consistent,
  flagged as open question Q1), and the §4.5 profile-flow section which now
  cites the verified content seam instead of a "build verifies" hedge.

## DoD reconciliation (handoff §5, research handoff)

| # | DoD line | status | proof / open decision |
|---|----------|--------|-----------------------|
| 1 | Independent worktree/branch from latest `origin/main`; no #1445 inheritance | met | worktree `.worktrees/cc-custom-backends`, branch `feat/cc-custom-backends`, base `66734aae5` (same SHA the handoff names); clean tree; no existing PR |
| 2 | DeepSeek migration surface enumerated with file:line + parity checklist | met | spec Appendix A (7 groups incl. tests + comment sweep); repo-wide search incl. seeds/CI/scripts/docs |
| 3 | DeepSeek compatibility reproduced through the real Claude Code/SDK seam, or exact blocker + authorized command | met (blocker path) | spec §2.1 (official docs), §2.3 (real-binary shape repro), §2.4 (exact probe command; blocked: no key in session env) |
| 4 | Kimi compatibility reproduced through the same real seam, or exact blocker + authorized command | met (blocker path) | spec §2.2 (official docs), §2.3 (same seam), §2.4 (exact probe command; blocked: no key) |
| 5 | ≥3 flavor/profile approaches compared against registry/restart/transport/secret/no-shim invariants | met | spec §3 (C1–C5 constraint table) |
| 6 | One provider-profile abstraction for both vendors; no duplication of `CcAgent`/`CcHeadlessAgent`/sidecar | met | spec §4.1–4.3 — thin shims delegate everything; profile is catalog data |
| 7 | Closed server-owned catalog + allowlisted credential references; arbitrary user env names/secret values rejected | met | spec §4.1 (catalog owns env-var names), §4.3 (fail-closed validation, structural via `validate_for_flavor`) |
| 8 | PTY + `:in_process_sync` flows, credential status, failures, redaction, seed migration, respawn, rollback explicit | met | spec §4.4–4.8, §5, §8 |
| 9 | Goal-derived build DoD + PR-sized TDD slices | met | spec §7 (7 slices), §11 (closed DoD) |
| 10 | Design saved under `docs/superpowers/specs/`, self-reviewed, presented to lead | met | this return + spec commit `a7e0f2bcd` |

**Gates for this research return (per handoff §5 — no `mix precommit` required):**
`git diff --check` ✓ clean; `mix ezagent.doc.scan` ✓ PASS
(undocumented_public_modules 0/0, undocumented_public_defs 404/404 cap,
dynamic_public_def_heads 0/0). PR-head CI will run on the Draft PR.

## Findings the lead should know (beyond the handoff's expectations)

1. **`provider` content seam already exists** — curl contributes `provider` via
   `template_data_extra/1` (`agent_template.ex:108`), and `to_template_data/2`
   runs `validate_for_flavor` before every spawn. The design needs **no new
   content contract**, only one additive role-slot key (spec §4.5 link 3).
2. **Two domain files are mandatorily on the migration surface** though the
   handoff's §7 conflict map didn't name them: `behavior/agent/receive.ex:345`
   (headless reply clause) and `session_creator/definition_agents.ex:585-586`
   (missing-key skip atom). They hardcode the retired vendor flavor, so they
   must change in the same stack (spec §4.4.2, §4.6).
3. **Deliberate behavior change flagged:** today's `provider_of/1` silently
   maps unknown providers to anthropic (`provider.ex:76-79`); the design makes
   unknown profiles a fail-closed structured error (locked decision #9). The
   old "fail-safe" test is updated in the parity map (spec §4.2, Appendix B).
4. **Docs vs code delta:** vendor guide now recommends `deepseek-v4-pro[1m]`
   for the main model slots; the shipped code uses `deepseek-v4-pro`. Open
   question Q1 (default: follow the docs).
5. **Kimi is greenfield** — zero existing `kimi`/`moonshot` references in the
   repo (confirmed by full-text search).

## Open decisions for the lead (spec §10)

1. `deepseek-v4-pro[1m]` vs `deepseek-v4-pro` as the shipped catalog value
   (default: follow the current vendor guide = `[1m]`, confirmed at PR-7 live proof).
2. Role-slot `provider` key on socialware definition role maps (additive;
   mechanism already exists — default: proceed).
3. PR-7 live-proof environment: which host holds both keys; billable minimal
   probe authorized?

## Method friction

- The handoff's §7 conflict-avoidance surface ("only the completion-backend
  integration surfaces") didn't name the two domain hardcodes (finding 2) —
  discoverable only after the inventory. Suggest future handoffs in this area
  name `receive.ex` + `definition_agents.ex` explicitly. Low risk: both
  hardcode the retired flavor and must change atomically with it anyway.
- `mix ezagent.doc.scan` on a fresh worktree requires a full umbrella compile
  (~10 min first run) even for a docs-only research return. Consider noting
  this in `handoff-standard` for research handoffs (or sharing `_build`
  across worktrees).

## Merge request

- **Branch:** `feat/cc-custom-backends` → Draft PR targeting `main` (separate
  from #1445, per the handoff's PR isolation rule). Contents: this design spec
  + this return only — **no implementation code**.
- **Requested action:** review the spec; answer open questions Q1–Q3; on
  approval, the build handoff (spec §7 slices) can be issued. Do NOT merge as
  implementation — merging just lands the design record.
