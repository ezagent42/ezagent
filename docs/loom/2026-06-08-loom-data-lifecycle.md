# Loom 数据生命周期:从 plugin 到 session.loom 到生成物(2026-06-08)

> 这份文档回答一个问题:**loom 从插件启动,到一个 `session.loom` 跑起来,到用户对话生成页面、
> 发布、分享、fork —— 每一步到底产生了什么数据、存在哪、谁拥有它。**
> 重点标注**用户数据**和**页面源码**这两类最关心的东西。
>
> 代码实地核对于 `feat/loom` @ `c08b50a6`(2026-06-08)。文件引用形如 `web_plug.ex:857`。

---

## 0. 一眼看全:数据存在哪

loom 的数据分**三个层级**,各有不同的持久化机制和生命周期:

| 层级 | 存什么 | 物理位置 | 谁写 | 重启后还在? |
|---|---|---|---|---|
| **A. 核心 Kind 状态**(框架管) | session.loom 本体、orchestrator/worker/v0 的 slice(**含页面源码**) | ezagent core 的 SnapshotStore + Repo(SQLite,`EZAGENT_HOME`) | 框架自动 snapshot-on-change | ✅ 在 |
| **B. 会话消息历史**(框架管) | session 里每条 chat 消息(用户的话 + agent 的回复 + page_update) | core `MessageStore` | `chat.send` dispatch | ✅ 在 |
| **C. loom 旁路 JSON**(loom 自管) | 用户增强 ops、Stitch 对话、分享快照、发布模板 | `~/.ezagent/<profile>/loom_*.json` 4 个文件 | loom 的 web_plug / 各 store 模块 | ✅ 在(普通文件) |

**关键认知**:
- **页面源码不在任何 loom JSON 文件里**。它活在 **orchestrator Kind 的 `:loom_orchestrator` slice** 的 `loom_source` 字段(层级 A),由框架的 Kind snapshot 持久化。
- loom 的 4 个 JSON(层级 C)是 v0 阶段"图快"的旁路存储,只装**发布/分享/增强**这套消费侧数据。moduledoc 明说架构正确归宿是迁进 slice(`user_schema.ex:21`)。

### 四个旁路 JSON(`~/.ezagent/<EZAGENT_PROFILE>/`,profile 默认 `default`)

| 文件 | key | value | 写入点 |
|---|---|---|---|
| `loom_user_schemas.json` | `session://loom/<ws>/<sid>` | `[op, op, ...]` 增强操作序列 | Stitch 加文字 / fork 复制 |
| `loom_stitch_chats.json` | `session://loom/<ws>/<sid>` | `[{role, text, id}, ...]` Stitch 对话 | 每条 Stitch 收发 |
| `loom_snapshots.json` | `<token>`(16-hex) | `{ws, page, ops, conversation, origin_sid, created_at}` | 点"分享"时冻结 |
| `loom_saved_classes.json` | `session.<name>` / `session.pub_<hex>` | `{saved_state, description, saved_at, [published, token, ws, published_from]}` | 存为模板 / 发布 |

---

## 1. 阶段 0 —— Plugin 启动

**模块**:`EzagentPluginLoom.Application.start/2`(`application.ex:52`)+ `after_boot/0`(`:174`)

产生/加载的数据:
- **OTP 监督树启动**:loom 的 DynamicSupervisor(`EzagentDomainInstanceMessage.AgentSupervisor` 等,2026-06-05 从已删的 `ezagent_domain_chat` 迁来)托管所有 loom Kind 进程。**此时还没有任何 session**。
- **`after_boot/0` → `SavedClasses.register_all_from_disk/0`**(`application.ex:194`):
  读 `loom_saved_classes.json`,把每条 `saved_state` 用 `Module.create/3` 在 **runtime 重新编译**成一个 Template Class 模块(`Ezagent.PluginLoom.Template.Generated.<Camel>`),注册进 `Ezagent.TemplateRegistry`。
  → **这就是"发布的页面/存的模板重启后还在"的机制**:模板不是活进程,是磁盘 JSON + 启动时重新长出来的模块。
- 可选:`~/.ezagent/<profile>/loom-design.md`(运营自定义设计系统,`prompts.ex:330`)如存在则被 prompt 读取。

**此阶段无用户数据、无页面源码。**

---

## 2. 阶段 1 —— `session.loom` 实例化

