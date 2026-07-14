# Website Demo · 页面流转关系

> **Living document — single source of truth.** 只记录页面之间的跳转关系。新增/删除/改动页面时更新本文档。
>
> 最后更新：2026-07-14

---

## 页面层级

### L1 — 从 mainsite 直接进入的页面（根目录）

| 页面 | 文件 | 从 mainsite 如何进入 |
|------|------|---------------------|
| **Mainsite**（官网首页） | `mainsite.html` | — 入口 |
| **Login**（登录） | `login.html` | 导航栏 "登录 · Login" 按钮 |
| **Driver License**（指挥官驾照） | `driver-license.html` | ① "测测你能指挥几个 agent" hookline ② 成就卡片 "指挥官驾照" |
| **World Demo**（试玩 world） | `world-demo.html` | ① "试玩 · Try world →" 按钮 ② 成就卡片 "试玩者" |
| **Hello Demo**（试玩 hello） | `hello-demo.html` | "试玩 · Try hello →" 按钮 |
| **Achievement Center**（成就中心） | `achievement-center.html` | 导航栏 "我的主页 · Me"（需登录态） |
| **Flywheel Gallery**（飞轮货架） | `flywheel/gallery.html` | ① 导航 tab "探索 · Gallery" ② "探索 Gallery" hookline |

### L2 — 从 L1 页面进入的页面

| 页面 | 文件 | 从哪个 L1 页面进入 |
|------|------|-------------------|
| **Recruit**（手搓挑战 / 抽卡） | `recruit/index.html` | 从 `flywheel/gallery.html` → 产品卡片 "试用 · Try" |
| **Flywheel Product Detail**（产品详情） | `flywheel/product-detail.html` | 从 `flywheel/gallery.html` → 点击产品卡片 |
| **Flywheel World Step** | `flywheel/world-step.html` | 从 `flywheel/gallery.html` → 相关入口 |
| **Flywheel Publish Landing** | `flywheel/publish-landing.html` | 从 `flywheel/gallery.html` → 发布入口 |

### L3 — 从 L2 页面进入的页面

| 页面 | 文件 | 从哪个 L2 页面进入 |
|------|------|-------------------|
| **World Workspace**（工作台） | `world/workspace.html` | 从 `recruit/index.html` → "Go" 按钮（抽完卡后进入） |

### 独立子站点（根目录，不通过 mainsite 导航进入）

| 子站点 | 入口文件 | 说明 |
|--------|---------|------|
| **Dogfooding Metrics** | `dogfooding-metrics/index.html` | 独立指标面板，历史项目 |

---

## 完整流转图

```
mainsite.html ─────────────────────────────────────────────────────────────
  │
  ├── login.html                          [L1] 登录
  ├── driver-license.html                 [L1] 驾照 / 成就
  ├── world-demo.html                     [L1] 试玩 world
  ├── hello-demo.html                     [L1] 试玩 hello
  ├── achievement-center.html             [L1] 成就中心
  │     └── → driver-license.html         (成就卡片)
  │     └── → world-demo.html             (成就卡片)
  │     └── → mainsite.html#worldcup      (成就卡片)
  │
  ├── recruit/index.html                  [L1] 专家招募 · Expert Recruit
  ├── dealscout/index.html                [L1] 投融资撮合 · DealScout
  ├── recruit-publish-flow/publish-entry.html  [L1] Builder 发布入口
  │
  └── flywheel/gallery.html               [L1] Gallery 货架入口
        │
        ├── flywheel/product-detail.html  [L2] 产品详情
        │     └── → recruit/index.html     (试用 · Try)
        │
        ├── flywheel/world-step.html      [L2] 飞轮步骤
        │     └── → recruit/index.html     (tryUrl)
        │
        ├── flywheel/publish-landing.html [L2] 发布页
        │
        └── recruit/index.html            [L2] 手搓挑战（抽卡）
              │
              ├── world/workspace.html     [L3] 工作台（抽卡后进入）
              │     └── → recruit/index.html  (再抽一张)
              │     └── → mainsite.html#intro (返回官网)
              │
              └── recruit-publish-flow/publish-entry.html  [L3] Builder 发布入口
                    │     ① 输入领域 → ② 选 agent → ③ 填写发布说明 → ④ 提交审核
                    │     ⬇ 审核中（占位）
                    └── → flywheel/gallery.html  (审核通过后上架)
```

### 返回路径

所有 L1 页面通过 `site-nav.js`（共享导航栏）返回 `mainsite.html`。
L2/L3 页面通过 `site-nav.js`（设置 `EZD_SITE_ROOT = "../"`）或显式 "← 返回" 链接返回上级页面。

---

## 共享依赖

| 资源 | 路径 | 加载方式 |
|------|------|---------|
| 设计系统 tokens | `assets/css/tokens.css` | `<link>` 直接引用 |
| 共享导航栏 | `assets/js/site-nav.js` | `<script>` 注入 nav（支持 ROOT 变量适配深度） |
| 成就状态管理 | `assets/js/demo-state.js` | `<script>` 提供 `EZD` 全局对象 |
| Mock API | `assets/js/mock-ezagent-api.js` | `<script>` 模拟后端数据 |
| world.cup 组件 | `assets/js/worldcup.js` | `<script>` 渲染投票路线图 |
| 品牌 Logo | `assets/images/ezagent-logo*.png` | 本地引用（flywheel 用 CDN） |

---

## 归档（无活跃入口链接）

`archive/` 中的文件无任何活跃页面链接进入，保留供历史参考：

- `team-office.html` — 内容已移植进 mainsite
- `puncture-judge.html` — 方案①判断题原型（recruit v2 替代方案，未接入）
- `puncture-scale.html` — 方案③′团队度量原型（同上）
- `recruit-v1.html` / `recruit-v3.html` — 旧版 recruit
- `index-old.html` — 旧版 mainsite（无 Gallery 入口）
- `ezagent-flywheel-demo.zip` — 旧版 flywheel 压缩包
- `2026-06-30-website-*.md` — 历史路线图 / 审计文档

---

## 设计参考（离线，不从 mainsite 链接）

这些页面是纯设计参考文档，不在 mainsite 导航流中，为真实 world/hello LiveView 面开发提供 IA/视觉方向。

| 参考页 | 文件 | 用途 | 关联 PR |
|--------|------|------|---------|
| **设计说明** | `flywheel/design-brief.md` | IA 映射表 + 视觉方向 + hello↔kanban 连接点 + 不做事项 | #1378 |
