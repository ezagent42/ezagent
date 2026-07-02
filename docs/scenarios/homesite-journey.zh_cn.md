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

> **官网是客户的主界面** —— 浏览和对话都在这里。`world` 是后端 session 基质 + 完整的
> session/IM 视图。两个明确的按钮把官网桥接进 world：**查看当前session**（看完整 session）
> 和 **Try world**（拥有一个新 session）。客户在官网说话；红点提示有新动静；只有点这两个
> 按钮才进入 world。

## 官网 composer bar —— 在这里说话，跳去看 session

官网底部那条 composer bar（参考 `~/Desktop/Socialware.html` 里的 `.previewbar`）是用户往
绑定的 world session 说话的地方。

```
┌─ 官网 composer bar (.previewbar) ─────────────────────────────────────┐
│  [ 在这里输入…（登录后参与） ]   [ 登录 / 发送 ]   [查看当前session ⑤]  │
│   .previewbar-input             .previewbar-action    （红点计数）      │
└────────────────────────────────────────────────────────────────────────┘
```

- **说话**：在 `.previewbar-input` 输入，点 `.previewbar-action` —— 未登录显示 `登录`
  （写操作门控，段 2）；登录后变为**发送**。
- **新动静红点**：官网 session 每多一条消息（用户**或** agent），**查看当前session** 上加一个
  红点计数；用户打开 session 后清零。这就是用户不离开官网、也能知道"话进了、有回复"的方式。
- **看完整 session**：点 **查看当前session** → 进入 world 的官网 session（完整对话在 world，
  官网只显示红点）。
- **已移除**：composer 原来的 `选择` 按钮和内联 `查看会话` 面板都去掉了 —— 由单个
  `查看当前session` 按钮 + 红点取代。

## 旅程（6 段）

| 段 | 用户动作 | 底层产品关系 | 状态变化 | scenario |
| --- | --- | --- | --- | --- |
| **0 页面 == session** | 打开官网页面 | 页面 = 绑定一个 world session 的 hello 产物;匿名看到该 session 的外部脸 | 匿名 viewer | 前提，cross-ref 35 |
| **1 匿名浏览** | GitHub / 看看进度 | 纯展示,不写 session | 无 | 36 |
| **2 写操作门控 → 登录** | 在底部对话框写 | 匿名不能写 session → 门控 | 匿名 → 登录 → 已登录 | 36 |
| **3 对话 == 在 world 说话** | 在 composer 输入+发送;每来一条新消息 **查看当前session** 红点 +1;点它进入 world | 消息落入官网 session;新消息（用户**或** agent）让红点 +1;点击进 world 阅读 | 成为 session 成员 | **37** |
| **4 分享 → 同一 session** | 分享（从官网**或**从 world） | 被邀者加入**同一个** session（群聊,留历史）;每条新消息让各方红点 +1 | 被邀者 = end user / 成员 | **38** |
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