**触发**:`/workspaces/<ws>` 后台点 "Add template"(class=`session.loom`),或 `Bootstrap.run/1`(`bootstrap.ex:42`)程序化创建。

**模块**:`Ezagent.PluginLoom.Template.LoomSession.instantiate/3`

产生的数据:
1. **session.loom 这个 Kind 被 spawn**:URI `session://loom/<ws>/<sid>`(层级 A)。它是一个 Chat session(`ezagent_domain_instance_message` 底座),自带空消息历史(层级 B)。
2. **临时用户**:`TempUser.provision/ensure_named`(`bootstrap.ex:45`)→ `entity://user/<ws>/loomui_<sid>`(或 `tmp_<id>`)。这是浏览器这一 tab 的发言身份。
3. **seed 的页面源码**:实例化时若没有 `saved_state`,orchestrator 的 `loom_source` 用 `Prompts.loom_seed_files()`(种子页)初始化(`loom_orchestrator.ex:81`)。若来自发布物/快照,则注入冻结的 `saved_state.orchestrator.loom_source`。

`session_name`(sid)决定 URI;无 sid 不合法。`pub_<hex>` 形态的 sid 是发布页打开/fork 时 mint 的(`web_plug.ex:928`)。

---

## 3. 阶段 2 —— 组队(Team)

**模块**:`EzagentPluginLoom.Team.ensure_team/2`(`team.ex:44`,幂等 reconciler)

spawn 出固定 4(默认)个 agent Kind(层级 A,各自有 slice 状态):

| 角色 | URI | slice / 状态 | 装什么 |
|---|---|---|---|
| **编排器** orchestrator | `entity://agent/<ws>/loomorch_<sid>` | `:loom_orchestrator` | persona、workers、pending 回合、**`loom_source`(页面源码!)** |
| **worker** ×2(默认 policy/company) | `entity://agent/<ws>/loomworker_<sid>_<theme>` | `:loom_worker` | 主题、system_prompt、role |
| **v0**(页面生成器) | `entity://agent/<ws>/loomv0_<sid>` | — | 把用户意图 → React 页面源码 |

- worker 数量可变(`opts[:worker_themes]`,`team.ex:51`),模板可带自定义 worker spec。
- **`include_v0?`**(`team.ex:54`):只有最初的创作 session 有 v0;**发布物/快照 fork 出来的 session `include_v0: false`** —— base 冻结,只能叠 user_schema,不能重写源码。这是创作页 vs 消费页的根本分界。

**此阶段页面源码 = orchestrator slice 里的 seed 页**(还没被用户改过)。

---

## 4. 阶段 3 —— 用户对话 → 页面生成(**页面源码在这里产生**)

**入口**:loom 前端发消息 → `POST /loom/api/<ws>/<sid>/...` → `web_plug.ex` 的 `send_to_session/3`(`:309`)

数据流:
1. 用户消息经 `Ezagent.Invocation.dispatch`(`chat.send`)进 session → **存进 MessageStore(层级 B)**,默认 @mention orchestrator(`parse_mentions/4`,`:356`)。
2. orchestrator `handle_receive`(`loom_orchestrator.ex:93`):
   - 普通改页/问答 → 拆解 → fan-out 给 worker → 聚合 → 合成一张 scene card 回复(也进 MessageStore)。
   - 改页面则把任务交给 **v0**(`@loomv0_<sid>`,2026-06-05 起 v0 从编排器解耦,只认显式 @v0)。
3. **v0 生成页面源码**:v0 产出 React 源码,以 `<span type="page_update">` 形式回到 session。
4. orchestrator 的 `handle_page_update`(`:104`)捕获 → **整体替换 `:loom_orchestrator` slice 的 `loom_source`**(`%{path => content}` 多文件 map,如 `%{"/App.jsx" => "...", "/components/Hero.jsx" => "..."}`)。

> **页面源码的权威存储 = orchestrator Kind 的 `loom_source` slice 字段**。
> 框架对这个 slice 做 snapshot-on-change,所以页面源码随 Kind 持久化(层级 A),**重启后还在**。
> 前端 Sandpack 实时预览拿的就是这份 files map(经 loom-view bridge 渲染)。

**用户数据产出**:对话历史(MessageStore)+ 最新页面源码(orchestrator slice)。

---

## 5. 阶段 4 —— 发布(Publish)

**入口**:loom 编辑页"发布"按钮 → `POST /loom/api/<ws>/<sid>/publish` → `publish_session/3`(`web_plug.ex:682`)

