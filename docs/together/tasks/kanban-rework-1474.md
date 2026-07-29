# #1474 kanban 协作改版二轮

- **id**: `kanban-rework-1474`
- **owner**: jjkysy
- **status**: wip(draft)
- **历史**: started 2026-07-24 · est_done 2026-07-29 · actual —
- **关联**: PR #1474(draft) · 周末仍活跃(07-26 更新)

## 目标
人本位分享 / tab 恒显 / 分享二期。

## 验收
- [ ] kanban 协作改版二轮（权宜全部溶解对齐读面正路），推到 mergeable

## Handoff prompt

> kanban 协作改版二轮，三个具名交付点：
> 1. **人本位分享** — 分享逻辑从「按 board/资源」转成「按人」为中心建模（谁能看到什么
>    由接收人身份决定，而不是资源上挂一份静态分享列表）。
> 2. **tab 恒显** — 协作相关的 tab/入口在 UI 里保持常驻可见（不是条件渲染消失）。
> 3. **分享二期** — 一期分享机制的续作，具体范围以 PR #1474 现有 diff + 一期实现为准。
>
> 核心要求是**「权宜全部溶解对齐读面正路」**：现有实现里为了赶一期进度打的临时补丁/
> 权宜实现，二轮要全部消解掉，改成和正式读面（world/socialware 统一读模型）对齐的
> 正路实现，不能留权宜代码转正。
>
> 推到 mergeable：CI（precommit + check_invariants）green、rebase 到最新 main。
> 具体实现细节以 PR #1474 的既有 diff 和 review 意见为准（本文件不重复该 PR 里的
> 代码级讨论）。
