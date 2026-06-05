# Loom 可分享快照 + Fork(SPEC,2026-06-05)

> 工作 spec,实施期可微调。承接 publish/share-link + 可增强发布页(user_schema)。

## 模型

- **session.loom(创作)**:唯一有 **v0** 的 session,@v0 重写页面源码(base)。
- **发布物 / 快照(消费)**:发布当前 session 的**冻结状态**,生成分享链接。**无 v0**,
  base 冻结,只能叠 user_schema ops + 对话(业务 worker)。
- **快照(share snapshot)** = 模板引用 + 冻结对话历史 + 冻结 user_schema ops +
  原 session URI + owner(阶段二)。**不可变**:快照后的新对话不回流。
  > 术语:叫 "share snapshot",别跟 Kind snapshot(状态持久化)混。

### 分享链接打开时的分流(阶段二)
- **分享者本人(已登录且=owner)** → 重定向到原页面 `/loom/<ws>/<origin_sid>`。
- **其他已登录 / 未登录** → **只读**浏览快照(页面+ops+对话历史)。
- 非分享者尝试"发起对话":
  - 未登录 → 跳转 ezagent 登录页(带 return URL),登录后回来。
  - 已登录 → "fork 到新 session 以继续" 确认。
  - 两者都收敛到 **fork**:从快照建一个**自己的**新 session(无 v0,带冻结历史 + 复制 ops)。

## 锁定决策
1. 只读浏览快照**要显示对话历史**。
2. 不用 temp-user;快照是**独立可读冻结产物**,匿名只读不建 session、不碰分享者 session。
3. 登录先做**跳转登录页**(弹框作后续打磨)。
4. v0 只在 `session.loom`;发布物 fork 出的 session **无 v0**。
5. "保存模板"按钮去掉(发布够了)。
6. fork 后的"对话"= session 的 orchestrator + 业务 worker(无 v0);增强(floating ops)
   是独立入口,v1 不合并。

---

## 阶段一(不依赖身份)

### 数据
`~/.ezagent/<profile>/loom_snapshots.json`,key=token:
```
{ "<token>": { "ws", "template_class", "origin_sid",
               "history": [frame...], "ops": [op...], "created_at" } }
```
- 复用发布 token。`history` = 发布时刻 session 消息的冻结副本(含 page_update,
  内含页面 files);`ops` = 发布时刻 user_schema 的副本(copy-on-snapshot)。

### 后端
- `POST /api/:ws/:sid/publish`(扩展):除现有 template 外,**冻结** history(读
  MessageStore)+ ops(读 UserSchema)写入 snapshot store。返回 token + link。
- `GET /loom/snapshot/:token` → `{ok, history, ops, ws, origin_sid}`(只读渲染用)。
- `POST /p/:token/fork` → `instantiate(template, no_v0)` 建新 session → 把冻结 history
  seed 进新 session(MessageStore)→ 把冻结 ops **复制**进新 session 的 user_schema →
  返回 `{ws, sid}`。(阶段二:owner=登录用户)
- **Team 无 v0**:`Team.ensure_team(..., include_v0: false)`;发布物 SavedClass 的
  `instantiate` 在 augmented tmpl 里带 `"no_v0" => true` → LoomSession 据此跳过 v0。
  原 `session.loom` 不带 → v0 照常。
- **编排器解耦 v0**:orchestrator 不再自动把改页派给 v0,只认显式 `@loomv0_<sid>`
  (`parse_mentions` 已支持)。

### 前端
- **只读快照视图**:打开 `/loom/p/<token>`(非 resume),`GET /loom/snapshot/:token`
  → 渲染 页面(从 history 的 page_update 提 files)+ ops + **只读对话历史面板**。
- **交互闸**:只读视图里"发起对话/增强" → 阶段一直接弹"fork 以继续"→
  `POST /p/:token/fork` → `{ws,sid}` → 跳到新 session(可编辑)。
- ChatPanel 加 `readonly` 模式(隐藏输入框,显示历史 + fork 提示)。

### 验证(阶段一)
- 发布 → snapshot.json 有 history+ops 冻结副本(curl/文件核对)。
- `GET /loom/snapshot/:token` 返回 history+ops。
- `POST /p/:token/fork` → 新 session 有冻结历史 + 复制的 ops + **无 v0**(team 成员核对)。
- 浏览器:打开链接 → 只读看到页面+ops+历史;点 fork → 进可编辑新 session。
- 编排器:普通消息不再自动改页;`@loomv0_<sid>` 才改页(仅在 session.loom)。

---

## 阶段二(身份)

### 后端
- `GET /loom/whoami` → `{logged_in, entity_uri}`,从 ezagent 鉴权 cookie/session 解析
  current_entity(复用 admin 的 token 校验;web_plug 自行 fetch_session)。
- `POST /api/:ws/:sid/publish`:记 `owner = current_entity`(写进 snapshot)。
- `POST /p/:token/fork`:`owner = current_entity`;未登录拒绝(前端先跳登录)。
- 分流由前端按 whoami 决定(见下)。

### 前端
- 打开 `/loom/p/<token>`:先 `whoami`。
  - `entity == snapshot.owner` → `location` 重定向 `/loom/<ws>/<origin_sid>`(原 session
    若已没了 → 兜底回只读快照)。
  - 否则只读快照。
- 非分享者点"发起对话":
  - 未登录 → 跳 `/login?return_to=<当前分享链接>`;登录后回来,已登录态 → 可 fork。
  - 已登录 → "fork 到新 session" 确认 → `POST /p/:token/fork`。

### 验证(阶段二)
- owner 打开自己的链接 → 重定向原页面。
- 他人(已登录)打开 → 只读;点对话 → fork 确认 → 自己的新 session(归属自己)。
- 匿名打开 → 只读;点对话 → 跳登录 → 回来 → fork。

### 风险
- **whoami 从 cookie 解析身份**是阶段二最不确定点(web_plug 绕过了 `:browser`/session
  pipeline)。须复用 ezagent 现有 auth token 校验;若 cookie/session 集成受阻,
  sharer 重定向 / 匿名分流会降级(阶段一仍独立可用)。
- 不变式 #10:快照带历史是**新概念(非 template fork)**,fork 是专门操作,勿混入
  template 语义。

## 不做(future)
- 元素级 op / 圈画(base 重写会让元素级 ops 错位;位置型 addText 不受影响)。
- 登录弹框(先跳转)。
- 快照/session 清理(接受累积)。
- 增强 AI 接 LLM(仍写死规则)。
