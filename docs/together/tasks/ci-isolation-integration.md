# CI 隔离整合 —— 轮换 intra-suite 隔离 flake 系统性修复 → main 真绿 → canary 放行

- **id**: `ci-isolation-integration`
- **owner**: Allen 轨道(cc 协调)
- **status**: wip
- **历史**: started 2026-08-02 · est_done 2026-08-03 · actual —
- **关联**: branch `integrate/ci-isolation-dod24-20260803`(HEAD 5cfb64256, ahead 33, 本地未 push) · 折入 PR #1684(head dbdf4ad76, merge 8bd91ec6a) · 残留 flake #184(轮换 intra-suite 隔离) · handoff `docs/together/2026-08-03/handoffs/integrated-ci-fixes-continuation.md`
- **依赖**: 无 —— 本分支是 main 真绿的唯一关键路径; C8 v5 / DeliveryOutbox 实现切片都暂缓等它落地

## 目标

分片各自绿(13/14)之后, 全套连跑仍轮换红(domain 一次、web 下一次)的 intra-suite 隔离
flake(#184 残留)做**系统性修复**, 五块折入一支整合分支一次过闸:

1. **#1684 clean-slate per-grant 撤销**(kimi) —— merge 8bd91ec6a; parity-test 冲突按已定删除保留。
2. **DoD24 SessionViewRegistry snapshot/restore** —— 84a5afb32。
3. **actor/SQL 沙箱 owner-lifecycle 收容**(#184 systemic) —— fabd595a9(from 9b1bc3f2d)。
4. **全局 env/PATH 隔离**(async VM-global Application/System env) —— 296f047c3(from 1a11268a0)。
5. **历史 migration-parity 测试移除** —— 5cfb64256(from f9e6e265d; 267 tests / 4,688 行)。

源分支分项证据已齐(见 handoff), 但**不替代**整合后一次完整 `mix precommit`。

## 验收

- [x] 五块折入, HEAD 5cfb64256, worktree clean, `git diff --check` 过(evidence: handoff 2026-08-03)
- [ ] 整合分支上**一次完整 `mix precommit` 诚实绿**(不拆回源 PR、不 mask、不盲加 timeout; 红则只修 demonstrated integrated-state 失败后重跑)
- [ ] push + 一个 PR → 正常 merge(无 force push) → `origin/main` 含整合 HEAD/merge
- [ ] #1684 标 subsumed(注明最终 main merge SHA)关闭, 不留重复 open PR
- [ ] #189 test-defects E/F/D 在整合后 main 验证绿(07-30 结转, 发布闸剩余项; 已绿则验证+记录回本项, 红则 systematic 小 PR 修复)
- [ ] main 真绿 → canary 放行评估(auto-reflow 已移除 #222, 数据同步手动)

## Handoff prompt

完整 continuation handoff(含当前状态/证据/DoD 七条)见
`docs/together/2026-08-03/handoffs/integrated-ci-fixes-continuation.md`(随 PR #1689
入 main)。核心约束:

> 确认目标 worktree `/Users/h2oslabs/Workspace/ezagent/.worktrees/integrate-ci-isolation-dod24-20260803`
> HEAD=5cfb64256 未变且 clean; 确认无残留 `mix precommit`/BEAM 子进程; 从该 worktree 跑**恰好一次**
> 完整 `mix precommit` 并留存完整 exit code/log; 红则系统性调试、只修整合态失败, 不 mask、不拆回源 PR;
> 绿后 push → 一个 PR → 正常 merge → 核对 origin/main; 再把 #1684 标 subsumed 关闭。
> 另: 合入后顺手验证 #189 test-defects E/F/D(见验收第 5 条, 07-30 结转)。
