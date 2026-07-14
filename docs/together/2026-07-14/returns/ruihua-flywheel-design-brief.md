# flywheel 飞轮 IA/视觉 → world/hello LiveView 面 设计参照 · ruihua · 2026-07-14

**分支 / PR:** `docs/hire-value-chain-0706` → #1378 · base `main`

## 演示了什么
- `flywheel/design-brief.md` — 面向研发的设计说明：将 #1372 飞轮原型的 IA 结构和视觉方向映射到真实 world/hello LiveView 面
- 作为 zhaomato hello live E2E + hello↔kanban 融合的设计参照

## 怎么看
- 文档：https://github.com/ezagent42/ezagent/blob/docs/hire-value-chain-0706/docs/website-demo/flywheel/design-brief.md
- 飞轮原型（可直接打开看效果）：https://github.com/ezagent42/ezagent/blob/docs/hire-value-chain-0706/docs/website-demo/flywheel/gallery.html

![mainsite 截图](../../website-demo/assets/images/mainsite-screenshot.png)

## 设计理由
- 本章文档直接放在 `flywheel/` 文件夹内——研发打开文件夹就能同时看到原型 HTML 和设计说明，不增加查找成本
- IA 映射表用 🔴🟡 诚实标注真实面的存在状态，避免研发误以为 HTML 原型里的东西都已经有了
- 术语对齐 GLOSSARY.md：Gallery 货架展示的是 socialware 产品（config-only Definition），不是 plugin（代码扩展）
- Flywheel homesite 风格与 World shadcn 风格各自保持——只移植结构模式，不统一视觉

## 对应本周目标
- W29 统一验收自举链：hello live E2E + hello↔kanban 融合。本设计说明为 hello 产品面提供 IA/视觉参照

## 关联
- PR #1372：飞轮原型（静态 HTML demo）
- PR #1373：designer 非代码交付 → PR 约定
- handoff：`docs/together/2026-07-09/handoffs/homesite-gallery-flywheel.md`（W-G/H-G 任务定义）
- 飞书已交付 zhaomato
