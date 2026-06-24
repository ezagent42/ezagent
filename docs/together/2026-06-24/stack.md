# dev-together merge stack — 2026-06-24 (lead)

_returned handoffs in analyzed merge order · dependencies · conflict check · reconciliation_

> `push` orders + analyzes only; merging happens in `close` (lead → `main`).
> Base `origin/main` at first push = `cd0d4067` (after per-dev handoffs #930);
> advanced to `ca2e6f2d` after #931/#933/#935 landed. This re-push (afternoon)
> folds in the Bug A return.

## Returns analyzed (1 merged · 1 blocked · 1 in-close)

| # | Task | Dev | PR | Branch | DoD | returned | status |
|---|---|---|---|---|---|---|---|
| 1 | cc-headless real implementation | @黄佳佳 (gagameow) | [#931](https://github.com/ezagent42/ezagent/pull/931) | `agent-flavor-headless-cc-headless-impl` | real SDK sidecar + cc-headless behavior + reply writeback + fake SDK + E2E seed/screenshots | on_time | ✅ **MERGED** `2c5bb208` |
| 2 | Bug A — session-snapshot race / silent `:cast` loss | @张宁→codex (lead-dispatched) | [#934](https://github.com/ezagent42/ezagent/pull/934) (draft) | `fix/session-snapshot-race` → `target/session-snapshot-race` | regression: concurrent `create_session/3` returns w/ durable finalized snapshot <5s + pre-delivery `:cast` failure logged & telemetered | ⏳ pending | ⛔ **BLOCKED** — E2E not yet run + return metadata incomplete (@林懿伦 2026-06-24: 先不要合并，等 return 文件更新) |
| 3 | Bug B — resolver Registry restart drops plugin resource types | lead (Claude) | — | `fix/resolver-restart-replay` | init/1 discovery-replay self-heal + idempotent re-reg + alias-attack still rejected + real-world e2e discovery; regression tests; todo销项 | on_time | 🔄 **IN CLOSE** — gates+codex green (1 MED fixed); admin-merge pending final precommit |

## Close outcome (#931)

Lead re-verified: `mix precommit` EXIT=0 (all suites 0 failures, grep-confirmed) + `check_invariants` EXIT=0 + 45 arch tests 0 failures. **codex adversarial-review of the core/domain diff:** all routing-correctness (cc/codex/curl/echo not mis-routed), cap-gating, slice-ownership, single-spawn-entry axes **sound**. Two MEDIUMs:
- **MEDIUM-2 (fixed at close):** `spawn_registry_call_sites`/`_modules` caps were bumped UP (43/38) while the actual count DROPPED to 41/36 (cc-headless template now uses `Kind.spawn`; sidecar uses `DynamicSupervisor` in the sidecar allowlist). Ratcheted caps DOWN to 41/36 so the gate stays tight (was masking 2 future regressions).
- **MEDIUM-1 (flagged, intended tightening — NOT fixed):** `openai_chat_plug` dropped prefix-magic flavor parsing (`cc_`/`codex_`/`curl_`) for `UriQuery.resolve(:flavor)`. This matches the no-prefix-parsing architecture (flavor = stored attr); restoring the prefix fallback would reintroduce the anti-pattern. Behavioral note: non-echo protocol targets must now be PROVISIONED (have a stored flavor), not conjured from a URI prefix. Resolved as comment-only fix #935 (option A: require provisioned targets, no auto-provision).

## Bug A (#934) — why BLOCKED (not stacked for merge)

The return (`returns/session-snapshot-race.md`) reports: post-#912 the create-time snapshot race was **not reproducible** on current main (a new regression proves concurrent `create_session/3` returns with a durable finalized `KindSnapshot` <5s), so **no create-path production change** was made; the real fix is **observability** — `Ezagent.Invocation` now logs + emits `[:ezagent, :dispatch, :cast_failed]` telemetry for pre-delivery `:cast`/`reply: :ignore` losses (previously silent). Unit/regression + `precommit` + `check_invariants` all green per the return.

Held out of the merge stack because:
1. **E2E not yet run** — @林懿伦 explicitly requested holding the merge until the live E2E is done and the return file is updated.
2. **Ledger metadata incomplete** — the return lacks `returned_at` / `deadline` / `deadline_status` (ledger rule: a return without that metadata is `blocked` until the dev adds it).
3. Targets `target/session-snapshot-race`, not `main` — it stages onto a target branch for later combined Bug A/B promotion after review + E2E.

→ Re-stack on the next `push` once the updated return (with E2E evidence + metadata) lands.

## Bug B (`fix/resolver-restart-replay`) — IN CLOSE

Lead-track core bug (Allen owns the core-bugs track; codex=Bug A, Claude=Bug B). `init/1` now rebuilds the FULL resolver allowlist from source on every start (core first + runtime discovery-replay of each loaded plugin's `resource_types/0`), so a Registry restart re-registers plugin types instead of dropping them. Security preserved (owner-only `:protected`, write-once on both `<type>`+`backend_component`, core-first); idempotent on identical re-registration to avoid an OTP-release first-boot crash (advisor catch); per-plugin `rescue`+`catch` isolation (codex MED-1 fix). `docs/futures/todo.md` resolver-restart item marked RESOLVED. Going through its own branch → admin-merge after the final full precommit confirms EXIT=0 + every-suite-0-failures. (NOT part of #934's target-branch staging.)

## Reconciliation (every return accounted for)

| return file | disposition |
|---|---|
| `returns/cc-headless-real-implementation.md` | **stacked** (#1) → **merged** `2c5bb208` |
| `returns/session-snapshot-race.md` | **blocked** (#2) — E2E pending + missing `returned_at`/`deadline_status`; re-stack after return update |

(Bug B is a lead-track branch, not a `returns/` file; tracked as #3 above. zyli=人肉全流程验证 in-flight, not a code return; zhaomato=官网 owner-scoping; fatnine=#84 agent-console — none returned yet.)

## Conflict analysis

- **#934 (Bug A)** vs **Bug B**: disjoint surfaces. Bug A touches `ezagent_domain_session` integration test + `ezagent_core/lib/ezagent/invocation.ex` + `invocation_test.exs`. Bug B touches `ezagent_core/lib/ezagent/resource/fs_resolver/registry.ex` + resolver/world tests. No file overlap → no merge-order dependency between them.
- **#931** already merged clean; no open overlap.

## Close gate (per remaining entry, before any merge)

- [ ] **Bug A (#934)** — DO NOT MERGE yet. Await: live E2E run + updated `returns/session-snapshot-race.md` (with E2E evidence + `returned_at`/`deadline_status`). Then re-`push` to stack, run close gate, merge `target/session-snapshot-race`.
- [x] **Bug B** — `mix precommit` EXIT=0 + every-suite-0-failures (final run in progress) · `check_invariants` EXIT=0 · codex adversarial-review (1 MED fixed) → admin-merge `fix/resolver-restart-replay`.

---

## Evening reconciliation — FINAL state (supersedes the above)

The table above was the afternoon snapshot. Net state of `main` at end of day — all gate-verified by the lead (`mix precommit` EXIT=0 + every-suite-0-failures grep-confirmed + `check_invariants` EXIT=0; agent-authored PRs reviewed directly by the lead since codex-rescue orphaned on whole-PR jobs today):

| Return / task | Dev | PR | merge SHA | status |
|---|---|---|---|---|
| cc-headless real implementation | @黄佳佳 | #931 | `2c5bb208` | ✅ MERGED |
| Bug B — resolver restart replay | lead (Claude) | #937 | `a0543aee` | ✅ MERGED |
| Bug A — session-snapshot / silent cast | codex (lead-dispatched) | #934→#939 | `62c3caf7` | ✅ MERGED (E2E done; promoted via #939, #934 closed as subsumed) |
| agent-config backend | @黄佳佳 | #938 | `564775c9` | ✅ MERGED |
| agent-config READ cap-gate (#93) | lead (Claude subagent) | #943 | `fc2cbbb4` | ✅ MERGED |
| cf-container cost/suitability (research) | Claude (out_of_scope) | #941 | `1ebfaa69` | ✅ MERGED (docs) |
| containerize-mac-stack (PG+mihomo+cloudflared) | Claude (out_of_scope) | #942 | `9db82041` | ✅ MERGED (docker/docs) |
| LOGO.png | — | #940 | — | ✅ MERGED |
| umbrella test-isolation race fix (#92) | lead (Claude subagent) | `fix/test-isolation-sandbox` | — | 🔄 IN CLOSE — DataCase drainable-owner conversion (41 files); precommit run1 green, run2 confirming (race fix → multi-run) |
| **remove-localization-assumption** (workspace-locality gate, prep for distributed-BEAM scaling) | Claude | integ branch `remove-localization-assumption` @ `2a293c20` (PR1 `feat/workspace-locality-core-gate` + PR2 `feat/workspace-locality-plugin-invariants` pre-merged in) | — | ⏸️ **RECEIVED, HELD — NOT merged to main** (@林懿伦: defer; merge-timing under lead analysis) |

### remove-localization-assumption — held, merge-timing under analysis
Adds core `RuntimeIdentity` / `WorkspacePlacement` / `WorkspaceOwnerGate`; gates workspace-bound dispatch/spawn/session create+repair by workspace ownership; default resolver maps all workspaces to the local BEAM node (claims single-node no-op); adds a plugin workspace-locality contract + static invariant + a debt allowlist warning (`total=37`; `ENFORCE_WORKSPACE_LOCALITY_DEBT=1` flips warning→fail). Per @林懿伦, **not merged now** — the lead dispatched a read-only analysis to decide merge-now vs merge-at-close, checking: (1) does the locality-debt invariant fail `precommit` by default (would redden main) or is it warning-only; (2) are the new gates provably inert on a single node (no regression / no spurious denials); (3) rebase-conflict risk now vs deferring (deferring only helps if core stops churning before close). Disposition recorded on the next push once the analysis returns.

### Reconciliation (every return file accounted for)
- `returns/cc-headless-real-implementation.md` → merged `2c5bb208`
- `returns/session-snapshot-race.md` → merged via #939 `62c3caf7` (E2E completed)
- `returns/agent-config-backend.md` → merged #938 `564775c9`
- `returns/cf-container-cost-pg.md` → merged #941 `1ebfaa69` (out_of_scope)
- `returns/containerize-mac-stack.md` → merged #942 `9db82041` (out_of_scope)
- `returns/remove-localization-assumption.md` → **received, held** (not merged; merge-timing under analysis)
- (lead-track branches, not return files: Bug B #937 merged; #92 test-isolation in-close; #93 read-cap merged #943.)

---

## #956 — zhaomato official-site / hello AI page generation (NOT merged; rehab required)

**Disposition: held off `main`.** Branch `feat/official-site` (tip `34f64614`) cannot land as submitted. Two process lessons + one substantive finding.

### Lesson 1 — branch pulled too early; **rebase before close, every time**
`feat/official-site` branched well before today's merges and never rebased. The lead landed it by `git merge origin/main` into the branch tip (clean 3-way, **0 conflicts** — git merges the two final trees; it does *not* replay #956's intermediate commits, which is why no conflict surfaced even though a `git rebase` of the same branch trips 17 conflicts on an old intermediate commit `01c8ed51`). Going forward: **dev rebases their task branch onto current `main` and re-runs `mix precommit` before returning it** — stale branches push integration cost and gate-drift onto the lead at close.

### Lesson 2 (the real one) — **#956 was never green on its own tip**
The merge was not the problem; #956 ships **9 pre-existing failures independent of the merge**, proven by checking #956's parent `34f64614` directly:

1. **`generator_test.exs` (7 tests) stale vs #956's own rewrite.** #956 changed `parse_plan/1`'s contract (now returns `{plan, scope}`; `classify_plan/1` unconditionally returns `{:simple}` — "fan-out disabled for the shadcn era") but did not update its own test. Test file is byte-identical to `main`, where the *old* contract makes it pass. → lead synced the test to the new contract (now 5/5 green) + removed the provably-dead disabled-fan-out cluster (`generate_complex/6`, `gen_section/1`, `briefs_of/1`, the unreachable `{:complex}` clause) plus an independently-dead content-theme cluster (`generate_content_theme/1`, `extract_css/1`, `strip_layout_props/1`). `mix compile --warnings-as-errors` clean; `check_invariants` EXIT=0; 0 CJK literals (anti-CJK gate respected).
2. **`SpecTest` (4) + `HelloPageE2ETest` (1) stale vs #956's own shadcn migration.** Commit `67cf3321` migrated `spec.ex` to shadcn types (`Stack`/`Card`/`Heading`/`Button`/…) but these two test files still assert the old lowercase catalog (`page`/`section`/`heading`/`card`). Same class as #1 — #956's own unfinished migration. **Not yet fixed** (author's code/intent).
3. **4 core arch-baseline trips** — `DocCoverage` (395 > cap 392), `RawHomePath` (2 > 1), `EffectDiscipline` (127 > 126), `DatabaseAgnosticGuard`. Caused by #956's new code (written against the pre-rebase, looser manifest) now exceeding `main`'s tightened caps. `RawHomePath`/`EffectDiscipline` are genuine arch anti-patterns the gate is catching — "bump the cap to land it" would be exactly the workaround we reject; the proper fix is on #956's code (or an explicit, annotated cap-bump decision by the lead).

**Lead's green-on-its-own work** (generator dead-code + generator_test sync) is staged in worktree `.worktrees/hello-956` (passes compile-WAE / check_invariants / formatter), pending disposition. Items #2 and #3 are #956's own unfinished rehab → recommend handing back to @zhaomato with this punch-list, OR an explicit lead-authorized scope to finish the test rewrites + an annotated arch-cap decision. `mix precommit` stays red until #2+#3 are resolved; **not committed to `main`.**

### RESOLUTION — @林懿伦 directed the lead to finish all of #956 → LANDED (PR #961, `6cfabacd`)
Allen: "你帮zhaomato改完 #956 的所有修改" + "添加GitHub CI，未来类似问题不允许通过合并." Lead fixed all 6 reds (code-level, one disclosed cap-bump):
- **SpecTest(4) + HelloPageE2ETest(1)** — rewrote old lowercase catalog → shadcn (`Stack/Card/Heading/Text/Button`).
- **RawHomePath** — `claude_code.ex` used `Path.expand("~/.local/bin/claude")` → `System.user_home/0` (OS home ≠ EZAGENT_HOME, which the gate guards).
- **DocCoverage(+3)** — documented `chat/2` + `Surface.handle_set_shell/2`; restored `decompose/1`'s `@doc` (an interposed `@type` had silently cleared the pending `@doc` — the scanner treats `@type` as doc-consuming).
- **DatabaseAgnosticGuard** — `sanitize.ex` HTML regex `<\/?#{tag}>` false-tripped the SQL numbered-placeholder heuristic via the literal `?#{`; rewrote the equivalent quantifier as `\/{0,1}` (HTML, not SQL).
- **EffectDiscipline(+1)** — **annotated `# arch-cap-bump:` 126→127** (the only non-code-fix; reported to Allen): `handle_set_shell` persists the generated shell via `{:set, :shell}`+`{:set, :shell_css}`, within the surface slice (cross-slice stays 0). Intentional new effect, not a defect.

Gate: `mix precommit` EXIT=0 (24 suites, every one 0 failures) + `mix ezagent.check_invariants` EXIT=0, on Elixir 1.19.5 / OTP 28. Landed via new branch `feat/official-site-merged` → PR #961 admin-squash-merge (author branch `feat/official-site` left intact; #956 closed as superseded).

### CI ADDED — PR #962 (`ci/precommit-gate`)
GitHub Actions workflow `.github/workflows/ci.yml` runs `mix precommit` + `mix ezagent.check_invariants` on every PR + push to main (Postgres 16 service, Elixir 1.19/OTP 28, Node 25/pnpm 10). Had this existed, #956's never-green submission could not have been queued. **Follow-up (repo admin):** add a branch-protection required-check on `main` once #962's first run is green.

### Process lessons for the team (esp. @zhaomato)
1. **A PR must be green on its own tip before return** — #956 failed its own `--warnings-as-errors` + 6 tests/gates as submitted. Run `mix precommit` locally and confirm EXIT=0 before handing back.
2. **Rebase onto current `main` before return** — stale branches push integration cost + gate-drift onto the lead at close. (CI now enforces both.)
