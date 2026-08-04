# #1684 clean-slate per-grant cap 撤销 —— 折入 CI 隔离整合分支

- **id**: `per-grant-cap-revocation`
- **owner**: Allen 轨道(实现: kimi agent)
- **status**: review(已折入整合分支, 待随之合入; 延 1d —— 08-04 仍 OPEN)
- **历史**: started 2026-07-31 · est_done 2026-08-03 · actual —
- **关联**: PR #1684(open, head dbdf4ad76) · 折入 `integrate/ci-isolation-dod24-20260803`(merge 8bd91ec6a) → 随 `ci-isolation-integration` 一次合入 main · 后续线: DeliveryOutbox final plan #1670(merged 07-31), 实现切片待 plan
- **branch**: `feat/p2-per-cap-revocation`
- **依赖**: 整合分支一次完整 `mix precommit` 闸 + merge

## 目标

clean-slate per-grant revocation: grant Store 作唯一权威 + durable revocation ledger/epoch
+ 原子 v2 撤销 cutover + actor lifecycle 绑定 identity Store —— 撤掉遗留 cutover hooks 与
双协议, 撤销语义一次到位(不再打兼容补丁)。

## 验收

- [x] #1684 实现完成(evidence: head dbdf4ad76, 含 P2 return)
- [x] 折入整合分支(evidence: merge 8bd91ec6a; identity_migration_parity_test 冲突按 user-approved 删除保留)
- [ ] cap×wipe semantic rebase(#1693 wipe 已 08-03 入 main ab12c63da —— 与 per-grant 撤销的语义重叠在整合合并前解, 见 `ci-isolation-integration`)
- [ ] 整合 PR 合入 main → #1684 评论标 subsumed(最终 main merge SHA)并关闭, 不留重复 open PR
- [ ] DeliveryOutbox(#1670 plan)实现切片 handoff → plan(下一增量, 整合落地后)

## Handoff prompt

> 整合合入后的 reconcile + 下一增量, 两步(实现本体已由 kimi 完成并折入整合分支,
> 见 `ci-isolation-integration`):
>
> (1) 待整合 PR 合入 main 后: 核对 `origin/main` 含 merge 8bd91ec6a 折入的 per-grant
> revocation 全部改动; 然后在 #1684 评论 "subsumed by <最终 main merge SHA>" 并关闭,
> 不留重复 open PR(Close PR state 规则)。
>
> (2) DeliveryOutbox 实现切片: 以 #1670 final plan(merged 07-31)收敛的五问为准,
> 切第一片 handoff —— 单 PR 可验收粒度, 走 clarify_first → build; 派发前与 lead
> 对齐切片边界, 不与 `ci-isolation-integration` 在飞期间并发改同面。
