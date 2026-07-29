# hooks sub-step-gate 修复

- **id**: `hooks-substep-gate-1601`
- **owner**: gaga
- **status**: done
- **历史**: started 2026-07-27 · est_done 2026-07-28 · actual 2026-07-28
- **关联**: PR #1601(merged, gaga) · #1603/#1605(merged, cc 折入 review 修复)

## 目标
sub-step-gate 应 gate 被提交的 worktree；测试步骤收窄 ci.fast。

## 验收
- [x] #1601 — sub-step-gate 修复（gaga）（evidence: merged 07-28）
- [x] #1603/#1605 — cc 折入 review 修复（`git -C` 提交目标解析 + pre-push 跳过
      deps-missing worktree）（evidence: merged 07-28）

## Handoff prompt（回溯归档）

07-28 派发，非本文件事后重构。实际派发内容摘要：

> dev-loop 的 sub-step-gate hook 之前 gate 的是当前工作目录而非被提交的 worktree
> （多 worktree 并行开发场景下会 gate 错目标），gaga 修复为正确解析被提交的
> worktree；同时把 gate 里跑的测试步骤收窄到 `ci.fast`（原先跑得更宽，拖慢每次
> commit 的反馈循环）。cc 在 review 这个修复时发现并顺带折入两个相关问题：
> `git -C` 提交目标解析的边界情况（#1603）、pre-push 检查在 deps-missing 的
> worktree（例如刚 clone 还没跑 `mix deps.get` 的临时 worktree）里应该跳过而非
> 报错阻塞（#1605）。四者一起验证后合入。
