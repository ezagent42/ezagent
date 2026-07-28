# 日报 · ruihua · 2026-07-16

**分支 / PR:** `docs/workspace-self-service-product-plan` → #1436（draft）· base `main`

## 今天做了什么 / 产出

- `文档: docs/plans/2026-07-16-workspace-self-service-product-plan.md` — 基于 PR #1427 的工程缺口清单，逐条撰写 10 条缺口的用户旅程（happy path）+ 验收标准 + 情绪曲线 + 按冷启动阻塞顺序排优先级（4 批）。G4 含 cap-signing 依赖未就绪时的降级/占位方案。请 lead 审核优先级排序和 G4 降级方案是否与工程现实对齐；通过后可作为 UI 开发的验收基准。
- `文档: docs/together/2026-07-16/returns/ruihua-workspace-product-plan.md` — 给 zyli 的 return，标注 G6（UI 可读性 5 痛点）和 G7（onboarding 向导）为他 UI 工作的讨论起点。
- `Skill: ~/.claude/skills/ezagent-productize-gaps/SKILL.md` — 将今天的「工程缺口 → 产品计划」流程沉淀为可复用 skill。
- `群消息：` 已 @ 李震宇，告知 PR #1436 链接 + 重点看 G6/G7 + 建议下一步。

## 设计决策

- **优先级排序原则：按「用户冷启动能走到第几步」而非技术难度。** 无依赖的纯 UI 闸门（G1-G3）先拆 → 核心价值链路（G4-G5）→ 体验打磨（G6-G7）→ 业务闭环（G8-G10）。G4 放第二批而非第一批的理由：有 cap-signing 外部依赖，先让用户进门再等钥匙。
- **G4 降级方案选 stub_grant 而非直接修 role check。** role check 会让权限语义散落两处，增加后续清理成本；stub_grant 显式标记临时 + telemetry 可审计 + 切换后归零即确认信号。
- **G1 分清了 admin Settings 页和用户关门页两个角色。** 缺口清单本身写了两个东西（admin UI 开关 + 关门页申请入口），产品计划拆成两条独立路径，避免角色混淆。

## 下一步计划（必填）

- 和 zyli 对齐 UI 优先级（G6/G7），产出 UI 问题优先级清单——这是 07-16 plan 验收标准里的第二条
- 等 lead 审核 #1436 产品计划 + 拍板 G3 产品决策（一注册一租户 vs 开放 UI 创建）
- #1388 DealScout 原型已交付，提醒 lead 审核合并

## 待办 / 阻塞

- #1388 DealScout：等待 lead 审核合并（原型已完成，无阻塞在自己这边）
- UI 对齐：等 zyli 看过 PR #1436 后约时间

## 关联

- handoff: 无指向 designer 的 handoff。今日 work 来自 07-16 plan（ruihua track：接手 #1427 + UI 对齐）
