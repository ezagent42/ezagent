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

1. **接受两个 deferral?（语义 = 延后转 issue，不挡本次合并）**
   (a) **cc-headless-custom 实况 spawn** — headless flavor 的单元/集成覆盖完整
   （52 tests：env 穿线、冷重启、fail-closed)，缺的只是实况拉起，被 F2
   `{:calling_self}` + F4 sidecar nil-config 两个 PRE-EXISTING 通用缺陷挡着
   (plain cc-headless 同样复现，非本分支引入）。接受 = 先合，F2/F4(+F3
   ad-hoc create lane）转跟进 issue。不接受 = headless 实况修完再合。
   (b) **开放平台 kimi 泳道** — 已用 kimi-coding（订阅）泳道证明 Kimi 设施；
   平台泳道只差一把开放平台 key，届时跑现成 probe 命令即可，零开发。
2. **F1(CRITICAL, pre-existing)——泄露路径已知、受控、待修，不是"还在漏"**
   PtyServer 崩溃 dump 打 `cmd_env` 含 `ANTHROPIC_AUTH_TOKEN`，仅在子进程异常
   崩溃时发生、落本地日志；issue **#1455** 已立案（修复方向：logged state 不
   留 raw child env)。local 实测期间两把 key 进过一次本地日志（原始日志已脱
   敏）——**请轮换 `DEEPSEEK_API_KEY` + `KIMI_CODING_API_KEY`**，轮换即归零。
3. **合并顺序（是谁先合）** — **#1454 尚未合并，CI 全绿，随时可合。**
   建议先合 #1454（小且独立），本分支随后 rebase 解 trivial hunk（两边碰
   `credential_adapter_completeness_test.exs` 的 `@adapters` 附近：它改 codex
   namespace、本分支删 deepseek 条目，语义不冲突）。

## Method-deltas 落地路径（流程规定 + 提案）

流程规定（dev-together):dev 在 return 里 capture method-friction（见下节）;
**lead 在 `review` 里 promote** —— 写进 review 的 method-deltas 节，再变成
dev-together skill PR 或 tracked process-debt。**dev 不改 skill(single
writer)，合稿权在 lead。**

三条 delta 的建议落点（lead 勾选后可成一页 skill diff):

| delta | 落点 |
|---|---|
| ① 每个 slice 的门禁集钉入 `mix test apps/ezagent_core/test/invariants/`（本地门禁集与 CI deterministic gate 对齐——本轮 4 个红全是这类） | `.claude/skills/dev-together/references/handoff-standard.md` 门禁节 |
| ② inline 行尾注释 marker 对 formatter 版本不稳定（1.19.2 抬注释）→ 涉及同行注释 marker 的 gate 优先用测试自己的 path allowlist | 同上（或 ezagent-developer skill 约定节，lead 定） |
| ③ 厂商文档快速漂移 → profile 值带取证日期、实测时复核（本轮抓到 kimi-k3→k3[1m] 漂移 + 订阅/平台分裂） | handoff-standard 的 research-handoff(reproduce-first）节 |

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
