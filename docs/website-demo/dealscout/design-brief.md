# Design Brief: DealScout 投融资撮合 demo

> **目标**：投融资撮合 socialware 的静态原型——用户描述需求，AI 匹配信号，双方牵线。
> **受众**：研发——理解撮合类 socialware 的产品形态
> **约束**：本文件夹是设计参照，不替代研发的技术方案
> **PR**：#1388

---

## 0. 实现路径（重要）

DealScout 是一个 **组合 socialware**（composite socialware）：
- **hello** 负责页面渲染——通过 @json-render spec 动态生成 UI（36 组件 catalog：Card / Grid / Heading / Text / Button / Badge / Input / …）
- **crawler plugin** 负责数据——爬取外部信号，dispatch `refresh_page` 触发 hello 重建页面
- 用户交互动作（牵线、接受/拒绝）→ 后端 dispatch action（参照 kanban 的 `dispatch 板动作` 模式）

**本文件夹的 HTML 原型是设计 spec**——告诉研发 hello 应该生成什么样的页面。原型组件均在 catalog 内，可直接映射为 @json-render spec。

参考：`docs/together/2026-07-06/handoffs/system-mechanism-feedback.md` — "dealscout v2 e2e 再证：crawl 完成 dispatch `refresh_page` → handler 真跑 → 页面重建"

---

## 1. 产品用户流程（DealScout 真实产品流）

> 本节来自 PR #1191 的 handoff 文档（`docs/together/2026-07-05/handoffs/dealscout/`）+ E2E 验证（`docs/e2e/2026-07-07/dealscout-refresh-v2/`）。本文件夹的 HTML 原型是这些流程的 UI 参照。

### 1.1 DealScout 是什么

一个 **组合 socialware**（composite socialware）：**crawler plugin**（爬取外部投融资/商业线索） + **hello**（@json-render 动态渲染页面 + concierge 客服）。用户是 **两类对称的"找机会的人"**——创始人（找钱、找路演）和投资人（找项目、找标的）。

### 1.2 两条价值腿

| 腿 | 作用 | 机制 |
|----|------|------|
| **发现腿**（地基） | AI 千人千面主动发现 deal + 手动搜索 | 爬取后台定期爬外部源（HN/RSS/搜索 API）→ 线索落库 → AI 按用户 profile 匹配推送 |
| **撮合腿**（亮点） | 公开面聊天连接双方 | DealScout 组合 hello 拿公开面 + concierge 客服。登录用户自助 join + 发言供线索，founder 看到发言者身份后 invite 进私有 session 深聊 |

### 1.3 完整用户流程

```
1. 作者开发 plugin
   写爬取代码 + recipe + Definition seed → 发布

2. Admin 装配组合
   安装 DealScout → 配置关键词/源/token → 组合 hello → 发布公开面

3. 公开共享 session（线上运行）
   ┌─────────────────────────────────────────────┐
   │ 匿名访客                                      │
   │   进入公开面 → 只读浏览线索页（hello 渲染）      │
   │                                              │
   │ 登录用户                                      │
   │   进入公开面 → 自助 join → 发消息供线索          │
   │   → concierge 客服回帖                        │
   │                                              │
   │ Founder（同一 session）                        │
   │   看到发言者身份（登录=真实 URI）                │
   │   → invite 进私有 session → 私密深聊           │
   │   → 撮合成功                                   │
   └─────────────────────────────────────────────┘

4. 自动刷新（E2E 已验证，v2）
   爬取完成 → dispatch refresh_page → handler 真跑
   → TurnDriver 生成 → Surface approved → 浏览器渲出重建页面
```

### 1.4 与 HTML 原型的对应

| 产品流 | 原型页面 | 说明 |
|--------|---------|------|
| 用户描述需求 / AI 匹配 | `index.html` 步骤 1-2 | 发现腿的 UI 参照 |
| 牵线 + 双向确认 | `connection/` | 撮合腿的 UI 参照 |
| 保存搜索 + 异步通知 | `notification/` | 第③腿（平台推荐）的占位 |
| 公开面浏览（匿名） | 原型未覆盖 | hello 渲染的公开线索页 |
| 公开面聊天 + invite | 原型未覆盖 | riding hello 的 concierge |

---

## 2. 页面与流转（HTML 原型）

| 页面 | 作用 | 状态 |
|------|------|------|
| **index.html** | 撮合入口：描述需求 → AI 匹配 → 查看结果 → 牵线 · 保存搜索 | 🆕 新建 |
| `profile/index.html` | 个人名片：身份 + 行业标签 + 资源/需求 | 🔴 **不在 dealscout 内**——名片是平台级功能（`achievement-center.html` 的角色档案），dealscout 只读取 |
| `connection/request-sent.html` | 牵线请求已发送 + 等待对方确认 | 🆕 新建 |
| `connection/inbox.html` | 牵线收件箱：查看请求 + 接受/拒绝 | 🆕 新建 |
| `notification/saved.html` | 保存的搜索 + 新匹配通知 | 🆕 新建 |
| `../flywheel/gallery.html` | Gallery 货架入口 | 🟡 已存在 |

### 流转

```
mainsite.html / flywheel/gallery.html
  → dealscout/index.html
    ├── achievement-center.html           [名片：平台级角色档案，dealscout 读取]
    │
    ├── ① 描述需求 → ② AI 匹配 → ③ 查看结果
    │     ├── 选中牵线 → connection/request-sent.html  [等待对方确认]
    │     │     └── → connection/inbox.html              [对方视角：接受/拒绝]
    │     │           ├── 接受 → workspace
    │     │           └── 拒绝 → 通知发送方
    │     │
    │     └── 保存搜索 → notification/saved.html        [异步通知]
    │           └── 新匹配 → 回 dealscout/index.html
    │
    └── connection/inbox.html             [牵线收件箱：查看他人请求]
```

## 3. index.html 设计

### 页面结构（聊天式交互）

1. **初始态**：对话框居中（hero state）——"投融资撮合树洞 · DealScout" + 输入框。无结果，无详情面板
2. **发送后**：对话框缩至顶部标题栏（高度减小），主屏幕展示左侧匹配结果 + 右侧详情面板
3. **匹配结果**：来自互联网的链接/摘要（标题 + 来源 + 描述 + 标签），AI 自动判断意图
4. **选中查看**：点击结果 → 右侧面板展示详情（来源 + 标题链接 + 摘要 + 匹配度 + 标签 + 牵线/原文按钮）
5. **保存搜索**：不满意 → 保存搜索条件 → notification/saved.html → 新匹配到达 → 点击"查看" → 回到主页 `?q=搜索词` 自动搜索

### 视觉方向

- 聊天式交互：hello 同款底部输入 → 结果上方展示
- 匹配结果：来源域名（mono 小写）+ 标题 + 摘要文字（非结构化卡片）
- 右侧详情面板：sticky 定位，实时更新
- "牵线"是主 CTA（jade 色），"查看原文"跳外部链接

## 4. 与已有页面的关系

| 已有页面 | 本次是否改动 | 说明 |
|---------|------------|------|
| `mainsite.html` | 是——加链接 | 加 DealScout 入口 |
| `flywheel/gallery-data.js` | 是——改 tryUrl | `dealscout-matching` 的 tryUrl 指向 `../dealscout/` |
| `flywheel/gallery.html` | 否 | |
| `doc/page-flow.md` | 是——更新 | 交付后更新 |

## 5. 不做的事

- ❌ 不实现真实匹配算法
- ❌ 不涉及 hello/kanban 自举链
