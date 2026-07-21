# Return: G5 stale capability reconciliation

> **Task:** 修复普通用户首次发送被旧 cap 拒绝、消息不进入列表的问题
> **Branch:** `fix/g5-cap-reconciliation`
> **PR:** https://github.com/ezagent42/ezagent/pull/1477
> **Dev:** zyli-developer + Codex
> **returned_at:** 2026-07-20 17:49 +0800
> **deadline:** 未设
> **deadline_status:** deferred
> **Rebase-base SHA:** `fe290643133cf3f8e9de932236c5d64623748122`
> **PR head:** `9103afd4f5726e0a6de1e2089f644d75be069995`

## Scope and outcome

本分支修复 G5 用户发送消息前的两层 capability 生命周期缺陷：

1. Session 补发逻辑不再把字段匹配等同于有效授权。只有 capability
   identity 精确一致，且目标 Kind 用当前 authority 验证签名有效时，才跳过补发；
   旧 key、损坏签名或错误 receiver 的 artifact 会重新签发并替换。
2. World 新增 `Ezagent.World.PresenterCaps`。所有 World action 统一从当前
   Identity cap store 与挂载期 bootstrap caps 合并出 dispatch caps；相同 identity
   以当前 artifact 覆盖挂载快照。
3. 新增 drift gate，禁止 World action 重新直接读取 LiveView 的
   `current_caps` 快照。
4. Hello front-desk 的 `self-target + per-instance action` 是独立的第二个根因，
   已拆成 Allen handoff，不在本 PR 中混修：
   `docs/together/2026-07-20/handoffs/allen-self-target-per-instance-cap-action.md`。

## DoD reconciliation

| # | DoD line | status | proof / open decision |
|---|---|---|---|
| 1 | 同 identity 但签名无效的 Session participation cap 不得抑制补发。 | met | `session_participation_caps_test.exs` 的 invalid-current-identity 用例先红后绿；补发后签名被替换。 |
| 2 | 有效的当前 artifact 保持幂等，不在每次导航重新签发。 | met | 同测试文件的 repeated-mount 用例断言 `signature` 与 `granted_at` 不变。 |
| 3 | World dispatch 使用当前 presenter caps，不长期使用 mount 快照。 | met | `Ezagent.World.PresenterCapsTest` 断言 current artifact 按 identity 覆盖 mounted artifact。 |
| 4 | World 不得重新出现 action 直接读取 `current_caps`。 | met | `PresenterCapsDispatchGateTest` 扫描 World action 与 `WorldLive`，allowlist 仅 `PresenterCaps` 真源。 |
| 5 | 保持目标 Kind 签名、显式携带、`Cap.Verifier` 单一严格验证边界。 | met | Core CapBAC invariants：394 tests，0 failures；`Authority.verify_current/2` 仍只有 `Cap.Verifier` 调用。 |
| 6 | Session 与 World 相关回归套件通过。 | met | Session 定向：15 tests，0 failures；World 全量：265 tests，0 failures。 |
| 7 | `mix precommit` 与 PR-head CI 全绿。 | deferred | 本地 precommit 的本次新增 doc regression 已修复；随后命中与 diff 无交集且串行仍失败的既有 PendingDelivery 测试。GitHub 所有 job 又因账户付款失败或 spending limit 未启动，见下方 CI 证据。Lead 需恢复 Actions 后重跑并决定 baseline 测试处置。 |
| 8 | 创建 PR 并提供第二根因给 Allen 的独立 handoff。 | met | PR #1477；handoff 路径见 Scope 第 4 项。 |

**Method friction:** 本任务最初容易被缩成“发送前 reload cap”，但真实问题同时位于
producer 的错误幂等判断和 consumer 的挂载期快照。另一个流程阻塞是 GitHub Actions
账单状态会让所有 job 在零 step 情况下瞬时失败；return 机器门应区分代码红灯和 runner
根本未启动，但在规则调整前本 return 必须保持 `deferred`。

## Verification evidence

| command | result |
|---|---|
| `mix test apps/ezagent_core/test/invariants` | PASS — 394 tests, 0 failures |
| Session capability focused suites | PASS — 15 tests, 0 failures |
| `mix test apps/ezagent_plugin_world/test` | PASS — 265 tests, 0 failures |
| `mix ezagent.doc.scan` | PASS — counters 0/0, 404/404, 0/0 |
| `git diff --check` | PASS |
| `mix precommit` | DEFERRED — unrelated `grant_recipe_caps_board_scope_test.exs:159` expects PendingDelivery 0, actual 1; reproduces when run alone |

The two additional full-suite load failures observed during precommit were rerun individually:

- `session_create_orchestrator_decouple_test.exs:90` — PASS, 1 test.
- `session_instance_set_test.exs:51` — PASS, 1 test.

## PR-head CI blocker

CI run: https://github.com/ezagent42/ezagent/actions/runs/29732657737

Every prerequisite job completed in about three seconds with zero executed steps. GitHub check
annotations report:

> The job was not started because recent account payments have failed or your spending limit needs to be increased.

The same annotation appears on the CI, return-advisory, and dev-together protection runs.
Deterministic/full-suite jobs were therefore skipped. Evidence is also recorded in PR comment:
https://github.com/ezagent42/ezagent/pull/1477#issuecomment-5020902220

## Deferred decisions for lead

1. Restore GitHub Actions billing/spending capacity and rerun #1477 checks.
2. Decide whether the independently reproducible PendingDelivery assertion is a main baseline fix
   or an intentional contract update; it has no changed-file overlap with #1477.
3. Only after PR-head CI is green, change this return from `deferred` and admit it to the stack.

## Merge request

Review PR #1477, but do not mark READY TO MERGE from this return while the machine gate is
blocked. Code commit is `94c88260a`; Allen handoff commit is `9103afd4f`.
