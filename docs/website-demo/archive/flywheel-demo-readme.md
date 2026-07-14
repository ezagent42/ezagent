# Ezagent 飞轮 Demo · 使用指南

> **一句话**：打开 `index-gallery.html`，你就能走完 Ezagent 官网飞轮的完整闭环 —— 从 gallery 货架浏览产品 → 试用 → Fork 成自己的 → 发布上架 → 回流货架。

---

## 1. 怎么跑

全部是**纯静态 HTML**，不需要服务器、不需要 `npm install`。

```
解压 zip → 双击 index-gallery.html（或用浏览器打开它）
```

推荐 Chrome / Edge / Safari，Firefox 也可以。

---

## 2. 这个 Demo 演示了什么

Ezagent 官网的核心是一个**双边飞轮**：

```
  🟦 Builder Arc（供给）                🟨 Seller Arc（需求）
  ────────────────────                  ────────────────────
  tech site → 了解产品                    Instagram → 落在 gallery 某产品
     ↓                                      ↓
  试玩 world + hello                      试用这个产品（对话拿价值）
     ↓                                      ↓
  建 builder 身份                         Fork → 改成自己的 → 认领 owner
     ↓                                      ↓
  用 world+hello 搓出 socialware          自己的产品跑起来 / 对客开放
     ↓                                      ↓
  发布进 gallery ────────┐                Fork 产物回流 gallery ──────┐
                         │                                            │
                         └────────── GALLERY 交换点 ←─────────────────┘
                              （活的 public_view 货架，可试用、可 Fork）
```

Demo 用一个**可点击走完的闭环**把这个概念演出来。

---

## 3. 走一遍：Builder 路径（造产品 → 发布）

| 步骤 | 页面 | 操作 |
|------|------|------|
| **B0-B1** 抵达·认同 | `index-gallery.html` | 打开即看到 Ezagent 介绍、world/hello 产品卡、研发进度、团队 |
| **B2** 体验 | 点 `world-demo.html` / `hello-demo.html` | 试玩两个产品（hello 是 iframe 嵌入 live service，需联网） |
| **B3** 建身份 | 右下角浮动卡 → `driver-license.html` | 测一下"你能同时指挥几个 agent"，拿张指挥官驾照 |
| **B4** 构建 | `index-gallery.html` → 点 `探索 · Gallery` → 点 `发布你的产品` | 进入 world 占位页：用 hello 生成 → 提交发布 |
| **B5** 发布 ★ | `world-step.html` → 点 `提交发布 →` | 跳转到"已上架"页，产品出现在 gallery 货架上 |

> Builder 路径入口：`index-gallery.html` 顶部 nav 点 `探索 · Gallery`，然后在 gallery 页左上角点 `发布你的产品 · Publish yours`。

---

## 4. 走一遍：Seller 路径（发现产品 → Fork → 回流）

| 步骤 | 页面 | 操作 |
|------|------|------|
| **S0** 抵达 ★ | `gallery.html` | 货架上看到 4 个初始产品 + 你刚发布的 |
| **S1** 试用 | `gallery.html` → 任选一个产品点 `查看 · View` → `product-detail.html` | 产品详情页 → 点 `试用 · Try →` 打开 recruit-v2 对话面 |
| **S2/S3** Fork ★ | `product-detail.html` → 点 `Fork 复制成我的 · Fork this` | 进入 world 占位页（fork 模式）→ 改造 → 提交发布 |
| **S4** 兑现 | （概念层） | Fork 后的产品在 world-step 页展示"即将对客开放" |
| **S5** 回流 ★ | `world-step.html` → `publish-landing.html` | 发布成功页 → `返回探索` → 你的 fork 产品已出现在货架上 |

> Seller 路径入口：直接从 `flywheel/gallery.html` 开始，或从 `index-gallery.html` → nav 点 `探索 · Gallery`。

---

## 5. 核心闭环（5 次点击走完）

```
gallery.html ──查看·View──▶ product-detail.html ──Fork──▶ world-step.html ──提交发布──▶ publish-landing.html ──返回探索──▶ gallery.html
                                                                                                           （新产品已上架 ✅）
```

