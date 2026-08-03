# #1684 clean-slate per-grant cap 撤销 —— 折入 CI 隔离整合分支

- **id**: `per-grant-cap-revocation`
- **owner**: kimi
- **status**: review(已折入整合分支, 待随之合入)
- **历史**: started 2026-07-31 · est_done 2026-08-03 · actual —
- **关联**: PR #1684(open, head dbdf4ad76) · 折入 `integrate/ci-isolation-dod24-20260803`(merge 8bd91ec6a) → 随 `ci-isolation-integration` 一次合入 main · 后续线: DeliveryOutbox final plan #1670(merged 07-31), 实现切片待 plan
- **branch**: `feat/p2-per-cap-revocation`
- **依赖**: 整合分支一次完整 `mix precommit` 闸

## 目标

clean-slate per-grant revocation: grant Store 作唯一权威 + durable revocation ledger/epoch
+ 原子 v2 撤销 cutover + actor lifecycle 绑定 identity Store —— 撤掉遗留 cutover hooks 与
双协议, 撤销语义一次到位(不再打兼容补丁)。

## 验收

- [x] #1684 实现完成(evidence: head dbdf4ad76, 含 P2 return)
- [x] 折入整合分支(evidence: merge 8bd91ec6a; identity_migration_parity_test 冲突按 user-approved 删除保留)
- [ ] 整合 PR 合入 main → #1684 评论标 subsumed(最终 main merge SHA)并关闭, 不留重复 open PR
- [ ] DeliveryOutbox(#1670 plan)实现切片 handoff → plan(下一增量)

## Handoff prompt

实现本体已由 kimi 完成并折入整合分支; 剩余动作是整合合入后的 reconcile(见
`ci-isolation-integration` 验收第 4 条)。无新派发 prompt。
