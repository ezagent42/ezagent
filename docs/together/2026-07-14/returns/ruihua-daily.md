# 日报 · ruihua · 2026-07-14

**分支 / PR:** `docs/hire-value-chain-0706` → #1378 (new) · base `main`

## 今天做了什么 / 产出

### 已完成（off-plan 基础建设）
- `docs/website-demo/` 目录重整：assets 分层 + L1/L2/L3 页面分级 + 孤立归档 + 交叉引用全量修正
- `doc/page-flow.md` — 页面流转关系 living doc，作为后续设计工作的 single source of truth
- `ezagent-together` SKILL.md 写入设计交付规范（6 条规则 + 设计 return 模板 + 验收 gate）
- flywheel 解耦 design-system 本地副本，改为 CDN 引用

### ⬜ Plan 分配任务（待开始）
- 飞轮原型 #1372 IA/视觉接入真实 world/hello LiveView 面（设计输入，走 Feishu）
- 作为 hello/官网面设计参照，对接 zhaomato 的 hello live E2E

## 设计决策
- L1 页面放根目录（从 mainsite 直接触达），L2/L3 收入子目录 — 遵循设计交付规范规则 #2
- 孤立原型（puncture/、team-office.html）归档而非删除 — git 历史可追溯
- site-nav.js 用 `EZD_SITE_ROOT` 变量适配不同页面深度，替代 `<base>` 标签（避免全局副作用）

## 下一步计划（必填）
- 开始 Plan 分配任务：将 #1372 飞轮的 IA/视觉方向写成设计输入文档（走 Feishu），对接 zhaomato 的 hello live E2E 产品面
- 产出的设计文档和 HTML 原型按新 workflow 放入 `docs/website-demo/` 对应文件夹，更新 `doc/page-flow.md`

## 待办 / 阻塞
- 无

## 关联
- yesterday review: #1372 (flywheel demo 已合入), #1373 (designer 交付规范 已合入)
- today plan: 飞轮 IA/视觉接入 LiveView 面（设计输入，走 Feishu）
