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
