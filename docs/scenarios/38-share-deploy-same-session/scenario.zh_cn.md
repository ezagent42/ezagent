# 场景 38：分享 / deploy —— 邀请他人进入同一个 session（群聊）

**分类**：3 — 会话流程
**状态**：🚧 设计规范 — 分享/deploy 控件尚未构建；分享动作用**未实现的空白 HTML 占位**
录制。未 ✅（无测试 + 未签收）。
**作者**：Claude（与 ruihua），2026-07-02 — 官网用户旅程第 4 段。

> 双语逐行镜像：[`scenario.md`](./scenario.md)。

## 意图

两条传播路径中的**第一条**。session owner **分享**（deploy）官网链接；被邀访客打开、登录，
**加入同一个 session** —— 所有人落到**一条共享对话**里（群聊），既有对话历史保留。被邀访客
是**end user / 群成员**，**不是**新 owner。这是"你和我在同一个群"的关系。

与场景 [39](../39-redeploy-publish-fork-session/scenario.zh_cn.md)（重新部署 / publish）
对照：那里访客**fork 出一个新 session** 并成为其 owner。**deploy = 同一个 session；
publish = 新的 session。** 把这个区分展示出来正是第 4、5 段的全部意义。

这是旅程**第 4 段**，承接场景
[37](../37-homesite-dialog-world-sync/scenario.zh_cn.md)（owner 已有一个活的页面↔session）。

## 前置条件

标准前置（README §1.1），另加：

- **Owner 已有活 session** —— 场景 37 完成：一个已登录 owner，其官网页面绑定的 world
  session 已承载一些对话。
- **一个分享/deploy 控件** —— 页面（或 world）上一个能为该 session 产出**分享链接**的控件。
  这是 `deploy`/`share`，区别于 `publish`（2026-07-02 产品决策）。
- **第二个访客** —— 用户 B，初始匿名，持有分享链接。

## 角色

- **Owner（A）**：world session 的已登录 owner（来自场景 37）。
- **被邀访客（B）**：初始匿名；登录后成为 A 的 session 的**成员（end user）** —— 非 owner。
- **共享 world session**：A、B 共同说话的那一个 `session://<workspace>/hello/<slug>`。

## 步骤

### 分享

1. **Owner 分享** —— A 点页面上的分享/deploy 控件。
   → 产出 A 的 session 的分享链接。

### 被邀访客加入同一 session

2. **B 打开链接** —— B 导航到分享链接 → 看到 A 的官网页面（A 的 session 的外部/匿名视图，
   cross-ref 场景 35）。
3. **B 写操作门控 → 登录** —— B 试图在对话框写入 → 被门控去登录（cross-ref 场景 36）→ B 登录。
4. **B 以成员加入** —— 登录后，B 被加为 A 的**同一个 session 的读写成员**（不是新 session）。
5. **群聊** —— B 发一条消息；出现在 A 的 session 里；A 在自己页面 / world 里看到 B 的消息。
   两人在一条对话里说话；B 加入前的历史保留。

## 实测结果 vs 预期

行为层（成员资格/CapBAC 基元在场景 35 断言）：

- 步骤 4：B 的成员资格指向与 A 页面绑定**相同**的 `session_uri` —— 不为 B 新建 session。
- 步骤 5：A 与 B 是**一个 session 的两个成员**；对话共享；加入前历史保留（deploy 保留历史，
  2026-07-02 决策）。
- 角色：B 是 **end user / 成员**，非 owner —— B 不能重配或销毁 A 的 session。

## 失败模式（需测试）

- **fork 而非加入** —— B 得到一个自己的新 session 而非加入 A 的。那是场景 39（publish）的行为；
  对 deploy 而言是 bug。
- **B 成了 owner** —— B 被授予 owner/租户 caps 而非成员 caps（必须保持 end-user，按租户/
  end-user 区分，2026-07-02 line 409）。
- **历史丢失** —— B（或 A）看不到 B 加入前的对话。
- **匿名写入泄漏** —— B 登录前就能写（必须保持门控，场景 36）。

## 交叉引用

- 场景 [37](../37-homesite-dialog-world-sync/scenario.zh_cn.md) —— 本 scenario 共享的
  活页面↔session。
- 场景 [39](../39-redeploy-publish-fork-session/scenario.zh_cn.md) —— **另一条**传播路径
  （publish/fork → 新 session）；38 与 39 是 deploy-vs-publish 这一对。
- 场景 [35](../35-external-user-anon-access/scenario.zh_cn.md) —— 匿名→成员加入基元
  （B 的加入是一次成员资格授权）。
- 场景 [36](../36-homesite-browse/scenario.zh_cn.md) —— B 的写操作门控→登录。
- 产品决策（2026-07-02 会）：deploy/share = 同一 session、保留历史、end-user 成员；
  租户 vs end-user 区分。

## 备注

- **术语** —— 会上定：今天的 `share` == `deploy`（直接用一个 app、群聊、保留历史）。该控件
  未来可能拆成 `publish`（场景 39）与 `deploy`。本 scenario 是 **deploy** 那一半。
- **录制占位** —— 分享/deploy 控件与 B 的加入流尚未构建；分享动作在真实控件上线前用
  **未实现的空白 HTML 占位**录制。成员加入可在 scenario 35 的 匿名→成员 基元可用处对其演练。
- **状态 🚧。** 在确定性/实景测试 + runbook + agent-browser 录屏存在且 ruihua/Allen
  签收前，**不要**标 ✅。
