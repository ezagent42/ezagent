# #1301 dealscout 完整改版

- **id**: `dealscout-1301`
- **owner**: jjkysy
- **status**: wip
- **历史**: started 2026-07-24 · est_done 2026-07-29 · actual —
- **关联**: PR #1301(open) · 推 mergeable

## 目标
真组合 socialware / 真页面真数据 / 四旅程。

## 验收
- [ ] dealscout 完整改版（五段完整）推到 mergeable

## Handoff prompt

> dealscout 完整改版，三个具名交付轴：
> 1. **真组合 socialware** — dealscout 页面真正组合既有 socialware 能力（不是独立
>    重造一套并行实现），复用统一的 composition/caps 机制。
> 2. **真页面真数据** — 去掉 mock/占位数据，接入真实数据源和真实页面渲染路径。
> 3. **四旅程** — 覆盖 dealscout 场景下的四条用户旅程（具体旅程定义以 PR #1301 现有
>    diff/设计记录为准，本文件不重复枚举）。
>
> 验收标注为「五段完整」——指改版拆成五个阶段/模块，全部完成才算数，不是部分完成
> 就能标 mergeable。推到 mergeable 前确认 CI green + rebase 到最新 main + 五段
> 各自都有可核实的证据（不是自称完成）。具体实现细节以 PR #1301 的既有 diff 和
> review 意见为准。