---

## 6. 文件结构

```
ezagent-flywheel-demo/
├── README.md                    ← 你在读的这份
├── index-gallery.html           ← 🚪 入口：官网 + 飞轮概述 + Gallery 入口
│
├── world-demo.html              ← B2：试玩 world
├── hello-demo.html              ← B2：试玩 hello（iframe 需联网）
├── driver-license.html          ← B3：测段位 · 拿驾照
├── recruit-v2.html              ← S1："试用"落点（对话面 demo）
│
├── demo-state.js                ← 驾照 ↔ 成就 共享状态（localStorage）
├── site-nav.js                  ← 官网顶部导航栏
├── tokens.css                   ← 官网设计系统 CSS
│
└── flywheel/
    ├── gallery.html             ← ① 货架：搜索 / 筛选 / 浏览产品
    ├── product-detail.html      ← ② 产品详情：查看 + 试用 + Fork
    ├── world-step.html          ← ③ world 占位：构建 / Fork → 提交发布
    ├── publish-landing.html     ← ④ 已上架：确认页 → 返回货架
    ├── gallery-data.js          ← 假后端（localStorage 模拟货架数据）
    ├── flywheel-ribbon.js       ← flywheel 页面顶部导航栏
    └── ds/
        ├── styles.css           ← 设计系统入口（级联加载 tokens/）
        ├── tokens/              ← 7 个 CSS token 文件
        ├── ezagent-logo.png     ← Ezagent logo（亮色主题）
        └── ezagent-logo-dark.png← Ezagent logo（暗色主题）
```

### 依赖关系速查

```
gallery.html ───────────▶ gallery-data.js, flywheel-ribbon.js, ds/styles.css
product-detail.html ────▶ gallery-data.js, flywheel-ribbon.js, ds/styles.css
world-step.html ────────▶ gallery-data.js（无 ribbon，用内联样式）
publish-landing.html ───▶ gallery-data.js, flywheel-ribbon.js, ds/styles.css
driver-license.html ────▶ demo-state.js, site-nav.js
world-demo.html ────────▶ demo-state.js, site-nav.js, tokens.css
hello-demo.html ────────▶ demo-state.js, site-nav.js, tokens.css
```

---

## 7. 已知限制

| 限制 | 说明 | 影响 |
|------|------|------|
| **hello-demo 内嵌 iframe** | `hello-demo.html` 用 `<iframe src="/socialware/chat?...">` 嵌入 live service | 本地打开 iframe 会是空白。不影响理解页面结构 |
| **CDN 依赖** | `driver-license.html` 引用 `html2canvas` + `qrcodejs` 两个 CDN 库 | 需联网才能生成驾照卡片图片 |
| **假后端** | 所有数据来自 `gallery-data.js` + `localStorage` | 刷新页面后发布的产品还在（localStorage）；换浏览器/清缓存会丢失 |
| **返回官网链接** | flywheel 页面的"返回官网"链接指向 `../index.html` | 因为 zip 里只有 `index-gallery.html`，这些链接会 404。实际部署时指向真实官网 |
| **暗色主题** | gallery 系列页面支持亮/暗切换（`data-theme` 属性） | 切换按钮在 `flywheel-ribbon.js` 里，world-step.html 无 ribbon 不支持 |

---

## 8. FAQ

**Q: 为什么 world-step.html 长得和其他页面不一样？**
A: 故意的。world-step 是"world 侧待建占位页"，朴素风格表明这是后端待实现的功能占位，不是最终 UI。

**Q: 如何重置 demo 数据？**
A: 打开浏览器 DevTools → Console → 输入 `FW.reset()` 回车 → 刷新页面。这会清空你发布过的产品。

**Q: 能把 gallery-data.js 换成真实 API 吗？**
A: `FW.products()` / `FW.get()` / `FW.publish()` 三个函数就是 API 面。把它们改成 `fetch()` 调用即可对接真实后端，页面代码不用改。

---

> 设计文档：`docs/rh/homesite/README.md`（飞轮框架 + P/J/V/F 树）· 场景底座：`docs/scenarios/36-39`（seller arc session 机制）
