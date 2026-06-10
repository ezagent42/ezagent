# Loom 数据归宿地图

> 权威详述：`docs/loom/2026-06-08-loom-data-lifecycle.md`（阶段 0-7 全程 + 重启/
> 清理边界）。本文件是速查 + 该文档之后的增量修正。

## 五个旁路 JSON（`~/.ezagent/<EZAGENT_PROFILE>/`，profile 默认 `default`）

| 文件 | key | value | 写入点 | 模块 |
|---|---|---|---|---|
| `loom_user_schemas.json` | session uri | `[op, ...]` 增强操作序列 | Stitch 加内容 / fork 复制 | `user_schema.ex` |
| `loom_stitch_chats.json` | session uri | `[{role, text, id}, ...]` | 每条 Stitch 收发 | `stitch_chat.ex` |
| `loom_snapshots.json` | 16-hex token | `{ws, page, ops, conversation, origin_sid, created_at}` | 分享时冻结 | `snapshots.ex` |
| `loom_saved_classes.json` | `session.<name>` / `session.pub_<hex>` | `{saved_state, description, saved_at, ...}` | 存为模板 / 发布 | `saved_classes.ex` |
| `loom_knowledge.json` | session uri | Markdown 知识库 | 编辑器保存 / fork 复制 | `knowledge.ex` |

> ⚠️ data-lifecycle 文档写的是"**四个**旁路 JSON"——它写于 06-08，
> `loom_knowledge.json` 是 06-09 加的第五个，文档未更新。

## 走 ezagent 正轨的数据

| 数据 | 归宿 |
|---|---|
| session 对话历史 | `Ezagent.MessageStore`（正常 session 消息） |
| agent / session 状态 | **Kind snapshot**（SnapshotStore，snapshot-on-change） |
| 临时用户 / loom_signup 用户 | Identity（`entity://user/<ws>/<username>`，Bcrypt） |
| saved class 的 Registry 注册 | `Ezagent.TemplateRegistry`（boot 时从 JSON 重建模块） |

## 消歧（最容易出错的一个词）

- **share snapshot**（本文件第 3 行那个）= 分享/发布时冻结的不可变快照，
  loom 自己的旁路 JSON，分享者后续编辑**不回流**。
- **Kind snapshot** = ezagent 核心的状态持久化（SnapshotStore / StateRebuilder），
  支撑重启重建与 lazy-spawn。
- 两者无任何关系。代码注释里 `snapshots.ex` 开头就有同样警告。

## 重启 / 清理语义速记

- 旁路 JSON 全部**持久**：重启后 saved classes 重新注册、快照/对话/知识库都在。
- Kind snapshot 让死掉的 session **可以被任何 in-flight dispatch 复活**
  （lazy-spawn-from-snapshot）——这是 ghost-session 问题的根因，见 `pitfalls.md`。
- `LoomSession.cleanup/3`（移除模板时触发）= terminate + Kind snapshot 删除，
  fire-and-forget，与复活路径存在竞态——所以 UI 层另有"可见性 = 模板声明"的过滤。

## 迁移指向

socialware 上这些归宿全部变化：页面/快照 → `:surface` 不可变版本 + 指针；
user_schema / stitch → vertical 后置项；saved classes → `template.read/write`。
详见 `migration-map.md` §2.5。
