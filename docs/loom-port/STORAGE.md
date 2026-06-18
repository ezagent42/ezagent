# Loom 产物存储说明

> Loom 跑起来会产生一堆东西:页面源码、各种 config、知识库、角色门控、谱系、素材……本文讲它们**存成什么形式、存在哪、什么格式、怎么改**。
>
> 配套:`MIGRATION.md`(怎么移植)。

---

## 0. 一切的根:profile 数据目录

所有 loom 持久化都落在一个 **profile 数据根**下:

```
~/.ezagent/<profile>/
```

`<profile>` = 环境变量 `EZAGENT_PROFILE`(不设则 `default`;隔离测试用 `port`)。换 profile = 换一整套数据 + 库,互不影响。目录里:

```
~/.ezagent/<profile>/
├── db/ezagent_core.db        ← SQLite 运行库(权威状态:slice 快照 + 消息)
├── loom_*.json               ← 各类旁路存储(plugin 自管,见 §2)
├── loom_materials/<ws>/<sid>/ ← 素材库:真实文件/文件夹(见 §3)
└── credentials/ …            ← 凭据等(非 loom)
```

存储分三层:**① DB(权威运行态)② 旁路 JSON(plugin 自管的边角数据)③ 素材库目录(大文件)**。

---

## 1. 页面源码 & 运行态 —— 存 DB

页面源码是最核心的产物,它**不在 JSON 里**,而在 DB(`db/ezagent_core.db`,SQLite),有两份互补的存法:

### 1.1 当前活动页源码 → `kind_snapshots` 表(orchestrator 的 slice)

- loom orchestrator(`Ezagent.Behavior.LoomOrchestrator`)的状态 slice 叫 **`:loom_orchestrator`**,里面有字段 **`loom_source`** —— 这就是**当前活动页的源码**(一组文件 `%{"/App.jsx" => "...", ...}` + 配置)。
- 框架按 **snapshot-on-change** 把每个 Kind 的 slice 落到 `kind_snapshots` 表:
  | 列 | 内容 |
  |---|---|
  | `uri` | `entity://<ws>/agent/loomorch_<sid>` |
  | `kind_type` | `loomorch`(loom agent 的 flavor 也存这) |
  | `state_binary` | **Erlang ETF 二进制**(`<<131,...>>`)—— slice 的真身 |
  | `state` | JSON 镜像(可读) |
  | `version` / `workspace_uri` / `ever_created` | 版本 / 工作区 / 是否建过 |
- **谁能改**:只有**创作型 session** 的 v0/builder worker 能改源码 —— 它走 `{:set, :loom_source, <new>}` effect → 框架写新快照。消费/发布/fork 出来的会话拿到的是**冻结 base**,只能在上面叠 `user_schema` ops(见 §2),**不能重写源码**。

### 1.2 历史版本源码 → `messages` 表(page_update 消息)

- 每次页面更新,orchestrator 还会**发一条 `page_update` 消息**进 session,落到 `messages` + `message_routings` 表。消息 body 文本里嵌:
  ```
  <span type="page_update">{"files":{"/App.jsx":"...源码..."},"danmakuConfig":{...},...}</span>
  ```
- 所以**每个历史版本的整套源码都在 messages 表里**留痕。「编辑回退」就是靠它:不动历史,让 builder **再 append 一条**带旧版本源码的 `page_update`(`POST /loom/api/:ws/:sid/revert`,body `{"to_id": "<某条 page_update 消息 id>"}`),同时把活动页旁路源回退到那一版。

> 小结:**活动态在 `kind_snapshots`,版本史在 `messages`**。两者都在那一个 SQLite 文件里。

---

## 2. 旁路 JSON 存储(plugin 自管)

不进 Kind slice、但要跨重启留存的边角数据,loom 各模块各自存一个 **pretty JSON 文件**,统一在 `~/.ezagent/<profile>/`。读写模式都是**整盘 read-modify-write**(`load_all → Map.put(key, val) → save_all`),key 一般是**规范的 workspace-first session URI 字符串** `session://<ws>/loom/<sid>`。

