# 场景 37：官网对话 ↔ world session（双向同步）

**分类**：3 — 会话流程
**状态**：🚧 设计规范 — 后端对话对接**尚未连通**（据 2026-07-02 产品会）；
world→页面的回复面在建成前用**未实现的空白 HTML 占位**录制。未 ✅（无测试 + 未签收）。
**作者**：Claude（与 ruihua），2026-07-02 — 官网用户旅程第 3 段。

> 双语逐行镜像：[`scenario.md`](./scenario.md)。

## 意图

整条官网叙事的承重命题：**在官网页面说话 = 在一个 world session 里说话。** 一个已登录
访客在官网对话框里输入，就是在**往页面绑定的那个 world session 写入**；而**在那个 world
session 内部产生的回复**（由 agent 或另一个成员）会流回并**渲染到官网页面上**。官网页面
是某个 world session 的一张前端脸，同步是**双向**的。

这是旅程**第 3 段** —— 整个产品 demo 挂在其上的主线。它是场景
[38](../38-share-deploy-same-session/scenario.zh_cn.md)（分享 → 同一 session）与
[39](../39-redeploy-publish-fork-session/scenario.zh_cn.md)（Try world → 重建自有 session）的前置，
并承接场景 [36](../36-homesite-browse/scenario.zh_cn.md)（访客在 36 的登录门控后已登录）。

## 前置条件

标准前置（README §1.1），另加：

- **已登录** —— 访客完成场景 36 第 2 段（登录门控 → 回跳 → `已登录`）；对话框输入框**可用**。
- **页面 ↔ session 绑定** —— 官网页面是绑定到一个 world session 的 hello 产物
  （参考 `~/Desktop/Socialware.html` 里的 `data-session-uri="session://system/hello/web"`）。
  每个打开的 hello 页面 == 一个 session（2026-07-02 产品决策）。
- **用户怎么观察** —— composer 的 **查看当前session** 按钮带一个红色新消息计数（红点）；
  点它**进入 world 的官网 session** 读完整对话。没有内联面板。`world` 是后端 session 基质；
  官网只显示红点 + 跳转。

## 角色

- **访客（已登录）**：一个真实 `Ezagent.Entity.User`，是绑定 world session 的**成员**
  （成员资格基元 = 场景 35）。
- **World session**：`session://<workspace>/hello/<slug>` —— 页面与 world 共享的
  那一条对话。
- **World 侧回复者**：session 上配置的 agent，或从 Word IM 侧回复的另一成员。

## 步骤

### 发送 — 页面 → session（经 composer）

1. **输入 + 发送** —— 在官网 composer（登录后可用）向 `.previewbar-input` 输入，点
   `.previewbar-action`（现在是**发送**，不再是未登录的 `登录`）。→ 消息写入绑定的官网 session。

### 新消息红点（用户怎么知道）

2. **每来一条新消息，红点 +1** —— 官网 session 每多一条消息 —— 用户自己发的**以及**任何
   回复（agent 或另一成员）—— 都给 **查看当前session** 按钮加一个红点计数。这就是用户不离开
   官网、也能知道"话进了、有回复"的方式。

### 看完整 session

3. **点 查看当前session** → 进入 world 的官网 session，读完整对话（用户的消息 + 回复）。
   红点清零。完整 session 视图在 world，官网只显示红点 + 跳转。

## 实测结果 vs 预期

行为层（CapBAC/成员资格基元在场景 35 断言，此处 cross-ref、不重证）：

- 步骤 1：恰好一条消息写入绑定的官网 session；其 `session_uri` == 页面的 `data-session-uri`
  （不漂到别的 session）。
- 步骤 2：每来一条新消息（用户**或** agent）让 **查看当前session** 红点 +1；红点反映该访客
  的新消息计数。
- 步骤 3：点 **查看当前session** 进入 world 的官网 session，展示共享对话（发出的消息 + 回复）；
  红点清零。

## 失败模式（需测试）

- **消息永不到达 session** —— 对话框"发送"了但无 session 行写入、红点也不 +1。"失败了谁会
  知道？" → 必须报错，绝不静默 no-op。
- **回复来了红点不更新** —— 官网未订阅 session 的新消息信号，用户永远不知道有回复到了。
- **查看当前session 打开了错的 session** —— 深链解析到了与页面绑定不同的 session。
- **红点不清零** —— 用户在 world 看过 session 后计数仍在，永远像有未读。
- **串 session 漂移** —— 页面写到了绑定之外的另一个 session（例如每次输入新建一个 session），
  破坏"页面 == 一个 session"不变式。
- **匿名写入泄漏** —— 匿名访客竟能写入 session（必须按场景 36 保持门控）。

## 交叉引用

- 场景 [36](../36-homesite-browse/scenario.zh_cn.md) —— 把访客送入本 scenario 起点
  已登录态的登录门控。
- 场景 [35](../35-external-user-anon-access/scenario.zh_cn.md) —— 匿名用户 + 成员资格
  读写基元。
- 旅程第 4–5 段：[38](../38-share-deploy-same-session/scenario.zh_cn.md)、
  [39](../39-redeploy-publish-fork-session/scenario.zh_cn.md)。
- 产品决策（2026-07-02 会）：world = IM 后端，hello = 展示面；每个 hello 页面 == 一个 session。
- Socialware 外链路由 + 绑定：`/socialware/external`
  （`apps/ezagent_web/lib/ezagent_web/router.ex:157`）；`~/Desktop/Socialware.html` 的
  `data-session-uri`。

## 备注

- **两个后端依赖尚未构建**（2026-07-02 会）：(1) world→官网的**新消息计数推送**（喂红点），
  (2) 从 查看当前session 打开 world 官网 session 的**深链**。二者都是 world/后端功能
  （见 handoff → zyli）。建成前用**未实现的空白 HTML 占位**录制；发送（composer→session）
  可在 `docs/website-demo/v1` mock 的 `mock-ezagent-api.js` 上跑。
- **cookie 注意** —— 官网登录当前借道一个覆盖 `*.ezagent.chat` 的 fornax-cookie
  （2026-07-02 会）；这是系统级问题，此处记录不修。override 移除后，已登录前置可能需要
  真实的按域登录。
- **状态 🚧。** 在确定性/实景测试 + runbook + agent-browser 录屏存在且 ruihua/Allen
  签收前，**不要**标 ✅。
