# Ezagent 官网 Demo · 使用指南

> **一句话**：打开 `mainsite.html`，走完 Ezagent 官网飞轮的完整闭环。

---

## 1. 怎么跑

全部是**纯静态 HTML**，不需要服务器、不需要 `npm install`。双击 `mainsite.html` 用浏览器打开即可（推荐 Chrome / Edge / Safari；需联网加载字体和 DS tokens）。

---

## 2. 这个 Demo 演示了什么

Ezagent 官网的核心是一个**双边飞轮**：

```
  🟦 Builder Arc（供给）                🟨 Seller Arc（需求）
  ────────────────────                  ────────────────────
  抵达官网 → 了解产品                    抵达 gallery → 发现产品
     ↓                                      ↓
  试玩 world + hello                      试用这个产品（对话拿价值）
     ↓                                      ↓
  用自己的 expertise 构建 agent           Fork → 改成自己的 → 认领 owner
     ↓                                      ↓
  发布进 gallery ────────┐                自己的产品跑起来 / 对客开放
                         │                                      ↓
                         │                Fork 产物回流 gallery ──┘
                         └────────── GALLERY 交换点 ←─────────────
                              （活的 public_view 货架，可试用、可 Fork）
```

---

## 3. 走一遍：Builder 路径（造 agent → 发布上架）

| 步骤 | 页面 | 操作 |
|------|------|------|
| 抵达 | `mainsite.html` | 打开官网，了解 Ezagent |
| 体验 | `world-demo.html` / `hello-demo.html` | 试玩两个产品 |
| 手搓挑战 | `recruit/index.html` → "发布你的 agent →" | 意识到自己也是专家，进入 Builder 发布入口 |
| 选 agent | `recruit-publish-flow/publish-entry.html` Step 1 | 从 workspace 中选择要发布的 agent |
| 写说明 + 标签 | `recruit-publish-flow/publish-entry.html` Step 2 | 填 marketplace 说明 + 领域标签 |
| 提交审核 | 同上 → 提交 | 审核中 → 审核通过 |
| 上架 ★ | → `flywheel/gallery.html` | agent 出现在货架上 |

> Builder 入口：① `mainsite.html` Gallery 区 → "发布上架 · Publish yours →" ② `recruit/index.html` → "发布你的 agent →"

---

## 4. 走一遍：Seller 路径（发现产品 → Fork → 运营）

| 步骤 | 页面 | 操作 |
|------|------|------|
| 浏览 | `flywheel/gallery.html` | Gallery 货架：搜索/筛选/浏览产品 |
| 查看 | 点产品卡片 | 进入 `flywheel/product-detail.html` 看产品详情 |
| 试用 | product-detail 点 "试用 · Try →" | 进 `recruit/index.html` 手搓挑战 |
| Fork | product-detail 点 "Fork 复制成我的" | 进入 `flywheel/world-step.html` Fork 流程 |
| 运营 | Fork 后进入 workspace | `world/workspace.html` 工作台 |
| 发布 | world-step 提交发布 | `flywheel/publish-landing.html` 确认 → 回到 gallery |

> Seller 入口：`mainsite.html` → "探索 · Explore →" 或 Gallery tab

---

## 5. 文件结构

```
docs/website-demo/
├── mainsite.html              ← 官网首页（入口）
├── login.html                 ← 登录
├── driver-license.html        ← 指挥官驾照
├── world-demo.html            ← 试玩 world
├── hello-demo.html            ← 试玩 hello
├── achievement-center.html    ← 成就中心
├── recruit/                   ← 手搓挑战（抽卡）
│   └── index.html
├── recruit-publish-flow/      ← Builder 发布流（选 agent → 写说明 → 提交审核）
│   ├── publish-entry.html
│   └── design-brief.md
├── world/                     ← 工作台
│   └── workspace.html
├── flywheel/                  ← 飞轮（Gallery 货架 + 产品详情 + Fork + 发布）
│   ├── design-brief.md        ← 面向研发的 IA/视觉映射说明
│   ├── gallery.html
│   ├── product-detail.html
│   ├── world-step.html
│   ├── publish-landing.html
│   ├── gallery-data.js
│   └── flywheel-ribbon.js
├── dogfooding-metrics/        ← 独立指标面板
├── assets/                    ← 共享资源（JS/CSS/图片）
├── doc/                       ← 文档
│   └── page-flow.md           ← 页面流转关系 living doc
├── archive/                   ← 历史归档
└── README.md                  ← 本文件
```

## 6. 设计系统

品牌设计系统在独立仓库 `ezagent42/design-system`。Demo 通过 CDN 引用：
- `https://cdn.jsdelivr.net/gh/ezagent42/design-system@main/styles.css`

设计原则见 `flywheel/design-brief.md`（面向研发）和 `doc/page-flow.md`（页面流转）。