产生的数据:
1. **读全队冻结快照** `read_full_session_snapshot`(`:931`):
   ```
   %{ "orchestrator" => %{persona, loom_source},   # ← 页面源码副本
      "workers"      => [%{theme, system_prompt, role}, ...],
      "v0"           => %{} }
   ```
   `loom_source` 从**活的 orchestrator** 经 `Ezagent.Kind.get_slice(orch_uri, :loom_orchestrator)` 读出(`read_orchestrator_snapshot`,`:931` 区)。
2. 生成 **token**(16-hex)+ 唯一名 `pub_<hex>`,调 `SavedClasses.save_one/4` 带 meta `%{published: true, token, ws, published_from: sid}`。
3. → 写进 **`loom_saved_classes.json`**(层级 C),并 `Module.create` 出一个不可变 Template Class。
4. 返回分享链接 `/loom/p/<token>`。

> **发布物 = 纯模板(无快照)**。它冻结的是**那一刻的页面源码 + 队伍配置**。
> 打开 `/loom/p/<token>` = 一个**全新的消费 session**(无 v0,base 冻结)。
> 发布**不**冻结对话或增强 ops —— 那是"分享快照"的事(阶段 6)。

---

## 6. 阶段 5 —— 打开发布页 + Stitch 增强(**消费侧用户数据**)

**打开** `/loom/p/<token>` → `POST /p/<token>/open` → `open_published/1`(`web_plug.ex:712`):
- token → 模板 → **mint 一个新 session**(随机 `pub_<hex>` sid,无 v0)+ per-tab 临时用户 `loomui_<sid>` + join。
- 每次打开都是独立访客 session。

**Stitch**(右下角悬浮聊天,独立 DeepSeek-v4-flash 非思考)→ `POST /p/<ws>/<sid>/stitch` → `stitch_send/3`(`:765`):
1. 用户消息追加进 **`loom_stitch_chats.json`**(层级 C,key=session URI)。
2. 直连 DeepSeek(**不走会话编排器、不走 v0**),回复里若含 `OP: {json}` 行(`parse_stitch_reply`,`:825`)→
3. 该 op(如 `{"op":"addText","position":"top","text":"..."}`)追加进 **`loom_user_schemas.json`**(层级 C)。
4. 助手回复也存回 stitch chat。

> **消费侧最终页面 = 渲染(发布物冻结 base) ⊕ 应用(user_schema 的 op 序列)**(`user_schema.ex:8`)。
> base 所有访客共享且不可变;user_schema **从属于每个访客 session**,空白起步。
> Stitch **不碰页面源码** —— 它只往 user_schema 追加叠加层 op。源码只有创作页的 v0 能改。

**两类用户数据在这阶段产生**:Stitch 对话(`loom_stitch_chats.json`)+ 增强 ops(`loom_user_schemas.json`)。

---

## 7. 阶段 6 —— 分享快照(Share Snapshot)

**入口**:消费页 Stitch 里的"分享"按钮 → `POST /p/<ws>/<sid>/snapshot` → `create_snapshot/2`(`web_plug.ex:857`)

把当前消费会话的**三样东西冻结成副本**,写进 **`loom_snapshots.json`**(层级 C,key=新 token):
```jsonc
{
  "ws": "...",
  "page":         { "/App.jsx": "..." },   // ← 页面源码副本(取自 orchestrator loom_source)
  "ops":          [ /* user_schema 副本 */ ],
  "conversation": [ /* StitchChat 副本 */ ],
  "origin_sid": "pub_...",
  "created_at": "2026-..."
}
```

> **快照不可变**:分享者之后继续增强/对话,**不回流**进这份快照。被分享者只读看到的是冻结时刻。
> 这是与 Kind snapshot(框架状态持久化)**不同的概念**,代码里刻意叫 "share snapshot"(`snapshots.ex:5`)。

被分享者打开 `/loom/p/<token>`(`GET /snapshot/<token>` 取数据)→ 只读看到 页面 + ops 叠加 + Stitch 对话历史。

---

## 8. 阶段 7 —— Fork

**入口**:被分享者(非 owner)想交互 → `POST /p/<token>/fork` → `fork_published/1`(`web_plug.ex:881`)

