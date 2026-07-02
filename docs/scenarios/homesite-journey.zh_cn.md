# 官网用户旅程 —— 总览地图（scenario 36–39）

**状态**：草拟 — 2026-07-02。作者：Claude（与 ruihua），据 2026-07-02 产品会
+ ruihua 的产品关系模型。

> 双语逐行镜像：[`homesite-journey.md`](./homesite-journey.md)。

## 这是什么

官网 E2E 群组的连接地图。一个匿名访客走一条连续旅程：从落地 ezagent 官网，到发布自己
fork 出的 session —— 每一段都被写成一条 1:1 scenario（36–39）。本文是**总览**，scenario 是
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

## 旅程（6 段）

| 段 | 用户动作 | 底层产品关系 | 状态变化 | scenario |
|---|---|---|---|---|
| **0 页面 == session** | 打开官网页面 | 页面 = 绑定一个 world session 的 hello 产物;匿名看到该 session 的外部脸 | 匿名 viewer | 前提，cross-ref 35 |
| **1 匿名浏览** | GitHub / 看看进度 | 纯展示,不写 session | 无 | 36 |
| **2 写操作门控 → 登录** | 在底部对话框写 | 匿名不能写 session → 门控 | 匿名 → 登录 → 已登录 | 36 |
| **3 对话 == 在 world 说话** | 在页面说话 | 消息进入 world session;agent/其他成员的回复**同步回**页面 | 成为 session 成员 | **37** |
| **4 分享 → 同一 session** | 分享链接、邀请他人 | 被邀者加入**同一个** session（群聊,留历史） | 被邀者 = end user / 成员 | **38** |
| **5 重新部署 → fork 新 session** | 重新部署（publish）session + 页面 | 存为 session template → fork 一个**新** session → fork 者成 owner,在 world 看对话 | fork 者 = 新 owner / 租户 | **39** |

## 胜负手：两条传播路径（第 4、5 段）

这里才是旅程真正展示产品关系的地方 —— 同一个页面，分享 vs 重新部署，意味着两种完全不同的
产品语义：

```
┌─ 第4段  分享 / deploy ────────┐   ┌─ 第5段  重新部署 / publish(fork) ─┐
│ 同一个 session                │   │ 新的 session                       │
│ 多人,一条对话                 │   │ fork 者另起炉灶                     │
│ 保留对话历史                  │   │ 不带原历史(publish)                │
│ 被邀者 = end user(成员)       │   │ fork 者 = 租户 / owner             │
│ 「你和我在同一个群」          │   │ 「他复制了我的模板」               │
└───────────────────────────────┘   └────────────────────────────────────┘
        end-user 视角                        租户 / owner 视角
        = deploy(保留历史)                   = publish → session template(fork)
```

deploy 与 publish 写成 **scenario 38 与 39** —— 各自是对方的失败模式（38 断言"fork 而非
加入 = bug";39 断言"加入而非 fork = bug"），以此逼后端的 session 语义必须精确。

## Scenario 映射

- **36** —— 段 0–2：匿名浏览 + 登录门控。
- **37** —— 段 3：官网对话 ↔ world session（双向同步）。主线;38、39 的前置。
- **38** —— 段 4：分享 / deploy → 同一 session（群聊,end-user 成员）。
- **39** —— 段 5：重新部署 / publish → fork 新 session（新 owner / 租户）。

## 录制备注

第 2 段之后的一切都依赖**尚未连通**的后端对接（2026-07-02 会）。在建成前，未实现的面
（world→页面回复传播、分享/publish 控件、插件市场列表）用**未实现的空白 HTML 占位**录制
—— scenario 断言预期行为,占位页替代缺失部件。录制脚本仿
`scripts/demo/agent-create-record.js`（Playwright `recordVideo`），由每条 scenario 指定的
角色/文案 selector 驱动。

## 本旅程编码的产品决策（2026-07-02 会）

- 每个打开的 hello 页面 == 一个 session。
- world = IM 后端（owner 看/配回复）;hello = 展示面。
- `deploy`/`share` = 同一 session、保留历史、end-user 成员。
- `publish` = 存为 session template + fork、新 owner、不带历史。
- 插件市场 = session-template 列表。
- 租户（owner）vs end-user（成员）是两条传播路径之间的承重区分。
