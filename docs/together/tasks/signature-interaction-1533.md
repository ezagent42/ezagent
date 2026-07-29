# #1533 Signature Interaction 原型

- **id**: `signature-interaction-1533`
- **owner**: 瑞华 (ruihua)
- **status**: wip(draft)
- **历史**: started 2026-07-27 · est_done 2026-07-29 · actual —
- **关联**: PR #1533(draft)

## 目标
Agent 角色交接 + Session 创建的签名式交互原型。

## 验收
- [ ] Signature Interaction 原型草案定稿

## Handoff prompt

> Signature Interaction 原型草案：为两类场景设计「签名式」交互模式（用户对一个动作
> 显式签署/确认，而不是隐式发生）——
> 1. **Agent 角色交接**——一个 agent 把当前角色/职责交给另一个 agent 或人时，交接
>    动作需要一个明确的签署步骤（谁交、交给谁、交接什么范围）。
> 2. **Session 创建**——新建 session 时的签名式确认交互（对齐当前 CapBAC/entity-caps
>    体系里「谁能创建什么」需要显式授权轨迹，而不是静默创建）。
>
> 产出是**设计原型草案**（产品/交互设计输入，不是代码实现）——参照现有 MFU demo
> （`mfu-demo/doc/tree/skill-tree.md`）的原型产出方式：可点击的静态原型或线框图 +
> 交互流程说明。草案定稿后交给 Allen/相关实现方评估是否/何时落地为代码。
