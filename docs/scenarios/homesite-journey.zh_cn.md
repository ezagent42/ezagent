# 官网用户旅程 —— 总览地图（scenario 36–39）

**状态**：草拟 — 2026-07-02。作者：Claude（与 ruihua），据 2026-07-02 产品会
- ruihua 的产品关系模型。

> 双语逐行镜像：[CODE0](./homesite-journey.md)。

## 这是什么

官网 E2E 群组的连接地图。一个匿名访客走一条连续旅程：从落地 ezagent 官网，到发布自己
进入 world、拥有自己重建的 session —— 每一段都被写成一条 1:1 scenario（36–39）。本文是**总览**，scenario 是
**细节**。它的存在是为了让读者在读任何单条 scenario 前先看到整个产品故事，也让录屏
（agent-browser / Playwright）有一条统一叙事可循。

## 三个产品（旅程的地基）

```
hello    = 生成 / 展示面     一句话 → 一个页面;官网页面就是一个 hello 产物
world    = IM / session 后端  对话真正所在;owner 在这里看它
官网页面  = 绑定到「一个」world session 的 hello 产物(那个 session 的一张前端脸)
```

> **一句话锚点**：*在官网页面说话不是在网页上留言 —— 而是在页面绑定的那个 world session
> 里说话。* 页面只是那个 session 的一张脸。

> **我们表达产品的界面只有这个官网。** 客户**不会**跳到单独的 Word / `/admin` / world
> 后台。`world` 是**后端 session 基质**（`session_uri`、owner 内部用的 IM）；客户对它的
> **唯一窗口是官网底部的 composer bar**（见下节）。下文所有用户视角的"看对话"步骤都发生在
> **官网上**，不在 world。（scenario 36 里的 `try world` CTA 是给愿意深入去搭建的访客的另一
> 条 opt-in 路径 —— 不属于这条"观察 session"的流程。）

## 官网 composer bar —— session 的唯一窗口

官网底部那条 composer bar（参考 `~/Desktop/Socialware.html` 里的 `.previewbar`）是页面与
world session 相遇之处。它有三个 affordance，合起来同时回答"点哪个按钮？"和"用户怎么知道
自己的话进了 session？"：

```
┌─ 官网 composer bar (.previewbar) ───────────────────────────────────┐
│  [▴ 查看会话]      [ 在这里输入…（登录后参与） ]      [ 登录 / 发送 ]  │
│  .previewbar-toggle   .previewbar-input               .previewbar-action │
└──────────────────────────────────────────────────────────────────────┘
        │ 点击展开 ↓
┌─ .previewbar-chat  （会话面板） ────────────────────────────────────┐
│  查看会话                                                 [× 关闭]   │
│  你   我想要一个……          ← 你刚发出的话 (.previewbar-msg)          │
│  AGENT  好的，正在生成……    ← session 的回复，实时                   │
│                                              .previewbar-tick（活动计数）│
└──────────────────────────────────────────────────────────────────────┘
```

- **点哪个按钮说话**：在 `.previewbar-input` 输入，然后点 `.previewbar-action` —— 未登录时
  显示 `登录`（写操作门控，段 2）；登录后变为**发送**。
- **用户怎么知道话进了 session**：点 **`.previewbar-toggle`（▴ 查看会话）**展开
  `.previewbar-chat` —— **自己刚发的话就在面板里**（`.previewbar-msg`），而 session 里的任何
  回复（agent 或另一成员）**实时出现在同一面板**（带 `.previewbar-tick` 活动计数）。
  `查看会话` 面板*就是* session；它是客户"在这里说话 == 在 world session 里说话"的证据，
  且全程不离开官网。

## 旅程（6 段）

