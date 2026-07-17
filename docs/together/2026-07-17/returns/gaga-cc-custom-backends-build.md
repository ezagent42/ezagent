# Return: cc-custom configurable completion backends — BUILD

> **Task:** cc-deepseek → cc-custom + DeepSeek/Kimi real proof (build)
> **Branch:** `feat/cc-custom-backends` (worktree `.worktrees/cc-custom-backends`)
> **PR:** Draft PR #1449 — https://github.com/ezagent42/ezagent/pull/1449
> **Dev:** gaga Codex session (Claude) — subagent-driven execution, per-task review loops
> **returned_at:** 2026-07-18 (build handoff issued 2026-07-17)
> **deadline:** 2026-07-18 EOD
> **deadline_status:** on_time
> **Rebase-base SHA:** `d533a5d73` (origin/main, rebased 2026-07-18, zero overlap)

## What's done

All 7 PR slices of the build plan landed on `feat/cc-custom-backends`, each
through implementer → task-reviewer → fix-loop review:

- **PR-1** `8d01e9b3d`+`d07613147` — closed `ProviderCatalog` + generalized
  `Provider` facade; review caught headless silent-degrade → fail-closed raise.
- **PR-2** `b25d5b366` — `cc-custom` PTY flavor (fail-closed profile validation).
- **PR-3** `5c2aff961` — `cc-headless-custom` + receive.ex clause.
- **PR-4** `e61fc160a`+`4663b76d2` — credential-routing profile threading;
  review caught a root-scope test-registration collision (Critical) + adapter
  roster gap (PR-2/3 follow-up folded in).
- **PR-5** `587d9b022` — seeds/config/CI flip; implementer's scope-add
  (`Definition.role_slot` provider passthrough) adjudicated correct with a
  mutation proof.
- **PR-6** `d9e429b9e` — deepseek flavors retired, no shims; Appendix A/B
  parity; grep gate zero; 44-test parity suite.
- **PR-7** `b9e047f93`+`11770568c`+`b1a35c699` — local live proof both vendors
  (see DoD row 7 for the kimi-coding substitution); `kimi-coding` profile
  added (Kimi for Coding subscription surface, empirically proven).
- **Merge-prep** `4ce5ae1e1` — final-review nits + spec amendment
  (closed-set-of-3 catalog).

**Final whole-branch review: READY** (independent re-run of gates on the
final tree: arch.scan 36/36, doc.scan PASS, check_invariants + lifecycle
clean, format clean, compile --warnings-as-errors zero; pre-existing failure
attributions spot-checked 4/4 vs main).

## DoD reconciliation (build handoff §5)

| # | DoD line | status | proof |
|---|----------|--------|-------|
| 1 | Both flavors spawn with deepseek AND kimi | **met (PTY) / deferred (headless live)** | `cc_custom_backend_test.exs` 52 tests; PR-7 PTY transcripts both vendors. Headless live spawn blocked by PRE-EXISTING F2 `{:calling_self}` + F4 sidecar nil-config (control-reproduced on plain cc-headless) — follow-up issue proposed |
| 2 | Fail-closed contract + automatic-lane skips | met | 4 error-shape test sets + PR-7 negatives (bogus/keyless/keyless-orchestrator-skip) |
| 3 | Cold restart re-resolves; no secret persisted | met | both resolver paths × both flavors; PR-7 cold-restart both profiles; grep evidence |
| 4 | Plain cc/cc-headless byte-unchanged | met | no-leak tests (10 catalog keys refuted; empty headless cmd_env) |
| 5 | Migration parity (App A/B); zero cc-deepseek code refs | met | PR-6 report row-by-row; strict grep gate zero hits |
| 6 | Seeds + definition flipped; dummies both keys | met | seed/reseed/installation tests; test.exs + ci.yml + gitleaks |
| 7 | Two sanitized transcripts through the real cc path | **met (substitution recorded)** | deepseek + kimi-**coding** PTY transcripts (`docs/e2e/2026-07-17/cc-custom-live-proof/`). Placed key is a Kimi for Coding SUBSCRIPTION key — the open platform 401s it (verified); catalog gained the `kimi-coding` profile. Platform-`kimi` lane needs an open-platform key (cheap re-run) — **deferred to lead** |
| 8 | Gates green per PR | met | every task's gate list + final-tree re-run (above) |
| 9 | CI green on PR head + rebased | rebase ✅ (`d533a5d73`); CI runs on push — **verify #1449 checks** |

## Open decisions for the lead

1. **Accept the two deferrals?** (a) cc-headless-custom live spawn → follow-up
   issue for pre-existing F2/F4 (+F3 ad-hoc create lane); (b) platform-`kimi`
   lane → needs an open-platform key. The final review judged both acceptable
   against the handoff's DoD wording.
2. **F1 (CRITICAL, pre-existing)** — PtyServer crash dumps log `cmd_env` incl.
   `ANTHROPIC_AUTH_TOKEN`. Filed as **issue #1455**. Action on you: **rotate
   `DEEPSEEK_API_KEY` + `KIMI_CODING_API_KEY`** (the proof hosts' keys).
3. **Merge adjacency**: PR #1454 (codex roster, opened per your instruction)
   touches the same `@adapters` hunk this branch edits — whichever lands
   second gets a trivial conflict.

## Method friction (for review's method-deltas)

- **The plan's gate list per PR was under-specified**: PR-3 never ran
  `arch.scan`, so its byte-copied `check_provider/1` introduced a
  `cross_file_duplicate_fn_groups` regression caught only in PR-6; PR-5's
  seed comment re-introduced a `DEEPSEEK_API_KEY` literal that failed the
  PR-1 allowlist gate unnoticed. Suggest the build-handoff template pin
  `arch.scan + the feature's own grep gates` into EVERY slice's gate list,
  not just the retirement slice.
- **Per-app vs root-scope test runs diverge silently**: PR-4's new tests
  passed per-app but collided at umbrella-root (registry double-boot).
  Reviewers should run touched suites at ROOT scope at least once per task.
- **Subagent infrastructure turbulence**: 4 dispatch failures on a broken
  model alias + 1 stall + 1 session-limit cutoff. The ledger + uncommitted-
  work checks made every recovery lossless; worth keeping the
  "verify tree before re-dispatch" habit as standard.
- **Vendor docs drift fast**: the Kimi guide's recommended model string
  changed (`kimi-k3` → `kimi-k3[1m]`, + a new FABLE tier var) within 48h of
  the research fetch. Profile values should carry proven-access dates (they
  do) and be re-checked at proof time (they were — and it caught the
  subscription/platform split).

## Merge request

Merge `feat/cc-custom-backends` → `main` at the lead's order (16 commits;
PR #1449 updated with this return). Independent of #1445. Watch the #1454
hunk adjacency (decision 3). After merge: destroy/recreate any legacy
deepseek agents as `cc-custom` (no shims, per locked #8) and reseed the
orchestrator definition (`mix ezagent.socialware.reseed_builtins orchestrator --force`).
