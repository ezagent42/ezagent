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
[39](../39-redeploy-publish-fork-session/scenario.zh_cn.md)（重新部署 → fork）的前置，
并承接场景 [36](../36-homesite-browse/scenario.zh_cn.md)（访客在 36 的登录门控后已登录）。

## 前置条件

标准前置（README §1.1），另加：

- **已登录** —— 访客完成场景 36 第 2 段（登录门控 → 回跳 → `已登录`）；对话框输入框**可用**。
- **页面 ↔ session 绑定** —— 官网页面是绑定到一个 world session 的 hello 产物
  （参考 `~/Desktop/Socialware.html` 里的 `data-session-uri="session://system/hello/web"`）。
  每个打开的 hello 页面 == 一个 session（2026-07-02 产品决策）。
- **World 界面** —— 同一 session 在 world/Word（IM 后端）可观察，例如
  `/admin/sessions/<session-uri>` 或 `app.ezagent.chat` 的 world session 视图。

## 角色

- **访客（已登录）**：一个真实 `Ezagent.Entity.User`，是绑定 world session 的**成员**
  （成员资格基元 = 场景 35）。
- **World session**：`session://<workspace>/hello/<slug>` —— 页面与 world 共享的
  那一条对话。
- **World 侧回复者**：session 上配置的 agent，或从 Word IM 侧回复的另一成员。

## 步骤

### 出站 — 页面 → world

1. **从页面发送** —— 在官网对话框（登录后可用）输入一条消息并发送
   *（`.previewbar-input` + `.previewbar-action`，现处于已登录态）*。
2. **在 world 观察** —— 在 world/Word 打开同一 session。
   → 页面发出的消息**出现在 world session 里**，归属该已登录访客，落在页面绑定的**同一个**
   `session_uri` 上。

### 入站 — world → 页面

3. **从 world 回复** —— 在 world session 里产生一条回复（agent 应答，或另一成员从 Word 发消息）。
4. **在页面观察** —— 回到官网页面（不刷新）。
   → world 侧回复**流回并渲染到官网页面** feed 上，实时，无需手动刷新。

## 实测结果 vs 预期

行为层（CapBAC/成员资格基元在场景 35 断言，此处 cross-ref、不重证）：

- 步骤 1–2：恰好一条消息写入绑定的 world session；其 `session_uri` == 页面的
  `data-session-uri`（不漂到别的 session）。
- 步骤 3–4：world 侧回复实时渲染到页面 feed；页面与 world 展示**同一条共享对话**，
  不是两份拷贝。
- 往返同一性：页面发出的消息与 world 的回复，都属于**同一个** session 时间线。

## 失败模式（需测试）

- **页面消息永不到达 world** —— 对话框"发送"了但 world 无 session 行。"失败了谁会知道？"
  → 必须报错，绝不静默 no-op。
- **world 回复永不到达页面** —— 页面从未订阅 session publisher，导致 world 侧回复在手动
  刷新前不可见。
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

- **后端对话对接尚未连通**（2026-07-02 会："对话交互还没接"）。在 world↔页面桥建成前，
  **入站（world→页面）回复面用未实现的空白 HTML 占位录制** —— scenario 断言"world 回复
  渲染到页面"，占位页替代尚未构建的传播。出站（页面→world）在 `docs/website-demo/v1` mock
  的 `mock-ezagent-api.js` 可用时对其录制。
- **cookie 注意** —— 官网登录当前借道一个覆盖 `*.ezagent.chat` 的 fornax-cookie
  （2026-07-02 会）；这是系统级问题，此处记录不修。override 移除后，已登录前置可能需要
  真实的按域登录。
- **状态 🚧。** 在确定性/实景测试 + runbook + agent-browser 录屏存在且 ruihua/Allen
  签收前，**不要**标 ✅。