产生的数据:
1. 从 `loom_snapshots.json` 取快照的冻结 `page`。
2. **mint 一个新的无-v0 session**,用冻结页面作 base(经 `saved_state.orchestrator.loom_source` 注入,`:892`)。
3. **复制**快照的 `ops` → 新 session 的 `loom_user_schemas.json`(`UserSchema.replace`,`:903`)。
4. **复制**快照的 `conversation` → 新 session 的 `loom_stitch_chats.json`(`StitchChat.replace`,`:904`)。
5. 返回 `{ws, sid}` → 跳到 forker 自己的可编辑(可增强)新 session。

> fork = 从冻结快照长出**自己的**一份。复制是 copy-on-fork:之后 forker 改自己的,不影响原快照。
> fork 出的 session **无 v0** —— 只能 Stitch 增强,不能重写源码。

---

## 9. 用户数据 / 页面源码 —— 专项小结(最关心的)

### 页面源码(React 源)经过哪些形态

| 时机 | 形态 | 存储 |
|---|---|---|
| session 创建 | seed 页(`loom_seed_files/0`) | orchestrator `:loom_orchestrator` slice `loom_source` |
| 用户 @v0 改页 | v0 生成 → `<span page_update>` → 整体替换 | 同上(slice,层级 A,框架 snapshot) |
| 发布 | 副本进 `saved_state.orchestrator.loom_source` | `loom_saved_classes.json`(层级 C) |
| 分享 | 副本进 `page` | `loom_snapshots.json`(层级 C) |
| fork/打开发布页 | 从冻结副本注入新 session 的 slice | 新 orchestrator slice |

**唯一能改页面源码的是创作 session 的 v0。** 所有消费侧(发布页/快照/fork)的 base 都冻结,只能叠 user_schema。

### 用户数据分类

| 数据 | 属于谁 | 存储 | 跟随 |
|---|---|---|---|
| 创作对话(改页指令、scene card) | 创作 session | MessageStore(层级 B) | session |
| 增强 ops(addText 等) | 每个消费 session | `loom_user_schemas.json` | session URI |
| Stitch 对话 | 每个消费 session | `loom_stitch_chats.json` | session URI |
| 分享快照(页面+ops+对话 冻结副本) | token | `loom_snapshots.json` | token |
| 发布模板(页面+队伍 冻结) | class_name | `loom_saved_classes.json` | token / class |

### 临时用户身份

- 每个浏览器 tab → `entity://user/<ws>/loomui_<sid>`(或 `tmp_<id>`),`TempUser` 造,无密码,session 内能发言。
- 阶段二身份(分享者 vs 匿名 vs 其他登录用户)走 `GET /loom/whoami`(`web_plug.ex:735`)读 cookie `current_entity_uri`,与 ezagent 登录态共用。

---

## 10. 持久化 vs 易失(重启/清理边界)

- **重启后都在**:三个层级全部落盘(core SnapshotStore+Repo / MessageStore / 4 个 JSON)。
- **刷新页面**:创作页 reuse 同 sid(`Bootstrap` reuse-or-create,`bootstrap.ex:94`);发布页/fork **每次打开都是新随机 sid**(新 user_schema、新 stitch chat 空白起步)。旧 session 序列**保留不删**(内部测试期接受累积,`user_schema.ex:18`)。
- **"从头开始"清理**:删 4 个 `loom_*.json` + core 里相关 session/agent Kind 快照 + MessageStore 记录。这些数据**不进 git**(在 `~/.ezagent/`,不在仓库)。

---

## 附:相关源文件索引

| 关注点 | 文件 |
|---|---|
| 启动 + 模板重注册 | `lib/ezagent_plugin_loom/application.ex` |
| session 创建/复用 | `lib/ezagent/bootstrap.ex` |
| 组队 | `lib/ezagent/team.ex` |
| session 实例化 | `lib/ezagent/template/loom_session.ex` |
| **页面源码 slice** | `lib/ezagent/behavior/loom_orchestrator.ex`(`loom_source`) |
| v0 页面生成 | `lib/ezagent/behavior/loom_v0_worker.ex` |
| HTTP 端点(publish/snapshot/fork/stitch/whoami) | `lib/ezagent/web_plug.ex` |
| 增强 ops 存储 | `lib/ezagent/user_schema.ex` |
| Stitch 对话存储 | `lib/ezagent/stitch_chat.ex` |
| 分享快照存储 | `lib/ezagent/snapshots.ex` |
| 发布/存模板 | `lib/ezagent/saved_classes.ex` |
| 设计 spec(分享+fork) | `docs/loom/2026-06-05-shareable-snapshots-and-fork.md` |