| 段 | 用户动作 | 底层产品关系 | 状态变化 | scenario |
| --- | --- | --- | --- | --- |
| **0 页面 == session** | 打开官网页面 | 页面 = 绑定一个 world session 的 hello 产物;匿名看到该 session 的外部脸 | 匿名 viewer | 前提，cross-ref 35 |
| **1 匿名浏览** | GitHub / 看看进度 | 纯展示,不写 session | 无 | 36 |
| **2 写操作门控 → 登录** | 在底部对话框写 | 匿名不能写 session → 门控 | 匿名 → 登录 → 已登录 | 36 |
| **3 对话 == 在 world 说话** | 在 composer 输入+发送,点 `▴ 查看会话` | 发出的消息落入 world session 并显示在 `查看会话` 面板;agent/其他成员的回复**实时出现在同一面板** | 成为 session 成员 | **37** |
| **4 分享 → 同一 session** | 分享链接、邀请他人 | 被邀者加入**同一个** session;各自消息出现在彼此的 `查看会话` 面板（群聊,留历史） | 被邀者 = end user / 成员 | **38** |
| **5 进入 world → 重建为新的自有 session** | 点 **Try world**（opt-in 去搭建）→ 进入 world | 基于官网 session **重新创建一个新 session**;用户成为它的 **owner**（不带历史） | 用户 = 新 owner / 租户 | **39** |

## 胜负手：两条传播路径（第 4、5 段）

这里才是旅程真正展示产品关系的地方 —— 同一个页面，分享 vs 重新部署，意味着两种完全不同的产品语义：

```
┌─ 第4段  分享 / deploy ────────┐   ┌─ 第5段  Try world → 重建 ──────────┐
│ 同一个 session                │   │ 新的 session                       │
│ 留在官网                      │   │ 进入 world（opt-in 去搭建）        │
│ 多人,一条对话                 │   │ 基于官网 session 重建              │
│ 保留对话历史                  │   │ 不带原历史                         │
│ 被邀者 = end user(成员)       │   │ 用户 = 租户 / owner                │
│ 「你和我在同一个群」          │   │ 「我喜欢它 —— 现在拥有我自己的」   │
└───────────────────────────────┘   └────────────────────────────────────┘
        end-user 视角                        租户 / owner 视角
        留在官网                             经 Try world 进入 world
```

第 4、5 段写成 **scenario 38 与 39** —— 各自是对方的失败模式（38 断言"新建 session 而非加入 = bug";39 断言"加入同一 session 而非重建新的 = bug"），以此逼后端的 session 语义必须精确。

## Scenario 映射

- **36** —— 段 0–2：匿名浏览 + 登录门控。
- **37** —— 段 3：官网对话 ↔ world session（双向同步）。主线;38、39 的前置。
- **38** —— 段 4：分享 / deploy → 同一 session（群聊,end-user 成员）。
- **39** —— 段 5：Try world → 进入 world → 基于官网 session 重建为新的自有 session
  （新 owner / 租户）。

## 录制备注

第 2 段之后的一切都依赖**尚未连通**的后端对接（2026-07-02 会）。在建成前，未实现的面（world→页面回复传播、分享控件、Try-world 进入 world 的入口、重建新 session 的流程）用**未实现的空白 HTML 占位**录制—— scenario 断言预期行为,占位页替代缺失部件。录制脚本仿`scripts/demo/agent-create-record.js`（Playwright `recordVideo`），由每条 scenario 指定的角色/文案 selector 驱动。

## 本旅程编码的产品决策（2026-07-02 会）

- 每个打开的 hello 页面 == 一个 session。
- world = IM 后端（owner 看/配回复）;hello = 展示面。
- `deploy`/`share` = 同一 session、留在官网、保留历史、end-user 成员。
- 段 5 拥有 = **Try world → 进入 world → 基于官网 session 重建一个新 session**；新 owner
  （租户）、不带历史。（后端机制可能是 存为 session template + spawn；cross-ref scenario 21。）
- 租户（owner，进 world 去搭建）vs end-user（成员，留在官网）是两条路径之间的承重区分。
