# 日报 · ruihua · 2026-07-14

**分支 / PR:** `docs/hire-value-chain-0706` → #1378 (new) · base `main`

## 今天做了什么 / 产出

### 已完成（off-plan 基础建设）
- `docs/website-demo/` 目录重整：assets 分层 + L1/L2/L3 页面分级 + 孤立归档 + 交叉引用全量修正
- `doc/page-flow.md` — 页面流转关系 living doc，作为后续设计工作的 single source of truth
- `ezagent-together` SKILL.md 写入设计交付规范（6 条规则 + 设计 return 模板 + 验收 gate）
- flywheel 解耦 design-system 本地副本，改为 CDN 引用

### ✅ Plan 分配任务（已完成）
- `1378-flywheel-to-liveview/design-brief.md` — IA 映射表 + 视觉方向 + hello↔kanban 连接点 + 不做事项清单
- `1378-flywheel-to-liveview/hello-entry-flow.html` — greeter → live 回复 → kanban 连接的用户旅程参考
- `doc/page-flow.md` 已更新设计参考节
- 受众 zhaomato，不改代码，设计输入最终走 Feishu

### 🔴 重点发现：真正的 Gallery 还不存在

IA 映射过程中发现关键事实：flywheel 原型的 gallery 是 socialware marketplace（浏览 → 试用 → Fork → 上架），而真实 WorldLive 里**没有任何页面对应它**。WorldLive `/plugins` 显示的是代码插件，不是 socialware 产品。

| Flywheel 页面 | 真实面对应 | 状态 |
|--------------|-----------|------|
| gallery 货架 | — | 🔴 不存在 |
| product-detail | — | 🔴 不存在 |
| world-step (发布) | Fork 后端/C管线已落地 | 🟡 缺前端入口+表单 |
| publish-landing | — | 🔴 不存在 |

这意味着 flywheel IA → 真实面的映射，多数行是 **"不存在"而非"改现有页面"**。设计参考的价值在于告诉 zhaomato：构建 hello live E2E 时，哪些 flywheel 的结构应该被带入。

## 设计决策
- L1 页面放根目录（从 mainsite 直接触达），L2/L3 收入子目录 — 遵循设计交付规范规则 #2
- 孤立原型（puncture/、team-office.html）归档而非删除 — git 历史可追溯
- site-nav.js 用 `EZD_SITE_ROOT` 变量适配不同页面深度，替代 `<base>` 标签（避免全局副作用）
- Flywheel IA 映射关键是 "结构对照" 而非 "风格统一" — homesite 暗色玻璃不进 world 的 shadcn 体系
- Hello↔Kanban 连接点设计标注 "松耦合，非最终挂载"（诚实策略，参照 flywheel world-step 占位页做法）
- **Plugin ≠ Socialware**：Gallery 货架展示的是 socialware 产品（config-only Definition），不是 plugin（代码扩展）。WorldLive `/plugins` 页不是 gallery 的对应物——这个区分写入 design-brief.md 术语约定

## 下一步计划（必填）
- 设计输入文档走 Feishu 交付给 zhaomato
- 若 Plan 有后续设计任务，按新 workflow 继续：新建文件夹 → 设计说明 → HTML 产物 → 更新 page-flow.md → return

## 待办 / 阻塞
- 无

## 关联
- yesterday review: #1372 (flywheel demo 已合入), #1373 (designer 交付规范 已合入)
- today plan: 飞轮 IA/视觉接入 LiveView 面（设计输入，走 Feishu）
