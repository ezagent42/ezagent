# 场景 39：重新部署 / publish —— fork 一个新 session，成为它的 owner

**分类**：3 — 会话流程
**状态**：🚧 设计规范 — publish → session-template → fork 尚未构建，且 `session template`
概念正在改造（吸收 APP 概念，2026-07-02 进行中）；用**未实现的空白 HTML 占位**录制。
未 ✅（无测试 + 未签收）。
**作者**：Claude（与 ruihua），2026-07-02 — 官网用户旅程第 5 段。

> 双语逐行镜像：[`scenario.md`](./scenario.md)。

## 意图

**第二条**传播路径。用户**重新部署**（publish）自己的 session + 页面 → 存为一个
**session template**（在插件市场 / 模板列表可发现）→ 某人（本人或他人）从该模板
**fork 出一个新 session** → fork 者**成为新 session 的 owner** → 且 fork 者能在
**world 里看到自己新 session 的对话**。这是 git-fork / 租户关系："他复制了我的模板另起炉灶。"

与场景 [38](../38-share-deploy-same-session/scenario.zh_cn.md)（deploy）对照：那里访客以
成员身份加入**同一个** session。**publish = 新 session、新 owner、不带历史；
deploy = 同一 session、成员、保留历史。** 把这一对展示出来是整条旅程的收束。

这是旅程**第 5 段**，承接场景 [37](../37-homesite-dialog-world-sync/scenario.zh_cn.md)。

## 前置条件

标准前置（README §1.1），另加：

- **一个可发布的活 session** —— 场景 37 完成：一个已登录作者，其官网页面绑定一个 world session。
- **一个 publish 控件** —— 把 session + 页面存为一个 **session template** 的控件
  （这是 `publish`，区别于 `deploy`/`share`）。
- **一个发现面** —— 已发布模板出现的插件市场 / 模板列表（当前可能是占位下拉，
  2026-07-02 line 466）。

## 角色

- **作者（A）**：执行 publish 的已登录 owner（来自场景 37）。
- **Fork 者（C）**：一个已登录用户（可以是 A），实例化已发布模板；**成为**结果新 session 的
  **owner**（一个**租户**，非 end-user）。
- **Session template**：发布产物（今天的 `session template`；正在改名/吸收 `APP` 概念，
  2026-07-02）。
- **新 fork session**：`session://<workspace>/hello/<new-slug>` —— C 自己的，与 A 的不同。

## 步骤

### 发布

1. **作者发布** —— A 点 session + 页面上的 重新部署/publish。
   → 从 A 的 session 配置 + 页面创建一个 **session template**；它出现在插件市场 / 模板列表。
   publish **不**携带 A 的对话历史。

### Fork → 新的自有 session

2. **Fork 者找到模板** —— C 打开插件市场 / 模板列表，找到 A 已发布的模板（下拉 / 列表项）。
3. **Fork** —— C 选中它 → 从模板 spawn 出一个**新 session**，**归 C 所有**，配 C 自己全新的页面。
4. **C 说话** —— C 在 C 的新 session 页面里发消息；对话是 C 自己的（全新，无 A 的任何历史）。
5. **Owner 在 world 看到** —— C 打开 world → 在 world 里看到 C 新 session 的对话
   （owner 能在 Word IM 后端观察/配置它）。

## 实测结果 vs 预期

行为层（成员资格/CapBAC 基元在场景 35 断言；模板机制 cross-ref 场景 21）：

- 步骤 1：一个 session template 存在且在列表可发现；A 的历史**不**属于它。
- 步骤 3：fork 出的 `session_uri` 是**新的**（≠ A 的 session）；C 对其持有 **owner / 租户** caps。
- 步骤 4–5：C 的对话是全新的、且 C 能在 world 看到；publish 创建了一个**新** session、
  而非加入（deploy/publish 区分成立）。

## 失败模式（需测试）

- **加入而非 fork** —— C 以成员身份落进 A 的 session，而非一个新的自有 session。那是场景 38
  （deploy）的行为；对 publish 而言是 bug。
- **历史泄漏进 fork** —— A 的对话历史渗进 C 的新 session（publish 必须干净，2026-07-02 决策）。
- **Fork 者不是 owner** —— C 只拿到成员 caps，不能重配/再发布（破坏租户关系）。
- **模板不可发现** —— publish"成功"了但模板从不出现在列表里，没人能 fork 它。静默成功 = bug。

## 交叉引用

- 场景 [38](../38-share-deploy-same-session/scenario.zh_cn.md) —— **另一条**传播路径
  （deploy/同一 session）；38 与 39 是 deploy-vs-publish 这一对。
- 场景 [37](../37-homesite-dialog-world-sync/scenario.zh_cn.md) —— 被发布的活 session。
- 场景 [21](../21-template-version-tag/scenario.md) —— 模板实例化 / 版本标签机制
  （fork 是一次模板 spawn）。
- 场景 [35](../35-external-user-anon-access/scenario.zh_cn.md) —— 成员资格/所有权基元。
- 产品决策（2026-07-02 会）：publish = 存为 session template + fork（git-fork）、新 owner、
  无历史；插件市场 = session-template 列表；租户 vs end-user 区分。

## 备注

- **概念在流动中** —— `session template` 今天正被改造（林懿伦）：`APP` 概念被吸收进它、
  可能改名。本 scenario 描述的是**产品行为**（publish → fork → 拥有），对命名鲁棒；
  改造落地后更新模板术语。
- **录制占位** —— publish、插件市场列表、fork-spawn 均未构建；在真实控件上线前用
  **未实现的空白 HTML 占位**（市场列表用占位下拉）录制。
- **版本** —— 发布 N 次创建 N 个模板（保留版本、不覆盖；2026-07-02 line 565 选的更简方案）。
  超出本 scenario happy path 范围，留待后续失败矩阵记录。
- **状态 🚧。** 在确定性/实景测试 + runbook + agent-browser 录屏存在且 ruihua/Allen
  签收前，**不要**标 ✅。
