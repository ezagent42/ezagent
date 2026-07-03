# 场景 39：Try world → 基于官网 session 重建为新的自有 session

**分类**：3 — 会话流程
**状态**：🚧 设计规范 — Try-world 进入 world + 重建新 session 的流程尚未构建，且
`session template` 概念正在改造（吸收 APP 概念，2026-07-02 进行中）；用**未实现的空白
HTML 占位**录制。未 ✅（无测试 + 未签收）。
**作者**：Claude（与 ruihua），2026-07-02 — 官网用户旅程第 5 段。

> 双语逐行镜像：[`scenario.md`](./scenario.md)。

## 意图

**第二条**传播路径 —— **opt-in 去搭建 / 租户**路径。一个喜欢上官网的访客点 **Try world**
**进入 world**（这是整条旅程唯一离开官网的地方，出于用户自己想搭建的主动选择）。在那里，
**基于官网 session 重新创建一个新 session** —— 他成为它的 **owner**（一个租户），不带原历史。

与场景 [38](../38-share-deploy-same-session/scenario.zh_cn.md)（deploy）对照：那里被邀者
**留在官网**、以成员身份加入**同一个** session。**deploy = 同一 session、留在官网、成员；
段 5 = 新 session、进入 world、owner。** 把这一对展示出来是整条旅程的收束：官网是你*消费*的
地方，world 是你去*拥有*的地方。

这是旅程**第 5 段**。它的入口是场景 [36](../36-homesite-browse/scenario.zh_cn.md) 的
**Try world** CTA；它的源头是场景 [37](../37-homesite-dialog-world-sync/scenario.zh_cn.md)
的活 session。

## 前置条件

标准前置（README §1.1），另加：

- **一个活的官网 session** —— 场景 37 完成：一个已登录用户，其官网页面绑定的 world session
  已承载一些对话。
- **Try world 可用** —— `试玩 · Try world →` CTA（场景 36 步骤 6）为已登录用户在新标签打开
  world（`app.ezagent.chat`）。
- **opt-in 去搭建** —— 这一段明确是访客选择深入。段 0–4 从不离开官网；段 5 离开，出于
  用户自己的动作。

## 角色

- **访客 → 租户（U）**：已登录；官网上的一个 end-user，现在选择进入 world 并**成为**一个新
  session 的 **owner**（一个租户）。
- **源官网 session**：`session://<workspace>/hello/<slug>` —— U 在官网上说话的 session；
  重建的依据。
- **world 里的新 session**：`session://<workspace>/hello/<new-slug>` —— U 自己的，与源不同。

## 步骤

### 进入 world（Try world）

1. **点 Try world** —— 在官网，U 点 `试玩 · Try world →`
   *（`.product-world .product-foot`，场景 36 步骤 6）*。
   → 新标签打开 world（`app.ezagent.chat/`），U 已登录。

### 重建一个自有的新 session

2. **一键复制配置 → 新 session** —— 在 world 里查看官网 session 时，U 点**复制当前 session
   配置、创建新 session**（world 功能：一键复制当前 session 配置、创建新 session）。
   → 从复制的配置创建出一个新 session，**归 U 所有**；其 `session_uri` ≠ 源的。
3. **全新对话** —— U 在新 session 里说话；对话是 U 自己的、**全新的** —— 不带源官网 session
   的任何历史。
4. **Owner 在 world 里操作** —— U 现在在 world 里，在那里看/配置这个新 session（world 是
   owner/租户操作 IM/回复的地方 —— 这是刻意的"进 world 去搭建"面，不是面向客户的官网）。

## 实测结果 vs 预期

行为层（所有权/成员资格基元在场景 35 断言；模板机制 cross-ref 场景 21）：

- 步骤 2：重建出的 `session_uri` 是**新的**（≠ 源官网 session）；U 对其持有 **owner / 租户** caps。
- 步骤 2：新 session **基于官网 session**（其配置/形态派生自源 —— U 喜欢的那个东西的延续）。
- 步骤 3：无源历史渗进新 session（一次干净的重建）。
- 步骤 4：U 在 world 里观察/配置新 session（owner 面），区别于官网的客户面。

## 失败模式（需测试）

- **加入而非重建** —— U 以成员身份落进**同一个** session，而非一个新的自有 session。那是
  场景 38（deploy）的行为；对段 5 而言是 bug。
- **历史泄漏进新 session** —— 源官网对话渗进 U 重建的 session（重建必须干净）。
- **用户不是 owner** —— U 只拿到成员 caps，不能重配新 session（破坏租户关系）。
- **重建丢了源形态** —— 新 session 是个空白默认态，而非基于 U 喜欢的官网 session
  （丢了延续性 / 他来的理由）。
- **匿名时 Try world 泄漏** —— 匿名访客未过登录门就进了 world（必须按场景 36 步骤 6 保持门控）。

## 交叉引用

- 场景 [36](../36-homesite-browse/scenario.zh_cn.md) —— 本段入口的 **Try world** CTA
  （步骤 6：已登录 → 新标签打开 `app.ezagent.chat`）。
- 场景 [38](../38-share-deploy-same-session/scenario.zh_cn.md) —— **另一条**路径
  （deploy / 同一 session / 成员，留在官网）；38 与 39 是这一对。
- 场景 [37](../37-homesite-dialog-world-sync/scenario.zh_cn.md) —— 被重建的源官网 session。
- 场景 [21](../21-template-version-tag/scenario.md) —— 模板实例化机制（重建底层可能从一个
  session template spawn）。
- 场景 [35](../35-external-user-anon-access/scenario.zh_cn.md) —— 所有权/成员资格基元。
- 产品决策（2026-07-02 会）：段 5 拥有 = Try world → 进入 world → 基于官网 session 重建；
  新 owner、无历史；租户（进 world 去搭建）vs end-user（留在官网）。

## 备注

- **用户视角 vs 后端** —— 用户的动作是"Try world → 基于这个重建一个新 session、并拥有它"。
  **后端机制**可能是 存为 session template + spawn（会上的 `publish`→模板→fork），但那是重建
  背后的实现细节；`session template` 概念今天正被改造（林懿伦，吸收 APP），故本 scenario
  描述的是**产品行为**，对命名鲁棒。
- **这是唯一离开官网的一段** —— 与"我们对客户只呈现官网"一致：段 0–4 留在官网；段 5 是
  用户*选择*进入 world 去搭建/拥有。
- **录制占位** —— Try-world 入口、重建流程、world owner 面均未构建；在真实控件上线前用
  **未实现的空白 HTML 占位**录制。
- **版本** —— 重建 N 次可能创建 N 个模板/session（保留版本、不覆盖；2026-07-02 line 565
  选的更简方案）。超出本 scenario happy path 范围，留待后续失败矩阵记录。
- **状态 🚧。** 在确定性/实景测试 + runbook + agent-browser 录屏存在且 ruihua/Allen
  签收前，**不要**标 ✅。