| 文件 | 模块 | key | 存什么 / 怎么改 |
|---|---|---|---|
| `loom_saved_classes.json` | `SavedClasses` | class 名 `session.<saved>` | **Plan B 核心**:保存/发布物的整盘 `saved_state`(含 `orchestrator.loom_source`、workers、knowledge、roles、pages)+ `published`/`token`/`ws` 标记。`instantiate_from_data/3` 据此直接实例化会话。改:保存/发布动作写入;手改即编辑该 JSON。 |
| `loom_snapshots.json` | `Snapshots` | `token` | 分享快照:对话历史 + `user_schema` ops + 页面 + `origin_sid`/`ws`/`template_class`。`GET /loom/snapshot/:token` 只读浏览;fork 时把 ops 复制进新会话。 |
| `loom_lineage.json` | `Lineage` | 节点 ref(class 名 / session URI) | 衍生**谱系**:`published_from` / `derived_from` / `forked_from` 三种 typed parent 指针。接线员同伴集靠它算。 |
| `loom_roles.json` | `RoleConfig` | session URI | per-session **角色门控**:`creator` + 内建 `superadmin` + 自定义 `roles`(key/label/effect/view/url/entities)。`/loom/api/:ws/:sid/roles` 读写。 |
| `loom_workers.json` | `WorkerConfig` | session URI | per-session **worker 配置**(每个 `key`/`desc`/`prompt`)。首次 seed 2 个默认通用 worker;`Team.ensure_team` 按它带配置 spawn。 |
| `loom_user_schemas.json` | `UserSchema` | session URI | 消费侧叠在冻结 base 上的 **user_schema ops**(Stitch 只 append ops,不碰源码)。 |
| `loom_pages.json` | `Pages` | session URI | 多页结构。 |
| `loom_page_init.json` | `PageInit` | session URI | 页面初始 files。 |
| `loom_knowledge.json` | `Knowledge` | session URI | 知识库 **markdown** 字符串。 |
| `loom_salesperson_chats.json` | `SalespersonChat` | session URI | 导购(Stitch)预览侧对话记录(`[{role,text,id}]`)。 |
| `loom_consumer_sessions.json` | `ConsumerSession` | session URI | 消费会话标记。 |
| `loom_owned.json` | `OwnedSessions` | 账号 URI | 某账号拥有的会话列表。 |
| `loom_stats.json` | `Stats` | session URI | Claude Code 调用统计(Dashboard 展示)。 |

**格式**:全是 `Jason.encode!(map, pretty: true)` 的 JSON,顶层一个 map,key→该类数据。坏数据/解析失败时模块都 `rescue` 成空 map,不崩。

---

## 3. 素材库 —— 文件系统目录

用户上传/挂的**素材**(可能是一个很大的源码文件夹)**不进 prompt、不进 JSON**,而是直接放文件系统:

```
~/.ezagent/<profile>/loom_materials/<ws>/<sid>/
```

- `Materials.ensure_dir(ws, sid)` 在 session 初始化时建好这个目录(目录即库)。
- v0 / Claude Code 以它为 **cwd**,用 `Read` 等工具按需读文件 —— **只在用户要求时才读**,避免把大文件塞进 prompt(见近期 commit「builder reads materials only when the user asks」)。
- 改:往这个目录放/删文件即可。

---

## 4. 怎么改(按场景)

| 想改的东西 | 怎么改 |
|---|---|
| **当前页面源码** | 走 builder/v0:在创作会话里 @builder 让它改 → `{:set, :loom_source}` → 新快照 + 一条 page_update。**不要手改 DB**。 |
| **回退到旧版页面** | `POST /loom/api/:ws/:sid/revert` `{"to_id": <page_update 消息 id>}`,或前端「回退历史」。 |
| **消费侧的页面叠加** | user_schema ops(`/user-schema`),只 append,不动 base。 |
| **worker / 角色 / 知识库 / 多页** | 对应 HTTP endpoint(`/workers`、`/roles`、…)或直接编辑对应 `loom_*.json`。 |
| **素材** | 往 `loom_materials/<ws>/<sid>/` 放/删文件。 |
| **排障 / 手工迁移** | 直接编辑 `loom_*.json`(注意 key 必须是**规范 workspace-first** `session://<ws>/loom/<sid>`;本次 port 就手动迁过 `loom_lineage.json` 的旧 stitch 顺序 key)。DB 里的 slice 不要手改 ETF;要重置就删对应 `kind_snapshots` 行让它重建(注意会丢状态)。 |

---

## 5. 一句话记忆

- **源码/运行态** → SQLite(`kind_snapshots` 活动态 + `messages` 版本史)。
- **边角 config/谱系/角色/知识** → `~/.ezagent/<profile>/loom_*.json`(整盘 JSON,key=规范 session URI)。
- **大素材** → `~/.ezagent/<profile>/loom_materials/<ws>/<sid>/`(真实文件)。
- 换 `EZAGENT_PROFILE` = 换一整套数据根,互不干扰。
