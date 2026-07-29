# #1501 held+pending caps 收敛幂等（rework）

- **id**: `caps-consolidation-1501`
- **owner**: gaga
- **status**: review(rework 中)
- **历史**: started 2026-07-24 · est_done 2026-07-29 · actual —
- **关联**: PR #1501(open) · 对抗性评审打回，rework 中

## 目标
held + pending caps 合并进 effective view（grant 幂等、fail-closed）。

## 验收
- [ ] 补齐 effective view 的 pending absorb 缺口
- [ ] grant 操作幂等（重复 grant 不产生重复/不一致状态）
- [ ] fail-closed（absorb 路径异常时不能默认放行）
- [ ] 重评审通过

## Handoff prompt

> #1501 held+pending caps 收敛幂等——对抗性评审已经打回一轮，具体缺口是：effective
> view（cap 持有者最终看到的「我实际有效的权限集合」）目前只正确合并了 held caps，
> 没有把 pending（已 grant 但还没被 absorb 进 held 状态的）caps 一并纳入合并逻辑，
> 导致 effective view 可能少算或状态不一致。
>
> SCOPE：
> 1. **pending absorb** — effective view 计算路径要同时读 held + pending 两个来源，
>    合并成一个统一视图，而不是只认 held。
> 2. **幂等** — 对同一 target 重复调用 grant（比如网络重试、UI 重复点击）不能产生
>    重复的 pending/held 记录，也不能因为重复调用而改变最终 effective 状态。
> 3. **fail-closed** — absorb 路径（pending → held 的转移）如果失败或遇到异常状态，
>    默认结果必须是「该 cap 不生效」，不能默认放行（对齐 authz 结构化正确性的团队
>    共识：错误路径必须让 ActionSet 无法构造，而不是靠事后检查）。
>
> 修完后重新过对抗性评审（codex），通过后由 cc gate + merge。具体的评审打回意见
> 以 PR #1501 的评论线为准（本文件是任务追踪摘要，不是评审记录本身）。
