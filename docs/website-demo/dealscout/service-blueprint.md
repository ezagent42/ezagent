# DealScout 服务蓝图 · Service Blueprint

> 每条行为均有依据——引用自 PR #1191 handoff + E2E v2 文档。
> 画法参照 [Service Blueprint Framework](https://pmframe.works/framework-service-blueprint)。

---

## 蓝图总览

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  EVIDENCE                                                                   │
│  公开面 URL  ·  Gallery 货架卡片  ·  浏览器通知  ·  收件箱 badge              │
├─────────────────────────────────────────────────────────────────────────────┤
│  CUSTOMER ACTIONS (用户行为)                                                 │
│                                                                             │
│  抵达 DealScout                                                             │
│    │                                                                        │
│    ├── 输入需求描述 ────→ AI 分析意图 ────→ 浏览匹配结果 ────→ 选中查看详情   │
│    │                                                   │                    │
│    │                                                   ├── 满意 → 牵线      │
│    │                                                   └── 不满意 → 保存搜索 │
│    │                                                                        │
│    └── 查看收件箱 ────→ 收到牵线请求 ────→ 查看对方名片 ────→ 接受 / 拒绝   │
│                              │                                               │
│                         接受 → 进入 world 工作台                             │
├─────────────────────────────────────────────────────────────────────────────┤
│  LINE OF INTERACTION                                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│  ONSTAGE (可见系统行为 · 发现腿)                                              │
│                                                                             │
│  AI 语义匹配引擎                       hello @json-render                     │
│    │                                     │                                   │
│    ├── 分析用户输入意图                   └── 渲染匹配结果页面                  │
│    ├── 检索线索池                        ┌── 渲染详情卡片                     │
│    └── 计算匹配度（语义相似度）            └── 渲染公开面（匿名浏览）             │
│                                                                             │
│  匹配度 = f(用户需求描述, 线索profile)                                        │
│  依据：model.md — "AI 副驾按用户 profile 千人千面主动发现"                    │
│         README.md §1 — "AI 千人千面主动发现 deal"                             │
├─────────────────────────────────────────────────────────────────────────────┤
│  LINE OF VISIBILITY                                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│  BACKSTAGE (不可见系统行为）                                                  │
│                                                                             │
│  ┌─ 发现腿 (Discovery) ─────────────────────┐                               │
│  │ Crawler Plugin                           │                               │
│  │   ├── 定时轮询外部源（HN/RSS/搜索 API）    │ 依据：README.md §1 F1          │
│  │   ├── 线索落库（messages）                │ 依据：refresh-v2 步2           │
│  │   └── crawl 完成 → dispatch refresh_page │ 依据：refresh-v2 步3c          │
│  │                                          │                               │
│  │ DefinitionRegistry                       │                               │
│  │   └── 线索/产品数据存储与检索              │ 依据：model.md §1.2            │
│  └──────────────────────────────────────────┘                               │
│                                                                             │
│  ┌─ 撮合腿 (Matchmaking) ───────────────────┐                               │
│  │ hello concierge                          │                               │
│  │   ├── 非 owner member → routing → concierge │ 依据：router.ex:13-14       │
│  │   └── concierge 回帖                      │ 依据：hello_concierge.ex:43    │
│  │                                          │                               │
│  │ session_feed_channel                     │                               │
│  │   ├── 登录用户自助 join + post            │ 依据：session_feed_channel:197 │
│  │   └── 匿名只读硬禁                        │ 依据：session_feed_channel:325 │
│  │                                          │                               │
│  │ invite_member (owner 主动拉人)            │ 依据：conversation_actions:683  │
│  └──────────────────────────────────────────┘                               │
├─────────────────────────────────────────────────────────────────────────────┤
│  LINE OF INTERNAL INTERACTION                                               │
├─────────────────────────────────────────────────────────────────────────────┤
│  SUPPORT PROCESSES                                                          │
│                                                                             │
│  TurnDriver (页面生成)                                                       │
│    └── turn.open → compose → settle → Surface approved                      │
│    依据：refresh-v2 步3c                                                     │
│                                                                             │
│  ExternalFeedController                                                     │
│    ├── /socialware/external → 公开面渲染                                     │
│    └── 读授权：live membership 判定                                          │
│    依据：external_feed.ex:10-21                                              │
│                                                                             │
│  通知系统（待建）                                                             │
│    └── 新线索入库 → 匹配保存的搜索 → badge / 浏览器通知 / 飞书                │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 两条腿的职责边界

| 职责 | 发现腿（Discovery） | 撮合腿（Matchmaking） |
|------|-------------------|---------------------|
| **做什么** | 找到"谁和谁可能匹配" | 让"已经匹配的双方"连接起来 |
| **匹配度计算** | ✅ **这里算**——AI 语义匹配引擎对比用户输入与线索 profile | ❌ 不参与匹配度计算 |
| **数据来源** | Crawler 爬取外部源 + DefinitionRegistry | — |
| **页面渲染** | hello @json-render 渲染结果列表 + 详情卡片 | hello 公开面 + concierge |
| **交互模式** | 用户输入 → AI 匹配 → 浏览结果 | 登录 → 发言 → concierge 回帖 → founder invite |
| **触发方式** | 用户手动搜索 / crawl 完成自动 dispatch refresh_page | 用户点击 "牵线" |
| **E2E 验证** | ✅ v2：crawl → dispatch → handler → TurnDriver → 浏览器渲染 | ✅ F7：登录自助 join + concierge 回帖 |

### 匹配度的计算方式

```
匹配度 = AI 语义相似度(用户需求描述, 线索 profile)

输入：
  用户侧：需求文本 + 名片信息（行业标签 / 资源 / 需求）
  线索侧：crawler 爬取的 name / brief / tags / have / need

计算：AI 模型对两端文本做语义 embedding，计算余弦相似度，
     叠加规则加权（类型匹配 +15%，标签命中 +3% per tag）

输出：0-100% 的匹配度分数

依据：
  - model.md："AI 副驾按用户 profile 千人千面主动发现、主动推匹配机会"
  - README.md §1："AI 千人千面主动发现 deal"
  - E2E refresh-v2：crawl 注入后 dispatch refresh_page → handler 真跑 → 页面内容更新
```

---

## HTML 原型 v.s. 真实实现

| 原型中的 UI 行为 | 对应真实系统中的腿 | 当前状态 |
|-----------------|------------------|---------|
| 用户输入需求 → 点击匹配 | 发现腿：AI 语义匹配引擎 | 🔴 原型 mock，真 AI 待接 |
| 匹配列表 + 百分比 | 发现腿：匹配度计算 | 🔴 原型 mock 数据 |
| 选中 → 右侧详情卡片 | 发现腿：hello @json-render 渲染 | 🔴 原型静态页面 |
| "牵线" → 请求已发送 | 撮合腿：触发 invite/connect 流 | 🔴 原型 mock，后端 dispatch 待建 |
| 收件箱 → 接受/拒绝 | 撮合腿：session_feed_channel → invite_member | 🔴 原型 mock |
| 保存搜索 → 通知 | 发现腿 + 通知系统 | 🔴 原型 mock |
| 匿名浏览公开面 | hello ExternalFeed（已实现） | 🟢 后端已通（refresh-v2 验证） |
| 登录用户发言 + concierge | hello concierge（已实现） | 🟢 后端已通（router + concierge） |

---

## 关键文件引用

| 文件 | 内容 | 位置 |
|------|------|------|
| model.md | Session 3 角色 + 权限两层 + 撮合机制 | #1191 `handoffs/dealscout/model.md` |
| README.md | 产品骨架 + 最小组件清单 + 分步 Plan | #1191 `handoffs/dealscout/README.md` |
| refresh-v2/README.md | E2E 验证：crawl → dispatch → 页面重建 | #1191 `e2e/dealscout-refresh-v2/` |
| system-mechanism-feedback.md | 系统机制缺口总览 | `docs/together/2026-07-06/handoffs/` |
| router.ex:13-14 | 非 owner 路由 concierge | ezagent_plugin_hello |
| hello_concierge.ex:43 | concierge 回帖 | ezagent_plugin_hello |
| session_feed_channel.ex:197-228 | 登录用户自助 join/post | ezagent_web |
| conversation_actions.ex:683 | owner invite 深聊 | ezagent_plugin_world |
